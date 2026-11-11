import Testing
import Foundation
@testable import True

private func craftedChat(from: PeerIdentity, to: PeerSide, _ payload: [String: Any]) -> Data {
    PeerSeal.seal(payload: try! JSONSerialization.data(withJSONObject: payload), now: Date(timeIntervalSince1970: 1_800_000_000), from: from, to: to.identity.keys)!
}

/// 100x 2d: a chat line to a seat on another Mac always comes back with an answer.
@Suite(.serialized) struct PeerChatReplyTests {
    func rig() -> (a: PeerSide, b: PeerSide, abus: ChatBus, bbus: ChatBus) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        let ab = a.attachChat(), bb = b.attachChat()
        ab.join("pm", "#bea"); bb.join("dev", "#al")
        return (a, b, ab, bb)
    }
    func send(_ r: (a: PeerSide, b: PeerSide, abus: ChatBus, bbus: ChatBus), _ ch: String) {
        _ = r.a.engine.postChat(channel: ch, agent: "pm", text: "ping")
        r.a.engine.flushChat(); settle(r.a, r.b)
    }
    func texts(_ r: (a: PeerSide, b: PeerSide, abus: ChatBus, bbus: ChatBus)) -> [String] { r.abus.tail("#bea").map(\.text) }

    @Test func unknownSeatComesBackAsNoSeat() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        send(r, "@ghost@bea")
        #expect(texts(r).last == "No ghost on Bea")
        #expect(r.b.sink.lines("dev").isEmpty)
    }

    @Test func deliveredSeatSendsAReceipt() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        r.b.sink.awake = ["dev"]
        send(r, "@dev@bea")
        #expect(r.b.sink.lines("dev") == ["[@dev pm@al] ping"])
        #expect(texts(r).last == "Delivered to dev on Bea")
    }

    @Test func retriedIdIsAnsweredAgainButDeliveredOnce() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        r.b.sink.awake = ["dev"]
        let item: [String: Any] = ["id": "dupr", "ts": 1, "channel": "@dev", "from": ["agent": "pm", "mac": "al"], "text": "once"]
        for _ in 0..<2 {
            r.b.engine.receive(craftedChat(from: r.a.identity, to: r.b, ["t": "chat", "items": [item]]))
            settle(r.a, r.b)
        }
        #expect(r.b.sink.lines("dev").count == 1)
        #expect(texts(r).filter { $0 == "Delivered to dev on Bea" }.count == 1)   // receipt deduped on the sender
    }

    @Test func oldPeerGetsNoReceiptNotice() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        r.b.sink.awake = ["dev"]
        let bea = try #require(r.a.engine.peerLinks().first)
        var old = try #require(r.a.engine.peerCaps(bea.mailboxId))
        old.features = ["watch", "m1"]
        r.a.engine.setPeerCaps(bea.mailboxId, old)
        let al = try #require(r.b.engine.peerLinks().first)      // an old receiver never sends a reply either
        r.b.engine.setPeerCaps(al.mailboxId, old)
        send(r, "@dev@bea")
        #expect(r.b.sink.lines("dev") == ["[@dev pm@al] ping"])
        #expect(texts(r).last == "Sent (no receipt from this Mac's version)")
        #expect(!texts(r).contains("Delivered to dev on Bea"))
    }

    @Test func receiverStaysQuietToASenderWithoutTheFlag() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let al = try #require(r.b.engine.peerLinks().first)
        var old = try #require(r.b.engine.peerCaps(al.mailboxId))
        old.features = ["watch", "m1"]
        r.b.engine.setPeerCaps(al.mailboxId, old)
        send(r, "@ghost@bea")
        #expect(!texts(r).contains("No ghost on Bea"))
    }
}
