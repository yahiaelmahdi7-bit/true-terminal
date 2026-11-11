import AppKit
import SwiftUI
import Testing
@testable import True

@MainActor
@Suite struct CodingWorkflowStillsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".out/stills/coding-workflow")

    func snap<V: View>(_ name: String, width: CGFloat = 560, @ViewBuilder _ content: () -> V) throws {
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        for (tag, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                          ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let view = content().frame(width: width).background(scheme == .dark ? Theme.Token.bg0 : Color(white: 0.93))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view); r.scale = 2
            let img = try #require(r.nsImage)
            let tiff = try #require(img.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: Self.root.appendingPathComponent("\(name)-\(tag).png"))
        }
    }

    func file(_ p: String, _ a: Int?, _ r: Int?, binary: Bool = false) -> TaskChangedFile {
        TaskChangedFile(path: p, added: a, removed: r, bytes: 900, binary: binary)
    }
    func detail(_ state: TaskRunState, finished: Bool = false, checks: TaskChecks = .notRun, merged: Bool = false,
                changes: TaskChanges? = nil, kind: TaskKind = .builder) -> TaskDetail {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ch = changes ?? TaskChanges(base: "main", head: "abc1234", commits: ["Add the task screen"],
                                         files: [file("Sources/True/Views/TaskScreen.swift", 120, 4), file("Tests/TaskTests.swift", 30, 0), file("logo.png", nil, nil, binary: true)],
                                         notCommitted: [file("README.md", 2, 1)])
        return TaskDetail(title: "Task screen", owner: "the user", provider: "Claude", branch: "builder/task-screen",
                          state: .make(kind: kind, state: state, now: now, time: { _ in "4:30 PM" }),
                          finished: finished, checks: checks, merged: merged, changes: ch,
                          report: "Built the screen on the engine.\nAll states render.")
    }
    func screen(_ d: TaskDetail, open: String? = nil, diffs: [String: String] = [:], folder: Bool = false) -> some View {
        TaskScreenView(detail: d, diffs: diffs, open: open, folderMode: folder, flat: true).frame(height: nil).background(Theme.Token.bg0)
    }

    @Test func taskScreenStates() throws {
        let states: [(String, TaskRunState)] = [("running", .running), ("question", .needsQuestion), ("permission", .needsPermission),
            ("waiting", .waiting(Date(timeIntervalSince1970: 1_800_010_000))), ("ready", .waiting(Date(timeIntervalSince1970: 1_700_000_000))),
            ("stopped", .stopped), ("finished", .finished), ("failed-work", .failed(.work)), ("failed-checks", .failed(.checks)),
            ("failed-provider", .failed(.provider)), ("failed-process", .failed(.process))]
        for (n, s) in states {
            // Waiting-in-past shows "Ready to resume" for a mission.
            try snap("state-\(n)") { screen(detail(s, finished: s == .finished, kind: n == "ready" ? .mission : .builder)) }
        }
        let checks: [(String, TaskChecks)] = [("notrun", .notRun), ("nocheck", .noCheck), ("passed", .passed), ("failed", .failed(2)), ("flaky", .flaky(1))]
        for (n, c) in checks { try snap("checks-\(n)") { screen(detail(.finished, finished: true, checks: c, merged: n == "passed")) } }
    }

    @Test func changesAndEmpties() throws {
        let key = TaskScreenModel.key(file("Sources/True/Views/TaskScreen.swift", 120, 4), false)
        let diff = "@@ -1,3 +1,4 @@\n import SwiftUI\n-let old = 1\n+let new = 2\n+let extra = 3\n struct X {}"
        try snap("changes-open-diff") { screen(detail(.finished, finished: true), open: key, diffs: [key: diff]) }
        for (n, m) in [("not-git", TaskDetailCopy.notGit), ("no-changes", TaskDetailCopy.noChanges), ("too-many", TaskDetailCopy.tooMany)] {
            try snap("empty-\(n)") { screen(detail(.running, changes: TaskChanges(emptyMessage: m))) }
        }
        try snap("empty-no-check") { screen(detail(.finished, finished: true, checks: .noCheck)) }
        try snap("folder-changes") { screen(detail(.running), folder: true) }
    }

    @Test func seatCard() throws {
        var t = AgentTurn(seat: "Mira", folder: "/x", pid: 1, started: Date(), before: AgentTurnSnapshot())
        t.files = ["a", "b", "c"]; t.ended = Date()
        try snap("seat-badge", width: 420) { SeatTurnBadge(turn: t, onOpen: {}).padding(16) }
        t.sharedFolder = true; t.questionPending = true; t.end = .session
        try snap("seat-badge-overlap", width: 640) { SeatTurnBadge(turn: t, onOpen: {}).padding(16) }
    }

    @Test func panePanel() throws {
        let repo = PaneGitStatus(isRepo: true, branch: "builder/task-screen", added: 142, removed: 9, files: 4)
        let clean = PaneGitStatus(isRepo: true, branch: "main", added: 0, removed: 0, files: 0)
        let editors = [PaneEditor(id: "a", name: "Cursor", url: URL(fileURLWithPath: "/Applications/Cursor.app"))]
        try snap("pill", width: 320) { HStack { Spacer(); PanePill(status: repo, solid: true) }.padding(12) }
        try snap("pill-folder", width: 320) { HStack { Spacer(); PanePill(status: .notGit, solid: true) }.padding(12) }
        try snap("panel-open", width: 330) { PanePanelView(status: repo, macName: "the user's MacBook", editors: editors, chosenEditor: editors[0], shadow: true, solid: true).padding(24) }
        try snap("panel-clean", width: 330) { PanePanelView(status: clean, macName: "the user's MacBook", editors: editors, chosenEditor: editors[0], shadow: true, solid: true).padding(24) }
        try snap("panel-nongit", width: 330) { PanePanelView(status: .notGit, macName: "the user's MacBook", shadow: true, solid: true).padding(24) }
        try snap("commit-sheet", width: 380) { CommitSheet(files: 4, preview: "Add the task screen and pane panel").padding(8) }
        try snap("commit-sheet-result", width: 380) { CommitSheet(files: 4, result: "Nothing to commit", preview: "Add the task screen").padding(8) }
        try snap("panel-over-terminal", width: 900) {
            ZStack(alignment: .topTrailing) {
                Color.black.frame(height: 420).overlay(alignment: .topLeading) {
                    Text("~/Projects/true $ swift build\nBuild complete! (42.1s)\n~/Projects/true $ _")
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).padding(16)
                }
                VStack(alignment: .trailing, spacing: 8) {
                    // ImageRenderer cannot draw Liquid Glass; the solid fill is what the glass sits on (85% bg3).
                    PanePill(status: repo, solid: true)
                    PanePanelView(status: repo, macName: "the user's MacBook", editors: editors, chosenEditor: editors[0], shadow: true, solid: true)
                }.padding(12)
            }
        }
    }
}
