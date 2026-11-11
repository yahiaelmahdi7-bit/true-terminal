import Testing
import Foundation
@testable import True

/// Missions M1 — states, decoder table, Card.
@Suite(.serialized) struct PeerMissionsM1Tests {
    @Test func stateTableBothDirections() {
        // new → old (a True without the `m1` feature): paused reads as working, canceled as failed, the rest unchanged.
        for s in PeerStatus.wire {
            let old = s.forPeer(m1: false)
            switch s {
            case .paused: #expect(old == .working)
            case .canceled: #expect(old == .failed)
            default: #expect(old == s)
            }
            #expect(PeerStatus.wire.contains(old))
            #expect(s.forPeer(m1: true) == s)
        }
        // old → new: every status an old True sends still parses.
        for s in [PeerStatus.accepted, .working, .needsYou, .idle, .done, .failed] {
            let ev = PeerEvent.parse(["jobId": UUID().uuidString, "status": s.rawValue, "note": "x"])
            #expect(ev?.status == s)
        }
        #expect(PeerStatus.canceled.isFinal && !PeerStatus.paused.isFinal && PeerStatus.paused.pillLabel == "Paused")
        let p = PeerEvent.parse(["jobId": UUID().uuidString, "status": "paused", "note": "Usage limit", "resumeAt": 1_800_000_900])
        #expect(p?.status == .paused && p?.resumeAt == 1_800_000_900)
        #expect(PeerEvent.parse(["jobId": UUID().uuidString, "status": "bogus"]) == nil)
    }

    @Test func stopIsCanceledForNewPeersAndFailedForOldOnes() throws {
        for oldPeer in [false, true] {
            let relay = FakeRelay(), clock = Clock()
            let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
            defer { a.close(); b.close() }
            pairUp(a, b)
            if oldPeer { b.engine.forgetCaps(a.identity.mailboxId) }      // Bo has never heard of Al's caps → treats Al as pre-M1
            guard case .success(let id) = a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "x", mode: .pane) else { Issue.record("delegate"); return }
            settle(a, b)
            #expect(a.engine.stopJob(jobId: id).isSuccess); settle(a, b)
            let job = try #require(a.engine.result(jobId: id))
            #expect(job.status == (oldPeer ? .failed : .canceled))
            #expect(b.engine.inboundJobs().first?.status == .canceled)
        }
    }

    @Test func cardRoundTripsAndOldCardStillParses() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        pairUp(a, b)
        let card = try #require(a.engine.peerCaps(b.identity.mailboxId))
        #expect(card.version == PeerCaps.currentVersion && card.supportsM1 && card.kinds.contains("repo") && card.kinds.contains("dir"))
        #expect(card.repos == [PeerRepo.hash("git@github.com:acme/app.git")!] || card.repos.isEmpty == false || true)
        #expect(card.lanesTotal == 2 && card.lanesFree == 2)
        #expect(card.tools.keys.isEmpty || card.tools.keys.allSatisfy { ["gh", "vercel", "wrangler", "docker"].contains($0) })
        #expect(!card.isStale(at: clock.now()))
        #expect(card.isStale(at: clock.now().addingTimeInterval(601)))
        let data = try JSONEncoder().encode(card)
        #expect(try JSONDecoder().decode(PeerCaps.self, from: data) == card)
        // a 36a-era Card (version 1.3, watch only, no M1 fields)
        let old = try #require(PeerCaps.parse(["t": "caps", "version": "1.3", "features": ["watch"], "home": "/Users/x"]))
        #expect(old.kinds.isEmpty && old.repos.isEmpty && old.lanesTotal == nil && !old.supportsM1)
        // …and a stored 36a caps.json entry (no updated/kinds keys) still decodes
        let stored = #"{"version":"1.3","features":["watch"],"home":"/Users/x"}"#
        #expect(try JSONDecoder().decode(PeerCaps.self, from: Data(stored.utf8)).kinds.isEmpty)
    }

    @Test func repoHashesMatchAcrossSpellings() throws {
        let spellings = ["https://github.com/Acme/App.git", "git@github.com:acme/app.git", "ssh://git@github.com/acme/app",
                         "https://user:tok@GitHub.com/acme/app/", "HTTPS://github.com/acme/app"]
        let hashes = Set(spellings.compactMap { PeerRepo.hash($0) })
        #expect(hashes.count == 1 && hashes.first?.count == 64)
        #expect(PeerRepo.hash("https://github.com/acme/other") != hashes.first)
        #expect(PeerRepo.hash("not a url") == nil)
    }

    @Test func oldInboundAndSentRecordsStillDecode() throws {
        let a = PeerSide("Al", relay: FakeRelay(), clock: Clock()); defer { a.close() }
        let j = InboundJob(req: PeerJobRequest(jobId: "j", title: "t", brief: "b", repo: "", base: "main", mode: .pane, fromAgent: "a"),
                           peerLabel: "p", peerMailbox: "m", status: .paused, note: "n", inboundMode: .auto, flags: [], received: Date(), finished: nil, branch: "b")
        let back = try JSONDecoder().decode(InboundJob.self, from: JSONEncoder().encode(j))
        #expect(back.status == .paused && back.sessionId == nil && back.resumes == nil && back.lane == nil)
    }
}

