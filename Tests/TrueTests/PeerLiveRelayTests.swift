import Testing
import Foundation
@testable import True

/// Opt-in: two fresh in-process engines talk through the real relay (`TRUE_LIVE_RELAY=1`). Never runs by default.
/// Checks the lease on the real wire: zero activity envelopes while unwatched, a tool item once watched.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TRUE_LIVE_RELAY"] == "1")) struct PeerLiveRelayTests {
    final class Side: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("true-live-\(UUID().uuidString)")
        let identity = PeerIdentity.generate(), launcher = FakeLauncher()
        let engine: PeerEngine, relay: PeerRelayLive
        init(_ name: String) {
            relay = PeerRelayLive(identity: identity, relayURL: { PeerRelay.defaultURL })
            engine = PeerEngine(root: root, identity: identity, launcher: launcher, transport: relay, inboundMode: { .bypass },
                                ownName: name, steering: { true }, share: { .activity }, allowedDirs: { [] }, chatOn: { false },
                                sharedRepos: { [:] }, setSharedRepos: { _ in }, desk: { false }, projectsRoot: root.path + "/Projects",
                                now: { Date() }, scheduler: { s, f in DispatchQueue.global().asyncAfter(deadline: .now() + s, execute: f) })
        }
    }

    private func until(_ timeout: TimeInterval, _ ok: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return true }; try? await Task.sleep(nanoseconds: 200_000_000) }
        return ok()
    }

    @Test func leaseGatesActivityOnTheRealRelay() async throws {
        let a = Side("Al"), b = Side("Bo")
        defer { try? FileManager.default.removeItem(at: a.root); try? FileManager.default.removeItem(at: b.root) }
        _ = a.engine.pairWithInvite(b.engine.invite(), label: "Bea")
        #expect(await until(30) { a.engine.capsState(mailbox: b.identity.mailboxId, feature: "watch") == .yes })
        guard case .success(let id) = a.engine.delegate(peer: "Bea", repo: testRepo, title: "Live", brief: "x", mode: .pane, fromAgent: "lead") else { Issue.record("delegate failed"); return }
        #expect(await until(30) { !b.launcher.panes.isEmpty })
        b.engine.paneEvent(pane: b.launcher.pane, kind: .progress, message: "Read", tool: nil, detail: "a.swift")
        try await Task.sleep(nanoseconds: 4_000_000_000)
        b.engine.flushActivity(id)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(a.engine.activity(jobId: id).filter { $0.kind == .tool }.isEmpty)       // unwatched: nothing on the wire
        a.engine.watchJob(jobId: id)
        #expect(await until(30) { a.engine.activity(jobId: id).contains { $0.kind == .tool } })
    }
}
