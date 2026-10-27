import Testing
import Foundation
@testable import True

/// Opt-in (`TRUE_LIVE_LAN=1`): two in-process engines with temp dirs and the real Bonjour transport. Never runs by default.
/// The full-flow case also needs the real relay (`TRUE_LIVE_RELAY=1`).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TRUE_LIVE_LAN"] == "1")) struct PeerLanLiveTests {
    @MainActor final class Side {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("true-live-lan-\(UUID().uuidString)")
        let identity = PeerIdentity.generate(), launcher = FakeLauncher()
        let engine: PeerEngine
        let lan: PeerLanCoordinator
        init(_ name: String, loopback: Bool = false, relay: (PeerIdentity) -> PeerTransport) {
            engine = PeerEngine(root: root, identity: identity, launcher: launcher, transport: relay(identity), inboundMode: { .bypass },
                                ownName: name, steering: { true }, share: { .activity }, allowedDirs: { [] }, chatOn: { false },
                                sharedRepos: { [:] }, setSharedRepos: { _ in }, desk: { false }, projectsRoot: root.path + "/Projects",
                                now: { Date() }, scheduler: { s, f in DispatchQueue.global().asyncAfter(deadline: .now() + s, execute: f) })
            let net = PeerLanNetwork()
            if loopback { net.dialInterface = .loopback }
            lan = PeerLanCoordinator(transport: net, engine: engine)
        }
        func close() { lan.close(); try? FileManager.default.removeItem(at: root) }
    }

    private func until(_ timeout: TimeInterval, _ ok: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return true }; try? await Task.sleep(nanoseconds: 200_000_000) }
        return ok()
    }

    @Test func eachSeesTheOtherWithinFiveSecondsAndPairedAfterPinning() async throws {
        let relay = FakeRelay()
        let a = Side("Live Al \(UUID().uuidString.prefix(4))", relay: { _ in relay.transport(for: "a") }), b = Side("Live Bo \(UUID().uuidString.prefix(4))", relay: { _ in relay.transport(for: "b") })
        defer { a.close(); b.close() }
        a.lan.open(); b.lan.open()
        #expect(await until(5) { a.lan.rows.contains { $0.name == b.engine.ownName } && b.lan.rows.contains { $0.name == a.engine.ownName } })
        #expect(a.lan.rows.first { $0.name == b.engine.ownName }?.paired == false)
        _ = a.engine.pairWithInvite(b.engine.invite(), label: "Bea")
        a.lan.close(); a.lan.open()
        #expect(await until(5) { a.lan.rows.first { $0.name == b.engine.ownName }?.paired == true })
    }

    /// Steps 1 + 3 together: real Bonjour, real handshake, real relay. Both temp engines end with a confirmed link.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRUE_LIVE_RELAY"] == "1"))
    func fullFlowOverRealBonjourAndRelay() async throws {
        let a = Side("Live Al \(UUID().uuidString.prefix(4))", loopback: true, relay: { PeerRelayLive(identity: $0, relayURL: { PeerRelay.defaultURL }) })
        let b = Side("Live Bo \(UUID().uuidString.prefix(4))", relay: { PeerRelayLive(identity: $0, relayURL: { PeerRelay.defaultURL }) })
        defer { a.close(); b.close() }
        a.lan.open(); b.lan.open()
        #expect(await until(5) { a.lan.rows.contains { $0.name == b.engine.ownName } })
        let row = try #require(a.lan.rows.first { $0.name == b.engine.ownName }).id
        a.lan.invite(rowId: row)
        #expect(await until(10) { b.lan.prompt != nil })
        guard case .check(let code)? = a.lan.sendState[row] else { Issue.record("sender shows no code"); return }
        #expect(b.lan.prompt?.code == code)
        a.lan.confirmSend(); b.lan.accept()
        #expect(await until(45) { a.lan.sendState[row] == .paired })
        #expect(a.engine.peerLinks().first?.confirmed == true)
        // The receiver's link confirms on the sender's first relay message after the intro, a beat later.
        #expect(await until(30) { b.engine.peerLinks().first?.confirmed == true })
    }
}
