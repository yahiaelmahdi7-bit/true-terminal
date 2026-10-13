import Foundation

/// Pure builders for how an awake agent starts: the role card it boots with and the exact `claude`
/// argv. Nothing here executes anything — `AgentLaunchTests` asserts on the returned strings.
enum AgentLaunch {
    /// The exact argv (argv[0] = "claude", resolved by the pane's login shell).
    static func argv(_ a: Agent, paths: AgentPaths, resumeID: String?, initialPrompt: String? = nil) -> [String] {
        var v = ["claude",
                 "--name", a.name,
                 "--model", a.model.rawValue,
                 "--effort", a.effort.rawValue,
                 "--permission-mode", a.permission.rawValue,
                 "--append-system-prompt-file", paths.rolePath(a.name),
                 "--settings", paths.settingsPath(a.name)]
        if let id = resumeID, !id.isEmpty { v += ["--resume", id] }
        if let p = initialPrompt, !p.isEmpty { v.append(p) }   // positional prompt: always last
        return v
    }

    /// POSIX single-quote: survives the pane's `sh -c` wrap untouched.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// What the pane's login shell runs: argv[0] goes through `~/.claude/bin/claude-burn` when it is installed
    /// (the same launcher as the user's `claude` alias, so seats get burn-control resets), plain `claude`
    /// otherwise. `exec` makes the launcher the pane's pid with claude as its child in the same process group;
    /// `AgentRegistry.sleep` signals the group. A missing `claude` leaves a usable shell and says why,
    /// rather than a pane that flashes and vanishes.
    static func shellCommand(argv: [String]) -> String {
        #"L="$HOME/.claude/bin/claude-burn"; [ -x "$L" ] || L=claude; "#
            + #"command -v "$L" >/dev/null 2>&1 || { echo "True: 'claude' was not found on PATH"; exec "${SHELL:-/bin/zsh}" -l; }; exec "$L""#
            + argv.dropFirst().map { " " + shellQuote($0) }.joined()
    }

    /// Claude keeps a repo's transcripts in `<config>/projects/<cwd with / and . as ->/<id>.jsonl`.
    /// `--resume` finds a session only under the cwd it boots in, and an unknown id would fail the
    /// boot — so resume only when the id is a UUID (it goes into a shell line) AND that file exists.
    static func resumeID(for a: Agent, claudeDir: URL = claudeConfigDir) -> String? {
        guard let id = a.lastSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              UUID(uuidString: id) != nil else { return nil }
        let cwd = a.repo.isEmpty ? NSHomeDirectory() : a.repo   // a global with no folder boots in home
        return transcriptExists(id: id, cwd: cwd, claudeDir: claudeDir) ? id : nil
    }

    /// Where Claude Code keeps session `id`'s transcript for `cwd`: `<claudeDir>/projects/<slugged cwd>/<id>.jsonl`.
    /// The one slug rule (`/` and `.` become `-`); PaneResume's check and the Results sheet both use it.
    static func transcriptURL(id: String, cwd: String, claudeDir: URL = claudeConfigDir) -> URL {
        let project = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return claudeDir.appendingPathComponent("projects/\(project)/\(id).jsonl")
    }

    /// Is there a transcript for session `id` under `cwd`? (`id` must already be trusted as a UUID.)
    static func transcriptExists(id: String, cwd: String, claudeDir: URL = claudeConfigDir) -> Bool {
        guard UUID(uuidString: id) != nil else { return false }
        return FileManager.default.fileExists(atPath: transcriptURL(id: id, cwd: cwd, claudeDir: claudeDir).path)
    }

    static var claudeConfigDir: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    // MARK: Role card