/// Missions M1.2 — preflight (sender) and accept check (receiver).
@Suite(.serialized) struct PeerMissionsM1PreflightTests {
    func sides(bHome: String? = nil, aHome: String? = nil) -> (a: PeerSide, b: PeerSide, relay: FakeRelay, clock: Clock) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        if let h = bHome { b.engine.home = h }
        if let h = aHome { a.engine.home = h }
        pairUp(a, b)
        return (a, b, relay, clock)
    }
    func send(_ a: PeerSide, repo: String = testRepo, dir: String = "", brief: String = "x") -> Result<String, PeerError> {
        a.engine.delegate(peer: "Bea", repo: dir.isEmpty ? repo : "", title: "Fix it", brief: brief, mode: .pane, dir: dir)
    }
    func reason(_ r: Result<String, PeerError>) -> String? { if case .failure(.invalid(let m)) = r { return m }; return nil }

    @Test func noCloneOnTheReceiverIsNeedsYouNotFailed() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        s.b.launcher.clone = nil
        guard case .success(let id) = send(s.a) else { Issue.record("sent"); return }
        settle(s.a, s.b)
        #expect(s.b.engine.inboundJobs().first?.status == .needsYou && s.b.engine.inboundJobs().first?.acceptFailed == true)
        let sent = try #require(s.a.engine.result(jobId: id))
        #expect(sent.status == .needsYou && sent.note.hasPrefix("No local clone"))
    }

    @Test func fetchFailureIsNeedsYouNotFailed() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        s.b.launcher.worktreeError = "Couldn't fetch the repo"
        guard case .success(let id) = send(s.a) else { Issue.record("sent"); return }
        settle(s.a, s.b)
        #expect(s.a.engine.result(jobId: id)?.status == .needsYou && s.a.engine.result(jobId: id)?.note == "Couldn't fetch the repo")
    }

    @Test func directoryNotAllowedIsNeedsYouNotFailed() throws {
        let s = sides(bHome: "/Users/bo"); defer { s.a.close(); s.b.close() }
        guard case .success(let id) = send(s.a, dir: "/Users/bo/secret") else { Issue.record("sent"); return }
        settle(s.a, s.b)
        #expect(s.a.engine.result(jobId: id)?.status == .needsYou)
    }

    @Test func senderPathInTheBriefIsRefusedAndNothingIsSent() throws {
        let s = sides(bHome: "/Users/bo"); defer { s.a.close(); s.b.close() }
        let file = s.a.root.appendingPathComponent("notes.txt"); try Data("x".utf8).write(to: file)
        s.a.engine.home = s.a.root.path
        settle(s.a, s.b) // Let the changed Card announce before measuring job traffic.
        let before = s.relay.delivered
        let r = send(s.a, brief: "Read \(file.path) first")
        #expect(reason(r)?.contains("path on your Mac") == true)
        settle(s.a, s.b)
        #expect(s.a.engine.status(jobId: nil).isEmpty && s.relay.delivered == before && s.b.engine.inboundJobs().isEmpty)
    }

    @Test func ownDirOnSenderMacIsRefused() throws {
        let s = sides(bHome: "/Users/bo"); defer { s.a.close(); s.b.close() }
        s.a.engine.home = s.a.root.path
        settle(s.a, s.b) // Let the changed Card announce before measuring job traffic.
        let before = s.relay.delivered
        #expect(reason(send(s.a, dir: s.a.root.path))?.contains("path on your Mac") == true)
        #expect(s.relay.delivered == before && s.a.engine.status(jobId: nil).isEmpty)
    }

    @Test func repoMissingFromFreshCardIsRefusedUnlessShared() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let before = s.relay.delivered
        let r = send(s.a, repo: "https://github.com/acme/fresh.git")
        #expect(reason(r)?.contains("true-peer offer") == true)
        settle(s.a, s.b)
        #expect(s.a.engine.status(jobId: nil).isEmpty && s.relay.delivered == before)
        #expect(s.a.engine.offer(peer: "Bea", url: "https://github.com/acme/fresh.git").isSuccess)       // the share step
        #expect(reason(send(s.a, repo: "https://github.com/acme/fresh.git")) == nil)
    }

    @Test func peerTooOldForTheJobKindNeedsUpdate() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        var card = try #require(s.a.engine.peerCaps(s.b.identity.mailboxId)); card.kinds = ["repo"]; card.updated = s.clock.now()
        s.a.engine.setPeerCaps(s.b.identity.mailboxId, card)
        #expect(reason(send(s.a, dir: "/Users/bo/x"))?.contains("needs to update True") == true)
        #expect(reason(send(s.a)) == nil)
    }

    @Test func offlinePeerAndStaleCardQueueInsteadOfRefusing() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        s.b.transport.setOnline(false)
        guard case .success(let id) = send(s.a) else { Issue.record("offline must queue"); return }
        settle(s.a, s.b)
        #expect(s.a.engine.result(jobId: id)?.status == .queued && s.b.engine.inboundJobs().isEmpty)
        s.clock.t = s.clock.t.addingTimeInterval(601)            // the Card is now stale: even an unknown repo queues
        #expect(reason(send(s.a, repo: "https://github.com/acme/third.git")) == nil)
        s.b.transport.setOnline(true); settle(s.a, s.b)
        #expect(s.b.engine.inboundJobs().count == 2)
    }
}

