import Foundation

/// AI fill, fast half: Jev picks the four dials (role, model, effort, permission) in about a second while
/// Claude writes the charter. Jev only supplies judgments; a pick below `floor` confidence is ignored.
enum JevFill {
    static let floor = 0.6
    static let timeout: TimeInterval = 3

    struct Picks: Equatable, Sendable {
        var role: AgentRole?
        var model: AgentModel?
        var effort: AgentEffort?
        var permission: AgentPermission?
    }

    /// The model and effort questions, shared with the Command bar (one source). `subject` is the state field the
    /// instructions point at: `request` for AI fill, `text` for the bar.
    static func modelQuestion(subject: String = "request") -> JevQuestion {
        .choice("Which model fits the weight of `\(subject)`?", [
            (id: "haiku", what: "search, inventories and read-only sweeps"),
            (id: "sonnet", what: "routine implementation, tests, mechanical edits"),
            (id: "opus", what: "architecture, coordination and hard debugging"),
            (id: "fable", what: "the highest-stakes judgment calls"),
        ])
    }

    static func effortQuestion(subject: String = "request") -> JevQuestion {
        .score("How much reasoning effort does `\(subject)` need?", levels: [
            "low: a lookup or listing",
            "medium: routine code changes",
            "high: tricky debugging or multi-part coordination",
            "xhigh: architecture across many parts",
            "max: a decision where a mistake is very expensive",
        ])
    }

    /// A score answer (0-4) → the effort level it sits on.
    static func effort(fromScore s: Double) -> AgentEffort {
        AgentEffort.allCases[min(max(Int(s.rounded()), 0), AgentEffort.allCases.count - 1)]
    }

    static func questions(editing: Bool) -> [String: JevQuestion] {
        var q: [String: JevQuestion] = [
            "model": modelQuestion(),
            "effort": effortQuestion(),
            "permission": .choice("How much autonomy does `request` imply?", [
                (id: "default", what: "acts but asks before each change"),
                (id: "acceptEdits", what: "edits files freely inside its task"),
                (id: "plan", what: "read-only: investigates or plans, changes nothing"),
                (id: "auto", what: "fully autonomous, runs unattended"),
            ]),
        ]
        if !editing {
            q["role"] = .choice("What role does `request` describe?", [
                (id: "lead", what: "coordinates helpers inside one repo"),
                (id: "helper", what: "does focused hands-on work"),
                (id: "global", what: "works across many repos and hands work to repo leads"),
            ])
        }
        return q
    }

    static func picks(from reply: JevReply?, editing: Bool) -> Picks {
        guard let reply else { return Picks() }
        func sure(_ id: String) -> JevAnswer? {
            guard let a = reply.answers[id], (a.confidence ?? 0) >= floor else { return nil }
            return a
        }
        var p = Picks()
        p.model = sure("model")?.choice.flatMap(AgentModel.init(rawValue:))
        p.permission = sure("permission")?.choice.flatMap(AgentPermission.init(rawValue:))
        if !editing { p.role = sure("role")?.choice.flatMap(AgentRole.init(rawValue:)) }
        if let s = sure("effort")?.score {
            p.effort = effort(fromScore: s)
        }
        return p
    }

    static func ask(request: String, editing: Bool, jev: JevClient) async -> Picks {
        let reply = await jev.ask(state: ["request": request], questions: questions(editing: editing), timeout: timeout)
        return picks(from: reply, editing: editing)
    }

    /// Jev's confident picks go straight onto the draft.
    static func apply(_ p: Picks, to draft: inout BuilderDraft) {
        if draft.editing == nil, let r = p.role { draft.role = r }
        if let m = p.model { draft.model = m }
        if let e = p.effort { draft.effort = e }
        if let x = p.permission { draft.permission = x }
    }

    /// When Claude returns: the charter and symbol are always Claude's; every other field only if Jev did not
    /// pick it and it still equals what it was when Fill started, so Jev's picks and anything the user touched
    /// win. `jev` matters when Jev's pick happens to equal the prefill value: the draft looks untouched then.
    static func merge(_ p: AgentFill.Profile, into draft: inout BuilderDraft, prefill: BuilderDraft,
                      jev: Picks = Picks()) {
        if draft.editing == nil, jev.role == nil, draft.role == prefill.role,
           let r = AgentRole(rawValue: p.role) { draft.role = r }
        if jev.model == nil, draft.model == prefill.model, let m = AgentModel(rawValue: p.model) { draft.model = m }
        if jev.effort == nil, draft.effort == prefill.effort, let e = AgentEffort(rawValue: p.effort) { draft.effort = e }
        if jev.permission == nil, draft.permission == prefill.permission,
           let x = AgentPermission(rawValue: p.permission) { draft.permission = x }
        if BuilderDraft.symbols.contains(p.symbol) { draft.symbol = p.symbol }
        draft.charter = p.charter
    }

    /// Runs Jev and Claude in parallel. Jev's picks land the moment they arrive; Claude's result is merged
    /// after. Claude failing keeps Jev's picks and rethrows for the sheet's error line.
    @MainActor
    static func orchestrate(prefill: BuilderDraft,
                            jev: @escaping @Sendable () async -> Picks,
                            claude: @Sendable () async throws -> AgentFill.Profile,
                            edit: @escaping @MainActor (@MainActor (inout BuilderDraft) -> Void) -> Void) async throws {
        let jevTask = Task { @MainActor () -> Picks in
            let p = await jev()
            guard !Task.isCancelled else { return Picks() }
            edit { apply(p, to: &$0) }
            return p
        }
        do {
            let profile = try await claude()
            let picks = await jevTask.value
            if !Task.isCancelled { edit { merge(profile, into: &$0, prefill: prefill, jev: picks) } }
        } catch is CancellationError {
            jevTask.cancel()
            throw CancellationError()
        } catch {
            _ = await jevTask.value
            throw error
        }
    }
}
