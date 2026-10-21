import Testing
import Foundation
@testable import True

private func craftedChat(from: PeerIdentity, to: PeerSide, _ payload: [String: Any]) -> Data {
    PeerSeal.seal(payload: try! JSONSerialization.data(withJSONObject: payload), now: Date(timeIntervalSince1970: 1_800_000_000), from: from, to: to.identity.keys)!
}

@Suite(.serialized) struct ChatPeerTests {
    /// Al ("Bea" on the other side is Bo): a calls b `#bea`, b calls a `#al`. Each has a joined seat.
    func rig() -> (a: PeerSide, b: PeerSide, abus: ChatBus, bbus: ChatBus, clock: Clock, relay: FakeRelay) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        let ab = a.attachChat(), bb = b.attachChat()
        ab.join("pm", "#bea"); bb.join("dev", "#al")
        return (a, b, ab, bb, clock, relay)
    }
    func send(_ side: PeerSide, _ ch: String, _ agent: String, _ text: String) {
        _ = side.engine.postChat(channel: ch, agent: agent, text: text)
    }

    @Test func roundTripBothWaysInsideTheSharedPeerChannel() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        r.abus.join("lead", "#bea")
        send(r.a, "#bea", "lead", "hi Bo")
        r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.b.sink.lines("dev") == ["[#al lead@al] hi Bo"])
        #expect(r.a.sink.lines("lead").isEmpty)                       // sender skipped
        #expect(r.a.sink.lines("pm") == ["[#bea lead@al] hi Bo"])     // another local seat in the same room
        send(r.b, "#al", "dev", "hello Al")
        r.b.engine.flushChat(); settle(r.a, r.b)
        #expect(r.a.sink.lines("pm").last == "[#bea dev@bea] hello Al")
        #expect(r.abus.tail("#bea").map(\.text) == ["hi Bo", "hello Al"])      // each side keeps its own file
    }

    @Test func aForeignChannelIsDropped() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let item: [String: Any] = ["id": "x1", "ts": 1, "channel": "#carol", "from": ["agent": "pm", "mac": "al"], "text": "sneaky"]
        let before = r.b.engine.dropCount
        r.b.engine.receive(craftedChat(from: r.a.identity, to: r.b, ["t": "chat", "items": [item]]))
        #expect(r.b.engine.dropCount == before + 1)
        #expect(r.bbus.tail("#carol").isEmpty && r.b.sink.lines("dev").isEmpty)
        // a DM for a seat that does not exist here is dropped too
        let dm: [String: Any] = ["id": "x2", "ts": 1, "channel": "@ghost", "from": ["agent": "pm", "mac": "al"], "text": "boo"]
        r.b.engine.receive(craftedChat(from: r.a.identity, to: r.b, ["t": "chat", "items": [dm]]))
        #expect(r.b.engine.dropCount == before + 2)
    }

    @Test func aChannelOnlyThePeerOwnsCannotBeFaked() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        // "#al" is MY name for Al; Al claiming to speak in "#bo" (a different peer's room) is refused
        let item: [String: Any] = ["id": "y1", "ts": 1, "channel": "#bea", "from": ["agent": "pm", "mac": "al"], "text": "x"]
        r.b.engine.receive(craftedChat(from: r.a.identity, to: r.b, ["t": "chat", "items": [item]]))
        #expect(r.b.sink.lines("dev").isEmpty)
    }

    @Test func aSharedNamedChannelNeedsLocalMembers() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        r.abus.join("pm", "#ops")
        send(r.a, "#ops", "pm", "nobody home"); r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.bbus.tail("#ops").isEmpty)
        r.bbus.join("dev", "#ops")
        send(r.a, "#ops", "pm", "now?"); r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.b.sink.lines("dev") == ["[#ops pm@al] now?"])
    }

    @Test func aDirectLineToAnAgentAtAPeerReachesThatSeat() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        r.b.sink.awake = ["dev"]
        send(r.a, "@dev@bea", "pm", "ping"); r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.b.sink.lines("dev") == ["[@dev pm@al] ping"])
        #expect(r.a.sink.lines("pm").isEmpty)                         // recorded in #bea, not typed anywhere
        #expect(r.abus.tail("#bea").last?.text == "@dev ping")
    }

    @Test func replayedItemsDeliverOnce() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let ok: [String: Any] = ["id": "dup2", "ts": 1, "channel": "#al", "from": ["agent": "pm", "mac": "al"], "text": "once"]
        r.b.engine.receive(craftedChat(from: r.a.identity, to: r.b, ["t": "chat", "items": [ok]]))
        r.b.engine.receive(craftedChat(from: r.a.identity, to: r.b, ["t": "chat", "items": [ok]]))   // fresh envelope, same item id
        #expect(r.b.sink.lines("dev").count == 1)
    }

    @Test func linesWithinThreeHundredMillisecondsShareOneEnvelope() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let sent0 = r.relay.delivered
        r.a.delays.v = []
        for i in 0..<5 { send(r.a, "#bea", "pm", "l\(i)") }
        #expect(r.a.delays.v.filter { $0 == 0.3 }.count == 1)         // one timer armed, not five
        #expect(r.relay.delivered == sent0)                           // nothing on the wire before the window closes
        r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.relay.delivered == sent0 + 1)
        #expect(r.b.sink.lines("dev").count == 5)
        #expect(r.bbus.tail("#al").map(\.text) == ["l0", "l1", "l2", "l3", "l4"])
    }

    @Test func overTwentyPerMinuteQueuesInOrderAndNeverDrops() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        for i in 0..<25 { send(r.a, "#bea", "pm", "m\(i)"); r.a.engine.flushChat(); r.a.engine.drain() }
        settle(r.a, r.b)
        #expect(r.bbus.tail("#al", last: 100).count == 20)            // the cap held
        #expect(r.a.engine.outboxCount() == 5)
        r.clock.t = r.clock.t.addingTimeInterval(61)
        r.a.engine.pump(); settle(r.a, r.b)
        #expect(r.bbus.tail("#al", last: 100).map(\.text) == (0..<25).map { "m\($0)" })
        #expect(r.a.engine.outboxCount() == 0)
    }

    @Test func chatOffNacksOncePerHourAndDeliversNothing() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        r.b.knobs.chat = false
        send(r.a, "#bea", "pm", "one"); r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.b.sink.lines("dev").isEmpty && r.bbus.tail("#al").isEmpty)
        #expect(r.abus.tail("#bea").map(\.from.agent).contains("true"))            // the sender got the system note
        send(r.a, "#bea", "pm", "two"); r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.abus.tail("#bea").filter { $0.from.agent == "true" }.count == 1)  // second line: no second nack
        r.clock.t = r.clock.t.addingTimeInterval(3601)
        send(r.a, "#bea", "pm", "three"); r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.abus.tail("#bea").filter { $0.from.agent == "true" }.count == 2)
        // outbound still works with chat off
        r.b.knobs.chat = false
        send(r.b, "#al", "dev", "i can still talk"); r.b.engine.flushChat(); settle(r.a, r.b)
        #expect(r.a.sink.lines("pm").last?.hasSuffix("i can still talk") == true)
    }

    @Test func reTravelsWithTheLineAndIsStoredOnBothSides() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        _ = r.a.engine.postChat(channel: "#bea", agent: "lead", text: "the answer", re: "q-123")
        r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.abus.tail("#bea").last?.re == "q-123")
        #expect(r.bbus.tail("#al").last?.re == "q-123")
        // an over-long re from the wire is ignored, the line still lands
        let item: [String: Any] = ["id": "z1", "ts": 1, "channel": "#al", "from": ["agent": "lead", "mac": "al"], "text": "x", "re": String(repeating: "r", count: 81)]
        r.b.engine.receive(craftedChat(from: r.a.identity, to: r.b, ["t": "chat", "items": [item]]))
        #expect(r.bbus.tail("#al").last?.text == "x" && r.bbus.tail("#al").last?.re == nil)
    }
}
