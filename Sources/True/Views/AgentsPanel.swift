import SwiftUI

/// What the Usage tile draws. Built from `UsageStore`, or by hand in stills.
struct UsagePanelData: Equatable {
    var providers: [UsageProvider] = [.claude]
    var windows: [UsageWindow] = []
    var checking = false
    /// The Team section: one line per other person on the Team board. Empty = no section (a solo user).
    var team: [TeamUsageLine] = []

    func window(_ p: UsageProvider, _ k: UsageKind) -> UsageWindow {
        windows.first { $0.provider == p && $0.kind == k } ?? .empty(p, k)
    }
    /// Any window at 80 % or more.
    var anyHigh: Bool { windows.contains { ($0.usedPercent ?? 0) >= 80 } }
    /// A provider has a reading when any of its windows was ever read (fresh, old or past reset).
    func hasReading(_ p: UsageProvider) -> Bool { windows.contains { $0.provider == p && $0.state != .none } }
    /// Providers with something to show; a provider without a reading drops out of the tile.
    var shownProviders: [UsageProvider] { providers.filter(hasReading) }
    /// No provider has a reading: the Usage tile is not drawn at all.
    var showsTile: Bool { !shownProviders.isEmpty || !team.isEmpty }
    /// "Read 12:00" once per provider, only when a reading is old or past its reset.
    func staleNote(_ p: UsageProvider) -> String? {
        let ws = windows.filter { $0.provider == p && ($0.state == .old || $0.state == .pastReset) }
        guard let at = ws.compactMap(\.readAt).max() else { return nil }
        return UsageText.readStamp(at)
    }
}

enum AgentsCopy {
    static let nothing = "Nothing running", showFewer = "Show fewer"
    static func all(_ n: Int) -> String { "All \(n)" }
    static let agents = "Agents", usage = "Usage", background = "Background", checkNow = "Check now", checking = "Checking…"
    static let fiveHour = "5 h", week = "Week"
    static func more(_ n: Int) -> String { "+\(n) more" }
    static func provider(_ p: UsageProvider) -> String { p == .claude ? "Claude" : "Codex" }
    static func label(running: Int, needsYou: Bool) -> String {
        running == 0 ? "No agents running"
            : "\(running) \(running == 1 ? "agent" : "agents") running" + (needsYou ? ", one needs you" : "")
    }
}

/// The Agents icon: running count and a white dot when someone needs the user. Always on screen; idle (nothing runs,
/// every window under 80 %) it is the icon alone, dimmed.
struct AgentsPill: View {
    let running: Int
    let needsYou: Bool
    var idle = false
    var solid = false   // stills only

    static func isIdle(running: Int, usage: UsagePanelData) -> Bool { running == 0 && !usage.anyHigh }
    /// The number is drawn only while something runs.
    static func showsCount(running: Int) -> Bool { running > 0 }
    static let idleOpacity = 0.55

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2").font(.system(size: 12)).foregroundStyle(Theme.Token.text1)
            if Self.showsCount(running: running) {
                Text("\(running)").font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text0)
            }
            if needsYou { Circle().fill(Theme.Token.text0).frame(width: 7, height: 7) }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Theme.Token.bg3.opacity(0.0001))
        .modifier(AgentsPillSurface(solid: solid))
        .opacity(idle ? Self.idleOpacity : 1)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentsCopy.label(running: running, needsYou: needsYou))
        .accessibilityAddTraits(.isButton)
    }
}

private struct AgentsPillSurface: ViewModifier {
    var solid: Bool
    func body(content: Content) -> some View {
        if solid { content.background(Theme.Token.bg3, in: Capsule()).overlay(Capsule().strokeBorder(Theme.Token.line, lineWidth: 1)) }
        else { content.background(Theme.Token.bg3.opacity(0.85), in: Capsule()).glassSurface(Capsule()) }
    }
}

/// Where the pill sits when the screenshot tray is up. Pure: coordinates are window space, y down.
enum PillAvoidsTray {
    static let gap: CGFloat = 8
    /// Points to move the pill left so its right edge clears the tray; 0 when the tray is hidden or not beside it.
    static func shift(pill: CGRect, tray: CGRect?) -> CGFloat {
        guard let tray, tray.intersects(CGRect(x: -10_000, y: pill.minY, width: 20_000, height: pill.height)),
              pill.maxX > tray.minX - gap else { return 0 }
        return pill.maxX - (tray.minX - gap)
    }
}

/// The Agents tile. One line per agent ("name · activity"). Needs-you first, with the white dot; collapsed to
/// three rows plus "All N", which opens the full list in place. Builders and mission jobs sit under Background.
struct AgentsTile: View {
    let rows: [ActivityRow]
    /// Teammates' agents in shared repos, one heading each, after this Mac's rows. Empty = exactly Wedge 1.
    var teammates: [TeammateAgents] = []
    var onOpen: (ActivityRow) -> Void = { _ in }
    @State private var expanded: Bool

