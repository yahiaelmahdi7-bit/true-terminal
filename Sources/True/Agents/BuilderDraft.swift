import Foundation

/// The character builder's working copy. Pure data + rules, so the sheet stays a thin form and the
/// name / validation logic is testable without a window.
struct BuilderDraft: Identifiable, Equatable {
    let id = UUID()
    /// Set when editing: the agent keeps its name (session files, tab titles and the lead's team
    /// list all key on it), so changing repo/role on an existing agent is not offered.
    var editing: String?
    var repo: String
    var role: AgentRole
    var model: AgentModel
    var effort: AgentEffort
    var permission: AgentPermission
    var symbol: String
    var charter: String
    var team: Set<String>
    /// A global agent's user-chosen name (typed in the builder); unused for lead/helper.
    var globalName: String = ""
    /// Chosen avatar colour; nil = whatever the name derives to (shown selected in the builder).
    var hue: AgentHue?

    /// ~24 curated SF Symbols. First three are the role defaults.
    static let symbols = ["crown", "hammer", "globe", "star", "shield", "bolt", "flame", "leaf", "moon",
                          "sparkles", "wand.and.stars", "scope", "binoculars", "map", "compass.drawing",
                          "wrench.and.screwdriver", "paintbrush", "pencil.and.ruler", "atom", "cpu",
                          "ant", "hare", "tortoise", "bird", "pawprint"]

    init(repo: String = "", role: AgentRole = .lead) {
        self.repo = repo; self.role = role
        model = .sonnet; effort = .medium; permission = .default
        symbol = role.defaultSymbol; charter = ""; team = []
    }

    init(editing a: Agent) {
        editing = a.name; repo = a.repo; role = a.role; model = a.model; effort = a.effort
        permission = a.permission; symbol = a.symbol; charter = a.charter; team = Set(a.team)
        hue = a.hue.flatMap(AgentHue.init(rawValue:))
    }

    /// The auto-assigned name, or the fixed one when editing. Nil = no repo yet, or no free slot;
    /// for a global, nil until the typed name is valid and not taken.
    func name(existing: [Agent]) -> String? {
        if let editing { return editing }
        if role == .global {
            let n = globalName.trimmingCharacters(in: .whitespaces).lowercased()
            return AgentNaming.isValidGlobalName(n) && !existing.contains { $0.name == n } ? n : nil
        }
        guard !repo.isEmpty else { return nil }
        return AgentNaming.nextName(role: role, repo: repo, existing: existing.map(\.name))
    }

    func canSave(existing: [Agent]) -> Bool { name(existing: existing) != nil }

    /// Who this agent may be given: a lead manages the helpers of its repo; a global may summon
    /// every lead (leads only, never helpers); a helper has no team.
    func teamChoices(existing: [Agent]) -> [Agent] {
        switch role {
        case .lead:
            let slug = AgentNaming.repoSlug(repo)
            return existing.filter { $0.role == .helper && AgentNaming.repoSlug($0.repo) == slug }
        case .global:
            return existing.filter { $0.role == .lead }.sorted { $0.name < $1.name }
        case .helper, .watcher:
            return []
        }
    }

    func agent(existing: [Agent]) -> Agent? {
        guard let n = name(existing: existing) else { return nil }
        let valid = Set(teamChoices(existing: existing).map(\.name))
        return Agent(name: n, role: role, repo: repo, model: model, effort: effort, permission: permission,
                     charter: charter, team: role == .helper ? [] : team.filter(valid.contains).sorted(),
                     symbol: symbol, hue: hue?.rawValue)
    }
}
