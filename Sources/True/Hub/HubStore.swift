import Foundation
import Observation

/// Read-only readers for the two directories other tools own. Never writes; never opens a `*.key`.
enum HubScanner {
    static let claudeDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")

    /// `sessions/<pid>.json` only — the neighbouring `<pid>.<hash>.key` files hold secrets and are skipped by extension.
    static func peers(in dir: URL) -> [PeerSession] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { n in
            (try? Data(contentsOf: dir.appendingPathComponent(n))).flatMap(PeerSession.parse)
        }.sorted { $0.pid < $1.pid }
    }

    /// Every `builders/<id>/meta.json`, unfiltered (the model applies the visibility rule).
    static func builders(in dir: URL, alive: (Int32) -> Bool = { PeerSession.isAlive($0) }) -> [BuilderRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { n in
            let d = dir.appendingPathComponent(n)
            guard var r = (try? Data(contentsOf: d.appendingPathComponent("meta.json")))
                .flatMap({ BuilderRecord.parse($0, dir: d.path, alive: alive) }) else { return nil }
            if r.state == .running {
                r.lastWrite = (try? FileManager.default.attributesOfItem(atPath: d.appendingPathComponent("stream.jsonl").path)[.modificationDate] as? Date)?
                    .timeIntervalSince1970
            }
            return r
        }.sorted { ($0.started, $0.id) > ($1.started, $1.id) }
    }

    /// What the read-only builder sheet shows: the final report when there is one, else what the run
    /// last did (assistant text and tool names from the tail of stream.jsonl, like `builder tail`).
    static func detail(of b: BuilderRecord, lines: Int = 40) -> String {
        guard let dir = b.dir else { return "" }
        let d = URL(fileURLWithPath: dir)
        if let result = try? String(contentsOf: d.appendingPathComponent("result.md"), encoding: .utf8),
           !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return result
        }
        guard let h = try? FileHandle(forReadingFrom: d.appendingPathComponent("stream.jsonl")) else { return "(no output yet)" }
        defer { try? h.close() }
        // Only the last 64 KB: a long run's stream is megabytes and this reads on a click.
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        return tail(ofStream: text, lines: lines)
    }

    /// One line of what a running builder last did (its newest assistant text or tool), for the Working card.
    static func lastActivity(of b: BuilderRecord) -> String? {
        guard let dir = b.dir, let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: dir).appendingPathComponent("stream.jsonl")) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        guard let last = tail(ofStream: text, lines: 1).split(separator: "\n").last, last != "(no output yet)" else { return nil }
        let one = last.replacingOccurrences(of: "[tool] ", with: "Using ").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(one.prefix(120))
    }

    static func tail(ofStream text: String, lines: Int) -> String {
        var out: [String] = []
        for raw in text.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  o["type"] as? String == "assistant",
                  let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in content {
                if block["type"] as? String == "text", let t = block["text"] as? String {
                    out.append(String(t.prefix(300)))
                } else if block["type"] as? String == "tool_use", let n = block["name"] as? String {
                    out.append("[tool] \(n)")
                }
            }
        }
        return out.isEmpty ? "(no output yet)" : out.suffix(lines).joined(separator: "\n")
    }
}

enum HubFilter: Hashable, CaseIterable { case all, seats, crew, chat }

/// The Hub's live data: peer sessions and builders, refreshed when either directory changes (and when
/// the Hub becomes visible). Event-driven — no timers: a DispatchSource per watched path parks in
/// kqueue at 0% CPU. Directory sources catch files added/removed/renamed; a running builder's meta.json
/// and a live session's file are rewritten inside their own folder/file, so those are watched too.
@MainActor
@Observable
final class HubStore {
    static let shared = HubStore()

    private(set) var peers: [PeerSession] = []
    private(set) var builders: [BuilderRecord] = []
    /// All (default) / Seats / Crew — the toggle at the top of the Hub.
    var filter: HubFilter = .all

    @ObservationIgnored private let sessionsDir: URL
    @ObservationIgnored private let buildersDir: URL
    @ObservationIgnored private var sources: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(claudeDir: URL = HubScanner.claudeDir) {
        sessionsDir = claudeDir.appendingPathComponent("sessions")
        buildersDir = claudeDir.appendingPathComponent("builders")
    }

    /// Launch side effect (justified in TrueApp): one scan + a handful of kqueue watches. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        Task { await reload() }
    }

    /// Scan off the main actor, publish only if something changed (so cards don't flicker), re-arm watchers.
    func reload() async {
        let (s, b) = (sessionsDir, buildersDir)
        let (newPeers, newBuilders) = await Task.detached(priority: .utility) {
            (HubScanner.peers(in: s), HubScanner.builders(in: b))
        }.value
        if newPeers != peers { peers = newPeers }
        if newBuilders != builders { builders = newBuilders; PeerBuilders.report(newBuilders); if WatcherStore.active { WatcherStore.shared.checkStuck() } }
        rearm()
    }

    /// The Hub just became visible: pids may have died with no file event, so re-probe now.
    func hubAppeared() { schedule(after: .zero) }

    private func schedule(after delay: Duration = .milliseconds(250)) {
        // Coalesce a burst of writes (a builder rewrites meta.json several times a second) into one scan.
        // One-shot per burst, not a loop.
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// Watch: both roots, every running builder's folder, every live session's file. Others are dropped.
    private func rearm() {
        var want: Set<String> = [sessionsDir.path, buildersDir.path]
        for b in builders where b.state == .running { if let d = b.dir { want.insert(d) } }
        for p in peers { want.insert(sessionsDir.appendingPathComponent("\(p.pid).json").path) }
        for path in sources.keys where !want.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for path in want where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                        eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.schedule() } }
            src.setCancelHandler { close(fd) }
            sources[path] = src
            src.resume()
        }
    }
}
