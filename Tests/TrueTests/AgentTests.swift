import Testing
import Foundation
@testable import True

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("true-agents-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct AgentStoreTests {
    func sample() -> [Agent] {
        [Agent(name: "lead-app", role: .lead, repo: "/tmp/app", model: .opus, effort: .xhigh,
               permission: .acceptEdits, charter: "be terse", team: ["helper-1-app"],
               lastSessionID: "2F6B1C0E-1111-4222-8333-444455556666", symbol: "star"),
         Agent(name: "helper-1-app", role: .helper, repo: "/tmp/app")]
    }

    @Test func roundTrip() {
        let store = AgentStore(url: tempDir().appendingPathComponent("agents.json"))
        store.save(sample())
        #expect(store.load() == sample())
    }

    @Test func missingVersionMigrates() throws {
        let url = tempDir().appendingPathComponent("agents.json")
        try Data(#"{"agents":[{"name":"lead-x","repo":"/tmp/x"}]}"#.utf8).write(to: url)
        let loaded = AgentStore(url: url).load()
        #expect(loaded.count == 1)
        #expect(loaded[0].role == .lead)          // inferred from the name
        #expect(loaded[0].model == .sonnet)       // defaulted
        #expect(loaded[0].symbol == "crown")
        // Re-saving stamps the current version.
        AgentStore(url: url).save(loaded)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"version\" : \(AgentsFile.currentVersion)"))
    }

    @Test func corruptFileFallsBackAndIsKeptAside() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("agents.json")
        try Data("{not json".utf8).write(to: url)
        #expect(AgentStore(url: url).load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("agents.corrupt.json").path))
    }
}

@Suite struct AgentNamingTests {
    @Test func slug() {
        #expect(AgentNaming.repoSlug("/Users/example/Projects/Finance Desk") == "finance-desk")
        #expect(AgentNaming.repoSlug("/x/café") == "caf")
        #expect(AgentNaming.repoSlug("/") == "repo")
    }

    @Test func globalNameRules() {
        for ok in ["designer", "arch-2", "ab"] { #expect(AgentNaming.isValidGlobalName(ok), "\(ok)") }
        for bad in ["Lead", "lead-x", "helper-1-x", "-x", "x-", "a", String(repeating: "a", count: 33), "d_x", "2fa", ""] {
            #expect(!AgentNaming.isValidGlobalName(bad), "\(bad)")
        }
        #expect(AgentNaming.isValidGlobalName(String(repeating: "a", count: 32)))
        #expect(AgentNaming.nextName(role: .global, repo: "/p/app", existing: []) == nil)
        #expect(AgentNaming.parse("designer") == nil)
    }

    @Test func leadOnceThenHelpersOneToFour() {
        var names: [String] = []
        let lead = AgentNaming.nextName(role: .lead, repo: "/p/app", existing: names)
        #expect(lead == "lead-app")
        names.append(lead!)
        #expect(AgentNaming.nextName(role: .lead, repo: "/p/app", existing: names) == nil)
        for n in 1...4 {
            let h = AgentNaming.nextName(role: .helper, repo: "/p/app", existing: names)
            #expect(h == "helper-\(n)-app")
            names.append(h!)
        }
        #expect(AgentNaming.nextName(role: .helper, repo: "/p/app", existing: names) == nil)
    }

    @Test func helperSkipsTakenSlot() {
        #expect(AgentNaming.nextName(role: .helper, repo: "/p/app", existing: ["helper-1-app", "helper-3-app"]) == "helper-2-app")
        // another repo's names never collide
        #expect(AgentNaming.nextName(role: .helper, repo: "/p/app", existing: ["helper-1-web"]) == "helper-1-app")
    }

    @Test func parseInvertsBuilders() {
        #expect(AgentNaming.parse("lead-app")?.role == .lead)
        #expect(AgentNaming.parse("helper-3-my-app")?.helper == 3)
        #expect(AgentNaming.parse("helper-3-my-app")?.slug == "my-app")
        #expect(AgentNaming.parse("helper-5-app") == nil)
        #expect(AgentNaming.parse("helper-03-app") == nil)
        #expect(AgentNaming.parse("bob") == nil)
    }
}

@Suite struct AgentLaunchTests {
    let paths = AgentPaths(root: URL(fileURLWithPath: "/tmp/tr"))

