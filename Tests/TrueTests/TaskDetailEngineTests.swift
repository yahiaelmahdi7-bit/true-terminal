import Foundation
import Testing
@testable import True

@Suite(.serialized) struct TaskDetailEngineTests {
    final class Repo {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var git: TaskGit { TaskGit(folder: root.path, deadline: Date().addingTimeInterval(30)) }
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try command(["init", "-b", "main"])
            try command(["config", "user.name", "Fixture"]); try command(["config", "user.email", "fixture@example.test"])
            try write("initial.txt", "first\nsecond\n"); try commit("Initial")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func command(_ args: [String]) throws {
            let result = git.run(args)
            #expect(result.code == 0, "git \(args) exited \(result.code)")
            if result.code != 0 { throw CocoaError(.fileReadUnknown) }
        }
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        func commit(_ message: String) throws { try command(["add", "."]); try command(["commit", "-m", message]) }
    }
    func builder(_ repo: Repo) -> BuilderRecord {
        BuilderRecord(id: "fixture", name: "Fixture", cwd: repo.root.path, originCwd: repo.root.path,
                      model: "sonnet", sessionID: "", claudePID: 0, started: 0, state: .done, acked: false,
                      branch: "feature")
    }
    @Test func independentSixteenCombinations() throws {
        let repo = try Repo()
        try repo.command(["checkout", "-b", "feature"])
        try repo.write("work", "work\n"); try repo.commit("Work")
        let directory = repo.root.appendingPathComponent(".git/gate")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let head = repo.git.value(["rev-parse", "HEAD"])!
        let resultFile = directory.appendingPathComponent(head + ".json")
        let checks: [TaskChecks] = [.notRun, .passed, .failed(2), .flaky(1)]
        var count = 0
        for merged in [false, true] {
            if merged {
                try repo.command(["checkout", "main"]); try repo.command(["merge", "feature"])
                try repo.command(["checkout", "feature"])
            }
            for finished in [false, true] {
                for check in checks {
                    if check == .notRun { try? FileManager.default.removeItem(at: resultFile) }
                    else {
                        let object: [String: Any] = ["passed": ["test"], "failed": check == .failed(2) ? ["a", "b"] : [],
                                                    "flaky": check == .flaky(1) ? ["c"] : [], "reason": NSNull(), "duration": 1, "commit": head]
                        try JSONSerialization.data(withJSONObject: object).write(to: resultFile)
                    }
                    var record = builder(repo); record.state = finished ? .done : .running
                    let detail = TaskDetail.builder(record, owner: "Me", provider: "Claude", gateDirectory: directory)
                    var progress = MissionJobProgress(); progress.state = finished ? .completed : .running
                    let mission = TaskDetail.mission(job: MissionJob(title: "Job", line: 1), progress: progress,
                                                     folder: repo.root.path, base: "main", branch: "feature",
                                                     checks: check, checkCommand: "swift test")
                    for value in [detail, mission] {
                        #expect(value.finished == finished && value.checks == check && value.merged == merged)
                    }
                    count += 1
                }
            }
        }
        #expect(count == 16)
    }
    @Test func renameSquashCountsAndBothTaskKinds() throws {
        let repo = try Repo()
        try repo.command(["checkout", "-b", "feature"])
        try repo.command(["mv", "initial.txt", "renamed.txt"])
        try repo.write("new.txt", "one\ntwo\n"); try repo.commit("Rename and add")
        try repo.write("new.txt", "one\ntwo\nthree\n"); try repo.commit("More work")
        let before = TaskChangesReader(folder: repo.root.path).read()
        #expect(before.files.count == 2)
        #expect(before.files.first { $0.path == "renamed.txt" }?.oldPath == "initial.txt")
        #expect(before.files.first { $0.path == "new.txt" }?.added == 3)
        let expected = TaskChangesReader.numstat(repo.git.run(["diff", "--numstat", "-z", "-M", "main", "HEAD"]).data, git: repo.git, ref: "HEAD")
        #expect(before.files == expected && !before.merged)
        try repo.command(["checkout", "main"]); try repo.command(["merge", "--squash", "feature"]); try repo.commit("Squashed")
        try repo.command(["checkout", "feature"])
        let built = TaskDetail.builder(builder(repo), owner: "Me", provider: "Claude")
        let mission = TaskDetail.mission(job: MissionJob(title: "Job", line: 1), progress: MissionJobProgress(),
                                         folder: repo.root.path, base: "main", branch: "feature", checks: .passed)
        #expect(built.merged && mission.merged)
        #expect(built.changes.files == expected && mission.changes.files == expected)
    }
    @Test func squashPatchRecognizedAfterBaseMoves() throws {
        let repo = try Repo()
        let original = (0..<40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try repo.write("context", original); try repo.commit("Context")
        try repo.command(["checkout", "-b", "feature"])
        try repo.write("context", original.replacingOccurrences(of: "line 25\n", with: "changed\n")); try repo.commit("Change")
        try repo.command(["checkout", "main"])
        try repo.write("context", "new first line\n" + original); try repo.commit("Base moved")
        try repo.command(["merge", "--squash", "feature"]); try repo.commit("Squash")
        try repo.command(["checkout", "feature"])
        #expect(TaskChangesReader(folder: repo.root.path).read().merged)
    }
    @Test func emptyCasesPagingBinaryAndDirty() throws {
        let repo = try Repo()
        let reader = TaskChangesReader(folder: repo.root.path)
        #expect(reader.read().emptyMessage == TaskDetailCopy.noChanges)
        #expect(TaskChangesReader(folder: "/no/such/folder").read().emptyMessage == TaskDetailCopy.notGit)
        let mission = TaskDetail.mission(job: MissionJob(title: "Empty", line: 1), progress: MissionJobProgress(),
                                         folder: repo.root.path, base: "main", branch: "main", checks: .passed)
        #expect(mission.checks.label == "No check set")
        try repo.command(["checkout", "-b", "feature"])
        try Data([0, 1, 2]).write(to: repo.root.appendingPathComponent("binary"))
        try repo.write("large", String(repeating: "a", count: 1_048_577))
        try repo.commit("Add opaque files")
        try repo.write("initial.txt", "changed\n")
        try repo.write("not committed", "hello\n")
        let result = reader.read()
        #expect(result.files.first { $0.path == "binary" }?.canShowDiff == false)
        #expect(result.files.first { $0.path == "large" }?.canShowDiff == false)
        #expect(result.files.first { $0.path == "large" }?.added == nil)
        #expect(Set(result.notCommitted.map(\.path)) == ["initial.txt", "not committed"])
        #expect(reader.diff(result.notCommitted.first { $0.path == "initial.txt" }!, changes: result, uncommitted: true)?.contains("+changed") == true)
        #expect(reader.diff(result.notCommitted.first { $0.path == "not committed" }!, changes: result, uncommitted: true)?.contains("+hello") == true)
        var many = TaskChanges()
        many.files = (0..<601).map { TaskChangedFile(path: "\($0)", added: 1, removed: 0, bytes: 1, binary: false) }
        #expect(many.page(0).count == 300 && many.page(1).count == 300 && many.page(2).count == 1 && many.page(-1).isEmpty)
    }
    @Test func basePreferenceAndGateSchema() throws {
        let repo = try Repo()
        try repo.command(["branch", "mission-base"]); try repo.command(["branch", "upstream"])
        try repo.command(["checkout", "-b", "feature"]); try repo.command(["branch", "--set-upstream-to=upstream"])
        #expect(TaskChangesReader(folder: repo.root.path).read(missionBase: "mission-base").base == "mission-base")
        #expect(TaskChangesReader(folder: repo.root.path).read().base == "upstream")
        let directory = repo.root.appendingPathComponent("gate"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let head = repo.git.value(["rev-parse", "HEAD"])!
        #expect(TaskChecks.read(commit: head, directory: directory) == .notRun)
        for (failed, flaky, expected) in [(0, 0, TaskChecks.passed), (2, 0, .failed(2)), (0, 1, .flaky(1))] {
            let object: [String: Any] = ["passed": ["test"], "failed": Array(repeating: "bad", count: failed),
                                        "flaky": Array(repeating: "flake", count: flaky), "reason": NSNull(), "duration": 1, "commit": head]
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(head + ".json"))
            #expect(TaskChecks.read(commit: head, directory: directory) == expected)
        }
    }
    @Test func stateActionsAndAllowanceReset() throws {
        let now = Date(timeIntervalSince1970: 100), future = Date(timeIntervalSince1970: 200)
        let format: (Date) -> String = { _ in "14:05" }
        #expect(TaskStateLine.make(kind: .mission, state: .waiting(future), now: now, time: format).resumeEnabled == false)
        #expect(TaskStateLine.make(kind: .mission, state: .waiting(now), now: future, time: format).text == "Ready to resume")
        #expect(TaskStateLine.make(kind: .builder, state: .waiting(future), now: now, time: format).nextAction == "Resumes automatically")
        #expect(TaskStateLine.make(kind: .seat, state: .waiting(future), now: now, time: format).nextAction == "Type continue in the pane after 14:05")
        #expect(TaskStateLine.make(kind: .builder, state: .waiting(now), now: future, time: format).text == "Running")
        var blocked = MissionJobProgress(); blocked.state = .needsYou; blocked.mergeBlocked = true
        let detail = TaskDetail.mission(job: MissionJob(title: "Blocked", line: 1), progress: blocked,
                                        folder: "/no/repo", base: "main", branch: "feature", checks: .failed(1), checkCommand: "swift test")
        #expect(detail.state.text == "Failed: The gate failed")
        #expect(detail.owner == "Unassigned" && detail.provider == "Not chosen")
        let data = Data(#"{"windows":{"five":{"status":"rejected","resets_at":200},"seven":{"util":1,"resets_at":90}}}"#.utf8)
        #expect(TaskUsageLimit.reset(reading: data, now: now) == future)
        #expect(TaskUsageLimit.reset(reading: data, now: future) == nil)
    }
}
