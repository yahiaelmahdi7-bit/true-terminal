import Foundation
import Testing
@testable import True

@Suite(.serialized) struct AgentTurnEngineTests {
    typealias Repo = TaskDetailEngineTests.Repo
    func store(_ repo: Repo) -> AgentTurnStore { AgentTurnStore(directory: repo.root.appendingPathComponent("../turns-" + repo.root.lastPathComponent)) }
    func clean(_ store: AgentTurnStore) { try? FileManager.default.removeItem(at: store.directory) }

    @Test func twoEditsAndOneCreationWithoutGitWrites() throws {
        let repo = try Repo(), turns = store(repo); defer { clean(turns) }
        try repo.write("second", "second\n"); try repo.commit("Second")
        // A real stash/index precondition catches refreshes and accidental writes.
        try repo.write("second", "stash me\n"); try repo.command(["stash", "push"])
        let gitDir = repo.root.appendingPathComponent(".git")
        func state() throws -> [String: Data] {
            var values: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(at: gitDir, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in enumerator {
                if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true { values[url.path] = try Data(contentsOf: url) }
            }
            return values
        }
        let before = try state()
        try turns.open(seat: "lead", folder: repo.root.path, pid: 1)
        try repo.write("initial.txt", "changed\n"); try repo.write("second", "also changed\n"); try repo.write("new", "created\n")
        let closed = try #require(try turns.close(seat: "lead", end: .stop))
        #expect(closed.files == ["initial.txt", "new", "second"])
        #expect(try state() == before)
        #expect(!closed.isOpen && closed.state == .finished)
    }
    @Test func movedHeadExcludesFortyArrivals() throws {
        let repo = try Repo(), turns = store(repo); defer { clean(turns) }
        try turns.open(seat: "lead", folder: repo.root.path, pid: 1)
        for n in 0..<40 { try repo.write("arrived-\(n)", "from elsewhere\n") }
        try repo.commit("Pulled forty files")
        try repo.write("initial.txt", "my edit\n")
        #expect(try turns.close(seat: "lead", end: .stop)?.files == ["initial.txt"])
    }
    @Test func bothOverlappingSeatsAndLifecycleClosures() throws {
        let repo = try Repo(), turns = store(repo); defer { clean(turns) }
        try turns.open(seat: "lead", folder: repo.root.path, pid: 1)
        try turns.open(seat: "helper", folder: repo.root.path, pid: 2)
        #expect(turns.records("lead").last?.overlapMessage == "Another seat was working here too")
        #expect(turns.records("helper").last?.sharedFolder == true)
        try turns.close(seat: "lead", end: .failure)
        try turns.close(seat: "helper", end: .session)
        #expect(turns.records("lead").last?.end == .failure)
        #expect(turns.records("helper").last?.end == .session)
        try turns.open(seat: "lead", folder: repo.root.path, pid: 1)
        #expect(turns.records("lead").count == 2)
    }
    @Test func pruneAndSnapshotLimits() throws {
        let repo = try Repo()
        let turns = AgentTurnStore(directory: repo.root.appendingPathComponent("records"), snapshot: { _ in AgentTurnSnapshot(head: "same") })
        for _ in 0..<55 { try turns.open(seat: "lead", folder: repo.root.path, pid: 1); try turns.close(seat: "lead", end: .stop) }
        #expect(turns.records("lead").count == 50)
        try repo.write("untracked", "new\n")
        #expect(AgentTurnSnapshot.capture(folder: repo.root.path, maxFiles: 0).message == "Too many changes to list")
        #expect(AgentTurnSnapshot.capture(folder: repo.root.path, seconds: 0).message == "Too many changes to list")
        #expect(AgentTurnSnapshot.capture(folder: "/no/such/repo").message == "This folder isn't tracked by git")
        try Data().write(to: repo.root.appendingPathComponent(".git/index.lock"))
        #expect(AgentTurnSnapshot.capture(folder: repo.root.path).message == "Busy, try again")
    }
    @Test func quitDuringLaunchAndDuringTurnClose() throws {
        let repo = try Repo(), turns = store(repo); defer { clean(turns) }
        try turns.open(seat: "launching", folder: repo.root.path, pid: 0)
        try turns.open(seat: "alive", folder: repo.root.path, pid: 42)
        try repo.write("initial.txt", "unfinished\n")
        let reopened = AgentTurnStore(directory: turns.directory)
        _ = try reopened.recover(alive: { $0 == 42 })
        #expect(reopened.records("launching").last?.state == .stopped)
        #expect(reopened.records("launching").last?.files == ["initial.txt"])
        #expect(reopened.records("alive").last?.isOpen == true)
        try reopened.close(seat: "alive", end: .stop)
        let closed = reopened.records("alive")
        _ = try AgentTurnStore(directory: turns.directory).recover(alive: { _ in false })
        #expect(reopened.records("alive") == closed) // quit after the atomic close never closes/runs twice
        let recovered = reopened.records("launching")
        _ = try reopened.recover(alive: { _ in false })
        #expect(reopened.records("launching") == recovered)
    }
    @Test func interruptedAtomicCloseRecoversFilesAndExpiresQuestion() throws {
        let repo = try Repo()
        var writes = 0
        let directory = repo.root.appendingPathComponent("../turns-" + repo.root.lastPathComponent)
        let turns = AgentTurnStore(directory: directory, write: { data, url in
            writes += 1
            if writes == 3 { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        })
        defer { clean(turns) }
        try turns.open(seat: "lead", folder: repo.root.path, pid: 0)
        try turns.markQuestion(seat: "lead")
        try repo.write("initial.txt", "edited before quit\n")
        #expect(throws: CocoaError.self) { try turns.close(seat: "lead", end: .stop) }
        #expect(turns.records("lead").last?.isOpen == true)
        let recovered = AgentTurnStore(directory: directory)
        _ = try recovered.recover(alive: { _ in false })
        #expect(recovered.records("lead").last?.files == ["initial.txt"])
        #expect(recovered.records("lead").last?.questionLabel == "Expired")
        #expect(recovered.records("lead").count == 1)
    }
    @MainActor @Test func hooksCloseOpenTurnsOnFailureAndSession() async throws {
        let repo = try Repo()
        let paths = AgentPaths(root: repo.root.appendingPathComponent("../state-" + repo.root.lastPathComponent))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = AgentStore(url: paths.root.appendingPathComponent("agents.json"))
        store.save([Agent(name: "lead-fixture", role: .lead, repo: repo.root.path)])
        let workspace = WorkspaceModel(store: WorkspaceStore(url: paths.root.appendingPathComponent("workspace.json")))
        let registry = AgentRegistry(store: store, paths: paths, workspace: workspace, claudeDir: paths.root)
        let pane = try #require(registry.wake("lead-fixture"))
        func send(_ kind: PaneEventKind, _ message: String = "") {
            registry.handle(PaneEvent(pane: pane, kind: kind, message: message, at: Date()))
        }
        send(.progress, "prompt"); send(.error, "raw error must not be shown")
        #expect(await eventually { registry.turnRecords["lead-fixture"]?.end == .failure })
        send(.progress, "prompt"); send(.session, UUID().uuidString)
        #expect(await eventually { registry.turnRecords["lead-fixture"]?.end == .session })
        #expect(registry.turnRecords["lead-fixture"]?.isOpen == false)
    }
    @Test func ownRepoSnapshotUnderOneSecond() {
        let start = Date()
        let snapshot = AgentTurnSnapshot.capture(folder: FileManager.default.currentDirectoryPath)
        #expect(snapshot.message == nil)
        #expect(Date().timeIntervalSince(start) < 1)
    }
    @Test func autoContinueAfterRestartCapsAtThreeInFiveMinutes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentTurnStore(directory: dir, snapshot: { _ in AgentTurnSnapshot() })
        let now = Date()
        for i in 0..<3 {  // three quits mid-turn, each continued by itself
            try store.open(seat: "lead", folder: dir.path, pid: 0, at: now.addingTimeInterval(Double(i * 10 - 200)))
            #expect(store.autoContinueAllowed(seat: "lead", now: now))
            _ = try store.recover(alive: { _ in false }, at: now.addingTimeInterval(Double(i * 10 - 100)))
        }
        #expect(!store.autoContinueAllowed(seat: "lead", now: now))  // the fourth waits at the prompt
        #expect(store.autoContinueAllowed(seat: "lead", now: now.addingTimeInterval(301)))  // the window passed
        #expect(store.autoContinueAllowed(seat: "other", now: now))  // the cap is per seat
    }
    @Test func restoredSeatContinuesOnlyWhenInterruptedResumedAndAllowed() {
        let go = ResumePlan.continuePrompt(.restart)
        #expect(AgentRegistry.restorePrompt(resumes: true, interrupted: true, allowed: true) == go)
        #expect(AgentRegistry.restorePrompt(resumes: false, interrupted: true, allowed: true) == nil)
        #expect(AgentRegistry.restorePrompt(resumes: true, interrupted: false, allowed: true) == nil)
        #expect(AgentRegistry.restorePrompt(resumes: true, interrupted: true, allowed: false) == nil)
    }
}