    @Test func argvHasEveryFlag() {
        let a = Agent(name: "lead-app", role: .lead, repo: "/p/app", model: .opus, effort: .high, permission: .plan)
        let v = AgentLaunch.argv(a, paths: paths, resumeID: nil)
        #expect(v == ["claude", "--name", "lead-app", "--model", "opus", "--effort", "high",
                      "--permission-mode", "plan",
                      "--append-system-prompt-file", "/tmp/tr/roles/lead-app.md",
                      "--settings", "/tmp/tr/hooks/lead-app.settings.json"])
    }

    @Test func resumeAppendedWhenGiven() {
        let a = Agent(name: "lead-app", role: .lead, repo: "/p/app")
        let v = AgentLaunch.argv(a, paths: paths, resumeID: "abc")
        #expect(Array(v.suffix(2)) == ["--resume", "abc"])
        #expect(!AgentLaunch.argv(a, paths: paths, resumeID: "").contains("--resume"))
    }

    @Test func resumeOnlyWhenIdValidAndTranscriptExists() throws {
        let claude = tempDir()
        let repo = "/p/some.repo"
        let id = UUID().uuidString
        var a = Agent(name: "lead-x", role: .lead, repo: repo, lastSessionID: id)
        #expect(AgentLaunch.resumeID(for: a, claudeDir: claude) == nil)      // no transcript yet
        let proj = claude.appendingPathComponent("projects/-p-some-repo")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try Data().write(to: proj.appendingPathComponent("\(id).jsonl"))
        #expect(AgentLaunch.resumeID(for: a, claudeDir: claude) == id)
        a.lastSessionID = ""
        #expect(AgentLaunch.resumeID(for: a, claudeDir: claude) == nil)      // empty id never resumes
        a.lastSessionID = "not-a-uuid; rm -rf /"
        #expect(AgentLaunch.resumeID(for: a, claudeDir: claude) == nil)      // never reaches a shell line
    }

    @Test func shellCommandQuotesAndExecs() {
        let cmd = AgentLaunch.shellCommand(argv: ["claude", "--name", "it's"])
        #expect(cmd.hasSuffix(#"exec "$L" '--name' 'it'\''s'"#))
    }

    /// Run the real launch line: claude-burn when installed, plain `claude` on PATH when not.
    @Test func shellCommandPrefersClaudeBurn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("burn-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".claude/bin"), path = home.appendingPathComponent("path")
        defer { try? FileManager.default.removeItem(at: home) }
        func fake(_ url: URL, _ tag: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\necho \(tag) \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try fake(path.appendingPathComponent("claude"), "plain")
        func run() throws -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", AgentLaunch.shellCommand(argv: ["claude", "--name", "it's"])]
            p.environment = ["HOME": home.path, "PATH": path.path + ":/usr/bin:/bin"]
            p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try run() == "plain --name it's\n")
        try fake(bin.appendingPathComponent("claude-burn"), "burn")
        #expect(try run() == "burn --name it's\n")
    }

    @Test func burnTokenIsStablePerPane() {
        let pane = UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000000")!
        #expect(EmbeddedTerminal.burnToken(pane) == "true-1a2b3c4d")
        #expect(EmbeddedTerminal.burnToken(pane) == EmbeddedTerminal.burnToken(pane))
    }

    @Test func globalAndLeadCardsTeachSummon() {
        let l = Agent(name: "lead-app", role: .lead, repo: "/p/app", model: .opus, effort: .high)
        let g = Agent(name: "designer", role: .global, repo: "", team: ["lead-app"])
        let card = AgentLaunch.roleCard(g, all: [l, g])
        #expect(card.contains("truectl summon") && card.contains("`lead-app` (Opus, High effort)") && card.contains("repo app"))
        #expect(card.contains("~/.true/bin/truectl"))
        let none = Agent(name: "solo", role: .global, repo: "")
        #expect(AgentLaunch.roleCard(none, all: [none]).contains("You have no leads configured yet"))
        let lead = AgentLaunch.roleCard(l, all: [l, g])
        #expect(lead.contains("truectl summon") && lead.contains("A global agent may summon you"))
    }

    @Test func roleCardsMentionTheProtocol() {
        let h = Agent(name: "helper-1-app", role: .helper, repo: "/p/app")
        let l = Agent(name: "lead-app", role: .lead, repo: "/p/app", charter: "ship small", team: ["helper-1-app"])
        let lead = AgentLaunch.roleCard(l, all: [l, h])
        #expect(lead.contains("SendMessage") && lead.contains("helper-1-app") && lead.contains("ship small"))
        #expect(AgentLaunch.roleCard(h, all: [l, h]).contains("`lead-app`"))
    }

    @Test func settingsJSONCoversEveryHook() throws {
        let json = try #require(JSONSerialization.jsonObject(with: Data(AgentHooks.settingsJSON(paths: paths).utf8)) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(AgentHooks.hookEvents))
        #expect(hooks.keys.contains("PermissionRequest") && hooks.keys.contains("Stop"))
    }
}

