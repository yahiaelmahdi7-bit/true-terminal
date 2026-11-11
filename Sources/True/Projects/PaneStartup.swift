import Foundation

/// A one-shot "run this instead of a bare shell" for a pane about to be created. Consumed by
/// `EmbeddedTerminal.makeNSView` and never persisted. A restored pane is a plain shell unless the
/// workspace recorded a Claude conversation for it, in which case `WorkspaceModel.init` registers a
/// `--resume` command here before any view exists. (Not an agent: no `launchSpecs`, no `TRUE_AGENT`, never counted by `isAgentPane`.)
@MainActor
final class PaneStartup {
    static let shared = PaneStartup()
    private var commands: [UUID: String] = [:]

    func set(_ command: String, for pane: UUID) { commands[pane] = command }

    /// Returns the command once; a second call (or a pane that never had one) gets nil.
    func take(_ pane: UUID) -> String? { commands.removeValue(forKey: pane) }

    /// Login + interactive so the user's `claude` alias (claude-burn) and PATH apply. When claude exits,
    /// the pane becomes a normal login shell in the repo instead of closing. `--settings` adds True's
    /// hook layer (on top of the user's own settings) so the session reports Working/Needs you/Done.
    /// Boots in bypass mode (the user's everyday mode); a later restore replays whatever mode the session was in.
    nonisolated static func claudeCommand(settings: String) -> String {
        "command -v claude >/dev/null && claude --dangerously-skip-permissions --settings \(AgentLaunch.shellQuote(settings)); exec \"${SHELL:-/bin/zsh}\" -l"
    }

    /// A fresh Claude whose first message is `prompt` (the final positional argument, shell-quoted).
    nonisolated static func claudeCommand(settings: String, prompt: String) -> String {
        "command -v claude >/dev/null && claude --dangerously-skip-permissions --settings \(AgentLaunch.shellQuote(settings)) \(AgentLaunch.shellQuote(prompt)); exec \"${SHELL:-/bin/zsh}\" -l"
    }

    /// Resume a recorded conversation in its pane; nil unless `sessionID` is a UUID (it goes into a shell line).
    /// `prompt` (interrupted sessions only) rides as the final positional argument: the session's first message.
    /// Always bypass, whatever mode the session was last in: a restart never brings a pane back in auto or plan.
    nonisolated static func resumeCommand(sessionID: String, settings: String, prompt: String? = nil) -> String? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        let tail = prompt.map { " " + AgentLaunch.shellQuote($0) } ?? ""
        return "claude --resume \(sessionID) --dangerously-skip-permissions --settings \(AgentLaunch.shellQuote(settings))\(tail); exec \"${SHELL:-/bin/zsh}\" -l"
    }

    /// tru's ids are `<unix secs>-<pid>`; anything else never reaches a shell line.
    nonisolated static func validTruID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && !id.hasPrefix(".")
            && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 45 || $0 == 95 }
    }

    /// Bring a tru pane back: the same command as typed (`tru-next` stays `tru-next`), falling back to its absolute
    /// path when the command is not on PATH, on the same conversation. Empty `sessionID` = a tru with no conversation
    /// yet, started fresh. nil when the id, provider or command is not safe to put in a shell line.
    nonisolated static func truCommand(_ tru: TruInfo, sessionID: String, prompt: String? = nil) -> String? {
        guard tru.provider == "claude" || tru.provider == "codex", !tru.cmd.isEmpty, !tru.cmd.contains("\n"),
              sessionID.isEmpty || validTruID(sessionID) else { return nil }
        let q = AgentLaunch.shellQuote
        var args = tru.provider == "codex" ? " --codex" : ""
        if !sessionID.isEmpty { args += " --resume \(q(sessionID))" }
        if let p = prompt, !sessionID.isEmpty { args += " --prompt \(q(p))" }
        let run = "\(q(tru.cmd))\(args)"
        if let exe = tru.exe, exe.hasPrefix("/"), !exe.contains("\n") {
            return "if command -v \(q(tru.cmd)) >/dev/null 2>&1; then \(run); else \(q(exe))\(args); fi; exec \"${SHELL:-/bin/zsh}\" -l"
        }
        return "\(run); exec \"${SHELL:-/bin/zsh}\" -l"
    }

    /// `command` after a `seconds` wait, so a relaunch never boots every restored Claude in the same second.
    /// Ctrl-C ends the wait early: without the trap zsh aborts the whole line and the pane closes.
    nonisolated static func staggered(_ command: String, after seconds: Int) -> String {
        guard seconds > 0 else { return command }
        return "trap 'true' INT; printf '\\033[2mTrue: waking this session in \(seconds)s so the Mac is not swamped (Ctrl-C = now)\\033[0m\\n'; sleep \(seconds); trap - INT; \(command)"
    }

    /// The shell argv that runs `command`.
    nonisolated static func shellArgs(for command: String) -> [String] { ["-l", "-i", "-c", command] }
}
