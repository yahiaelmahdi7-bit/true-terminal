import SwiftUI
import Observation

/// Recognises Claude Code's permission dialog in a pane's text — the one gate that must pass
/// before Axon presses a key on the user's behalf.
///
/// The shape on screen (box characters stripped):
///
///     Do you want to proceed?
///     ❯ 1. Yes
///       2. Yes, and don't ask again for …
///       3. No, and tell Claude what to do differently (esc)
///     Esc to cancel · Tab to amend
///
/// A dialog only counts as *visible* while it is at the bottom of the SCREEN with its own
/// "Esc to cancel" footer under the options — a numbered "Do you want to…" in Claude's prose sits
/// above the composer, never above that footer.
///
/// Read the rendered screen (`screenText`), never PaneTail: that is the printed stream, where
/// Claude Code draws spaces as cursor moves ("Doyouwanttoproceed?"), the blinking ⏺ keeps
/// appending lines under a dialog that is still waiting, and an answered dialog is never erased.
/// Both were proven on recorded sessions (NeedsYouTests.recordedDialog*).
enum PermissionDialog {
    /// How many lines may follow the last option (the "Esc to cancel" footer and a stray redraw).
    private static let footerAllowance = 3

    static func isVisible(in tail: String) -> Bool {
        let lines = tail.split(separator: "\n")
            .map { line -> String in
                var s = String(line)
                s.removeAll { "│┃┆┇┊┋╎╏|╭╮╰╯─━═┌┐└┘".contains($0) }
                return s.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .suffix(14)
            .map { $0 }

        guard let q = lines.lastIndex(where: { squeezed($0).hasPrefix("doyouwantto") }) else {
            return false
        }
        let below = Array(lines[(q + 1)...])
        // The first option follows the question within a line or two (a tool preview never sits
        // between them in the modern dialog, but allow a little slack).
        guard let one = below.prefix(3).firstIndex(where: { isOption($0, number: 1, word: "yes") }) else {
            return false
        }
        guard let lastOption = below.lastIndex(where: { isOption($0, number: nil, word: nil) }),
              lastOption > one,
              below[(one + 1)...].contains(where: { isOption($0, number: 2, word: nil) })
        else { return false }
        let after = below[(lastOption + 1)...]
        return after.count <= footerAllowance
            && after.contains(where: { squeezed($0).hasPrefix("esctocancel") })
    }

    /// Lowercased with all whitespace gone, so a match survives however the row was drawn.
    private static func squeezed(_ line: String) -> String {
        String(line.lowercased().filter { !$0.isWhitespace })
    }

    /// "1. Yes", "❯ 1. Yes", "> 2. No" — an option row, optionally pinned to a number and a word.
    private static func isOption(_ line: String, number: Int?, word: String?) -> Bool {
        var s = line
        for cursor in ["❯", ">"] where s.hasPrefix(cursor) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let first = s.first, first.isNumber, let n = first.wholeNumberValue,
              s.dropFirst().first == "." else { return false }
        if let number, n != number { return false }
        if let word {
            return s.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(word)
        }
        return true
    }
}

/// One agent that is blocked on the user, as the tray shows it.
struct NeedsYouRow: Identifiable, Equatable {
    enum Status: Equatable {
        case idle
        case sending
        /// The dialog wasn't on screen — nothing was sent.
        case promptGone
        /// A key was sent but the dialog never left the pane.
        case unconfirmed
    }

    let paneID: UUID
    let name: String
    let color: Color
    let question: String
    let tool: String?
    let detail: String?
    let since: Date
    var status: Status = .idle

    var id: UUID { paneID }
}

/// Every pane currently blocked on a permission prompt, oldest first — the model behind the tab
/// bar's "Needs you" tray. Derived from the registry's latest events; the only state it owns is
/// which answers were already delivered and verified.
@MainActor
@Observable
final class NeedsYouQueue {
    static let shared = NeedsYouQueue()

    var trayOpen = false
    private(set) var statuses: [UUID: NeedsYouRow.Status] = [:]
    /// Claude Code has no "permission resolved" hook, so a `.need` stays the pane's latest event
    /// until the next progress/Stop. An answered prompt is remembered by the event stamp it answered.
    private(set) var resolved: [UUID: Date] = [:]

    /// Pure derivation, so the rules are testable without a window.
    static func rows(events: [UUID: PaneEvent],
                     seat: (UUID) -> (name: String, color: Color)?,
                     resolved: [UUID: Date] = [:]) -> [NeedsYouRow] {
        events.compactMap { id, e -> NeedsYouRow? in
            guard e.kind == .need, resolved[id] != e.at else { return nil }
            let who = seat(id)
            return NeedsYouRow(paneID: id, name: who?.name ?? "Agent", color: who?.color ?? .orange,
                               question: e.message, tool: e.tool, detail: e.detail, since: e.at)
        }
        .sorted { $0.since < $1.since }
    }

    var rows: [NeedsYouRow] {
        let reg = AgentRegistry.shared
        return Self.rows(events: reg.latest, seat: { id in
            guard let n = reg.name(for: id) else { return nil }
            return (n, reg.agent(named: n)?.model.tint ?? Theme.text)
        }, resolved: resolved)
        .map { var r = $0; r.status = statuses[$0.paneID] ?? .idle; return r }
    }

    func answer(_ row: NeedsYouRow, approve: Bool) {
        guard statuses[row.paneID] != .sending else { return }
        statuses[row.paneID] = .sending
        let paneID = row.paneID
        let stamp = row.since
        PaneDelivery.write(PaneDelivery.answerKey(approve: approve), intent: .answer(approve: approve),
                           to: paneID) { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                switch outcome {
                case .landed:
                    self.statuses[paneID] = nil
                    self.resolved[paneID] = stamp
                case .promptGone, .noPane:
                    self.statuses[paneID] = .promptGone
                default:
                    self.statuses[paneID] = .unconfirmed
                }
            }
        }
    }

    /// Focus the pane, then close the tray.
    func jump(to paneID: UUID) {
        WorkspaceModel.shared.focus(pane: paneID)
        trayOpen = false
    }
}
