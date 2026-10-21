import Testing
import Foundation
@testable import True

private let now = 1_800_000_000.0

@MainActor
enum TriageFixture {
    static func builder(_ id: String, _ project: String, _ state: BuilderState, ago: Double = 600, acked: Bool = false) -> BuilderRecord {
        let cwd = "/Users/u/Projects/\(project)"
        return BuilderRecord(id: id, name: id, cwd: cwd, originCwd: cwd, model: "sonnet", sessionID: "s-\(id)", claudePID: 0,
                             started: now - ago - 900, ended: state == .running ? nil : now - ago, state: state, acked: acked,
                             parent: nil, branch: nil, worktree: nil, cost: 1, budget: 5, dir: nil)
    }

    static func cloud(_ id: String, _ status: String, unviewed: Bool = true, repo: String = "/srv/gamenight") -> CloudJob {
        CloudJob(id: id, title: "Cloud \(id)", repo: repo, branch: "b", status: status, foremanStatus: nil,
                 needsYouReason: status == "needsYou" ? "Which database?" : nil, reason: nil, createdAt: now - 1200,
                 updatedAt: now - 60, viewedAt: nil, unviewed: unviewed, archived: nil)
    }

    static func groups(_ builders: [BuilderRecord]) -> [HubProjectGroup] {
        HubModel.build(seats: [], seatStatus: { _ in .asleep }, seatAwake: { _ in false }, peers: [], builders: builders,
                       now: now, hasGit: { _ in true })
    }

    static func buckets(_ builders: [BuilderRecord], cloud: [CloudJob] = []) -> [TriageBucket] {
        HubTriage.build(groups: groups(builders), seatStatus: { _ in .asleep }, cloud: cloud, watcher: [], now: now)
    }
}

@MainActor
@Suite struct HubTriageTests {
    private func bucket(_ b: [TriageBucket], _ s: TriageSection) -> TriageBucket { b.first { $0.section == s }! }

    @Test func sectionsFollowTriageOrder() {
        let b = TriageFixture.buckets([
            .init(id: "r", name: "r", cwd: "/p/a", originCwd: "/p/a", model: "sonnet", sessionID: "r", claudePID: 0, started: now - 60,
                  ended: nil, state: .running, acked: false, parent: nil, branch: nil, worktree: nil, cost: nil, budget: nil, dir: nil),
            TriageFixture.builder("f", "a", .failed), TriageFixture.builder("d", "a", .done),
            TriageFixture.builder("old", "a", .done, acked: true), TriageFixture.builder("p", "a", .paused)],
            cloud: [TriageFixture.cloud("c1", "needsYou")])
        #expect(b.map(\.section) == [.needsYou, .working, .review, .backlog])
        #expect(bucket(b, .needsYou).count == 3)      // failed + paused + cloud needsYou
        #expect(bucket(b, .working).count == 1)
        #expect(bucket(b, .review).count == 1)
        #expect(bucket(b, .backlog).count == 1)       // acked done
    }

    @Test func needsYouSortsAmberBeforeFailed() {
        let b = TriageFixture.buckets([TriageFixture.builder("f", "a", .failed)], cloud: [TriageFixture.cloud("c", "needsYou")])
        guard case .row(let first) = bucket(b, .needsYou).entries[0] else { Issue.record("expected row"); return }
        #expect(first.tone == .needsYou && first.isCloud && first.actionLabel == "Answer")
    }

    @Test func actionsPerState() {
        let b = TriageFixture.buckets([TriageFixture.builder("d", "a", .done), TriageFixture.builder("f", "a", .failed)])
        guard case .row(let done) = bucket(b, .review).entries[0], case .row(let failed) = bucket(b, .needsYou).entries[0] else {
            Issue.record("expected rows"); return
        }
        #expect(done.actionLabel == "Review gates" && done.action == .builder("d"))
        #expect(failed.actionLabel == "Open" && failed.tone == .failed)
    }

    @Test func runOfThreeSameProjectFolds() {
        let many = (0..<6).map { TriageFixture.builder("g\($0)", "gamenight", .done, ago: Double(100 + $0)) }
        let b = TriageFixture.buckets(many)
        let entries = bucket(b, .review).entries
        #expect(entries.count == 1)
        guard case .group(_, let project, let tone, let label, let items) = entries[0] else { Issue.record("expected group"); return }
        #expect(project == "gamenight" && tone == .done && label == "6 builders finished" && items.count == 6)
        #expect(bucket(b, .review).count == 6)
    }

    @Test func twoStayAsRowsAndProjectsCluster() {
        let b = TriageFixture.buckets([TriageFixture.builder("a1", "alpha", .done, ago: 100), TriageFixture.builder("b1", "beta", .done, ago: 50),
                                       TriageFixture.builder("a2", "alpha", .done, ago: 200), TriageFixture.builder("b2", "beta", .done, ago: 60)])
        let projects = bucket(b, .review).entries.compactMap { e -> String? in if case .row(let i) = e { return i.project } else { return nil } }
        #expect(projects == ["beta", "beta", "alpha", "alpha"])
    }

