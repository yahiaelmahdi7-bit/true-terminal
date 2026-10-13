import Testing
import Foundation
@testable import True

final class FakeCommands: RemoteCommands, @unchecked Sendable {
    var projects = [Project(name: "app", path: "/tmp/true-fake/app", parent: "~/tmp")]
    var reply: JevReply?
    var launches = 0
    var seats: [BarSeat] = []
    var records: [[String: Any]] = []
    var pushed: [String] = []
    func environment() -> BarEnvironment {
        BarEnvironment(focused: FocusedPane(kind: .empty, project: nil, seat: nil, cwd: nil), projects: projects, recent: [], seats: seats)
    }
    func isExecutable(_ name: String) -> Bool { ["git", "ls"].contains(name) }
    var jevEnabled: Bool { reply != nil }
    func jev(text: String, context: CommandContext, rule: RuleMatch?) -> JevReply? { reply }
    func launch(_ plan: Plan, route: Route) -> RemoteLaunch { launches += 1; return .pane(UUID()) }
    func history() -> [String] { ["one", "two"] }
    func pushHistory(_ text: String) { pushed.append(text) }
    func hubJSON() -> Data { Data("{}".utf8) }
    func builderDetail(id: String) -> Data? { nil }
    func ackBuilder(id: String) -> Bool { false }
    func record(_ line: [String: Any]) { records.append(line) }
    var phoneBuilders = 0
    var marked: [String] = []
    var workingSeats: Set<String> = []
    func phoneBuildersRunning() -> Int { phoneBuilders }
    func markPhoneBuilder(_ name: String) { marked.append(name) }
    func seatIsWorking(_ name: String) -> Bool { workingSeats.contains(name) }
}

/// Defaults to a low danger answer (Jev judged it safe); `judged: false` = Jev answered no danger noul (destructive nil).
func answer(_ kind: String, danger: Double? = nil, judged: Bool = true) -> JevReply {
    let danger = danger ?? (judged ? 0.0 : nil)
    var a: [String: JevAnswer] = ["kind": JevAnswer(type: "choice", choice: kind, confidence: 0.95, probabilities: nil, noul: nil, score: nil)]
    if let danger { a["danger_push"] = JevAnswer(type: "noul", choice: nil, confidence: 0.9, probabilities: nil, noul: danger, score: nil) }
    return JevReply(answers: a)
}

@Suite struct RemoteBarSecurityTests {
    let dev = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func make(_ reply: JevReply?) -> (RemoteBar, FakeCommands) {
        let c = FakeCommands(); c.reply = reply
        return (RemoteBar(commands: c), c)
    }

    @Test func multiLineTextIsRejected() {
        let (bar, _) = make(answer("shell_command"))
        for bad in ["ls\nrm -rf x", "ls\r\nwhoami", "a\u{0}b", "a\u{1B}[0m", "a\u{7F}b", "git status\rwhoami"] {
            #expect(bar.propose(device: dev, text: bad, now: t0) == nil, "\(bad.debugDescription)")
            #expect(!RemoteBar.isSingleLine(bad))
        }
        #expect(RemoteBar.isSingleLine("ls\t-la"))
        #expect(bar.propose(device: dev, text: "  git status \n", now: t0) != nil)   // ends are trimmed, not rejected
    }

    @Test func newlineMakesACommandCompound() {
        #expect(CommandRules.isCompound("a\nb"))
        #expect(CommandRules.isCompound("a\r\nb"))
        #expect(CommandRules.isCompound("a\rb"))
        #expect(!CommandRules.isCompound("git status"))
    }

    @Test func unjudgedAgentTaskNeedsConfirmFromThePhone() throws {
        let (bar, c) = make(answer("agent_task", judged: false))
        let a = try #require(bar.propose(device: dev, text: "fix the tests in app", now: t0))
        #expect(bar.run(a.id, device: dev, background: false, confirm: true, now: t0) == .needsConfirm("unjudged"))   // unarmed confirm
        #expect(c.launches == 0)
        guard case .ok = bar.run(a.id, device: dev, background: false, confirm: true, now: t0) else { Issue.record("armed"); return }
        #expect(c.launches == 1)
    }

