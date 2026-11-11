import Foundation

/// Turns the last tool an agent used into one short plain phrase. Raw tool names, ids and full commands
/// never reach the screen. Exact lookups from `docs/designs/t3-parity.md`, not judgments.
enum ActivityPhrase {
    static let unknown = "Working"

    /// `tool` is the tool's name as the hook reports it. For an MCP tool the hook forwarder shows the chip
    /// "MCP" and puts `server:tool` in `detail`; both that and the raw `mcp__server__tool` spelling work.
    /// `detail` is the one-line summary (file path, command, ...).
    static func phrase(tool: String?, detail: String?) -> String {
        guard let name = tool?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return unknown }
        if let server = mcpServer(tool: name, detail: detail) {
            return browser(server: server) != nil ? "Using the browser" : "Using \(server)"
        }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return fileName(detail).map { "Editing \($0)" } ?? "Editing a file"
        case "Read":
            return fileName(detail).map { "Reading \($0)" } ?? "Reading a file"
        case "Grep", "Glob", "LS":
            return "Searching the code"
        case "Bash":
            return bash(detail)
        case "WebFetch", "WebSearch":
            return "Reading the web"
        case "Task", "Agent":
            return "Working with a helper"
        case "TodoWrite":
            return "Planning"
        default:
            return unknown
        }
    }

    /// "Browser" or "Playwright" for the two browser servers, else nil.
    static func browser(server: String) -> String? {
        switch server {
        case "claude-in-chrome": return "Browser"
        case "playwright": return "Playwright"
        default: return nil
        }
    }

    /// The MCP server named by a tool, whichever spelling the source used.
    static func mcpServer(tool: String, detail: String?) -> String? {
        if tool.hasPrefix("mcp__") {
            let server = tool.dropFirst(5).components(separatedBy: "__").first ?? ""
            return server.isEmpty ? nil : server
        }
        if tool == "MCP" {
            let server = (detail ?? "").split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            return server.isEmpty ? nil : server
        }
        return nil
    }

    private static func fileName(_ detail: String?) -> String? {
        guard let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return nil }
        let last = (d as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }

    /// First word of the command with its path stripped; a few well-known commands get a task phrase.
    private static func bash(_ detail: String?) -> String {
        let words = (detail ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first else { return "Running a command" }
        let program = (first as NSString).lastPathComponent
        let second = words.dropFirst().first ?? ""
        switch (program, second) {
        case ("swift", "test"), ("pytest", _), ("npm", "test"), ("python", "-m") where words.dropFirst(2).first == "pytest":
            return "Running tests"
        case ("swift", "build"), ("xcodebuild", _):
            return "Building"
        default:
            // A word with no letters or digits (a stray symbol) is not a program name.
            return program.contains(where: \.isLetter) ? "Running \(program)" : "Running a command"
        }
    }

    /// The browser a tool belongs to, for the 10-minute rule: "Browser", "Playwright" or nil.
    static func browserLabel(tool: String?, detail: String?) -> String? {
        guard let name = tool?.trimmingCharacters(in: .whitespaces),
              let server = mcpServer(tool: name, detail: detail) else { return nil }
        return browser(server: server)
    }
}

/// Which agents drove a browser lately: remembers the newest browser tool use per agent and forgets it
/// after the window. Pure; the clock comes in.
struct BrowserMemory: Equatable {
    static let window: TimeInterval = 10 * 60
    private(set) var seen: [String: (label: String, at: Date)] = [:]

    static func == (a: Self, b: Self) -> Bool {
        a.seen.keys == b.seen.keys && a.seen.allSatisfy { b.seen[$0.key]?.label == $0.value.label && b.seen[$0.key]?.at == $0.value.at }
    }

    mutating func note(agent: String, label: String, at: Date) {
        if let old = seen[agent], old.at > at { return }
        seen[agent] = (label, at)
    }

    /// The label to show, or nil when nothing browser-like happened in the last 10 minutes.
    func label(for agent: String, now: Date) -> String? {
        guard let s = seen[agent], now.timeIntervalSince(s.at) <= Self.window, s.at <= now.addingTimeInterval(60) else { return nil }
        return s.label
    }
}
