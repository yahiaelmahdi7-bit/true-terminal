import AppKit
import SwiftUI
import Testing
@testable import True

@Suite struct PRReviewTests {
    static let sha = TaskPRBarTests.sha
    static func row(_ n: Int = 42, title: String = "Add the PR line", ref: String = "builder/pr-line", login: String = "owner",
                    gate: String = "Green", held: Bool = false, add: Int = 40, del: Int = 2) -> PRRow {
        PRRow(number: n, title: title, author: PRList.author(headRef: ref, login: login), headRef: ref, head: sha,
              additions: add, deletions: del, isDraft: false, url: "https://example.test/pr/\(n)", gate: gate, held: held, holdWhy: "")
    }
    static func review(_ gate: GateResult?, behind: Bool = false, local: PRLocalCopy = .none, hold: HoldEntry? = nil,
                       signedIn: Bool = true, body: PRReviewState.Body = .diff([]), updateNote: String? = nil, running: Int? = nil) throws -> PRReviewState {
        PRReviewState.make(row: row(), facts: TaskPRBarTests.facts(behind: behind), gates: try TaskPRBarTests.gates(gate), hold: hold,
                           signedIn: signedIn, gateRunningFor: running, body: body, local: local, updateNote: updateNote)
    }

    // MARK: List

    @Test func listGateWordAndAuthorComeFromPRList() throws {
        let g = try TaskPRBarTests.gates(TaskPRBarTests.pass())
        let json = #"[{"number":42,"title":"T","headRefName":"builder/pr-line","headRefOid":"\#(Self.sha)","author":{"login":"owner"},"commits":[]},{"number":43,"title":"U","headRefName":"fix/x","headRefOid":"\#(Self.sha)","author":{"login":"owner"},"commits":[]}]"#
        let rows = try #require(PRList.rows(json: json, gates: g, held: { $0 == 43 ? TaskPRBarTests.hold : nil }))
        #expect(PRRowLine(rows[0]).gate == "Green" && PRRowLine(rows[0]).author == "pr-line")
        #expect(PRRowLine(rows[1]).author == "owner" && PRRowLine(rows[1]).held)
        #expect(!PRRowLine(rows[0]).held)
        #expect(PRRowLine(rows[0]).strings == ["T", "pr-line", "+0", "−0", "Green"])
        #expect(PRRowLine(rows[1]).strings.last == "Held")
    }