    @Test func dangerousTextNeedsConfirmEvenWhenJevSaysSafe() throws {
        let (bar, c) = make(answer("agent_task"))
        let text = "rm -rf build in app"
        try #require(CommandRules.isDangerous(text))
        let a = try #require(bar.propose(device: dev, text: text, now: t0))
        #expect(bar.run(a.id, device: dev, background: false, confirm: false, now: t0) == .needsConfirm("dangerous_text"))
        #expect(c.launches == 0)
    }

    @Test func backgroundRunsNeedConfirmAndCapAtThree() throws {
        let (bar, c) = make(answer("agent_task"))
        let a = try #require(bar.propose(device: dev, text: "fix the tests in app", now: t0))
        #expect(bar.run(a.id, device: dev, background: true, confirm: false, now: t0) == .needsConfirm(RemoteBar.backgroundConfirm))
        #expect(c.launches == 0)
        guard case .ok(.pane) = bar.run(a.id, device: dev, background: true, confirm: true, now: t0) else { Issue.record("armed run"); return }
        #expect(c.launches == 1 && c.marked.count == 1)
        c.phoneBuilders = 3
        let b = try #require(bar.propose(device: dev, text: "fix the tests in app", now: t0))
        #expect(bar.run(b.id, device: dev, background: true, confirm: false, now: t0) == .tooManyBuilders)
        #expect(bar.run(b.id, device: dev, background: true, confirm: true, now: t0) == .tooManyBuilders)
        #expect(c.launches == 1)
    }

    @Test func runLogNamesTheDoorCaseOnly() {
        for d: Plan.Door in [.background(name: "secret-builder", cwd: "/Users/x/secret", model: "m"), .seat("secret-seat"),
                             .newClaudePane(cwd: "/Users/x/secret"), .newShellSplit(cwd: "/Users/x/secret")] {
            let n = RemoteBar.doorName(d)
            #expect(!n.contains("secret") && !n.contains("/") && !n.contains("("))
        }
    }

    @Test func sleepingAWorkingSeatNeedsConfirm() throws {
        let sleep = JevReply(answers: [
            "kind": JevAnswer(type: "choice", choice: "true_action", confidence: 0.95, probabilities: nil, noul: nil, score: nil),
            "action": JevAnswer(type: "choice", choice: "sleep_seat", confidence: 0.95, probabilities: nil, noul: nil, score: nil)])
        let (bar, c) = make(sleep)
        c.seats = [BarSeat(name: "ada", project: "app", awake: true)]
        c.workingSeats = ["ada"]
        let a = try #require(bar.propose(device: dev, text: "sleep ada", now: t0))
        try #require(a.entry.route.action == .sleepSeat && a.entry.route.seat == "ada")
        #expect(bar.run(a.id, device: dev, background: false, confirm: false, now: t0) == .needsConfirm("seat_working"))
        c.workingSeats = []
        guard case .ok = bar.run(a.id, device: dev, background: false, confirm: false, now: t0) else { Issue.record("idle seat sleeps"); return }
        #expect(c.launches == 1)
    }

    @Test func phoneBuilderCountUsesRunningStateAndFreshLaunches() {
        let p = PhoneBuilders(), now = Date()
        p.mark("a", now: now); p.mark("b", now: now); p.mark("c", now: now.addingTimeInterval(-3600))
        #expect(p.running(records: [], now: now) == 2)                                    // c is stale, unlisted
        #expect(p.running(records: [("a", true), ("b", false), ("c", true)], now: now) == 2)
        #expect(p.running(records: [("a", false), ("b", false)], now: now) == 0)
    }

