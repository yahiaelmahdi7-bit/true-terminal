import AppKit
import Observation

/// What the PR line's "Sign in to GitHub" runs: the real `gh` in a terminal tab. Pure: builds the line only.
/// True never sees the token; `gh` opens the browser and stores it itself.
enum GitHubSignIn {
    static func shellCommand(executable: String?) -> String {
        let exe = executable ?? "gh"
        return "exec " + ["auth", "login", "--hostname", "github.com", "--web"].reduce(AgentLaunch.shellQuote(exe)) { $0 + " " + AgentLaunch.shellQuote($1) }
    }
}

/// The task screen's gate / PR line, loaded with the task. Every GitHub call goes through the injected
/// `PRRunner`; every rule comes from `prMergeCheck` (via `TaskPRState.make` and `prMerge`).
@MainActor @Observable
final class TaskPRModel {
    /// nil = not known yet (the line is not shown).
    private(set) var state: TaskPRState?

    let folder: String, branch: String, name: String, resultFile: String?
    private let runner: PRRunner
    private let gates: GateReader
    private let holds: PRHoldStore
    private let scratch: (prDir: String, gateWorktrees: String)
    private let openSignIn: @MainActor () -> Void
    private let sleep: @Sendable () async -> Void
    /// Same follow-up as `truectl pr merge`: the one background gate on main after a merge.
    private let mainGate: @Sendable (PRContext) -> Void
    /// Set after this screen merged the PR: the line then says so instead of offering Create PR again.
    private var merged: String?
    private var repo: String?
    private var facts: PRFacts?
    private var gatedSha = ""
    private var actionNote: String?
    private var busyClicked = false
    private var tick: Task<Void, Never>?
    private var gateRun: Task<Void, Never>?

