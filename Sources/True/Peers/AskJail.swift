import Foundation

/// the jail an `ask` runs in. The ask is a short, read-only Claude Code run on a partner's Mac. Three layers, none of
/// them Claude's own judgement: the tool flags, a strict empty MCP config, and the PreToolUse hook `ask-jail` (below), which
/// real-paths every path the model names and refuses anything outside the ask's folder or matching a secret pattern.
enum AskJail {
    static let model = "sonnet"
    static let maxTurns = 8
    static let wallClock: TimeInterval = 180
    static let allowedTools = "Read,Grep,Glob"
    static let disallowedTools = "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task"
    static let emptyMCP = #"{"mcpServers":{}}"#

    /// `~/.true/peers/ask/` — the hook, its decision log and the per-ask settings files.
    static func dir(_ root: URL) -> URL { root.appendingPathComponent("ask", isDirectory: true) }
    static func hookPath(_ root: URL) -> URL { dir(root).appendingPathComponent("ask-jail.py") }
    static func logPath(_ root: URL) -> URL { dir(root).appendingPathComponent("jail.log") }

    /// The whole argument list for `claude`. The prompt rides on `-p`; nothing here comes from the asker except the prompt text.
    static func arguments(prompt: String, settingsFile: String) -> [String] {
        ["-p", prompt, "--model", model, "--max-turns", String(maxTurns),
         "--allowedTools", allowedTools, "--disallowedTools", disallowedTools,
         "--strict-mcp-config", "--mcp-config", emptyMCP,
         "--settings", settingsFile, "--no-session-persistence", "--output-format", "text"]
    }

    /// Write the hook (once per content) and a per-ask settings file that wires it to every tool call, locked to `cwd`.
    /// Returns the settings path, or nil if the files could not be written.
    static func prepare(root: URL, askId: String, cwd: String) -> String? {
        let fm = FileManager.default
        let d = dir(root)
        guard (try? fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        let hook = hookPath(root)
        if (try? String(contentsOf: hook, encoding: .utf8)) != hookScript {
            guard (try? hookScript.write(to: hook, atomically: true, encoding: .utf8)) != nil else { return nil }
        }
        chmod(hook.path, 0o700)
        let cmd = "python3 \(shellQuote(hook.path)) \(shellQuote(cwd)) \(shellQuote(logPath(root).path))"
        let settings: [String: Any] = ["hooks": ["PreToolUse": [["matcher": ".*", "hooks": [["type": "command", "command": cmd]]]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]) else { return nil }
        let file = d.appendingPathComponent("settings-\(askId).json")
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        chmod(file.path, 0o600)
        return file.path
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// argv: hook.py <jail cwd> <log file>; stdin: the PreToolUse JSON. Exit 2 = deny (blocking). Any crash also exits 2.
    /// The log holds a time, the tool name and a reason code. Never a path and never any text.
    static let hookScript = #"""
    #!/usr/bin/env python3
    import fnmatch, json, os, sys, time

    SECRET_NAMES = (".env*", "*.pem", "*.key", "id_*")
    SECRET_DIRS = (".ssh", ".true")
    ALLOWED = ("Read", "Grep", "Glob")
    SKIP_WALK = (".git", "node_modules", ".build")
    WALK_CAP = 20000

    def log(tool, verdict, code):
        try:
            with open(sys.argv[2], "a") as f:
                f.write("%d %s %s %s\n" % (int(time.time()), tool[:24], verdict, code))
        except Exception:
            pass

    def deny(tool, code, why):
        log(tool, "deny", code)
        sys.stderr.write("ask-jail: " + why + "\n")
        sys.exit(2)

    def is_secret(real):
        parts = real.split(os.sep)
        base = parts[-1].lower()
        if any(fnmatch.fnmatch(base, g) for g in SECRET_NAMES):
            return True
        if any(p.lower() in SECRET_DIRS for p in parts[:-1]) or parts[-1].lower() in SECRET_DIRS:
            return True
        return len(parts) >= 2 and parts[-2] == ".git" and parts[-1] == "config"

    def inside(real, jail):
        return real == jail or real.startswith(jail + os.sep)

    def glob_names_secret(pattern):
        last = pattern.replace("\\", "/").split("/")[-1].lower().strip("{}*")
        return (last.startswith(".env") or last.endswith(".pem") or last.endswith(".key") or last.startswith("id_")
                or last in (".ssh", ".true", "config") and ".git" in pattern)

    def holds_secrets(top):
        seen = 0
        for dirpath, dirnames, filenames in os.walk(top, followlinks=False):
            dirnames[:] = [d for d in dirnames if d not in SKIP_WALK]
            for n in filenames + dirnames:
                seen += 1
                if seen > WALK_CAP:
                    return True
                if is_secret(os.path.join(dirpath, n)):
                    return True
        return False

    def main():
        jail = os.path.realpath(sys.argv[1])
        ev = json.load(sys.stdin)
        tool = str(ev.get("tool_name", ""))
        ti = ev.get("tool_input")
        if tool not in ALLOWED:
            deny(tool, "tool", "this tool is not allowed in an ask")
        if not isinstance(ti, dict):
            deny(tool, "input", "unreadable tool input")
        named = [ti[k] for k in ("file_path", "path", "notebook_path") if k in ti]
        if tool in ("Grep", "Glob") and not named:
            named = [jail]
        if not named:
            deny(tool, "input", "no path given")
        for p in named:
            if not isinstance(p, str) or not p or "\x00" in p:
                deny(tool, "input", "bad path")
            full = p if os.path.isabs(p) else os.path.join(jail, p)
            real = os.path.realpath(os.path.expanduser(full) if p.startswith("~") else full)
            if p.startswith("~"):
                deny(tool, "outside", "that path is outside the repo")
            if not inside(real, jail):
                deny(tool, "outside", "that path is outside the repo")
            if is_secret(real):
                deny(tool, "secret", "that path is secret and not readable")
            if tool in ("Grep", "Glob") and os.path.isdir(real) and holds_secrets(real):
                deny(tool, "secret-dir", "that folder holds secret files; name a subfolder without them")
        for k in ("pattern", "glob"):
            if (tool == "Glob" and k == "pattern") or (tool == "Grep" and k == "glob"):
                g = ti.get(k)
                if isinstance(g, str) and g:
                    segs = g.replace("\\", "/").split("/")
                    if g.startswith(("/", "~")) or ".." in segs:
                        deny(tool, "outside", "a pattern may not leave the repo")
                    if glob_names_secret(g):
                        deny(tool, "secret", "that pattern names secret files")
        log(tool, "allow", "ok")

    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.stderr.write("ask-jail: internal error, denied\n")
        sys.exit(2)
    """#
}