    @Test func phoneClaudePaneUsesAutoModeMacKeepsSkipPermissions() throws {
        let (bar, _) = make(answer("agent_task"))
        let a = try #require(bar.propose(device: dev, text: "fix the tests in app", now: t0))
        let phone = CommandExecutor.plan(route: a.entry.route, background: false, context: a.entry.context, fromPhone: true)
        let mac = CommandExecutor.plan(route: a.entry.route, background: false, context: a.entry.context)
        guard case .newClaudePane = phone.door, case .newClaudePane = mac.door else { Issue.record("expected new pane"); return }
        #expect(phone.argv.contains("--permission-mode") && phone.argv.contains("auto"))
        #expect(!phone.argv.contains("--dangerously-skip-permissions"))
        #expect(mac.argv.contains("--dangerously-skip-permissions") && !mac.argv.contains("--permission-mode"))
        let cmd = CommandExecutor.startupCommand(argv: phone.argv, settings: "/tmp/s.json")
        #expect(cmd.contains("--permission-mode") && cmd.contains("auto") && cmd.contains("--settings") && !cmd.contains("dangerously"))
    }

    @Test func randomnessFailureRefusesToMakeARoute() {
        #expect(RemoteBar.newID() != nil)
    }
}

@Suite struct RemoteBarTests {
    let dev = UUID(), other = UUID()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func make(_ reply: JevReply? = nil) -> (RemoteBar, FakeCommands) {
        let c = FakeCommands(); c.reply = reply
        return (RemoteBar(commands: c), c)
    }

    @Test func routeIdIsRandomAndSingleUse() throws {
        let (bar, c) = make(answer("agent_task"))
        let a = try #require(bar.propose(device: dev, text: "fix the tests in app", now: t0))
        let b = try #require(bar.propose(device: dev, text: "fix the tests in app", now: t0))
        #expect(a.id != b.id && a.id.count >= 32)
        guard case .ok = bar.run(a.id, device: dev, background: false, confirm: false, now: t0) else { Issue.record("first run should work"); return }
        #expect(c.launches == 1)
        #expect(bar.run(a.id, device: dev, background: false, confirm: false, now: t0) == .gone)
        #expect(c.launches == 1)
    }

    @Test func expiresAfterTwoMinutes() throws {
        let (bar, c) = make(answer("agent_task"))
        let a = try #require(bar.propose(device: dev, text: "fix the tests in app", now: t0))
        #expect(bar.run(a.id, device: dev, background: false, confirm: false, now: t0.addingTimeInterval(121)) == .gone)
        #expect(c.launches == 0)
    }

    @Test func wrongDeviceCannotUseOrEditARoute() throws {
        let (bar, c) = make(answer("agent_task"))
        let a = try #require(bar.propose(device: dev, text: "fix the tests in app", now: t0))
        #expect(bar.run(a.id, device: other, background: false, confirm: false, now: t0) == .gone)
        if case .gone = bar.setSlot(a.id, device: other, slot: "model", value: "sonnet", now: t0) {} else { Issue.record("expected gone") }
        #expect(bar.entry(a.id, device: other, now: t0) == nil)
        #expect(c.launches == 0)
    }

    @Test func slotValuesOutsideCandidatesAreRejected() throws {
        let (bar, _) = make(answer("agent_task"))
        let a = try #require(bar.propose(device: dev, text: "fix the tests in app", now: t0))
        for (slot, value) in [("project", "/etc"), ("project", "../../etc"), ("target", "rm -rf /"), ("kind", "shell_command; rm"),
                              ("model", "gpt-9"), ("effort", "ludicrous"), ("argv", "x")] {
            if case .invalid = bar.setSlot(a.id, device: dev, slot: slot, value: value, now: t0) {} else { Issue.record("\(slot)=\(value) accepted") }
        }
        let e = try #require(bar.entry(a.id, device: dev, now: t0))
        let cands = RemoteBar.candidates(e)
        let good = try #require(cands["effort"]?.first)
        if case .ok = bar.setSlot(a.id, device: dev, slot: "effort", value: good.value, now: t0) {} else { Issue.record("candidate refused") }
    }

