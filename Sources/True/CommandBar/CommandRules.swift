import Foundation

/// What the bar can do with a line of text.
enum CommandKind: String, CaseIterable, Sendable {
    case shellCommand = "shell_command"
    case agentTask = "agent_task"
    case questionForClaude = "question_for_claude"
    case trueAction = "true_action"
    case none

    /// The two sent to Claude behave the same at the door; they differ only in what the chip says.
    var sendsToClaude: Bool { self == .agentTask || self == .questionForClaude }
}

/// A True verb the bar can run (the same functions the menus call).
enum CommandAction: String, CaseIterable, Sendable {
    case openProject = "open_project", newTab = "new_tab", splitRight = "split_right", splitDown = "split_down"
    case showHub = "show_hub", showResults = "show_results", wakeSeat = "wake_seat", sleepSeat = "sleep_seat"
    case fillDisplays = "fill_displays", none
}

/// What the focused pane is, as far as routing cares.
enum PaneKind: String, Sendable { case shell, claude, seat, empty }

struct FocusedPane: Equatable, Sendable {
    var kind: PaneKind
    var project: String?
    var seat: String?
    var cwd: String? = nil
}

struct BarSeat: Equatable, Sendable {
    var name: String
    var project: String
    var awake: Bool
}

/// Deterministic prefix rules (SPEC Run 14 item 2): the user said which door, so no model second-guesses it.
/// Pure: no network, no panes. The only exceptions to "no keyword lists for judgments", with `isDangerous`.
struct RuleMatch: Equatable, Sendable {
    var kind: CommandKind?          // nil: the rule fixes only the project, Jev picks the door
    var payload: String             // the text to run / send, prefix stripped
    var project: Project? = nil
    var seat: String? = nil
    var action: CommandAction = .none
    /// false = a guess (a bare executable name): it wins only when Jev has nothing better to say.
    var authoritative = true
    /// true = Jev is asked ONLY whether it is destructive; the rest of the route is the rule's.
    var onlyDanger = true
}

enum CommandRules {
    static let actionPhrases: [String: CommandAction] = [
        "new tab": .newTab, "split right": .splitRight, "split down": .splitDown,
        "show hub": .showHub, "hub": .showHub, "results": .showResults, "show results": .showResults,
        "fill all displays": .fillDisplays,
    ]

