import Testing
import Foundation
@testable import True

/// A scripted brain: records every call; never touches the live server on 127.0.0.1:8800.
final class FakeBrain: BrainTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [[String]] = [], _questions: [String] = []
    /// How many `scopes()` calls come back nil before the brain is "up" (a cold start).
    var coldCalls = 0
    private var calls = 0
    var scopeMap: [String: String]? = ["finance-director-os": "shared-projects", "prism": "walled-prism", "docs": "shared-knowledge"]
    var reply: @Sendable (String) -> BrainAnswer? = { _ in BrainAnswer(answer: "director.plan() builds the plan.", sources: ["/Users/example/Projects/finance-director-os/SPEC.md"]) }
    var asked: [[String]] { lock.lock(); defer { lock.unlock() }; return _asked }
    var questions: [String] { lock.lock(); defer { lock.unlock() }; return _questions }
    private func record(_ q: String, _ p: [String]) { lock.lock(); _asked.append(p); _questions.append(q); lock.unlock() }
    func ask(question: String, projects: [String]) async -> BrainAnswer? {
        record(question, projects)
        return reply(question)
    }
    private func nextScopes() -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls <= coldCalls ? nil : scopeMap
    }
    func scopes() async -> [String: String]? {
        return nextScopes()
    }
    private(set) var wakeCalls = 0
    func wakeIfDown() async { bumpWake() }
    private func bumpWake() { lock.lock(); wakeCalls += 1; lock.unlock() }
}

final class OracleKnobs: @unchecked Sendable { var on = true; var projects: [String] = ["finance-director-os"]; var slept: [TimeInterval] = [] }

@Suite(.serialized) struct OracleTests {
    /// `a` ("Al", calls b "Bea") asks; `b` ("Bo", calls a "Al") owns the brain and the oracle.
    struct Rig { let a: PeerSide, b: PeerSide, abus: ChatBus, bbus: ChatBus, brain: FakeBrain, knobs: OracleKnobs, oracle: Oracle }
    func rig() -> Rig {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        let ab = a.attachChat(), bb = b.attachChat()
        a.sink.awake = ["dev"]
        let brain = FakeBrain(), k = OracleKnobs()
        let bLinkId = b.engine.peerLinks().first!.mailboxId
        let o = Oracle(engine: b.engine, bus: bb, brain: brain, askOn: { k.on }, projectsFor: { $0 == bLinkId ? k.projects : [] },
                       now: { clock.now() }, sleep: { s in k.slept.append(s) })
        return Rig(a: a, b: b, abus: ab, bbus: bb, brain: brain, knobs: k, oracle: o)
    }
    /// dev@al asks `@oracle@bea`; returns the question id once the answer has travelled back.
    @discardableResult
    func ask(_ r: Rig, _ q: String, agent: String = "dev") async -> String {
        guard case .success(let m) = r.a.engine.postChat(channel: "@oracle@bea", agent: agent, text: q) else { fatalError("post failed") }
        r.a.engine.flushChat(); settle(r.a, r.b)
        await r.oracle.waitIdle()
        r.b.engine.flushChat(); settle(r.a, r.b)
        return m.id
    }
    func close(_ r: Rig) { r.a.close(); r.b.close() }

