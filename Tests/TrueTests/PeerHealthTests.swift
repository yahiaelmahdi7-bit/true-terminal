import Testing
import Foundation
@testable import True

@Suite(.serialized) struct PeerHealthTests {
    private func rig() -> (a: PeerSide, b: PeerSide, relay: FakeRelay, clock: Clock)? {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock, mode: .ask)
        pairUp(a, b)
        return (a, b, relay, clock)
    }
    private func send(_ r: (a: PeerSide, b: PeerSide, relay: FakeRelay, clock: Clock)) -> String? {
        guard case .success(let id) = r.a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "do the thing", mode: .pane, fromAgent: "x") else { return nil }
        settle(r.a, r.b)
        return id
    }

    @Test func removalByThemWritesHistoryAndHoldsJobs() throws {
        let r = try #require(rig()); defer { r.a.close(); r.b.close() }
        let id = try #require(send(r))
        let bMailbox = r.b.identity.mailboxId
        r.b.engine.revoke(label: "Al"); settle(r.a, r.b)
        let row = try #require(r.a.engine.linkHistory().first)
        #expect(row.who == "them" && row.label == "Bea" && row.mailboxId == bMailbox && row.heldJobs == 1)
        #expect(r.a.engine.removedByThem().count == 1)
        #expect(r.a.engine.status(jobId: id).first?.status == .paused)
        let g = try #require(r.a.engine.heldGroups().first)
        #expect(g.count == 1 && g.canResume == false)
        #expect(r.a.engine.problems().contains { $0.kind == .linkRemoved })
        // They send a new invite; same person, same keys: resume works, never before.
        if case .success = r.a.engine.resumeHeld(mailboxId: bMailbox) { Issue.record("resumed with no link") }
        pairUp(r.a, r.b)
        #expect(r.a.engine.heldGroups().first?.canResume == true)
        guard case .success(let ids) = r.a.engine.resumeHeld(mailboxId: bMailbox) else { Issue.record("resume failed"); return }
        settle(r.a, r.b)
        #expect(ids.count == 1 && r.b.engine.inboundJobs().contains { $0.id == ids[0] })
        #expect(r.a.engine.heldGroups().isEmpty)
    }

    @Test func aFailedResumeLeavesTheJobHeld() throws {
        let r = try #require(rig()); defer { r.a.close(); r.b.close() }
        let id = try #require(send(r))
        let bMailbox = r.b.identity.mailboxId
        r.b.engine.revoke(label: "Al"); settle(r.a, r.b)
        pairUp(r.a, r.b)
        // The saved brief is gone, so the re-send fails: the job must stay held, not end up canceled.
        try FileManager.default.removeItem(at: r.a.engine.jobDir(id).appendingPathComponent("brief.md"))
        if case .success(let ids) = r.a.engine.resumeHeld(mailboxId: bMailbox), !ids.isEmpty { Issue.record("resumed without a brief") }
        let job = try #require(r.a.engine.status(jobId: id).first)
        #expect(job.status == .paused && job.heldSince != nil)
        #expect(job.note.hasPrefix("Resume failed"))
        #expect(r.a.engine.heldGroups().first?.count == 1)
    }

    @Test func resumeRefusesADifferentPersonWithTheSameLabel() throws {
        let r = try #require(rig()); defer { r.a.close(); r.b.close() }
        let id = try #require(send(r))
        let bMailbox = r.b.identity.mailboxId
        r.b.engine.revoke(label: "Al"); settle(r.a, r.b)
        let c = PeerSide("Cy", relay: r.relay, clock: r.clock, mode: .ask); defer { c.close() }
        pairUp(r.a, c, as: "Bea")                       // same label, different keys
        #expect(r.a.engine.peerLinks().first?.label == "Bea")
        #expect(r.a.engine.heldGroups().first?.canResume == false)
        if case .success = r.a.engine.resumeHeld(mailboxId: bMailbox) { Issue.record("resumed to a stranger") }
        if case .success = r.a.engine.resumeHeld(mailboxId: c.identity.mailboxId) { Issue.record("resumed by label") }
        settle(r.a, c)
        #expect(c.engine.inboundJobs().isEmpty)
        #expect(r.a.engine.status(jobId: id).first?.status == .paused)
    }

    @Test func heldJobsExpireAfter72HoursAndSenderIsTold() throws {
        let r = try #require(rig()); defer { r.a.close(); r.b.close() }
        let id = try #require(send(r))
        r.b.engine.revoke(label: "Al"); settle(r.a, r.b)
        r.clock.t = r.clock.t.addingTimeInterval(72 * 3600 + 60)
        #expect(r.a.engine.heldGroups().isEmpty)
        #expect(r.a.engine.status(jobId: id).first?.status == .failed)
    }

    @Test func unreadableKindIsHeldWithTheUpdateLine() throws {
        let r = try #require(rig()); defer { r.a.close(); r.b.close() }
        var card = try #require(r.a.engine.peerCaps(r.b.identity.mailboxId)); card.version = "1.3"; card.updated = r.clock.now()
        r.a.engine.setPeerCaps(r.b.identity.mailboxId, card)
        let link = try #require(r.a.engine.peerLinks().first)
        #expect(r.a.engine.sealAndQueue(["t": "resume", "jobId": "x"], to: link, owner: nil) == false)
        #expect(r.a.engine.problems().contains { $0.kind == .needsUpdate && $0.text == "Bea needs to update True" })
        #expect(PeerKindTable.unreadable(kind: "watch", card: card, now: r.clock.now()) == false)
        #expect(PeerKindTable.unreadable(kind: "resume", card: nil, now: r.clock.now()) == false)
    }

    @Test func healthStringsForEachState() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tz = TimeZone(identifier: "UTC")!
        func line(_ s: PeerHealth.State, build: String? = nil, flowing: Bool = false) -> String { PeerHealth.line(s, build: build, flowing: flowing, tz: tz) }
        let heard = PeerHealth.state(heard: now.addingTimeInterval(-120), sentCard: true, cardVersion: PeerCaps.currentVersion, linkAge: 9999, now: now)
        #expect(line(heard, build: "2026-11-02", flowing: true) == "Heard 2 min ago · True 2026-11-02 · jobs flowing")
        let silent = PeerHealth.state(heard: now.addingTimeInterval(-3 * 3600), sentCard: true, cardVersion: PeerCaps.currentVersion, linkAge: 9999, now: now)
        #expect(line(silent) == "Not heard for 3 h")
        let older = PeerHealth.state(heard: now.addingTimeInterval(-60), sentCard: true, cardVersion: "1.0", linkAge: 9999, now: now)
        #expect(line(older) == "Their True is older — update True")
        #expect(line(PeerHealth.state(heard: nil, sentCard: false, cardVersion: nil, linkAge: 5, now: now)) == "Not heard yet")
        #expect(line(.removedByThem(Date(timeIntervalSince1970: 1_800_000_000))).hasPrefix("Link removed by them at "))
        #expect(PeerHealth.relayLine(connected: true) == "Relay: connected")
        #expect(PeerHealth.relayLine(connected: false).hasPrefix("Relay: offline"))
    }

    @Test func lastHeardIsOneReadAndSurvivesRestart() throws {
        let r = try #require(rig()); defer { r.a.close(); r.b.close() }
        let m = r.b.identity.mailboxId
        #expect(r.a.engine.lastHeard(m) != nil)
        #expect(r.a.engine.lastHeard("stranger") == nil)
    }
}
