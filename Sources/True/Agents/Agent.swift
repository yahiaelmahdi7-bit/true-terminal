import Foundation

/// An **agent** is a saved Claude config. One name per thing (SPEC Run 2): an agent running in a
/// pane is *awake*, otherwise *asleep*. Every repo has at most one lead and up to four helpers,
/// named `lead-<repo>` / `helper-N-<repo>` — the same naming Axon's crew used, so a session name and
/// its role always round-trip (`AgentNaming.parse`).
enum AgentRole: String, Codable, CaseIterable, Sendable {
    case lead, helper
    /// No repo: works across repos by summoning their leads (`truectl summon`). Named by the user.
    case global
    /// An agent that is *on duty* (Run 15): never woken into a pane, summoned or a ⌘K `@` target.
    case watcher

    var defaultSymbol: String {
        switch self {
        case .lead: return "crown"
        case .helper: return "hammer"
        case .global: return "globe"
        case .watcher: return "eye"
        }
    }
}

enum AgentModel: String, Codable, CaseIterable, Sendable {
    case haiku, sonnet, opus, fable
    var label: String { rawValue.capitalized }
}

/// Reasoning effort, in the order the `--effort` flag and the 5-step meter share.
enum AgentEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high, xhigh, max
    /// 1...5 — how many steps of the meter are lit.
    var level: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    var label: String { self == .xhigh ? "X-High" : rawValue.capitalized }
}

enum AgentPermission: String, Codable, CaseIterable, Sendable {
    case `default`, acceptEdits, plan, auto
    var label: String {
        switch self {
        case .default: return "Ask"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        case .auto: return "Auto"
        }
    }
    var symbol: String {
        switch self {
        case .default: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .plan: return "list.bullet.clipboard"
        case .auto: return "bolt"
        }
    }
}

struct Agent: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var role: AgentRole
    /// Absolute path of the repo the agent works in (its tab opens here). A global's may be ""
    /// (= the user's home folder) or a folder it was given.
    var repo: String
    var model: AgentModel
    var effort: AgentEffort
    var permission: AgentPermission
    /// Extra instructions appended to the role card.
    var charter: String
    /// A lead lists the helper names it manages; a global lists the lead names it may summon.
    /// Empty for helpers.
    var team: [String]
    /// The conversation to resume on next wake. Only used when non-empty AND its transcript exists.
    var lastSessionID: String?
    var symbol: String
    /// Avatar colour (an `AgentHue` raw value). Optional so agents.json from older builds still decodes;
    /// nil or unknown = derived from the name (`resolvedHue`).
    var hue: String?
    /// On duty (Run 15): a job, triggers, budget and permission ceiling. nil = a plain seat.
    var duty: Duty?

    var id: String { name }
    var repoName: String {
        role == .global && repo.isEmpty ? "Global" : (repo as NSString).lastPathComponent
    }

    init(name: String, role: AgentRole, repo: String, model: AgentModel = .sonnet,
         effort: AgentEffort = .medium, permission: AgentPermission = .default,
         charter: String = "", team: [String] = [], lastSessionID: String? = nil, symbol: String? = nil, hue: String? = nil, duty: Duty? = nil) {
        self.name = name; self.role = role; self.repo = repo; self.model = model
        self.effort = effort; self.permission = permission; self.charter = charter
        self.team = team; self.lastSessionID = lastSessionID
        self.symbol = symbol ?? role.defaultSymbol
        self.hue = hue
        self.duty = duty
    }

    /// Tolerant on purpose: a file written by an older build (missing fields) or hand-edited
    /// (unknown enum value) still loads with sane defaults instead of discarding every agent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        role = (try? c.decode(AgentRole.self, forKey: .role)) ?? AgentNaming.parse(name)?.role ?? .helper
        repo = try c.decode(String.self, forKey: .repo)
        model = (try? c.decode(AgentModel.self, forKey: .model)) ?? .sonnet
        effort = (try? c.decode(AgentEffort.self, forKey: .effort)) ?? .medium
        permission = (try? c.decode(AgentPermission.self, forKey: .permission)) ?? .default
        charter = (try? c.decode(String.self, forKey: .charter)) ?? ""
        team = (try? c.decode([String].self, forKey: .team)) ?? []
        lastSessionID = try? c.decodeIfPresent(String.self, forKey: .lastSessionID)
        symbol = (try? c.decode(String.self, forKey: .symbol)) ?? role.defaultSymbol
        hue = try? c.decodeIfPresent(String.self, forKey: .hue)
        duty = try? c.decodeIfPresent(Duty.self, forKey: .duty)
    }
}

/// The naming contract: `sessionName` and `parse` are exact inverses.
enum AgentNaming {
    static let helperSlots = 1...4

