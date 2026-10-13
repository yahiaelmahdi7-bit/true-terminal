import Testing
import Foundation
@testable import True

private func tmpDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("ckpt-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func failedBuilder(_ id: String = "b1") -> BuilderRecord {
    BuilderRecord(id: id, name: id, cwd: "/tmp/r", originCwd: "/tmp/r", model: "sonnet", sessionID: "s", claudePID: 0,
                  started: 1000, ended: 1060, state: .failed, acked: false)
}
private func capJSON(_ subtype: String, session: String? = "S1", cost: Double = 0.1) -> String {
    let sid = session.map { "\"session_id\":\"\($0)\"," } ?? ""
    return "{\"subtype\":\"\(subtype)\",\(sid)\"total_cost_usd\":\(cost),\"usage\":{\"input_tokens\":3000}}"
}
private func reportJSON(cost: Double = 0.1) -> String {
    let rep = ItemReport(title: "Gate skipped", what: "w", cause: "c", sure: "high", evidence: [],
                         fix: .init(summary: "Add the flag", steps: ["Edit Package.swift"], commands: [], files: ["Package.swift"]),
                         checked: [], unknowns: [])
    return "{\"total_cost_usd\":\(cost),\"usage\":{\"input_tokens\":2000},\"structured_output\":\(String(decoding: try! JSONEncoder().encode(rep), as: UTF8.self))}"
}