    @Test func groupNeverMixesToneOrKind() {
        let items = (0..<3).map { TriageFixture.builder("x\($0)", "p", .done) } + [TriageFixture.builder("y", "p", .failed)]
        let b = TriageFixture.buckets(items, cloud: [TriageFixture.cloud("c", "done", repo: "/srv/p")])
        let review = bucket(b, .review).entries
        #expect(review.count == 2)    // builders folded, cloud job stays its own row
        #expect(bucket(b, .needsYou).entries.count == 1)
    }

    @Test func viewedCloudResultsGoToHistory() {
        let b = TriageFixture.buckets([], cloud: [TriageFixture.cloud("v", "done", unviewed: false), TriageFixture.cloud("u", "failed", unviewed: true)])
        #expect(bucket(b, .backlog).count == 1 && bucket(b, .needsYou).count == 1)
    }

    @Test func headerCountsAndJumpTarget() {
        let b = TriageFixture.buckets((0..<4).map { TriageFixture.builder("f\($0)", "p", .failed) } + [TriageFixture.builder("d", "q", .done)])
        #expect(HubTriage.count(b, tone: .failed) == 4)
        #expect(HubTriage.firstID(b, tone: .failed)?.hasPrefix("group:") == true)
        #expect(HubTriage.firstID(b, tone: .working) == nil)
    }

    @Test func keyboardOrderAndClamp() {
        let b = TriageFixture.buckets((0..<3).map { TriageFixture.builder("g\($0)", "p", .done) } + [TriageFixture.builder("f", "q", .failed)])
        let collapsed = HubTriage.visibleIDs(b, expanded: [], backlogOpen: false)
        #expect(collapsed.count == 2)
        let group = collapsed[1]
        #expect(HubTriage.visibleIDs(b, expanded: [group], backlogOpen: false).count == 5)
        #expect(HubTriage.move(collapsed, from: nil, by: 1) == collapsed.first)
        #expect(HubTriage.move(collapsed, from: nil, by: -1) == collapsed.last)
        #expect(HubTriage.move(collapsed, from: collapsed.last, by: 1) == collapsed.last)
        #expect(HubTriage.move(collapsed, from: collapsed.first, by: -1) == collapsed.first)
        #expect(HubTriage.move([], from: nil, by: 1) == nil)
    }

    @Test func historyRowsOnlyWalkableWhenOpen() {
        let b = TriageFixture.buckets([TriageFixture.builder("old", "p", .done, acked: true)])
        #expect(HubTriage.visibleIDs(b, expanded: [], backlogOpen: false).isEmpty)
        #expect(HubTriage.visibleIDs(b, expanded: [], backlogOpen: true).count == 1)
    }

    @Test func cloudLinkStates() {
        #expect(CloudLink.of(error: nil, loaded: false) == .checking)
        #expect(CloudLink.of(error: nil, loaded: true) == .connected)
        #expect(CloudLink.of(error: "x", loaded: true) == .offline)
        #expect(CloudLink.offline.label == "Cloud · offline — retry")
    }
}

@MainActor
@Suite struct HubTriageInboundTests {
    private func job(_ id: String, _ status: PeerStatus, _ mode: PeerInboundMode = .ask) -> InboundJob {
        InboundJob(req: PeerJobRequest(jobId: id, title: "Job \(id)", brief: "b", repo: "/srv/gamenight", base: "main",
                                       mode: .background, fromAgent: "a"),
                   peerLabel: "Mini", peerMailbox: "m", status: status, note: "", inboundMode: mode, flags: [],
                   received: Date(timeIntervalSince1970: now - 30), finished: nil, branch: "b")
    }

    @Test func queuedAskJobLandsInNeedsYouWithAccept() {
        let b = HubTriage.build(groups: [], seatStatus: { _ in .asleep }, cloud: [], watcher: [],
                                inbound: [job("1", .queued)], now: now)
        let needs = b.first { $0.section == .needsYou }!
        guard case .row(let i) = needs.entries.first else { Issue.record("expected a row"); return }
        #expect(i.actionLabel == "Accept")
        #expect(i.action == .inbound("1"))
        #expect(i.tone == .needsYou)
        #expect(i.project == "gamenight")
        #expect(needs.count == 1)
    }

    @Test func acceptedOrAutoJobsStayOut() {
        let b = HubTriage.build(groups: [], seatStatus: { _ in .asleep }, cloud: [], watcher: [],
                                inbound: [job("2", .working), job("3", .queued, .auto), job("4", .done)], now: now)
        #expect(b.allSatisfy { $0.count == 0 })
    }
}
