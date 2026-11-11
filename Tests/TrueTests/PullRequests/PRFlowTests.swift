import Testing
import Foundation
@testable import True

@Suite struct PullRequestsDescriptionTests {
    @Test func descriptionFromRecordedResultAndGate() {
        let box = Sandbox(); box.writeGate(sha1, run: "e3f001a5ffff", tests: 1691)
        let result = "# Done\n\n**Agents panel**: one place to see every agent.\nSecond line.\n\nMore later."
        let log = "\(sha2) Live snapshot harness\n\(sha1) Place tile goes live\n"
        let text = PRDescription.build(result: result, commits: PRDescription.commits(fromLog: log), head: sha1, gates: GateReader(dir: box.gateDir))
        #expect(text.hasPrefix("Agents panel: one place to see every agent. Second line.\n\n## What changed\n"))
        #expect(text.contains("- bbbbbbb Live snapshot harness\n- aaaaaaa Place tile goes live"))
        #expect(text.contains("- Gate: passed on aaaaaaa (clean run), 1691 tests, 89 s. Run e3f001a5."))
        #expect(text.contains("- Flaky: none. Failed: none."))
        #expect(text.contains("Built by True from the builder's result and the gate file."))
    }
    @Test func dotRunIdsDoNotEscapeTheGateDir() {
        let box = Sandbox(); box.writeGate(sha1)
        let reader = GateReader(dir: box.gateDir)
        try? #"{"passed":true,"failed":[],"flaky":[],"reason":"","duration":1,"commit":"\#(sha1)","run_id":"..","dirty":false}"#
            .write(toFile: "\(box.gateDir)/../result.json", atomically: true, encoding: .utf8)
        for bad in [".", ".."] {
            var g = reader.result(sha1)!; g.run_id = bad
            #expect(reader.runFileOK(g) == false)
        }
    }
    @Test func missingPiecesSayNotRecorded() {
        let box = Sandbox()
        let text = PRDescription.build(result: nil, commits: [], head: sha1, gates: GateReader(dir: box.gateDir))
        #expect(text.contains("Summary not recorded.") && text.contains("- not recorded") && text.contains("Gate: not run."))
        box.writeGate(sha2)
        let old = PRDescription.build(result: nil, commits: [.init(sha: sha2, subject: "x"), .init(sha: sha1, subject: "y")], head: sha1, gates: GateReader(dir: box.gateDir))
        #expect(old.contains("Gate: last run on bbbbbbb, not this commit."))
        box.writeGate(sha1, passed: false, reason: "build failed")
        #expect(PRDescription.build(result: nil, commits: [], head: sha1, gates: GateReader(dir: box.gateDir)).contains("Gate: failed (build failed)."))
        let long = PRDescription.summary(fromResult: String(repeating: "x", count: 3000))
        #expect(long?.count == 1200)
    }
}

@Suite struct PullRequestsListTests {
    @Test func listGateWordsGreenRedNotRunOld() {
        let box = Sandbox(); let g = GateReader(dir: box.gateDir)
        box.writeGate(sha1)
        #expect(g.word(head: sha1, commits: [sha1]) == .green)
        #expect(g.word(head: sha2, commits: [sha1, sha2]) == .old)
        #expect(g.word(head: sha3, commits: [sha3]) == .notRun)
        box.writeGate(sha2, passed: false)
        #expect(g.word(head: sha2, commits: [sha2]) == .red)
    }
    @Test func everyGateFileStateHasAWord() {
        let box = Sandbox(); let g = GateReader(dir: box.gateDir)
        box.writeGate(sha1, dirty: true)
        #expect(g.word(head: sha1, commits: []) == .notRun)
        box.writeGate(sha2, commit: sha3)
        #expect(g.word(head: sha2, commits: []) == .notRun)
    }
    @Test func rowsDecodeWithAuthorAndHold() {
        let box = Sandbox(); box.writeGate(sha1)
        let json = #"[{"number":7,"title":"T","headRefName":"builder/alpha","headRefOid":"\#(sha1)","author":{"login":"owner"},"additions":3,"deletions":1,"isDraft":false,"url":"u","commits":[{"oid":"\#(sha1)"}]},{"number":8,"title":"U","headRefName":"fix","headRefOid":"\#(sha2)","author":{"login":"owner"},"commits":[]}]"#
        let hold = HoldEntry(repo: "o/r", number: 8, since: "s", why: "w")
        let rows = PRList.rows(json: json, gates: GateReader(dir: box.gateDir), held: { $0 == 8 ? hold : nil })
        #expect(rows?.map(\.author) == ["alpha", "owner"])
        #expect(rows?.map(\.gate) == ["Green", "Not run"])
        #expect(rows?.map(\.held) == [false, true])
    }
}