    static func match(_ raw: String, projects: [Project], seats: [BarSeat], recent: [String] = [],
                      isExecutable: (String) -> Bool = { _ in false }) -> RuleMatch? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let a = actionPhrases[text.lowercased()] {
            return RuleMatch(kind: .trueAction, payload: text, action: a, onlyDanger: false)
        }
        if text.hasPrefix("$ ") || text.hasPrefix("!") {
            let body = text.hasPrefix("!") ? String(text.dropFirst()) : String(text.dropFirst(2))
            let cmd = body.trimmingCharacters(in: .whitespaces)
            return cmd.isEmpty ? nil : RuleMatch(kind: .shellCommand, payload: cmd)
        }
        if text.hasPrefix(">") {
            let body = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : RuleMatch(kind: .agentTask, payload: body)
        }
        if text.hasPrefix("@") {
            let (head, tail) = split(String(text.dropFirst()))
            if !tail.isEmpty, let seat = seat(named: head, in: seats) {
                return RuleMatch(kind: .agentTask, payload: tail, seat: seat)
            }
            return nil
        }
        if text.hasPrefix("/") {
            let (head, tail) = split(String(text.dropFirst()))
            if !head.isEmpty, !tail.isEmpty,
               let p = ProjectMatcher.rank(projects, query: head, recent: recent).first {
                return RuleMatch(kind: nil, payload: tail, project: p, onlyDanger: false)
            }
            return nil
        }
        // A bare executable with no natural-language tail: "ls", "git status", "npm run dev".
        let words = text.split(separator: " ").map(String.init)
        if let first = words.first, isExecutable(first), !hasProseTail(words.dropFirst()) {
            return RuleMatch(kind: .shellCommand, payload: text, authoritative: false, onlyDanger: false)
        }
        return nil
    }

    private static func split(_ s: String) -> (String, String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let i = t.firstIndex(of: " ") else { return (t, "") }
        return (String(t[..<i]), String(t[i...]).trimmingCharacters(in: .whitespaces))
    }

    /// `@ben`, `@cto` and `@true-cto` all reach the seat `true-cto`: its name, its display name, or a "-suffix".
    static func seat(named q: String, in seats: [BarSeat]) -> String? {
        let n = q.lowercased()
        guard !n.isEmpty else { return nil }
        return seats.first { s in
            let name = s.name.lowercased()
            return name == n || name.hasSuffix("-" + n) || CrewDisplay.name(name, repo: s.project).lowercased() == n
        }?.name
    }

    /// The seat a sentence names, whole-word and case-insensitive, over ALL seats awake or asleep: its full name,
    /// its CrewDisplay name, or any "-suffix" of it. Longest term wins; a tie prefers `preferProject`, then order.
    static func namedSeat(in text: String, seats: [BarSeat], preferProject: String? = nil) -> BarSeat? {
        var best: (seat: BarSeat, len: Int, preferred: Bool)?
        for s in seats {
            let name = s.name.lowercased()
            let parts = name.split(separator: "-").map(String.init)
            var terms = [name, CrewDisplay.name(name, repo: s.project).lowercased()]
            terms += parts.indices.dropFirst().map { parts[$0...].joined(separator: "-") }
            for t in Set(terms) where !t.isEmpty && containsWholeWord(text, t) {
                let cand = (seat: s, len: t.count, preferred: s.project == preferProject)
                if best == nil || cand.len > best!.len || (cand.len == best!.len && cand.preferred && !best!.preferred) { best = cand }
            }
        }
        return best?.seat
    }

    static func containsWholeWord(_ text: String, _ term: String) -> Bool {
        let pattern = #"(?<![\p{L}\p{N}-])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}-])"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Words that name the True verb, not the project: "open trading" asks for `trading`.
    private static let verbWords: Set<String> = ["open", "project", "folder", "go", "to", "switch", "launch", "show", "the", "my", "in", "cd"]

    static func stripVerbWords(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).filter { !verbWords.contains($0.lowercased()) }.joined(separator: " ")
    }

    /// Shell builtins that are not files on `$PATH`.
    private static let builtins: Set<String> = [
        "cd", "echo", "export", "alias", "unalias", "source", ".", "pwd", "set", "unset", "exit", "type", "history", "jobs", "fg", "bg",
        "eval", "exec", "read", "umask", "ulimit", "wait", "kill", "pushd", "popd", "dirs", "which", "whence", "hash", "builtin",
        "command", "printf", "test", "true", "false", "trap", "shift", "return", "let", "local", "declare", "typeset", "setopt", "unsetopt",
    ]

    /// Could the first word of `text` start a shell command? A path, a builtin, or an executable on `$PATH`.
    static func looksRunnable(_ text: String, isExecutable: (String) -> Bool) -> Bool {
        guard let first = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) else { return false }
        if first.hasPrefix("./") || first.hasPrefix("~/") || first.hasPrefix("/") { return true }
        return builtins.contains(first) || isExecutable(first)
    }

    /// Two or more purely alphabetic words after the command read as a sentence, not arguments.
    private static func hasProseTail(_ tail: ArraySlice<String>) -> Bool {
        tail.filter { w in w.count >= 2 && w.allSatisfy { $0.isLetter } }.count >= 2
    }

    // MARK: Danger list (the SPEC's one allowed keyword exception: the fallback when Jev cannot answer)

    private static let dangerous: [NSRegularExpression] = [
        #"\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*[fF]|-[a-zA-Z]*[fF][a-zA-Z]*[rR]|--recursive|--force)"#,
        #"\bgit\s+push\b"#,
        #"\bsudo\b"#,
        #"(?i)\bdrop\s+(table|database|schema)\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func isDangerous(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        return dangerous.contains { $0.firstMatch(in: text, range: r) != nil }
    }

    /// Shell syntax that chains or substitutes commands: the danger list cannot judge what these run.
    static func isCompound(_ text: String) -> Bool {
        // Line breaks count: each line would run (checked on scalars, since "\r\n" is one Character).
        text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" })
            || ["&&", "||", ";", "|", "$(", "`", ">"].contains { text.contains($0) }
    }
}
