import Testing
import Foundation
@testable import True

private func ans(_ type: String, choice: String? = nil, _ conf: Double? = 0.9, noul: Double? = nil, score: Double? = nil) -> JevAnswer {
    JevAnswer(type: type, choice: choice, confidence: conf, probabilities: nil, noul: noul, score: score)
}
private func proj(_ n: String) -> Project { Project(name: n, path: "/p/\(n)", parent: "/p") }
private let shellPane = FocusedPane(kind: .shell, project: "alpha", seat: nil, cwd: "/p/alpha")
private let claudePane = FocusedPane(kind: .claude, project: "alpha", seat: nil, cwd: "/p/alpha")
private func ctx(_ f: FocusedPane = shellPane) -> CommandContext {
    CommandContext(focused: f, projects: [proj("alpha"), proj("beta")], seats: [BarSeat(name: "lead", project: "alpha", awake: true)])
}

@Suite struct CommandRulesTests {
    private let projects = [proj("alpha"), proj("beta")]
    private let seats = [BarSeat(name: "lead", project: "alpha", awake: true)]
    private func m(_ t: String, exe: @escaping (String) -> Bool = { _ in false }) -> RuleMatch? {
        CommandRules.match(t, projects: projects, seats: seats, isExecutable: exe)
    }

    @Test func prefixes() {
        #expect(m("! ls -la")?.kind == .shellCommand && m("! ls -la")?.payload == "ls -la")
        #expect(m("$ pwd")?.payload == "pwd")
        #expect(m("> fix the bug")?.kind == .agentTask)
        #expect(m("!")?.kind == nil && m("!") == nil)
    }
    @Test func seatSuffixNeedsTail() {
        #expect(m("@lead check the build")?.seat == "lead")
        #expect(m("@lead") == nil)
        #expect(m("@nobody hi there") == nil)
    }
    @Test func projectPrefixFixesOnlyProject() {
        let r = m("/beta add tests")
        #expect(r?.kind == nil && r?.project?.name == "beta" && r?.payload == "add tests" && r?.onlyDanger == false)
        #expect(m("/beta") == nil)
    }
    @Test func actionPhrases() {
        #expect(m("Split Right")?.action == .splitRight && m("Split Right")?.kind == .trueAction)
        #expect(m("new tab")?.action == .newTab)
    }
    @Test func bareExecutableIsNotAuthoritative() {
        let r = m("git status", exe: { $0 == "git" })
        #expect(r?.kind == .shellCommand && r?.authoritative == false)
        #expect(m("git is confusing me today", exe: { $0 == "git" }) == nil)
    }
    @Test func dangerAndCompound() {
        #expect(CommandRules.isDangerous("rm -rf /tmp/x"))
        #expect(CommandRules.isDangerous("git push --force origin main"))
        #expect(!CommandRules.isDangerous("ls -la"))
        #expect(CommandRules.isCompound("a && b") && CommandRules.isCompound("echo hi > f") && !CommandRules.isCompound("ls"))
    }
}

@Suite struct CommandRouterTests {
    private func reply(_ a: [String: JevAnswer]) -> JevReply { JevReply(answers: a) }

    @Test func questionShape() {
        let q = CommandRouter.questions(text: "hi", context: ctx(), onlyDanger: false)
        #expect(Set(q.keys).isSuperset(of: ["kind", "project", "target", "action", "model", "effort"] + CommandRouter.dangerQuestions.map(\.id)))
        #expect(!q.keys.contains("destructive"))
        #expect(CommandRouter.questions(text: "hi", context: ctx(), onlyDanger: true).keys.sorted() == ["danger_delete", "danger_deploy", "danger_live", "danger_push", "danger_send"])
    }
    @Test func belowFloorKeepsDefaultsAndMarksUncertain() {
        let r = CommandRouter.route(text: "tidy it", reply: reply(["kind": ans("choice", choice: "agent_task", 0.55)]), context: ctx(shellPane))
        #expect(r.kind == .shellCommand && r.uncertain.contains(.kind))
        #expect(!r.twoChoice)
    }
    @Test func lowKindConfidenceIsTwoChoice() {
        let r = CommandRouter.route(text: "x", reply: reply(["kind": ans("choice", choice: "agent_task", 0.4)]), context: ctx())
        #expect(r.twoChoice)
    }
    @Test func confidentKindApplies() {
        let r = CommandRouter.route(text: "x", reply: reply(["kind": ans("choice", choice: "agent_task", 0.9)]), context: ctx(shellPane))
        #expect(r.kind == .agentTask && r.kindConfidence == 0.9)
    }
    @Test func unknownProjectIDFallsBackToCurrent() {
        let r = CommandRouter.route(text: "x", reply: reply(["project": ans("choice", choice: "p99")]), context: ctx())
        #expect(r.project == nil)
    }
    @Test func unknownSeatTargetIsRejected() {
        let r = CommandRouter.route(text: "x", reply: reply(["kind": ans("choice", choice: "agent_task"),
                                                             "target": ans("choice", choice: "seat_ghost")]), context: ctx(claudePane))
        #expect(r.target == .focusedPane)
    }
    @Test func nilReplyIsDeterministic() {
        let r = CommandRouter.route(text: "x", reply: nil, context: ctx(claudePane))
        #expect(r.kind == .agentTask && r.target == .focusedPane && r.destructive == nil && r.uncertain.isEmpty)
    }
    @Test func ruleKeepsDestructiveFromJev() {
        let rule = RuleMatch(kind: .shellCommand, payload: "supabase db push")
        let r = CommandRouter.route(text: "!supabase db push", reply: reply(["danger_push": ans("noul", 0.9, noul: 0.2), "danger_live": ans("noul", 0.9, noul: 0.8)]), context: ctx(), rule: rule)
        #expect(r.kind == .shellCommand && r.viaRule && r.isDestructive && r.text == "supabase db push")
    }
}

