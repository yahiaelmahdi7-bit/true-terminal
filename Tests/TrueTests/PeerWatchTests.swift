import Testing
import Foundation
@testable import True

/// Run 36a step 5 (A5): activity flows only while someone holds a watch lease; questions and chat never wait for it.
@Suite struct PeerWatchTests {
    private func rig() -> PeerEngineTests.Rig { PeerEngineTests().rig() }
    private func delegate(_ r: PeerEngineTests.Rig, title: String = "Fix it") throws -> String {
        guard case .success(let id) = r.a.engine.delegate(peer: "Bea", repo: testRepo, title: title, brief: "go", mode: .pane, fromAgent: "lead") else { throw PeerError.invalid("delegate") }
        settle(r.a, r.b)
        return id
    }
    private func tools(_ r: PeerEngineTests.Rig, _ id: String) -> Int { r.a.engine.activity(jobId: id).filter { $0.kind == .tool }.count }
    private func beat(_ r: PeerEngineTests.Rig, _ id: String, _ msg: String = "Read") {
        r.b.engine.paneEvent(pane: r.b.launcher.pane, kind: .progress, message: msg, tool: nil, detail: "a.swift")
        r.clock.t += 3
        r.b.engine.flushActivity(id); settle(r.a, r.b)
    }

    @Test func noLeaseNoActivity() throws {
        let r = rig(); defer { r.close() }
        let id = try delegate(r)
        beat(r, id); beat(r, id, "Edit")
        #expect(tools(r, id) == 0)
        r.a.engine.watchJob(jobId: id); settle(r.a, r.b)       // the backlog arrives once someone looks
        #expect(tools(r, id) == 2)
    }

    @Test func leaseStreamsAndExpires() throws {
        let r = rig(); defer { r.close() }
        let id = try delegate(r)
        r.a.engine.watchJob(jobId: id); settle(r.a, r.b)
        beat(r, id)
        #expect(tools(r, id) == 1)
        r.clock.t += PeerEngine.leaseSeconds + 5
        beat(r, id, "Edit")
        #expect(tools(r, id) == 1)                              // lapsed: held back
        r.a.engine.watchJob(jobId: id); settle(r.a, r.b)
        #expect(tools(r, id) == 2)
    }

    @Test func chatIsNotHeldBehindActivity() throws {
        let r = rig(); defer { r.close() }
        let id = try delegate(r)
        r.a.engine.watchJob(jobId: id); settle(r.a, r.b)
        r.b.engine.paneEvent(pane: r.b.launcher.pane, kind: .progress, message: "Read", tool: nil, detail: "x")
        settle(r.a, r.b)                                        // its status event goes first, so the nack lands on the batch
        r.clock.t += 3
        r.b.transport.rateNext = true                           // the relay turns the activity batch away
        r.b.engine.flushActivity(id); settle(r.a, r.b)
        _ = r.a.engine.stopJob(jobId: id); settle(r.a, r.b)     // b's reply (a non-activity message) still goes through
        #expect(r.a.engine.status(jobId: id).first?.status.isFinal == true)
        #expect(tools(r, id) == 0)
    }

    @Test func perMinuteBudgetIsEngineWide() throws {
        let r = rig(); defer { r.close() }
        let ids = try (0..<3).map { try delegate(r, title: "J\($0)") }
        for id in ids { r.a.engine.watchJob(jobId: id) }
        settle(r.a, r.b)
        for i in 0..<30 {
            for id in ids {
                r.b.engine.paneEvent(pane: r.b.launcher.pane, kind: .progress, message: "Read\(i)", tool: nil, detail: "f")
                r.b.engine.flushActivity(id)
            }
            r.clock.t += 2
        }
        settle(r.a, r.b)
        let sends = ids.map { tools(r, $0) }.reduce(0, +)
        #expect(sends > 0)
        #expect(r.relay.delivered < 400)                         // sanity: not a flood
        #expect(r.b.engine.activitySendsInLastMinute() <= PeerEngine.activityPerMinute)
    }

    @Test func foreignLeaseIsIgnored() throws {
        let r = rig(); defer { r.close() }
        let id = try delegate(r)
        func watch(_ job: String, from who: PeerIdentity) throws {
            let body = try JSONSerialization.data(withJSONObject: ["t": "watch", "jobId": job, "since": 0])
            r.b.engine.receive(try #require(PeerSeal.seal(payload: body, now: r.clock.now(), from: who, to: r.b.identity.keys)))
        }
        try watch(id, from: PeerIdentity.generate())            // unpaired sender
        try watch("no-such-job", from: r.a.identity)            // paired, wrong job
        beat(r, id)
        #expect(tools(r, id) == 0)
    }

    @Test func oldPeerStillStreamsWithoutALease() throws {
        let r = rig(); defer { r.close() }
        let id = try delegate(r)
        r.b.engine.forgetCaps(r.a.identity.mailboxId)
        beat(r, id)
        #expect(tools(r, id) == 1)
    }
}
