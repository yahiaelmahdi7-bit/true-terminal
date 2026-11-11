import AppKit
import Observation

/// The Pull requests screen: the list, the open review, and every button. It only sequences core calls
/// (`PRList`, `PRView`, `prMerge`, `PRPostMerge`, `PRGate`, `PRHoldStore`, `PRUpdate`); no PR rule lives here.
/// Refresh runs on open, when the window gains focus, and every 60 s while the screen is visible. Hidden = no polling.
@MainActor @Observable
final class PRScreenModel {
    private(set) var list = PRListState(phase: .loading)
    /// nil = the list is showing.
    private(set) var review: PRReviewState?
    /// Is the Pull requests screen on screen? Only then does the 60 s refresh run.
    private(set) var visible = false

    static let refreshEvery: Double = 60

    private let folder: String
    private let runner: PRRunner
    private let gates: GateReader
    private let holds: PRHoldStore
    private let scratch: (prDir: String, gateWorktrees: String)
    private let sleep: @Sendable (Double) async -> Void
    private let now: () -> Date
    private let open: @MainActor (URL) -> Void
    private let toast: @MainActor (String) -> Void
    private let signInTab: @MainActor () -> Void
    /// Same follow-up as `truectl pr merge`: the one background gate on main after a merge.
    private let mainGate: @Sendable (PRContext) -> Void

    private var repo: String?
    private var timer: Task<Void, Never>?
    private var loading = false
    private var tick: Task<Void, Never>?

    // The open review's parts (the state itself is rebuilt from them).
    private var row: PRRow?
    private var facts: PRFacts?
    private var gatedSha = ""
    private var body: PRReviewState.Body = .loading
    private var local: PRLocalCopy = .none
    private var updateNote: String?
    private var actionNote: String?
    private var updating = false
    private var gateRunningFor: Int?

    init(folder: String, runner: PRRunner = .live, gates: GateReader = GateReader(), holds: PRHoldStore = PRHoldStore(),
         prDir: String = NSHomeDirectory() + "/.true/pr", gateWorktrees: String = NSHomeDirectory() + "/.true/pr-gate",
         sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         now: @escaping () -> Date = Date.init,
         open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
         toast: @escaping @MainActor (String) -> Void = { TrayPanelController.shared.showToast($0) },
         signInTab: @escaping @MainActor () -> Void = TaskPRModel.openSignInTab,
         mainGate: @escaping @Sendable (PRContext) -> Void = { ctx in Task.detached { await PRMainGate.run(ctx: ctx) } }) {
        self.folder = folder; self.runner = runner; self.gates = gates; self.holds = holds
        self.scratch = (prDir, gateWorktrees); self.sleep = sleep; self.now = now
        self.open = open; self.toast = toast; self.signInTab = signInTab; self.mainGate = mainGate
    }

    // MARK: Visible + refresh

