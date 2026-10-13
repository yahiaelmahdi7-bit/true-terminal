import Testing
import Foundation
@testable import True

private func choice(_ c: String, _ conf: Double) -> JevAnswer {
    JevAnswer(type: "choice", choice: c, confidence: conf, probabilities: [c: conf], noul: nil, score: nil)
}
private func noul(_ v: Double) -> JevAnswer { JevAnswer(type: "noul", choice: nil, confidence: nil, probabilities: nil, noul: v, score: nil) }

private func reply(_ outcome: String, _ conf: Double = 0.9, proof: Double = 0.5, contradiction: Double = 0.1,
                   nextSafe: Double = 0.5) -> JevReply {
    JevReply(answers: ["outcome": choice(outcome, conf), "proof": noul(proof),
                       "contradiction": noul(contradiction), "next_safe": noul(nextSafe)])
}
private let step = TurnStep(n: 1, tool: "Bash", what: "swift test", result: "ok", failed: false)
private let failedStep = TurnStep(n: 2, tool: "Bash", what: "swift build", result: "error", failed: true)
private func digest(steps: [TurnStep] = [step], edited: Bool = true) -> TurnDigest {
    TurnDigest(asked: "do it", steps: steps, edited: edited, answer: "done")
}

@MainActor @Suite struct OverseerJudgeTests {
    @Test func questionShape() throws {
        let q = OverseerJudge.questions()
        #expect(Set(q.keys) == ["outcome", "proof", "contradiction", "next_safe"])
        let body = try #require(JevClient.body(state: digest().state, questions: q))
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let state = try #require(obj["state"] as? [String: Any])
        #expect(Set(state.keys) == ["asked", "steps", "edited", "answer"])
        let qs = try #require(obj["questions"] as? [String: [String: Any]])
        #expect(qs["outcome"]?["type"] as? String == "choice")
        let crit = try #require(qs["outcome"]?["criteria"] as? [String: String])
        #expect(Set(crit.keys) == ["finished", "partial", "asks_to_continue", "asks_you", "blocked", "answered", "none"])
        for k in ["proof", "contradiction", "next_safe"] { #expect(qs[k]?["type"] as? String == "noul") }
        #expect(OverseerJudge.Policy.timeout == 8)
    }

    private func verdict(_ r: JevReply?, _ d: TurnDigest = digest()) -> VerdictKind? {
        OverseerJudge.judge(reply: r, digest: d).verdict
    }

    @Test func nonFinishedOutcomesMapDirectly() {
        #expect(verdict(reply("partial")) == .partial)
        #expect(verdict(reply("asks_to_continue")) == .asksToContinue)
        #expect(verdict(reply("asks_you")) == .asksYou)
        #expect(verdict(reply("blocked")) == .blocked)
        #expect(verdict(reply("answered")) == nil)
        #expect(verdict(reply("none")) == nil)
        #expect(verdict(reply("bogus")) == nil)
        #expect(verdict(nil) == nil)
    }

    @Test func outcomeFloorIsHalf() {
        #expect(verdict(reply("blocked", 0.49)) == nil)
        #expect(verdict(reply("blocked", 0.5)) == .blocked)
        #expect(verdict(reply("finished", 0.49, proof: 0.9)) == nil)
    }

    @Test func finishedProofEdges() {
        #expect(verdict(reply("finished", proof: 0.7)) == .verified)
        #expect(verdict(reply("finished", proof: 0.69)) == nil)
        #expect(verdict(reply("finished", proof: 0.36)) == nil)
        #expect(verdict(reply("finished", proof: 0.35)) == .unverified)
        #expect(verdict(reply("finished", proof: 0.0)) == .unverified)
    }

    @Test func contradictionOverridesProof() {
        let j = OverseerJudge.judge(reply: reply("finished", proof: 0.95, contradiction: 0.7),
                                    digest: digest(steps: [step, failedStep]))
        #expect(j.verdict == .unverified)
        #expect(j.reason == "A step failed that the answer doesn't mention: swift build")
        #expect(verdict(reply("finished", proof: 0.95, contradiction: 0.69)) == .verified)
    }

    @Test func noStepsAndNoEditMeansNoVerdict() {
        #expect(verdict(reply("finished", proof: 0.9), digest(steps: [], edited: false)) == nil)
        #expect(verdict(reply("finished", proof: 0.1), digest(steps: [], edited: false)) == nil)
        #expect(verdict(reply("finished", proof: 0.9), digest(steps: [], edited: true)) == .verified)
    }

    @Test func reasonsAreCodeComposed() {
        #expect(OverseerJudge.judge(reply: reply("finished", proof: 0.1), digest: digest()).reason == "Says done; no check ran")
        #expect(OverseerJudge.judge(reply: reply("partial"), digest: digest()).reason == "Stopped with work left")
        #expect(OverseerJudge.judge(reply: reply("blocked"), digest: digest()).reason == "Hit an error")
        #expect(OverseerJudge.judge(reply: reply("asks_you"), digest: digest()).reason == "Waiting on your answer")
        #expect(OverseerJudge.judge(reply: reply("asks_to_continue"), digest: digest()).reason == "Wants to carry on")
    }

    @Test func shadowAnswerIsKeptNotActedOn() {
        let j = OverseerJudge.judge(reply: reply("asks_to_continue", nextSafe: 0.93), digest: digest())
        #expect(j.nextSafe == 0.93 && j.verdict == .asksToContinue)
    }

    @Test func urgencyOrderThenNewestFirst() {
        #expect(VerdictKind.allCases.sorted { $0.urgency < $1.urgency }
                == [.blocked, .asksYou, .unverified, .asksToContinue, .partial, .verified])
        let t = Date(timeIntervalSince1970: 1_000)
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let v: [UUID: OverseerVerdict] = [
            a: OverseerVerdict(kind: .partial, reason: "", at: t, sessionID: nil, cwd: nil),
            b: OverseerVerdict(kind: .blocked, reason: "", at: t, sessionID: nil, cwd: nil),
            c: OverseerVerdict(kind: .partial, reason: "", at: t.addingTimeInterval(50), sessionID: nil, cwd: nil),
            d: OverseerVerdict(kind: .asksYou, reason: "", at: t, sessionID: nil, cwd: nil),
        ]
        #expect(OverseerStore.ordered(v).map(\.pane) == [b, d, c, a])
    }
}
