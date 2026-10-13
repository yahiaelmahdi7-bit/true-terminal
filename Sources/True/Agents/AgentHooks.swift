import Foundation

/// The producer side of live status: the files that make `claude` *report* to True instead of
/// being guessed at from the screen. Lifted from Axon's `AgentHooks`, repointed at `~/.true`:
///
/// - `hooks/forward-claude.py` — the hook command. Claude pipes each hook's stdin JSON here; it tags
///   the event with the pane (`$TRUE_PANE_ID`, set on every pane's environment) and writes one line
///   to the events socket.
/// - `bin/truectl` — the agents' command-line door back into True (summon another agent).
/// - `hooks/<agent>.settings.json` — the per-agent `--settings` layer enabling those hooks. It is an
///   EXTRA settings layer, so the user's own `~/.claude/settings.json` (never touched) still applies.
enum AgentHooks {
    /// Claude Code hook events the forwarder is registered for.
    static let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification",
                             "PermissionRequest", "Stop", "StopFailure"]

    /// Write the forwarder (if stale), this agent's settings layer and its role card.
    static func install(for a: Agent, all: [Agent], paths: AgentPaths) {
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.hooksDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: paths.rolesDir, withIntermediateDirectories: true)
        write(paths.forwarderPath, forwarder(socketPath: paths.socketPath), executable: true)
        installClient(paths: paths)
        write(paths.settingsPath(a.name), settingsJSON(paths: paths), executable: false)
        write(paths.rolePath(a.name), AgentLaunch.roleCard(a, all: all), executable: false)
    }

    /// `bin/truectl` alone. Written at launch beside the control socket, so a human pane can run
    /// `truectl status` before any agent has ever woken (waking is what installs the rest).
    static func installClient(paths: AgentPaths) {
        try? FileManager.default.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        write(paths.truectlPath, AgentControl.truectl(socketPath: paths.controlSocketPath), executable: true)
    }

    /// The forwarder plus the agent-less settings layer, so a ⌘↩ tab's claude reports status (and
    /// keeps the screen on while it works) before any named agent has ever woken. Rewrites only if stale.
    static func installPaneHooks(paths: AgentPaths) {
        try? FileManager.default.createDirectory(at: paths.hooksDir, withIntermediateDirectories: true)
        write(paths.forwarderPath, forwarder(socketPath: paths.socketPath), executable: true)
        write(paths.paneSettingsPath, settingsJSON(paths: paths), executable: false)
    }

    private static func write(_ path: String, _ content: String, executable: Bool) {
        if FileManager.default.contents(atPath: path).flatMap({ String(data: $0, encoding: .utf8) }) != content {
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if executable { chmod(path, 0o755) }
    }

    /// The `--settings` file body. Matchers are deliberately omitted so every subtype arrives and
    /// gets classified in Python instead of being filtered by a matcher this Claude build lacks.
    static func settingsJSON(paths: AgentPaths) -> String {
        let command = "python3 \(AgentLaunch.shellQuote(paths.forwarderPath))"
        let entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 10]]]
        var hooks: [String: Any] = [:]
        for e in hookEvents { hooks[e] = [entry] }
        let data = try? JSONSerialization.data(withJSONObject: ["hooks": hooks],
                                               options: [.sortedKeys, .prettyPrinted])
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self)
    }

    /// The classification below is the point of the file: a Notification carries a TYPE and
    /// PermissionRequest carries the exact tool, so every branch turns a hook FACT into an event
    /// kind and nothing has to be guessed from pixels. `TRUE_EVENTS_SOCK` overrides the socket
    /// (used by the round-trip test against a temp socket).
    static func forwarder(socketPath: String) -> String {
        #"""
        #!/usr/bin/env python3
        # True hook forwarder — Claude Code hook stdin JSON -> agent-events.sock, tagged with the pane
        # that owns this session. No pane id = silently do nothing. Always exits 0 and never writes
        # stdout: a hook must never surface as an error inside the agent, and PermissionRequest reads
        # stdout as a permission DECISION — a stray print there would answer prompts for the user.
        import json, os, socket, sys

        # Notification types that mean "stopped, and waiting on the human".
        NEED_TYPES = {"permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"}
        # Wording fallback for a build that omits the type. Narrow: a false "need" interrupts the user.
        NEED_PHRASES = ("needs your permission", "is waiting for your", "permission to use")

        def notification_type(p):
            for key in ("notification_type", "notificationType", "type", "matcher"):
                v = p.get(key)
                if isinstance(v, str) and v:
                    return v
            return ""

        def classify(p):
            name = p.get("hook_event_name", "")
            if name == "Stop":
                return "stop", p.get("last_assistant_message") or ""
            if name == "StopFailure":
                # The turn ended on an API error — never announced as work that finished.
                return "error", p.get("error") or p.get("message") or "the turn ended with an API error"
            if name == "PermissionRequest":
                return "need", "permission to run " + (p.get("tool_name") or "a tool")
            if name == "SessionStart":
                sid = p.get("session_id") or ""
                return ("session", sid) if sid else None
            if name == "UserPromptSubmit":
                return "progress", "prompt"
            if name == "PreToolUse":
                return "progress", p.get("tool_name") or ""
            if name == "Notification":
                message = p.get("message") or ""
                kind = notification_type(p)
                if kind in NEED_TYPES:
                    return "need", message or kind.replace("_", " ")
                if kind == "idle_prompt":
                    return "idle", message
                if not kind and any(x in message.lower() for x in NEED_PHRASES):
                    return "need", message
                return "notification", message
            return None

        def main():
            pane = os.environ.get("TRUE_PANE_ID")
            if not pane:
                return
            payload = json.load(sys.stdin)
            verdict = classify(payload)
            if not verdict:
                return
            event, message = verdict
            wire = {"pane": pane, "event": event, "message": message}
            mode = payload.get("permission_mode")
            if isinstance(mode, str) and mode:
                wire["mode"] = mode
            if payload.get("hook_event_name") == "Stop":
                # The Overseer reads the finished turn from the transcript; the session id matches Hub rows.
                for key, field in (("transcript_path", "transcript"), ("session_id", "session")):
                    v = payload.get(key)
                    if isinstance(v, str) and v:
                        wire[field] = v
            if payload.get("hook_event_name") == "PermissionRequest":
                wire["tool"] = str(payload.get("tool_name") or "")
                args = payload.get("tool_input")
                if isinstance(args, dict):
                    wire["input"] = {k: v[:300] for k, v in args.items() if isinstance(v, str)}
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(os.environ.get("TRUE_EVENTS_SOCK") or SOCKET)
            s.sendall((json.dumps(wire) + "\n").encode())
            s.close()

        try:
            main()
        except Exception:
            pass
        sys.exit(0)
        """#
        .replacingOccurrences(of: "SOCKET)", with: pythonString(socketPath) + ")")
    }

    static func pythonString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
