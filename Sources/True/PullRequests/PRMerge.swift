import Foundation

/// Fresh from `gh` (plus the behind-main check) right before a merge decision.
struct PRFacts: Equatable, Sendable {
    var number: Int
    var headSha: String
    var state: String
    var isDraft: Bool
    var baseRef: String
    var behindMain: Bool
}

enum PRMergeVerdict: Equatable, Sendable {
    case merge(sha: String)
    case refuse(reason: String)
}

/// The merge rule. Pure: facts in, verdict out. No network, no disk, no model; every input is passed in
/// so each refusal is a unit test. First failure wins; each string is shown as-is.
func prMergeCheck(facts: PRFacts, gatedSha: String, gate: GateResult?, runFileOK: Bool, held: HoldEntry?) -> PRMergeVerdict {
    // 1. open and not a draft
    if facts.state != "OPEN" { return .refuse(reason: "This PR is closed.") }
    if facts.isDraft { return .refuse(reason: "This PR is a draft.") }
    // 2. held (wins over every other policy message)
    if held != nil { return .refuse(reason: PRCopy.held) }
    // 3. against main
    if facts.baseRef != "main" { return .refuse(reason: "This PR is not against main.") }
    // 4. a gate file and its run file exist
    guard let gate, runFileOK else { return .refuse(reason: "No gate result for this commit. Run the gate first.") }
    // 5. the file is for this head
    if gate.commit != facts.headSha { return .refuse(reason: "Gate result belongs to another commit.") }
    // 6. the gate passed
    if !gate.passed {
        var why = gate.reason.isEmpty ? (gate.failed.first ?? "no reason recorded") : gate.reason
        if why.hasSuffix(".") { why.removeLast() }
        return .refuse(reason: "The gate failed: \(why).")
    }
    // 7. the gate ran on committed work
    if gate.dirty { return .refuse(reason: "The gate ran on uncommitted work, so it does not count.") }
    // 8. the head is the one the caller saw gated
    if facts.headSha != gatedSha { return .refuse(reason: "The PR changed after the gate. Run the gate again.") }
    // 9. the head contains current origin/main
    if facts.behindMain { return .refuse(reason: "Update the branch first.") }
    return .merge(sha: facts.headSha)
}

struct PRMerged: Equatable, Sendable {
    var number: Int
    var sha: String
    var branch: String
    /// false = the GitHub branch was left alone (main, base of another PR, a fork, or the delete failed).
    var branchDeleted: Bool
}

enum PRMergeResult: Equatable, Sendable {
    case merged(PRMerged)
    case refused(String)
}

struct PRView: Equatable, Sendable {
    var number: Int
    var state: String
    var isDraft: Bool
    var headSha: String
    var baseRef: String
    var headRef: String
    var isFork: Bool

    static let fields = "number,state,isDraft,headRefOid,baseRefName,headRefName,isCrossRepository"

    static func read(_ n: Int, ctx: PRContext) async -> (PRView?, String) {
        let r = await ctx.gh(["pr", "view", String(n), "--json", fields])
        guard r.ok else { return (nil, PRCopy.ghFailure(r, other: PRCopy.notLoaded)) }
        struct Wire: Decodable {
            let number: Int, state: String, isDraft: Bool, headRefOid: String, baseRefName: String
            let headRefName: String?, isCrossRepository: Bool?
        }
        guard let w = try? JSONDecoder().decode(Wire.self, from: Data(r.out.utf8)) else { return (nil, PRCopy.notLoaded) }
        return (PRView(number: w.number, state: w.state, isDraft: w.isDraft, headSha: w.headRefOid, baseRef: w.baseRefName,
                       headRef: w.headRefName ?? "", isFork: w.isCrossRepository ?? false), "")
    }

    /// `gh api repos/{owner}/{repo}/compare/main...<sha>`: ahead/identical = contains current remote main.
    static func behindMain(_ sha: String, ctx: PRContext) async -> (Bool?, String) {
        let r = await ctx.gh(["api", "repos/{owner}/{repo}/compare/main...\(sha)", "--jq", ".status"])
        guard r.ok else { return (nil, PRCopy.ghFailure(r, other: PRCopy.notLoaded)) }
        return (!["ahead", "identical"].contains(r.trimmed), "")
    }
}

/// The only caller of `gh pr merge`. `truectl pr merge` and the Merge button both end here.
/// Always squash, always pinned to the head the rule checked (`--match-head-commit`); never
/// `--admin`, `--auto`, `--delete-branch` or `--body`.
func prMerge(number: Int, gatedSha: String, in ctx: PRContext) async -> PRMergeResult {
    let (first, why) = await PRView.read(number, ctx: ctx)
    guard let view = first else { return .refused(why) }
    let (behind, behindWhy) = await PRView.behindMain(view.headSha, ctx: ctx)
    guard let behind else { return .refused(behindWhy) }
    let facts = PRFacts(number: number, headSha: view.headSha, state: view.state, isDraft: view.isDraft,
                        baseRef: view.baseRef, behindMain: behind)
    let gate = ctx.gates.result(view.headSha)
    let verdict = prMergeCheck(facts: facts, gatedSha: gatedSha, gate: gate,
                               runFileOK: gate.map(ctx.gates.runFileOK) ?? false, held: ctx.held(number))
    guard case .merge(let sha) = verdict else {
        if case .refuse(let reason) = verdict { return .refused(reason) }
        return .refused(PRCopy.notLoaded)
    }
    // 10. one more look right before merging: the head and the Hold list.
    let (again, _) = await PRView.read(number, ctx: ctx)
    if ctx.held(number) != nil { return .refused(PRCopy.held) }
    guard let again, again.headSha == sha else { return .refused(PRCopy.changedWhileMerging) }
    // 11. merge with the head pinned.
    let merge = await ctx.gh(["pr", "merge", String(number), "--squash", "--match-head-commit", sha], timeout: 60)
    if !merge.ok {
        let (after, _) = await PRView.read(number, ctx: ctx)
        if let after, after.headSha != sha { return .refused(PRCopy.changedWhileMerging) }
        let line = merge.firstLine
        return .refused(merge.timedOut || line.isEmpty ? "GitHub refused the merge." : "GitHub refused the merge: \(line).")
    }
    // Done = verified: GitHub must say MERGED.
    let confirm = await ctx.gh(["pr", "view", String(number), "--json", "state,mergeCommit"])
    struct Done: Decodable { let state: String }
    guard confirm.ok, let done = try? JSONDecoder().decode(Done.self, from: Data(confirm.out.utf8)), done.state == "MERGED" else {
        return .refused("Merge not confirmed. Check GitHub.")
    }
    let deleted = await prDeleteBranch(again, ctx: ctx)
    return .merged(PRMerged(number: number, sha: sha, branch: again.headRef, branchDeleted: deleted))
}

/// Deletes the GitHub branch only. Skips `main`, the base of another open PR, and forks. The local
/// branch and any worktree on it are left to True's cleaner.
func prDeleteBranch(_ view: PRView, ctx: PRContext) async -> Bool {
    let branch = view.headRef
    guard !branch.isEmpty, branch != "main", !view.isFork else { return false }
    let others = await ctx.gh(["pr", "list", "--state", "open", "--base", branch, "--json", "number"])
    guard others.ok, others.trimmed == "[]" else { return false }
    let del = await ctx.gh(["api", "-X", "DELETE", "repos/{owner}/{repo}/git/refs/heads/\(branch)"])
    return del.ok
}
