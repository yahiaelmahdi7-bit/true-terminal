import AppKit
import SwiftUI
import Testing
@testable import True

@MainActor
@Suite struct AgentsStillsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".out/stills/t3-parity")
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snap<V: View>(_ name: String, width: CGFloat = 312, @ViewBuilder _ content: () -> V) throws {
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

    func seat(_ n: String, _ activity: String = "Editing a file", needs: Bool = false) -> ActivityRow {
        ActivityRow(kind: .seat, id: n, name: n, status: needs ? "needs-you" : "working", activity: activity, project: "true",
                    provider: "Claude", model: "Opus", effort: nil, browser: nil, needsYou: needs, since: Self.now)
    }
    func builder(_ n: String) -> ActivityRow {
        ActivityRow(kind: .builder, id: n, name: n, status: "working", activity: "Running tests", project: "true",
                    provider: "Claude", model: "Sonnet", effort: nil, browser: nil, needsYou: false, since: Self.now)
    }
    func win(_ p: UsageProvider, _ k: UsageKind, _ pct: Double?, _ state: UsageFreshness = .fresh, readAgo: TimeInterval = 300) -> UsageWindow {
        UsageWindow(provider: p, kind: k, usedPercent: pct, resetsAt: Self.now.addingTimeInterval(7200),
                    windowMins: k == .fiveHour ? 300 : 10080, readAt: Self.now.addingTimeInterval(-readAgo), state: state)
    }
    var calm: UsagePanelData {
        UsagePanelData(providers: [.claude, .codex], windows: [win(.claude, .fiveHour, 31), win(.claude, .weekly, 12),
                                                              win(.codex, .fiveHour, 18), win(.codex, .weekly, 40)])
    }
    static let me = PlaceRow(id: "me", name: "the user's MacBook Pro", folder: NSHomeDirectory() + "/Projects/true", isThisMac: true)
    static func peer(_ n: String, _ folder: String = "~/code/true", online: Bool = true, lastSeen: Date? = nil) -> PlaceRow {
        PlaceRow(id: n, name: n, folder: folder, online: online, lastSeen: lastSeen)
    }
    static let alone = [me]
    /// Fixed clock and zone so "last seen" reads the same on every run: now = 08:00 UTC, 2027-01-15.
    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    static let placeNow = Date(timeIntervalSince1970: 1_800_000_000)
    static let earlierToday = placeNow.addingTimeInterval(-3 * 3600)
    var git: PaneGitStatus { PaneGitStatus(isRepo: true, branch: "main", added: 12, removed: 3, files: 2) }

    func panel(_ rows: [ActivityRow], _ usage: UsagePanelData, expanded: Bool = false, places: [PlaceRow]? = nil) -> some View {
        let running = rows.count
        let idle = AgentsPill.isIdle(running: running, usage: usage)
        return VStack(alignment: .trailing, spacing: 8) {
            AgentsPill(running: running, needsYou: rows.contains { $0.needsYou }, idle: idle, solid: true)
            PanePanelView(status: git, solid: true, agents: rows, usage: usage, agentsExpanded: expanded,
                          places: places ?? Self.alone, placesNow: Self.placeNow, placesCalendar: Self.utc)
        }.padding(8)
    }

    @Test func counts() throws {
        try snap("t3-0-agents") { panel([], calm) }
        try snap("t3-1-agent") { panel([seat("Main")], calm) }
        try snap("t3-3-agents") { panel([seat("Main"), seat("Docs"), seat("Tests")], calm) }
        let nine = (1...9).map { seat("Seat \($0)") }
        try snap("t3-9-collapsed") { panel(nine, calm) }
        try snap("t3-9-expanded") { panel(nine, calm, expanded: true) }
        try snap("t3-needs-you-fifth") {
            panel([seat("Main"), seat("Docs"), seat("Tests"), seat("Site"), seat("Review", "Waiting for you", needs: true)], calm)
        }
        try snap("t3-long-names") {
            panel([seat("A very long agent name that keeps going and going past the edge", "Reading a very long file name here and more"),
                   seat("Another extremely long seat name for the layout", needs: true)], calm)
        }
        try snap("t3-builder") { panel([seat("Main"), builder("Task screen polish"), builder("Docs sweep")], calm) }
    }

    @Test func places() throws {
        let one = [seat("Main")]
        try snap("t3-place-alone") { panel(one, calm, places: Self.alone) }
        try snap("t3-place-peer-online") { panel(one, calm, places: [Self.me, Self.peer("Alex's MacBook")]) }
        try snap("t3-place-peer-offline") { panel(one, calm, places: [Self.me, Self.peer("Alex's MacBook", online: false, lastSeen: Self.earlierToday)]) }
        var long = Self.me; long.folder = NSHomeDirectory() + "/Projects/clients/very-long-client-name/workspaces/true-terminal-app"
        try snap("t3-place-long-path") {
            panel(one, calm, places: [long, Self.peer("Alex's very long named MacBook Pro 16-inch", "~/Documents/code/shared/clients/true/terminal/app", online: false, lastSeen: Self.earlierToday)])
        }
        try snap("t3-place-long-name") {
            panel(one, calm, places: [Self.me, Self.peer("Alex's extraordinarily well-travelled MacBook Pro 16-inch (work)", online: false, lastSeen: Self.earlierToday)])
        }
        try snap("t3-place-4-macs") {
            panel(one, calm, places: [Self.me, Self.peer("Alex's MacBook"), Self.peer("Sara's iMac", "~/true", online: false, lastSeen: Self.placeNow.addingTimeInterval(-3 * 86400)), Self.peer("Studio Mac", "~/src/true")])
        }
    }

    @Test func usage() throws {
        let one = [seat("Main")]
        var full = calm; full.windows[2] = win(.codex, .fiveHour, 100)
        try snap("t3-codex-100") { panel(one, full) }
        var old = calm; old.windows = [win(.claude, .fiveHour, 31, .old, readAgo: 7200), win(.claude, .weekly, 12, .old, readAgo: 7200),
                                       win(.codex, .fiveHour, 18), win(.codex, .weekly, 40)]
        try snap("t3-old-reading") { panel(one, old) }
        var past = calm
        past.windows = [UsageWindow(provider: .claude, kind: .fiveHour, usedPercent: nil, resetsAt: Self.now.addingTimeInterval(-600),
                                    windowMins: 300, readAt: Self.now.addingTimeInterval(-9000), state: .pastReset),
                        win(.claude, .weekly, 12, .old, readAgo: 9000),
                        win(.codex, .fiveHour, 18), win(.codex, .weekly, 40)]
        try snap("t3-past-reset") { panel(one, past) }
        var noCodexReading = calm; noCodexReading.windows = Array(calm.windows.prefix(2))
        try snap("t3-codex-no-reading") { panel(one, noCodexReading) }
        try snap("t3-no-reading-at-all") { panel(one, UsagePanelData(providers: [.claude, .codex], windows: [])) }
        var noCodex = calm; noCodex.providers = [.claude]; noCodex.windows = Array(calm.windows.prefix(2))
        try snap("t3-codex-not-installed") { panel(one, noCodex) }
    }

    /// The real positions: the tray frame comes from `TrayPanelFrame` (collapsed chip, top-right), the pill's own
    /// place is the tab bar's trailing edge, and the shift is the same `PillAvoidsTray` the app uses.
    func titleBar(trayOpen: Bool) -> some View {
        let size = CGSize(width: 900, height: 560)
        let chip = TrayPanelController.collapsedSize
        let appKit = TrayPanelFrame.frame(corner: .topRight, visible: CGRect(origin: .zero, size: size), size: chip,
                                          inset: TrayPanelController.inset)
        let tray = CGRect(x: appKit.minX, y: size.height - appKit.maxY, width: appKit.width, height: appKit.height)
        let pillW: CGFloat = 52, pillH: CGFloat = 26
        let natural = CGRect(x: size.width - Theme.paneInsets.trailing - pillW, y: (38 - pillH) / 2, width: pillW, height: pillH)
        let shift = trayOpen ? PillAvoidsTray.shift(pill: natural, tray: tray) : 0
        return ZStack(alignment: .topLeading) {
            Theme.Token.bg0
            Rectangle().fill(Theme.Token.line).frame(height: 1).offset(y: 38)
            AgentsPill(running: 2, needsYou: true, solid: true).offset(x: natural.minX - shift, y: natural.minY)
            if trayOpen {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Token.bg3)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Token.line, lineWidth: 1))
                    .overlay(Text("Screenshots").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Token.text1))
                    .frame(width: tray.width, height: tray.height).offset(x: tray.minX, y: tray.minY)
            }
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @Test func trayStills() throws {
        try snap("t3-tray-open", width: 900) { titleBar(trayOpen: true) }
        try snap("t3-tray-closed", width: 900) { titleBar(trayOpen: false) }
    }
}
