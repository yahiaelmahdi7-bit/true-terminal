import Testing
import Foundation
@testable import True

/// Run 34 — `true-peer offer` / `true-peer shares`.
@Suite(.serialized) struct PeerCLISharedTests {
    func rig() -> (a: PeerSide, b: PeerSide) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        return (a, b)
    }

    @Test func offerThenSharesOnBothSides() throws {
        let (a, b) = rig(); defer { a.close(); b.close() }
        _ = a.attachChat(); _ = b.attachChat()
        let o = PeerCLI.handle(["op": "offer", "peer": "Bea", "url": testRepo, "name": "demo", "note": "look"], engine: a.engine)
        let id = try #require(o["offerId"] as? String)
        settle(a, b)
        #expect((PeerCLI.handle(["op": "shares"], engine: a.engine)["shares"] as? [[String: String]])?.isEmpty == true)   // nothing until accepted
        b.engine.acceptOffer(id); settle(a, b)
        for side in [a, b] {
            let rows = try #require(PeerCLI.handle(["op": "shares"], engine: side.engine)["shares"] as? [[String: String]])
            #expect(rows.count == 1 && rows[0]["slug"] == "demo" && rows[0]["url"] == testRepo)
        }
        #expect(PeerCLI.handle(["op": "shares"], engine: a.engine)["shares"].map { "\($0)" }?.contains("Bea") == true)
    }

    @Test func offerRefusesBadInput() {
        let (a, b) = rig(); defer { a.close(); b.close() }
        #expect(PeerCLI.handle(["op": "offer", "url": testRepo], engine: a.engine)["ok"] as? Bool == false)                       // no peer
        #expect(PeerCLI.handle(["op": "offer", "peer": "Bea", "url": "nope"], engine: a.engine)["ok"] as? Bool == false)          // not a git URL
        #expect(PeerCLI.handle(["op": "offer", "peer": "Zed", "url": testRepo], engine: a.engine)["ok"] as? Bool == false)        // unknown peer
        // no --name: the repo's own name is used
        let ok = PeerCLI.handle(["op": "offer", "peer": "Bea", "url": testRepo], engine: a.engine)
        #expect(ok["ok"] as? Bool == true)
        settle(a, b)
        #expect(b.engine.pendingOffers().first?.name == "app")
    }

    @Test func theInstalledScriptCompilesAndMentionsTheNewCommands() throws {
        let body = PeerCLI.script(socketPath: "/tmp/x.sock")
        #expect(body.contains("true-peer offer") && body.contains("true-peer shares"))
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("true-peer-\(UUID().uuidString).py")
        try body.write(to: f, atomically: true, encoding: .utf8); defer { try? FileManager.default.removeItem(at: f) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", "-m", "py_compile", f.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
}
