import AppKit
import SwiftUI
import Testing
@testable import True

@Suite struct TaskPRBarTests {
    static let sha = "abc1234def5678"
    static let other = "1111111aaaaaaa"

    /// A gate folder with a result for `sha` (and its run file), or none.
    static func gates(_ result: GateResult?) throws -> GateReader {
        let dir = NSTemporaryDirectory() + "pr-bar-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/run1", withIntermediateDirectories: true)
        if let r = result {
            let data = try JSONEncoder().encode(r)
            FileManager.default.createFile(atPath: "\(dir)/\(r.commit).json", contents: data)
            FileManager.default.createFile(atPath: "\(dir)/run1/result.json", contents: data)
        }
        return GateReader(dir: dir)
    }
    static func pass(_ sha: String = sha) -> GateResult { GateResult(passed: true, commit: sha, run_id: "run1") }
    static func facts(state: String = "OPEN", draft: Bool = false, base: String = "main", behind: Bool = false, head: String = sha) -> PRFacts {
        PRFacts(number: 42, headSha: head, state: state, isDraft: draft, baseRef: base, behindMain: behind)
    }
    static let hold = HoldEntry(repo: "o/r", number: 42, since: "2026-11-09T10:00:00Z", why: "")

    static func state(_ gate: GateResult?, facts: PRFacts? = facts(), gated: String = sha, hold: HoldEntry? = nil,
                      signedIn: Bool = true) throws -> TaskPRState {
        TaskPRState.make(signedIn: signedIn, headSha: facts?.headSha ?? sha, commits: [], facts: facts, gatedSha: gated,
                         gates: try gates(gate), hold: hold)
    }

    @Test func mergeEnabledWhenRulePasses() throws {
        let s = try Self.state(Self.pass())
        #expect(s.mergeEnabled)
        #expect(s.note == nil)
    }

    /// One case per refusal the screen can show; the text is the rule's own, shown as written.
    @Test(arguments: [
        ("closed", "This PR is closed."), ("draft", "This PR is a draft."), ("held", PRCopy.held),
        ("not-main", "This PR is not against main."), ("no-gate", "No gate result for this commit. Run the gate first."),
        ("other-commit", "Gate result belongs to another commit."), ("failed", "The gate failed: 2 tests failed."),
        ("dirty", "The gate ran on uncommitted work, so it does not count."),
        ("changed-after-gate", "The PR changed after the gate. Run the gate again."), ("behind", "Update the branch first."),
    ])
    func refusalDisablesMerge(name: String, text: String) throws {
        let s: TaskPRState
        switch name {
        case "closed": s = try Self.state(Self.pass(), facts: Self.facts(state: "CLOSED"))
        case "draft": s = try Self.state(Self.pass(), facts: Self.facts(draft: true))
        case "held": s = try Self.state(Self.pass(), hold: Self.hold)
        case "not-main": s = try Self.state(Self.pass(), facts: Self.facts(base: "dev"))
        case "no-gate": s = try Self.state(nil)
        case "other-commit":
            // A copied file: named for this head, but its commit is another one.
            var g = Self.pass(); g.commit = Self.other
            let dir = NSTemporaryDirectory() + "pr-bar-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir + "/run1", withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(g)
            FileManager.default.createFile(atPath: "\(dir)/\(Self.sha).json", contents: data)
            FileManager.default.createFile(atPath: "\(dir)/run1/result.json", contents: data)
            s = TaskPRState.make(signedIn: true, headSha: Self.sha, commits: [], facts: Self.facts(), gatedSha: Self.sha,
                                 gates: GateReader(dir: dir), hold: nil)
        case "failed": s = try Self.state(GateResult(passed: false, commit: Self.sha, reason: "2 tests failed", run_id: "run1"))
        case "dirty": s = try Self.state(GateResult(passed: true, dirty: true, commit: Self.sha, run_id: "run1"))
        case "changed-after-gate": s = try Self.state(Self.pass(), gated: Self.other)
        default: s = try Self.state(Self.pass(), facts: Self.facts(behind: true))
        }
        #expect(!s.mergeEnabled)
        #expect(s.note == text)
    }

    @Test func heldDisablesMergeAndOffersRelease() throws {
        let s = try Self.state(Self.pass(), hold: Self.hold)
        #expect(s.held && !s.mergeEnabled)
        #expect(s.holdLabel == "Release")
        #expect(try Self.state(Self.pass()).holdLabel == "Hold")
    }

    @Test func gateWordMatchesPRList() throws {
        let cases: [(GateResult?, [String])] = [
            (Self.pass(), []), (GateResult(passed: false, commit: Self.sha, run_id: "run1"), []), (nil, []),
            (GateResult(passed: true, dirty: true, commit: Self.sha, run_id: "run1"), []),
        ]
        for (result, _) in cases {
            let g = try Self.gates(result)
            let json = #"[{"number":42,"title":"T","headRefName":"builder/x","headRefOid":"\#(Self.sha)","commits":[]}]"#
            let row = try #require(PRList.rows(json: json, gates: g, held: { _ in nil })).first
            let s = TaskPRState.make(signedIn: true, headSha: Self.sha, commits: [], facts: Self.facts(), gatedSha: Self.sha, gates: g, hold: nil)
            #expect(s.gate.rawValue == row?.gate)
        }
        // "Old": a file exists for another commit of the PR.
        let g = try Self.gates(Self.pass(Self.other))
        let s = TaskPRState.make(signedIn: true, headSha: Self.sha, commits: [Self.other, Self.sha], facts: nil, gatedSha: Self.sha, gates: g, hold: nil)
        #expect(s.gate == .old)
        let json = #"[{"number":42,"title":"T","headRefName":"b","headRefOid":"\#(Self.sha)","commits":[{"oid":"\#(Self.other)"},{"oid":"\#(Self.sha)"}]}]"#
        #expect(PRList.rows(json: json, gates: g, held: { _ in nil })?.first?.gate == "Old")
    }

    @Test func noPRShowsCreateOnly() throws {
        let s = try Self.state(nil, facts: nil)
        #expect(s.showsCreate && !s.showsMerge && !s.mergeEnabled)
        #expect(s.visibleStrings.contains("Create PR") && !s.visibleStrings.contains("Merge"))
    }

    @Test func signedOutHidesPRButtons() throws {
        for facts in [nil, Self.facts()] {
            let s = try Self.state(Self.pass(), facts: facts, signedIn: false)
            #expect(!s.showsPRControls && !s.showsCreate && !s.showsMerge && !s.mergeEnabled)
            #expect(s.visibleStrings == [PRCopy.signedOut, TaskPRCopy.signIn] && s.showsSignIn)
        }
    }

    @Test func gateRunningAndBusyWords() throws {
        #expect(TaskPRCopy.gateRunning(65) == "Gate running… 1:05")
        #expect(TaskPRCopy.gateRunning(5) == "Gate running… 0:05")
        let s = TaskPRState.make(signedIn: true, headSha: Self.sha, commits: [], facts: Self.facts(), gatedSha: Self.sha,
                                 gates: try Self.gates(Self.pass()), hold: nil, gateRunningFor: 65, gateBusyClicked: true)
        // Running: the elapsed time says it all; Run gate is off and no line sits under the buttons.
        #expect(s.note == nil && !s.gateButtonEnabled)
        #expect(s.visibleStrings.contains("Gate running… 1:05"))
        // A gate started elsewhere (no elapsed time known here): the click gets the busy line.
        let elsewhere = TaskPRState.make(signedIn: true, headSha: Self.sha, commits: [], facts: Self.facts(), gatedSha: Self.sha,
                                         gates: try Self.gates(nil), hold: nil, gateBusyClicked: true)
        #expect(elsewhere.note == "A gate is already running." && elsewhere.gateButtonEnabled)
    }

    /// The strong fill goes to the next useful step, never to a disabled button.
    @Test func primaryIsTheNextStep() throws {
        #expect(try Self.state(nil, facts: nil).primary == .create)
        #expect(try Self.state(Self.pass()).primary == .merge)
        #expect(try Self.state(Self.pass(), hold: Self.hold).primary == .release)
        #expect(try Self.state(nil).primary == .runGate)
        #expect(try Self.state(Self.pass(), signedIn: false).primary == .signIn)
        let running = TaskPRState.make(signedIn: true, headSha: Self.sha, commits: [], facts: Self.facts(), gatedSha: Self.sha,
                                       gates: try Self.gates(nil), hold: nil, gateRunningFor: 10)
        #expect(running.primary == .none)
    }

    /// A short plain reason is shown as the rule wrote it; raw tool text becomes "The gate failed."
    @Test(arguments: [
        ("2 tests failed", "The gate failed: 2 tests failed."),
        ("build failed", "The gate failed: build failed."),
        ("error: no such module 'Foo'", "The gate failed."),
        ("swift test exited with 1", "The gate failed."),
        ("/Users/example/Projects/true/Sources/True/X.swift:12", "The gate failed."),
        (String(repeating: "word ", count: 20), "The gate failed."),
    ])
    func gateFailedReasonStaysPlain(why: String, shown: String) throws {
        let s = try Self.state(GateResult(passed: false, commit: Self.sha, reason: why, run_id: "run1"))
        #expect(s.note == shown)
    }

    @Test func noRawNamesInVisibleStrings() throws {
        var all: [String] = []
        for facts in [Self.facts(), Self.facts(state: "CLOSED"), Self.facts(behind: true), nil] {
            for hold in [Self.hold, nil] {
                for gate in [Self.pass(), GateResult(passed: false, commit: Self.sha, reason: "build failed", run_id: "run1"), nil] {
                    all += try Self.state(gate, facts: facts, hold: hold).visibleStrings
                }
            }
        }
        let banned = ["merge(", "refuse", "reason:", "PRMerge", "PRFacts", "notRun", "green", "headSha", "Optional", "Error", "abc1234"]
        for text in all { for b in banned { #expect(!text.contains(b), "\(text) contains \(b)") } }
    }
}

/// Stills: skipped unless TRUE_SNAPSHOT_DIR is set (dark only).
/// `TRUE_SNAPSHOT_DIR=$PWD/docs/designs/stills/t3-w4-11a swift test --filter TaskPRStillsTests`
@MainActor
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty, "TRUE_SNAPSHOT_DIR not set"))
struct TaskPRStillsTests {
    private func render(_ name: String, _ view: some View, width: CGFloat) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp")
        let framed = view.frame(width: width).background(Color.black).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: framed)
        let size = NSSize(width: width, height: max(host.fittingSize.height, 60))
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

    private func screen(title: String = "Add the pull request line to the task screen", checks: TaskChecks = .passed, _ pr: TaskPRState) -> some View {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let changes = TaskChanges(base: "main", head: TaskPRBarTests.sha, commits: ["Add the PR line"],
                                  files: [TaskChangedFile(path: "Sources/True/Views/TaskScreen.swift", added: 40, removed: 2, bytes: 900, binary: false)],
                                  notCommitted: [])
        let d = TaskDetail(title: title, owner: "Me", provider: "Claude", branch: "builder/pr-line",
                           state: .make(kind: .builder, state: .finished, now: now, time: { UsageText.clock($0) }),
                           finished: true, checks: checks, merged: false, changes: changes, report: "")
        return TaskScreenView(detail: d, flat: true, pr: pr)
    }

    private func s(_ gate: GateResult?, facts: PRFacts? = TaskPRBarTests.facts(), hold: HoldEntry? = nil, running: Int? = nil,
                   busy: Bool = false, signedIn: Bool = true, commits: [String] = []) throws -> TaskPRState {
        TaskPRState.make(signedIn: signedIn, headSha: TaskPRBarTests.sha, commits: commits, facts: facts, gatedSha: TaskPRBarTests.sha,
                         gates: try TaskPRBarTests.gates(gate), hold: hold, gateRunningFor: running, gateBusyClicked: busy)
    }

    @Test func stills() throws {
        let pass = TaskPRBarTests.pass()
        try render("task-1-no-pr", screen(checks: .notRun, try s(nil, facts: nil)), width: 560)
        try render("task-2-green", screen(try s(pass)), width: 560)
        try render("task-3-red", screen(checks: .failed(2), try s(GateResult(passed: false, commit: TaskPRBarTests.sha, reason: "2 tests failed", run_id: "run1"))), width: 560)
        try render("task-4-not-run", screen(checks: .notRun, try s(nil)), width: 560)
        try render("task-5-old", screen(checks: .notRun, try s(TaskPRBarTests.pass(TaskPRBarTests.other), commits: [TaskPRBarTests.other, TaskPRBarTests.sha])), width: 560)
        try render("task-6-held", screen(try s(pass, hold: TaskPRBarTests.hold)), width: 560)
        try render("task-7-gate-running", screen(checks: .notRun, try s(nil, running: 65)), width: 560)
        try render("task-8-signed-out", screen(try s(pass, signedIn: false)), width: 560)
        try render("task-10-red-raw", screen(checks: .failed(1), try s(GateResult(passed: false, commit: TaskPRBarTests.sha, reason: "error: swift build exited with code 1 (/Users/example/Projects/true/Package.swift)", run_id: "run1"))), width: 560)
        try render("task-9-long-title", screen(title: "Make the pull request line on the task screen show the gate word, the held pill and every refusal in plain words without wrapping badly", checks: .notRun, try s(nil, commits: [])), width: 560)
    }
}