    @Test func peerRoundTripReturnsACitedAnswerWithRe() async {
        let r = rig(); defer { close(r) }
        let id = await ask(r, "what does director.plan() do?")
        #expect(r.brain.asked == [["finance-director-os"]])
        let lines = r.a.sink.lines("dev")
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("[@dev oracle@bea] director.plan() builds the plan."))
        #expect(lines[0].contains("Sources: finance-director-os/SPEC.md") && !lines[0].contains("/Users/"))
        #expect(r.abus.tail("@dev").last?.re == id)
    }

    @Test func emptyAllowListGetsTheNackAndNoBrainCall() async {
        let r = rig(); defer { close(r) }
        r.knobs.projects = []
        await ask(r, "anything?")
        #expect(r.brain.asked.isEmpty)
        #expect(r.a.sink.lines("dev").first?.contains("No projects are shared with you for asking — ask Bo in #bo.") == true)
    }

    @Test func walledSlugsAreFilteredOutBeforeTheCall() async {
        let r = rig(); defer { close(r) }
        r.knobs.projects = ["prism", "finance-director-os", "unknown-slug"]
        await ask(r, "q")
        #expect(r.brain.asked == [["finance-director-os"]])
        r.brain.scopeMap = ["prism": "walled-prism"]
        r.knobs.projects = ["prism"]
        await ask(r, "q2")
        #expect(r.brain.asked.count == 1)                                   // nothing queried for an all-walled list
        #expect(r.a.sink.lines("dev").last?.contains("No projects are shared") == true)
    }

    @Test func brainDownSaysAsleep() async {
        let r = rig(); defer { close(r) }
        r.brain.reply = { _ in nil }
        await ask(r, "q")
        #expect(r.a.sink.lines("dev").first?.contains("The brain on Bo's Mac is asleep — ask in #bo.") == true)
        r.brain.scopeMap = nil
        await ask(r, "q2")                                  // scopes are cached (10 min), so no wake — the ask itself failing is "asleep"
        #expect(r.a.sink.lines("dev").last?.contains("is asleep") == true)
    }

    @Test func noSourcesMeansNoRecord() async {
        let r = rig(); defer { close(r) }
        r.brain.reply = { _ in BrainAnswer(answer: "I think maybe", sources: []) }
        await ask(r, "q")
        #expect(r.a.sink.lines("dev").first?.contains("No record in the brain for that — ask Bo in #bo.") == true)
    }

    @Test func replyIsMaskedAndCappedAt4KB() async {
        let r = rig(); defer { close(r) }
        r.brain.reply = { _ in BrainAnswer(answer: "key sk-abcdefgh12345678 " + String(repeating: "x", count: 6000), sources: ["/Users/me/Projects/a/b.md"]) }
        await ask(r, "q")
        let t = r.abus.tail("@dev").last?.text ?? ""
        #expect(!t.contains("sk-abcdefgh") && t.contains("‹masked›"))
        #expect(t.count <= 4096 && t.hasSuffix("…(cut)"))
        #expect(Oracle.compose(BrainAnswer(answer: "a", sources: ["/Users/x/Projects/p/f.md"]), owner: "O", room: "#o") == "a\nSources: p/f.md")
    }

    @Test func overLongQuestionIsRefused() async {
        let r = rig(); defer { close(r) }
        await ask(r, String(repeating: "q", count: 2100))
        #expect(r.brain.asked.isEmpty)
        #expect(r.a.sink.lines("dev").first?.contains("Ask one question at a time (2 KB).") == true)
    }

    @Test func askingOffNacks() async {
        let r = rig(); defer { close(r) }
        r.knobs.on = false
        await ask(r, "q")
        #expect(r.brain.asked.isEmpty)
        #expect(r.a.sink.lines("dev").first?.contains("asking is off") == true)
    }

    @Test func sevenQuestionsInAMinuteQueueInOrderNeverDropped() async {
        let r = rig(); defer { close(r) }
        r.brain.reply = { q in BrainAnswer(answer: "re " + q, sources: ["s.md"]) }
        for i in 1...7 {
            _ = r.a.engine.postChat(channel: "@oracle@bea", agent: "dev", text: "q\(i)")
            r.a.engine.flushChat(); settle(r.a, r.b)
        }
        await r.oracle.waitIdle()
        r.b.engine.flushChat(); settle(r.a, r.b)
        #expect(r.brain.questions == (1...7).map { "q\($0)" })
        #expect(r.knobs.slept.count == 1 && r.knobs.slept[0] > 59)       // only the 7th waited
        #expect(r.a.sink.lines("dev").count == 7)
        #expect(r.a.sink.lines("dev").last?.contains("re q7") == true)
    }

    @Test func localAskIsUnrestrictedAndTypedIntoTheAskersPane() async {
        let r = rig(); defer { close(r) }
        r.knobs.projects = []
        r.bbus.post(channel: "@oracle", agent: "pm", text: "what is Run 33?")
        await r.oracle.waitIdle()
        #expect(r.brain.asked == [[]])
        #expect(r.b.sink.lines("pm").first?.hasPrefix("[@pm oracle@bo]") == true)
    }

    @Test func coldBrainGetsOneWakingLineThenTheAnswer() async {
        let r = rig(); defer { close(r) }
        r.brain.coldCalls = 5                                      // ≈ 10 s of polling at 2 s
        await ask(r, "what does director.plan() do?")
        let lines = r.a.sink.lines("dev")
        #expect(lines.count == 2)
        #expect(lines[0].contains("Waking the brain on Bo's Mac"))
        #expect(lines[1].contains("director.plan() builds the plan."))
        #expect(r.brain.wakeCalls == 1)
        #expect(r.knobs.slept.allSatisfy { $0 == 2 })
    }

    @Test func otherQuestionsAreAnsweredWhileOneWakes() async {
        let r = rig(); defer { close(r) }
        r.brain.coldCalls = 3
        await ask(r, "first, cold")
        r.brain.coldCalls = 0                                      // the brain is up now; a second question needs no wake
        await ask(r, "second", agent: "dev")
        let lines = r.a.sink.lines("dev")
        #expect(lines.filter { $0.contains("Waking") }.count == 1)
        #expect(lines.filter { $0.contains("director.plan() builds the plan.") }.count == 2)
    }

    @Test func stillColdAfter45SecondsSaysSo() async {
        let r = rig(); defer { close(r) }
        r.brain.coldCalls = 1000
        await ask(r, "will it wake?")
        let lines = r.a.sink.lines("dev")
        #expect(lines.last?.contains("still waking up") == true, "\(lines)"); #expect(lines.count == 2, "\(lines)")
        #expect(r.knobs.slept.reduce(0, +) == 46)                  // 2 s polls until the 45 s limit is passed
        #expect(r.brain.asked.isEmpty)
    }

    @Test func theQAPairIsRecordedInThePeerRoom() async {
        let r = rig(); defer { close(r) }
        let id = await ask(r, "where is it specified?")
        let room = r.bbus.tail("#al")
        #expect(room.map(\.text).first == "Q (dev): where is it specified?")
        #expect(room.last?.text.hasPrefix("A: director.plan()") == true && room.last?.re == id)
        #expect(room.count == 2)
    }
}

@Suite(.serialized) struct OracleSettingsTests {
    @Test func slugsAreTrimmedLowercasedAndDeduped() {
        #expect(PeerSettings.parseSlugs(" Finance-Director-OS , prism,,PRISM ") == ["finance-director-os", "prism"])
        #expect(PeerSettings.parseSlugs("  ").isEmpty)
    }

    @Test func answerLineQuotesItsQuestionAcrossChannels() async {
        let r = OracleTests().rig(); defer { r.a.close(); r.b.close() }
        let id = await OracleTests().ask(r, String(repeating: "w", count: 80))
        // either side finds the question text (owner: @oracle / #al copies, asker: #bea) and previews it
        #expect(r.bbus.question(for: id)?.contains("www") == true)
        #expect((r.bbus.question(for: id)?.count ?? 0) <= 61)             // 60 chars + "…"
        #expect(r.abus.question(for: id)?.contains("www") == true)
        #expect(r.abus.question(for: "nope") == nil)
    }
}
