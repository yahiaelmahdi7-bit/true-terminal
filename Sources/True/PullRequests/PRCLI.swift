import Foundation

/// One `truectl pr ...` request off the control socket. `from` is `$TRUE_AGENT`: advisory, marks agent vs person.
struct PRRequest: Equatable, Sendable {
    var verb: String
    var number: Int?
    var sha: String?
    var why: String?
    var branch: String?
    var task: String?
    var cwd: String?
    var from: String?
}

/// Everything the verbs reach for, injectable. `live` uses the real runner and files.
struct PRControlEnv: Sendable {
    var runner: PRRunner = .live
    var gates = GateReader()
    var holds = PRHoldStore()
    var prDir = NSHomeDirectory() + "/.true/pr"
    var gateWorktrees = NSHomeDirectory() + "/.true/pr-gate"
    /// The task row for `--task <id>`, or the builder whose branch is `branch`.
    var task: @Sendable (_ id: String?, _ branch: String?) async -> PRTask? = { _, _ in nil }
    /// Starts the one background gate on `origin/main` after a merge. Tests record the call.
    var mainGate: @Sendable (PRContext) -> Void = { ctx in Task.detached { await PRMainGate.run(ctx: ctx) } }
    var gateLock = PRGateLock.shared

    /// The real thing: tasks come from the Hub's builder records.
    static let live: PRControlEnv = {
        var env = PRControlEnv()
        env.task = { id, branch in
            await MainActor.run {
                let b = HubStore.shared.builders.first {
                    (id != nil && ($0.id == id || $0.name == id)) || (id == nil && branch != nil && $0.branch == branch)
                }
                return b.map { PRTask(name: $0.name, folder: $0.worktree ?? $0.cwd, branch: $0.branch,
                                      resultFile: $0.dir.map { $0 + "/result.md" }) }
            }
        }
        return env
    }()
}

enum PRControl {
    static let usage = "usage: truectl pr create|list|merge|gate|hold"

    static func handle(_ req: PRRequest, env: PRControlEnv = .live) async -> ControlResponse {
        guard let cwd = req.cwd, !cwd.isEmpty else { return .failure("Run truectl pr from inside the repo.") }
        // Hold and Release touch no GitHub and need no sign-in.
        switch req.verb {
        case "release":
            // A flag an agent can type is not a brake: release is app-only, always.
            return .failure(PRCopy.releaseRefused)
        case "hold":
            guard let n = req.number else { return .failure(usage) }
            guard let repo = await repoSlug(cwd: cwd, env: env) else { return .failure("This folder is not a GitHub repo.") }
            guard env.holds.hold(repo: repo, number: n, why: req.why ?? "") else { return .failure("Could not save the Hold.") }
            return ControlResponse(ok: true, outcome: "Held PR #\(n)")
        default: break
        }
        if let problem = await PRPreflight.check(runner: env.runner, cwd: cwd) { return .failure(problem) }
        guard let repo = await repoSlug(cwd: cwd, env: env) else { return .failure("This folder is not a GitHub repo.") }
        var ctx = PRContext(repoDir: cwd, repo: repo, holds: env.holds)
        ctx.runner = env.runner; ctx.gates = env.gates; ctx.prDir = env.prDir
        ctx.gateWorktrees = env.gateWorktrees; ctx.gateLock = env.gateLock
        switch req.verb {
        case "list": return await list(ctx: ctx)
        case "create": return await create(req, ctx: ctx, env: env)
        case "merge": return await merge(req, ctx: ctx, env: env)
        case "gate":
            guard let n = req.number else { return .failure(usage) }
            let (word, error) = await PRGate.runForPR(n, ctx: ctx)
            guard let word else { return .failure(error) }
            return ControlResponse(ok: true, outcome: word.rawValue)
        default: return .failure(usage)
        }
    }

    private static func repoSlug(cwd: String, env: PRControlEnv) async -> String? {
        let r = await env.runner.run(PRCommand(tool: .git, args: ["remote", "get-url", "origin"], cwd: cwd, timeout: 10))
        return r.ok ? prRepoSlug(fromRemote: r.trimmed) : nil
    }

    private static func list(ctx: PRContext) async -> ControlResponse {
        let (rows, error) = await PRList.load(ctx: ctx)
        guard let rows else { return .failure(error) }
        return ControlResponse(ok: true, prs: rows)
    }

    private static func create(_ req: PRRequest, ctx: PRContext, env: PRControlEnv) async -> ControlResponse {
        var task = await env.task(req.task, req.branch)
        if task == nil {
            if req.task != nil { return .failure("No task with that id.") }
            task = PRTask(name: req.branch ?? "", folder: ctx.repoDir, branch: req.branch, resultFile: nil)
        }
        guard var task else { return .failure(usage) }
        if task.name.isEmpty {
            // Title falls back to the newest commit's subject.
            task.name = await ctx.git(["log", "-1", "--format=%s"], in: task.folder).trimmed
        }
        switch await PRCreate.run(task: task, ctx: ctx) {
        case .created(let n, let url): return ControlResponse(ok: true, outcome: "\(n) \(url)")
        case .alreadyOpen(let n, let url): return .failure("PR #\(n) already open. \(url)")
        case .refused(let why): return .failure(why)
        }
    }

    private static func merge(_ req: PRRequest, ctx: PRContext, env: PRControlEnv) async -> ControlResponse {
        guard let n = req.number else { return .failure(usage) }
        var sha = req.sha
        var note = ""
        if sha == nil {
            // An agent must say which commit it gated, so check 8 is never vacuous.
            if let from = req.from, !from.isEmpty { return .failure("Not merged: pass --sha with the commit you gated.") }
            let (view, why) = await PRView.read(n, ctx: ctx)
            guard let view else { return .failure("Not merged: \(why)") }
            sha = view.headSha
            note = " (head \(view.headSha.prefix(7)))"
        }
        switch await prMerge(number: n, gatedSha: sha ?? "", in: ctx) {
        case .refused(let why): return .failure("Not merged: \(why)")
        case .merged(let m):
            var lines = ["Merged PR #\(m.number)" + note]
            if let local = await PRPostMerge.updateLocalMain(ctx: ctx) { lines.append(local) }
            env.mainGate(ctx)
            return ControlResponse(ok: true, outcome: lines.joined(separator: "\n"))
        }
    }
}
