import Testing
import Foundation
@testable import True

/// Today's load as plain triage items: 21 needs-you across kinds, 144 backlog, 3 running, 5 done. Shared with the stills.
enum HubBoardFixture {
    static let now = 1_800_000_000.0

    static func item(_ id: String, _ section: TriageSection, _ tone: TriageTone, _ title: String, _ sub: String, project: String,
                     noun: String, action: String, cloud: Bool = false, ago: Double = 600) -> TriageItem {
        TriageItem(id: id, section: section, tone: tone, title: title, subtitle: sub, project: project, at: now - ago,
                   isCloud: cloud, actionLabel: action, action: cloud ? .cloud(id) : .builder(id), noun: noun)
    }

    static func needsYou() -> [TriageItem] {
        var out: [TriageItem] = []
        for n in 0..<9 { out.append(item("rev\(n)", .needsYou, .needsYou, "peers-u\(n)", "Finished: check its gates", project: n % 2 == 0 ? "true" : "prism", noun: "builders", action: "Review gates", ago: Double(60 * n + 60))) }
        for n in 0..<3 { out.append(item("pause\(n)", .needsYou, .needsYou, "steward-step\(n)", "Paused, needs a go-ahead", project: "true", noun: "builders", action: "Open", ago: Double(900 + n))) }
        for n in 0..<3 { out.append(item("ask\(n)", .needsYou, .needsYou, "Add login test \(n)", "Which database?", project: "gamenight", noun: "cloud jobs", action: "Answer", cloud: true, ago: Double(300 + n))) }
        for n in 0..<2 { out.append(item("pane\(n)", .needsYou, .needsYou, "pane \(n)", "Waiting on your answer", project: "prism", noun: "panes", action: "Open", ago: Double(1200 + n))) }
        for n in 0..<2 { out.append(item("bfail\(n)", .needsYou, .failed, "ledger-audit\(n)", "Sonnet · failed after 14m", project: "finance-desk", noun: "builders", action: "Open", ago: Double(2000 + n))) }
        out.append(item("peer0", .needsYou, .needsYou, "Fix the nav", "From Alex · waiting for Accept", project: "clip-site", noun: "peer jobs", action: "Accept"))
        out.append(item("cfail0", .needsYou, .failed, "Bump deps", "Hit its $3 cap", project: "gamenight", noun: "cloud jobs", action: "Open", cloud: true))
        return out
    }

    static func running() -> [TriageItem] {
        var a = item("run-cloud", .working, .working, "Refactor the importer", "Running 12m", project: "gamenight", noun: "cloud jobs", action: "Open", cloud: true, ago: 720)
        a.activity = "Writing tests for the importer"
        var b = item("run-mac", .working, .working, "hub-v4-tiles", "Sonnet · running 31m", project: "true", noun: "builders", action: "Open", ago: 1860)
        b.activity = "Running swift build"; b.cost = 1.4
        var c = item("run-alex", .working, .working, "Clip captions pass", "Running 5m", project: "clip-site", noun: "peer jobs", action: "Open", ago: 300)
        c.activity = "Reading the style notes"; c.machine = "Alex's Mac"
        return [a, b, c]
    }

    static func done() -> [TriageItem] {
        (0..<5).map { item("done\($0)", .review, .done, ["Fix footer links", "Tidy settings", "Rename modules", "Add retry test", "Update docs"][$0], "Finished", project: "true", noun: "builders", action: "Review gates", ago: Double(3600 * ($0 + 1))) }
    }

    static func backlog(_ n: Int = 144) -> [TriageItem] {
        (0..<n).map { item("old\($0)", .backlog, .idle, "old-\($0)", "Finished", project: "archive", noun: "builders", action: "Open", ago: 200_000 + Double($0)) }
    }

    static func buckets(needs: [TriageItem], working: [TriageItem] = [], review: [TriageItem] = [], backlog: [TriageItem] = []) -> [TriageBucket] {
        func b(_ s: TriageSection, _ xs: [TriageItem]) -> TriageBucket { TriageBucket(section: s, entries: xs.map { .row($0) }, count: xs.count) }
        return [b(.needsYou, needs), b(.working, working), b(.review, review), b(.backlog, backlog)]
    }

    static var today: [TriageBucket] { buckets(needs: needsYou(), working: running(), review: done(), backlog: backlog()) }
}

