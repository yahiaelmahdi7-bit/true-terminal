import Foundation
import Testing
@testable import True

@Suite(.serialized) struct MissionHumanStepsTests {
    static let repo = "https://github.com/example/ledger-app"
    static let source = """
    # Mission: Acquire Stub
    workspace: stubco

    ## Ask
    tool: human
    where: alex
    Send the request.

    ## Read
    repo: \(repo)
    needs: Ask

    ## Approve
    tool: human
    where: owner
    needs: Read
    """

    final class Steward: MissionHumanSteps {
        var items: [String: String] = [:]      // key -> item
        var done = Set<String>()
        var opens: [String] = []
        var offline = false
        var released: [String] = []
        func open(key: String, title: String, who: String, brief: String, workspace: String) throws -> String {
            if offline { throw HumanStepError.offline }
            if let id = items[key] { return id }
            let id = "item-\(items.count + 1)"; items[key] = id; opens.append(key); return id
        }
        func state(item: String) throws -> HumanStepState {
            if offline { throw HumanStepError.offline }
            return done.contains(item) ? .done : .open(owner: nil)
        }
        func release(item: String, reason: String) throws { released.append(item) }
    }
    final class Clock { var t = Date(timeIntervalSince1970: 100) }

    struct World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let launcher = MissionsTests.Launcher(), gate = MissionsTests.Gate(), scheduler = MissionsTests.Schedule()
        let steward = Steward(), clock = Clock()
        func open(source: String? = MissionHumanStepsTests.source) throws -> MissionRunner {
            try MissionRunner(id: "acq", root: root, source: source, peers: ["alex"], launcher: launcher,
                              gate: gate, now: { clock.t }, scheduler: scheduler.enqueue,
                              route: { _, _ in .mine }, humans: steward)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func humanStepBlocksDependentsThenDoneUnblocks() throws {
        let w = World(); defer { w.clean() }
        let r = try w.open(); defer { r.close() }
        try r.reconcile()
        #expect(w.steward.opens.count == 1)
        #expect(r.jobs["Ask"]?.state == .needsYou)
        #expect(w.launcher.starts.isEmpty)
        #expect(r.jobs["Read"]?.state == .blocked)
        w.clock.t += 20; try r.reconcile()
        #expect(w.launcher.starts.isEmpty)
        w.steward.done.insert("item-1")
        try r.reconcile(pollHumans: true)
        #expect(r.jobs["Ask"]?.state == .answered)
        try r.reconcile()
        #expect(w.launcher.starts.map(\.job.title) == ["Read"])
        #expect(w.steward.opens.count == 1)
        w.launcher.finish("Read"); try r.reconcile()
        try r.reconcile()
        #expect(r.jobs["Approve"]?.state == .needsYou)
        #expect(w.steward.opens.count == 2)
    }

    @Test func restartKeepsTheSameItem() throws {
        let w = World(); defer { w.clean() }
        var r = try w.open()
        try r.reconcile()
        let item = r.jobs["Ask"]?.item
        #expect(item != nil)
        r.close()
        r = try w.open(source: nil); defer { r.close() }
        try r.reconcile(pollHumans: true)
        #expect(r.jobs["Ask"]?.item == item)
        #expect(w.steward.opens.count == 1)
    }

    @Test func replayAfterCrashBeforeItemSavedFindsSameItem() throws {
        let w = World(); defer { w.clean() }
        // Steward already holds the item for the key the mission will use (crash after Steward answered, before we saved it).
        w.steward.items["mission-acq-0-0"] = "item-9"
        let r = try w.open(); defer { r.close() }
        try r.reconcile()
        #expect(r.jobs["Ask"]?.item == "item-9")
        #expect(w.steward.opens.isEmpty)
    }

    @Test func stewardOfflineKeepsTheStepAndRetries() throws {
        let w = World(); defer { w.clean() }
        w.steward.offline = true
        let r = try w.open(); defer { r.close() }
        try r.reconcile()
        #expect(r.jobs["Ask"]?.state == .needsYou && r.jobs["Ask"]?.item == nil)
        #expect(r.jobs["Ask"]?.reason.isEmpty == false)
        w.steward.offline = false; w.clock.t += 20
        try r.reconcile(pollHumans: true)
        #expect(r.jobs["Ask"]?.item == "item-1")
        #expect(w.steward.opens.count == 1)
    }

    @Test func cancelReleasesOpenSteps() throws {
        let w = World(); defer { w.clean() }
        let r = try w.open(); defer { r.close() }
        try r.reconcile()
        try r.cancel()
        #expect(w.steward.released == ["item-1"])
    }

    @Test func templateFillAndErrors() throws {
        #expect(try MissionTemplates.fill("Acquire {{firm}}", vars: ["firm": "stubco"]) == "Acquire stubco")
        #expect(throws: PeerError.self) { try MissionTemplates.fill("{{firm}} {{repo}}", vars: ["firm": "x"]) }
        #expect(throws: PeerError.self) { try MissionTemplates.fill("{{firm}}", vars: ["firm": "a\nb"]) }
    }

    @Test func parserRejectsHumanWithoutWhereOrWorkspace() {
        #expect(throws: MissionValidationError.self) { try MissionFile.parse("# Mission: M\nworkspace: w\n## A\ntool: human", peers: []) }
        #expect(throws: MissionValidationError.self) { try MissionFile.parse("# Mission: M\n## A\ntool: human\nwhere: owner", peers: []) }
    }

    @Test func allTemplatesParseWhenFilled() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/missions/templates")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }   // docs/ is not in the public tree
        let names = MissionTemplates.names(in: [dir])
        #expect(names.sorted() == ["acquire-firm", "month-end", "onboard-peer", "stand-up-ledger"])
        for n in names {
            let text = try MissionTemplates.fill(try MissionTemplates.load(n, in: [dir]),
                                                 vars: ["firm": "stubco", "person": "alex", "repo": Self.repo])
            let file = try MissionFile.parse(text, peers: ["alex", "owner"])
            #expect(!file.jobs.isEmpty, "\(n)")
        }
    }
}
