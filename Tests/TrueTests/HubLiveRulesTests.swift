import Testing
import Foundation
@testable import True

private let now = 1_800_000_000.0
private let day = 86_400.0

@MainActor
@Suite struct HubLiveRulesTests {
    typealias F = TriageFixture

    private func sec(_ b: [TriageBucket], _ id: String) -> TriageSection? {
        for bucket in b {
            for e in bucket.entries {
                switch e {
                case .row(let i): if i.id == id { return bucket.section }
                case .group(let g): if g.items.contains(where: { $0.id == id }) { return bucket.section }
                }
            }
        }
        return nil
    }

    private func watch(_ id: String, _ kind: String, subject: String, source: String = "builders", at: Double,
                       title: String = "Builder feed-so…: check its gates") -> InboxItem {
        InboxItem(id: id, agent: "watcher", source: source, kind: kind, subject: subject, repo: "/p/timbre", fingerprint: id,
                  title: title, evidence: "", report: nil, level: nil, state: .open, seen: 1, at: at, cost: 0, note: nil,
                  builderID: nil, lookedFixed: false, snoozeUntil: nil, canInvestigate: false)
    }

    @Test func builderRulesByAge() {
        let b = F.buckets([F.builder("fresh", "a", .done, ago: 3600), F.builder("old", "a", .done, ago: day + 60),
                           F.builder("acked", "a", .done, ago: 60, acked: true), F.builder("killed", "a", .killed, ago: 60),
                           F.builder("f1", "a", .failed, ago: 3600), F.builder("f2", "a", .failed, ago: 2 * day),
                           F.builder("p", "a", .paused, ago: 60)])
        #expect(sec(b, "builder:fresh") == .review)
        #expect(sec(b, "builder:old") == .backlog)
        #expect(sec(b, "builder:acked") == .backlog)
        #expect(sec(b, "builder:killed") == .backlog)
        #expect(sec(b, "builder:f1") == .needsYou)
        #expect(sec(b, "builder:f2") == .backlog)
        #expect(sec(b, "builder:p") == .needsYou)
    }

    @Test func watcherDoneUncheckedIsLiveOnlyAndDedupesBuilderRow() {
        let live = F.builder("feed-solver", "timbre", .done, ago: 3600)
        let old = F.builder("old-one", "timbre", .done, ago: 3 * day)
        let acked = F.builder("acked-one", "timbre", .done, ago: 60, acked: true)
        let w = [watch("w1", "doneUnchecked", subject: "feed-solver", at: now - 3600),
                 watch("w2", "doneUnchecked", subject: "old-one", at: now - 3 * day),
                 watch("w3", "doneUnchecked", subject: "acked-one", at: now - 60),
                 watch("w4", "doneUnchecked", subject: "gone", at: now - 60)]
        let b = HubTriage.build(groups: F.groups([live, old, acked]), seatStatus: { _ in .asleep }, cloud: [], watcher: w,
                                builders: [live, old, acked], now: now)
        #expect(sec(b, "watch:w1") == .needsYou)
        #expect(sec(b, "builder:feed-solver") == nil)          // deduped: the watcher row speaks for it
        #expect(sec(b, "watch:w2") == .backlog)
        #expect(sec(b, "watch:w3") == .backlog)
        #expect(sec(b, "watch:w4") == .backlog)                // builder record gc'd
        let row = b.flatMap(\.entries).compactMap { e -> TriageItem? in if case .row(let i) = e, i.id == "watch:w1" { return i }; return nil }.first
        #expect(row?.title == "feed-solver")
        #expect(HubTriage.count(b, tone: .needsYou) == 1)
    }

    @Test func watcherFailedAndGit() {
        let f = F.builder("fx", "timbre", .failed, ago: 3600)
        let w = [watch("a", "failed", subject: "fx", at: now - 3600),
                 watch("g", "unpushed", subject: "repo@main", source: "git", at: now - 60)]
        let b = HubTriage.build(groups: F.groups([f]), seatStatus: { _ in .asleep }, cloud: [], watcher: w, builders: [f], now: now)
        #expect(sec(b, "watch:a") == .needsYou)
        #expect(sec(b, "watch:g") == .backlog)
    }

    @Test func closedPaneAndDismissed() {
        let open = UUID(), closed = UUID()
        func row(_ p: UUID) -> YourMoveRow {
            YourMoveRow(pane: p, name: "claude", project: "a", kind: .asksYou, reason: "q", at: Date(timeIntervalSince1970: now - 60))
        }
        let b = HubTriage.build(groups: [], seatStatus: { _ in .asleep }, cloud: [], watcher: [], yourMove: [row(open), row(closed)],
                                openPanes: [open], now: now)
        #expect(sec(b, "pane:\(open.uuidString)") == .needsYou)
        #expect(sec(b, "pane:\(closed.uuidString)") == .backlog)
        let d = HubTriage.build(groups: [], seatStatus: { _ in .asleep }, cloud: [], watcher: [], yourMove: [row(open)],
                                openPanes: [open], dismissed: ["pane:\(open.uuidString)"], now: now)
        #expect(sec(d, "pane:\(open.uuidString)") == nil)
    }

    @Test func cloudStaleGoesToBacklog() {
        var old = F.cloud("old", "done"); old.updatedAt = now - 2 * day
        let b = F.buckets([], cloud: [F.cloud("new", "done"), old, F.cloud("ask", "needsYou")])
        #expect(sec(b, "cloud:new") == .review)
        #expect(sec(b, "cloud:old") == .backlog)
        #expect(sec(b, "cloud:ask") == .needsYou)
    }

    @Test func ageAndCleanName() {
        #expect(HubTriage.age(20) == "now")
        #expect(HubTriage.age(120) == "2m")
        #expect(HubTriage.age(3 * 3600 + 100) == "3h")
        #expect(HubTriage.age(136.5 * 3600) == "5d")
        #expect(HubTriage.cleanName("Builder feed-solver finished: check its gates") == "feed-solver")
        #expect(HubTriage.cleanName("Builder x failed") == "x")
        #expect(HubTriage.cleanName("plain") == "plain")
    }

    @Test func layoutSizes() {
        let screen = CGSize(width: 2000, height: 1200)
        #expect(HubLayout.defaultSize(screen: screen) == CGSize(width: 1500, height: 900))
        #expect(HubLayout.defaultSize(screen: CGSize(width: 1000, height: 600)) == HubLayout.minSize)
        let s = HubLayout.size(saved: nil, screen: screen, window: CGSize(width: 1200, height: 800), margin: 24)
        #expect(s == CGSize(width: 1152, height: 752))
        #expect(HubLayout.isTwoColumn(width: 900) && !HubLayout.isTwoColumn(width: 899))
    }

    @Test func dismissalsPersistAndExpire() {
        let name = "hub-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        HubDismissals.add(["a"], d, now: 1000)
        HubDismissals.add(["b"], d, now: 1000 + HubDismissals.keepFor - 10)
        #expect(HubDismissals.load(d, now: 1000 + 20) == ["a", "b"])
        #expect(HubDismissals.load(d, now: 1000 + HubDismissals.keepFor + 5) == ["b"])
    }
}