@Suite struct HubBoardTests {
    @Test func todaysLoadFitsSixNeedsYouTilesAndNoBacklogRows() {
        let b = HubTriage.board(HubBoardFixture.today)
        #expect(HubBoardFixture.needsYou().count == 21)
        #expect(b.needsYou.count <= 6)
        #expect(b.needsYouCount == 21)
        #expect(b.backlogCount == 144)
        // The board holds no backlog item anywhere.
        let ids = Set((b.needsYou + b.running).flatMap(\.items).map(\.id)).union(b.done.map(\.id))
        #expect(!ids.contains { $0.hasPrefix("old") })
        #expect(b.running.count == 3)
        #expect(b.done.count == 5)
    }

    @Test func moreThanSixGroupsBecomeANMoreTile() {
        let b = HubTriage.board(HubBoardFixture.today)
        #expect(b.needsYou.count == 6)
        let more = b.needsYou.last!
        #expect(more.kind == .more)
        // Nothing is lost: every needs-you item sits behind exactly one tile.
        #expect(b.needsYou.reduce(0) { $0 + $1.count } == 21)
        #expect(more.title.hasSuffix(" more groups"))
        #expect(more.detail.contains(" · "))
    }

    @Test func sameKindItemsShareOneTile() {
        let b = HubTriage.board(HubBoardFixture.today)
        let reviews = b.needsYou.first { $0.title == "9 reviews waiting" }
        #expect(reviews?.button == "Review")
        #expect(reviews?.items.count == 9)
    }

    @Test func failuresGroupByCauseAndHideRetry() {
        let b = HubTriage.board(HubBoardFixture.today)
        let f = b.needsYou.first { $0.title == "2 builders failed" }
        #expect(f?.kind == .failures)
        #expect(f?.button == "See what broke")
        #expect(f?.secondary == "")
        #expect(f?.detail.isEmpty == false)
        // A different cause is a different tile.
        let items = [HubBoardFixture.item("a", .needsYou, .failed, "a", "Sonnet · failed after 3m", project: "p", noun: "builders", action: "Open"),
                     HubBoardFixture.item("b", .needsYou, .failed, "b", "Sonnet · died after 3m", project: "p", noun: "builders", action: "Open")]
        let two = HubTriage.board(HubBoardFixture.buckets(needs: items))
        #expect(two.needsYou.count == 2)
    }

    @Test func fewGroupsAllShowWithoutAMoreTile() {
        let b = HubTriage.board(HubBoardFixture.buckets(needs: Array(HubBoardFixture.needsYou().prefix(8))))
        #expect(b.needsYou.allSatisfy { $0.kind != .more })
    }

    @Test func emptyInputIsTheEmptyHub() {
        let b = HubTriage.board(HubBoardFixture.buckets(needs: []))
        #expect(b.isEmpty)
        #expect(b.needsYou.isEmpty && b.running.isEmpty && b.done.isEmpty)
        #expect(b.backlogCount == 0)
        #expect(HubTriage.groupWords(noun: "cloud jobs", action: "x", count: 2).button == "Answer")
        #expect(HubTriage.groupWords(noun: "builders", action: "Review gates", count: 2).button == "Review")
        #expect(HubTriage.groupWords(noun: "builders", action: "Open", count: 2).button == "Give go-ahead")
        #expect(HubTriage.groupWords(noun: "panes", action: "x", count: 2).button == "Look")
        #expect(HubTriage.plainVerb("Review gates") == "Review")
        let none = HubTriage.board([])
        #expect(none.isEmpty)
    }

    @Test func emptyBandsAreAbsentNotPlaceholders() {
        let b = HubTriage.board(HubBoardFixture.buckets(needs: [], working: HubBoardFixture.running()))
        #expect(b.needsYou.isEmpty)
        #expect(!b.isEmpty)
    }

    @Test func plainStatusReadsAsEnglish() {
        let done = HubBoardFixture.item("d", .needsYou, .needsYou, "d", "Finished: check its gates", project: "p", noun: "builders", action: "Review gates")
        let s = HubTriage.plainStatus(done, now: done.at + 60)
        #expect(s == "finished 1m ago")
        #expect(HubTriage.plainStatus(done, now: done.at) == "finished just now")
    }

    @Test func runningTilesCarryWhereChips() {
        let b = HubTriage.board(HubBoardFixture.today)
        #expect(b.running.map { $0.items[0].runsOn.label } == ["Cloud", "My Mac", "Alex's Mac"])
    }
}