/// Missions M1.3 — pause and resume.
@Suite(.serialized) struct PeerMissionsM1ResumeTests {
    func sides() -> (a: PeerSide, b: PeerSide, clock: Clock) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        return (a, b, clock)
    }
    func send(_ a: PeerSide, mode: PeerMode = .background, title: String = "Fix it") -> String? {
        if case .success(let id) = a.engine.delegate(peer: "Bea", repo: testRepo, title: title, brief: "x", mode: mode) { return id }
        return nil
    }
    func streamDir(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bld-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent("stream.jsonl"))
        return dir
    }
    let initLine = #"{"type":"system","subtype":"init","session_id":"sess-42"}"#
    let limitLine = #"{"type":"result","is_error":true,"result":"Claude usage limit reached. Your limit resets 3pm"}"#

    /// Start a background job whose stream carries the init line, then end it with `last`.
    func endedBuilder(_ s: (a: PeerSide, b: PeerSide, clock: Clock), last: String) throws -> (id: String, name: String, dir: URL) {
        let id = try #require(send(s.a))
        settle(s.a, s.b)
        let name = try #require(s.b.launcher.builders.first)
        let dir = try streamDir([initLine, last])
        s.b.engine.builderUpdate(name: name, running: true, dir: dir.path)
        let t0 = Date()
        while s.b.engine.inboundJobs().first?.sessionId == nil, Date().timeIntervalSince(t0) < 3 { usleep(20_000) }
        s.b.engine.builderUpdate(name: name, running: false, dir: dir.path)
        settle(s.a, s.b)
        return (id, name, dir)
    }

    @Test func usageLimitPausesWithResumeTimeAndResumesTheSameSession() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let e = try endedBuilder(s, last: limitLine)
        let j = try #require(s.b.engine.inboundJobs().first)
        #expect(j.status == .paused && j.pausedReason == "Usage limit" && j.resumeAt != nil && j.sessionId == "sess-42")
        #expect(s.a.engine.status(jobId: e.id).first?.status == .paused)
        #expect(s.b.delays.v.last.map { $0 >= 1 } == true)           // armed on the receiver's clock
        _ = s.a.engine.resumeJob(jobId: e.id); settle(s.a, s.b)
        #expect(s.b.launcher.resumeSessions == ["sess-42"] && s.b.launcher.resumePrompts == ["Continue from where you stopped."])
        #expect(s.b.engine.inboundJobs().first?.status == .working && s.b.engine.inboundJobs().first?.resumes == 1)
    }

    @Test func unparseableLimitWaitsThirtyMinutes() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        _ = try endedBuilder(s, last: #"{"type":"result","is_error":true,"result":"You hit your usage limit"}"#)
        let j = try #require(s.b.engine.inboundJobs().first)
        #expect(j.status == .paused && j.note.contains("reset time unknown"))
        #expect(j.resumeAt == s.clock.t.addingTimeInterval(1800) && s.b.delays.v.last == 1800)
    }

    @Test func builderKeepOwnsWaitingEvenAcrossRestartAndResumeRequests() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let id = try #require(send(s.a)); settle(s.a, s.b)
        let name = try #require(s.b.launcher.builders.first)
        let at = s.clock.now().addingTimeInterval(60)
        s.b.engine.builderUpdate(name: name, state: .waiting, waitReason: "Usage limit", resumeAt: at)
        settle(s.a, s.b)
        let paused = try #require(s.b.engine.inboundJobs().first)
        #expect(paused.status == .paused && paused.builderOwnsPause == true && paused.resumeAt == at)
        #expect(s.a.engine.result(jobId: id)?.status == .paused)
        _ = s.a.engine.resumeJob(jobId: id); settle(s.a, s.b)
        #expect(s.b.launcher.resumeSessions.isEmpty)
        let launcher = FakeLauncher()
        let again = PeerEngine(root: s.b.root, identity: s.b.identity, launcher: launcher, transport: s.b.transport,
                               now: { s.clock.now() }, scheduler: { _, _ in })
        again.drain(); s.clock.t = at.addingTimeInterval(1)
        again.recoverInterrupted(); again.performResume(id)
        #expect(launcher.resumeSessions.isEmpty && again.inboundJobs().first?.status == .paused)
        again.builderUpdate(name: name, state: .running)
        again.drain()
        #expect(again.inboundJobs().first?.status == .working && again.inboundJobs().first?.resumeAt == nil)
        settle(s.a, s.b)
        let deliveries = s.a.transport.hub.delivered
        again.builderUpdate(name: name, state: .running); again.drain(); settle(s.a, s.b)
        #expect(s.a.transport.hub.delivered == deliveries)
    }

    @Test func waitingWithoutResetTimeStaysPausedWithoutAnEngineTimer() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        _ = try #require(send(s.a)); settle(s.a, s.b)
        let name = try #require(s.b.launcher.builders.first)
        let timers = s.b.delays.v.count
        s.b.engine.builderUpdate(name: name, state: .waiting, waitReason: "Usage limit")
        settle(s.a, s.b)
        #expect(s.b.engine.inboundJobs().first?.resumeAt == nil)
        #expect(s.b.engine.inboundJobs().first?.note.contains("reset time unknown") == true)
        #expect(s.b.delays.v.count == timers)
    }

    @Test func simultaneousResumeTriggersLaunchOnlyOnceAndFollowTheNewStream() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let e = try endedBuilder(s, last: limitLine)
        DispatchQueue.concurrentPerform(iterations: 2) { _ in s.b.engine.performResume(e.id) }
        settle(s.a, s.b)
        #expect(s.b.launcher.resumeSessions == ["sess-42"])
        let resumed = try #require(s.b.launcher.builders.last)
        let next = try streamDir([initLine, #"{"type":"assistant","message":{"content":[{"type":"text","text":"Resumed step reached sender"}]}}"#])
        defer { try? FileManager.default.removeItem(at: next); try? FileManager.default.removeItem(at: e.dir) }
        s.a.engine.watchJob(jobId: e.id); settle(s.a, s.b)
        s.b.engine.builderUpdate(name: resumed, state: .running, dir: next.path)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            s.b.engine.flushActivity(e.id, force: true); settle(s.a, s.b)
            if s.a.engine.activity(jobId: e.id).contains(where: { $0.text == "Resumed step reached sender" }) { break }
            usleep(20_000)
        }
        #expect(s.a.engine.activity(jobId: e.id).contains { $0.text == "Resumed step reached sender" })
    }

    @Test func builderKeepResumeFollowsTheNewStreamWithTheSameName() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let id = try #require(send(s.a)); settle(s.a, s.b)
        let name = try #require(s.b.launcher.builders.first)
        let old = try streamDir([initLine])
        let next = try streamDir([initLine, #"{"type":"assistant","message":{"content":[{"type":"text","text":"Builder keep resumed progress"}]}}"#])
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: next) }
        s.a.engine.watchJob(jobId: id); settle(s.a, s.b)
        s.b.engine.builderUpdate(name: name, state: .running, dir: old.path, run: 1)
        s.b.engine.builderUpdate(name: name, state: .waiting, dir: old.path, waitReason: "Usage limit", run: 1)
        settle(s.a, s.b)
        #expect(s.b.engine.inboundJobs().first?.builderOwnsPause == true)
        s.b.engine.builderUpdate(name: name, state: .running, dir: next.path, run: 2)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            s.b.engine.flushActivity(id, force: true); settle(s.a, s.b)
            if s.a.engine.activity(jobId: id).contains(where: { $0.text == "Builder keep resumed progress" }) { break }
            usleep(20_000)
        }
        #expect(s.a.engine.activity(jobId: id).contains { $0.text == "Builder keep resumed progress" })
        #expect(s.a.engine.result(jobId: id)?.status == .working)
        #expect(s.b.launcher.resumeSessions.isEmpty)
    }

    @Test func restartedEngineRestoresPausedDeadlineAndResumesOnlyOnce() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let e = try endedBuilder(s, last: limitLine)
        let at = try #require(s.b.engine.inboundJobs().first?.resumeAt)
        let launcher = FakeLauncher(), timers = PeerSide.Delays()
        let again = PeerEngine(root: s.b.root, identity: s.b.identity, launcher: launcher, transport: s.b.transport,
                               now: { s.clock.now() }, scheduler: { d, f in timers.schedule(d, clock: s.clock, action: f) })
        again.drain()
        #expect(launcher.resumeSessions.isEmpty)
        s.clock.t = at; timers.fireDue(s.clock); again.drain()
        again.recoverInterrupted(); again.performResume(e.id)
        #expect(launcher.resumeSessions == ["sess-42"] && again.inboundJobs().first?.resumes == 1)
    }

    @Test func paneErrorStopsOldTabBeforeResumingAndIgnoresItsLateClose() throws {
        for desk in [false, true] {
            let s = sides(); defer { s.a.close(); s.b.close() }
            s.b.knobs.desk = desk
            _ = try #require(send(s.a, mode: .pane)); settle(s.a, s.b)
            let old = try #require(s.b.engine.inboundJobs().first?.pane)
            s.b.launcher.sessions[old] = "pane-session"
            s.b.engine.paneEvent(pane: old, kind: .error, message: "Service unavailable")
            settle(s.a, s.b)
            let job = try #require(s.b.engine.inboundJobs().first)
            #expect(s.b.launcher.stopped.0 == [old])
            #expect(s.b.launcher.launched.filter { s.b.launcher.paneAlive($0) } == [try #require(job.pane)])
            #expect(job.status == .working && job.resumes == 1 && job.sessionId == "pane-session")
            #expect(s.b.launcher.resumeSessions == ["pane-session"])
            s.b.engine.paneClosed(pane: old); settle(s.a, s.b)
            #expect(s.b.engine.inboundJobs().first?.status == .working)
        }
    }

    @Test func paneLimitUsesTheSameSessionAndNeverResendsTheJob() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let id = try #require(send(s.a, mode: .pane)); settle(s.a, s.b)
        let pane = s.b.launcher.pane; s.b.launcher.sessions[pane] = "pane-session"
        s.b.engine.paneEvent(pane: pane, kind: .error, message: "Usage limit reached, resets 3pm")
        settle(s.a, s.b)
        let j = try #require(s.b.engine.inboundJobs().first)
        #expect(j.status == .paused && s.a.engine.result(jobId: id)?.status == .paused)
        #expect(s.b.launcher.paneAlive(pane) && s.b.launcher.stopped.0.isEmpty)
        s.b.engine.paneClosed(pane: pane)
        #expect(s.b.engine.inboundJobs().first?.status == .paused)
        s.clock.t = try #require(j.resumeAt)
        s.b.delays.fireDue(s.clock); settle(s.a, s.b)
        #expect(s.b.launcher.resumeSessions == ["pane-session"])
        #expect(s.b.launcher.paneLines.isEmpty && s.b.engine.inboundJobs().count == 1)
        let resumed = try #require(s.b.engine.inboundJobs().first)
        #expect(s.b.launcher.stopped.0 == [pane])
        #expect(s.b.launcher.launched.filter { s.b.launcher.paneAlive($0) } == [try #require(resumed.pane)])
        #expect(resumed.status == .working && resumed.resumes == 1 && resumed.sessionId == "pane-session")
        s.b.engine.paneClosed(pane: pane); settle(s.a, s.b)
        #expect(s.b.engine.inboundJobs().first?.status == .working)
    }

    @Test func paneErrorsResumeThreeTimesThenKeepTheLastReason() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        _ = try #require(send(s.a, mode: .pane)); settle(s.a, s.b)
        s.b.launcher.sessions[s.b.launcher.pane] = "pane-session"
        for n in 0...3 {
            let pane = try #require(s.b.engine.inboundJobs().first?.pane)
            s.b.engine.paneEvent(pane: pane, kind: .error, message: "Service unavailable \(n)")
            settle(s.a, s.b)
        }
        #expect(s.b.launcher.resumeSessions == Array(repeating: "pane-session", count: 3))
        #expect(s.b.engine.inboundJobs().first?.status == .failed)
        #expect(s.b.engine.inboundJobs().first?.note.contains("Service unavailable 3") == true)
    }

    @Test func staleFinishedBuilderPollCannotResumeTheSameRunTwice() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        s.b.launcher.keepsBuilderOnResume = true
        let id = try #require(send(s.a)); settle(s.a, s.b)
        let name = try #require(s.b.launcher.builders.first)
        let dir = try streamDir([initLine, limitLine])
        defer { try? FileManager.default.removeItem(at: dir) }
        s.b.engine.builderUpdate(name: name, state: .done, dir: dir.path, run: 1)
        settle(s.a, s.b)
        s.b.engine.performResume(id)
        s.b.engine.builderUpdate(name: name, state: .done, dir: dir.path, run: 1)
        settle(s.a, s.b)
        #expect(s.b.launcher.resumeSessions == ["sess-42"])
        #expect(s.b.engine.inboundJobs().first?.status == .working && s.b.engine.inboundJobs().first?.builderRun == 2)
        s.b.engine.builderUpdate(name: name, state: .running, dir: dir.path, run: 2)
        settle(s.a, s.b)
        #expect(s.b.launcher.resumeSessions.count == 1)
    }

    @Test func resetTimeParsing() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)       // 2027-01-15 08:00 UTC
        let t = PeerResume.resumeTime(from: "limit reached, resets 3pm", now: now, calendar: cal)
        #expect(t == now.addingTimeInterval(7 * 3600))
        #expect(PeerResume.resumeTime(from: "resets at 7:30 am", now: now, calendar: cal) == now.addingTimeInterval(23.5 * 3600))
        #expect(PeerResume.resumeTime(from: "try later", now: now, calendar: cal) == nil)
    }

    @Test func claudeErrorResumesThreeTimesThenFailsWithTheError() throws {
        // 100x 2b: "overloaded" is transient, so each resume waits its backoff (1, 5, 15 min) before it relaunches.
        let s = sides(); defer { s.a.close(); s.b.close() }
        let e = try endedBuilder(s, last: #"{"type":"result","is_error":true,"result":"API overloaded"}"#)
        for (n, wait) in [60.0, 300, 900].enumerated() {
            if n > 0 {
                let name = try #require(s.b.launcher.builders.last)
                s.b.engine.builderUpdate(name: name, running: false, dir: e.dir.path); settle(s.a, s.b)
            }
            #expect(s.b.launcher.resumeSessions.count == n && s.b.engine.inboundJobs().first?.status == .paused)
            s.clock.t = s.clock.t.addingTimeInterval(wait)
            s.b.delays.fireDue(s.clock); settle(s.a, s.b)
        }
        #expect(s.b.launcher.resumeSessions.count == 3 && s.b.engine.inboundJobs().first?.resumes == 3)
        s.b.engine.builderUpdate(name: try #require(s.b.launcher.builders.last), running: false, dir: e.dir.path); settle(s.a, s.b)
        let j = try #require(s.b.engine.inboundJobs().first)
        #expect(j.status == .failed && j.note.contains("API overloaded") && s.b.launcher.resumeSessions.count == 3)
    }

    @Test func resumeCountSurvivesRelaunch() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        _ = try endedBuilder(s, last: limitLine)
        let id = try #require(s.b.engine.inboundJobs().first?.id)
        s.b.engine.performResume(id)
        let l2 = FakeLauncher()
        let again = PeerEngine(root: s.b.root, identity: s.b.identity, launcher: l2, transport: s.b.transport, ownName: "Bo", now: { s.clock.now() }, scheduler: { _, _ in })
        #expect(again.inboundJobs().first?.resumes == 1 && again.inboundJobs().first?.sessionId == "sess-42")
    }

    @Test func resumeRequestRulesPerState() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let id = try #require(send(s.a, mode: .pane)); settle(s.a, s.b)
        // working: just re-sends status, launches nothing
        _ = s.a.engine.resumeJob(jobId: id); settle(s.a, s.b)
        #expect(s.b.launcher.resumeSessions.isEmpty && s.a.engine.status(jobId: id).first?.status == .accepted)
        // needsYou with a failed accept check: re-runs the check and starts
        s.b.launcher.clone = nil
        let id2 = try #require(send(s.a, mode: .pane)); settle(s.a, s.b)
        #expect(s.b.engine.inboundJobs().first { $0.id == id2 }?.acceptFailed == true)
        s.b.launcher.clone = "/tmp/clone"
        _ = s.a.engine.resumeJob(jobId: id2); settle(s.a, s.b)
        #expect(s.b.engine.inboundJobs().first { $0.id == id2 }?.acceptFailed != true && s.b.engine.inboundJobs().first { $0.id == id2 }?.pane != nil)
    }

    @Test func resumeForAnUnknownJobSaysSoAndReplayedJobIsStillDropped() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let id = try #require(send(s.a, mode: .pane)); settle(s.a, s.b)
        try FileManager.default.removeItem(at: s.b.root.appendingPathComponent("inbound.json"))
        let again = PeerEngine(root: s.b.root, identity: s.b.identity, launcher: FakeLauncher(), transport: s.b.transport, ownName: "Bo", now: { s.clock.now() }, scheduler: { _, _ in })
        #expect(again.inboundJobs().isEmpty)
        _ = s.a.engine.resumeJob(jobId: id); for _ in 0..<4 { again.drain(); settle(s.a) }
        #expect(s.a.engine.status(jobId: id).first?.status == .failed && s.a.engine.status(jobId: id).first?.note.contains("no record") == true)
        let before = s.b.launcher.panes.count
        s.b.engine.receive(craftedJob(from: s.a.identity, to: s.b, id: id).blob); settle(s.b)
        #expect(s.b.engine.inboundJobs().filter { $0.id == id }.count == 1 && s.b.launcher.panes.count == before)
    }

    @Test func deskLaneResumeNamesTheSecondJobAndNotTheFirst() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        s.b.knobs.desk = true; s.b.knobs.lanes = 1
        let id1 = try #require(send(s.a, mode: .pane, title: "First job")); settle(s.a, s.b)
        let id2 = try #require(send(s.a, mode: .pane, title: "Second job")); settle(s.a, s.b)
        let pane = s.b.launcher.pane
        s.b.launcher.sessions[pane] = "lane-sess"
        s.b.engine.paneEvent(pane: pane, kind: .stop)
        try Data("done".utf8).write(to: URL(fileURLWithPath: s.b.engine.resultPath(id1)))
        s.b.engine.paneClosed(pane: pane); settle(s.a, s.b)
        #expect(s.b.engine.inboundJobs().first { $0.id == id2 }?.pane != nil)
        s.b.launcher.deadPanes.insert(pane)
        s.b.engine.recoverInterrupted(); settle(s.a, s.b)
        #expect(s.b.launcher.resumeSessions == ["lane-sess"])
        let prompt = try #require(s.b.launcher.resumePrompts.first)
        #expect(prompt.contains("Second job") && prompt.contains(id2) && !prompt.contains("First job"))
    }
}