@Suite struct CommandExecutorTests {
    private func route(_ k: CommandKind, text: String = "do it", destructive: Double? = nil, target: CommandTarget = .focusedPane,
                       model: AgentModel? = nil, effort: AgentEffort? = nil) -> Route {
        Route(text: text, kind: k, kindConfidence: 0.9, project: nil, target: target, action: .none, seat: nil,
              destructive: destructive, model: model, effort: effort)
    }
    private func plan(_ r: Route, _ f: FocusedPane = shellPane, bg: Bool = false) -> Plan {
        CommandExecutor.plan(route: r, background: bg, context: ctx(f), stamp: 42)
    }

    @Test func shellTypedHereOrSplit() {
        #expect(plan(route(.shellCommand, text: "ls", destructive: 0.1)) == Plan(door: .typeInFocusedShell, argv: ["ls"], autoSubmit: true, needsSecondReturn: false))
        #expect(plan(route(.shellCommand, text: "ls", destructive: 0.1), claudePane).door == .newShellSplit(cwd: "/p/alpha"))
    }
    @Test func shellHeldWhenDestructiveDangerousOrUnjudgedCompound() {
        #expect(!plan(route(.shellCommand, text: "ls", destructive: 0.9)).autoSubmit)
        #expect(!plan(route(.shellCommand, text: "rm -rf build", destructive: 0.1)).autoSubmit)
        #expect(!plan(route(.shellCommand, text: "a && b", destructive: nil)).autoSubmit)
        #expect(plan(route(.shellCommand, text: "a && b", destructive: 0.1)).autoSubmit)
        #expect(plan(route(.shellCommand, text: "ls", destructive: nil)).autoSubmit)
    }
    @Test func agentDoors() {
        #expect(plan(route(.agentTask), claudePane).door == .writeToFocusedClaude)
        #expect(plan(route(.agentTask, target: .seat("lead")), claudePane).door == .seat("lead"))
        let p = plan(route(.agentTask, target: .newClaudePane, model: .opus, effort: .high), shellPane)
        #expect(p.door == .newClaudePane(cwd: "/p/alpha"))
        #expect(p.argv == ["claude", "--dangerously-skip-permissions", "--model", "opus", "--effort", "high", "do it"])
    }
    @Test func backgroundNameIsValidAndModelDefaultsToSonnet() {
        let p = plan(route(.agentTask, text: "Fix: the Weird_name!! now please"), shellPane, bg: true)
        guard case .background(let name, _, let model) = p.door else { Issue.record("not background"); return }
        #expect(SpawnRequest.isValidName(name) && model == "sonnet")
    }
    @Test func destructiveAgentWorkNeedsSecondReturn() {
        #expect(plan(route(.agentTask, destructive: 0.8), claudePane).needsSecondReturn)
        #expect(!plan(route(.agentTask, destructive: 0.1), claudePane).needsSecondReturn)
    }
    @Test func trueActionArgs() {
        var r = route(.trueAction); r.action = .splitRight
        #expect(plan(r).door == .trueAction(.splitRight))
        r.action = .wakeSeat; r.seat = nil
        #expect(plan(r).door == .nothing)
        r.seat = "lead"
        #expect(plan(r).argv == ["lead"])
        #expect(plan(route(.none)).door == .nothing)
    }
    @Test func promptFilePermissions() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "cb-\(UUID().uuidString)/prompts")
        let f = try #require(CommandExecutor.writePrompt("secret task", name: "cb-x", dir: dir))
        let attr = { (p: String) in ((try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? Int) ?? 0 }
        #expect(attr(f) == 0o600 && attr(dir.path) == 0o700)
    }
}

