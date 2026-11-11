import Foundation

/// A model pick: which provider and (optionally) which model. Provider is what routing decides on.
struct ModelChoice: Codable, Hashable, Sendable {
    var provider: SeatProvider
    var model: String?
}

struct ProjectRouting: Codable, Equatable, Sendable {
    var defaultModel: ModelChoice?
    var fallbackModel: ModelChoice?
}

/// `~/.true/routing.json`: per-project default and fallback model, plus providers switched off. Choices only,
/// never a credential. Keyed by the project's repo path.
struct RoutingFile: Codable, Equatable, Sendable {
    var version = 1
    var projects: [String: ProjectRouting] = [:]
    var disabledProviders: [SeatProvider] = []

    init(projects: [String: ProjectRouting] = [:], disabledProviders: [SeatProvider] = []) {
        self.projects = projects; self.disabledProviders = disabledProviders
    }
    /// Tolerant like agents.json: a missing or odd field falls back to nothing set.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try? c.decodeIfPresent([String: ProjectRouting].self, forKey: .projects)) ?? [:]
        disabledProviders = (try? c.decodeIfPresent([SeatProvider].self, forKey: .disabledProviders)) ?? []
    }
}

struct RoutingStore: Sendable {
    let url: URL
    init(url: URL = AgentPaths.standard.root.appendingPathComponent("routing.json")) { self.url = url }

    func load() -> RoutingFile {
        guard let data = try? Data(contentsOf: url) else { return RoutingFile() }
        return (try? JSONDecoder().decode(RoutingFile.self, from: data)) ?? RoutingFile()
    }
    func save(_ file: RoutingFile) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(file).write(to: url, options: .atomic)
        } catch { NSLog("True: routing save failed: \(error)") }
    }
}

/// Everything the fallback rule needs to know about one provider. Plain values, so the rule stays pure.
struct ProviderFacts: Equatable, Sendable {
    var installed: Bool
    var enabled: Bool = true
    var signIn: SeatSignIn
    var windows: [UsageWindow]
}

enum FallbackBlock: String, Equatable, Sendable {
    case notFreshWake, explicitModel, noFallback, sameProvider, chosenNotExhausted
    case fallbackNotInstalled, fallbackDisabled, fallbackNotSignedIn, fallbackWindowsNotFresh, fallbackAtLimit
}

struct FallbackCard: Equatable, Sendable {
    let chosen: SeatProvider
    let fallback: ModelChoice
    /// When the chosen provider's exhausted window(s) reset.
    let resetsAt: Date
    /// "Using Codex · Claude resets 14:20"
    let text: String
    /// "Use Claude"
    let buttonText: String
}

enum FallbackDecision: Equatable, Sendable {
    case keep(FallbackBlock)
    case useFallback(FallbackCard)
}

/// A window that really is at its limit right now: read within the last 30 minutes, 100 %, reset still ahead.
enum UsageLimitRule {
    static func exhausted(_ windows: [UsageWindow], now: Date) -> [UsageWindow] {
        windows.map { $0.classified(now: now) }.filter {
            $0.state == .fresh && ($0.usedPercent ?? 0) >= 100 && ($0.resetsAt.map { $0 > now } ?? false)
        }
    }
    /// The structured source for a seat's "Limited · resets 14:20": the usage windows (never error prose).
    /// The limit lifts when the last exhausted window resets.
    static func limitedUntil(_ windows: [UsageWindow], now: Date) -> Date? {
        exhausted(windows, now: now).compactMap(\.resetsAt).max()
    }
}

/// T3's one automatic fallback (`t3-usage-routing-notes.md` Q7), pure over structured fields: no clock reads,
/// no files, no keyword matching, no model call. Ask it only when a seat is woken fresh; a running turn never
/// goes through here, so it never switches.
enum FallbackOnWake {
    /// Conditions, in the order they are checked. Every one must hold or the seat wakes as it would have.
    ///  1. `isFreshWake`: the seat is being woken, not already running.
    ///  2. No explicit model was picked for this wake.
    ///  3. A fallback model is set (and names a different provider).
    ///  4. The chosen provider has a window that is fresh, at 100 %, with its reset in the future.
    ///  5. The fallback provider is installed.
    ///  6. ...and enabled.
    ///  7. ...and signed in (Unknown is not signed in).
    ///  8. ...and its windows are fresh (read within 30 min; a never-read window is ignored but at least one must
    ///     be read) and every one is under 100 %.
    static func decide(chosen: SeatProvider, chosenFacts: ProviderFacts, fallback: ModelChoice?, fallbackFacts: ProviderFacts,
                       explicitModel: Bool, isFreshWake: Bool, now: Date) -> FallbackDecision {
        guard isFreshWake else { return .keep(.notFreshWake) }
        guard !explicitModel else { return .keep(.explicitModel) }
        guard let fallback else { return .keep(.noFallback) }
        guard fallback.provider != chosen else { return .keep(.sameProvider) }
        let limited = UsageLimitRule.exhausted(chosenFacts.windows, now: now)
        guard let reset = limited.compactMap(\.resetsAt).max() else { return .keep(.chosenNotExhausted) }
        guard fallbackFacts.installed else { return .keep(.fallbackNotInstalled) }
        guard fallbackFacts.enabled else { return .keep(.fallbackDisabled) }
        guard fallbackFacts.signIn.isSignedIn else { return .keep(.fallbackNotSignedIn) }
        let read = fallbackFacts.windows.map { $0.classified(now: now) }.filter { $0.state != .none }
        guard !read.isEmpty, read.allSatisfy({ $0.state == .fresh }) else { return .keep(.fallbackWindowsNotFresh) }
        guard read.allSatisfy({ ($0.usedPercent ?? 100) < 100 }) else { return .keep(.fallbackAtLimit) }
        let words = UsageText.line(limited.first { $0.resetsAt == reset } ?? limited[0])
        return .useFallback(FallbackCard(chosen: chosen, fallback: fallback, resetsAt: reset,
                                         text: "Using \(fallback.provider.label) · \(chosen.label) \(words)",
                                         buttonText: "Use \(chosen.label)"))
    }
}

/// Test switch for the live fallback check. OFF by default. To force Claude's usage windows to read 100 %
/// (fresh, reset in the future) without spending real allowance, launch True with env
/// `TRUE_FORCE_CLAUDE_USAGE_100=1`, or `defaults write <bundle id> TrueForceClaudeUsage100 -bool YES`.
/// It changes only what the routing and limited-state code read; it writes nothing and never touches the Usage stores.
enum UsageTestSwitch {
    static let envName = "TRUE_FORCE_CLAUDE_USAGE_100"
    static let defaultsKey = "TrueForceClaudeUsage100"

    static func isOn(env: [String: String] = ProcessInfo.processInfo.environment,
                     defaults: UserDefaults = .standard) -> Bool {
        env[envName] == "1" || defaults.bool(forKey: defaultsKey)
    }

    static func apply(_ windows: [UsageWindow], on: Bool, now: Date) -> [UsageWindow] {
        guard on else { return windows }
        var out = windows.filter { $0.provider != .claude }
        for kind in [UsageKind.fiveHour, .weekly] {
            let old = windows.first { $0.provider == .claude && $0.kind == kind }
            let reset = old?.resetsAt.flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(kind == .fiveHour ? 3_600 : 86_400)
            out.append(UsageWindow(provider: .claude, kind: kind, usedPercent: 100, resetsAt: reset,
                                   windowMins: kind == .fiveHour ? 300 : 10_080, readAt: now, state: .fresh))
        }
        return out
    }
}