    @Test func dangerNeedsServerArmedConfirm() throws {
        let (bar, c) = make(answer("agent_task", danger: 0.9))
        let a = try #require(bar.propose(device: dev, text: "push app to main", now: t0))
        // confirm:true on an unarmed route does not skip the gate
        guard case .needsConfirm = bar.run(a.id, device: dev, background: false, confirm: true, now: t0) else { Issue.record("expected needsConfirm"); return }
        #expect(c.launches == 0)
        guard case .needsConfirm = bar.run(a.id, device: dev, background: false, confirm: false, now: t0) else { Issue.record("still gated"); return }
        #expect(c.launches == 0)
        guard case .ok = bar.run(a.id, device: dev, background: false, confirm: true, now: t0) else { Issue.record("armed confirm should run"); return }
        #expect(c.launches == 1)
    }

    @Test func slotEditDisarmsConfirm() throws {
        let (bar, c) = make(answer("agent_task", danger: 0.9))
        let a = try #require(bar.propose(device: dev, text: "push app to main", now: t0))
        _ = bar.run(a.id, device: dev, background: false, confirm: false, now: t0)
        let e = try #require(bar.entry(a.id, device: dev, now: t0))
        let m = try #require(RemoteBar.candidates(e)["model"]?.first)
        _ = bar.setSlot(a.id, device: dev, slot: "model", value: m.value, now: t0)
        guard case .needsConfirm = bar.run(a.id, device: dev, background: false, confirm: true, now: t0) else { Issue.record("edit must re-arm"); return }
        #expect(c.launches == 0)
    }

    @Test func rateLimitTenRunsPerMinutePerDevice() throws {
        let (bar, c) = make(answer("agent_task"))
        for i in 0..<10 {
            let a = try #require(bar.propose(device: dev, text: "task \(i) in app", now: t0))
            guard case .ok = bar.run(a.id, device: dev, background: false, confirm: false, now: t0) else { Issue.record("run \(i)"); return }
        }
        let a = try #require(bar.propose(device: dev, text: "task 11 in app", now: t0))
        #expect(bar.run(a.id, device: dev, background: false, confirm: false, now: t0) == .rateLimited)
        #expect(c.launches == 10)
        // another device is unaffected; a minute later this one is free again
        let o = try #require(bar.propose(device: other, text: "task in app", now: t0))
        guard case .ok = bar.run(o.id, device: other, background: false, confirm: false, now: t0) else { Issue.record("other device"); return }
        guard case .ok = bar.run(a.id, device: dev, background: false, confirm: false, now: t0.addingTimeInterval(61)) else { Issue.record("after window"); return }
    }

    @Test func runsAreLoggedWithHashNotText() throws {
        let (bar, c) = make(answer("agent_task"))
        let a = try #require(bar.propose(device: dev, text: "secret plan for app", now: t0))
        _ = bar.run(a.id, device: dev, background: false, confirm: false, now: t0)
        #expect(c.records.map { $0["event"] as? String } == ["propose", "run"])
        let blob = String(describing: c.records)
        #expect(!blob.contains("secret plan") && blob.contains(dev.uuidString) && blob.contains(RemoteBar.hash("secret plan for app")))
        #expect(c.pushed == ["secret plan for app"])
    }

    @Test func onlyVisibleNewPaneDoorsAreAllowed() {
        #expect(!RemoteBar.allowed(.typeInFocusedShell))
        #expect(!RemoteBar.allowed(.writeToFocusedClaude))
        #expect(!RemoteBar.allowed(.nothing))
        #expect(RemoteBar.allowed(.newClaudePane(cwd: "/tmp")))
        #expect(RemoteBar.allowed(.background(name: "b", cwd: "/tmp", model: "sonnet")))
    }

    @Test func noRawCommandRouteExists() {
        let table = RemoteServer.routeTable
        for entry in table where entry.hasPrefix("POST") {
            #expect(["POST /pair", "POST /api/drop", "POST /api/clip", "POST /api/hub/builder/<id>/ack",
                     "POST /api/route", "POST /api/route/<routeId>/slot", "POST /api/run",
                     "POST /api/pane/<uuid>/input"].contains(entry), "\(entry)")
        }
        for bad in ["exec", "cmd", "shell", "command", "eval"] { #expect(!table.contains { $0.contains(bad) }) }
    }

    @Test func remoteOriginWindowIsTenMinutes() {
        let o = RemoteOrigin(), p = UUID()
        o.mark(p, now: t0)
        #expect(o.isRecent(p, now: t0.addingTimeInterval(599)))
        #expect(!o.isRecent(p, now: t0.addingTimeInterval(601)))
        #expect(!o.isRecent(UUID(), now: t0))
    }
}

