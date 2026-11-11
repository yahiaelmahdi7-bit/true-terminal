import Foundation

/// Plain words for the Pull requests list and the review view. Nothing here is a code, id or raw error.
/// Gate words, Merge / Hold / Run gate and every refusal come from `TaskPRCopy`, `PRCopy` and the merge core.
enum PRScreenCopy {
    static let title = "Pull requests"
    static let loading = "Loading PRs…", empty = "No open PRs.", newest50 = "Showing the newest 50."
    static let loadFailed = "Could not load PRs."
    static func lastList(_ time: String) -> String { "Showing the last list from \(time)." }
    static let loadingDiff = "Loading diff…", diffTooLarge = "Diff too large. Open on GitHub."
    static let openOnGitHub = "Open on GitHub", updateBranch = "Update branch"
    /// Fork / branch not on origin: Update branch cannot work here (shown after a try).
    static let noCleanCopy = "Can't update here: no clean local copy. Update it on GitHub."
    static let dirtyCopy = "Can't update: your local copy has uncommitted changes."
    /// The merge rule's refusal while behind main (PRMerge.swift); the Update lines below replace it.
    static let updateFirst = "Update the branch first."
    static let back = "Pull requests"
}

// MARK: List

/// What the Pull requests list shows. Rows come from `PRList` (gate word, author, Held); this only decides which
/// sentence goes with them.
struct PRListState: Equatable {
    enum Phase: Equatable { case loading, signedOut, loaded, failed(String) }
    var phase: Phase
    var rows: [PRRow] = []
    /// When `rows` was last read fine (kept in memory only); drives "Showing the last list from <time>.".
    var cachedAt: Date? = nil
    var time: (Date) -> String = { UsageText.clock($0) }

    static func == (a: Self, b: Self) -> Bool { a.phase == b.phase && a.rows == b.rows && a.cachedAt == b.cachedAt }

    /// `gh pr list` stops at 50.
    var over50: Bool { rows.count >= 50 }
    var showsRows: Bool { (phase == .loaded || failedWithCache) && !rows.isEmpty }
    private var failedWithCache: Bool { if case .failed = phase { return cachedAt != nil } else { return false } }
    var showsSignIn: Bool { phase == .signedOut }
    /// The Held column exists only when some row is held; otherwise the gate word sits on the right margin.
    var anyHeld: Bool { showsRows && rows.contains { $0.held } }

    /// The one line above or in place of the rows: loading, empty, or why the list is old.
    var message: String? {
        switch phase {
        case .loading: return PRScreenCopy.loading
        case .signedOut: return PRCopy.signedOut
        case .loaded: return rows.isEmpty ? PRScreenCopy.empty : nil
        case .failed(let why): return why
        }
    }
    var secondLine: String? {
        if case .failed = phase, let at = cachedAt { return PRScreenCopy.lastList(time(at)) }
        return nil
    }
    var footer: String? { showsRows && over50 ? PRScreenCopy.newest50 : nil }

    /// Everything a person can read (the tests check it for raw names).
    var visibleStrings: [String] {
        var out = [PRScreenCopy.title]
        if let m = message { out.append(m) }
        if let s = secondLine { out.append(s) }
        if showsSignIn { out.append(TaskPRCopy.signIn) }
        if showsRows { for r in rows { out += PRRowLine(r).strings } }
        if let f = footer { out.append(f) }
        return out
    }
}

/// One list row: title · author · +/− · gate word · Held pill.
struct PRRowLine: Equatable {
    let title: String, author: String, added: String, removed: String, gate: String, held: Bool
    init(_ row: PRRow) {
        title = row.title; author = row.author
        added = "+\(row.additions)"; removed = "−\(row.deletions)"
        gate = row.gate; held = row.held
    }
    var strings: [String] { [title, author, added, removed, gate] + (held ? [TaskPRCopy.held] : []) }
}

// MARK: Diff

/// What one visible diff row is. Raw git text (`diff --git`, `index`, `---`/`+++`, modes, renames, "No newline") is never a row.
enum PRDiffKind: Equatable, Sendable { case file, hunk, added, removed, context }
/// `file`: text = the path, `added`/`removed` = its counts. `hunk`: text = only the text after the second `@@` (may be empty).
struct PRDiffLine: Equatable, Sendable {
    var text: String; var kind: PRDiffKind; var added = 0; var removed = 0
}

