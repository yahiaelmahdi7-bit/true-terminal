import Foundation

/// A task's place on disk: the folder to push from, its branch, its name, and where its result.md lives.
struct PRTask: Equatable, Sendable {
    var name: String
    var folder: String
    var branch: String?
    var resultFile: String?
}

enum PRCreateResult: Equatable, Sendable {
    case created(number: Int, url: String)
    case refused(String)
    /// An OPEN PR for this branch already exists.
    case alreadyOpen(number: Int, url: String)
}

/// One `pr create` at a time per branch; the second finds the open PR and shows it.
actor PRCreateLock {
    static let shared = PRCreateLock()
    private var active = Set<String>()
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    func enter(_ key: String) async {
        if active.contains(key) { await withCheckedContinuation { waiting[key, default: []].append($0) }; return }
        active.insert(key)
    }
    func leave(_ key: String) {
        if var w = waiting[key], !w.isEmpty { let next = w.removeFirst(); waiting[key] = w; next.resume() }
        else { active.remove(key); waiting[key] = nil }
    }
}

enum PRCreate {
    static func run(task: PRTask, ctx: PRContext, lock: PRCreateLock = .shared) async -> PRCreateResult {
        let dir = task.folder
        let branchRun = await ctx.git(["rev-parse", "--abbrev-ref", "HEAD"], in: dir)
        let branch = task.branch ?? branchRun.trimmed
        guard branchRun.ok || task.branch != nil, !branch.isEmpty, branch != "main", branch != "HEAD" else {
            return .refused("Work is not on its own branch.")
        }
        let key = ctx.repo + "#" + branch
        await lock.enter(key)
        let result = await createLocked(task: task, branch: branch, ctx: ctx)
        await lock.leave(key)
        return result
    }

    private static func openPR(branch: String, ctx: PRContext) async -> (found: (Int, String)?, error: String?) {
        let r = await ctx.gh(["pr", "list", "--state", "open", "--head", branch, "--json", "number,url"])
        guard r.ok else { return (nil, PRCopy.ghFailure(r, other: "Could not load PRs.")) }
        struct W: Decodable { let number: Int; let url: String }
        guard let items = try? JSONDecoder().decode([W].self, from: Data(r.out.utf8)) else { return (nil, "Could not load PRs.") }
        return (items.first.map { ($0.number, $0.url) }, nil)
    }

    private static func createLocked(task: PRTask, branch: String, ctx: PRContext) async -> PRCreateResult {
        let dir = task.folder
        if !(await ctx.git(["status", "--porcelain"], in: dir).trimmed.isEmpty) { return .refused("Commit first.") }
        let existing = await openPR(branch: branch, ctx: ctx)
        if let error = existing.error { return .refused(error) }
        if let (n, url) = existing.found { return .alreadyOpen(number: n, url: url) }

        let sha = await ctx.git(["rev-parse", "HEAD"], in: dir).trimmed
        guard GateReader.isSha(sha) else { return .refused("Work is not on its own branch.") }
        let log = await ctx.git(["log", "--reverse", "--format=%H %s", "origin/main..HEAD"], in: dir)
        let push = await ctx.runner.run(PRCommand(tool: .git, args: ["push", "--set-upstream", "origin", branch], cwd: dir, timeout: 120))
        if !push.ok {
            let text = (push.err + push.out).lowercased()
            if text.contains("rejected") || text.contains("non-fast-forward") || text.contains("fetch first") {
                return .refused("Branch is behind GitHub. Update it first.")
            }
            let line = push.firstLine
            return .refused(push.timedOut || line.isEmpty ? PRCopy.network : "Push failed: \(line).")
        }

        let slug = branch.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let file = "\(ctx.prDir)/\(slug)-\(sha.prefix(7)).md"
        try? FileManager.default.createDirectory(atPath: ctx.prDir, withIntermediateDirectories: true)
        let result = task.resultFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let body = PRDescription.build(result: result, commits: PRDescription.commits(fromLog: log.out), head: sha, gates: ctx.gates)
        guard (try? body.write(toFile: file, atomically: true, encoding: .utf8)) != nil else { return .refused("Could not write the PR text.") }

        let create = await ctx.gh(["pr", "create", "--base", "main", "--head", branch, "--title", task.name, "--body-file", file], timeout: 60)
        guard create.ok else {
            if create.timedOut || create.missing { return .refused("Pushed, but the PR was not created. Try again.") }
            let line = create.firstLine
            return .refused(line.isEmpty ? "Pushed, but the PR was not created. Try again." : "GitHub refused the PR: \(line).")
        }
        // The URL's last component is the number; the view below is the proof.
        let url = create.trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard let number = Int(url.split(separator: "/").last ?? "") else {
            return .refused("Pushed, but the PR was not created. Try again.")
        }
        let view = await ctx.gh(["pr", "view", String(number), "--json", "number,url,headRefOid,state"])
        struct V: Decodable { let number: Int; let url: String; let headRefOid: String; let state: String }
        guard view.ok, let v = try? JSONDecoder().decode(V.self, from: Data(view.out.utf8)) else {
            return .refused("Pushed, but the PR was not created. Try again.")
        }
        guard v.headRefOid == sha else { return .refused("PR opened, but its head is not this commit. Check GitHub.") }
        try? FileManager.default.removeItem(atPath: file)
        return .created(number: number, url: v.url)
    }
}
