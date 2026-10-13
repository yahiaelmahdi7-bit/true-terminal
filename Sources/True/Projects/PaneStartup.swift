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
        "claude --dangerously-skip-permissions --settings \(AgentLaunch.shellQuote(settings)); exec \"${SHELL:-/bin/zsh}\" -l"
    }

    /// Resume a recorded conversation in its pane; nil unless `sessionID` is a UUID (it goes into a shell line).
    /// `prompt` (interrupted sessions only) rides as the final positional argument: the session's first message.
    nonisolated static func resumeCommand(sessionID: String, settings: String, mode: String? = nil,
                                          prompt: String? = nil) -> String? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        let tail = prompt.map { " " + AgentLaunch.shellQuote($0) } ?? ""
        return "claude --resume \(sessionID)\(permissionFlag(mode)) --settings \(AgentLaunch.shellQuote(settings))\(tail); exec \"${SHELL:-/bin/zsh}\" -l"
    }

    /// Values `claude --permission-mode` accepts (2.1.x `--help`); only these are ever replayed (the value goes into a
    /// shell line). An unaccepted value would stop the resumed session from booting at all.
    nonisolated static let replayableModes: Set<String> = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]

    /// The flag (with leading space) that puts a resumed session back in `mode`; "" for nil or anything unknown.
    /// Hooks report the ask-every-time mode as `default`, which the CLI flag calls `manual`.
    nonisolated static func permissionFlag(_ mode: String?) -> String {
        guard let reported = mode else { return "" }
        let m = reported == "default" ? "manual" : reported
        guard replayableModes.contains(m) else { return "" }
        return m == "bypassPermissions" ? " --dangerously-skip-permissions" : " --permission-mode \(m)"
    }

    /// The shell argv that runs `command`.
    nonisolated static func shellArgs(for command: String) -> [String] { ["-l", "-i", "-c", command] }
}