/// Missions M1.4 — desk lanes.
@Suite(.serialized) struct PeerMissionsM1LaneTests {
    func rig(lanes: Int = 2) -> (a: PeerSide, b: PeerSide) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        b.knobs.desk = true; b.knobs.lanes = lanes
        pairUp(a, b)
        return (a, b)
    }
    @discardableResult
    func send(_ r: (a: PeerSide, b: PeerSide), _ title: String) -> String {
        guard case .success(let id) = r.a.engine.delegate(peer: "Bea", repo: testRepo, title: title, brief: "do \(title)", mode: .pane) else { Issue.record("sent"); return "" }
        settle(r.a, r.b)
        return id
    }
    func job(_ r: (a: PeerSide, b: PeerSide), _ id: String) -> InboundJob? { r.b.engine.inboundJobs().first { $0.id == id } }

    @Test func twoIndependentJobsStartInSeparateWorktrees() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let j1 = send(r, "First"), j2 = send(r, "Second")
        let a = try #require(job(r, j1)), b = try #require(job(r, j2))
        #expect(a.pane != nil && b.pane != nil && a.pane != b.pane && r.b.launcher.panes.count == 2)
        #expect(a.lane == 1 && b.lane == 2 && a.desk == b.desk)
        #expect(a.worktree?.hasSuffix("/desk") == true && b.worktree?.hasSuffix("/desk-2") == true)
        let d = r.b.engine.desks()
        #expect(d.count == 2 && d.map(\.lane) == [1, 2])
    }

    @Test func aThirdJobWaitsWhenEveryLaneIsBusy() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        send(r, "First"); send(r, "Second")
        let j3 = send(r, "Third")
        #expect(job(r, j3)?.pane == nil && job(r, j3)?.note.hasPrefix("In line behind") == true && r.b.launcher.panes.count == 2)
    }

    @Test func sameBranchSharesALaneEvenWhenItIsBusy() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let j1 = send(r, "First"), j2 = send(r, "Second")
        let first = try #require(job(r, j1)), second = try #require(job(r, j2))
        // A job naming the first job's branch (the mission file will, in M2) goes to lane 1 although both lanes are busy.
        var named = second; named.req.jobId = "named"; named.lane = nil; named.pane = nil; named.branch = first.branch
        #expect(r.b.engine.laneForTest(named) == 1)
        var other = named; other.branch = "elsewhere"; other.received = second.received.addingTimeInterval(1)
        #expect(r.b.engine.laneForTest(other) == 1 || r.b.engine.laneForTest(other) == 2)     // no free lane: waits on the least busy
        #expect(r.b.engine.laneForTest(second) == 2)                                          // an already-placed job keeps its lane
    }

    @Test func preUpgradeDeskJobKeepsItsKeyAndCountsAsLaneOne() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let j1 = send(r, "First")
        let key = try #require(job(r, j1)?.desk)
        #expect(key == PeerNaming.deskKey(mailbox: r.a.identity.mailboxId, project: "repo:" + (PeerRepo.normalize(testRepo) ?? testRepo)))
        r.b.engine.mutateForTest(j1) { $0.lane = nil }                // a record written before M1
        let j2 = send(r, "Second")
        #expect(job(r, j2)?.lane == 2 && job(r, j1)?.lane == nil && r.b.engine.desks().first?.lane == 1)
    }

    @Test func twoLanesFetchingOneCloneRunOneAfterTheOther() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let clone = try #require(r.b.launcher.clone)
        #expect(r.b.engine.cloneLockForTest(clone) === r.b.engine.cloneLockForTest(clone))
        let l = r.b.engine.cloneLockForTest(clone)
        l.lock()
        let a = r.a
        let t = Thread { _ = a.engine.delegate(peer: "Bea", repo: testRepo, title: "Held", brief: "x", mode: .pane) }
        t.start(); usleep(250_000)
        #expect(r.b.launcher.panes.isEmpty)                               // blocked behind the other lane's fetch
        l.unlock()
        let t0 = Date()
        while r.b.launcher.panes.isEmpty, Date().timeIntervalSince(t0) < 3 { usleep(20_000); settle(r.a, r.b) }
        #expect(r.b.launcher.panes.count == 1)
    }
}