@Suite struct CapParseTests {
    @Test func turnCapBecomesCapped() {
        if case let .capped(reason, sid, cost, tokens) = Investigation.parse(status: 1, output: capJSON("error_max_turns")) {
            #expect(reason == "Hit its turn limit" && sid == "S1" && cost == 0.1 && tokens == 3000)
        } else { Issue.record("expected capped") }
    }
    @Test func moneyCapBecomesCapped() {
        if case let .capped(reason, sid, _, _) = Investigation.parse(status: 1, output: capJSON("error_max_budget_usd", session: "S9")) {
            #expect(reason == "Hit its money limit" && sid == "S9")
        } else { Issue.record("expected capped") }
    }
    @Test func capWithoutSessionOrGarbageStaysStopped() {
        if case .capped = Investigation.parse(status: 1, output: capJSON("error_max_turns", session: nil)) { Issue.record("no session: must stay stopped") }
        if case .capped = Investigation.parse(status: 1, output: "not json") { Issue.record("garbage must stay stopped") }
        if case let .stopped(why, _) = Investigation.parse(status: 1, output: "{\"usage\":{\"input_tokens\":90000}}") { #expect(why.contains("90k")) }
        else { Issue.record("expected stopped") }
    }
    @Test func resumeArgvCarriesSessionAndKeepsTheRest() {
        let p = Investigation.Paths(home: URL(fileURLWithPath: "/h"), hooksDir: URL(fileURLWithPath: "/k"), rolesDir: URL(fileURLWithPath: "/r"))
        let a = Investigation.argv(paths: p, maxBudgetUSD: 0.3, maxTurns: 30, addDir: nil, resume: "S1")
        #expect(a[a.firstIndex(of: "--resume")! + 1] == "S1" && a.contains("--json-schema") && a.contains("--max-turns"))
        #expect(!Investigation.argv(paths: p, maxBudgetUSD: 0.3, maxTurns: 30, addDir: nil).contains("--resume"))
    }
}

@Suite struct PausedBuilderTests {
    private func meta(_ status: String, acked: Bool = false) -> Data {
        Data("{\"id\":\"p1\",\"name\":\"fix-x\",\"cwd\":\"/tmp/r\",\"started\":1000,\"status\":\"\(status)\",\"acked\":\(acked)}".utf8)
    }
    @Test func pausedStatusParsesAsPausedNotFailed() {
        let b = BuilderRecord.parse(meta("paused"))
        #expect(b?.state == .paused && b?.statusLabel == "Paused")
    }
    @Test func pausedYieldsASignalUnlessAcked() {
        let b = BuilderRecord.parse(meta("paused"))!
        let s = BuilderSignals.scan([b], now: 5000, resultText: { _ in nil })
        #expect(s.count == 1 && s[0].kind == "paused" && s[0].title == "Builder fix-x paused: needs a go-ahead")
        #expect(s[0].evidence == "The builder paused and left no result.md.")
        let withResult = BuilderSignals.scan([b], now: 5000, resultText: { _ in "Reached the ceiling" })
        #expect(withResult[0].evidence == "Reached the ceiling")
        let acked = BuilderRecord.parse(meta("paused", acked: true))!
        #expect(BuilderSignals.scan([acked], now: 5000, resultText: { _ in nil }).isEmpty)
    }
    @Test func fixMaxDefaultsToTenAndDecodesTolerantly() throws {
        #expect(DutyBudget().fixMaxUSD == 10)
        #expect(try JSONDecoder().decode(DutyBudget.self, from: Data("{\"dailyUSD\":3}".utf8)).fixMaxUSD == 10)
        #expect(try JSONDecoder().decode(DutyBudget.self, from: Data("{\"fixMaxUSD\":\"x\"}".utf8)).fixMaxUSD == 10)
    }
}

@MainActor @Suite struct CheckpointInvestigateTests {
    struct Rig {
        let store: WatcherStore, runs: Box<[(argv: [String], stdin: String)]>, spawns: Box<[[String]]>, root: URL
    }
    /// `script` is replayed in order; the last entry repeats.
    static func rig(_ script: [String]) -> Rig {
        let root = tmpDir()
        let jev = NoulJev { id in id.hasPrefix("wg_") ? (id == "wg_injection" ? 0.02 : 0.95) : (["p_local", "p_undo", "p_scope"].contains(id) ? 0.95 : 0.02) }
        let runs = Box<[(argv: [String], stdin: String)]>([])
        let spawns = Box<[[String]]>([])
        let clock = Box(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12))!)
        var d = WatcherStore.Deps()
        d.jev = JevClient(transport: jev, keyProvider: { "k" }, env: [:])
        d.runner = { argv, _, stdin, _ in
            let n = runs.value.count
            runs.mutate { $0.append((argv, stdin)) }
            return (0, script[min(n, script.count - 1)])
        }
        d.spawn = { argv in spawns.mutate { $0.append(argv) }; return (0, "STARTED b-123\n") }
        d.git = { _ in nil }
        d.now = { clock.value }
        d.root = root
        d.paths = Investigation.Paths(home: root.appendingPathComponent("watcher"), hooksDir: root.appendingPathComponent("hooks"),
                                      rolesDir: root.appendingPathComponent("roles"))
        d.builderBin = "/bin/builder"
        d.enabled = { true }
        return Rig(store: WatcherStore(deps: d), runs: runs, spawns: spawns, root: root)
    }
    static func resumeID(_ argv: [String]) -> String? { argv.firstIndex(of: "--resume").map { argv[$0 + 1] } }

    @Test func cappedThenReportContinuesTheSameSession() async {
        let r = Self.rig([capJSON("error_max_turns", cost: 0.1), reportJSON(cost: 0.1)])
        await r.store.scan(builders: [failedBuilder()])
        #expect(r.runs.value.count == 2)
        #expect(Self.resumeID(r.runs.value[0].argv) == nil && Self.resumeID(r.runs.value[1].argv) == "S1")
        #expect(r.runs.value[1].stdin.contains("Checkpoint, not a stop"))
        let it = r.store.items[0]
        #expect(it.report?.title == "Gate skipped" && it.resumeSession == nil && abs(it.cost - 0.2) < 1e-9)
        #expect(r.store.today().runs == 1 && abs(r.store.today().usd - 0.2) < 1e-9 && r.store.today().perRepo["/tmp/r"] == 1)
    }

    @Test func dailyBudgetExhaustedParksTheSessionThenResumes() async {
        let r = Self.rig([capJSON("error_max_budget_usd", cost: 0.18), reportJSON(cost: 0.1)])
        r.store.duty.budget.dailyUSD = 0.2
        await r.store.scan(builders: [failedBuilder()])
        #expect(r.runs.value.count == 1)
        var it = r.store.items[0]
        #expect(it.note?.contains("Paused at the daily budget (12:00): Investigate continues where it stopped") == true)
        #expect(it.resumeSession == "S1" && it.report == nil)
        #expect(r.store.today().runs == 1)
        r.store.duty.budget.dailyUSD = 2.0
        await r.store.investigate(it.id)
        #expect(r.runs.value.count == 2 && Self.resumeID(r.runs.value[1].argv) == "S1")
        #expect(r.runs.value[1].stdin.contains("Checkpoint, not a stop"))
        it = r.store.items[0]
        #expect(it.report != nil && it.resumeSession == nil && it.note == nil)
        #expect(r.store.today().runs == 1)
    }

    @Test func continuationsStopAtFour() async {
        let r = Self.rig([capJSON("error_max_turns", cost: 0.01)])
        await r.store.scan(builders: [failedBuilder()])
        #expect(r.runs.value.count == 5)
        #expect(r.store.items[0].report == nil && r.store.items[0].note?.contains("4 continuations") == true)
        #expect(r.store.today().runs == 1)
    }

    @Test func contextSizeStopIsNotResumed() async {
        let r = Self.rig(["{\"usage\":{\"input_tokens\":90000}}"])
        await r.store.scan(builders: [failedBuilder()])
        #expect(r.runs.value.count == 1 && r.store.items[0].resumeSession == nil && r.store.items[0].note?.contains("90k") == true)
    }

    @Test func approvePassesTheAbsoluteCeiling() async {
        let r = Self.rig([reportJSON()])
        await r.store.scan(builders: [failedBuilder()])
        _ = await r.store.approve(r.store.items[0].id)
        let a = r.spawns.value[0]
        #expect(a[a.firstIndex(of: "--max-total")! + 1] == "10.00" && a[a.firstIndex(of: "--budget")! + 1] == "1.00")
    }
}
