import Testing
import Foundation
@testable import True

/// The coordinator driving real handshakes between real (temp) engines over the fake in-memory network.
@MainActor
final class LanNode {
    let side: PeerSide, transport: FakeLanTransport, lan: PeerLanCoordinator, timers = ManualTimers()
    init(_ name: String, net: FakeLanNet, relay: FakeRelay, clock: Clock, address: String) {
        side = PeerSide(name, relay: relay, clock: clock)
        transport = FakeLanTransport(net: net, address: address)
        lan = PeerLanCoordinator(transport: transport, engine: side.engine, timer: timers.factory, now: { clock.now() })
    }
    func close() { lan.close(); side.close() }
    func rowId(_ name: String) -> String? { lan.rows.first { $0.name == name }?.id }
}

@MainActor
@Suite(.serialized) struct PeerLanFlowTests {
    @MainActor final class World {
        let net = FakeLanNet(), relay = FakeRelay(), clock = Clock()
        var nodes: [LanNode] = []
        func node(_ name: String) -> LanNode {
            let n = LanNode(name, net: net, relay: relay, clock: clock, address: name.lowercased()); nodes.append(n); return n
        }
        func close() { nodes.forEach { $0.close() } }
        func settle() { net.run(); for n in nodes { n.side.engine.drain() }; net.run() }
    }

    @Test func fullFlowPairsBothMacs() throws {
        let w = World(); defer { w.close() }
        let a = w.node("Ann"), b = w.node("Bob")
        a.lan.open(); b.lan.open()
        let row = try #require(a.rowId("Bob"))
        a.lan.invite(rowId: row)
        #expect(a.lan.sendState[row] == .connecting)
        w.net.run()
        let p = try #require(b.lan.prompt)
        guard case .check(let code)? = a.lan.sendState[row] else { Issue.record("sender should show the code"); return }
        #expect(p.code == code && p.name == "Ann" && code.count == 7)
        a.lan.confirmSend()
        #expect(a.lan.sendState[row] == .waitingAccept)
        b.lan.accept()
        w.net.run()
        #expect(a.lan.sendState[row] == .pairing && b.lan.prompt == nil)
        w.settle(); a.lan.rebuild(); b.lan.rebuild()
        #expect(a.lan.sendState[row] == .paired)
        #expect(a.side.engine.peerLinks().map(\.label) == ["Bob"] && b.side.engine.peerLinks().map(\.label) == ["Ann"])
        #expect(a.lan.rows.first?.paired == true && b.lan.rows.first?.paired == true)
        a.lan.invite(rowId: row)                                  // Paired rows are not offered again
        #expect(a.lan.sendState[row] == .paired)
    }

    @Test func declineLeavesNoPeerAndNoInvite() throws {
        let w = World(); defer { w.close() }
        let a = w.node("Ann"), b = w.node("Bob")
        a.lan.open(); b.lan.open()
        let row = try #require(a.rowId("Bob"))
        a.lan.invite(rowId: row); w.net.run()
        b.lan.cancelSession(); w.settle()
        #expect(a.lan.sendState[row] == .declined && b.lan.prompt == nil)
        #expect(a.side.engine.liveInviteCount() == 0 && a.side.engine.peerLinks().isEmpty && b.side.engine.peerLinks().isEmpty)
        a.lan.invite(rowId: row)                                  // Invite is offered again after Declined
        #expect(a.lan.sendState[row] == .connecting)
    }

    @Test func receiverPromptTimeoutAndSenderTimeout() throws {
        let w = World(); defer { w.close() }
        let a = w.node("Ann"), b = w.node("Bob")
        a.lan.open(); b.lan.open()
        let row = try #require(a.rowId("Bob"))
        a.lan.invite(rowId: row); w.net.run()
        #expect(b.timers.fire(PeerLanHandshake.receiverPromptSeconds)); w.settle()
        #expect(b.lan.prompt == nil && a.lan.sendState[row] == .timedOut && a.side.engine.liveInviteCount() == 0)
        a.lan.invite(rowId: row); w.net.run()
        #expect(a.timers.fire(PeerLanHandshake.senderPromptSeconds)); w.settle()
        #expect(a.lan.sendState[row] == .timedOut && b.lan.prompt == nil && a.side.engine.liveInviteCount() == 0)
    }

