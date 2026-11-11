import Testing
import Foundation
import SwiftUI
import AppKit
@testable import True

/// dp-2 stills: Command bar + project palette, light and dark. Skipped unless TRUE_SNAPSHOT_DIR is set:
/// `TRUE_SNAPSHOT_DIR=$PWD/docs/designs/stills/dp-2 swift test --filter DesignPassStillsTests`.
/// These write PNGs for review; they are not baselines and nothing compares against them.
@MainActor
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty, "TRUE_SNAPSHOT_DIR not set"))
struct DesignPassStillsTests {
    private struct BarHost: View {
        @State var text: String
        var route: Route?
        var plan: Plan?
        var armed = false
        var reading = false
        @FocusState var focus: Bool
        var body: some View {
            CommandBarCard(text: $text, route: route, plan: plan, reading: reading, armed: armed, focus: $focus)
                .frame(width: 640)
        }
    }

    private struct PaletteHost: View {
        @State var query: String
        var rows: [Project]
        var details: [String: ProjectPalette.Detail]
        @FocusState var focus: Bool
        var body: some View {
            ProjectPaletteCard(query: $query, rows: rows, details: details, highlight: 1, focus: $focus)
                .frame(width: 560)
        }
    }

    private func still(_ name: String, _ scheme: ColorScheme, _ view: some View) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp")
        // A wallpaper-ish backdrop so the glass has something to show through.
        let backdrop = scheme == .dark
            ? LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(white: 0.96), Color(white: 0.82)], startPoint: .top, endPoint: .bottom)
        let framed = view.padding(40).frame(width: 720).background(backdrop).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: framed)
        let size = NSSize(width: 720, height: max(host.fittingSize.height, 100))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
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
        try png.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    private let truth = Project(name: "true", path: "/Users/example/Projects/true", parent: "~/Projects")
    private func route(_ k: CommandKind, text: String, destructive: Double? = 0.05) -> Route {
        Route(text: text, kind: k, kindConfidence: 0.92, project: truth, target: .newClaudePane, action: .none, seat: nil,
              destructive: destructive, model: .sonnet, effort: .medium)
    }
    private let ctx = CommandContext(focused: FocusedPane(kind: .shell, project: "true", seat: nil, cwd: "/Users/example/Projects/true"),
                                     projects: [], seats: [])

    @Test(arguments: [ColorScheme.light, .dark]) func commandBarStates(scheme: ColorScheme) throws {
        try still("commandbar-1-idle", scheme, BarHost(text: ""))
        let typing = route(.agentTask, text: "add a dark mode toggle to settings")
        try still("commandbar-2-typing", scheme, BarHost(text: "add a dark mode", reading: true))
        try still("commandbar-3-results", scheme,
                  BarHost(text: typing.text, route: typing, plan: CommandExecutor.plan(route: typing, background: false, context: ctx)))
        // "Error" here is the bar's loudest warning state: a destructive request, armed (no separate error view exists).
        let bad = route(.agentTask, text: "delete every merged branch and force push", destructive: 0.93)
        try still("commandbar-4-error", scheme, BarHost(text: bad.text, route: bad, plan: nil, armed: true))
        var unsure = route(.shellCommand, text: "clean up the build output")
        unsure.twoChoice = true; unsure.kindConfidence = 0.31; unsure.uncertain = [.kind, .project]
        try still("commandbar-5-which-one", scheme, BarHost(text: unsure.text, route: unsure))
    }

    @Test(arguments: [ColorScheme.light, .dark]) func paletteOpen(scheme: ColorScheme) throws {
        let rows = [
            Project(name: "true", path: "/Users/example/Projects/true", parent: "~/Projects"),
            Project(name: "prism", path: "/Users/example/Projects/prism", parent: "~/Projects"),
            Project(name: "clipping-site", path: "/Users/example/Projects/clipping-site", parent: "~/Projects"),
            Project(name: "notes-index", path: "/Users/example/Projects/notes-index", parent: "~/Projects"),
        ]
        let details = [rows[0].path: ProjectPalette.Detail(branch: "main", handoff: false),
                       rows[1].path: ProjectPalette.Detail(branch: "feature/onboarding", handoff: true),
                       rows[2].path: ProjectPalette.Detail(branch: "main", handoff: false)]
        try still("palette-open", scheme, PaletteHost(query: "", rows: rows, details: details))
    }
}
