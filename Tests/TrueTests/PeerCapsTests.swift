import Testing
import Foundation
@testable import True

/// Run 36a step 2 (A1 + A2): caps announced, persisted and reloaded; unknown peers wait then "need the update"; own-path guard.
@Suite(.serialized) struct PeerCapsTests {
    func rig() -> (a: PeerSide, b: PeerSide, clock: Clock) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        return (a, b, clock)
    }

    @Test func capsExchangedOnPairing() throws {
        let (a, b, _) = rig(); defer { a.close(); b.close() }
        let bea = try #require(a.engine.peerLinks().first)
        let c = try #require(a.engine.peerCaps(bea.mailboxId))
        #expect(c.features.contains("watch"))
        #expect(c.home == NSHomeDirectory())
        #expect(a.engine.capsState(mailbox: bea.mailboxId, feature: "watch") == .yes)
        #expect(a.engine.capsState(mailbox: bea.mailboxId, feature: "files") == .no)
        #expect(b.engine.peerLinks().first.flatMap { b.engine.peerCaps($0.mailboxId) } != nil)
    }

    @Test func capsSurviveRestart() throws {
        let (a, b, _) = rig(); defer { a.close(); b.close() }
        let bea = try #require(a.engine.peerLinks().first)
        let reloaded = PeerEngine(root: a.root, identity: a.identity, launcher: FakeLauncher(), transport: a.transport, ownName: "Al")
        #expect(reloaded.peerCaps(bea.mailboxId)?.features == ["watch"])
        #expect(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("caps.json").path))
    }

    @Test func unknownWaitsThenNeedsUpdate() {
        let (a, b, clock) = rig(); defer { a.close(); b.close() }
        #expect(a.engine.capsState(mailbox: "stranger", feature: "watch") == .wait)
        clock.t = clock.t.addingTimeInterval(59)
        #expect(a.engine.capsState(mailbox: "stranger", feature: "watch") == .wait)
        clock.t = clock.t.addingTimeInterval(2)
        #expect(a.engine.capsState(mailbox: "stranger", feature: "watch") == .no)
        #expect(a.engine.needsUpdateMessage(peer: "Mahmoud") == "Mahmoud's True needs the update (v1.3+)")
    }

    @Test func ownPathGuard() throws {
        let (a, b, _) = rig(); defer { a.close(); b.close() }
        // A path under our own home that exists here, while the peer announced a different home → rejected.
        let dir = NSHomeDirectory() + "/Library"        // exists on any Mac
        a.engine.home = NSHomeDirectory()
        // The peer's announced home is its real home (same process) — make it differ by re-announcing.
        b.engine.home = "/Users/mahmoud"
        b.engine.sendCapsToAll(); settle(a, b)
        let r = a.engine.delegate(peer: "Bea", title: "T", brief: "b", mode: .pane, fromAgent: "x", dir: dir)
        guard case .failure(let e) = r else { Issue.record("expected rejection"); return }
        #expect("\(e)".contains("That is a path on your Mac"))
        // A path that doesn't exist locally, or a ~/ path, passes the guard.
        if case .failure(let e2) = a.engine.delegate(peer: "Bea", title: "T", brief: "b", mode: .pane, fromAgent: "x", dir: NSHomeDirectory() + "/nope-\(UUID().uuidString)") { Issue.record("rejected missing path: \(e2)") }
        if case .failure(let e3) = a.engine.delegate(peer: "Bea", title: "T", brief: "b", mode: .pane, fromAgent: "x", dir: "~/Library") { Issue.record("rejected ~ path: \(e3)") }
        // Homes match again: allowed.
        b.engine.home = NSHomeDirectory(); b.engine.sendCapsToAll(); settle(a, b)
        if case .failure(let e4) = a.engine.delegate(peer: "Bea", title: "T", brief: "b", mode: .pane, fromAgent: "x", dir: dir) { Issue.record("rejected with matching homes: \(e4)") }
    }
}
