import Foundation

/// Gate any commit in a fresh detached worktree (a PR head, or `origin/main` after a merge).
/// The result file is keyed by sha, so it counts wherever it ran clean.
enum PRGate {
    static let timeout: TimeInterval = 1_800
    static let busy = "A gate is already running."

    /// `fetch` = the git args that bring `sha` into the repo (`["fetch","origin","pull/7/head"]`).
    /// Returns the gate word for `sha` afterwards, or the plain reason it could not run.
    static func run(sha: String, fetch: [String], ctx: PRContext) async -> (word: GateWord?, error: String) {
        guard GateReader.isSha(sha) else { return (nil, "Could not load this PR.") }
        guard await ctx.gateLock.tryTake() else { return (nil, busy) }
        let result = await runLocked(sha: sha, fetch: fetch, ctx: ctx)
        await ctx.gateLock.release()
        return result
    }

    private static func runLocked(sha: String, fetch: [String], ctx: PRContext) async -> (word: GateWord?, error: String) {
        let fetched = await ctx.git(fetch, timeout: 120)
        guard fetched.ok else { return (nil, fetched.timedOut ? PRCopy.network : "Could not fetch the code to gate.") }
        guard await ctx.git(["cat-file", "-e", "\(sha)^{commit}"]).ok else { return (nil, "Could not fetch the code to gate.") }
        let dir = "\(ctx.gateWorktrees)/\(sha)"
        try? FileManager.default.createDirectory(atPath: ctx.gateWorktrees, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dir) {
            _ = await ctx.git(["worktree", "remove", "--force", dir])
            try? FileManager.default.removeItem(atPath: dir)
        }
        guard await ctx.git(["worktree", "add", "--detach", dir, sha], timeout: 60).ok else {
            return (nil, "Could not set up a clean copy to gate.")
        }
        var failure = ""
        let before = await ctx.git(["rev-parse", "HEAD"], in: dir).trimmed
        if before != sha {
            failure = "The clean copy is not this commit."
        } else {
            _ = await ctx.runner.run(PRCommand(tool: .file(dir + "/scripts/gate.sh"), args: [], cwd: dir, timeout: timeout))
            if await ctx.git(["rev-parse", "HEAD"], in: dir).trimmed != sha { failure = "The clean copy moved while gating." }
        }
        // Always remove the worktree, also on failure.
        _ = await ctx.git(["worktree", "remove", "--force", dir])
        try? FileManager.default.removeItem(atPath: dir)
        if !failure.isEmpty { return (nil, failure) }
        return (ctx.gates.word(head: sha, commits: []), "")
    }

    /// `truectl pr gate <n>`: read the head from GitHub, then gate exactly that commit.
    static func runForPR(_ number: Int, ctx: PRContext) async -> (word: GateWord?, error: String) {
        let (view, why) = await PRView.read(number, ctx: ctx)
        guard let view else { return (nil, why) }
        return await run(sha: view.headSha, fetch: ["fetch", "origin", "pull/\(number)/head"], ctx: ctx)
    }
}

/// What the UI shows later: is `main` red after a merge?
final class PRMainHealth: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case unknown
        case running(sha: String)
        case green(sha: String)
        case red(sha: String, reason: String)
    }
    static let shared = PRMainHealth()
    private let lock = NSLock()
    private var _state = State.unknown
    var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    func set(_ s: State) { lock.lock(); _state = s; lock.unlock() }
    var isRed: Bool { if case .red = state { return true }; return false }
}

/// After a squash merge: gate `origin/main` once, in the background, and record red or green.
/// The squash result is a commit nobody gated; this is how a red `main` gets noticed.
enum PRMainGate {
    static func run(ctx: PRContext, health: PRMainHealth = .shared) async {
        let fetched = await ctx.git(["fetch", "origin", "main"], timeout: 120)
        guard fetched.ok else { return }
        let sha = await ctx.git(["rev-parse", "origin/main"]).trimmed
        guard GateReader.isSha(sha) else { return }
        health.set(.running(sha: sha))
        let (word, error) = await PRGate.run(sha: sha, fetch: ["fetch", "origin", "main"], ctx: ctx)
        switch word {
        case .green: health.set(.green(sha: sha))
        case .red:
            let g = ctx.gates.result(sha)
            health.set(.red(sha: sha, reason: g.map { $0.reason.isEmpty ? ($0.failed.first ?? "gate failed") : $0.reason } ?? "gate failed"))
        default: health.set(error.isEmpty ? .unknown : .red(sha: sha, reason: error))
        }
    }
}