    @Test func secondConnectionGetsBusy() throws {
        let w = World(); defer { w.close() }
        let a = w.node("Ann"), b = w.node("Bob")
        a.lan.open(); b.lan.open()
        a.lan.invite(rowId: try #require(a.rowId("Bob"))); w.net.run()
        let intruder = b.transport.inject(remote: "10.0.0.7"); w.net.run()
        #expect(intruder.deliveredTypes() == ["bye"])
        #expect(b.lan.prompt != nil)                                // the first handshake is untouched
    }

    @Test func busyReceiverShowsBusyOnTheSenderRow() throws {
        let w = World(); defer { w.close() }
        let a = w.node("Ann"), b = w.node("Bob"), c = w.node("Cy")
        a.lan.open(); b.lan.open(); c.lan.open()
        a.lan.invite(rowId: try #require(a.rowId("Bob"))); w.net.run()
        let row = try #require(c.rowId("Bob"))
        c.lan.invite(rowId: row); w.net.run()
        #expect(c.lan.sendState[row] == .busy)
        #expect(b.lan.prompt?.name == "Ann")
    }

    @Test func sixthConnectionInAMinuteIsClosedSilently() {
        let w = World(); defer { w.close() }
        let b = w.node("Bob")
        b.lan.open()
        var conns: [FakeLanConnection] = []
        for _ in 0..<6 { conns.append(b.transport.inject(remote: "10.0.0.7")); w.net.run() }
        #expect(conns[1].deliveredTypes() == ["bye"])               // busy
        #expect(conns[5].deliveredTypes().isEmpty && conns[5].closed)  // rate-limited: nothing said
    }

    @Test func connectTimeoutReadsCantReach() throws {
        let w = World(); defer { w.close() }
        let a = w.node("Ann"), b = w.node("Bob")
        a.lan.open(); b.lan.open()
        let row = try #require(a.rowId("Bob"))
        a.lan.invite(rowId: row)                                    // never run the network: it never connects
        #expect(a.timers.fire(PeerLanCoordinator.connectSeconds))
        #expect(a.lan.sendState[row] == .cantReach)
        a.lan.invite(rowId: row)
        #expect(a.lan.sendState[row] == .connecting)
    }

    @Test func windowCloseMidHandshakeSaysByeAndStopsListening() throws {
        let w = World(); defer { w.close() }
        let a = w.node("Ann"), b = w.node("Bob")
        a.lan.open(); b.lan.open()
        let row = try #require(a.rowId("Bob"))
        a.lan.invite(rowId: row); w.net.run()
        #expect(b.lan.prompt != nil)
        b.lan.close(); w.settle()
        #expect(!b.transport.isOpen && b.lan.prompt == nil && b.lan.rows.isEmpty)
        #expect(a.lan.sendState[row] == nil && a.side.engine.liveInviteCount() == 0)
        #expect(a.transport.dialled.first?.closed == true)
    }

    @Test func relayConfirmTimeoutShowsItsOwnState() throws {
        let w = World(); defer { w.close() }
        let a = w.node("Ann"), b = w.node("Bob")
        a.lan.open(); b.lan.open()
        let row = try #require(a.rowId("Bob"))
        a.lan.invite(rowId: row); w.net.run()
        a.lan.confirmSend(); b.lan.accept(); w.net.run()
        #expect(a.lan.sendState[row] == .pairing)
        #expect(a.timers.fire(PeerLanCoordinator.relayConfirmSeconds))
        #expect(a.lan.sendState[row] == .relayTimeout)
    }
}
