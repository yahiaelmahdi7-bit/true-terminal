import Testing
import Foundation
@testable import True

private let noGit: @Sendable (String) -> Bool = { _ in false }
private let now = 1_800_000_000.0

private func peerJSON(pid: Int, session: String = "s-1", cwd: String = "/Users/u/Projects/app", name: String? = "helper",
                      status: String = "idle", updated: Double = 1_799_999_000_000) -> Data {
    var o: [String: Any] = ["pid": pid, "sessionId": session, "cwd": cwd, "status": status, "updatedAt": updated, "kind": "interactive"]
    if let name { o["name"] = name }
    return try! JSONSerialization.data(withJSONObject: o)
}

private func builderJSON(id: String = "b1", status: String = "running", cwd: String = "/Users/u/Projects/app.builders/b1",
                         origin: String = "/Users/u/Projects/app", started: Double = now - 600, ended: Double? = nil,
                         acked: Bool = false, parent: String? = nil, claude: Int? = 999_999, sup: Int? = 999_998,
                         session: String = "bs-1") -> Data {
    var o: [String: Any] = ["id": id, "name": "task-\(id)", "cwd": cwd, "origin_cwd": origin, "model": "sonnet",
                            "status": status, "started": started, "acked": acked, "session_id": session]
    if let ended { o["ended"] = ended }
    if let parent { o["parent"] = parent }
    if let claude { o["claude_pid"] = claude }
    if let sup { o["supervisor_pid"] = sup }
    return try! JSONSerialization.data(withJSONObject: o)
}

@Suite struct HubProjectKeyTests {
    @Test func normalisationTable() {
        let git: Set<String> = ["/Users/u/Projects/app", "/Users/u"]
        let hasGit: (String) -> Bool = { git.contains($0) }
        func key(_ c: String) -> String { HubProject.key(forCwd: c, home: "/Users/u", hasGit: hasGit) }
        #expect(key("/Users/u/Projects/app.builders/run-1") == "/Users/u/Projects/app")
        #expect(key("/Users/u/Projects/app/.claude/worktrees/feat") == "/Users/u/Projects/app")
        #expect(key("/Users/u/Projects/app/Sources/deep") == "/Users/u/Projects/app")      // nearest .git ancestor
        #expect(key("/Users/u/Projects/other/sub") == "/Users/u/Projects/other/sub")      // home's .git never swallows it
        #expect(HubProject.key(forCwd: "/tmp/x", home: "/Users/u", hasGit: noGit) == "/tmp/x")
        #expect(HubProject.title("/Users/u/Projects/app") == "app" && HubProject.title("") == "Global")
    }
}

@Suite struct PeerSessionTests {
    @Test func parsesFieldsAndConvertsMillis() throws {
        let p = try #require(PeerSession.parse(peerJSON(pid: 42, status: "busy")))
        #expect(p.pid == 42 && p.busy && p.updatedAt == 1_799_999_000 && p.displayName == "helper")
    }

    @Test func missingFieldsDegradeOrDrop() throws {
        let bare = try #require(PeerSession.parse(Data(#"{"pid":7,"cwd":"/Users/u/x"}"#.utf8)))
        #expect(bare.name == "" && bare.sessionID == "" && !bare.busy && bare.kind == "session" && bare.displayName == "x")
        #expect(PeerSession.parse(Data(#"{"cwd":"/x"}"#.utf8)) == nil)
        #expect(PeerSession.parse(Data(#"{"pid":7}"#.utf8)) == nil)
        #expect(PeerSession.parse(Data("junk".utf8)) == nil)
    }

    @Test func aliveMeansSignalZeroOrEPERM() {
        #expect(PeerSession.isAlive(1, probe: { _ in 0 }))
        #expect(PeerSession.isAlive(1, probe: { _ in EPERM }))
        #expect(!PeerSession.isAlive(1, probe: { _ in ESRCH }))
        #expect(!PeerSession.isAlive(0, probe: { _ in 0 }))
        #expect(PeerSession.isAlive(getpid()))
    }

    @Test func scannerReadsJsonOnlyNeverKeyFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hub-peers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try peerJSON(pid: 11).write(to: dir.appendingPathComponent("11.json"))
        // A secret-shaped neighbour that is valid peer JSON: if the scanner opened it, it would come back.
        try peerJSON(pid: 22, name: "SECRET").write(to: dir.appendingPathComponent("22.abc123.key"))
        let got = HubScanner.peers(in: dir)
        #expect(got.map(\.pid) == [11])
        #expect(!got.contains { $0.name == "SECRET" })
    }
}

@Suite struct BuilderRecordTests {
    let alive: (Int32) -> Bool = { $0 == 999_999 }

    func rec(_ d: Data) -> BuilderRecord { BuilderRecord.parse(d, alive: alive)! }

    @Test func runningAliveAndDied() {
        #expect(rec(builderJSON()).state == .running)
        #expect(rec(builderJSON()).status == .working)
        let died = rec(builderJSON(claude: 1, sup: 2))
        #expect(died.state == .died && died.status == .failed)
        #expect(rec(builderJSON(claude: nil, sup: nil)).state == .running)      // launch in progress
    }

