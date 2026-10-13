import Testing
import Foundation
@testable import True

/// Answers each question id with `noul(id)`; records the state of every call.
final class NoulJev: JevTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var states: [[String: Any]] = []
    let noul: @Sendable (String) -> Double?
    let status: Int
    init(status: Int = 200, noul: @escaping @Sendable (String) -> Double?) { self.status = status; self.noul = noul }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let obj = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        lock.withLock { states.append(obj["state"] as? [String: Any] ?? [:]) }
        var answers: [String: Any] = [:]
        for id in (obj["questions"] as? [String: Any] ?? [:]).keys {
            if let v = noul(id) { answers[id] = ["type": "noul", "noul": v] }
        }
        return (status, try JSONSerialization.data(withJSONObject: ["model": "jev-latest", "answers": answers]))
    }
}

private func jev(_ t: NoulJev) -> JevClient { JevClient(transport: t, keyProvider: { "k" }, env: [:]) }

@Suite struct CleanerFactCheckTests {
    typealias C = CleanerFactCheck

    // MARK: blocks / norm / dice

    @Test func blocksSplitAndJoin() {
        let text = """
        # Title
        intro line one
        continues here

        - item a
          wrapped item a
        * item b
        + item c
        1. first
        12. twelfth
        > quote
        | a | b |
        123 not a list
        """
        #expect(C.blocks(text) == ["# Title intro line one continues here", "- item a wrapped item a",
                                   "* item b", "+ item c", "1. first", "12. twelfth", "> quote", "| a | b | 123 not a list"])
    }

    @Test func normStripsMarkupAndMarkers() {
        #expect(C.norm("- **NEVER**  push `main`  now") == "never push main now")
        #expect(C.norm("1. Do the _thing_") == "do the thing")
        #expect(C.norm("## > | Heading") == "heading")
        #expect(C.norm("* item") == "item")
    }

    @Test func diceIsMultisetOverWords() {
        #expect(C.dice("a b c d", "a b c d") == 1)
        #expect(C.dice("a a b", "a b b") == 2 * 2.0 / 6)
        #expect(C.dice("x y", "p q") == 0)
        #expect(C.dice("", "") == 0)
    }

    // MARK: vanished

    @Test func rewrappedParagraphIsKept() {
        let orig = "The deploy runs from the staging box and needs the VPN\nto be up before the script starts."
        let out = "The deploy runs from the staging box and needs the VPN to be up before the script starts."
        #expect(C.vanished(original: orig, output: out).isEmpty)
    }

    @Test func reWordedButPresentLineIsKept() {
        let orig = "- The deploy script needs the VPN to be up before it starts running"
        let out = "- Deploy script needs the VPN up before it starts running"
        #expect(C.vanished(original: orig, output: out).isEmpty)
    }

    @Test func deletedRuleIsVanished() {
        let orig = "# Notes\n\n- Never run the migration against production without a backup\n- Tests live in Tests/"
        let out = "# Notes\n\n- Tests live in Tests/"
        #expect(C.vanished(original: orig, output: out) == ["- Never run the migration against production without a backup"])
    }

    @Test func repeatedVanishedBlockIsReportedOnce() {
        let rule = "- Never run the migration against production without a backup"
        let orig = "# Notes\n\n\(rule)\n- Tests live in Tests/\n\n## Again\n\n\(rule)"
        #expect(C.vanished(original: orig, output: "# Notes\n\n- Tests live in Tests/") == [rule])
    }

    @Test func shortBlocksAreIgnored() {
        #expect(C.vanished(original: "# Rules\n\n- be nice", output: "x").isEmpty)   // "rules" / "be nice" < 15 chars
    }

    // MARK: flag rule

    @Test func flagTruthTable() {
        #expect(C.flag(filler: 0.1, kept: 0.1))
        #expect(C.flag(filler: 0.49, kept: 0.49))
        #expect(!C.flag(filler: 0.5, kept: 0.1))    // filler
        #expect(!C.flag(filler: 0.1, kept: 0.5))    // still stated
        #expect(!C.flag(filler: 0.9, kept: 0.9))
        #expect(!C.flag(filler: nil, kept: 0.1))    // missing answer never flags
    }

    // MARK: run

    private let original = "# T\n\n- Never run the migration against production without a backup\n- Always keep the shared mizan worktree clean before switching branches\n- Tests live in Tests/"
    private let output = "# T\n\n- Tests live in Tests/"

    @Test func flagsOnlyWhatJevCannotClear() async {
        // f0 says not filler (0.1), k0 says not kept (0.2) -> flagged. Block 1: filler 0.9 -> cleared.
        let t = NoulJev { id in ["f0": 0.1, "k0": 0.2, "f1": 0.9, "k1": 0.1][id] }
        let r = await C.run(original: original, output: output, jev: jev(t))
        #expect(r == .flagged([LostFact(text: "- Never run the migration against production without a backup")]))
        #expect(r.blocksApply)
        #expect(t.states.count == 2)
        let filler = t.states.first { $0["after"] == nil }, kept = t.states.first { $0["after"] != nil }
        #expect((filler?["dropped"] as? [String])?.count == 2)
        #expect(kept?["after"] as? String == output)
    }

    @Test func allClearedIsClean() async {
        let t = NoulJev { _ in 0.9 }
        let r = await C.run(original: original, output: output, jev: jev(t))
        #expect(r == .clean && !r.blocksApply)
    }

    @Test func noReplyMeansOffAndKeepsRowCheckable() async {
        let r = await C.run(original: original, output: output, jev: jev(NoulJev(status: 500) { _ in 0.1 }))
        #expect(r == .off && !r.blocksApply)
    }

    @Test func nothingVanishedSkipsJev() async {
        let t = NoulJev { _ in 0.0 }
        let r = await C.run(original: output, output: output, jev: jev(t))
        #expect(r == .clean && t.states.isEmpty)
    }

    @Test func moreThan40BlocksIsLargeRewrite() async {
        let many = (0..<41).map { "- Rule number \($0) says do something quite specific here" }.joined(separator: "\n")
        let t = NoulJev { _ in 0.0 }
        let r = await C.run(original: many, output: "# Gone", jev: jev(t))
        #expect(r == .largeRewrite(41) && r.blocksApply && t.states.isEmpty)
    }

    @Test func exactly40AreSentAndFlagsNeverTouchRegexChips() async {
        let many = (0..<40).map { "- Rule number \($0) says do something quite specific `x\($0)`" }.joined(separator: "\n")
        let t = NoulJev { _ in 0.0 }
        let out = "# Gone"
        let r = await C.run(original: many, output: out, jev: jev(t))
        #expect(r.flags.count == 40)
        // The regex check is a separate pure function and is unaffected by Jev.
        #expect(CleanerChecks.droppedFacts(original: many, output: out).count == 40)
    }

    // MARK: engine wiring

    @Test func engineFlagUnchecksRowAndEngineWithoutJevIsNotRun() async throws {
        let home = cleanerTemp()
        cleanerWrite(home.appendingPathComponent("p/CLAUDE.md"), original + String(repeating: "\n- filler filler filler filler filler filler", count: 20))
        let files = ContextScanner(home: home.path).scan(roots: [home.path + "/p"])
        let runner = FakeRunner(); runner.reply = { _ in "# T\n\n- Tests live in Tests/" }
        var engine = CleanerEngine(runner: runner, binary: URL(fileURLWithPath: "/fake/claude"),
                                   cwd: URL(fileURLWithPath: "/fake/e"), env: [:])
        final class Box: @unchecked Sendable { var o: RewriteOutcome? }
        let box = Box()
        await engine.rewrite(files, model: .opus) { _, e in if case .finished(.success(let o)) = e { box.o = o } }
        #expect(box.o?.factCheck == .notRun)
        engine.jev = jev(NoulJev { _ in 0.1 })
        await engine.rewrite(files, model: .opus) { _, e in if case .finished(.success(let o)) = e { box.o = o } }
        #expect(box.o?.factCheck.blocksApply == true)
    }
}
