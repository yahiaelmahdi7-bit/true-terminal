import Foundation
import Testing
@testable import True

@Suite(.serialized) struct MissionsTests {
    static let repo = "https://github.com/example/ledger-app"
    static let example = """
    # Mission: LEDGER data plane + CRM
    into: mission/ledger-dp
    check: npm test

    ## Wave 1a: period locks
    repo: \(repo)
    where: auto
    The job's prompt, any length.

    ## Wave 1b: original store
    repo: \(repo)
    where: alex

    ## CRM U0: craft pass
    repo: \(repo)
    needs: Wave 1a, Wave 1b
    tool: vercel
    """

    final class Launcher: MissionJobLauncher {
        var starts: [MissionLaunch] = []
        var statuses: [String: MissionJobStatus] = [:]
        var stops: [String] = []
        var stopFailure = false
        var stopFailures = Set<String>()
        func start(_ launch: MissionLaunch, at destination: MissionDestination) throws {
            #expect(statuses[launch.key] == nil)
            starts.append(launch); statuses[launch.key] = MissionJobStatus(state: .running)
        }
        func status(key: String, at destination: MissionDestination) -> MissionJobStatus? { statuses[key] }
        func stop(key: String, at destination: MissionDestination) throws {
            if stopFailure || stopFailures.contains(key) { throw PeerError.invalid("Stop failed") }
            stops.append(key); statuses[key] = MissionJobStatus(state: .canceled)
        }
        func finish(_ title: String, as state: MissionJobState = .completed) {
            statuses[starts.last { $0.job.title == title }!.key] = MissionJobStatus(state: state, reason: state == .failed ? "Job failed" : "")
        }
    }
    final class Gate: MissionMergeGate {
        var merges: [String] = []
        var refuse = Set<String>()
        var failures = Set<String>()
        var checks: [String?] = []
        func merge(_ launch: MissionLaunch, at destination: MissionDestination, check: String?) throws -> MissionMergeAnswer {
            checks.append(check)
            if failures.contains(launch.job.title) { throw PeerError.invalid("Merge unavailable") }
            if refuse.contains(launch.job.title) { return .inputRequired("Check failed") }
            merges.append(launch.job.title); return .merged
        }
    }
    final class Schedule {
        var callbacks: [() -> Void] = []
        func enqueue(_ delay: TimeInterval, _ callback: @escaping () -> Void) { callbacks.append(callback) }
    }
    struct World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let launcher = Launcher(), gate = Gate(), scheduler = Schedule()
        func open(source: String? = MissionsTests.example) throws -> MissionRunner {
            try MissionRunner(id: "ledger", root: root, source: source, peers: ["alex"], launcher: launcher, gate: gate,
                              now: { Date(timeIntervalSince1970: 100) }, scheduler: scheduler.enqueue,
                              route: { job, _ in job.whereTo == "alex" ? .peer("alex") : .mine })
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func parsesPublishedLEDGER() throws {
        let file = try MissionFile.parse(Self.example, peers: ["alex"])
        #expect(file.name == "LEDGER data plane + CRM")
        #expect(file.into == "mission/ledger-dp" && file.check == "npm test")
        #expect(file.jobs.count == 3)
        #expect(file.jobs[0].brief.contains("The job's prompt"))
        #expect(file.jobs[2].needs == [file.jobs[0].title, file.jobs[1].title])
        #expect(file.jobs[2].tool == "vercel")
        let markdown = "# Mission: Code\n## Job\nrepo: \(Self.repo)\nreview: cross\ncheck: local check\n```\nrepo: code sample\n## Not a job\n```\nMore text"
        let code = try MissionFile.parse(markdown, peers: [])
        #expect(code.jobs.count == 1 && code.jobs[0].review == "cross")
        #expect(code.jobs[0].brief.contains("repo: code sample"))
    }

    @Test func validationNamesEachFileLine() throws {
        let cases: [(String, Int)] = [
            ("# Mission: M\n## A\nrepo: x\n## A\nrepo: x", 4),
            ("# Mission: M\n## A\nrepo: x\nneeds: Missing", 4),
            ("# Mission: M\n## A\nrepo: x\nneeds: A", 4),
            ("# Mission: M\n## A\nrepo: x\nneeds: B\n## B\nrepo: x\nneeds: A", 7),
            ("# Mission: M\n## A\nrepo: x\nwhere: stranger", 4),
            ("# Mission: M\n## A\nA brief", 2),
            ("# Mission: M\n## A\nrepo:", 3)
        ]
        for (text, line) in cases {
            do { _ = try MissionFile.parse(text, peers: []); Issue.record("Accepted invalid mission") }
            catch let error as MissionValidationError {
                #expect(error.line == line)
                #expect(error.description.hasPrefix("Line \(line): "))
                #expect(!error.description.contains("\n"))
            }
        }
        let world = World(); defer { world.clean() }
        #expect(throws: MissionValidationError.self) { try world.open(source: "# Mission: Invalid\n## Job") }
        #expect(!FileManager.default.fileExists(atPath: world.root.path))
    }

    @Test func routerRuleTable() throws {
        let now = Date(timeIntervalSince1970: 2000)
        var card = PeerCaps(version: "1.4", features: ["m1"], home: "")
        card.updated = now; card.repos = [PeerRepo.hash(Self.repo)!]; card.tools = ["vercel": true]
        card.lanesFree = 0
        var job = try MissionFile.parse(Self.example, peers: ["alex"]).jobs[2]
        #expect(MissionRouter.route(job, peers: [MissionPeer(label: "alex", card: card)], localRepos: [Self.repo], now: now) == .peer("alex"))
        for mode in 0..<4 {
            var changed = card
            if mode == 0 { changed.updated = now.addingTimeInterval(-601) }
            if mode == 1 { changed.repos = [] }
            if mode == 2 { changed.tools = [:] }
            let peer = MissionPeer(label: "alex", card: mode == 3 ? nil : changed)
            #expect(MissionRouter.route(job, peers: [peer], localRepos: [Self.repo + ".git"], now: now) == .mine)
            if case .waiting(let reason) = MissionRouter.route(job, peers: [peer], localRepos: [], now: now) { #expect(!reason.isEmpty) }
            else { Issue.record("Missing repo should wait") }
        }
        job.whereTo = "mine"
        #expect(MissionRouter.route(job, peers: [MissionPeer(label: "alex", card: card)], localRepos: [Self.repo], now: now) == .mine)
        job.whereTo = "alex"
        #expect(MissionRouter.route(job, peers: [MissionPeer(label: "alex", card: nil)], localRepos: [], now: now) == .peer("alex"))
    }

    @Test func runsInMergedNeedsOrderAndKeepsFileImmutable() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open(); defer { runner.close() }
        try runner.reconcile()
        #expect(w.launcher.starts.map(\.job.title) == ["Wave 1a: period locks", "Wave 1b: original store"])
        w.gate.refuse.insert("Wave 1a: period locks")
        w.launcher.finish("Wave 1a: period locks"); w.launcher.finish("Wave 1b: original store")
        try runner.reconcile()
        #expect(runner.state == .needsYou && w.launcher.starts.count == 2)
        #expect(runner.jobs["CRM U0: craft pass"]?.state == .blocked)
        w.gate.refuse.removeAll()
        try runner.retryJob("Wave 1a: period locks")
        #expect(w.launcher.starts.count == 3)
        #expect(w.launcher.starts.last?.base == "mission/ledger-dp")
        w.launcher.finish("CRM U0: craft pass"); try runner.reconcile()
        #expect(runner.state == .done)
        #expect(w.gate.checks.allSatisfy { $0 == "npm test" })
        #expect(try String(contentsOf: runner.folder.appendingPathComponent("mission.md"), encoding: .utf8) == Self.example)
        #expect(throws: (any Error).self) { try w.open() }
    }

    @Test func failedJobBlocksOnlyItsDependentsThenSkipReleasesThem() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open(); defer { runner.close() }
        try runner.reconcile()
        w.launcher.finish("Wave 1a: period locks", as: .failed)
        try runner.reconcile()
        #expect(runner.state == .needsYou)
        #expect(runner.jobs["Wave 1b: original store"]?.state == .running)
        w.launcher.finish("Wave 1b: original store"); try runner.reconcile()
        #expect(runner.jobs["Wave 1b: original store"]?.state == .merged)
        #expect(w.launcher.starts.count == 2)
        try runner.skipJob("Wave 1a: period locks")
        #expect(w.launcher.starts.count == 3 && runner.state == .running)
    }