    /// r4: 50 rows in a 450-pt window: the list is capped by its container and the pinned footer stays inside it.
    @MainActor @Test func listHeightIsCappedByTheContainer() throws {
        let fifty = (0..<50).map { Self.row(100 + $0, title: "Sample change \($0 + 1)") }
        #expect(PullRequestsView.rowPitch == 53)
        let view = PullRequestsView(state: PRListState(phase: .loaded, rows: fifty)).frame(width: 720, height: 450)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 450)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height <= 450)
        // Uncapped, 50 rows would be 2650 pt; a short list must still hug its content.
        let short = NSHostingView(rootView: PullRequestsView(state: PRListState(phase: .loaded, rows: Array(fifty.prefix(2)))).frame(width: 720))
        #expect(short.fittingSize.height < 450)
    }

    @Test func listMessages() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [PRReviewTests.row()]
        #expect(PRListState(phase: .loading).message == "Loading PRs…")
        #expect(PRListState(phase: .loaded).message == "No open PRs.")
        #expect(PRListState(phase: .loaded, rows: rows).message == nil)
        #expect(PRListState(phase: .loaded, rows: rows).footer == nil)
        let fifty = PRListState(phase: .loaded, rows: Array(repeating: rows[0], count: 50))
        #expect(fifty.footer == "Showing the newest 50.")
        let failed = PRListState(phase: .failed(PRCopy.network), rows: rows, cachedAt: at, time: { _ in "14:20" })
        #expect(failed.message == "Could not reach GitHub." && failed.secondLine == "Showing the last list from 14:20." && failed.showsRows)
        let bare = PRListState(phase: .failed("Could not load PRs."))
        #expect(bare.secondLine == nil && !bare.showsRows)
        let out = PRListState(phase: .signedOut, rows: rows)
        #expect(out.showsSignIn && !out.showsRows && out.visibleStrings == ["Pull requests", "Not signed in to GitHub.", "Sign in to GitHub"])
    }

    @Test func listTimeUsesTheMacClock() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let s = PRListState(phase: .failed(PRCopy.network), rows: [PRReviewTests.row()], cachedAt: at)
        #expect(s.secondLine == PRScreenCopy.lastList(UsageText.clock(at)))
    }

    // MARK: Diff

    static let rawDiff = """
    diff --git a/a.sql b/a.sql
    index 1111111..2222222 100644
    --- a/a.sql
    +++ b/a.sql
    @@ -1,3 +1,3 @@ select things
     keep
    --- removed comment
    +++ added plus plus
    -old
    +new
    \\ No newline at end of file
    diff --git a/old/name.swift b/new/name.swift
    similarity index 90%
    rename from old/name.swift
    rename to new/name.swift
    index 3333333..4444444 100644
    --- a/old/name.swift
    +++ b/new/name.swift
    @@ -5 +5 @@
    -let a = 1
    +let a = 2
    diff --git a/fresh.txt b/fresh.txt
    new file mode 100644
    index 0000000..5555555
    --- /dev/null
    +++ b/fresh.txt
    @@ -0,0 +1,2 @@
    +one
    +two
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    index 6666666..0000000
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye

    """

    @Test func onlyPlusMinusLinesAreColoured() {
        let lines = PRDiff.lines(Self.rawDiff)
        let kinds = lines.map(\.kind)
        #expect(kinds == [.file, .hunk, .context, .removed, .added, .removed, .added,
                          .file, .hunk, .removed, .added, .file, .hunk, .added, .added, .file, .hunk, .removed])
        // `--- removed comment` inside a hunk is a removed line, not a header.
        #expect(lines[3].text == "--- removed comment" && lines[4].text == "+++ added plus plus")
    }

    @Test func diffHidesRawGitTextAndShowsPathsAndCounts() {
        let lines = PRDiff.lines(Self.rawDiff)
        let files = lines.filter { $0.kind == .file }
        #expect(files.map(\.text) == ["a.sql", "old/name.swift → new/name.swift", "fresh.txt", "gone.txt"])
        #expect(files.map(\.added) == [2, 1, 2, 0] && files.map(\.removed) == [2, 1, 0, 1])
        #expect(lines.filter { $0.kind == .hunk }.map(\.text) == ["select things", "", "", ""])
        let shown = lines.filter { $0.kind == .file || $0.kind == .hunk }.map(\.text).joined(separator: "\n")
        for raw in ["diff --git", "index ", "a/", "b/", "new file mode", "deleted file mode", "similarity", "rename from", "No newline", "@@", "1111111"] {
            #expect(!shown.contains(raw), "\(raw)")
        }
        #expect(!lines.contains { $0.text.contains("No newline") })
    }

    @Test func gateRunningReplacesTheGateWord() throws {
        let r = try Self.review(nil, running: 65)
        #expect(r.gateText == "Gate running… 1:05")
        #expect(!r.visibleStrings.contains("Not run") && r.visibleStrings.contains("Gate running… 1:05"))
        #expect(try Self.review(nil).gateText == "Not run")
    }

    @Test func conflictsLeaveNoBrightButton() throws {
        let clean = PRLocalCopy.clean(path: "/tmp/w")
        let r = try Self.review(TaskPRBarTests.pass(), behind: true, local: clean, updateNote: "Can't update: conflicts in 2 files.")
        #expect(r.showsUpdate && r.updateEnabled && !r.updateIsPrimary && r.primary == .none)
    }

    @Test func fileCountsHideAZeroSide() {
        func t(_ a: Int, _ r: Int) -> [String] { PRFileCounts.parts(added: a, removed: r).map(\.text) }
        #expect(t(2, 0) == ["+2"] && t(0, 3) == ["−3"] && t(4, 1) == ["+4", "−1"] && t(0, 0).isEmpty)
    }

    @Test func behindWithNoCleanCopyPointsToGitHub() throws {
        let r = try Self.review(TaskPRBarTests.pass(), behind: true, local: .dirty)
        #expect(r.shown == .openOnGitHub && !r.showsUpdate)
        #expect(r.notes == ["Can't update: your local copy has uncommitted changes."])
        // No worktree at all: Update branch (temporary copy) is the bright one, with no refusal line.
        let none = try Self.review(TaskPRBarTests.pass(), behind: true, local: .none)
        #expect(none.shown == .update && none.showsUpdate && none.updateIsPrimary && none.notes == [PRScreenCopy.updateFirst])
        // A fork / branch not on origin: the r3 line, Open on GitHub primary.
        let fork = try Self.review(TaskPRBarTests.pass(), behind: true, local: .none, updateNote: PRScreenCopy.noCleanCopy)
        #expect(fork.shown == .openOnGitHub && fork.notes == [PRScreenCopy.noCleanCopy])
        // A clean copy keeps Update branch as the bright one.
        #expect(try Self.review(TaskPRBarTests.pass(), behind: true, local: .clean(path: "/tmp/w")).shown == .update)
        #expect(try Self.review(TaskPRBarTests.pass(), behind: true, local: .clean(path: "/tmp/w"), updateNote: "x").shown == .none)
    }

    @Test func heldColumnOnlyWhenSomeRowIsHeld() {
        var rows = [PRReviewTests.row(1, gate: "Green"), PRReviewTests.row(2, gate: "Red")]
        #expect(PRListState(phase: .loaded, rows: rows).anyHeld == false)
        rows[1].held = true
        #expect(PRListState(phase: .loaded, rows: rows).anyHeld)
        #expect(PRListState(phase: .loading, rows: rows).anyHeld == false)
    }

    // MARK: Review

    @Test func reviewButtonsComeFromTaskPRState() throws {
        for (gate, hold) in [(TaskPRBarTests.pass() as GateResult?, nil as HoldEntry?), (nil, nil), (TaskPRBarTests.pass(), TaskPRBarTests.hold)] {
            let r = try Self.review(gate, hold: hold)
            let t = try TaskPRBarTests.state(gate, hold: hold)
            #expect(r.pr == t && r.primary == t.primary)
            #expect(r.pr?.mergeEnabled == t.mergeEnabled && r.pr?.holdLabel == t.holdLabel)
        }
        let green = try Self.review(TaskPRBarTests.pass())
        #expect(green.primary == .merge && green.notes.isEmpty)
        #expect(try Self.review(nil).primary == .runGate)
    }

    @Test func heldShowsPillAndDisablesMerge() throws {
        let r = try Self.review(TaskPRBarTests.pass(), hold: TaskPRBarTests.hold)
        #expect(r.pr?.held == true && r.pr?.mergeEnabled == false && r.pr?.holdLabel == "Release")
        #expect(r.visibleStrings.contains("Held") && r.notes == [PRCopy.held])
        #expect(r.primary == .release)
    }

    @Test func redGateIsPlain() throws {
        let r = try Self.review(GateResult(passed: false, commit: Self.sha, reason: "error: swift build exited with code 1 (/Users/example/x.swift)", run_id: "run1"))
        #expect(r.pr?.gate == .red && r.notes == ["The gate failed."])
    }

    @Test func updateBranchOnlyWhenBehindAndCleanLocalCopy() throws {
        let clean = PRLocalCopy.clean(path: "/tmp/w")
        let cases: [(Bool, PRLocalCopy, Bool, Bool)] = [   // behind, local, offered, "no clean copy" line
            (true, clean, true, false), (true, .dirty, false, true), (true, .none, true, false),
            (false, clean, false, false), (false, .dirty, false, false), (false, .none, false, false),
        ]
        for (behind, local, offered, line) in cases {
            let r = try Self.review(TaskPRBarTests.pass(), behind: behind, local: local)
            #expect(r.showsUpdate == offered, "behind \(behind) \(local)")
            #expect(r.notes.contains(PRScreenCopy.dirtyCopy) == line)
            #expect(r.visibleStrings.contains("Update branch") == offered)
        }
        // Offered: it is the strong button, and Merge says why it is off.
        let r = try Self.review(TaskPRBarTests.pass(), behind: true, local: clean)
        #expect(r.updateIsPrimary && r.notes == [PRScreenCopy.updateFirst])
        #expect(try Self.review(TaskPRBarTests.pass(), behind: true, local: clean, hold: TaskPRBarTests.hold).updateIsPrimary == false)
        let conflict = try Self.review(TaskPRBarTests.pass(), behind: true, local: clean, updateNote: "Can't update: conflicts in 2 files.")
        #expect(conflict.notes == ["Can't update: conflicts in 2 files."])
    }

    @Test func worktreeLookupFindsTheBranchCheckout() {
        let porcelain = """
        worktree /Users/example/Projects/true
        HEAD aaa
        branch refs/heads/main

        worktree /Users/example/Projects/true.builders/pr-line
        HEAD bbb
        branch refs/heads/builder/pr-line

        worktree /tmp/detached
        HEAD ccc
        detached

        """
        #expect(PRWorktrees.path(branch: "builder/pr-line", porcelain: porcelain) == "/Users/example/Projects/true.builders/pr-line")
        #expect(PRWorktrees.path(branch: "builder/other", porcelain: porcelain) == nil)
        #expect(PRWorktrees.path(branch: "main", porcelain: porcelain) == "/Users/example/Projects/true")
    }

    @Test func signedOutHidesPRButtons() throws {
        let r = try Self.review(TaskPRBarTests.pass(), signedIn: false)
        #expect(!r.showsButtons && !r.showsUpdate && r.pr?.showsSignIn == true)
        #expect(!r.visibleStrings.contains("Merge") && !r.visibleStrings.contains("Run gate") && !r.visibleStrings.contains("Hold"))
        #expect(r.visibleStrings.contains("Sign in to GitHub") && r.visibleStrings.contains("Open on GitHub"))
    }

    @Test func couldNotLoadHasNoPRButtons() throws {
        let r = try Self.review(nil, body: .couldNotLoad)
        #expect(r.pr == nil && !r.showsButtons && r.visibleStrings.contains("Could not load this PR."))
        #expect(try Self.review(nil, body: .tooLarge).visibleStrings.contains("Diff too large. Open on GitHub."))
        #expect(try Self.review(nil, body: .loading).visibleStrings.contains("Loading diff…"))
    }

    @Test func noRawNamesInVisibleStrings() throws {
        var all: [String] = []
        for gate in [TaskPRBarTests.pass(), GateResult(passed: false, commit: Self.sha, reason: "build failed", run_id: "run1"), nil] {
            for behind in [true, false] { for local in [PRLocalCopy.none, .dirty, .clean(path: "/tmp/w")] {
                for hold in [TaskPRBarTests.hold, nil] {
                    all += try Self.review(gate, behind: behind, local: local, hold: hold).visibleStrings
                }
            } }
        }
        for body in [PRReviewState.Body.loading, .tooLarge, .couldNotLoad] { all += try Self.review(nil, body: body).visibleStrings }
        for phase in [PRListState.Phase.loading, .signedOut, .loaded, .failed("Could not load PRs.")] {
            all += PRListState(phase: phase, rows: [Self.row(held: true)], cachedAt: Date()).visibleStrings
        }
        let banned = ["merge(", "refuse", "reason:", "PRMerge", "PRFacts", "PRRow", "notRun", "green", "headSha", "Optional", "Error",
                      "error:", "abc1234", "/tmp/w", "builder/", "behindMain", "dirty", "clean("]
        for text in all { for b in banned { #expect(!text.contains(b), "\(text) contains \(b)") } }
    }

    // MARK: Task screen

    @MainActor @Test func nextLineHidesWhenPRLineShows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func screen(pr: TaskPRState?, pending: Bool = false) -> TaskScreenView {
            let d = TaskDetail(title: "T", owner: "Me", provider: "Claude", branch: "builder/x",
                               state: .make(kind: .builder, state: .finished, now: now, time: { UsageText.clock($0) }),
                               finished: true, checks: .passed, merged: false,
                               changes: TaskChanges(base: "main", head: Self.sha, commits: [], files: [], notCommitted: []), report: "")
            return TaskScreenView(detail: d, flat: true, pr: pr, prPending: pending)
        }
        #expect(screen(pr: try TaskPRBarTests.state(TaskPRBarTests.pass())).showsNextLine == false)
        #expect(screen(pr: nil, pending: true).showsNextLine == false)
        #expect(screen(pr: nil).showsNextLine == true)
    }
}

