import Foundation
import Testing
@testable import True

@Suite(.serialized) struct TaskMissionRecoveryTests {
    final class Launcher: MissionJobLauncher {
        var starts = 0, resumes = 0
        var startedKeys = Set<String>()
        var statusValue = MissionJobStatus(state: .running)
        func start(_ launch: MissionLaunch, at destination: MissionDestination) throws { if startedKeys.insert(launch.key).inserted { starts += 1 } }
        func status(key: String, at destination: MissionDestination) -> MissionJobStatus? { startedKeys.contains(key) ? statusValue : nil }
        func stop(key: String, at destination: MissionDestination) throws {}
        func resume(_ launch: MissionLaunch, at destination: MissionDestination) throws { resumes += 1; statusValue = MissionJobStatus(state: .running) }
    }
    final class Gate: MissionMergeGate {
        var applied = Set<String>(), effects = 0
        var interrupt = false
        func merge(_ launch: MissionLaunch, at destination: MissionDestination, check: String?) throws -> MissionMergeAnswer {
            if applied.insert(launch.key).inserted { effects += 1 }
            if interrupt { throw CocoaError(.fileWriteUnknown) }
            return .merged
        }
    }
    let source = "# Mission: Example\ninto: mission/example\ncheck: swift test\n## Job\nrepo: https://github.com/example/repo\nDo the work"
    func open(_ root: URL, source: String?, launcher: Launcher, gate: Gate, now: Date) throws -> MissionRunner {
        try MissionRunner(id: "fixture", root: root, source: source, peers: [], launcher: launcher, gate: gate,
                          now: { now }, scheduler: { _, _ in }, route: { _, _ in .mine })
    }
    @Test func pausedPastResetReadyAfterRestartAndResumesOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = Launcher(), gate = Gate(), now = Date(timeIntervalSince1970: 100)
        let runner = try open(root, source: source, launcher: launcher, gate: gate, now: now)
        try runner.reconcile()
        launcher.statusValue = MissionJobStatus(state: .paused, resumeAt: now.addingTimeInterval(100))
        try runner.reconcile(); try runner.resume("Job")
        #expect(launcher.resumes == 0)
        #expect(runner.state == .running) // waiting on the limit is not a person's turn yet
        runner.close()
        let recovered = try open(root, source: nil, launcher: launcher, gate: gate, now: now.addingTimeInterval(200))
        try recovered.reconcile()
        let job = try #require(recovered.jobs["Job"])
        #expect(job.state == .paused)
        #expect(recovered.state == .needsYou) // past the reset, the Resume click is a person's turn
        #expect(TaskStateLine.make(kind: .mission, state: .waiting(job.resumeAt), now: now.addingTimeInterval(200), time: { _ in "14:05" }).text == "Ready to resume")
        try recovered.resume("Job"); try recovered.resume("Job")
        #expect(launcher.resumes == 1 && launcher.starts == 1)
        recovered.close()
    }
    @Test func quitDuringMissionMergeUsesSameKeyWithoutSecondEffect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = Launcher(), gate = Gate(), now = Date()
        let runner = try open(root, source: source, launcher: launcher, gate: gate, now: now)
        try runner.reconcile()
        launcher.statusValue = MissionJobStatus(state: .completed)
        gate.interrupt = true
        try runner.reconcile(); runner.close() // remote merge succeeded; result was lost
        gate.interrupt = false
        let recovered = try open(root, source: nil, launcher: launcher, gate: gate, now: now)
        try recovered.resume("Job")
        #expect(recovered.jobs["Job"]?.state == .merged)
        #expect(gate.effects == 1 && launcher.starts == 1 && launcher.resumes == 0)
        recovered.close()
    }
}
