import SwiftUI

extension VerdictKind {
    /// Monochrome + one colour (Run 8): Unverified is the only warm tint; Blocked / Asks you use the
    /// needs-you tint (white); the rest stay neutral.
    var tint: Color {
        switch self {
        case .unverified: Theme.verdictWarn
        case .blocked, .asksYou: AgentStatus.needsYou.tint
        case .asksToContinue, .partial, .verified: Theme.hubSecondary
        }
    }
}

/// The small verdict capsule beside a status pill.
struct VerdictBadge: View {
    let kind: VerdictKind
    var body: some View {
        // Blocked / Asks you are inverted like the Needs you pill (`AttentionPill`): the most urgent rows must
        // not look like Partial.
        let loud = kind == .blocked || kind == .asksYou
        Text(kind.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(loud ? Color.white : kind.tint.opacity(0.22), in: .capsule)
            .foregroundStyle(loud ? Color.black : kind.tint)
            .accessibilityLabel("Verdict: \(kind.label)")
    }
}

/// One "Your move" line: a pane whose last turn needs a look.
struct YourMoveRow: Identifiable, Equatable {
    let pane: UUID
    let name: String
    let project: String
    let kind: VerdictKind
    let reason: String
    let at: Date
    var id: UUID { pane }

    /// Non-verified verdicts, most urgent first. `name` is the seat name, else the tab title, else the project.
    /// `project` is empty when it would repeat `name` (a plain pane's tab title is usually the folder name).
    @MainActor static func build(_ verdicts: [UUID: OverseerVerdict], seatName: (UUID) -> String?,
                                 tabTitle: (UUID) -> String?) -> [YourMoveRow] {
        OverseerStore.ordered(verdicts).filter { $0.verdict.kind != .verified }.map { p, v in
            let project = HubProject.title(HubProject.key(forCwd: v.cwd ?? ""))
            let name = seatName(p) ?? tabTitle(p) ?? project
            return YourMoveRow(pane: p, name: name,
                               project: name.caseInsensitiveCompare(project) == .orderedSame ? "" : project,
                               kind: v.kind, reason: v.reason, at: v.at)
        }
    }

    var spoken: String { [name, project, kind.label, reason].filter { !$0.isEmpty }.joined(separator: ", ") }
}

struct YourMoveSection: View {
    let rows: [YourMoveRow]
    let now: Double
    var onFocus: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your move").font(.body.weight(.semibold)).foregroundStyle(Theme.text).padding(.horizontal, 4)
            ForEach(rows) { r in
                HubRowFrame {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(r.name).font(.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                if !r.project.isEmpty {
                                    Text(r.project).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                                }
                            }
                            Text(r.reason).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        VerdictBadge(kind: r.kind)
                        Text(hubElapsed(now - r.at.timeIntervalSince1970)).font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.hubSecondary)
                    }
                }
                .onTapGesture { onFocus(r.pane) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(r.spoken)
                .accessibilityHint("Focuses this pane")
                .accessibilityAddTraits(.isButton)
            }
        }
    }
}