    /// The standing brief (`--append-system-prompt-file`), rewritten on every wake so an edited
    /// charter or team reaches the agent next boot with nothing to invalidate.
    static func roleCard(_ a: Agent, all: [Agent]) -> String {
        let slug = AgentNaming.repoSlug(a.repo)
        var out: String
        switch a.role {
        case .lead:
            let helpers = a.team.isEmpty
                ? "You have no helpers configured yet — do the work yourself."
                : a.team.map { name -> String in
                    let m = all.first { $0.name == name }
                    return "- `\(name)`" + (m.map { " (\($0.model.label), \($0.effort.label) effort)" } ?? "")
                }.joined(separator: "\n")
            out = """
            # Role: Lead on \(a.repoName)

            You are `\(a.name)`, the lead agent for \(a.repoName) (\(a.repo)). The user talks to you;
            you hand bounded work to your helpers and stay accountable for the result.

            Your helpers:
            \(helpers)

            ## Protocol
            1. Split the request into bounded tasks. Each hand-off names the owner, the objective, the
               files they may touch and how you will check the result.
            2. Hand work to a helper with `truectl summon <helper> "<brief>"` — it wakes a helper that is
               asleep and delivers the brief (truectl is at ~/.true/bin/truectl and on your PATH). For a
               helper that is already awake, `SendMessage` to its name (`to: "<helper name>"`) also works.
            3. Review what comes back (diff, tests) before calling anything done. Report outcomes with
               evidence, never on a helper's word alone.
            4. If a helper is waiting on a decision only you can make, answer it before anything else.
            5. A global agent may summon you. When it does, do the work through your helpers as usual and
               reply to that global agent by name with `SendMessage` when done or blocked.
            6. Run `truectl status` before starting anything sizeable: it lists every agent and, under
               `hub`, every background build and other live session — so you do not duplicate work.
            7. For long or unattended work, start a background build: `truectl spawn --name <name>
               --prompt-file <file> [--repo <path>] [--worktree] [--model sonnet]`. It survives context
               resets and shows under Background in the Hub. Use `truectl summon` instead when the work
               is interactive and needs a helper seat.
            """
        case .helper:
            let lead = all.first { $0.role == .lead && AgentNaming.repoSlug($0.repo) == slug }?.name
                ?? AgentNaming.leadName(slug: slug)
            out = """
            # Role: Helper on \(a.repoName)

            You are `\(a.name)`, a helper agent for \(a.repoName) (\(a.repo)). Your lead is `\(lead)`.

            ## Protocol
            1. Work on what your lead assigns, inside the files they name. Do not widen scope.
            2. When done, reply to whoever summoned you (named in the brief), else to `\(lead)`, with
               `SendMessage`: a one-line summary, what changed and the verification output. No "done"
               without evidence.
            3. If you are blocked or need a decision, message whoever summoned you (else `\(lead)`) with
               the exact question, then stop.
            """
        case .watcher:
            // Never woken into a pane; the Watcher's real role card is written by `Investigation.roleCard`.
            out = "# Role: Watcher `\(a.name)`\n\nOn duty; investigates read-only."
        case .global:
            let leads = a.team.isEmpty
                ? "You have no leads configured yet — do the work yourself."
                : a.team.map { name -> String in
                    let m = all.first { $0.name == name }
                    return "- `\(name)`" + (m.map { " (\($0.model.label), \($0.effort.label) effort) — repo \($0.repoName)" } ?? "")
                }.joined(separator: "\n")
            out = """
            # Role: Global agent `\(a.name)`

            You are `\(a.name)`, a global agent for the user. You work across repositories by briefing their
            lead agents; you do not edit a repo that has a lead yourself.

            Leads you may summon:
            \(leads)

            ## Protocol
            1. `truectl status` shows every agent and whether it is awake (truectl is at
               ~/.true/bin/truectl and on your PATH).
            2. Hand work to a lead with `truectl summon <lead> "<brief>"` — it wakes the lead if asleep and
               delivers the brief. A brief names the objective, the files or areas in scope, and how you
               will check the result.
            3. The lead replies to you by name with `SendMessage`. Wait for that reply; do not re-summon
               the same brief.
            4. Review what comes back before reporting to the user; report with evidence, never on a
               lead's word alone.
            """
        }
        let charter = a.charter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !charter.isEmpty { out += "\n\n## Charter\n\(charter)" }
        return out + "\n"
    }
}
