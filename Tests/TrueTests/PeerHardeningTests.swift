import Testing
import Foundation
@testable import True

@Suite(.serialized) struct PeerHardeningTests {
    @Test func sendTimeNeverListOnly() {
        let h = "/Users/killk"
        #expect(PeerDirs.sendProblem("~/.ssh", peerHome: h) != nil)
        #expect(PeerDirs.sendProblem("/Users/killk/Library/Mail", peerHome: h) != nil)
        #expect(PeerDirs.sendProblem("/", peerHome: h) != nil)
        #expect(PeerDirs.sendProblem("/Users", peerHome: h) != nil)
        #expect(PeerDirs.sendProblem("/tmp/x", peerHome: h) != nil)              // outside home
        #expect(PeerDirs.sendProblem("~/.true/peers", peerHome: nil) != nil)
        #expect(PeerDirs.sendProblem("~", peerHome: h) == nil)                   // home itself: receiver makes an auto folder
        #expect(PeerDirs.sendProblem("~/Documents/FAB", peerHome: h) == nil)
        #expect(PeerDirs.sendProblem("~/Documents/FAB", peerHome: nil) == nil)
    }

    @Test func delegateRefusesNeverListFolderAtSendTime() {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        pairUp(a, b)
        if case .success = a.engine.delegate(peer: "Bea", title: "T", brief: "b", mode: .pane, fromAgent: "x", dir: "~/.ssh") { Issue.record("sent into ~/.ssh") }
    }

    @Test func resendSealsAgainFromSavedBrief() {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock, mode: .ask)
        defer { a.close(); b.close() }
        pairUp(a, b)
        guard case .success(let id) = a.engine.delegate(peer: "Bea", title: "Bank", brief: "do the bank thing", mode: .pane, fromAgent: "x", dir: "~/Work") else { Issue.record("delegate failed"); return }
        settle(a, b)
        #expect(FileManager.default.contents(atPath: a.engine.jobDir(id).appendingPathComponent("brief.md").path).flatMap { String(data: $0, encoding: .utf8) } == "do the bank thing")
        if case .success = a.engine.resend(jobId: id) { Issue.record("resent a live job") }
        b.engine.decline(id); settle(a, b)
        guard case .success(let id2) = a.engine.resend(jobId: id, dir: "~/Other") else { Issue.record("resend failed"); return }
        settle(a, b)
        #expect(id2 != id)
        let got = b.engine.inboundJobs().first { $0.id == id2 }
        #expect(got?.req.brief == "do the bank thing")
        if case .dir(let p)? = got?.req.target { #expect(p == "~/Other") } else { Issue.record("no dir target") }
        if case .success = a.engine.resend(jobId: "nope") { Issue.record("resent unknown job") }
    }

    // MARK: H5 waiting for Accept

    private func askRig() -> (a: PeerSide, b: PeerSide, clock: Clock, id: String)? {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock, mode: .ask)
        pairUp(a, b)
        guard case .success(let id) = a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "x", mode: .pane, fromAgent: "x") else { return nil }
        settle(a, b)
        return (a, b, clock, id)
    }

    @Test func acceptSinceIsStoredAndSurvivesRestart() throws {
        guard let r = askRig() else { Issue.record("delegate failed"); return }
        defer { r.a.close(); r.b.close() }
        let since = try #require(r.b.engine.inboundJobs().first { $0.id == r.id }?.acceptSince)
        #expect(since == r.clock.now())
        // a new engine on the same folder (an app restart) re-arms the reminders from the stored time
        let delays = PeerSide.Delays(), fired = Counter()
        let again = PeerEngine(root: r.b.root, identity: r.b.identity, launcher: FakeLauncher(), transport: r.b.transport, inboundMode: { .ask },
                               ownName: "Bo", now: { r.clock.now() }, scheduler: { s, f in delays.schedule(s, clock: r.clock, action: f) })
        #expect(again.inboundJobs().first { $0.id == r.id }?.acceptSince == since)
        again.onAcceptReminder = { _ in fired.bump() }
        r.clock.t = since.addingTimeInterval(3601)
        delays.fireDue(r.clock)
        #expect(fired.n == 1)
    }

    @Test func reminderFiresOnceAfterAnHourAndNotAfterAccept() {
        guard let r = askRig() else { Issue.record("delegate failed"); return }
        defer { r.a.close(); r.b.close() }
        let fired = Counter()
        r.b.engine.onAcceptReminder = { _ in fired.bump() }
        r.clock.t = r.clock.t.addingTimeInterval(1800); r.b.delays.fireDue(r.clock)
        #expect(fired.n == 0)
        r.clock.t = r.clock.t.addingTimeInterval(1900); r.b.delays.fireDue(r.clock)
        #expect(fired.n == 1)
    }

    @Test func noReminderForADeclinedJob() {
        guard let r = askRig() else { Issue.record("delegate failed"); return }
        defer { r.a.close(); r.b.close() }
        let fired = Counter()
        r.b.engine.onAcceptReminder = { _ in fired.bump() }
        r.b.engine.decline(r.id)
        r.clock.t = r.clock.t.addingTimeInterval(25 * 3600); r.b.delays.fireDue(r.clock)
        #expect(fired.n == 0)
    }

    @Test func chatNudgeAtADay() {
        guard let r = askRig() else { Issue.record("delegate failed"); return }
        defer { r.a.close(); r.b.close() }
        let bus = r.b.attachChat()
        r.clock.t = r.clock.t.addingTimeInterval(24 * 3600 + 5); r.b.delays.fireDue(r.clock)
        #expect(bus.tail("#peers").contains { $0.text.contains("still waiting for you to accept") })
    }

    @Test func senderSeesWaitingForNameAndAge() {
        guard let r = askRig() else { Issue.record("delegate failed"); return }
        defer { r.a.close(); r.b.close() }
        let j = r.a.engine.status(jobId: r.id)[0]
        #expect(PeerStatusText.isWaitingForAccept(j))
        let line = PeerStatusText.waitingForAccept(name: "Kai", since: r.clock.now(), now: r.clock.now().addingTimeInterval(2 * 3600 + 10 * 60 + 5))
        #expect(line == "waiting for Kai to accept · 2 h 10 m")
        #expect(PeerStatusText.waitingForAccept(name: "K", since: r.clock.now(), now: r.clock.now().addingTimeInterval(45 * 60)) == "waiting for K to accept · 45 m")
    }
}

final class Counter: @unchecked Sendable { private let l = NSLock(); private var c = 0
    func bump() { l.lock(); c += 1; l.unlock() }
    var n: Int { l.lock(); defer { l.unlock() }; return c } }
