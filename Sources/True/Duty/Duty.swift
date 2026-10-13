import Foundation

/// The four permission levels (SPEC Run 15 §4), strictest last.
enum PermissionLevel: String, Codable, CaseIterable, Sendable {
    case act, actIfPreapproved, askFirst, handOff
    var strictness: Int { Self.allCases.firstIndex(of: self) ?? 3 }
    /// Final level = the strictest any rule gives.
    static func strictest(_ a: PermissionLevel, _ b: PermissionLevel) -> PermissionLevel { a.strictness >= b.strictness ? a : b }
    var label: String {
        switch self {
        case .act: "Do it"
        case .actIfPreapproved: "Do it if pre-approved"
        case .askFirst: "Ask first"
        case .handOff: "You do this"
        }
    }
}

enum DutyTrigger: String, Codable, CaseIterable, Sendable {
    case builders, git, abandonedFailures, digest
    case schedule, channel      // reserved
}

struct Preapproval: Codable, Equatable, Sendable {
    var actionKind: String
    var repo: String
    var at: Double
}

struct DutyBudget: Codable, Equatable, Sendable {
    var dailyUSD = 2.0
    var perRunUSD = 0.40
    var runsPerDay = 8
    var jevCallsPerDay = 300
    var fixUSD = 1.0
    /// Absolute ceiling for a fix builder across checkpoints (`builder start --max-total`).
    var fixMaxUSD = 10.0
    var softContext = 60_000
    var hardContext = 90_000
    var maxTurns = 30
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = DutyBudget()
        dailyUSD = (try? c.decodeIfPresent(Double.self, forKey: .dailyUSD)) ?? z.dailyUSD
        perRunUSD = (try? c.decodeIfPresent(Double.self, forKey: .perRunUSD)) ?? z.perRunUSD
        runsPerDay = (try? c.decodeIfPresent(Int.self, forKey: .runsPerDay)) ?? z.runsPerDay
        jevCallsPerDay = (try? c.decodeIfPresent(Int.self, forKey: .jevCallsPerDay)) ?? z.jevCallsPerDay
        fixUSD = (try? c.decodeIfPresent(Double.self, forKey: .fixUSD)) ?? z.fixUSD
        fixMaxUSD = (try? c.decodeIfPresent(Double.self, forKey: .fixMaxUSD)) ?? z.fixMaxUSD
        softContext = (try? c.decodeIfPresent(Int.self, forKey: .softContext)) ?? z.softContext
        hardContext = (try? c.decodeIfPresent(Int.self, forKey: .hardContext)) ?? z.hardContext
        maxTurns = (try? c.decodeIfPresent(Int.self, forKey: .maxTurns)) ?? z.maxTurns
    }
}

struct DutyDigest: Codable, Equatable, Sendable {
    var everyHours = 20
    var notBefore = 8
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        everyHours = (try? c.decodeIfPresent(Int.self, forKey: .everyHours)) ?? 20
        notBefore = (try? c.decodeIfPresent(Int.self, forKey: .notBefore)) ?? 8
    }
}

/// What makes an agent *on duty*: a job, triggers that wake it, permission rules and a hard budget.
/// Tolerant decode: an old or hand-edited agents.json never loses the agent over a bad duty field.
struct Duty: Codable, Equatable, Sendable {
    var job: String
    var triggers: [DutyTrigger]
    /// nil = active repos.
    var scope: [String]?
    var ceiling: PermissionLevel
    var preapproved: [Preapproval]
    var budget: DutyBudget
    var digest: DutyDigest

    init(job: String, triggers: [DutyTrigger], scope: [String]? = nil, ceiling: PermissionLevel = .askFirst,
         preapproved: [Preapproval] = [], budget: DutyBudget = DutyBudget(), digest: DutyDigest = DutyDigest()) {
        self.job = job; self.triggers = triggers; self.scope = scope; self.ceiling = ceiling
        self.preapproved = preapproved; self.budget = budget; self.digest = digest
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        job = (try? c.decodeIfPresent(String.self, forKey: .job)) ?? ""
        let raw = (try? c.decodeIfPresent([String].self, forKey: .triggers)) ?? []
        triggers = raw.compactMap(DutyTrigger.init(rawValue:))
        scope = try? c.decodeIfPresent([String].self, forKey: .scope)
        ceiling = (try? c.decodeIfPresent(PermissionLevel.self, forKey: .ceiling)) ?? .askFirst
        preapproved = (try? c.decodeIfPresent([Preapproval].self, forKey: .preapproved)) ?? []
        budget = (try? c.decodeIfPresent(DutyBudget.self, forKey: .budget)) ?? DutyBudget()
        digest = (try? c.decodeIfPresent(DutyDigest.self, forKey: .digest)) ?? DutyDigest()
    }

    static let watcherName = "watcher"
    static let watcherJob = "Watch your projects read-only, look into what broke, and propose a fix for me to approve."

    /// The Watcher's agent: no repo, never woken in a pane.
    static func watcherAgent() -> Agent {
        Agent(name: watcherName, role: .watcher, repo: "", model: .sonnet, effort: .medium, permission: .plan,
              duty: Duty(job: watcherJob, triggers: [.builders, .git, .abandonedFailures, .digest]))
    }
}