    static let collapsedRows = 3

    init(rows: [ActivityRow], teammates: [TeammateAgents] = [], expanded: Bool = false, onOpen: @escaping (ActivityRow) -> Void = { _ in }) {
        self.rows = rows; self.teammates = teammates; self.onOpen = onOpen; _expanded = State(initialValue: expanded)
    }

    /// Needs-you first, then seats, then builders and mission jobs.
    static func order(_ rows: [ActivityRow]) -> [ActivityRow] { AgentActivityBuilder.ordered(rows) }
    /// The rows drawn: all when expanded, else the first three. The disclosure row exists past three.
    static func visible(_ rows: [ActivityRow], expanded: Bool) -> (rows: [ActivityRow], hasDisclosure: Bool) {
        let all = order(rows)
        return (expanded ? all : Array(all.prefix(collapsedRows)), all.count > collapsedRows)
    }
    /// Index of the row the Background heading goes above: the first builder or mission job that is not needs-you.
    static func backgroundStart(_ drawn: [ActivityRow]) -> Int? {
        drawn.firstIndex { $0.kind != .seat && !$0.needsYou }
    }

    var body: some View {
        let v = Self.visible(rows, expanded: expanded)
        let bg = Self.backgroundStart(v.rows)
        VStack(alignment: .leading, spacing: 0) {
            heading(AgentsCopy.agents)
            if rows.isEmpty {
                Text(AgentsCopy.nothing).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            ForEach(Array(v.rows.enumerated()), id: \.element.id) { i, r in
                if i == bg { heading(AgentsCopy.background) }
                line(r)
            }
            if v.hasDisclosure { disclosure }
            ForEach(teammates) { TeammateAgentsSection(teammate: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4).padding(.horizontal, 4)
    }

    private func heading(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text2)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
    }

    private var disclosure: some View {
        Button { withAnimation(Motion.list.spring) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Text(AgentsCopy.all(rows.count)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Token.text2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? AgentsCopy.showFewer : AgentsCopy.all(rows.count))
    }

    private func line(_ r: ActivityRow) -> some View {
        Button { onOpen(r) } label: {
            HStack(spacing: 8) {
                Circle().fill(r.needsYou ? Theme.Token.text0 : Color.clear).frame(width: 7, height: 7)
                (Text(r.name).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundColor(Theme.Token.text0)
                 + Text(" · " + (r.browser.map { "\(r.activity) · \($0)" } ?? r.activity))
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.Token.text1))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                ContextMeterView(reading: r.context)
            }
            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The Usage tile: per provider with a reading, two thin bars, the percent and the reset time. A stale reading is
/// noted once, next to the provider name. Not drawn at all when nothing has been read.
struct UsageTile: View {
    let data: UsagePanelData
    var onCheckNow: () -> Void = {}
    var onOpenHistory: () -> Void = {}
    var onOpenTeam: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The heading opens Usage history too: one click from the panel, like T3's Usage icon.
            Button(action: onOpenHistory) {
                HStack(spacing: 4) {
                    Text(AgentsCopy.usage)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(UsageHistoryCopy.link)
            ForEach(data.shownProviders, id: \.self) { p in
                HStack(spacing: 8) {
                    Text(AgentsCopy.provider(p)).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Token.text0)
                    if let note = data.staleNote(p) {
                        Text(note).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1).padding(.horizontal, 12).padding(.top, 4)
                ForEach([UsageKind.fiveHour, .weekly], id: \.self) { k in windowRow(data.window(p, k)) }
            }
            if !data.team.isEmpty { TeamUsageSection(lines: data.team, onOpen: onOpenTeam) }
            if !data.shownProviders.isEmpty { HStack {
                Button(action: onOpenHistory) {
                    Text(UsageHistoryCopy.link).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Token.text1)
                        .frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: onCheckNow) {
                    Text(data.checking ? AgentsCopy.checking : AgentsCopy.checkNow)
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text0)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Theme.Token.line, in: Capsule())
                }
                .buttonStyle(.plain).disabled(data.checking)
            }
            .padding(.horizontal, 12).padding(.vertical, 8) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func windowRow(_ w: UsageWindow) -> some View {
        let dim = w.state != .fresh
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(w.kind == .fiveHour ? AgentsCopy.fiveHour : AgentsCopy.week)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.Token.text2).frame(width: 36, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Token.line)
                        Capsule().fill(dim ? Theme.Token.text2 : ((w.usedPercent ?? 0) >= 80 ? Theme.Token.text0 : Theme.Token.text1))
                            .frame(width: g.size.width * CGFloat(min(100, max(0, w.usedPercent ?? 0)) / 100))
                    }
                }
                .frame(height: 3)
                Text(w.usedPercent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(dim ? Theme.Token.text2 : Theme.Token.text0)
                    .frame(width: 38, alignment: .trailing)
            }
            if let r = UsageText.resetShort(w) {
                Text(r).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false).padding(.leading, 44)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
    }
}
