import Foundation

/// Optional provider facts for T3 Wedge 3 (accounts + routing). Nothing in the app reads these yet; every
/// default changes no current behaviour. One provider layer: Wedge 3 extends these, never adds a second.
enum SeatSignIn: String, Codable, Sendable {
    case signedIn, notSignedIn, unknown
    /// Unknown is never treated as signed in.
    var isSignedIn: Bool { self == .signedIn }
    var label: String {
        switch self {
        case .signedIn: return "Signed in"
        case .notSignedIn: return "Not signed in"
        case .unknown: return "Not checked"
        }
    }
    /// Only a probe that actually confirmed a login counts. Claude's `auth status` reports `loggedIn: true`
    /// for Ready; Codex's `login status` is only read for "Not logged in", so its Ready proves nothing.
    static func from(_ state: ProgramFinder.State?, provider: SeatProvider) -> SeatSignIn {
        switch (state, provider) {
        case (.notSignedIn?, _): return .notSignedIn
        case (.ready?, .claude): return .signedIn
        default: return .unknown
        }
    }
}

struct SeatRuntimeInfo: Equatable, Sendable {
    var installed: Bool
    var version: String?
    var signIn: SeatSignIn = .unknown
    /// Set only from a structured source (T3's UsageWindows reset time). Never parsed from error text.
    var limitedUntil: Date?
    /// Plan label and email from the sign-in reader. In memory only; the email is shown hidden until clicked.
    var plan: String?
    var email: String?
    var limitLabel: String? {
        limitedUntil.map { "Limited until " + UsageText.clock($0) }
    }

    /// The live limit for a seat's card, from the usage windows. Those are read for each provider's default account
    /// only, so a seat on another account gets nil: never a limit that belongs to a different login.
    static func liveLimit(provider: SeatProvider, account: String?, windows: [UsageWindow], now: Date) -> Date? {
        guard account == nil else { return nil }
        let p: UsageProvider = provider == .codex ? .codex : .claude
        return UsageLimitRule.limitedUntil(windows.filter { $0.provider == p }, now: now)
    }
}

extension SeatProviding {
    /// Environment variable that points the provider at a per-seat config directory.
    var configDirEnvName: String { kind == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR" }

    /// The launch line with an optional per-seat config dir. nil returns today's line byte for byte.
    func shellCommand(argv: [String], seatConfigDir: URL?) -> String {
        let base = shellCommand(argv: argv)
        guard let dir = seatConfigDir else { return base }
        return "export \(configDirEnvName)=\(AgentLaunch.shellQuote(dir.path)); " + base
    }

    /// File lookups and cached state only: no process is started, so it is safe on the main thread.
    /// `version` comes from an earlier `probeRuntime`.
    func runtimeSnapshot(finder: ProgramFinder = .shared, version: String? = nil, limitedUntil: Date? = nil) -> SeatRuntimeInfo {
        let name = kind.rawValue
        return SeatRuntimeInfo(installed: finder.resolve(name) != nil, version: version,
                               signIn: finder.cachedResult(name).map { $0.signIn == .unknown ? .from($0.state, provider: kind) : $0.signIn } ?? .unknown,
                               limitedUntil: limitedUntil)
    }

    /// Sign-in for one account (nil = the default account), read off the main thread into the same SeatSignIn field.
    /// Reads only what the reader allows: stored accounts any time, the live default dir on demand.
    func probeSignIn(account: ResolvedAccount?, reader: AccountSignInReader, limitedUntil: Date? = nil) async -> SeatRuntimeInfo {
        var info = runtimeSnapshot(finder: reader.finder, limitedUntil: limitedUntil)
        let reading = await reader.read(account ?? reader.store.defaultAccount(kind))
        info.signIn = reading.signIn; info.plan = reading.plan; info.email = reading.email
        return info
    }

    /// Runs `--version` off the calling thread (bounded to 2 s), then returns the snapshot with it.
    func probeRuntime(finder: ProgramFinder = .shared, limitedUntil: Date? = nil) async -> SeatRuntimeInfo {
        let name = kind.rawValue
        guard let path = finder.resolve(name) else { return runtimeSnapshot(finder: finder, limitedUntil: limitedUntil) }
        let version: String? = await Task.detached {
            ProgramFinder.run(path, ["--version"], ProcessInfo.processInfo.environment, 2)
                .flatMap { $0.status == 0 && !$0.timedOut ? $0.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        }.value
        return runtimeSnapshot(finder: finder, version: version, limitedUntil: limitedUntil)
    }
}
