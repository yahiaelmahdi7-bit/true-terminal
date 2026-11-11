import Foundation

/// Local follow-ups. Never automatic beyond a fast-forward of a clean local `main`.
enum PRPostMerge {
    /// After a merge: bring local `main` forward only if that cannot lose work. nil = updated; else the note to show.
    static func updateLocalMain(ctx: PRContext) async -> String? {
        let fetch = await ctx.git(["fetch", "origin", "main"], timeout: 120)
        guard fetch.ok else { return "Merged. Local main not updated (could not reach GitHub)." }
        let branch = await ctx.git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmed
        let clean = await ctx.git(["status", "--porcelain"]).trimmed.isEmpty
        guard branch == "main", clean else { return "Merged. Local main not updated (it has uncommitted work)." }
        let ff = await ctx.git(["merge", "--ff-only", "origin/main"], timeout: 60)
        return ff.ok ? nil : "Merged. Local main has diverged from GitHub; not updated."
    }
}

/// The one merge sequence, used by the task bar and the Pull requests screen:
/// prMerge (re-reads the PR, applies the rule) -> fast-forward clean local main -> main gate.
/// Exactly one of `toast` (merged; includes the local-main note) / `refusal` (plain sentence) is set.
enum PRMergeFlow {
    static func run(number: Int, gatedSha: String, ctx: PRContext,
                    mainGate: @Sendable (PRContext) -> Void) async -> (toast: String?, refusal: String?) {
        switch await prMerge(number: number, gatedSha: gatedSha, in: ctx) {
        case .merged(let m):
            let local = await PRPostMerge.updateLocalMain(ctx: ctx)
            mainGate(ctx)
            return (TaskPRCopy.merged(m.number, local: local), nil)
        case .refused(let why):
            return (nil, TaskPRCopy.plain(why))
        }
    }
}

/// "Update branch": rebase the PR branch onto `origin/main` and push with a lease.
/// The one allowed exception to "never --force". Never automatic, never merged in the same step.
/// One rule, two places to do it: the PR's own clean worktree (`worktree` given), or, with no local copy
/// (`worktree` nil), a throwaway worktree that is always removed again.
enum PRUpdate {
    static func run(branch: String, worktree: String?, ctx: PRContext) async -> String? {
        if let worktree {
            guard FileManager.default.fileExists(atPath: worktree),
                  await ctx.git(["status", "--porcelain"], in: worktree).trimmed.isEmpty,
                  await ctx.git(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree).trimmed == branch else {
                return "No clean local copy of this branch."
            }
            let old = await ctx.git(["rev-parse", "HEAD"], in: worktree).trimmed
            guard await ctx.git(["fetch", "origin", "main"], in: worktree, timeout: 120).ok else { return PRCopy.network }
            return await rebaseAndPush(branch: branch, old: old, push: branch, in: worktree, ctx: ctx)
        }
        return await runInTempCopy(branch: branch, ctx: ctx)
    }

    /// No local copy: fetch, check out the remote branch in a fresh temp worktree, rebase, push, then remove it.
    /// Touches no local branch, local main or other worktree.
    private static func runInTempCopy(branch: String, ctx: PRContext) async -> String? {
        // A fork PR (or a deleted branch) is not on origin: the plain "update it on GitHub" line. Asked by exit code
        // (2 = no such ref), never by git's message text, which changes with the language.
        let there = await ctx.git(["ls-remote", "--exit-code", "origin", "refs/heads/\(branch)"], timeout: 60)
        if there.code == 2 { return PRScreenCopy.noCleanCopy }
        guard there.ok else { return PRCopy.network }
        guard await ctx.git(["fetch", "origin", "main", branch], timeout: 120).ok else { return PRCopy.network }
        let old = await ctx.git(["rev-parse", "refs/remotes/origin/\(branch)"]).trimmed
        guard !old.isEmpty else { return PRScreenCopy.noCleanCopy }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("true-pr-update-\(UUID().uuidString)").path
        let add = await ctx.git(["worktree", "add", "--detach", tmp, "origin/\(branch)"], timeout: 120)
        var result: String?
        if add.ok {
            result = await rebaseAndPush(branch: branch, old: old, push: "HEAD:refs/heads/\(branch)", in: tmp, ctx: ctx)
        } else {
            result = "Can't update: \(add.firstLine)."
        }
        _ = await ctx.git(["worktree", "remove", "--force", tmp], timeout: 60)
        try? FileManager.default.removeItem(atPath: tmp)   // only if git left the folder behind
        _ = await ctx.git(["worktree", "prune"])
        return result
    }

    private static func rebaseAndPush(branch: String, old: String, push ref: String, in dir: String, ctx: PRContext) async -> String? {
        let rebase = await ctx.git(["rebase", "origin/main"], in: dir, timeout: 120)
        if !rebase.ok {
            let files = await ctx.git(["diff", "--name-only", "--diff-filter=U"], in: dir).trimmed
                .split(whereSeparator: \.isNewline).count
            _ = await ctx.git(["rebase", "--abort"], in: dir)
            return "Can't update: conflicts in \(files) files."
        }
        let push = await ctx.runner.run(PRCommand(tool: .git, args: ["push", "--force-with-lease=\(branch):\(old)", "origin", ref],
                                                  cwd: dir, timeout: 120))
        if push.ok { return nil }
        let line = push.firstLine
        return push.timedOut || line.isEmpty ? PRCopy.network : "Push failed: \(line)."
    }
}