    /// The screen appeared / disappeared. Appearing loads once and starts the 60 s beat; hiding stops it.
    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        timer?.cancel(); timer = nil
        guard on else { return }
        timer = Task { [weak self] in
            await self?.load()
            while !Task.isCancelled {
                guard let self else { return }
                await self.sleep(Self.refreshEvery)
                if Task.isCancelled { return }
                await self.load()
            }
        }
    }

    /// The window became active again: read the list now (only while the screen is showing).
    func refreshOnFocus() async {
        guard visible else { return }
        await load()
    }

    func signIn() { signInTab() }

    // MARK: List

    /// Never throws. A failure keeps the last rows and says so ("Showing the last list from <time>.").
    func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        if let probe = await PRPreflight.check(runner: runner, cwd: folder) {
            list.phase = probe == PRCopy.signedOut ? .signedOut : .failed(probe)
            return
        }
        guard let ctx = await context() else { list.phase = .failed(PRScreenCopy.loadFailed); return }
        let result = await PRList.load(ctx: ctx)
        if let rows = result.rows {
            list.rows = rows; list.cachedAt = now(); list.phase = .loaded
        } else {
            list.phase = .failed(result.error)
        }
    }

    private func context() async -> PRContext? {
        if repo == nil {
            let r = await runner.run(PRCommand(tool: .git, args: ["remote", "get-url", "origin"], cwd: folder, timeout: 15))
            guard r.ok else { return nil }
            repo = prRepoSlug(fromRemote: r.trimmed)
        }
        guard let repo else { return nil }
        var ctx = PRContext(repoDir: folder, repo: repo, holds: holds)
        ctx.runner = runner; ctx.gates = gates
        ctx.prDir = scratch.prDir; ctx.gateWorktrees = scratch.gateWorktrees
        ctx.gateLock = PRGateLock.shared
        return ctx
    }

    // MARK: Review

    func openReview(_ r: PRRow) async {
        row = r; facts = nil; gatedSha = ""; body = .loading; local = .none
        updateNote = nil; actionNote = nil; updating = false; gateRunningFor = nil
        rebuild()
        await loadReview(diff: true)
    }

    func back() {
        tick?.cancel(); tick = nil
        review = nil; row = nil
        Task { await load() }
    }

    /// Reads the PR again (head, behind main, local copy, Hold) and, when asked, its diff.
    private func loadReview(diff: Bool) async {
        guard let r = row, let ctx = await context() else { return }
        let (view, _) = await PRView.read(r.number, ctx: ctx)
        guard let view else { facts = nil; body = .couldNotLoad; rebuild(); return }
        let (behind, _) = await PRView.behindMain(view.headSha, ctx: ctx)
        guard let behind else { facts = nil; body = .couldNotLoad; rebuild(); return }
        let f = PRFacts(number: r.number, headSha: view.headSha, state: view.state, isDraft: view.isDraft,
                        baseRef: view.baseRef, behindMain: behind)
        facts = f
        gatedSha = gates.result(f.headSha) != nil ? f.headSha : ""
        local = await PRWorktrees.probe(branch: r.headRef, ctx: ctx)
        if diff || body == .couldNotLoad {
            let d = await ctx.gh(["pr", "diff", String(r.number)], timeout: 30, maxBytes: 1_000_000)
            if d.truncated { body = .tooLarge }
            else if d.ok { body = .diff(PRDiff.lines(d.out)) }
            else { body = .couldNotLoad }
        }
        rebuild()
    }

    private func rebuild() {
        guard let r = row else { review = nil; return }
        let hold = repo.flatMap { holds.entry(repo: $0, number: r.number) }
        var s = PRReviewState.make(row: r, facts: facts, commits: r.commits, gates: gates, hold: hold, gateRunningFor: gateRunningFor,
                                   gatedSha: gatedSha, body: body, local: local, updateNote: updateNote, updating: updating)
        if let n = actionNote, s.pr != nil, s.pr?.gateRunningFor == nil { s.pr?.note = n }
        review = s
    }

    // MARK: Buttons

    /// The PR's own page; no url in the list JSON -> `gh pr view <n> --web`.
    func openOnGitHub() {
        guard let r = row else { return }
        if !r.url.isEmpty, let url = URL(string: r.url) { open(url); return }
        let runner = runner, folder = folder
        Task { _ = await runner.run(PRCommand(tool: .gh, args: ["pr", "view", String(r.number), "--web"], cwd: folder, timeout: 15)) }
    }

    func update() async {
        guard let r = row, review?.updateEnabled == true, !updating, let ctx = await context() else { return }
        updating = true; updateNote = nil; rebuild()
        var path: String?
        if case .clean(let p) = local { path = p }
        let result = await PRUpdate.run(branch: r.headRef, worktree: path, ctx: ctx)
        updating = false; updateNote = result
        guard result == nil else { rebuild(); return }
        // It worked: the head moved, so the row, the diff and the gate word are read again (the new head needs a gate).
        await load()
        if let fresh = list.rows.first(where: { $0.number == r.number }) { row = fresh }
        await loadReview(diff: true)
    }

    func merge() async {
        guard let ctx = await context(), let facts, review?.pr?.mergeEnabled == true else { return }
        // The shared flow (also TaskPRModel's): core re-reads the PR, merges, fast-forwards local main, starts the main gate.
        let out = await PRMergeFlow.run(number: facts.number, gatedSha: gatedSha, ctx: ctx, mainGate: mainGate)
        if let t = out.toast {
            toast(t)
            actionNote = nil; row = nil; review = nil
            await load()
        } else {
            actionNote = out.refusal
            await loadReview(diff: false)
        }
    }

    /// One click, no reason asked.
    func toggleHold() async {
        guard let repo, let n = facts?.number else { return }
        let ok = review?.pr?.held == true ? holds.release(repo: repo, number: n) : holds.hold(repo: repo, number: n, why: "")
        actionNote = ok ? nil : "Could not save the Hold."
        await loadReview(diff: false)
        await load()
    }

    /// Runs the gate on the PR head. The clock exists only until it returns.
    func runGate() async {
        guard tick == nil, let ctx = await context(), let facts, review?.pr?.gateButtonEnabled == true else { return }
        actionNote = nil
        gateRunningFor = 0; rebuild()
        tick = Task { [weak self, sleep] in
            while !Task.isCancelled {
                await sleep(1)
                if Task.isCancelled { break }
                guard let self, let n = self.gateRunningFor else { break }
                self.gateRunningFor = n + 1; self.rebuild()
            }
        }
        let error = await PRGate.runForPR(facts.number, ctx: ctx).error
        tick?.cancel(); tick = nil
        gateRunningFor = nil
        actionNote = error.isEmpty || error == PRGate.busy ? nil : error
        await loadReview(diff: false)
        await load()
    }
}