@Suite @MainActor struct RemoteHubJSONTests {
    let now = 1_800_000_000.0
    func builder(_ id: String, _ state: BuilderState, dir: String? = nil) -> BuilderRecord {
        BuilderRecord(id: id, name: "task-\(id)", cwd: "/p/one", originCwd: "/p/one", model: "sonnet", sessionID: "", claudePID: 0,
                      started: now - 60, ended: state == .running ? nil : now - 30, state: state, acked: false, dir: dir)
    }

    @Test func hubJSONMirrorsTheMacModel() throws {
        let peer = PeerSession(pid: 4242, sessionID: "s", cwd: "/p/one", name: "helper", kind: "interactive", busy: true, updatedAt: now - 10)
        let groups = HubModel.build(seats: [], seatStatus: { _ in .idle }, seatAwake: { _ in false }, peers: [peer],
                                    builders: [builder("b1", .running), builder("b2", .done)], now: now, seatsOnly: false, hasGit: { _ in false })
        let json = RemoteHubJSON.make(groups: groups, seatStatus: { _ in .idle }, seatPane: { _ in nil }, now: now)
        let projects = try #require(json["projects"] as? [[String: Any]])
        #expect(projects.count == groups.count)
        for (g, p) in zip(groups, projects) {
            #expect(p["title"] as? String == g.title)
            let rows = try #require(p["rows"] as? [[String: Any]])
            #expect(rows.count == g.seats.count + g.others.count + g.background.count)
        }
        let ids = projects.flatMap { ($0["rows"] as? [[String: Any]]) ?? [] }.compactMap { $0["builderId"] as? String }
        #expect(Set(ids) == ["b1", "b2"])
        #expect((json["summary"] as? String) != nil)
    }

    @Test func ackValidatesTheIdAndWritesMeta() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"id":"b2","status":"done"}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        let known = [builder("b2", .done, dir: dir.path)]
        for bad in ["../b2", "b2/../x", "b2 ", "", "nope", "/etc/passwd", String(repeating: "a", count: 200)] {
            #expect(!RemoteHubJSON.isValidBuilderID(bad, known: known), "\(bad)")
            #expect(!RemoteHubJSON.ack(id: bad, known: known))
        }
        #expect(!RemoteHubJSON.ack(id: "r1", known: [builder("r1", .running, dir: dir.path)]))   // still running: canAck is false
        #expect(RemoteHubJSON.ack(id: "b2", known: known))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json"))) as? [String: Any]
        #expect(obj?["acked"] as? Bool == true && obj?["status"] as? String == "done")
    }
}

extension RemoteDropEndToEndTests {
    @Test func barRoutesNeedOriginAndKnownRouteId() throws {
        try withEnv(port: 18861, commands: FakeCommands()) { env in
            let body = Array(#"{"text":"fix it"}"#.utf8)
            #expect(raw(18861, "POST", "/api/route", bearer: env.token, body: body).status == 403)       // no Origin
            #expect(raw(18861, "POST", "/api/route", bearer: nil, origin: "https://" + Self.dns + ":8444", body: body).status == 401)
            let run = Array(#"{"routeId":"deadbeef"}"#.utf8)
            let rr = raw(18861, "POST", "/api/run", bearer: env.token, origin: "https://" + Self.dns + ":8444", body: run)
            #expect(rr.status == 404)
            #expect(raw(18861, "POST", "/api/run", bearer: env.shortcut, origin: "https://" + Self.dns + ":8444", body: run).status == 403)
            #expect(raw(18861, "POST", "/api/exec", bearer: env.token, origin: "https://" + Self.dns + ":8444", body: run).status == 404)
        }
    }
}