    @Test func retryFailedJobIsAnExplicitNewAttempt() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open(); defer { runner.close() }
        try runner.reconcile()
        w.launcher.finish("Wave 1a: period locks", as: .declined); try runner.reconcile()
        try runner.retryJob("Wave 1a: period locks")
        #expect(w.launcher.starts.count == 3)
        #expect(Set(w.launcher.starts.map(\.key)).count == 3)
        #expect(runner.jobs["Wave 1a: period locks"]?.attempt == 1)
    }

    @Test func mergeErrorBlocksOnlyDependentsAndCanBeRetriedAfterReopen() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open()
        try runner.reconcile()
        let first = "Wave 1a: period locks", second = "Wave 1b: original store"
        w.gate.failures.insert(first)
        w.launcher.finish(first); w.launcher.finish(second)
        try runner.reconcile()
        #expect(runner.state == .needsYou)
        #expect(runner.jobs[first]?.state == .needsYou)
        #expect(runner.jobs[first]?.reason == "Couldn't merge the job")
        #expect(runner.jobs[second]?.state == .merged)
        #expect(runner.jobs["CRM U0: craft pass"]?.state == .blocked)
        runner.close()
        w.gate.failures.removeAll()
        let reopened = try w.open(source: nil); defer { reopened.close() }
        try reopened.retryJob(first)
        #expect(w.launcher.starts.count == 3)
        #expect(w.launcher.starts.filter { $0.job.title == first }.count == 1)
        w.launcher.finish("CRM U0: craft pass"); try reopened.reconcile()
        #expect(reopened.state == .done)
    }

    @Test func cancelAttemptsOtherStopsWhenOneJobCannotStop() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open(); try runner.reconcile()
        let firstKey = w.launcher.starts[0].key
        w.launcher.stopFailures.insert(firstKey)
        #expect(throws: (any Error).self) { try runner.cancel() }
        #expect(runner.state == .canceled)
        #expect(w.launcher.stops == [w.launcher.starts[1].key])
        #expect(runner.jobs["CRM U0: craft pass"]?.state == .canceled)
        runner.close()
        w.launcher.stopFailures.removeAll()
        let reopened = try w.open(source: nil); defer { reopened.close() }
        try reopened.reconcile()
        #expect(reopened.jobs.values.allSatisfy { $0.state == .canceled })
        #expect(w.launcher.stops.count == 2)
        #expect(w.launcher.starts.count == 2)
    }

    @Test func crashRelaunchReconcilesWithoutDoubleStarts() throws {
        let w = World(); defer { w.clean() }
        var runner: MissionRunner? = try w.open()
        try runner!.reconcile()
        #expect(throws: MissionValidationError.self) { try w.open(source: nil) }
        runner!.close(); runner = nil
        w.launcher.finish("Wave 1a: period locks"); w.launcher.finish("Wave 1b: original store")
        let reopened = try w.open(source: nil); defer { reopened.close() }
        try reopened.reconcile(); try reopened.reconcile()
        #expect(w.launcher.starts.count == 3)
        for callback in w.scheduler.callbacks { callback() }
        #expect(w.launcher.starts.count == 3)
        w.launcher.finish("CRM U0: craft pass"); try reopened.reconcile()
        #expect(reopened.state == .done)
    }

    @Test func recoveryOfLaunchIntentAndPartialLastAppend() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open(); try runner.reconcile()
        let events = runner.folder.appendingPathComponent("events.jsonl")
        runner.close()
        // Simulate a crash after the first start, before its running event was committed.
        let lines = try Data(contentsOf: events).split(separator: 10)
        var data = Data()
        for line in lines.prefix(2) { data.append(contentsOf: line); data.append(10) }
        data.append(contentsOf: "{partial".utf8)
        try data.write(to: events)
        let reopened = try w.open(source: nil); defer { reopened.close() }
        try reopened.reconcile()
        // Existing platform records also protect an intent whose later event was lost.
        #expect(w.launcher.starts.count == 2)
        #expect(w.launcher.starts.filter { $0.job.title == "Wave 1a: period locks" }.count == 1)
    }

    @Test func cancelStopsEveryUnfinishedJobAndSurvivesInterruptedStop() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open(); try runner.reconcile()
        w.launcher.stopFailure = true
        #expect(throws: (any Error).self) { try runner.cancel() }
        runner.close(); w.launcher.stopFailure = false
        let reopened = try w.open(source: nil); defer { reopened.close() }
        try reopened.reconcile()
        #expect(reopened.state == .canceled)
        #expect(reopened.jobs.values.allSatisfy { $0.state == .canceled })
        #expect(w.launcher.stops.count == 2)
        try reopened.reconcile()
        #expect(w.launcher.starts.count == 2 && w.launcher.stops.count == 2)
    }
    @Test func jobInputCanResolveWithoutResendingAndMissingCheckStaysNil() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open(source: "# Mission: M\n## Job\nrepo: \(Self.repo)\ncheck: untrusted job check")
        defer { runner.close() }
        try runner.reconcile()
        w.launcher.finish("Job", as: .needsYou); try runner.reconcile()
        #expect(runner.state == .needsYou)
        w.launcher.finish("Job"); try runner.reconcile()
        #expect(runner.state == .done && w.launcher.starts.count == 1)
        #expect(w.gate.checks.count == 1 && w.gate.checks[0] == nil)
    }

    @Test func missingLaunchRecordWaitsForHelpWithoutStartingAgain() throws {
        let w = World(); defer { w.clean() }
        let runner = try w.open(); try runner.reconcile(); runner.close()
        w.launcher.statuses.removeAll()
        let reopened = try w.open(source: nil); defer { reopened.close() }
        try reopened.reconcile(); try reopened.retryJob("Wave 1a: period locks")
        #expect(reopened.state == .needsYou && w.launcher.starts.count == 2)
    }

    @Test func remoteAdapterUsesM1SendResumeAndStopWithStableIdentity() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        pairUp(a, b)
        let job = MissionJob(title: "Mission work", line: 2, repo: testRepo, brief: "Do the work")
        let launch = MissionLaunch(key: "mission-test-job", job: job, base: "mission/test", branch: "peer/test/job")
        let adapter = MissionPeerLauncher(engine: a.engine)
        try adapter.start(launch, at: .peer("Bea")); settle(a, b)
        try adapter.start(launch, at: .peer("Bea")); settle(a, b)
        #expect(a.engine.sentJobs().count == 1 && b.engine.inboundJobs().count == 1)
        #expect(a.engine.sentJobs()[0].base == "mission/test")
        #expect(b.engine.inboundJobs()[0].req.brief.contains("peer/test/job"))
        try adapter.resume(launch, at: .peer("Bea")); settle(a, b)
        #expect(a.engine.sentJobs().count == 1)
        try adapter.stop(key: launch.key, at: .peer("Bea")); settle(a, b)
        #expect(adapter.status(key: launch.key, at: .peer("Bea"))?.state == .canceled)
    }

    @Test func localAdapterReusesBackgroundLaunchAndBuilderRecords() throws {
        let platform = FakeLauncher()
        var records: [BuilderRecord] = []
        let adapter = MissionLocalLauncher(platform: platform, records: { records })
        let job = MissionJob(title: "Local work", line: 2, repo: testRepo, brief: "Do the work")
        let launch = MissionLaunch(key: "mission-local-job", job: job, base: "mission/test", branch: "peer/test/local")
        try adapter.start(launch, at: .mine)
        #expect(platform.builders == [launch.key])
        let data = try JSONSerialization.data(withJSONObject: ["id": "record", "name": launch.key, "started": 100,
                                                               "status": "waiting", "session_id": "same-session"])
        records = [try #require(BuilderRecord.parse(data))]
        try adapter.start(launch, at: .mine)
        #expect(platform.builders.count == 1)
        #expect(adapter.status(key: launch.key, at: .mine)?.state == .running)
        records[0].state = .paused
        try adapter.resume(launch, at: .mine)
        #expect(platform.resumeSessions == ["same-session"])
        records[0].state = .done
        #expect(adapter.status(key: launch.key, at: .mine)?.state == .completed)
        try adapter.stop(key: launch.key, at: .mine)
        #expect(platform.stopped.1 == [launch.key])
    }

}