@Suite struct PullRequestsRunnerTests {
    @Test func runnerTimeoutAndPathUseProgramFinder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("true-pr-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slow = dir.appendingPathComponent("slow-gh").path, env = dir.appendingPathComponent("env-gh").path
        try "#!/bin/sh\n/bin/sleep 5\n".write(toFile: slow, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho \"$PATH\"\n".write(toFile: env, atomically: true, encoding: .utf8)
        for f in [slow, env] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f) }
        let timedOut = PRRunner.process(resolve: { $0 == "gh" ? slow : nil }, path: { "/x" })
        let started = Date()
        let r = await timedOut.run(PRCommand(tool: .gh, args: [], timeout: 0.3))
        #expect(r.timedOut && !r.ok && Date().timeIntervalSince(started) < 3)
        let withPath = PRRunner.process(resolve: { $0 == "gh" ? env : nil }, path: { "/opt/homebrew/bin:/usr/bin" })
        #expect(await withPath.run(PRCommand(tool: .gh, args: [])).trimmed == "/opt/homebrew/bin:/usr/bin")
        let none = PRRunner.process(resolve: { _ in nil }, path: { "" })
        #expect(await none.run(PRCommand(tool: .gh, args: [])).missing)
    }
    @Test func outputCapStopsReading() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("true-pr-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let big = dir.appendingPathComponent("big").path
        try "#!/bin/sh\nyes x | head -c 3000000\n".write(toFile: big, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: big)
        let r = await PRRunner.process(resolve: { _ in big }, path: { "/usr/bin:/bin" }).run(PRCommand(tool: .gh, args: [], timeout: 10, maxBytes: 1_048_576))
        #expect(r.truncated && r.out.utf8.count <= 1_048_576)
    }
}

@Suite struct PullRequestsPreflightTests {
    private func run(_ r: PRFakeRunner) async -> String? { await PRPreflight.check(runner: r.runner, cwd: "/x") }
    @Test func ghMissingAndSignedOutHavePlainText() async {
        #expect(await run(PRFakeRunner { _ in PRRun(code: -127, missing: true) }) == "GitHub CLI missing. Install it, then try again.")
        #expect(await run(PRFakeRunner { $0.args == ["--version"] ? PRRun(code: 0, out: "gh version 2.92.0 (2026-04-28)") : PRRun(code: 1, err: "You are not logged in") }) == "Not signed in to GitHub.")
        #expect(await run(PRFakeRunner { _ in PRRun(code: 0, out: "gh version 2.93.1") }) == nil)
    }
    @Test func ghOlderThanFloorSaysUpdate() async {
        #expect(await run(PRFakeRunner { _ in PRRun(code: 0, out: "gh version 2.81.0 (2025-01-01)") }) == "Update the GitHub CLI.")
    }
    @Test func ghNetworkFailureIsNotSignedOut() async {
        #expect(await run(PRFakeRunner { $0.args == ["--version"] ? PRRun(code: 0, out: "gh version 2.92.0") : PRRun(code: 1, err: "error connecting to api.github.com") }) == "Could not reach GitHub.")
        #expect(await run(PRFakeRunner { $0.args == ["--version"] ? PRRun(code: 0, out: "gh version 2.92.0") : PRRun(code: -2, timedOut: true) }) == "Could not reach GitHub.")
    }
}