@Suite struct CommandBarLogTests {
    private func tmp() -> URL { URL(fileURLWithPath: NSTemporaryDirectory() + "cbl-\(UUID().uuidString)") }
    private func perm(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int) ?? 0 }

    @Test func redactsAndLocksDown() throws {
        let log = CommandBarLog(dir: tmp())
        log.append(.init(event: .run, text: "deploy with API_KEY=sk-abcdef1234567890abcdef"))
        let s = try String(contentsOf: log.file, encoding: .utf8)
        #expect(!s.contains("sk-abcdef1234567890abcdef"))
        #expect(perm(log.file) == 0o600 && perm(log.dir) == 0o700)
    }
    @Test func rotatesOverFiveMB() throws {
        let log = CommandBarLog(dir: tmp())
        log.append(.init(event: .read, text: "one"))
        let h = try FileHandle(forWritingTo: log.file); try h.truncate(atOffset: UInt64(CommandBarLog.maxBytes + 10)); try h.close()
        log.append(.init(event: .read, text: "two"))
        #expect(FileManager.default.fileExists(atPath: log.rotated.path))
        #expect(try String(contentsOf: log.file, encoding: .utf8).contains("two"))
    }
    @Test func historyCapDedupeRedact() {
        var h: [String] = []
        for i in 0..<60 { h = CommandBarLog.pushed("cmd \(i)", onto: h) }
        #expect(h.count == 50 && h.first == "cmd 59")
        h = CommandBarLog.pushed("cmd 30", onto: h)
        #expect(h.first == "cmd 30" && h.filter { $0 == "cmd 30" }.count == 1)
        #expect(!CommandBarLog.pushed("TOKEN=sk-abcdef1234567890abcdef", onto: []).joined().contains("sk-abcdef1234567890abcdef"))
        let log = CommandBarLog(dir: tmp()); log.saveHistory(h)
        #expect(log.loadHistory() == h && perm(log.historyFile) == 0o600)
    }
}

@MainActor
@Suite struct CommandBarStoreTests {
    private func body(kind: String = "shell_command", conf: Double = 0.9, destructive: Double = 0.1) -> Data {
        Data("""
        {"model":"jev","answers":{"kind":{"type":"choice","choice":"\(kind)","confidence":\(conf)},
         "danger_push":{"type":"noul","noul":\(destructive)}}}
        """.utf8)
    }
    private final class Box { var plans: [Plan] = [] }
    private func make(_ t: FakeJev, _ box: Box, focused: FocusedPane = claudePane) -> CommandBarStore {
        CommandBarStore(jev: JevClient(transport: t, keyProvider: { "k" }, env: [:]), enabled: { true },
                        log: CommandBarLog(dir: URL(fileURLWithPath: NSTemporaryDirectory() + "cbs-\(UUID().uuidString)")),
                        environment: { BarEnvironment(focused: focused, projects: [proj("alpha"), proj("beta")], recent: [], seats: []) },
                        isExecutable: { $0 == "ls" }, execute: { p, _ in box.plans.append(p) }, debounce: .milliseconds(1))
    }
    private func settle(_ s: CommandBarStore) async {
        for _ in 0..<300 { if !s.reading { return }; try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func closedBarMakesNoCalls() async {
        let t = FakeJev(.reply(200, body())); let s = make(t, Box())
        s.text = "hello"
        try? await Task.sleep(for: .milliseconds(50))
        #expect(t.requests.isEmpty && s.route == nil)
    }
    @Test func typingOpensOneReadAndAppliesIt() async {
        let t = FakeJev(.reply(200, body(kind: "shell_command"))); let s = make(t, Box())
        s.show(); s.text = "ls the logs"
        await settle(s)
        #expect(t.requests.count == 1 && s.route?.kind == .shellCommand && !s.reading)
    }
    @Test func cancelledReadNeverApplies() async {
        let t = FakeJev(.stall); let s = make(t, Box())
        s.show(); s.text = "slow one"
        try? await Task.sleep(for: .milliseconds(30))
        let before = s.route
        s.close()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(s.route == before && !s.reading && !s.isOpen)
    }
    @Test func destructiveAgentRunArmsThenRuns() async {
        let t = FakeJev(.reply(200, body(kind: "agent_task", destructive: 0.9))); let box = Box(); let s = make(t, box)
        s.show(); s.text = "delete all old branches"
        await settle(s)
        s.run()
        #expect(s.armed && box.plans.isEmpty && s.isOpen)
        s.run()
        #expect(box.plans.count == 1 && !s.isOpen)
    }
    @Test func jevDownStillRunsDeterministicRoute() async {
        let t = FakeJev(.fail); let box = Box(); let s = make(t, box)
        s.show(); s.text = "explain this"
        await settle(s)
        s.run()
        #expect(box.plans.first?.door == .writeToFocusedClaude)
    }
    @Test func twoChoiceRefusesRunUntilChosen() async {
        let t = FakeJev(.reply(200, body(kind: "agent_task", conf: 0.3))); let box = Box(); let s = make(t, box)
        s.show(); s.text = "make it better"
        await settle(s)
        #expect(s.route?.twoChoice == true)
        s.run(); #expect(box.plans.isEmpty)
        s.choose(.agentTask); s.run()
        #expect(box.plans.count == 1)
    }
}
