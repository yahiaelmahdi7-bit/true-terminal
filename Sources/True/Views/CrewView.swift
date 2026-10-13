import SwiftUI

/// The Hub's Crew tab body: pure view over a snapshot + closures (no store, no workspace).
struct CrewTabView: View {
    let snapshot: CrewSnapshot?
    var notice: String?
    var onPick: (CrewAgent) -> Void = { _ in }

    var body: some View {
        if let snapshot {
            if snapshot.isEmpty {
                ContentUnavailableView("No crew yet", systemImage: "person.3",
                                       description: Text("Add specialist files to .claude/agents in a project, or ~/.claude/agents for every project."))
            } else {
                list(snapshot)
            }
        } else {
            Spacer()
        }
    }

    private func list(_ s: CrewSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(s.header).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let notice { noticePill(notice) }
                }
                .padding(.horizontal, 4)
                Text("Specialists Claude can call in. Click one to start a prompt.")
                    .font(.callout).foregroundStyle(Theme.hubSecondary).padding(.horizontal, 4).padding(.top, -10)
                ForEach(s.project) { g in
                    section(CrewDisplay.groupTitle(g.title), count: g.agents.count) {
                        ForEach(g.agents) { CrewRow(agent: $0, family: g.title, onPick: onPick) }
                    }
                }
                if !s.global.isEmpty {
                    section(CrewDisplay.groupTitle("Everywhere"), count: nil) {
                        ForEach(s.global) { CrewGlobalGroup(group: $0, onPick: onPick) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 20)
        }
    }

    /// Header line (quiet label + count) over one soft card holding the rows: a single level of nesting.
    private func section<Content: View>(_ title: String, count: Int?, @ViewBuilder _ rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(Theme.hubSecondary)
                Spacer()
                if let count { Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(Theme.hubSecondary) }
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { rows() }
                .padding(4)
                .background(Theme.hubCardFill, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
        }
    }

    private func noticePill(_ text: String) -> some View {
        Label(text, systemImage: "doc.on.clipboard").font(.callout).foregroundStyle(Theme.text).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.white.opacity(0.12), in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
            .transition(.opacity)
    }
}

/// One "Everywhere" team: a header row that folds its members open. Collapsed by default.
private struct CrewGlobalGroup: View {
    let group: CrewGroup
    let onPick: (CrewAgent) -> Void
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HubRowFrame {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.hubSecondary).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                        Text(group.title).font(.callout.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(group.agents.count)").font(.callout.monospacedDigit()).foregroundStyle(Theme.hubSecondary)
                    }
                }
            }
            .buttonStyle(CrewPressStyle())
            .accessibilityLabel("\(group.title), \(group.agents.count) crew members")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open { ForEach(group.agents) { CrewRow(agent: $0, family: CrewGrouping.family(of: $0.name), onPick: onPick) } }
        }
    }
}

struct CrewRow: View {
    let agent: CrewAgent
    let family: String
    let onPick: (CrewAgent) -> Void

    var body: some View {
        Button { onPick(agent) } label: {
            HubRowFrame {
                HStack(alignment: .top, spacing: 12) {
                    // Same avatar as a sleeping Seat: identity hue derived from the name, faded to a hint (asleep).
                    // Colour stays inside the avatar; nothing else in the row is coloured.
                    AgentAvatar(hue: .derived(from: agent.name), symbol: CrewDisplay.symbol(family: family), status: .asleep, size: 32,
                                showsPresence: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CrewDisplay.name(agent.name)).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        if !agent.summary.isEmpty {
                            Text(agent.summary).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(CrewDisplay.model(agent.model)).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                        .padding(.top, 1)
                }
            }
        }
        .buttonStyle(CrewPressStyle())
        .help(agent.fullDescription.isEmpty ? agent.name : agent.fullDescription)
        .accessibilityLabel("\(CrewDisplay.name(agent.name)), \(CrewDisplay.model(agent.model)). \(agent.summary)")
        .accessibilityHint("Starts a prompt for this crew member in the focused Claude pane")
    }
}

/// Plain button with a pressed fill (hover comes from `HubRowFrame`).
private struct CrewPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.08) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Display-only names for Crew. The typed starter prompt keeps the real id (`CrewStarter`): Claude routes by it.
enum CrewDisplay {
    private static let acronyms: Set<String> = ["cto", "ceo", "coo", "cfo", "cmo", "ui", "ux", "qa", "ai", "api"]

    /// `true-cto` -> "CTO", `swift-engineer` -> "Swift Engineer". Drops a leading word shared with the repo/team.
    static func name(_ id: String, repo: String = "true") -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.count > 1, parts[0].lowercased() == repo.lowercased() { parts.removeFirst() }
        return parts.map { acronyms.contains($0.lowercased()) ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func symbol(family: String) -> String {
        switch family {
        case "Lead": "crown"
        case "Engineering": "chevron.left.forwardslash.chevron.right"
        case "Design": "paintbrush"
        case "Security": "shield"
        case "Knowledge": "books.vertical"
        default: "person"
        }
    }

    static func groupTitle(_ title: String) -> String {
        switch title {
        case "Lead": "Leadership"
        case "Everywhere": "All projects"
        default: title
        }
    }

    static func model(_ raw: String) -> String {
        raw == "inherit" ? "Same model" : raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