    init(folder: String, branch: String, name: String, resultFile: String? = nil,
         runner: PRRunner = .live, gates: GateReader = GateReader(), holds: PRHoldStore = PRHoldStore(),
         prDir: String = NSHomeDirectory() + "/.true/pr", gateWorktrees: String = NSHomeDirectory() + "/.true/pr-gate",
         openSignIn: @escaping @MainActor () -> Void = TaskPRModel.openSignInTab,
         sleep: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) },
         mainGate: @escaping @Sendable (PRContext) -> Void = { ctx in Task.detached { await PRMainGate.run(ctx: ctx) } }) {
        self.folder = folder; self.branch = branch; self.name = name; self.resultFile = resultFile
        self.runner = runner; self.gates = gates; self.holds = holds; self.scratch = (prDir, gateWorktrees); self.openSignIn = openSignIn; self.sleep = sleep
        self.mainGate = mainGate
    }

    private func context() -> PRContext? {
        guard let repo else { return nil }
        var ctx = PRContext(repoDir: folder, repo: repo, holds: holds)
        ctx.runner = runner; ctx.gates = gates
        ctx.prDir = scratch.prDir; ctx.gateWorktrees = scratch.gateWorktrees
        ctx.gateLock = PRGateLock()
        return ctx
    }

    // MARK: Load

    /// Signed in? Then the branch's PR, the Hold, the gate files. Never throws; a problem becomes plain text on the line.
    func load() async {
        let probe = await PRPreflight.check(runner: runner, cwd: folder)
        let head = await git(["rev-parse", "HEAD"]).trimmed
        let commits = await git(["log", "--format=%H", "-n", "50", "origin/main..HEAD"]).out
            .split(whereSeparator: \.isNewline).map(String.init)
        func make(signedIn: Bool, facts: PRFacts?, hold: HoldEntry?, problem: String? = nil) -> TaskPRState {
            var s = TaskPRState.make(signedIn: signedIn, headSha: facts?.headSha ?? head, commits: commits, facts: facts,
                                     gatedSha: gatedSha, gates: gates, hold: hold, gateRunningFor: state?.gateRunningFor,
                                     gateBusyClicked: busyClicked)
            s.problem = problem
            if let actionNote, problem == nil, s.gateRunningFor == nil { s.note = actionNote }
            return s
        }
        if let probe {
            facts = nil
            state = make(signedIn: probe != PRCopy.signedOut, facts: nil, hold: nil, problem: probe == PRCopy.signedOut ? nil : probe)
            return
        }
        let slug = await git(["remote", "get-url", "origin"])
        guard slug.ok, let repo = prRepoSlug(fromRemote: slug.trimmed) else { state = nil; return }
        self.repo = repo
        guard let ctx = context() else { return }
        let found = await ctx.gh(["pr", "list", "--state", "open", "--head", branch, "--json", "number"])
        guard found.ok else { state = make(signedIn: true, facts: nil, hold: nil, problem: PRCopy.ghFailure(found, other: "Could not load PRs.")); return }
        struct Item: Decodable { let number: Int }
        guard let items = try? JSONDecoder().decode([Item].self, from: Data(found.out.utf8)) else {
            state = make(signedIn: true, facts: nil, hold: nil, problem: "Could not load PRs."); return
        }
        guard let number = items.first?.number else {
            facts = nil; gatedSha = ""
            state = make(signedIn: true, facts: nil, hold: nil, problem: merged); return
        }
        let (view, why) = await PRView.read(number, ctx: ctx)
        guard let view else { state = make(signedIn: true, facts: nil, hold: nil, problem: why); return }
        let (behind, behindWhy) = await PRView.behindMain(view.headSha, ctx: ctx)
        guard let behind else { state = make(signedIn: true, facts: nil, hold: nil, problem: behindWhy); return }
        let f = PRFacts(number: number, headSha: view.headSha, state: view.state, isDraft: view.isDraft,
                        baseRef: view.baseRef, behindMain: behind)
        facts = f
        // The commit this screen showed with its gate result: a merge later must still be on this head.
        gatedSha = gates.result(f.headSha) != nil ? f.headSha : ""
        state = make(signedIn: true, facts: f, hold: ctx.held(number))
        busyClicked = false
    }

    private func git(_ args: [String]) async -> PRRun {
        await runner.run(PRCommand(tool: .git, args: args, cwd: folder, timeout: 15))
    }

    // MARK: Buttons

    func createPR() {
        Task {
            guard let ctx = context() else { return }
            let task = PRTask(name: name, folder: folder, branch: branch, resultFile: resultFile)
            switch await PRCreate.run(task: task, ctx: ctx) {
            case .created, .alreadyOpen: actionNote = nil
            case .refused(let why): actionNote = why
            }
            await load()
        }
    }

    func merge() {
        Task {
            guard let ctx = context(), let facts, state?.mergeEnabled == true else { return }
            let out = await PRMergeFlow.run(number: facts.number, gatedSha: gatedSha, ctx: ctx, mainGate: mainGate)
            if let t = out.toast { actionNote = nil; merged = t } else { actionNote = out.refusal }
            await load()
        }
    }

    /// One click, no reason asked.
    func toggleHold() {
        guard let repo, let n = facts?.number else { return }
        let ok = state?.held == true ? holds.release(repo: repo, number: n) : holds.hold(repo: repo, number: n, why: "")
        actionNote = ok ? nil : "Could not save the Hold."
        Task { await load() }
    }

    /// Runs the gate on the PR head (or this branch's head when there is no PR yet). The clock below exists only until it returns.
    func runGate() {
        guard gateRun == nil, let ctx = context(), state?.gateButtonEnabled == true else { return }
        actionNote = nil; busyClicked = false
        state?.gateRunningFor = 0
        state?.note = nil
        let facts = facts, folder = folder
        tick = Task { [weak self, sleep] in
            while !Task.isCancelled {
                await sleep()
                if Task.isCancelled { break }
                guard let self, let n = self.state?.gateRunningFor else { break }
                self.state?.gateRunningFor = n + 1
            }
        }
        gateRun = Task { [weak self] in
            let error: String
            if let facts {
                error = await PRGate.runForPR(facts.number, ctx: ctx).error
            } else {
                // No PR yet: the commit is already in this repo, so "fetching" it is just a presence check.
                let sha = await ctx.git(["rev-parse", "HEAD"], in: folder).trimmed
                error = await PRGate.run(sha: sha, fetch: ["cat-file", "-e", "\(sha)^{commit}"], ctx: ctx).error
            }
            guard let self else { return }
            self.tick?.cancel(); self.tick = nil; self.gateRun = nil
            self.state?.gateRunningFor = nil
            self.busyClicked = error == PRGate.busy
            self.actionNote = error.isEmpty || error == PRGate.busy ? nil : error
            await self.load()
        }
    }

    func signIn() { openSignIn() }

    /// Closing the screen stops the clock. The gate itself keeps going and writes its result file.
    func stop() { tick?.cancel(); tick = nil }

    /// Same mechanism as the Accounts screen: a new tab running the CLI's own login.
    static let openSignInTab: @MainActor () -> Void = {
        let ws = WorkspaceModel.shared
        let pane = ws.openShellTab(cwd: NSHomeDirectory())
        if let i = ws.tabIndex(containing: pane) { ws.rename(tab: ws.state.tabs[i].id, to: "Sign in · GitHub") }
        PaneStartup.shared.set(GitHubSignIn.shellCommand(executable: ProgramFinder.shared.resolve("gh")), for: pane)
        NSApp.activate(ignoringOtherApps: true)
    }
}