@Suite struct PullRequestsHoldTests {
    @Test func holdFileHasNoTokensAndSurvivesPush() throws {
        let box = Sandbox(); let store = PRHoldStore(path: box.holdsPath)
        #expect(store.hold(repo: "o/r", number: 42, why: "waiting on Alex", now: Date(timeIntervalSince1970: 0)))
        let attrs = try FileManager.default.attributesOfItem(atPath: box.holdsPath)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: box.holdsPath))) as? [String: Any])
        #expect(Set(obj.keys) == ["version", "holds"])
        let entry = try #require((obj["holds"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["repo", "number", "since", "why"])
        // Holds follow the PR number: a new head changes nothing.
        let ctx = box.ctx(PRFakeRunner(), holds: store)
        #expect(ctx.held(42)?.why == "waiting on Alex" && ctx.held(43) == nil)
        #expect(store.release(repo: "o/r", number: 42) && store.entry(repo: "o/r", number: 42) == nil)
    }
    @Test func holdReleaseRefusedFromTruectlAndAgents() async {
        let box = Sandbox(); let store = PRHoldStore(path: box.holdsPath)
        store.hold(repo: "o/r", number: 7, why: "w")
        var env = PRControlEnv(); env.holds = store
        env.runner = PRFakeRunner { _ in PRRun(code: 0, out: "git@github.com:o/r.git") }.runner
        for from in [nil, "builder-x"] as [String?] {
            let r = await PRControl.handle(PRRequest(verb: "release", number: 7, cwd: box.root.path, from: from), env: env)
            #expect(!r.ok && r.error == "Held. Only the user can release, in True.")
        }
        #expect(store.entry(repo: "o/r", number: 7) != nil)
        let held = await PRControl.handle(PRRequest(verb: "hold", number: 8, why: "later", cwd: box.root.path), env: env)
        #expect(held.ok && store.entry(repo: "o/r", number: 8)?.why == "later")
    }
}

