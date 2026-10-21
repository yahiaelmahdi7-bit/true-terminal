import Foundation
import Darwin

/// One pane as the detector sees it.
struct PaneProbe: Sendable { var pane: UUID; var shellPid: Int32; var hasJob: Bool; var project: String }

struct SiteInfo: Sendable, Equatable {
    var port: Int
    var title: String
    var pane: UUID
    var project: String
    var command: String
    var servePort: Int?
    var url: String?
    var hostFix: SitesLogic.HostFix?
    var exposed: Bool { servePort != nil }
}

/// What the Remote API needs from Sites. Default implementation does nothing so test servers compile unchanged.
protocol RemoteSites: Sendable {
    func listJSON(refresh: Bool) -> Data
    func expose(port: Int) -> (status: Int, json: [String: Any])
    func unexpose(port: Int) -> (status: Int, json: [String: Any])
}

struct NoSites: RemoteSites {
    func listJSON(refresh: Bool) -> Data { Data(#"{"sites":[]}"#.utf8) }
    func expose(port: Int) -> (status: Int, json: [String: Any]) { (404, ["error": "Sites off"]) }
    func unexpose(port: Int) -> (status: Int, json: [String: Any]) { (404, ["error": "Sites off"]) }
}

/// Finds dev web servers started from True panes and shares them to the phone through `tailscale serve`.
final class SiteService: RemoteSites, @unchecked Sendable {
    static let shared = SiteService()
    static let pollInterval: TimeInterval = 10

    private let lock = NSLock()
    private var sites: [Int: SiteInfo] = [:]
    private var lastScan = Date.distantPast
    private var titles: [Int: (title: String, at: Date)] = [:]
    private var running = false
    private let exposure: SiteExposure
    private let dns: @Sendable () -> String?
    private let panes: @Sendable () -> [PaneProbe]
    private let scanLock = NSLock()
    /// Called (off-main) after every scan that changed the list; the Mac UI mirrors it.
    var onChange: (@Sendable ([SiteInfo]) -> Void)?

    init(exposure: SiteExposure = SiteExposure(runner: { SiteHTTP.run(RemoteAccess.tailscale, $0) }, file: SiteExposure.defaultFile),
         dns: @escaping @Sendable () -> String? = { RemoteAccess.currentDNS() },
         panes: @escaping @Sendable () -> [PaneProbe] = SiteService.livePanes) {
        self.exposure = exposure; self.dns = dns; self.panes = panes
    }

    /// Pane list from the main actor (the model + terminal registry live there).
    static let livePanes: @Sendable () -> [PaneProbe] = {
        let read: () -> [PaneProbe] = {
            MainActor.assumeIsolated {
                var out: [PaneProbe] = []
                for tab in WorkspaceModel.shared.state.tabs {
                    for p in tab.tree.leafIDs {
                        guard let v = TerminalRegistry.shared.view(for: p), v.process.running, v.process.shellPid > 0 else { continue }
                        let fg = tcgetpgrp(v.process.childfd)
                        out.append(PaneProbe(pane: p, shellPid: v.process.shellPid, hasJob: fg > 0 && fg != v.process.shellPid,
                                             project: TabState.basename(tab.cwds[p] ?? "~")))
                    }
                }
                return out
            }
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    // MARK: lifecycle

    /// Reconcile leftovers from a previous run (servers that died while True was closed), then poll while a pane has a job.
    func start() {
        lock.lock(); let already = running; running = true; lock.unlock()
        guard !already else { return }
        exposure.reconcile(livePorts: [])   // nothing is "live" until a scan proves it; stale mappings go now
        Thread.detachNewThread { [self] in
            var hadJob = false
            while isRunning {
                let ps = panes()
                let job = ps.contains { $0.hasJob }
                if job || hadJob { _ = scan(ps) }   // one extra scan after the job ends so a stopped server is cleaned up
                hadJob = job
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
        }
    }

    func stop() { lock.lock(); running = false; lock.unlock() }
    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    // MARK: scan

    @discardableResult
    func scan(_ ps: [PaneProbe]? = nil) -> [SiteInfo] {
        scanLock.lock(); defer { scanLock.unlock() }
        let probes = ps ?? panes()
        let shells = Dictionary(probes.filter { $0.shellPid > 0 }.map { ($0.pane, $0.shellPid) }, uniquingKeysWith: { a, _ in a })
        var listeners: [SitesLogic.Listener] = []
        var parents: [Int32: Int32] = [:]
        if !shells.isEmpty,
           let l = SiteHTTP.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]),
           let p = SiteHTTP.run("/bin/ps", ["-axo", "pid=,ppid="]) {
            listeners = SitesLogic.parseLsof(String(decoding: l, as: UTF8.self))
            parents = SitesLogic.parsePs(String(decoding: p, as: UTF8.self))
        }
        let owned = SitesLogic.attribute(listeners: listeners, shells: shells, parents: parents)
        var next: [Int: SiteInfo] = [:]
        let host = dns()
        for (l, pane) in owned where next[l.port] == nil {
            guard let title = probe(port: l.port) else { continue }
            let sp = exposure.servePort(for: l.port)
            next[l.port] = SiteInfo(port: l.port, title: title, pane: pane,
                                    project: probes.first { $0.pane == pane }?.project ?? "", command: l.command, servePort: sp,
                                    url: sp.flatMap { p in host.map { "https://\($0):\(p)/" } },
                                    hostFix: nil)
        }
        lock.lock()
        for (port, old) in sites where next[port] != nil { next[port]?.hostFix = old.hostFix }
        let changed = next != sites
        sites = next; lastScan = Date()
        lock.unlock()
        exposure.reconcile(livePorts: Set(next.keys))
        if changed { onChange?(snapshot()) }
        return snapshot()
    }

    /// 300 ms HEAD confirms HTTP; the title comes from a short GET, re-read at most every 30 s.
    private func probe(port: Int) -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return nil }
        guard SiteHTTP.fetch(url, method: "HEAD", timeout: 0.3, maxBytes: 1) != nil else { return nil }
        if let t = titles[port], Date().timeIntervalSince(t.at) < 30 { return t.title }
        let body = SiteHTTP.fetch(url, timeout: 1.0)?.body ?? ""
        let t = SitesLogic.title(fromHTML: body) ?? ""
        titles[port] = (t, Date())
        return t
    }

    func snapshot() -> [SiteInfo] { lock.lock(); defer { lock.unlock() }; return sites.values.sorted { $0.port < $1.port } }

    // MARK: RemoteSites

    private func row(_ s: SiteInfo) -> [String: Any] {
        var r: [String: Any] = ["port": s.port, "title": s.title, "pane": s.pane.uuidString, "project": s.project,
                                "command": s.command, "exposed": s.exposed]
        if let u = s.url { r["url"] = u }
        if let f = s.hostFix { r["hostFix"] = ["framework": f.framework, "snippet": f.snippet] }
        return r
    }

    func listJSON(refresh: Bool) -> Data {
        lock.lock(); let stale = Date().timeIntervalSince(lastScan) > Self.pollInterval; lock.unlock()
        let list = (refresh || stale) ? scan() : snapshot()
        return (try? JSONSerialization.data(withJSONObject: ["sites": list.map(row)])) ?? Data(#"{"sites":[]}"#.utf8)
    }

    func expose(port: Int) -> (status: Int, json: [String: Any]) {
        guard snapshot().contains(where: { $0.port == port }) || scan().contains(where: { $0.port == port }) else {
            return (404, ["error": "That server isn't running any more."])
        }
        guard let sp = exposure.expose(port: port) else { return (502, ["error": "Couldn't share it. Is Tailscale on?"]) }
        guard let host = dns() else { return (502, ["error": "Tailscale name not found."]) }
        let url = "https://\(host):\(sp)/"
        // Ask the dev server the way the phone will (Host = the *.ts.net name): frameworks often refuse it.
        var fix: SitesLogic.HostFix?
        if let r = SiteHTTP.rawGet(port: port, host: "\(host):\(sp)") { fix = SitesLogic.blockedHostFix(status: r.status, body: r.body) }
        lock.lock()
        sites[port]?.servePort = sp; sites[port]?.url = url; sites[port]?.hostFix = fix
        let s = sites[port]
        lock.unlock()
        onChange?(snapshot())
        return (200, s.map(row) ?? ["port": port, "exposed": true, "url": url])
    }

    func unexpose(port: Int) -> (status: Int, json: [String: Any]) {
        guard exposure.servePort(for: port) != nil else { return (200, ["port": port, "exposed": false]) }
        guard exposure.unexpose(port: port) else { return (502, ["error": "Couldn't stop sharing."]) }
        lock.lock(); sites[port]?.servePort = nil; sites[port]?.url = nil; sites[port]?.hostFix = nil; lock.unlock()
        onChange?(snapshot())
        return (200, ["port": port, "exposed": false])
    }
}
