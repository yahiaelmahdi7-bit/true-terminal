import Testing
import Foundation
import SwiftUI
import AppKit
@testable import True

/// Renders the Command bar from fixtures to PNGs. Skipped unless TRUE_SNAPSHOT_DIR is set:
/// `TRUE_SNAPSHOT_DIR=$PWD/docs/design/commandbar swift test --filter CommandBarSnapshotTests`.
@MainActor
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty, "TRUE_SNAPSHOT_DIR not set"))
struct CommandBarSnapshotTests {
    private struct Host: View {
        @State var text: String
        var route: Route
        var plan: Plan?
        var armed = false
        @FocusState var focus: Bool
        var body: some View {
            CommandBarCard(text: $text, route: route, plan: plan, armed: armed, focus: $focus)
                .frame(width: 640).padding(40).background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func snapshot(_ name: String, _ view: some View) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp")
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).background(Theme.background))
        let size = NSSize(width: 720, height: max(host.fittingSize.height, 100))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { Issue.record("no bitmap"); return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { Issue.record("no png"); return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private let truth = Project(name: "true", path: "/Users/example/Projects/true", parent: "~/Projects")
    private func route(_ k: CommandKind, text: String, target: CommandTarget = .newClaudePane, destructive: Double? = 0.05) -> Route {
        Route(text: text, kind: k, kindConfidence: 0.92, project: truth, target: target, action: .none, seat: nil,
              destructive: destructive, model: .sonnet, effort: .medium)
    }
    private let ctx = CommandContext(focused: FocusedPane(kind: .shell, project: "true", seat: nil, cwd: "/Users/example/Projects/true"),
                                     projects: [], seats: [])

    @Test func confident() throws {
        let r = route(.agentTask, text: "add a dark mode toggle to settings")
        try snapshot("confident", Host(text: r.text, route: r, plan: CommandExecutor.plan(route: r, background: false, context: ctx)))
    }
    @Test func lowConfidence() throws {
        var r = route(.shellCommand, text: "clean up the build output")
        r.twoChoice = true; r.kindConfidence = 0.31; r.uncertain = [.kind, .project]
        try snapshot("low-confidence", Host(text: r.text, route: r, plan: nil))
        var u = route(.agentTask, text: "tidy the tests", target: .focusedPane)
        u.uncertain = [.project, .target]
        try snapshot("uncertain-chips", Host(text: u.text, route: u, plan: nil))
    }
    @Test func destructive() throws {
        let r = route(.agentTask, text: "delete every merged branch and force push", destructive: 0.93)
        try snapshot("destructive", Host(text: r.text, route: r, plan: CommandExecutor.plan(route: r, background: false, context: ctx)))
        try snapshot("destructive-armed", Host(text: r.text, route: r, plan: nil, armed: true))
        let s = route(.shellCommand, text: "supabase db push", destructive: 0.9)
        try snapshot("shell-typed-not-sent", Host(text: s.text, route: s, plan: CommandExecutor.plan(route: s, background: false, context: ctx)))
    }
}
