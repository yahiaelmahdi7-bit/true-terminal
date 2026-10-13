import Foundation

/// What the Overseer concluded about a finished turn. One name each; `label` is the UI wording.
enum VerdictKind: String, CaseIterable, Sendable {
    case verified, unverified, partial, asksToContinue, asksYou, blocked

    var label: String {
        switch self {
        case .verified: "Verified"
        case .unverified: "Unverified"
        case .partial: "Partial"
        case .asksToContinue: "Asks to continue"
        case .asksYou: "Asks you"
        case .blocked: "Blocked"
        }
    }

    /// Lower = look at it sooner. Ties break newest first (in `OverseerStore.ordered`).
    var urgency: Int {
        switch self {
        case .blocked: 0
        case .asksYou: 1
        case .unverified: 2
        case .asksToContinue: 3
        case .partial: 4
        case .verified: 5
        }
    }
}

struct OverseerVerdict: Equatable, Sendable {
    var kind: VerdictKind
    /// Code-composed, never Jev text.
    var reason: String
    var at: Date
    var sessionID: String?
    var cwd: String?
    /// Already-redacted digest text (asked + answer) for the Watcher's abandoned-failure source.
    var evidence: String? = nil
}

/// Jev's answers to the four questions, plus what the mapping made of them.
struct OverseerJudgment: Equatable, Sendable {
    var outcome: String?
    var outcomeConfidence: Double?
    var outcomeProbabilities: [String: Double]?
    var proof: Double?
    var contradiction: Double?
    /// Shadow: logged for Run 13 (Autopilot), never acted on here.
    var nextSafe: Double?
    var verdict: VerdictKind?
    var reason: String?
}

/// Pure: the questions and the mapping from answers to a verdict. Code owns the flow and every number;
/// Jev only answers the narrow typed questions.
enum OverseerJudge {
    /// All thresholds, in one place.
    enum Policy {
        /// Below this the outcome pick is not trusted: no verdict.
        static let outcomeFloor = 0.5
        /// `finished` + a failure the answer doesn't mention at or above this → unverified.
        static let contradictionAt = 0.7
        /// `finished` + proof at or above this → verified; at or below `noProofAt` → unverified; between → silence.
        static let proofAt = 0.7
        static let noProofAt = 0.35
        static let timeout: TimeInterval = 8
    }

    static func questions() -> [String: JevQuestion] {
        [
            "outcome": .choice("How did the turn end? `asked` is what the user asked for; `answer` is what Claude said last.", [
                (id: "finished", what: "`answer` says the work asked for in `asked` is complete"),
                (id: "partial", what: "some of the asked work is done and `answer` names work still left, or it stopped midway"),
                (id: "asks_to_continue", what: "`answer` ends by offering or asking to carry on with the next step of the same task"),
                (id: "asks_you", what: "`answer` needs something only the user can give: a choice between options, missing information, credentials, or approval for something outside the task"),
                (id: "blocked", what: "`answer` reports an error or obstacle it could not get past"),
                (id: "answered", what: "`asked` was a question or conversation, not work, and `answer` replies to it"),
                (id: "none", what: "none of these fit"),
            ]),
            "proof": .noul("Does `steps` show a check that ran successfully after the work it checks — tests or a build that passed, a command whose output confirms the result, an HTTP or live check — supporting what `answer` says was done?"),
            "contradiction": .noul("Does any `result` in `steps` show a failure — a failing test, an error, a non-zero exit — that `answer` does not mention?"),
            "next_safe": .noul("Would the next step that `answer` proposes stay inside the task in `asked` and be easy to undo, touching only local files and local commands?"),
        ]
    }

    /// The one Jev call. nil = no reply (no key, slow, down).
    static func ask(_ digest: TurnDigest, jev: JevClient) async -> JevReply? {
        await jev.ask(state: digest.state, questions: questions(), timeout: Policy.timeout)
    }

    /// Answers → judgment. `digest` supplies the code facts (steps, edited) the mapping needs.
    static func judge(reply: JevReply?, digest: TurnDigest) -> OverseerJudgment {
        var j = OverseerJudgment()
        guard let reply else { return j }
        let o = reply.answers["outcome"]
        j.outcome = o?.choice
        j.outcomeConfidence = o?.confidence
        j.outcomeProbabilities = o?.probabilities
        j.proof = reply.answers["proof"]?.noul
        j.contradiction = reply.answers["contradiction"]?.noul
        j.nextSafe = reply.answers["next_safe"]?.noul
        if let (kind, reason) = map(j, digest: digest) { j.verdict = kind; j.reason = reason }
        return j
    }

    static func map(_ j: OverseerJudgment, digest: TurnDigest) -> (VerdictKind, String)? {
        guard let outcome = j.outcome, (j.outcomeConfidence ?? 0) >= Policy.outcomeFloor else { return nil }
        switch outcome {
        case "finished":
            if (j.contradiction ?? 0) >= Policy.contradictionAt {
                let failed = digest.steps.last(where: \.failed)
                let what = failed.map { $0.what.isEmpty ? $0.tool : $0.what } ?? "a step"
                return (.unverified, "A step failed that the answer doesn't mention: \(what)")
            }
            if digest.steps.isEmpty && !digest.edited { return nil }
            guard let proof = j.proof else { return nil }
            if proof >= Policy.proofAt { return (.verified, "A check ran after the work") }
            if proof <= Policy.noProofAt { return (.unverified, "Says done; no check ran") }
            return nil
        case "partial": return (.partial, "Stopped with work left")
        case "asks_to_continue": return (.asksToContinue, "Wants to carry on")
        case "asks_you": return (.asksYou, "Waiting on your answer")
        case "blocked": return (.blocked, "Hit an error")
        default: return nil
        }
    }
}
