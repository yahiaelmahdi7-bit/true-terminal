import Testing
import Foundation
@testable import True

@Suite(.serialized) struct PeerEndToEndTests {
    @Test func pairJobEventsDoneWithResultAndOneLineToLead() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        let link = try pairUp(a, b).get()
        #expect(link.label == "Bea")
        #expect(b.engine.peerLinks().first?.label == "Al" && b.engine.lastPaired == "Al")
        #expect(a.engine.peerLinks().first?.confirmed == true)             // pair-accept came back

        let id: String
        switch a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "do the thing") {
        case .success(let j): id = j
        case .failure(let e): Issue.record("\(e)"); return
        }
        settle(a, b)
        #expect(b.launcher.panes.count == 1 && b.engine.inboundJobs().first?.req.jobId == id)
        b.engine.paneEvent(pane: b.launcher.pane, kind: .progress); settle(a, b)
        #expect(a.engine.status(jobId: id).first?.status == .working)

        try "Fixed it. Verified with tests.".write(toFile: b.engine.resultPath(id), atomically: true, encoding: .utf8)
        b.engine.paneEvent(pane: b.launcher.pane, kind: .stop); settle(a, b)
        let sent = try #require(a.engine.result(jobId: id))
        #expect(sent.status == .done && sent.result?.contains("Fixed it") == true)
        #expect(a.launcher.lines.count == 1 && a.launcher.lines[0].1.contains("[peer Bea]") && a.launcher.lines[0].1.contains("done"))

        let r = PeerCLI.handle(["op": "result", "jobId": id], engine: a.engine)
        #expect(r["ok"] as? Bool == true && r["status"] as? String == "done")
        #expect((PeerCLI.handle(["op": "list"], engine: a.engine)["peers"] as? [String]) == ["Bea"])
        #expect(PeerCLI.handle(["op": "result", "jobId": "nope"], engine: a.engine)["ok"] as? Bool == false)
        #expect(PeerCLI.handle(["op": "bogus"], engine: a.engine)["ok"] as? Bool == false)
    }

    @Test func nothingOnTheWireContainsThePlaintext() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        final class Tap: @unchecked Sendable { var blobs: [Data] = [] }
        let tap = Tap()
        relay.rewrite = { to, blob in tap.blobs.append(blob); return (to, blob) }
        try pairUp(a, b).get()
        _ = a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "SECRET-BRIEF-TEXT")
        settle(a, b)
        #expect(tap.blobs.count >= 3)
        #expect(b.launcher.panes.count == 1)
        for blob in tap.blobs { #expect(!String(decoding: blob, as: UTF8.self).contains("SECRET-BRIEF-TEXT")) }
    }

    @Test func aRelayThatSwapsOrRedirectsCannotHijackPairing() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        let m = PeerSide("Mallory", relay: relay, clock: clock)
        defer { a.close(); b.close(); m.close() }
        let mbox = m.identity.mailboxId
        relay.rewrite = { _, blob in (mbox, blob) }                        // everything goes to Mallory instead
        try pairUp(a, b).get()
        #expect(m.engine.peerLinks().isEmpty && m.engine.dropCount >= 1)
        #expect(b.engine.peerLinks().isEmpty)
        // Mallory forges a pair-accept to the joiner under her own keys: the joiner pinned the inviter's keys from the invite.
        let body = try JSONSerialization.data(withJSONObject: ["t": "pair-accept", "name": "Bo"])
        let forged = try #require(PeerSeal.seal(payload: body, now: clock.now(), from: m.identity, to: a.identity.keys))
        a.engine.receive(forged)
        #expect(a.engine.peerLinks().count == 1 && a.engine.peerLinks()[0].mailboxId == b.identity.mailboxId)
        #expect(a.engine.peerLinks()[0].confirmed == false)
    }
}