@Suite struct PaneEventTests {
    let pane = UUID()
    func line(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesGoodLine() {
        let e = PaneEvent.parse(line: line(#"{"pane":"\#(pane.uuidString)","event":"need","message":"ok","tool":"Bash","input":{"command":"npm test"}}"#))
        #expect(e?.pane == pane && e?.kind == .need && e?.message == "ok")
        #expect(e?.tool == "Bash" && e?.detail == "npm test")
    }

    @Test func rejectsGarbage() {
        #expect(PaneEvent.parse(line: line("nope")) == nil)
        #expect(PaneEvent.parse(line: line(#"{"pane":"x","event":"stop"}"#)) == nil)
        #expect(PaneEvent.parse(line: line(#"{"pane":"\#(pane.uuidString)","event":"bogus"}"#)) == nil)
    }

    @Test func missingMessageIsEmpty() {
        #expect(PaneEvent.parse(line: line(#"{"pane":"\#(pane.uuidString)","event":"stop"}"#))?.message == "")
    }

    /// The real forwarder script → real socket → parsed event. Runs python3 only (never claude).
    @Test func forwarderRoundTrip() throws {
        let root = URL(fileURLWithPath: "/tmp/tr-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(root: root)
        let a = Agent(name: "lead-app", role: .lead, repo: "/tmp")
        AgentHooks.install(for: a, all: [a], paths: paths)

        let sock = "/tmp/t-\(UUID().uuidString.prefix(8)).sock"
        let got = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var event: PaneEvent? }
        let box = Box()
        let listener = AgentEventSocket(path: sock) { box.event = $0; got.signal() }
        #expect(listener.start())
        defer { listener.stop() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", paths.forwarderPath]
        p.environment = ["TRUE_PANE_ID": pane.uuidString, "TRUE_EVENTS_SOCK": sock, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        let stdin = Pipe(); p.standardInput = stdin
        p.standardOutput = Pipe()
        try p.run()
        stdin.fileHandleForWriting.write(Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(got.wait(timeout: .now() + 3) == .success)
        #expect(box.event?.pane == pane && box.event?.kind == .need && box.event?.detail == "ls")
        let out = (p.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        #expect(out.isEmpty)   // a stray stdout line on PermissionRequest would answer the prompt
    }
}

@Suite @MainActor struct RegistryTests {
    func make() -> (AgentRegistry, WorkspaceModel, AgentStore) {
        let dir = tempDir()
        let store = AgentStore(url: dir.appendingPathComponent("agents.json"))
        let ws = WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("workspace.json")))
        let reg = AgentRegistry(store: store, paths: AgentPaths(root: dir), workspace: ws, claudeDir: dir)
        return (reg, ws, store)
    }

    @Test func statusTable() {
        typealias S = AgentStatus
        #expect(S.next(after: .progress, from: .idle) == .working)
        #expect(S.next(after: .need, from: .working) == .needsYou)
        #expect(S.next(after: .stop, from: .working) == .done)
        #expect(S.next(after: .done, from: .working) == .done)
        #expect(S.next(after: .idle, from: .done) == .idle)
        #expect(S.next(after: .error, from: .working) == .idle)
        #expect(S.next(after: .notification, from: .working) == .working)
        #expect(S.next(after: .session, from: .idle) == .idle)
    }

    @Test func agentsStartAsleepAndWakeOnlyMutatesState() throws {
        let (reg, ws, store) = make()
        reg.save(Agent(name: "lead-app", role: .lead, repo: "/tmp"))
        #expect(reg.statusOf("lead-app") == .asleep && !reg.isAwake("lead-app"))
        #expect(AgentRegistry(store: store, paths: reg.paths, workspace: ws).agents.count == 1)
        let tabs = ws.state.tabs.count
        let pane = try #require(reg.wake("lead-app"))
        #expect(ws.state.tabs.count == tabs + 1)
        #expect(ws.selectedTab.customName == "lead-app")
        #expect(reg.name(for: pane) == "lead-app" && reg.statusOf("lead-app") == .idle)
        let spec = try #require(reg.launchSpecs[pane])
        #expect(spec.argv.first == "claude" && spec.argv.contains("lead-app"))
        // waking again focuses, never opens a second tab
        #expect(reg.wake("lead-app") == pane && ws.state.tabs.count == tabs + 1)
        #expect(reg.wake("nobody") == nil)
    }

    @Test func eventsDriveStatusAndSessionIsSaved() throws {
        let (reg, _, store) = make()
        reg.save(Agent(name: "lead-app", role: .lead, repo: "/tmp"))
        let pane = try #require(reg.wake("lead-app"))
        func ev(_ k: PaneEventKind, _ m: String = "") -> PaneEvent { PaneEvent(pane: pane, kind: k, message: m, at: Date()) }
        reg.handle(ev(.progress)); #expect(reg.statusOf("lead-app") == .working)
        reg.handle(ev(.need, "permission")); #expect(reg.statusOf("lead-app") == .needsYou)
        #expect(NeedsYouQueue.rows(events: reg.latest, seat: { _ in nil }).contains { $0.paneID == pane })
        reg.handle(ev(.progress)); #expect(reg.statusOf("lead-app") == .working)
        reg.handle(ev(.stop)); #expect(reg.statusOf("lead-app") == .done)
        let id = UUID().uuidString
        reg.handle(ev(.session, id))
        #expect(reg.agent(named: "lead-app")?.lastSessionID == id)
        #expect(store.load().first?.lastSessionID == id)
        reg.handle(ev(.session, "garbage"))                       // an invalid id is never stored
        #expect(reg.agent(named: "lead-app")?.lastSessionID == id)
    }

    @Test func closingThePaneMakesItAsleepAndKeepsSession() throws {
        let (reg, ws, _) = make()
        reg.save(Agent(name: "lead-app", role: .lead, repo: "/tmp"))
        let pane = try #require(reg.wake("lead-app"))
        reg.handle(PaneEvent(pane: pane, kind: .session, message: UUID().uuidString, at: Date()))
        let kept = reg.agent(named: "lead-app")?.lastSessionID
        ws.paneExited(pane)
        #expect(reg.statusOf("lead-app") == .asleep && reg.launchSpecs[pane] == nil)
        #expect(!ws.state.tabs.contains { $0.tree.contains(pane) })
        #expect(reg.agent(named: "lead-app")?.lastSessionID == kept && kept != nil)
    }

    @Test func groupingIsByRepoLeadFirst() {
        let a = [Agent(name: "helper-2-b", role: .helper, repo: "/p/b"),
                 Agent(name: "helper-1-b", role: .helper, repo: "/p/b"),
                 Agent(name: "lead-b", role: .lead, repo: "/p/b"),
                 Agent(name: "lead-a", role: .lead, repo: "/p/a")]
        let g = AgentRegistry.grouped(a)
        #expect(g.map(\.key) == ["/p/a", "/p/b"] && g.map(\.title) == ["a", "b"])
        #expect(g[1].agents.map(\.name) == ["lead-b", "helper-1-b", "helper-2-b"])
    }

    @Test func globalsFormOneGroupFirst() {
        let a = [Agent(name: "lead-a", role: .lead, repo: "/p/a"),
                 Agent(name: "zed", role: .global, repo: ""),
                 Agent(name: "designer", role: .global, repo: "/p/a")]
        let g = AgentRegistry.grouped(a)
        #expect(g.map(\.title) == ["Global", "a"] && g[0].key == "")
        #expect(g[0].agents.map(\.name) == ["designer", "zed"])
        #expect(AgentRegistry.grouped([Agent(name: "lead-a", role: .lead, repo: "/p/a")]).map(\.title) == ["a"])
    }

    @Test func talkToUnknownAgentReportsNoPane() {
        let (reg, _, _) = make()
        var outcome: PaneDelivery.Outcome?
        reg.talk("ghost", "hi") { outcome = $0 }
        #expect(outcome == .noPane)
    }
}

@Suite struct BuilderDraftTests {
    @Test func nameFollowsRepoAndRole() {
        var d = BuilderDraft(repo: "/p/app", role: .lead)
        #expect(d.name(existing: []) == "lead-app")
        let lead = Agent(name: "lead-app", role: .lead, repo: "/p/app")
        #expect(d.name(existing: [lead]) == nil && !d.canSave(existing: [lead]))
        d.role = .helper
        #expect(d.name(existing: [lead]) == "helper-1-app")
        #expect(BuilderDraft().name(existing: []) == nil)
    }

    @Test func globalNameIsTypedValidatedAndUnique() {
        var d = BuilderDraft(repo: "", role: .global)
        #expect(d.name(existing: []) == nil && !d.canSave(existing: []))
        d.globalName = "  Designer "
        #expect(d.name(existing: []) == "designer")
        #expect(d.name(existing: [Agent(name: "designer", role: .global, repo: "")]) == nil)
        d.globalName = "lead-x"
        #expect(d.name(existing: []) == nil)
        d.globalName = "d_x"
        #expect(d.name(existing: []) == nil)
    }

    @Test func teamChoicesPerRole() {
        let h = Agent(name: "helper-1-app", role: .helper, repo: "/p/app")
        let h2 = Agent(name: "helper-1-web", role: .helper, repo: "/p/web")
        let lb = Agent(name: "lead-web", role: .lead, repo: "/p/web")
        let la = Agent(name: "lead-app", role: .lead, repo: "/p/app")
        let g = Agent(name: "designer", role: .global, repo: "")
        let all = [h, h2, lb, la, g]
        #expect(BuilderDraft(repo: "/p/app", role: .lead).teamChoices(existing: all).map(\.name) == ["helper-1-app"])
        #expect(BuilderDraft(repo: "", role: .global).teamChoices(existing: all).map(\.name) == ["lead-app", "lead-web"])
        #expect(BuilderDraft(repo: "/p/app", role: .helper).teamChoices(existing: all).isEmpty)
    }

    @Test func globalTeamKeepsOnlyRealLeads() throws {
        let la = Agent(name: "lead-app", role: .lead, repo: "/p/app")
        let h = Agent(name: "helper-1-app", role: .helper, repo: "/p/app")
        var d = BuilderDraft(repo: "", role: .global)
        d.globalName = "designer"
        d.team = ["lead-app", "helper-1-app", "lead-ghost"]
        let a = try #require(d.agent(existing: [la, h]))
        #expect(a.team == ["lead-app"] && a.repoName == "Global" && a.symbol == "globe")
    }

    @Test func leadTeamKeepsOnlyRealHelpersOfTheRepo() throws {
        let h = Agent(name: "helper-1-app", role: .helper, repo: "/p/app")
        var d = BuilderDraft(repo: "/p/app", role: .lead)
        d.team = ["helper-1-app", "helper-1-other"]
        #expect(try #require(d.agent(existing: [h])).team == ["helper-1-app"])
    }

    @Test func editingKeepsName() {
        let a = Agent(name: "helper-2-app", role: .helper, repo: "/p/app", model: .haiku)
        var d = BuilderDraft(editing: a)
        d.model = .fable
        #expect(d.agent(existing: [a])?.name == "helper-2-app" && d.agent(existing: [a])?.model == .fable)
    }

    @Test func symbolListIsCurated() {
        #expect(BuilderDraft.symbols.count == 25 && Set(BuilderDraft.symbols).count == 25)
        #expect(Array(BuilderDraft.symbols.prefix(3)) == AgentRole.allCases.filter { $0 != .watcher }.map(\.defaultSymbol))
    }
}