/// Stills: skipped unless TRUE_SNAPSHOT_DIR is set (dark only).
/// `TRUE_SNAPSHOT_DIR=$PWD/docs/designs/stills/t3-w4-11b swift test --filter PRStillsTests`
@MainActor
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty, "TRUE_SNAPSHOT_DIR not set"))
struct PRStillsTests {
    private func render(_ name: String, _ view: some View, width: CGFloat, height: CGFloat? = nil) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp")
        let framed = view.frame(width: width, height: height).background(Color.black).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: framed)
        let size = NSSize(width: width, height: height ?? max(host.fittingSize.height, 60))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name)-dark.png"))
    }

    static let diff = PRDiff.lines("""
    diff --git a/Sources/True/Views/TaskScreen.swift b/Sources/True/Views/TaskScreen.swift
    index 3f2a1b0..9c8d7e4 100644
    --- a/Sources/True/Views/TaskScreen.swift
    +++ b/Sources/True/Views/TaskScreen.swift
    @@ -198,7 +198,10 @@ struct TaskScreenView: View {
         private var stateBlock: some View {
             VStack(alignment: .leading, spacing: 6) {
    -            Text(detail.state.text)
    +            if showsNextLine {
    +                Text(detail.state.nextAction)
    +            }
                 Spacer()
             }
         }
    diff --git a/Tests/TrueTests/TaskScreenTests.swift b/Tests/TrueTests/TaskScreenTests.swift
    index 11aa22b..33cc44d 100644
    --- a/Tests/TrueTests/TaskScreenTests.swift
    +++ b/Tests/TrueTests/TaskScreenTests.swift
    @@ -12,6 +12,8 @@ struct TaskScreenTests {
         @Test func nextLineHides() {
    +        let screen = makeScreen(pr: green)
    +        #expect(screen.showsNextLine == false)
         }
     }
    diff --git a/Sources/True/Views/Old.swift b/Sources/True/Views/Legacy.swift
    similarity index 88%
    rename from Sources/True/Views/Old.swift
    rename to Sources/True/Views/Legacy.swift
    --- a/Sources/True/Views/Old.swift
    +++ b/Sources/True/Views/Legacy.swift
    @@ -3 +3 @@
    -struct Old {}
    +struct Legacy {}
    diff --git a/docs/notes.txt b/docs/notes.txt
    deleted file mode 100644
    index 6666666..0000000
    --- a/docs/notes.txt
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -draft one
    -draft two
    \\ No newline at end of file
    """)

    private func list(_ state: PRListState) throws -> PullRequestsView { PullRequestsView(state: state) }
    private let r = PRReviewTests.row
    private func rows(_ words: [String]) -> [PRRow] {
        zip(words, ["Add the pull request line to the task screen", "Fix the Hold list losing a PR", "Show the gate word in the list", "Update the review diff colours"])
            .enumerated().map { i, p in
                PRReviewTests.row(40 + i, title: p.1, ref: i % 2 == 0 ? "builder/\(["pr-line", "hold-fix", "gate-word", "diff-ink"][i])" : "fix/x",
                                  login: "owner", gate: p.0, add: [40, 12, 130, 7][i], del: [2, 30, 8, 7][i])
            }
    }
    private func review(_ gate: GateResult?, behind: Bool = false, local: PRLocalCopy = .none, hold: HoldEntry? = nil,
                        body: PRReviewState.Body? = nil, running: Int? = nil, updateNote: String? = nil,
                        facts: PRFacts? = TaskPRBarTests.facts()) throws -> PRReviewView {
        var f = facts; f?.behindMain = behind
        return PRReviewView(state: PRReviewState.make(row: PRReviewTests.row(), facts: f, gates: try TaskPRBarTests.gates(gate), hold: hold,
                                                      gateRunningFor: running, body: body ?? .diff(Self.diff), local: local, updateNote: updateNote))
    }

    @Test func stills() throws {
        let pass = TaskPRBarTests.pass()
        let W: CGFloat = 720
        try render("list-1-loading", list(PRListState(phase: .loading)), width: W, height: 200)
        try render("list-2-empty", list(PRListState(phase: .loaded)), width: W, height: 200)
        try render("list-3-gate-words", list(PRListState(phase: .loaded, rows: rows(["Green", "Red", "Not run", "Old"]))), width: W, height: 330)
        var held = rows(["Green", "Not run", "Green", "Red"]); held[0].held = true; held[2].held = true
        try render("list-4-held", list(PRListState(phase: .loaded, rows: held)), width: W, height: 330)
        var long = rows(["Not run", "Green"])
        long[0].title = "Make the pull request list show the gate word, the held pill and the plus and minus counts without wrapping badly when the title is very long"
        try render("list-5-long-title", list(PRListState(phase: .loaded, rows: long)), width: W, height: 200)
        try render("list-6-signed-out", list(PRListState(phase: .signedOut)), width: W, height: 200)
        try render("list-7-failed-cached", list(PRListState(phase: .failed(PRCopy.network), rows: rows(["Green", "Red", "Not run", "Old"]),
                                                            cachedAt: Date(timeIntervalSince1970: 1_800_000_000))), width: W, height: 380)
        let fifty = (0..<50).map { PRReviewTests.row(100 + $0, title: "Sample change \($0 + 1)", gate: $0 % 3 == 0 ? "Green" : "Not run") }
        try render("list-8-over-50", list(PRListState(phase: .loaded, rows: fifty)), width: W, height: 450)
        try render("list-9-over-50-scrolled", PullRequestsView(state: PRListState(phase: .loaded, rows: fifty), startAtEnd: true), width: W, height: 450)

        let H: CGFloat = 560
        try render("review-1-loading", review(nil, body: .loading), width: W, height: 300)
        try render("review-2-green", review(pass), width: W, height: H)
        try render("review-3-red", review(GateResult(passed: false, commit: TaskPRBarTests.sha, reason: "2 tests failed", run_id: "run1")), width: W, height: H)
        try render("review-4-held", review(pass, hold: TaskPRBarTests.hold), width: W, height: H)
        try render("review-5-gate-running", review(nil, running: 65), width: W, height: H)
        try render("review-6-update-branch", review(pass, behind: true, local: .clean(path: "/tmp/w")), width: W, height: H)
        try render("review-7-update-conflicts", review(pass, behind: true, local: .clean(path: "/tmp/w"), updateNote: "Can't update: conflicts in 2 files."), width: W, height: H)
        try render("review-8-no-local-copy", review(pass, behind: true, local: .none), width: W, height: H)
        try render("review-11-dirty-copy", review(pass, behind: true, local: .dirty), width: W, height: H)
        try render("review-9-diff-too-large", review(pass, body: .tooLarge), width: W, height: 300)
        try render("review-10-could-not-load", review(nil, body: .couldNotLoad, facts: nil), width: W, height: 300)

        // Task screen: finished + Green shows the PR line and no "Next: Run gate".
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let changes = TaskChanges(base: "main", head: TaskPRBarTests.sha, commits: ["Add the PR line"],
                                  files: [TaskChangedFile(path: "Sources/True/Views/TaskScreen.swift", added: 40, removed: 2, bytes: 900, binary: false)], notCommitted: [])
        let d = TaskDetail(title: "Add the pull request line to the task screen", owner: "Me", provider: "Claude", branch: "builder/pr-line",
                           state: .make(kind: .builder, state: .finished, now: now, time: { UsageText.clock($0) }),
                           finished: true, checks: .passed, merged: false, changes: changes, report: "")
        let prState = TaskPRState.make(signedIn: true, headSha: TaskPRBarTests.sha, commits: [], facts: TaskPRBarTests.facts(), gatedSha: TaskPRBarTests.sha,
                                       gates: try TaskPRBarTests.gates(pass), hold: nil)
        try render("task-11-finished-green", TaskScreenView(detail: d, flat: true, pr: prState), width: 560)
    }

    /// Where the entry sits: the Hub menu, between Context Cleaner and Show Results (a picture of the menu, not the real menu).
    @Test func entryStill() throws {
        func item(_ t: String, hot: Bool = false, key: String? = nil) -> some View {
            HStack { Text(t); Spacer(); if let key { Text(key).foregroundStyle(Theme.Token.text2) } }
                .font(Theme.Fonts.body).foregroundStyle(Theme.Token.text0)
                .padding(.horizontal, 12).frame(height: 26)
                .background(hot ? Color.white.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        let menu = VStack(alignment: .leading, spacing: 0) {
            item("Hide Hub", key: "⌘E"); item("Needs You", key: "⇧⌘U")
            Divider().overlay(Theme.Token.line).padding(.vertical, 4)
            item("New Agent…"); item("Accounts…"); item("Context Cleaner…")
            item("Pull Requests…", hot: true)
            item("Show Results", key: "⇧⌘R")
        }
        .padding(6).frame(width: 240)
        .background(Theme.Token.bg1, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Token.line))
        try render("entry-1", HStack { menu; Spacer() }.padding(20), width: 320, height: 250)
    }
}
