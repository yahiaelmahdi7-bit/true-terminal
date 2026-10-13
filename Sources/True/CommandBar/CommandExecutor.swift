import Foundation

/// What Return will do, as a plain value: the whole decision matrix is unit-testable without a pane.
struct Plan: Equatable, Sendable {
    enum Door: Equatable, Sendable {
        case typeInFocusedShell
        case newShellSplit(cwd: String?)
        case writeToFocusedClaude
        case newClaudePane(cwd: String?)
        case seat(String)
        case background(name: String, cwd: String?, model: String)
        case trueAction(CommandAction)
        case nothing
    }
    var door: Door
    /// shell: the text typed. new Claude pane: the `claude` argv. true_action: its argument (project path / seat).
    var argv: [String]
    /// false = the text is typed but Return is left to the user.
    var autoSubmit: Bool
    /// Destructive agent work: the first Return arms ("will ask first"), the second runs.
    var needsSecondReturn: Bool
}

enum CommandExecutor {
    /// Builder's slug alphabet; `stamp` keeps two runs of one sentence apart.
    static func backgroundName(_ text: String, stamp: Int) -> String {
        let words = text.lowercased().split(whereSeparator: { !($0.isLetter && $0.isASCII) && !$0.isNumber }).prefix(4)
        let slug = (["cb"] + words.map(String.init) + [String(stamp % 100_000)]).joined(separator: "-")
        let n = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return SpawnRequest.isValidName(n) ? n : "cb-\(stamp % 100_000)"
    }

    static func plan(route r: Route, background: Bool, context c: CommandContext, stamp: Int = 0,
                     fromPhone: Bool = false) -> Plan {
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = r.project?.path ?? c.focused.cwd
        guard !text.isEmpty || r.kind == .trueAction else {
            return Plan(door: .nothing, argv: [], autoSubmit: false, needsSecondReturn: false)
        }
        switch r.kind {
        case .none:
            return Plan(door: .nothing, argv: [], autoSubmit: false, needsSecondReturn: false)
        case .trueAction:
            let arg = r.action == .openProject ? [r.project?.path].compactMap { $0 } : [r.seat].compactMap { $0 }
            let needsArg = r.action == .openProject || r.action == .wakeSeat || r.action == .sleepSeat
            return Plan(door: (r.action == .none || (needsArg && arg.isEmpty)) ? .nothing : .trueAction(r.action),
                        argv: arg, autoSubmit: true, needsSecondReturn: false)
        case .shellCommand:
            // The danger list is the fallback when Jev says nothing; when neither can judge a compound line, type it only.
            let held = r.isDestructive || CommandRules.isDangerous(text)
                || (r.destructive == nil && CommandRules.isCompound(text))
            let here = c.focused.kind == .shell && r.project == nil
            return Plan(door: here ? .typeInFocusedShell : .newShellSplit(cwd: cwd), argv: [text],
                        autoSubmit: !held, needsSecondReturn: false)
        case .agentTask, .questionForClaude:
            let second = r.isDestructive
            let onClaude = c.focused.kind == .claude || c.focused.kind == .seat
            if background || r.target == .backgroundBuilder {
                let model = r.model?.rawValue ?? AgentModel.sonnet.rawValue
                return Plan(door: .background(name: backgroundName(text, stamp: stamp), cwd: cwd, model: model),
                            argv: [text], autoSubmit: true, needsSecondReturn: second)
            }
            switch r.target {
            case .seat(let n):
                return Plan(door: .seat(n), argv: [text], autoSubmit: true, needsSecondReturn: second)
            case .focusedPane where onClaude:
                return Plan(door: .writeToFocusedClaude, argv: [text], autoSubmit: true, needsSecondReturn: second)
            default:
                // The Mac bar runs without prompts; a pane the phone starts uses auto mode (a checker approves routine steps).
                var argv = ["claude"] + (fromPhone ? ["--permission-mode", "auto"] : ["--dangerously-skip-permissions"])
                if let m = r.model { argv += ["--model", m.rawValue] }
                if let e = r.effort { argv += ["--effort", e.rawValue] }
                argv.append(text)
                return Plan(door: .newClaudePane(cwd: cwd), argv: argv, autoSubmit: true, needsSecondReturn: second)
            }
        }
    }

