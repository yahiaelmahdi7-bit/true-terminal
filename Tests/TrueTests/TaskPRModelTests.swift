import Foundation
import Testing
@testable import True

actor Latch {
    private var open = false
    func release() { open = true }
    func wait() async { while !open { try? await Task.sleep(for: .milliseconds(2)) } }
}

/// The PR line's view model against a fake `gh`/`git`: no network, no real repo, no home-folder writes.
@MainActor
@Suite struct TaskPRModelTests {
    final class Fake: @unchecked Sendable {
        var signedIn = true
        var hasPR = true
        var calls: [String] = []
        var latch: Latch?
        var onGateRun: (@Sendable () -> Void)?
        var createRefusal = false
        let lock = NSLock()
        func record(_ c: String) { lock.lock(); calls.append(c); lock.unlock() }
        var log: [String] { lock.lock(); defer { lock.unlock() }; return calls }

        var runner: PRRunner {
            PRRunner { [self] c in
                let line = ([c.tool == .gh ? "gh" : c.tool == .git ? "git" : "file"] + c.args).joined(separator: " ")
                record(line)
                switch (c.tool, c.args.first ?? "") {
                case (.gh, "--version"): return PRRun(code: 0, out: "gh version 2.92.0 (2026-04-28)")
                case (.gh, "auth"): return signedIn ? PRRun(code: 0) : PRRun(code: 1, err: "You are not logged into any GitHub hosts.")
                case (.gh, "pr"):
                    if c.args[1] == "list" && c.args.contains("--head") { return PRRun(code: 0, out: hasPR ? #"[{"number":42}]"# : "[]") }
                    if c.args[1] == "merge" { hasPR = false; return PRRun(code: 0) }
                    if c.args[1] == "view" && c.args.contains("state,mergeCommit") { return PRRun(code: 0, out: #"{"state":"MERGED","mergeCommit":{"oid":"\#(TaskPRBarTests.sha)"}}"#) }
                    if c.args[1] == "view" { return PRRun(code: 0, out: #"{"number":42,"state":"OPEN","isDraft":false,"headRefOid":"\#(TaskPRBarTests.sha)","baseRefName":"main","headRefName":"b","isCrossRepository":false}"#) }
                    if c.args[1] == "create" { return createRefusal ? PRRun(code: 1, err: "boom") : PRRun(code: 0, out: "https://github.com/o/r/pull/42\n") }
                    return PRRun(code: 0, out: "[]")
                case (.gh, "api"): return PRRun(code: 0, out: "ahead")
                case (.git, "remote"): return PRRun(code: 0, out: "git@github.com:o/r.git\n")
                case (.git, "rev-parse"): return PRRun(code: 0, out: TaskPRBarTests.sha + "\n")
                case (.git, "status"): return PRRun(code: 0)
                case (.git, "log"): return PRRun(code: 0)
                case (.file, _):
                    await latch?.wait()
                    onGateRun?()
                    return PRRun(code: 0)
                default: return PRRun(code: 0)
                }
            }
        }
    }

    struct Rig {
        let model: TaskPRModel
        let fake: Fake
        let gateDir: String
        let holds: PRHoldStore
    }

    final class Counter: @unchecked Sendable { var n = 0 }

    func rig(_ fake: Fake = Fake(), gate: GateResult? = TaskPRBarTests.pass(), fastTick: Bool = true, mainGates: Counter = Counter()) throws -> Rig {
        let reader = try TaskPRBarTests.gates(gate)
        let tmp = NSTemporaryDirectory() + "pr-model-\(UUID().uuidString)"
        let holds = PRHoldStore(path: tmp + "/holds.json")
        let m = TaskPRModel(folder: tmp, branch: "builder/x", name: "Task", runner: fake.runner, gates: reader, holds: holds,
                            prDir: tmp + "/pr", gateWorktrees: tmp + "/wt", openSignIn: {},
                            sleep: { try? await Task.sleep(for: .milliseconds(5)) }, mainGate: { _ in mainGates.n += 1 })
        return Rig(model: m, fake: fake, gateDir: reader.dir, holds: holds)
    }

    func until(_ what: @MainActor () -> Bool) async {
        for _ in 0..<600 where !what() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func signedOutShowsTheLineWithSignIn() async throws {
        let f = Fake(); f.signedIn = false
        let r = try rig(f)
        await r.model.load()
        let s = try #require(r.model.state)
        #expect(!s.signedIn && s.showsSignIn && s.primary == .signIn)
        #expect(s.visibleStrings == ["Not signed in to GitHub.", "Sign in to GitHub"])
        #expect(!f.log.contains { $0.hasPrefix("gh pr") })
    }

    /// Merge does what `truectl pr merge` does: merge, fast-forward a clean local main, start the main gate once.
    /// Afterwards the line says "Merged PR #42." instead of offering Create PR for the same work.
    @Test func mergeRunsTheSameFollowUpsAsTheCLI() async throws {
        let f = Fake(), gates = Counter()
        let r = try rig(f, mainGates: gates)
        await r.model.load()
        #expect(r.model.state?.mergeEnabled == true)
        r.model.merge()
        await until { r.model.state?.problem != nil }
        #expect(f.log.contains { $0.hasPrefix("gh pr merge 42 --squash --match-head-commit") })
        #expect(f.log.contains("git fetch origin main"))
        #expect(gates.n == 1)
        let s = try #require(r.model.state)
        #expect(s.problem?.hasPrefix("Merged PR #42.") == true && !s.showsCreate && !s.showsMerge)
        // The local-main note reaches the line, exactly as the shared merge flow words it (this fake's HEAD is not main).
        #expect(s.problem == "Merged PR #42. Local main not updated (it has uncommitted work).")
    }

    @Test func mergedCopy() {
        #expect(TaskPRCopy.merged(42, local: nil) == "Merged PR #42.")
        #expect(TaskPRCopy.merged(42, local: "Merged. Local main not updated (it has uncommitted work).")
                == "Merged PR #42. Local main not updated (it has uncommitted work).")
    }

    @Test func signInButtonOnlyWhenSignedOut() async throws {
        let r = try rig()
        await r.model.load()
        let s = try #require(r.model.state)
        #expect(!s.showsSignIn && !s.visibleStrings.contains(TaskPRCopy.signIn))
    }

    @Test func noPRShowsCreate() async throws {
        let f = Fake(); f.hasPR = false
        let r = try rig(f, gate: nil)
        await r.model.load()
        let s = try #require(r.model.state)
        #expect(s.showsCreate && !s.showsMerge && s.primary == .create)
    }

    @Test func prWithGreenGateCanMerge() async throws {
        let r = try rig()
        await r.model.load()
        let s = try #require(r.model.state)
        #expect(s.prNumber == 42 && s.gate == .green && s.mergeEnabled && s.note == nil)
    }

    @Test func holdAndReleaseRoundTripWithEmptyWhy() async throws {
        let r = try rig()
        await r.model.load()
        r.model.toggleHold()
        await until { r.model.state?.held == true }
        #expect(r.holds.entry(repo: "o/r", number: 42)?.why == "")
        #expect(r.model.state?.mergeEnabled == false && r.model.state?.holdLabel == "Release")
        r.model.toggleHold()
        await until { r.model.state?.held == false }
        #expect(r.holds.entry(repo: "o/r", number: 42) == nil)
        #expect(r.model.state?.mergeEnabled == true)
    }

    @Test func runGateTicksOnlyWhileRunningThenReloads() async throws {
        let f = Fake(); let latch = Latch(); f.latch = latch
        let r = try rig(f, gate: nil)
        let dir = r.gateDir
        f.onGateRun = {
            // The gate script writes its result file; the screen reloads and reads it.
            let data = try! JSONEncoder().encode(TaskPRBarTests.pass())
            FileManager.default.createFile(atPath: "\(dir)/\(TaskPRBarTests.sha).json", contents: data)
            FileManager.default.createFile(atPath: "\(dir)/run1/result.json", contents: data)
        }
        await r.model.load()
        #expect(r.model.state?.gateRunningFor == nil && r.model.state?.gate == .notRun)
        r.model.runGate()
        #expect(r.model.state?.gateRunningFor == 0 && r.model.state?.gateButtonEnabled == false)
        await until { (r.model.state?.gateRunningFor ?? 0) >= 2 }
        #expect((r.model.state?.gateRunningFor ?? 0) >= 2)
        await latch.release()
        await until { r.model.state?.gateRunningFor == nil && r.model.state?.gate == .green }
        #expect(r.model.state?.gateRunningFor == nil)
        #expect(r.model.state?.gate == .green)
        // The clock is gone: the count stays put.
        let after = r.model.state?.gateRunningFor
        try await Task.sleep(for: .milliseconds(40))
        #expect(r.model.state?.gateRunningFor == after)
    }

    @Test func createRefusalShowsPlainLine() async throws {
        let f = Fake(); f.hasPR = false; f.createRefusal = true
        let r = try rig(f, gate: nil)
        await r.model.load()
        r.model.createPR()
        await until { r.model.state?.note != nil }
        let note = try #require(r.model.state?.note)
        #expect(note.hasPrefix("Pushed") || note.hasPrefix("GitHub refused") || note.hasPrefix("Push"))
    }

    @Test func ghMissingShowsPlainProblem() async throws {
        let r = try rig(Fake(), gate: nil)
        let m = TaskPRModel(folder: "/tmp", branch: "b", name: "T",
                            runner: PRRunner { c in c.tool == .gh ? PRRun(code: -127, missing: true) : PRRun(code: 0) },
                            gates: GateReader(dir: r.gateDir), holds: r.holds, openSignIn: {})
        await m.load()
        #expect(m.state?.visibleStrings == [PRCopy.ghMissing])
    }

    @Test func signInCommandIsGhWebLogin() {
        #expect(GitHubSignIn.shellCommand(executable: "/opt/homebrew/bin/gh")
                == "exec '/opt/homebrew/bin/gh' 'auth' 'login' '--hostname' 'github.com' '--web'")
    }

    @Test func gateWordNotChecks() throws {
        #expect(TaskDetailCopy.runGate == "Run gate" && TaskDetailCopy.gateLabel == "Gate")
        let line = TaskStateLine.make(kind: .builder, state: .finished, now: Date(), time: { _ in "" })
        #expect(line.nextAction == "Run gate")
        #expect(TaskFailure.checks.label == "The gate failed")
    }

    @Test func gateRowHiddenWhenPRLineShows() throws {
        let d = TaskDetail(title: "T", owner: "Me", provider: "Claude", branch: "b", state: TaskStateLine(text: "", nextAction: ""),
                           finished: true, checks: .passed, merged: false,
                           changes: TaskChanges(base: "main", head: TaskPRBarTests.sha, commits: [], files: [], notCommitted: []), report: "")
        let line = try TaskPRBarTests.state(TaskPRBarTests.pass())
        #expect(!TaskScreenView(detail: d, pr: line).showsGateRow)
        #expect(!TaskScreenView(detail: d, prPending: true).showsGateRow)
        #expect(TaskScreenView(detail: d).showsGateRow)
    }
}
