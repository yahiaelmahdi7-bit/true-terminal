import SwiftUI

/// One person on the Team board, as the Usage tile's Team section draws it. A person with two Macs is one line.
struct TeamUsageLine: Equatable, Identifiable {
    var id: String
    var name: String
    /// The newest reading's weekly percent; nil = unknown.
    var weeklyPercent: Double?
    /// nil = this reading came from a teammate's Card, which says nothing about lending.
    var lending: Bool? = false
    /// "13:05" when the reading is unknown but was read once; nil = never read.
    var lastRead: String?

    /// "weekly 30% · lending", "weekly 30% · not lending", "weekly 30%" (lending unknown), or "usage unknown · last read 13:05" (all lower-case).
    var detail: String {
        guard let p = weeklyPercent else { return lastRead.map { "usage unknown · last read \($0)" } ?? "usage unknown" }
        return "weekly \(Int(p.rounded()))%" + (lending.map { " · " + ($0 ? "lending" : "not lending") } ?? "")
    }
}

/// One teammate agent in a shared repo. Read-only: no question text, command or id ever reaches this row.
struct TeammateAgentRow: Equatable, Identifiable {
    var id: String
    var name: String
    var activity: String
    var repo: String
    var provider: String
    var model: String
    var needsYou = false
}

/// A teammate heading in the Agents tile with their shared rows; offline = no rows, "offline" beside the name.
struct TeammateAgents: Equatable, Identifiable {
    var id: String { person }
    var person: String
    var rows: [TeammateAgentRow]
    var offline = false

    static let collapsedRows = 3
    /// The "All N" control exists only when something is folded away.
    static func hasDisclosure(rowCount: Int) -> Bool { rowCount > collapsedRows }
    /// The Agents badge: this Mac's agents plus every row of each teammate who is online (offline rows are removed).
    static func badgeCount(own: Int, teammates: [TeammateAgents]) -> Int {
        own + teammates.filter { !$0.offline }.reduce(0) { $0 + $1.rows.count }
    }
    /// Needs-you first, then the order given.
    var ordered: [TeammateAgentRow] { rows.filter(\.needsYou) + rows.filter { !$0.needsYou } }
}

enum GroupCopy {
    static let rename = "Rename…", renamePlaceholder = "Name", team = "Team", offline = "offline", folderNotShared = "Folder not shared yet"
    /// "+1 folder", "+2 folders"; "" for none.
    static func moreFolders(_ n: Int) -> String { n <= 0 ? "" : "+\(n) \(n == 1 ? "folder" : "folders")" }
    static func waitingOn(_ person: String) -> String { "Waiting on \(person)" }
}

struct TeamUsageSection: View {
    let lines: [TeamUsageLine]
    var onOpen: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(GroupCopy.team).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            ForEach(lines) { l in
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.name).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text0)
                        .lineLimit(1).truncationMode(.tail)
                    Text(l.detail).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(l.weeklyPercent == nil ? Theme.Token.text2 : Theme.Token.text1).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .accessibilityElement(children: .ignore).accessibilityLabel("\(l.name), \(l.detail)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
        .contentShape(Rectangle()).onTapGesture(perform: onOpen)
    }
}

struct TeammateAgentsSection: View {
    let teammate: TeammateAgents
    @State private var expanded: Bool
    init(teammate: TeammateAgents, expanded: Bool = false) { self.teammate = teammate; _expanded = State(initialValue: expanded) }

    var body: some View {
        let all = teammate.ordered
        let shown = expanded ? all : Array(all.prefix(TeammateAgents.collapsedRows))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(teammate.person).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                    .lineLimit(1).truncationMode(.tail)
                if teammate.offline {
                    Text(GroupCopy.offline).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            if !teammate.offline {
                ForEach(shown) { line($0) }
                if TeammateAgents.hasDisclosure(rowCount: all.count) {
                    Button { withAnimation(Motion.list.spring) { expanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text(AgentsCopy.all(all.count)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.Token.text2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ r: TeammateAgentRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Circle().fill(r.needsYou ? Theme.Token.text0 : Color.clear).frame(width: 7, height: 7)
                (Text(r.name).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundColor(Theme.Token.text0)
                 + Text(" · " + (r.needsYou ? GroupCopy.waitingOn(teammate.person) : r.activity))
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.Token.text1))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            Text("\(r.repo) · \(r.provider) \(r.model)").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.Token.text2).lineLimit(1).truncationMode(.tail).padding(.leading, 15)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