enum PRDiff {
    /// Turns a unified diff into rows a person can read: one file row per file (path + counts), one dim line per hunk,
    /// then context / +/- lines. Only `+` and `-` lines inside a hunk are +/- (a removed `--- x` inside a hunk is still removed).
    static func lines(_ text: String) -> [PRDiffLine] {
        var out: [PRDiffLine] = []
        var inHunk = false
        var fileAt: Int?
        var oldPath = "", newPath = "", renameFrom: String?, renameTo: String?, deleted = false

        func strip(_ p: Substring, _ prefix: String) -> String { p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : String(p) }
        func path() -> String {
            if let f = renameFrom, let t = renameTo { return "\(f) → \(t)" }
            return deleted || newPath.isEmpty ? (oldPath.isEmpty ? newPath : oldPath) : newPath
        }
        func sync() { if let i = fileAt { out[i].text = path() } }

        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        for sub in all.dropLast(text.hasSuffix("\n") ? 1 : 0) {
            let line = String(sub)
            if line.hasPrefix("diff --git ") {
                inHunk = false; renameFrom = nil; renameTo = nil; deleted = false; oldPath = ""; newPath = ""
                // "diff --git a/P b/P": take what follows the last " b/" (paths with spaces still land right for the common case).
                if let r = line.range(of: " b/", options: .backwards) { newPath = String(line[r.upperBound...]) }
                out.append(PRDiffLine(text: path(), kind: .file)); fileAt = out.count - 1
                continue
            }
            if line.hasPrefix("@@") {
                inHunk = true
                let rest = line.dropFirst(2)
                let ctx = rest.range(of: "@@").map { String(rest[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
                out.append(PRDiffLine(text: ctx, kind: .hunk)); continue
            }
            guard inHunk else {
                // File header lines: only used to get the right path; never shown.
                if line.hasPrefix("rename from ") { renameFrom = String(line.dropFirst(12)) }
                else if line.hasPrefix("rename to ") { renameTo = String(line.dropFirst(10)) }
                else if line.hasPrefix("deleted file mode") { deleted = true }
                else if line.hasPrefix("--- ") { let p = line.dropFirst(4); if p != "/dev/null" { oldPath = strip(p, "a/") } }
                else if line.hasPrefix("+++ ") { let p = line.dropFirst(4); if p != "/dev/null" { newPath = strip(p, "b/") } }
                sync(); continue
            }
            switch line.first {
            case "+": out.append(PRDiffLine(text: line, kind: .added)); if let i = fileAt { out[i].added += 1 }
            case "-": out.append(PRDiffLine(text: line, kind: .removed)); if let i = fileAt { out[i].removed += 1 }
            case "\\": continue
            default: out.append(PRDiffLine(text: line, kind: .context))
            }
        }
        return out
    }
}

// MARK: Local copy (for Update branch)

/// The PR's own worktree: none (GitHub only, or a peer Mac), one with uncommitted work, or a clean one.
enum PRLocalCopy: Equatable, Sendable { case none, dirty, clean(path: String) }

enum PRWorktrees {
    /// Path of the worktree that has `branch` checked out, from `git worktree list --porcelain`.
    static func path(branch: String, porcelain: String) -> String? {
        var path: String?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            else if line == "branch refs/heads/\(branch)", let path { return path }
            else if line.isEmpty { path = nil }
        }
        return nil
    }

    static func probe(branch: String, ctx: PRContext) async -> PRLocalCopy {
        let list = await ctx.git(["worktree", "list", "--porcelain"])
        guard list.ok, let p = path(branch: branch, porcelain: list.out), FileManager.default.fileExists(atPath: p) else { return .none }
        let clean = await ctx.git(["status", "--porcelain"], in: p).trimmed.isEmpty
        return clean ? .clean(path: p) : .dirty
    }
}

// MARK: Review

/// What the review view shows. The buttons, the primary and every refusal line come from `TaskPRState`
/// (the same type the task screen's PR line uses); this adds the diff, Open on GitHub and Update branch.
struct PRReviewState: Equatable, Sendable {
    enum Body: Equatable, Sendable { case loading, diff([PRDiffLine]), tooLarge, couldNotLoad }
    var number: Int
    var title: String
    var author: String
    var additions: Int, deletions: Int
    var body: Body
    /// nil until the PR was read (loading, or could not load): then there are no PR buttons.
    var pr: TaskPRState?
    /// The head is behind main (from the merge core's facts).
    var behind: Bool
    var local: PRLocalCopy
    /// The result of the last Update branch ("Can't update: conflicts in 2 files."); nil = none or it worked.
    var updateNote: String?
    var updating = false

    static func make(row: PRRow, facts: PRFacts?, commits: [String] = [], gates: GateReader, hold: HoldEntry?,
                     signedIn: Bool = true, gateRunningFor: Int? = nil, gatedSha: String? = nil, body: Body,
                     local: PRLocalCopy = .none, updateNote: String? = nil, updating: Bool = false) -> Self {
        let pr = body == .couldNotLoad ? nil
            : TaskPRState.make(signedIn: signedIn, headSha: row.head, commits: commits, facts: facts, gatedSha: gatedSha ?? row.head,
                               gates: gates, hold: hold, gateRunningFor: gateRunningFor)
        return Self(number: row.number, title: row.title, author: row.author, additions: row.additions, deletions: row.deletions,
                    body: body, pr: pr, behind: facts?.behindMain ?? false, local: local, updateNote: updateNote, updating: updating)
    }

    var showsButtons: Bool { pr?.showsMerge == true }
    var openEnabled: Bool { true }
    /// Offered when the head is behind main and the PR's own worktree is clean OR there is none (a temporary copy does it).
    var showsUpdate: Bool { showsButtons && behind && local != .dirty }
    /// Behind main, a worktree exists, but it has uncommitted work: no button, and the plain reason.
    var noCleanCopy: Bool { showsButtons && behind && local == .dirty }
    var updateEnabled: Bool { showsUpdate && !updating && pr?.gateRunningFor == nil }

    /// Buttons from `TaskPRState`; Update branch takes the strong fill when it is the next step (behind main, nothing running).
    /// After "Can't update: conflicts" no button is bright: a retry would hit the same conflicts.
    var primary: TaskPRPrimary { updateNote != nil ? .none : (pr?.primary ?? .none) }
    /// The one bright button on the review view. Behind main with no clean local copy, a re-run gate fixes nothing, so GitHub is next.
    enum Shown: Equatable, Sendable { case merge, update, runGate, release, openOnGitHub, signIn, none }
    var shown: Shown {
        if pr?.showsSignIn == true { return .signIn }
        if (noCleanCopy || updateNote == PRScreenCopy.noCleanCopy) && pr?.held != true && pr?.mergeEnabled != true { return .openOnGitHub }
        if updateIsPrimary { return .update }
        switch primary {
        case .merge: return .merge
        case .runGate: return .runGate
        case .release: return .release
        default: return .none
        }
    }
    var updateIsPrimary: Bool { updateNote == nil && updateEnabled && pr?.mergeEnabled != true && pr?.held != true }
    /// The one word beside the title: the gate word, or "Gate running… m:ss" IN PLACE of it (never both).
    var gateText: String? {
        guard let pr else { return nil }
        if let s = pr.gateRunningFor { return TaskPRCopy.gateRunning(s) }
        return pr.gate.rawValue
    }

    /// Lines under the buttons: the rule's refusal, then the Update branch line.
    var notes: [String] {
        var out: [String] = []
        let update = updateNote ?? (noCleanCopy ? PRScreenCopy.dirtyCopy : nil)
        // One line: the Update result replaces "Update the branch first." (other refusals, e.g. held or red, stay).
        if let n = pr?.note, !(update != nil && n == PRScreenCopy.updateFirst) { out.append(n) }
        if let u = update { out.append(u) }
        return out
    }

    var visibleStrings: [String] {
        var out = [PRScreenCopy.back, TaskPRCopy.pr(number), title, author, "+\(additions)", "−\(deletions)"]
        if let pr {
            if let g = gateText { out.append(g) }
            if pr.held { out.append(TaskPRCopy.held) }
            if pr.showsPRControls { out += [TaskPRCopy.merge, TaskPRCopy.runGate, pr.holdLabel] }
            if showsUpdate { out.append(PRScreenCopy.updateBranch) }
            if pr.showsSignIn || pr.problem != nil { out += pr.visibleStrings }
        }
        switch body {
        case .loading: out.append(PRScreenCopy.loadingDiff)
        case .tooLarge: out.append(PRScreenCopy.diffTooLarge)
        case .couldNotLoad: out.append(PRCopy.notLoaded)
        case .diff(let lines): out += lines.flatMap { $0.kind == .file ? [$0.text, "+\($0.added)", "−\($0.removed)"] : [$0.text] }
        }
        out.append(PRScreenCopy.openOnGitHub)
        out += notes
        return out
    }
}

extension PRLocalCopy { var isClean: Bool { if case .clean = self { return true } else { return false } } }