    /// The startup line for a new Claude pane: the plan's argv plus True's hook settings, ending in a login shell.
    static func startupCommand(argv: [String], settings: String) -> String {
        guard argv.count >= 2 else { return PaneStartup.claudeCommand(settings: settings) }
        let flags = argv.dropFirst().dropLast().map { AgentLaunch.shellQuote($0) }.joined(separator: " ")
        return "claude \(flags) --settings \(AgentLaunch.shellQuote(settings)) \(AgentLaunch.shellQuote(argv.last!)); exec \"${SHELL:-/bin/zsh}\" -l"
    }

    // MARK: Running (touches panes)

    @MainActor
    static func run(_ plan: Plan, route r: Route, workspace: WorkspaceModel = .shared,
                    registry: AgentRegistry = .shared, runner: @escaping BuilderSpawn.Runner = BuilderSpawn.systemRunner,
                    onBackground: @escaping @MainActor (Result<String, SpawnError>) -> Void = { _ in }) {
        let text = plan.argv.last ?? ""
        switch plan.door {
        case .nothing: return
        case .typeInFocusedShell:
            TerminalRegistry.shared.view(for: workspace.selectedTab.focusedPane)?.send(txt: text + (plan.autoSubmit ? "\r" : ""))
        case .newShellSplit(let cwd):
            let dir = cwd ?? workspace.selectedTab.cwds[workspace.selectedTab.focusedPane] ?? NSHomeDirectory()
            let pane = workspace.split(.horizontal, cwd: dir)
            if plan.autoSubmit {
                PaneStartup.shared.set("\(text); exec \"${SHELL:-/bin/zsh}\" -l", for: pane)
            } else {
                Task { @MainActor in
                    for _ in 0..<20 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if let v = TerminalRegistry.shared.view(for: pane) { v.send(txt: text); return }
                    }
                }
            }
        case .writeToFocusedClaude:
            PaneDelivery.write(text, intent: .prompt, to: workspace.selectedTab.focusedPane)
        case .seat(let n):
            registry.talk(n, text)
        case .newClaudePane(let cwd):
            let cmd = startupCommand(argv: plan.argv, settings: AgentPaths.standard.paneSettingsPath)
            workspace.openProjectBeside(path: cwd ?? NSHomeDirectory(), startupCommand: cmd)
        case .background(let name, let cwd, let model):
            guard let file = writePrompt(text, name: name) else { onBackground(.failure(.init("cannot write the prompt file"))); return }
            let req = SpawnRequest(name: name, promptFile: file, repo: cwd, worktree: true, model: model, from: nil)
            Task { @MainActor in
                onBackground(await BuilderSpawn.run(req, callerRepo: cwd, runner: runner))
            }
        case .trueAction(let a):
            runAction(a, arg: plan.argv.first, workspace: workspace, registry: registry)
        }
    }

    @MainActor
    static func runAction(_ a: CommandAction, arg: String?, workspace: WorkspaceModel, registry: AgentRegistry) {
        switch a {
        case .newTab: workspace.newTab()
        case .splitRight: workspace.splitFocused(.horizontal)
        case .splitDown: workspace.splitFocused(.vertical)
        case .showHub: registry.panelOpen = true
        case .showResults: ResultsStore.shared.open()
        case .fillDisplays: MainWindow.fillAllDisplays()
        case .openProject:
            if let p = arg { workspace.openProjectBeside(path: p, startupCommand: nil) }
        case .wakeSeat: if let n = arg { registry.wake(n) }
        case .sleepSeat: if let n = arg { registry.sleep(n) }
        case .none: break
        }
    }

    /// `~/.true/commandbar/prompts/<name>.md`, 0600 inside a 0700 folder (the text may hold anything the user typed).
    static func writePrompt(_ text: String, name: String, dir: URL = CommandBarLog.standard.dir.appendingPathComponent("prompts")) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let url = dir.appendingPathComponent("\(name).md")
        guard fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        chmod(url.path, 0o600)
        return url.path
    }
}
