import Foundation

struct CodexSeat: SeatProviding {
    var configDir: URL = CodexSeat.codexDir
    var kind: SeatProvider { .codex }
    var capabilities: SeatCapabilities { SeatProviders.codexRuntime.capabilities }
    var startsOnFirstPrompt: Bool { true }
    var screen: SeatScreen {
        SeatScreen(dialogVisible: CodexScreen.dialogVisible, answerKeys: ("\r", "\u{1B}"),
                   isBusy: CodexScreen.busy, interruptKey: "\u{1B}")
    }
    static let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "Interrupt"]
    static var codexDir: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex") }
    func install(for agent: Agent, all: [Agent], paths: AgentPaths) {
        install(for: agent, all: all, paths: paths, codexDir: configDir)
    }
    func install(for agent: Agent, all: [Agent], paths: AgentPaths, codexDir: URL) {
        // Reuse the existing role card and forwarder writer; no user Claude settings are touched.
        AgentHooks.installClaude(for: agent, all: all, paths: paths)
        // Only this True-owned profile may be written in Codex's home. Never create a .codex directory.
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return }
        AgentHooks.write(codexDir.appendingPathComponent("true-seat.config.toml").path,
                         Self.profile(all: all + [agent], paths: paths), executable: false)
    }
    static func tomlString(_ text: String) -> String {
        // TOML accepts JSON escapes except the optional escaped slash.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try! encoder.encode(text)
        return String(decoding: data, as: UTF8.self)
    }
    static func profile(all: [Agent], paths: AgentPaths) -> String {
        let folders = Set(all.filter { $0.seatProvider == .codex }.map { $0.repo.isEmpty || !FileManager.default.fileExists(atPath: $0.repo) ? NSHomeDirectory() : $0.repo })
        let projects = folders.sorted().map { "[projects.\(tomlString($0))]\ntrust_level = \"trusted\"\n" }.joined(separator: "\n")
        let command = "python3 \(AgentLaunch.shellQuote(paths.forwarderPath))"
        return projects + "\n[hooks]\n" + hookEvents.map {
            "\($0) = [{hooks=[{type=\"command\",command=\(tomlString(command)),timeout=10}]}]"
        }.joined(separator: "\n") + "\n"
    }
    func argv(for agent: Agent, paths: AgentPaths, resumeID: String?, initialPrompt: String?) -> [String] {
        var args = ["codex"]
        if let resumeID { args += ["resume", resumeID] }
        let sandbox = [.acceptEdits, .auto].contains(agent.permission) ? "workspace-write" : "read-only"
        let approval = [.default, .acceptEdits].contains(agent.permission) ? "on-request" : "never"
        let card = (try? String(contentsOfFile: paths.rolePath(agent.name), encoding: .utf8)) ?? AgentLaunch.roleCard(agent, all: [])
        args += ["-s", sandbox, "-a", approval, "-c", "model_reasoning_effort=\(Self.tomlString(agent.effort == .max ? "xhigh" : agent.effort.rawValue))",
                 "-c", "developer_instructions=\(Self.tomlString(card))", "-p", "true-seat", "--dangerously-bypass-hook-trust", "--no-daemon"]
        // "--" ends the options, so a message that starts with "-" (a list, "--help") is still the prompt.
        if let initialPrompt, !initialPrompt.isEmpty { args += ["--", initialPrompt] }
        return args
    }
    func shellCommand(argv: [String]) -> String {
        "export TRUE_PROVIDER=codex; command -v codex >/dev/null 2>&1 || { echo \"True: 'codex' was not found\"; exec \"${SHELL:-/bin/zsh}\" -l; }; exec "
            + argv.map(AgentLaunch.shellQuote).joined(separator: " ")
    }
    func resumeID(for agent: Agent) -> String? { resumeID(for: agent, codexDir: configDir) }
    func resumeID(for agent: Agent, codexDir: URL) -> String? {
        guard let id = agent.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), UUID(uuidString: id) != nil,
              let files = FileManager.default.enumerator(at: codexDir.appendingPathComponent("sessions"), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
        for case let file as URL in files where file.lastPathComponent.hasSuffix("-\(id).jsonl") && file.lastPathComponent.hasPrefix("rollout-") {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return id }
        }
        return nil
    }
}

/// Codex CLI 0.167.0: match the active dialog footer and selected first option, never quoted prose.
enum CodexScreen {
    static func dialogVisible(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.last == "Press enter to confirm or esc to cancel",
              let question = lines.lastIndex(of: "Would you like to run the following command?") else { return false }
        let dialog = lines[question...]
        return dialog.contains { $0.hasPrefix("Environment:") }
            && dialog.contains { $0.hasPrefix("$ ") }
            && dialog.contains("› 1. Yes, proceed (y)")
            && dialog.contains { $0.hasPrefix("2. Yes, and don't ask again") }
            && dialog.contains { $0.hasPrefix("3. No, and tell Codex what to do differently") }
    }
    static func busy(_ text: String) -> Bool {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(12).contains { line in
                line.range(of: #"^[•◦] Working \([0-9]+[smh](?: [0-9]+s)? • esc to interrupt\)"#,
                           options: .regularExpression) != nil
            }
    }
}
