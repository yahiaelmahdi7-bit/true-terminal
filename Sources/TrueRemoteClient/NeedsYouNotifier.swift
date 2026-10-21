import Foundation

/// Pure decisions behind the phone's lock-screen notifications (no UserNotifications dependency, so `swift test` covers them).
public enum NeedsYouNotifier {
    /// Rows that started needing you since `old` (fire) and ids that stopped needing you (clear their delivered notification).
    /// The next stored set is always `new.needsYouIDs`.
    public static func plan(old: Set<String>, new: HubSnapshot) -> (fire: [HubRow], clear: [String]) {
        let now = new.needsYouIDs
        let fire = new.projects.flatMap(\.rows).filter { $0.statusKey == "needsYou" && !old.contains($0.id) }
        return (fire, old.subtracting(now).sorted())
    }

    /// Rows that just finished a turn: they were `working` in `oldWorking` and are now idle/done (not needs-you, not failed, not gone).
    /// Only rows with a pane qualify, because the notification's only action is a reply into that pane.
    /// The next stored set is `workingIDs(new)`, so one transition fires once.
    public static func donePlan(oldWorking: Set<String>, new: HubSnapshot) -> [HubRow] {
        new.projects.flatMap(\.rows).filter {
            oldWorking.contains($0.id) && $0.pane != nil && ($0.statusKey == "idle" || $0.statusKey == "done")
        }
    }

    public static func workingIDs(_ snap: HubSnapshot) -> Set<String> {
        Set(snap.projects.flatMap(\.rows).filter { $0.statusKey == "working" }.map(\.id))
    }

    public static func isQuestion(_ row: HubRow) -> Bool { row.needKind == "question" }

    public static func title(for row: HubRow) -> String { isQuestion(row) ? "\(row.name) has a question" : "\(row.name) needs you" }

    /// First line the question, second line "tool: detail" when the Mac sent either.
    public static func body(for row: HubRow) -> String {
        let first = (row.question?.isEmpty == false ? row.question : nil) ?? row.cwd ?? "Tap to open"
        let second = [row.tool, row.detail].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
        return second.isEmpty ? first : first + "\n" + second
    }
}

/// What a lock-screen button asks the Mac to do; the phone maps these to `PaneInputIntent`.
public enum LockScreenAnswer: Equatable, Sendable {
    case approve, deny
    case reply(String)

    /// A reply is trimmed and must not be empty.
    public static func reply(trimming text: String) -> LockScreenAnswer? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : .reply(t)
    }

    public var intent: PaneInputIntent {
        switch self { case .approve: return .approve; case .deny: return .deny; case .reply: return .prompt }
    }
    public var text: String { if case .reply(let t) = self { return t } else { return "" } }

    /// Quiet follow-up sentence for outcomes that did not land; nil = nothing to say.
    public static func followUp(for outcome: InputOutcome) -> String? {
        switch outcome {
        case .promptGone: return "That prompt is gone"
        case .noPane: return "That pane is gone"
        case .stuckInComposer: return "Didn't go through"
        default: return nil
        }
    }
}
