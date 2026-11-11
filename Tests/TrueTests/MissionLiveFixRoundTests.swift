import Foundation
import Testing
@testable import True

/// U3b: the fix round on the LIVE launchers (not the drill's fake launcher). Covers the four live-path gaps:
/// old progress JSON still decodes, the local resume prompt carries the note, the peer fix round re-opens a done
/// job's session with the note, and a completed status whose branch head is unchanged never re-runs the gate.

@Suite(.serialized) struct MissionLiveFixRoundTests {
    // MARK: 1 — old state loads

    @Test func oldProgressJSONWithoutNewKeysDecodesWithDefaults() throws {
        // A state file written before attempt/launchKey/mergeBlocked/fixRounds/head/failedHead existed.
        let old = #"{"state":"waiting","reason":"","destination":{"mine":{}}}"#
        let p = try JSONDecoder().decode(MissionJobProgress.self, from: Data(old.utf8))
        #expect(p.state == .waiting && p.reason == "" && p.destination == .mine)
        #expect(p.attempt == 0 && p.launchKey == nil && p.mergeBlocked == false && p.fixRounds == 0)
        #expect(p.head == nil && p.failedHead == nil)

        let running = try JSONDecoder().decode(MissionJobProgress.self, from: Data(#"{"state":"running"}"#.utf8))
        #expect(running.state == .running && running.destination == nil && running.fixRounds == 0)
    }

    // MARK: 2 — local resume prompt carries the note

    @Test func localFixResumePromptCarriesTheNote() throws {
        let platform = FakeLauncher()
        var records: [BuilderRecord] = []
        let adapter = MissionLocalLauncher(platform: platform, records: { records })
        var launch = MissionLaunch(key: "mission-local-job", job: MissionJob(title: "Local work", line: 2, repo: testRepo, brief: "Do the work"),
                                   base: "mission/test", branch: "peer/test/local")
        launch.note = "tests failed: expected 3, got 2"
        let data = try JSONSerialization.data(withJSONObject: ["id": "record", "name": launch.key, "started": 100,
                                                               "status": "waiting", "session_id": "same-session"])
        records = [try #require(BuilderRecord.parse(data))]
        try adapter.resume(launch, at: .mine)
        let prompt = try #require(platform.resumePrompts.first)
        #expect(prompt.contains("merge check failed"))
        #expect(prompt.contains("tests failed: expected 3, got 2"))
        #expect(prompt.contains(launch.branch))
        #expect(platform.resumeSessions == ["same-session"])
    }

    @Test func localResumeWithoutNoteKeepsTodayPrompt() throws {
        let platform = FakeLauncher()
        var records: [BuilderRecord] = []
        let adapter = MissionLocalLauncher(platform: platform, records: { records })
        let launch = MissionLaunch(key: "mission-local-job", job: MissionJob(title: "Local work", line: 2, repo: testRepo, brief: "Do the work"),
                                   base: "mission/test", branch: "peer/test/local")
        let data = try JSONSerialization.data(withJSONObject: ["id": "record", "name": launch.key, "started": 100,
                                                               "status": "waiting", "session_id": "same-session"])
        records = [try #require(BuilderRecord.parse(data))]
        try adapter.resume(launch, at: .mine)
        #expect(platform.resumePrompts == ["Continue from where you stopped."])
        #expect(platform.resumeSessions == ["same-session"])
    }

    // MARK: 3 — peer fix round re-opens a done job's session with the note

    @Test func peerFixResumeOnDoneJobCarriesTheNote() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        pairUp(a, b)
        guard case .success(let id) = a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "do the thing", mode: .pane, fromAgent: "lead-1") else {
            Issue.record("delegate failed"); return
        }
        settle(a, b)
        let pane = b.launcher.pane
        b.launcher.sessions[pane] = "fix-session"
        try Data("done".utf8).write(to: URL(fileURLWithPath: b.engine.resultPath(id)))
        b.engine.paneEvent(pane: pane, kind: .stop); settle(a, b)
        #expect(a.engine.result(jobId: id)?.status == .done)
        // A finished job still refuses a plain resume, but accepts a note-carrying one (fix round).
        if case .success = a.engine.resumeJob(jobId: id) { Issue.record("a plain resume must refuse a done job") }
        guard case .success = a.engine.resumeJob(jobId: id, note: "check failed: tests red") else {
            Issue.record("a note-carrying resume must be accepted on a done job"); return
        }
        settle(a, b)
        #expect(b.launcher.resumeSessions == ["fix-session"])
        let prompt = try #require(b.launcher.resumePrompts.first)
        #expect(prompt.contains("merge check failed"))
        #expect(prompt.contains("check failed: tests red"))
        #expect(b.engine.inboundJobs().first?.status == .working)
    }

    // MARK: 4 — no stale re-merge

    final class Launcher: MissionJobLauncher {
        var starts: [MissionLaunch] = []
        var resumes: [MissionLaunch] = []
        var statuses: [String: MissionJobStatus] = [:]
        func start(_ launch: MissionLaunch, at destination: MissionDestination) throws {
            starts.append(launch); statuses[launch.key] = MissionJobStatus(state: .running)
        }
        func status(key: String, at destination: MissionDestination) -> MissionJobStatus? { statuses[key] }
        func stop(key: String, at destination: MissionDestination) throws { statuses[key] = MissionJobStatus(state: .canceled) }
        func resume(_ launch: MissionLaunch, at destination: MissionDestination) throws { resumes.append(launch) }
    }
    final class Gate: MissionMergeGate {
        var merges: [String] = []
        var answer: MissionMergeAnswer = .merged
        func merge(_ launch: MissionLaunch, at destination: MissionDestination, check: String?) throws -> MissionMergeAnswer {
            merges.append(launch.job.title); return answer
        }
    }
    final class Schedule {
        var callbacks: [() -> Void] = []
        func enqueue(_ delay: TimeInterval, _ callback: @escaping () -> Void) { callbacks.append(callback) }
    }
    struct World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let launcher = Launcher(), gate = Gate(), scheduler = Schedule()
        static let mission = """
        # Mission: Fix
        check: npm test

        ## A
        repo: repo
        where: mine
        Do the work.
        """
        func open() throws -> MissionRunner {
            try MissionRunner(id: "fix", root: root, source: Self.mission, peers: [], launcher: launcher, gate: gate,
                              now: { Date(timeIntervalSince1970: 100) }, scheduler: scheduler.enqueue,
                              route: { _, _ in .mine })
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func unchangedHeadAfterFixRoundDoesNotRerunTheGate() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open(); defer { runner.close() }
        try runner.reconcile()
        let key = try #require(runner.jobs["A"]?.launchKey)
        #expect(w.launcher.starts.count == 1)
        w.gate.answer = .fix("check output tail")
        w.launcher.statuses[key] = MissionJobStatus(state: .completed, head: "aaa1111")
        try runner.reconcile()
        #expect(w.gate.merges == ["A"])
        #expect(runner.jobs["A"]?.fixRounds == 1)
        #expect(runner.jobs["A"]?.failedHead == "aaa1111")
        #expect(w.launcher.resumes.last?.note == "check output tail")
        // The worker hasn't restarted: the same red head is still there. No gate call, no round.
        try runner.reconcile()
        #expect(w.gate.merges.count == 1)
        #expect(runner.jobs["A"]?.fixRounds == 1)
        #expect(runner.jobs["A"]?.state == .running)
        // A new head goes to the gate (and, once it passes, merges).
        w.gate.answer = .merged
        w.launcher.statuses[key] = MissionJobStatus(state: .completed, head: "bbb2222")
        try runner.reconcile()
        #expect(w.gate.merges.count == 2)
        #expect(runner.jobs["A"]?.state == .merged)
        #expect(runner.state == .done)
    }
}