    /// "/Users/example/Projects/Finance Desk" → "finance-desk". ASCII-only on purpose: the result goes
    /// into a peer name, a file name and a shell-quoted flag, and "café" vs "cafe" must not be two crews.
    static func repoSlug(_ repoPath: String) -> String {
        var out = ""
        var lastDash = true
        for u in ((repoPath as NSString).lastPathComponent).lowercased().unicodeScalars {
            if ("a"..."z").contains(u) || ("0"..."9").contains(u) {
                out.unicodeScalars.append(u); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "repo" : out
    }

    static func leadName(slug: String) -> String { "lead-\(slug)" }
    static func helperName(_ n: Int, slug: String) -> String { "helper-\(n)-\(slug)" }

    /// Exact inverse of the two builders above; nil for anything they could not have produced.
    static func parse(_ name: String) -> (role: AgentRole, helper: Int?, slug: String)? {
        if name.hasPrefix("lead-") {
            let slug = String(name.dropFirst(5))
            return slug.isEmpty ? nil : (.lead, nil, slug)
        }
        guard name.hasPrefix("helper-") else { return nil }
        let tail = name.dropFirst(7)
        guard let dash = tail.firstIndex(of: "-"), let n = Int(tail[..<dash]), helperSlots.contains(n),
              String(n) == tail[..<dash] else { return nil }
        let slug = String(tail[tail.index(after: dash)...])
        return slug.isEmpty ? nil : (.helper, n, slug)
    }

    /// A global's name is the user's own. Lowercase ASCII so it is safe in a file name, a shell-quoted
    /// flag and a `truectl` argument, and `parse(s) == nil` so it can never be read as a lead/helper.
    static func isValidGlobalName(_ s: String) -> Bool {
        guard (2...32).contains(s.count), let first = s.unicodeScalars.first, ("a"..."z").contains(first),
              !s.hasSuffix("-"), parse(s) == nil else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The name a new agent gets: `lead-<repo>` if the repo has no lead yet, else the next free
    /// `helper-N-<repo>`. Nil when the requested role has no free slot (one lead, four helpers),
    /// and always nil for a global (the user names it).
    static func nextName(role: AgentRole, repo: String, existing: [String]) -> String? {
        let slug = repoSlug(repo)
        switch role {
        case .lead:
            let n = leadName(slug: slug)
            return existing.contains(n) ? nil : n
        case .helper:
            return helperSlots.map { helperName($0, slug: slug) }.first { !existing.contains($0) }
        case .global, .watcher:
            return nil
        }
    }
}

/// `~/.true/agents.json`. `version` 0 = a file that predates the field; it migrates in place.
struct AgentsFile: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int = AgentsFile.currentVersion
    var agents: [Agent] = []

    init(agents: [Agent] = []) { self.agents = agents }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing `version` is a v0 file: same shape, so migration is just stamping the version.
        _ = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 0
        version = Self.currentVersion
        agents = try c.decodeIfPresent([Agent].self, forKey: .agents) ?? []
    }
}

/// Reads/writes agents.json. Never throws to the caller: a missing or corrupt file means "no
/// agents yet" (a corrupt one is kept aside as `agents.corrupt.json`, like workspace.json).
struct AgentStore: Sendable {
    let url: URL
    init(url: URL = AgentPaths.standard.root.appendingPathComponent("agents.json")) { self.url = url }

    func load() -> [Agent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let file = try? JSONDecoder().decode(AgentsFile.self, from: data) { return file.agents }
        let aside = url.deletingLastPathComponent().appendingPathComponent("agents.corrupt.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return []
    }

    func save(_ agents: [Agent]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            try enc.encode(AgentsFile(agents: agents)).write(to: url, options: .atomic)
        } catch {
            NSLog("True: agents save failed: \(error)")
        }
    }
}

/// Where True keeps agent state. Everything under `~/.true` — never `~/.axon`, never
/// `~/.claude/settings.json` (per-agent `--settings <file>` only).
struct AgentPaths: Sendable {
    let root: URL
    static let standard = AgentPaths(root: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true"))

    var hooksDir: URL { root.appendingPathComponent("hooks") }
    var rolesDir: URL { root.appendingPathComponent("roles") }
    var socketPath: String { root.appendingPathComponent("agent-events.sock").path }
    var forwarderPath: String { hooksDir.appendingPathComponent("forward-claude.py").path }
    var controlSocketPath: String { root.appendingPathComponent("control.sock").path }
    var binDir: URL { root.appendingPathComponent("bin") }
    var truectlPath: String { binDir.appendingPathComponent("truectl").path }

    /// Agent names are slugs, but the file name is sanitised anyway — a hand-edited agents.json
    /// must not be able to write outside the directory.
    private func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }
    /// The hooks layer for a plain pane that runs claude (⌘↩ in the project palette): same forwarder, no agent.
    var paneSettingsPath: String { hooksDir.appendingPathComponent("pane.settings.json").path }
    func settingsPath(_ name: String) -> String { hooksDir.appendingPathComponent("\(safe(name)).settings.json").path }
    func rolePath(_ name: String) -> String { rolesDir.appendingPathComponent("\(safe(name)).md").path }
}