@Suite struct PullRequestsControlTests {
    private func env(_ box: Sandbox, _ gh: PRFakeRunner, mainGate: (@Sendable (PRContext) -> Void)? = nil) -> PRControlEnv {
        var e = PRControlEnv()
        e.runner = gh.runner; e.gates = GateReader(dir: box.gateDir); e.holds = PRHoldStore(path: box.holdsPath)
        e.prDir = box.root.appendingPathComponent("pr").path; e.gateWorktrees = box.root.appendingPathComponent("pr-gate").path
        e.gateLock = PRGateLock()
        if let mainGate { e.mainGate = mainGate }
        return e
    }
    private func github(_ box: Sandbox, heads: [String]) -> FakeGitHub {
        let gh = FakeGitHub(heads: heads)
        let inner = gh.fake.handler
        gh.fake.handler = { c in
            if c.tool == .git, c.args.starts(with: ["remote", "get-url"]) { return PRRun(code: 0, out: "https://github.com/o/r.git\n") }
            if c.args == ["--version"] { return PRRun(code: 0, out: "gh version 2.92.0") }
            if c.args.starts(with: ["auth", "status"]) { return PRRun(code: 0) }
            if c.tool == .git, c.args == ["status", "--porcelain"] { return PRRun(code: 0, out: " M f\n") }
            return inner(c)
        }
        return gh
    }
    @Test func agentMergeWithoutShaIsRefused() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = github(box, heads: [sha1])
        let r = await PRControl.handle(PRRequest(verb: "merge", number: 7, cwd: box.root.path, from: "builder-x"), env: env(box, gh.fake))
        #expect(!r.ok && r.error == "Not merged: pass --sha with the commit you gated.")
        #expect(gh.fake.count("gh pr merge") == 0)
    }
    @Test func postMergeTriggersOneOriginMainGate() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = github(box, heads: [sha1])
        let triggered = PRCounter()
        let r = await PRControl.handle(PRRequest(verb: "merge", number: 7, sha: sha1, cwd: box.root.path),
                                       env: env(box, gh.fake, mainGate: { _ in _ = triggered.next() }))
        #expect(r.ok && r.outcome?.hasPrefix("Merged PR #7") == true)
        #expect(triggered.next() == 2)
        #expect(gh.fake.count("gh pr merge 7 --squash --match-head-commit") == 1)
    }
    @Test func refusedMergeDoesNotTriggerMainGate() async {
        let box = Sandbox()
        let gh = github(box, heads: [sha1])
        let triggered = PRCounter()
        let r = await PRControl.handle(PRRequest(verb: "merge", number: 7, sha: sha1, cwd: box.root.path),
                                       env: env(box, gh.fake, mainGate: { _ in _ = triggered.next() }))
        #expect(!r.ok && r.error == "Not merged: No gate result for this commit. Run the gate first.")
        #expect(triggered.next() == 1)
    }
    @Test func mainGateRecordsRedMain() async {
        let box = Sandbox()
        let fake = PRFakeRunner { c in
            if c.tool == .git, c.args == ["rev-parse", "origin/main"] { return PRRun(code: 0, out: sha2 + "\n") }
            if c.tool == .git, c.args == ["rev-parse", "HEAD"] { return PRRun(code: 0, out: sha2 + "\n") }
            if case .file = c.tool { box.writeGate(sha2, passed: false, reason: "tests failed"); return PRRun(code: 1) }
            return PRRun(code: 0)
        }
        let health = PRMainHealth()
        await PRMainGate.run(ctx: box.ctx(fake), health: health)
        #expect(health.state == .red(sha: sha2, reason: "tests failed") && health.isRed)
        #expect(fake.count("git worktree remove --force") >= 1)
    }
    @Test func secondGateWhileOneRunsSaysSo() async {
        let box = Sandbox(); let ctx = box.ctx(PRFakeRunner())
        _ = await ctx.gateLock.tryTake()
        let r = await PRGate.run(sha: sha1, fetch: ["fetch", "origin", "pull/7/head"], ctx: ctx)
        #expect(r.word == nil && r.error == "A gate is already running.")
    }
    @Test func gateRunsInDetachedWorktreeAndRemovesIt() async {
        let box = Sandbox()
        let fake = PRFakeRunner { c in
            if c.tool == .git, c.args == ["rev-parse", "HEAD"] { return PRRun(code: 0, out: sha1 + "\n") }
            if case .file = c.tool { box.writeGate(sha1); return PRRun(code: 0) }
            return PRRun(code: 0)
        }
        let r = await PRGate.run(sha: sha1, fetch: ["fetch", "origin", "pull/7/head"], ctx: box.ctx(fake))
        #expect(r.word == .green)
        let dir = box.root.appendingPathComponent("pr-gate/\(sha1)").path
        #expect(fake.lines.contains("git fetch origin pull/7/head"))
        #expect(fake.lines.contains("git worktree add --detach \(dir) \(sha1)"))
        #expect(fake.lines.last == "git worktree remove --force \(dir)")
    }
    @Test func concurrentPrCreateMakesOnePR() async {
        let box = Sandbox()
        let created = PRCounter()
        let fake = PRFakeRunner()
        fake.handler = { c in
            let a = c.args
            if a == ["rev-parse", "--abbrev-ref", "HEAD"] { return PRRun(code: 0, out: "builder/x\n") }
            if a == ["status", "--porcelain"] { return PRRun(code: 0) }
            if a == ["rev-parse", "HEAD"] { return PRRun(code: 0, out: sha1 + "\n") }
            if a.starts(with: ["pr", "list"]) {
                return PRRun(code: 0, out: created.peek() > 0 ? #"[{"number":7,"url":"https://github.com/o/r/pull/7"}]"# : "[]")
            }
            if a.starts(with: ["pr", "create"]) { _ = created.next(); return PRRun(code: 0, out: "https://github.com/o/r/pull/7\n") }
            if a.starts(with: ["pr", "view"]) { return PRRun(code: 0, out: #"{"number":7,"url":"https://github.com/o/r/pull/7","headRefOid":"\#(sha1)","state":"OPEN"}"#) }
            return PRRun(code: 0)
        }
        let ctx = box.ctx(fake)
        let task = PRTask(name: "Title", folder: box.root.path, branch: nil, resultFile: nil)
        let lock = PRCreateLock()
        async let a = PRCreate.run(task: task, ctx: ctx, lock: lock)
        async let b = PRCreate.run(task: task, ctx: ctx, lock: lock)
        let results = await [a, b]
        #expect(fake.count("gh pr create") == 1)
        #expect(results.contains(.created(number: 7, url: "https://github.com/o/r/pull/7")))
        #expect(results.contains(.alreadyOpen(number: 7, url: "https://github.com/o/r/pull/7")))
        let create = fake.lines.first { $0.hasPrefix("gh pr create") } ?? ""
        #expect(create.hasPrefix("gh pr create --base main --head builder/x --title Title --body-file "))
        #expect(fake.lines.contains("git push --set-upstream origin builder/x"))
        #expect(!fake.lines.joined().contains("--force"))
    }
    @Test func createRefusesMainDirtyAndBehind() async {
        let box = Sandbox()
        let main = PRFakeRunner { $0.args == ["rev-parse", "--abbrev-ref", "HEAD"] ? PRRun(code: 0, out: "main\n") : PRRun(code: 0) }
        let task = PRTask(name: "T", folder: box.root.path, branch: nil, resultFile: nil)
        #expect(await PRCreate.run(task: task, ctx: box.ctx(main)) == .refused("Work is not on its own branch."))
        let dirty = PRFakeRunner { c in
            c.args == ["rev-parse", "--abbrev-ref", "HEAD"] ? PRRun(code: 0, out: "b/x\n") : c.args == ["status", "--porcelain"] ? PRRun(code: 0, out: " M f\n") : PRRun(code: 0)
        }
        #expect(await PRCreate.run(task: task, ctx: box.ctx(dirty)) == .refused("Commit first."))
        let behind = PRFakeRunner { c in
            if c.args == ["rev-parse", "--abbrev-ref", "HEAD"] { return PRRun(code: 0, out: "b/x\n") }
            if c.args == ["rev-parse", "HEAD"] { return PRRun(code: 0, out: sha1 + "\n") }
            if c.args.starts(with: ["pr", "list"]) { return PRRun(code: 0, out: "[]") }
            if c.args.first == "push" { return PRRun(code: 1, err: " ! [rejected] b/x -> b/x (non-fast-forward)") }
            return PRRun(code: 0)
        }
        #expect(await PRCreate.run(task: task, ctx: box.ctx(behind)) == .refused("Branch is behind GitHub. Update it first."))
    }
}

@Suite struct PullRequestsUpdateTests {
    private func clean(_ box: Sandbox, rebaseFails: Bool = false, diverged: Bool = false) -> PRFakeRunner {
        PRFakeRunner { c in
            let a = c.args
            if a == ["rev-parse", "--abbrev-ref", "HEAD"] { return PRRun(code: 0, out: c.cwd == box.root.path && diverged ? "main\n" : "builder/x\n") }
            if a == ["rev-parse", "HEAD"] { return PRRun(code: 0, out: sha1 + "\n") }
            if a.first == "rebase", a.count == 2, rebaseFails { return PRRun(code: 1, err: "CONFLICT") }
            if a.starts(with: ["diff", "--name-only"]) { return PRRun(code: 0, out: "a\nb\n") }
            if a.starts(with: ["merge", "--ff-only"]) { return PRRun(code: diverged ? 128 : 0) }
            return PRRun(code: 0)
        }
    }
    @Test func rebaseConflictAbortsAndSaysCount() async {
        let box = Sandbox(); let fake = clean(box, rebaseFails: true)
        let r = await PRUpdate.run(branch: "builder/x", worktree: box.root.path, ctx: box.ctx(fake))
        #expect(r == "Can't update: conflicts in 2 files.")
        #expect(fake.lines.contains("git rebase --abort") && fake.count("git push") == 0)
    }
    @Test func updateBranchPushesWithLeaseOnly() async {
        let box = Sandbox(); let fake = clean(box)
        #expect(await PRUpdate.run(branch: "builder/x", worktree: box.root.path, ctx: box.ctx(fake)) == nil)
        #expect(fake.lines.contains("git push --force-with-lease=builder/x:\(sha1) origin builder/x"))
    }
    @Test func updateBranchNeedsCleanWorktree() async {
        let box = Sandbox()
        let dirty = PRFakeRunner { $0.args == ["status", "--porcelain"] ? PRRun(code: 0, out: " M f\n") : PRRun(code: 0) }
        #expect(await PRUpdate.run(branch: "builder/x", worktree: box.root.path, ctx: box.ctx(dirty)) == "No clean local copy of this branch.")
        #expect(dirty.count("git rebase") == 0)
    }
    @Test func divergedLocalMainSaysNotUpdated() async {
        let box = Sandbox()
        #expect(await PRPostMerge.updateLocalMain(ctx: box.ctx(clean(box, diverged: true))) == "Merged. Local main has diverged from GitHub; not updated.")
        let dirty = PRFakeRunner { c in
            c.args == ["rev-parse", "--abbrev-ref", "HEAD"] ? PRRun(code: 0, out: "main\n") : c.args == ["status", "--porcelain"] ? PRRun(code: 0, out: " M f\n") : PRRun(code: 0)
        }
        #expect(await PRPostMerge.updateLocalMain(ctx: box.ctx(dirty)) == "Merged. Local main not updated (it has uncommitted work).")
        #expect(dirty.count("git merge") == 0)
    }
}

/// Update branch with no local copy, against real git: a bare "origin", a seed clone that pushes, and a work clone
/// (the True repo dir) that has no local copy of the PR branch.
@Suite struct PRFlowTests {
    struct Repo {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("true-pr-flow-\(UUID().uuidString)")
        var origin: String { root.appendingPathComponent("origin.git").path }
        var seed: String { root.appendingPathComponent("seed").path }
        var work: String { root.appendingPathComponent("work").path }
        @discardableResult func git(_ args: [String], in dir: String) -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: dir)
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func write(_ name: String, _ text: String, in dir: String) { try? text.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        func commit(_ msg: String, in dir: String) { git(["add", "-A"], in: dir); git(["commit", "-qm", msg], in: dir) }
        /// main has a.txt + b.txt; builder/x adds x.txt (or edits a.txt + b.txt when `conflict`); main then moves on.
        init(conflict: Bool = false) {
            let fm = FileManager.default
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            git(["init", "-q", "--bare", "-b", "main", origin], in: root.path)
            git(["clone", "-q", origin, seed], in: root.path)
            for d in [seed] { git(["config", "user.email", "t@t"], in: d); git(["config", "user.name", "t"], in: d) }
            write("a.txt", "a\n", in: seed); write("b.txt", "b\n", in: seed); commit("base", in: seed)
            git(["push", "-q", "origin", "main"], in: seed)
            git(["checkout", "-q", "-b", "builder/x"], in: seed)
            if conflict { write("a.txt", "branch a\n", in: seed); write("b.txt", "branch b\n", in: seed) } else { write("x.txt", "x\n", in: seed) }
            commit("pr work", in: seed); git(["push", "-q", "origin", "builder/x"], in: seed)
            git(["checkout", "-q", "main"], in: seed)
            if conflict { write("a.txt", "main a\n", in: seed); write("b.txt", "main b\n", in: seed) } else { write("m.txt", "m\n", in: seed) }
            commit("main moves", in: seed); git(["push", "-q", "origin", "main"], in: seed)
            git(["clone", "-q", origin, work], in: root.path)
            git(["config", "user.email", "t@t"], in: work); git(["config", "user.name", "t"], in: work)
        }
        /// Records the temp folder `git worktree add` was given, so a test can check it is gone.
        final class Seen: @unchecked Sendable { var tmp: String? }
        func ctx(_ seen: Seen = Seen()) -> PRContext {
            var c = PRContext(repoDir: work, repo: "o/r", holds: PRHoldStore(path: root.appendingPathComponent("holds.json").path))
            let live = PRRunner.live
            c.runner = PRRunner { cmd in
                if cmd.args.starts(with: ["worktree", "add"]) { seen.tmp = cmd.args.first { $0.contains("true-pr-update-") } }
                return await live.run(cmd)
            }
            return c
        }
        var remoteBranch: String { git(["rev-parse", "builder/x"], in: origin) }
        var remoteMain: String { git(["rev-parse", "main"], in: origin) }
        var worktreeCount: Int { git(["worktree", "list", "--porcelain"], in: work).split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count }
        func gone(_ seen: Seen) -> Bool { seen.tmp.map { !FileManager.default.fileExists(atPath: $0) } ?? false }
    }

    @Test func noLocalCopyRebasesPushesAndRemovesTheTempWorktree() async {
        let r = Repo(); let seen = Repo.Seen(); let oldHead = r.remoteBranch
        #expect(await PRUpdate.run(branch: "builder/x", worktree: nil, ctx: r.ctx(seen)) == nil)
        #expect(r.remoteBranch != oldHead)
        #expect(r.git(["log", "--format=%s", "builder/x"], in: r.origin).split(separator: "\n").map(String.init) == ["pr work", "main moves", "base"])
        #expect(r.worktreeCount == 1 && r.gone(seen))
        #expect(r.git(["branch", "--list", "builder/x"], in: r.work).isEmpty)      // no local branch was made
    }

    @Test func noLocalCopyConflictLeavesRemoteAlone() async {
        let r = Repo(conflict: true); let seen = Repo.Seen(); let oldHead = r.remoteBranch
        #expect(await PRUpdate.run(branch: "builder/x", worktree: nil, ctx: r.ctx(seen)) == "Can't update: conflicts in 2 files.")
        #expect(r.remoteBranch == oldHead)
        #expect(r.worktreeCount == 1 && r.gone(seen))
    }

    @Test func leaseRefusesWhenTheRemoteBranchMovedAfterTheFetch() async {
        let r = Repo(); let oldHead = r.remoteBranch
        // After the fetch, someone pushes to the branch: the push of the stale rebase must be refused.
        var ctx = r.ctx(); let live = PRRunner.live
        ctx.runner = PRRunner { c in
            if c.args.first == "push" {
                r.git(["checkout", "-q", "builder/x"], in: r.seed); r.write("late.txt", "l\n", in: r.seed); r.commit("late", in: r.seed)
                r.git(["push", "-q", "origin", "builder/x"], in: r.seed)
            }
            return await live.run(c)
        }
        let line = await PRUpdate.run(branch: "builder/x", worktree: nil, ctx: ctx)
        #expect(line?.hasPrefix("Push failed:") == true)
        #expect(r.remoteBranch != oldHead)                                        // the late push is intact
        #expect(r.git(["log", "--format=%s", "-1", "builder/x"], in: r.origin) == "late")
        #expect(r.worktreeCount == 1)
    }

    @Test func branchNotOnOriginUsesTheGitHubLine() async {
        let r = Repo()
        #expect(await PRUpdate.run(branch: "fork/nope", worktree: nil, ctx: r.ctx()) == PRScreenCopy.noCleanCopy)
        #expect(r.worktreeCount == 1)
    }
}
