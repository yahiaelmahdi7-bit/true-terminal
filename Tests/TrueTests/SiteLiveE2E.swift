import Testing
import Foundation
@testable import True

/// Real Mac + real tailscale. Runs only with TRUE_LIVE_E2E=1. A python server is a child of this process, which plays the pane shell.
@Suite("Sites live", .enabled(if: ProcessInfo.processInfo.environment["TRUE_LIVE_E2E"] == "1"))
struct SiteLiveE2E {
    @Test func detectExposeFetchUnexpose() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("site-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<html><head><title>True E2E</title></head><body>ok</body></html>".write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let py = Process(); py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-m", "http.server", "8765", "--bind", "127.0.0.1"]; py.currentDirectoryURL = dir
        py.standardOutput = FileHandle.nullDevice; py.standardError = FileHandle.nullDevice
        try py.run(); defer { py.terminate() }
        for _ in 0..<50 where SiteHTTP.fetch(URL(string: "http://127.0.0.1:8765/")!, method: "HEAD", timeout: 0.3, maxBytes: 1) == nil { Thread.sleep(forTimeInterval: 0.2) }
        let pane = UUID()
        let svc = SiteService(panes: { [PaneProbe(pane: pane, shellPid: getpid(), hasJob: true, project: "e2e")] })
        let found = svc.scan()
        print("E2E detected: \(found)")
        let site = try #require(found.first { $0.port == 8765 })
        #expect(site.title == "True E2E"); #expect(site.pane == pane); #expect(!site.exposed)
        let ex = svc.expose(port: 8765)
        print("E2E expose: \(ex)")
        #expect(ex.status == 200)
        let url = try #require(ex.json["url"] as? String)
        // A Mac cannot open its own *.ts.net URL (true for the pre-existing :8444 too), so prove the mapping instead:
        // tailscale lists it, and the dev server answers a request carrying the tailnet Host header.
        let served = SitesLogic.servePorts(fromStatus: SiteHTTP.run(RemoteAccess.tailscale, ["serve", "status", "--json"]) ?? Data())
        print("E2E serve ports while exposed: \(served.sorted())")
        #expect(served.contains(8765))
        let r = SiteHTTP.rawGet(port: 8765, host: url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "/", with: ""))
        print("E2E dev server answers tailnet Host -> \(r?.status ?? -1)")
        #expect(r?.status == 200)
        let c = SiteHTTP.fetch(URL(string: url)!, timeout: 4)
        print("E2E GET \(url) from this Mac -> \(c?.status ?? -1) (self-access is blocked by Tailscale here)")
        let un = svc.unexpose(port: 8765)
        print("E2E unexpose: \(un)")
        #expect(un.status == 200)
    }
}
