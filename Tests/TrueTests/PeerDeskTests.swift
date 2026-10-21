import Testing
import Foundation
@testable import True

/// Run 35 — One desk per peer project. `a` ("Al") delegates; `b` ("Bo") receives with `knobs.desk` on.
@Suite(.serialized) struct PeerDeskTests {
    struct Rig {
        let a: PeerSide, b: PeerSide
        func close() { a.close(); b.close() }
    }
    func rig(mode: PeerInboundMode = .bypass, desk: Bool = true) -> Rig {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock, mode: mode)
        b.knobs.desk = desk
        pairUp(a, b)
        return Rig(a: a, b: b)
    }
    @discardableResult
    func send(_ r: Rig, repo: String = testRepo, title: String = "Fix it", dir: String = "") -> String {
        guard case .success(let id) = r.a.engine.delegate(peer: "Bea", repo: repo, title: title, brief: "do \(title)", mode: .pane, fromAgent: "lead", dir: dir) else {
            Issue.record("delegate failed"); return ""
        }
        settle(r.a, r.b)
        return id
    }
    func job(_ r: Rig, _ id: String) -> InboundJob? { r.b.engine.inboundJobs().first { $0.id == id } }
    func finish(_ r: Rig, _ id: String, pane: UUID) throws {
        try Data("ok".utf8).write(to: URL(fileURLWithPath: r.b.engine.resultPath(id)))
        r.b.engine.paneEvent(pane: pane, kind: .stop); settle(r.a, r.b)
    }

    @Test func secondJobWaitsInLineThenIsTypedIntoTheSamePane() throws {
        let r = rig(); defer { r.close() }
        let j1 = send(r, title: "First"), j2 = send(r, title: "Second")
        #expect(r.b.launcher.panes.count == 1 && r.b.launcher.delivered.isEmpty)
        let line = try #require(job(r, j2))
        #expect(line.status == .accepted && line.pane == nil && line.note == "In line behind First" && line.desk != nil)
        #expect(job(r, j1)?.desk == line.desk && r.b.engine.inLineCount(desk: line.desk) == 1)
        #expect(r.a.engine.status(jobId: j2).first?.status == .accepted)
        // The running job's pane events map to it only, never to the one in line.
        r.b.engine.paneEvent(pane: r.b.launcher.pane, kind: .progress); settle(r.a, r.b)
        #expect(job(r, j1)?.status == .working && job(r, j2)?.status == .accepted)
        try finish(r, j1, pane: r.b.launcher.pane)
        #expect(job(r, j1)?.status == .done)
        #expect(r.b.launcher.panes.count == 1)
        #expect(r.b.launcher.delivered.count == 1 && r.b.launcher.delivered[0].0 == r.b.launcher.pane)
        #expect(r.b.launcher.delivered[0].1.contains(r.b.root.appendingPathComponent("jobs/\(j2)/envelope.md").path))
        let now = try #require(job(r, j2))
        #expect(now.pane == r.b.launcher.pane && now.note == "Started")
        #expect(r.b.engine.inLineCount(desk: now.desk) == 0)
        // Its envelope moves the agent onto its own branch first.
        let env = try String(contentsOf: r.b.root.appendingPathComponent("jobs/\(j2)/envelope.md"), encoding: .utf8)
        #expect(env.contains("git checkout -B \(PeerNaming.branch(label: "Al", jobId: j2)) origin/main") && env.contains("FIRST"))
        let env1 = try String(contentsOf: r.b.root.appendingPathComponent("jobs/\(j1)/envelope.md"), encoding: .utf8)
        #expect(!env1.contains("checkout -B"))
        // The desk pane is named for peer + project, and both jobs share one worktree.
        #expect(r.b.launcher.panes[0].name == PeerNaming.deskAgentName(label: "Al", project: "app"))
        #expect(job(r, j1)?.worktree == job(r, j2)?.worktree && job(r, j1)?.worktree?.hasSuffix(".peers/al/desk") == true)
    }

    @Test func differentReposGetTheirOwnDesks() {
        let r = rig(); defer { r.close() }
        send(r, repo: testRepo); send(r, repo: "https://github.com/acme/other.git")
        #expect(r.b.launcher.panes.count == 2 && r.b.launcher.delivered.isEmpty)
        #expect(r.b.engine.desks().count == 2)
        #expect(Set(r.b.engine.desks().map(\.project)) == ["app", "other"])
    }

    @Test func sameRepoSpelledDifferentlyIsOneDesk() {
        let r = rig(); defer { r.close() }
        send(r, repo: "https://github.com/acme/app.git"); send(r, repo: "git@github.com:acme/app")
        #expect(r.b.launcher.panes.count == 1 && r.b.engine.desks().first?.inLine == 1)
    }

    @Test func aGonePaneGetsAFreshLaunch() throws {
        let r = rig(); defer { r.close() }
        let j1 = send(r)
        try finish(r, j1, pane: r.b.launcher.pane)
        r.b.launcher.deadPanes.insert(r.b.launcher.pane)
        let j2 = send(r)
        #expect(r.b.launcher.panes.count == 2 && r.b.launcher.delivered.isEmpty)
        #expect(job(r, j2)?.pane == r.b.launcher.launched[1])
    }

    @Test func aFreeLivePaneTakesTheNextJobDirectly() throws {
        let r = rig(); defer { r.close() }
        let j1 = send(r)
        try finish(r, j1, pane: r.b.launcher.pane)
        let j2 = send(r)
        #expect(r.b.launcher.panes.count == 1 && r.b.launcher.delivered.count == 1)
        #expect(job(r, j2)?.pane == r.b.launcher.pane)
    }

    @Test func runningJobWhosePaneDiedDoesNotBlockTheLine() {
        let r = rig(); defer { r.close() }
        send(r)
        r.b.launcher.deadPanes.insert(r.b.launcher.pane)
        let j2 = send(r)
        #expect(r.b.launcher.panes.count == 2 && job(r, j2)?.pane == r.b.launcher.launched[1])
    }

    @Test func askModeNeverQueuesBeforeApprove() throws {
        let r = rig(mode: .ask); defer { r.close() }
        let j1 = send(r), j2 = send(r)
        #expect(r.b.launcher.panes.isEmpty)
        #expect(r.b.engine.inboundJobs().allSatisfy { $0.status == .queued && $0.desk == nil })
        r.b.engine.accept(j1); settle(r.a, r.b)
        r.b.engine.accept(j2); settle(r.a, r.b)
        #expect(r.b.launcher.panes.count == 1)
        #expect(job(r, j2)?.note == "In line behind Fix it")
        try finish(r, j1, pane: r.b.launcher.pane)
        #expect(r.b.launcher.delivered.count == 1 && job(r, j2)?.pane == r.b.launcher.pane)
    }

    @Test func declineWhileQueuedLeavesNoDeskAndStopOnRunningOpensAFreshPane() throws {
        let r = rig(); defer { r.close() }
        let j1 = send(r), j2 = send(r)
        r.a.engine.stopJob(jobId: j1); settle(r.a, r.b)
        #expect(job(r, j1)?.status == .failed)
        #expect(r.b.launcher.stopped.0 == [r.b.launcher.pane])
        #expect(r.b.launcher.panes.count == 2 && r.b.launcher.delivered.isEmpty)
        #expect(job(r, j2)?.pane == r.b.launcher.launched[1])
    }

    @Test func stoppingAnInLineJobJustEndsIt() {
        let r = rig(); defer { r.close() }
        send(r); let j2 = send(r)
        r.a.engine.stopJob(jobId: j2); settle(r.a, r.b)
        #expect(job(r, j2)?.status == .failed && r.b.launcher.panes.count == 1 && r.b.engine.desks().first?.inLine == 0)
    }

    @Test func deskOffKeepsOnePanePerJob() {
        let r = rig(desk: false); defer { r.close() }
        send(r); send(r)
        #expect(r.b.launcher.panes.count == 2 && r.b.launcher.delivered.isEmpty)
        #expect(r.b.engine.inboundJobs().allSatisfy { $0.desk == nil })
    }

    @Test func backgroundJobsAreNotDesks() {
        let r = rig(); defer { r.close() }
        guard case .success = r.a.engine.delegate(peer: "Bea", repo: testRepo, title: "Bg", brief: "b", mode: .background, fromAgent: "lead") else { Issue.record("delegate"); return }
        settle(r.a, r.b)
        #expect(r.b.launcher.panes.isEmpty && r.b.launcher.builders.count == 1 && r.b.engine.inboundJobs().allSatisfy { $0.desk == nil })
    }

    @Test func scratchJobsShareOneDeskAndDirJobsKeyOnTheFolder() throws {
        let r = rig(); defer { r.close() }
        send(r, repo: "", title: "S1"); let s2 = send(r, repo: "", title: "S2")
        #expect(r.b.launcher.panes.count == 1 && job(r, s2)?.note == "In line behind S1")
        #expect(r.b.engine.desks().first?.project == "scratch")
        let d1 = NSTemporaryDirectory() + "deskA-\(UUID().uuidString)", d2 = NSTemporaryDirectory() + "deskB-\(UUID().uuidString)"
        for d in [d1, d2] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
        defer { for d in [d1, d2] { try? FileManager.default.removeItem(atPath: d) } }
        r.b.knobs.dirs = [d1, d2]
        let before = r.b.launcher.panes.count
        send(r, repo: "", title: "D1", dir: d1); let x2 = send(r, repo: "", title: "D1b", dir: d1); send(r, repo: "", title: "D2", dir: d2)
        #expect(r.b.launcher.panes.count == before + 2)
        #expect(job(r, x2)?.note == "In line behind D1")
        let dirKeys = Set(r.b.engine.desks().map(\.key).filter { $0.contains("|dir:") })
        #expect(dirKeys.count == 2)
    }

    @Test func namingAndCardLines() {
        #expect(PeerNaming.deskWorktree(clone: "/p/app", label: "Al Bo") == "/p/app.peers/al-bo/desk")
        #expect(PeerNaming.deskAgentName(label: "Mahmoud's MacBook Air", project: "finance-director-os") == "peer-mahmoud-s-macbook-air-finance-director-os")
        #expect(PeerNaming.deskProject("mb|repo:github.com/acme/app") == "app" && PeerNaming.deskProject("mb|dir:/Users/example/Docs") == "Docs" && PeerNaming.deskProject("mb|scratch") == "scratch")
        #expect(PeerText.deskLine(peer: "Al", project: "app", inLine: 2) == "Desk: Al · app · 2 in line")
        #expect(PeerText.deskLine(peer: "Al", project: "app", inLine: 0) == "Desk: Al · app")
        let role = PeerText.roleCardDesk(label: "Al", workDir: "/w")
        #expect(role.contains("/w") && role.contains("its own branch") && role.contains("result path"))
    }
}