    @Test func doneAckedAndAge() {
        let fresh = rec(builderJSON(status: "done", ended: now - 3_600))
        #expect(fresh.status == .done && fresh.isVisible(now: now))
        let oldAcked = rec(builderJSON(status: "done", ended: now - 90_000, acked: true))
        #expect(!oldAcked.isVisible(now: now))
        let oldUnacked = rec(builderJSON(status: "done", ended: now - 90_000, acked: false))
        #expect(oldUnacked.isVisible(now: now))
        let recentAcked = rec(builderJSON(status: "done", ended: now - 3_600, acked: true))
        #expect(recentAcked.isVisible(now: now))
    }

    @Test func failedKilledAndParent() {
        #expect(rec(builderJSON(status: "failed", ended: now - 60)).status == .failed)
        let killed = rec(builderJSON(status: "killed", ended: now - 60, parent: "lead-app"))
        #expect(killed.state == .killed && killed.status == .failed && killed.parent == "lead-app")
        #expect(rec(builderJSON()).parent == nil)
        #expect(rec(builderJSON(acked: true, claude: 1, sup: 2)).isVisible(now: now) == false)
    }

    @Test func elapsedAndProject() {
        #expect(rec(builderJSON()).elapsed(now: now) == 600)
        #expect(rec(builderJSON(status: "done", started: now - 600, ended: now - 300)).elapsed(now: now) == 300)
        #expect(BuilderRecord.parse(Data("{}".utf8)) == nil)
    }
}

@Suite @MainActor struct HubModelTests {
    func build(seats: [Agent] = [], peers: [PeerSession] = [], builders: [BuilderRecord] = [],
               seatsOnly: Bool = false, status: AgentStatus = .idle, awake: Bool = false) -> [HubProjectGroup] {
        HubModel.build(seats: seats, seatStatus: { _ in status }, seatAwake: { _ in awake }, peers: peers,
                       builders: builders, now: now, seatsOnly: seatsOnly, hasGit: noGit)
    }
    func peer(_ pid: Int32, session: String = "", cwd: String = "/p/one", busy: Bool = false, updated: Double = now - 100) -> PeerSession {
        PeerSession(pid: pid, sessionID: session, cwd: cwd, name: "n\(pid)", kind: "interactive", busy: busy, updatedAt: updated)
    }
    func builder(_ id: String, state: BuilderState = .running, cwd: String = "/p/one", session: String = "", pid: Int32 = 0) -> BuilderRecord {
        BuilderRecord(id: id, name: id, cwd: cwd, originCwd: cwd, model: "sonnet", sessionID: session, claudePID: pid,
                      started: now - 60, ended: state == .running ? nil : now - 30, state: state, acked: false)
    }
    let me = getpid()

    @Test func seatIsNotShownAgainAsPeer() {
        var a = Agent(name: "lead-one", role: .lead, repo: "/p/one"); a.lastSessionID = "sess-a"
        let g = build(seats: [a], peers: [peer(me, session: "sess-a")])
        #expect(g.count == 1 && g[0].seats.count == 1 && g[0].others.isEmpty)
    }

    @Test func builderIsNotShownAgainAsPeer() {
        let g = build(peers: [peer(me, session: "bs")], builders: [builder("b", session: "bs")])
        #expect(g[0].background.count == 1 && g[0].others.isEmpty)
        let byPID = build(peers: [peer(me)], builders: [builder("b", pid: me)])
        #expect(byPID[0].others.isEmpty)
    }

    @Test func deadPeerIsDropped() {
        #expect(build(peers: [peer(2_147_000_000)]).isEmpty)
        #expect(build(peers: [peer(me)])[0].others.count == 1)
    }

    @Test func groupsSortByLatestActivityWithCounts() {
        let g = build(peers: [peer(me, cwd: "/p/old", updated: now - 5_000), peer(me &+ 1, cwd: "/p/old", updated: now - 4_000)],
                      builders: [builder("run", cwd: "/p/new"), builder("bad", state: .failed, cwd: "/p/new")])
        #expect(g.map(\.title) == ["new", "old"])
        #expect(g[0].working == 1 && g[0].failed == 1 && g[0].summary == "1 working · 1 failed")
        #expect(g[1].summary == "")
    }

    @Test func needsYouAndSeatsOnly() {
        let a = Agent(name: "lead-one", role: .lead, repo: "/p/one")
        let full = build(seats: [a], builders: [builder("b")], status: .needsYou)
        #expect(full[0].summary == "1 working · 1 needs you" && full[0].background.count == 1)
        let seatsOnly = build(seats: [a], peers: [peer(me)], builders: [builder("b")], seatsOnly: true, status: .needsYou)
        #expect(seatsOnly.count == 1 && seatsOnly[0].background.isEmpty && seatsOnly[0].others.isEmpty)
        #expect(seatsOnly[0].summary == "1 needs you")
    }

    @Test func globalsGroupUnderGlobalAndEmptyProjectsVanish() {
        let gl = Agent(name: "designer", role: .global, repo: "")
        let g = build(seats: [gl], builders: [builder("old", state: .done, cwd: "/p/x")].map { var b = $0; b.acked = true; b.ended = now - 200_000; return b })
        #expect(g.map(\.key) == [""] && g[0].title == "Global")
    }

    @Test func rowsFlattenForTruectl() {
        let a = Agent(name: "lead-one", role: .lead, repo: "/p/one")
        let groups = build(seats: [a], peers: [peer(me, busy: true)], builders: [builder("b")])
        let rows = HubModel.rows(groups, seatStatus: { _ in .idle })
        #expect(rows.map(\.kind) == ["seat", "background", "other"])
        #expect(rows.allSatisfy { $0.project == "one" })
        #expect(rows[2].status == "working")
    }
}
