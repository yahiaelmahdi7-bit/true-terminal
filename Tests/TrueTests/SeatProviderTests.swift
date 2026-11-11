import Foundation
import Testing
@testable import True

@Suite struct SeatProviderTests {
    func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    @Test func claudeBytesMatchBeforeProviderExtraction() {
        let agent = Agent(name: "lead-app", role: .lead, repo: "/p/app", model: .opus, effort: .high, permission: .plan)
        let paths = AgentPaths(root: URL(fileURLWithPath: "/tmp/tr"))
        let expected = ["claude", "--name", "lead-app", "--model", "opus", "--effort", "high", "--permission-mode", "plan",
                        "--append-system-prompt-file", "/tmp/tr/roles/lead-app.md", "--settings", "/tmp/tr/hooks/lead-app.settings.json", "--resume", "abc", "hello"]
        let expectedShell = #"L="$HOME/.claude/bin/claude-burn"; [ -x "$L" ] || L=claude; command -v "$L" >/dev/null 2>&1 || { echo "True: 'claude' was not found on PATH"; exec "${SHELL:-/bin/zsh}" -l; }; exec "$L" '--name' 'lead-app' '--model' 'opus' '--effort' 'high' '--permission-mode' 'plan' '--append-system-prompt-file' '/tmp/tr/roles/lead-app.md' '--settings' '/tmp/tr/hooks/lead-app.settings.json' '--resume' 'abc' 'hello'"#
        let provider = SeatProviders.for(agent)
        #expect(provider.argv(for: agent, paths: paths, resumeID: "abc", initialPrompt: "hello") == expected)
        #expect(provider.shellCommand(argv: expected) == expectedShell)
        #expect(AgentLaunch.argv(agent, paths: paths, resumeID: "abc", initialPrompt: "hello") == expected)
        #expect(AgentLaunch.shellCommand(argv: expected) == expectedShell)
        #expect(!provider.startsOnFirstPrompt)
    }
    @Test func permissionsAndEffort() {
        #expect(CodexSeat.tomlString("/tmp/seat") == "\"/tmp/seat\"")
        let paths = AgentPaths(root: URL(fileURLWithPath: "/tmp/tr")), provider = CodexSeat()
        for permission in AgentPermission.allCases {
            for effort in AgentEffort.allCases {
                let agent = Agent(name: "seat", role: .helper, repo: "/tmp", effort: effort, permission: permission, provider: .codex)
                let args = provider.argv(for: agent, paths: paths, resumeID: "saved", initialPrompt: "hello")
                #expect(args.prefix(3) == ["codex", "resume", "saved"])
                #expect(args[4] == ([.acceptEdits, .auto].contains(permission) ? "workspace-write" : "read-only"))
                #expect(args[6] == ([.default, .acceptEdits].contains(permission) ? "on-request" : "never"))
                #expect(args.contains("model_reasoning_effort=\"\(effort == .max ? "xhigh" : effort.rawValue)\""))
                #expect(args.last == "hello" && !args.contains("--model") && args.contains("--dangerously-bypass-hook-trust"))
            }
        }
    }
    @Test func dashLedPromptStaysThePrompt() {
        let paths = AgentPaths(root: URL(fileURLWithPath: "/tmp/tr")), provider = CodexSeat()
        let agent = Agent(name: "seat", role: .helper, repo: "/tmp", provider: .codex)
        #expect(provider.argv(for: agent, paths: paths, resumeID: nil, initialPrompt: "- fix the header").suffix(2) == ["--", "- fix the header"])
        #expect(provider.argv(for: agent, paths: paths, resumeID: "saved", initialPrompt: nil).last == "--no-daemon")
    }
    @Test func hostileRoleCardSurvivesTheShell() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AgentPaths(root: dir), provider = CodexSeat(configDir: dir)
        let agent = Agent(name: "seat", role: .helper, repo: dir.path, provider: .codex)
        provider.install(for: agent, all: [agent], paths: paths)
        let hostile = "quotes ' \" $HOME `touch BAD` $(touch WORSE)\\line\nsecond line ☀"
        try hostile.write(toFile: paths.rolePath(agent.name), atomically: true, encoding: .utf8)
        let fake = dir.appendingPathComponent("codex")
        try "#!/usr/bin/python3\nimport json,sys,os\nprint(json.dumps([os.environ.get('TRUE_PROVIDER'),sys.argv[1:]]))\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let args = provider.argv(for: agent, paths: paths, resumeID: nil, initialPrompt: "hello ' $HOME")
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", provider.shellCommand(argv: args)]
        p.environment = ["PATH": dir.path + ":/usr/bin:/bin"]; p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let json = try #require(try JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [Any])
        #expect(json[0] as? String == "codex")
        #expect(json[1] as? [String] == Array(args.dropFirst()))
        let card = try #require(args.first { $0.hasPrefix("developer_instructions=") })
        let decoded = try JSONDecoder().decode(String.self, from: Data(card.dropFirst("developer_instructions=".count).utf8))
        #expect(decoded == hostile)
    }
    @Test func missingProgramLeavesUsableShell() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let shell = dir.appendingPathComponent("shell")
        try "#!/bin/sh\necho SHELL_READY\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", CodexSeat().shellCommand(argv: ["codex"])]
        p.environment = ["PATH": dir.path, "SHELL": shell.path]; p.standardOutput = out
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "True: 'codex' was not found\nSHELL_READY\n")
    }
    @Test func oldSessionsAndDateFolderLookup() throws {
        let dir = try temp(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = Data(#"{"name":"lead-app","repo":"/tmp","lastSessionID":"AAAAAAAA-1111-4222-8333-444455556666"}"#.utf8)
        var a = try JSONDecoder().decode(Agent.self, from: old)
        let claudeID = a.sessionID
        #expect(a.seatProvider == .claude && a.sessions == nil)
        a.provider = .codex
        #expect(a.sessionID == nil && a.claudeSessionID == nil)
        let id = "01a1bf46-352f-79f1-923b-c3b0278cb43e"
        a.sessionID = id
        #expect(a.lastSessionID == claudeID)
        let codex = CodexSeat(configDir: dir)
        #expect(codex.resumeID(for: a) == nil)
        let folder = dir.appendingPathComponent("sessions/2026/11/09")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("rollout-2026-11-09T11-46-51-\(id).jsonl"))
        #expect(codex.resumeID(for: a) == id)
        let encoded = try JSONEncoder().encode(a)
        #expect(try JSONDecoder().decode(Agent.self, from: encoded) == a)
        a.provider = .claude; #expect(a.sessionID == claudeID)
        a.provider = .codex; a.sessionID = "../../bad"; #expect(codex.resumeID(for: a) == nil)
        let file = dir.appendingPathComponent("agents.json")
        try Data("broken".utf8).write(to: file)
        #expect(AgentStore(url: file).load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agents.corrupt.json").path))
    }
    @Test func capabilityRowsAndAvailability() {
        let known = CodexRuntime(installed: true, version: CodexRuntime.capturedVersion)
        let c = known.capabilities
        #expect(c.rows.map(\.feature) == SeatCapabilities.Feature.allCases)
        for f in [SeatCapabilities.Feature.liveStatus, .needsYou, .answer, .stopTurn, .resume] { #expect(c.supports(f)) }
        for f in [SeatCapabilities.Feature.failure, .usageReset, .overseer, .modelChoice, .handoff] { #expect(!c.supports(f)) }
        let unknown = CodexRuntime(installed: true, version: "new")
        #expect(unknown.capabilities.rows.allSatisfy { !$0.verified && $0.note == "Checked on another Codex version" })
        #expect(!unknown.capabilities.supports(.answer))
        let agent = Agent(name: "seat", role: .helper, repo: "/tmp")
        #expect(CodexRuntime(installed: false, version: nil).disabledReason(for: .codex, agent: agent, awake: false) == "Codex is not installed")
        #expect(known.disabledReason(for: .codex, agent: agent, awake: true) == "Put the seat to sleep to switch")
        #expect(SeatStartupIssue.detect("Welcome to Codex\n1. Sign in with ChatGPT") == .signIn)
        #expect(SeatStartupIssue.detect("Hooks need review\n6 hooks are new or changed") == .hooksApproval)
        #expect(SeatStartupIssue.detect("ordinary output") == nil)
    }
}

@Suite @MainActor struct CodexRegistryTests {
    @Test func restartWaitTimeoutAndTwoWakes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reg-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AgentStore(url: dir.appendingPathComponent("agents.json"))
        let ws = WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("workspace.json")))
        let r = AgentRegistry(store: store, paths: AgentPaths(root: dir), workspace: ws, claudeDir: dir, codexDir: dir)
        let a = Agent(name: "lead-app", role: .lead, repo: dir.path, lastSessionID: UUID().uuidString, provider: .codex)
        r.save(a)
        r.talk(a.name, "first prompt")
        let pane = try #require(r.panes[a.name])
        #expect(r.launchSpecs[pane]?.argv.last == "first prompt") // no SessionStart deadlock
        let tabs = ws.state.tabs.count
        #expect(r.wake(a.name) == pane && ws.state.tabs.count == tabs)
        r.startupTimedOut(a.name, pane: pane)
        #expect(r.startupIssue(for: a.name)?.label == "Needs you: approve True's hooks in the pane")
        #expect(r.statusOf(a.name) == .needsYou)
        let id = UUID().uuidString
        r.handle(PaneEvent(pane: pane, kind: .session, message: id, at: Date()))
        #expect(r.startupIssue(for: a.name) == nil)
        #expect(store.load().first?.sessions?["codex"] == id && store.load().first?.lastSessionID == a.lastSessionID)
        r.startupTimedOut(a.name, pane: pane); #expect(r.startupIssue(for: a.name) == nil)
        var switched = a; switched.provider = .claude
        r.save(switched); #expect(r.agent(named: a.name)?.seatProvider == .codex)
        let saved = ws.state
        let plan = ResumePlan.apply(saved, claudeDir: dir, settings: "none")
        #expect(plan.startups[pane] == nil)
        let ws2 = WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("workspace2.json")))
        ws2.state = plan.state
        let restored = AgentRegistry(store: store, paths: AgentPaths(root: dir), workspace: ws2, claudeDir: dir, codexDir: dir)
        #expect(restored.launchSpecs[pane]?.argv.first == "codex")
        #expect(!restored.launchSpecs[pane]!.argv.contains("resume")) // missing rollout: fresh session
        #expect(restored.capabilities(for: a.name) == SeatProviders.for(a).capabilities)
        let row = ControlResponse.Row(name: a.name, role: "lead", repo: "app", status: "idle", awake: true,
                                      provider: a.seatProvider.label, capabilities: restored.capabilities(for: a.name)!)
        #expect(row.provider == "Codex" && row.capabilities == restored.capabilities(for: a.name))
        #expect(AgentControl.agentRows(restored).first?.capabilities == BuilderDraft(editing: a).capabilities)
        #expect(AgentControl.agentRows(restored).first?.provider == "Codex")
        #expect(!BuilderDraft(editing: Agent(name: "watcher", role: .watcher, repo: "")).showsProviderPicker)
        #expect(ResultsStore.session(for: pane, registry: restored) == nil)
        restored.paneClosed(pane); r.paneClosed(pane)
    }
}
