import Testing
import Foundation
@testable import True

private func reply(_ a: [String: JevAnswer]) -> JevReply { JevReply(answers: a) }
private func choice(_ c: String, _ conf: Double) -> JevAnswer {
    JevAnswer(type: "choice", choice: c, confidence: conf, probabilities: nil, noul: nil, score: nil)
}
private func score(_ s: Double, _ conf: Double) -> JevAnswer {
    JevAnswer(type: "score", choice: nil, confidence: conf, probabilities: nil, noul: nil, score: s)
}
private func profile(role: String = "helper", model: String = "haiku", effort: String = "low",
                     permission: String = "plan", symbol: String = "scope", charter: String = "CLAUDE CHARTER") -> AgentFill.Profile {
    AgentFill.Profile(role: role, model: model, effort: effort, permission: permission, symbol: symbol, charter: charter)
}

@MainActor
@Suite struct JevFillTests {
    @Test func questionsOmitRoleWhenEditing() {
        #expect(Set(JevFill.questions(editing: false).keys) == ["model", "effort", "permission", "role"])
        #expect(Set(JevFill.questions(editing: true).keys) == ["model", "effort", "permission"])
    }

    @Test func floorIsPointSix() {
        let r = reply(["model": choice("opus", 0.6), "permission": choice("plan", 0.59),
                       "effort": score(3.4, 0.6), "role": choice("global", 0.59)])
        let p = JevFill.picks(from: r, editing: false)
        #expect(p.model == .opus && p.effort == .xhigh)
        #expect(p.permission == nil && p.role == nil)
    }

    @Test func effortRoundsAndClamps() {
        #expect(JevFill.picks(from: reply(["effort": score(0.4, 0.9)]), editing: false).effort == .low)
        #expect(JevFill.picks(from: reply(["effort": score(1.5, 0.9)]), editing: false).effort == .high)
        #expect(JevFill.picks(from: reply(["effort": score(9, 0.9)]), editing: false).effort == .max)
        #expect(JevFill.picks(from: reply(["effort": score(-2, 0.9)]), editing: false).effort == .low)
    }

    @Test func roleSkippedWhenEditingAndUnknownChoicesIgnored() {
        let r = reply(["role": choice("global", 0.9), "model": choice("gpt", 0.9)])
        #expect(JevFill.picks(from: r, editing: true).role == nil)
        #expect(JevFill.picks(from: r, editing: false).role == .global)
        #expect(JevFill.picks(from: r, editing: false).model == nil)
        #expect(JevFill.picks(from: nil, editing: false) == JevFill.Picks())
    }

    @Test func applyOnDraftSkipsRoleWhenEditing() {
        var d = BuilderDraft(editing: Agent(name: "lead-app", role: .lead, repo: "/tmp/app"))
        JevFill.apply(.init(role: .global, model: .fable, effort: .max, permission: .auto), to: &d)
        #expect(d.role == .lead && d.model == .fable && d.effort == .max && d.permission == .auto)
    }

    @Test func claudeDoesNotOverwriteJevOrUserChangedFields() {
        let pre = BuilderDraft(repo: "/tmp/app")                       // sonnet / medium / default / lead
        var d = pre
        JevFill.apply(.init(role: .helper, model: .opus, effort: nil, permission: nil), to: &d)
        d.permission = .auto                                            // user touched it mid-fill
        JevFill.merge(profile(), into: &d, prefill: pre)
        #expect(d.role == .helper && d.model == .opus)                  // Jev's picks kept
        #expect(d.permission == .auto)                                  // user's kept
        #expect(d.effort == .low)                                       // untouched -> Claude's
        #expect(d.symbol == "scope" && d.charter == "CLAUDE CHARTER")   // always Claude's
    }

    @Test func jevPickEqualToPrefillStillBeatsClaude() async throws {
        let pre = BuilderDraft(repo: "/tmp/app")                       // model sonnet
        var d = pre
        try await JevFill.orchestrate(prefill: pre,
                                      jev: { .init(role: nil, model: .sonnet, effort: nil, permission: nil) },
                                      claude: { profile(model: "opus") },
                                      edit: { change in change(&d) })
        #expect(d.model == .sonnet)                                     // Jev said sonnet; Claude's opus loses
        #expect(d.effort == .low)                                       // Jev silent -> Claude's
    }

    @Test func mergeKeepsRoleWhenEditingAndAlwaysTakesCharter() {
        let pre = BuilderDraft(editing: Agent(name: "lead-app", role: .lead, repo: "/tmp/app", charter: "old"))
        var d = pre
        JevFill.merge(profile(role: "global"), into: &d, prefill: pre)
        #expect(d.role == .lead && d.charter == "CLAUDE CHARTER")
    }

    // MARK: orchestration

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock(); private var open = false
        func release() { lock.withLock { open = true } }
        func wait() async { while !lock.withLock({ open }) { try? await Task.sleep(for: .milliseconds(5)) } }
    }

    @Test func jevLandsBeforeClaudeReturns() async throws {
        let pre = BuilderDraft(repo: "/tmp/app")
        var d = pre
        var seenBeforeClaude: BuilderDraft?
        let gate = Gate()
        try await JevFill.orchestrate(
            prefill: pre,
            jev: { .init(role: nil, model: .opus, effort: .high, permission: nil) },
            claude: { await gate.wait(); return profile() },
            edit: { change in
                change(&d)
                if seenBeforeClaude == nil { seenBeforeClaude = d; gate.release() }
            })
        #expect(seenBeforeClaude?.model == .opus && seenBeforeClaude?.charter == "")   // Jev first, no charter yet
        #expect(d.model == .opus && d.effort == .high)                                  // Claude did not override
        #expect(d.permission == .plan && d.charter == "CLAUDE CHARTER")
    }

    @Test func claudeErrorKeepsJevPicksAndRethrows() async {
        let pre = BuilderDraft(repo: "/tmp/app")
        var d = pre
        await #expect(throws: AgentFill.FillError.self) {
            try await JevFill.orchestrate(
                prefill: pre,
                jev: { .init(role: nil, model: .fable, effort: nil, permission: .auto) },
                claude: { throw AgentFill.FillError(message: "boom") },
                edit: { change in change(&d) })
        }
        #expect(d.model == .fable && d.permission == .auto && d.charter == "")
    }

    @Test func noJevPicksBehavesLikeToday() async throws {
        let pre = BuilderDraft(repo: "/tmp/app")
        var d = pre
        try await JevFill.orchestrate(prefill: pre, jev: { JevFill.Picks() }, claude: { profile() },
                                      edit: { change in change(&d) })
        #expect(d.role == .helper && d.model == .haiku && d.effort == .low && d.permission == .plan)
    }
}
