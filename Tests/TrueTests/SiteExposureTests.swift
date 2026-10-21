import Testing
import Foundation
@testable import True

/// Fake `tailscale`: records every command and keeps a serve table, seeded with the foreign entries.
private final class FakeTS: @unchecked Sendable {
    let lock = NSLock()
    var ports: Set<Int>
    var cmds: [[String]] = []
    init(ports: Set<Int>) { self.ports = ports }
    func run(_ a: [String]) -> Data? {
        lock.lock(); defer { lock.unlock() }
        if a.first == "serve", a.dropFirst().first == "status" {
            let web = ports.map { "\"h.ts.net:\($0)\":{}" }.joined(separator: ",")
            return Data("{\"Web\":{\(web)}}".utf8)
        }
        cmds.append(a)
        if let h = a.first(where: { $0.hasPrefix("--https=") }), let p = Int(h.dropFirst(8)) {
            if a.last == "off" { ports.remove(p) } else { ports.insert(p) }
        }
        return Data()
    }
}

@Suite("SiteExposure")
struct SiteExposureTests {
    private func make(_ ts: FakeTS) -> (SiteExposure, URL) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sites-\(UUID().uuidString).json")
        return (SiteExposure(runner: { ts.run($0) }, file: f), f)
    }

    @Test func exposesOnSamePortAndLeavesForeignAlone() {
        let ts = FakeTS(ports: [443, 8444])
        let (x, _) = make(ts)
        #expect(x.expose(port: 3000) == 3000)
        #expect(ts.ports == [443, 8444, 3000])
        #expect(ts.cmds.last == ["serve", "--bg", "--https=3000", "http://127.0.0.1:3000"])
    }

    @Test func takenPortFallsBackToRange() {
        let ts = FakeTS(ports: [443, 8444, 3000])
        let (x, _) = make(ts)
        #expect(x.expose(port: 3000) == 8450)
        #expect(x.mappings == [3000: 8450])
    }

    @Test func neverRemovesForeignOrReservedEntries() {
        let ts = FakeTS(ports: [443, 8444, 3000])   // 3000 is someone else's
        let (x, _) = make(ts)
        #expect(!x.unexpose(port: 3000))
        x.reconcile(livePorts: [])
        #expect(ts.cmds.isEmpty)
        #expect(ts.ports == [443, 8444, 3000])
    }

    @Test func reconcileRemovesOnlyOwnedStale() {
        let ts = FakeTS(ports: [443, 8444])
        let (x, f) = make(ts)
        _ = x.expose(port: 3000); _ = x.expose(port: 4000)
        x.reconcile(livePorts: [4000])
        #expect(ts.ports == [443, 8444, 4000])
        #expect(ts.cmds.contains(["serve", "--https=3000", "off"]))
        #expect(!ts.cmds.contains { $0.contains("reset") })
        // survives a relaunch: a new instance reads the file and still owns 4000 only
        let again = SiteExposure(runner: { ts.run($0) }, file: f)
        #expect(again.mappings == [4000: 4000])
    }

    @Test func exposeIsIdempotent() {
        let ts = FakeTS(ports: [443])
        let (x, _) = make(ts)
        _ = x.expose(port: 5000)
        let n = ts.cmds.count
        #expect(x.expose(port: 5000) == 5000)
        #expect(ts.cmds.count == n)
    }
}
