import Foundation
import Testing
@testable import True

/// Wedge 3 step 8: routing.json, the fallback-on-wake rule (T3 Q7), the limited state and the test switch.
@Suite struct RoutingTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let reset = now.addingTimeInterval(3_600)

    static func win(_ p: UsageProvider, _ k: UsageKind = .fiveHour, used: Double? = 40, reset: Date? = now.addingTimeInterval(3_600),
                    readAgo: TimeInterval = 60) -> UsageWindow {
        UsageWindow(provider: p, kind: k, usedPercent: used, resetsAt: reset, windowMins: k == .fiveHour ? 300 : 10_080,
                    readAt: now.addingTimeInterval(-readAgo), state: .none).classified(now: now)
    }
    static let claudeFull = ProviderFacts(installed: true, signIn: .signedIn, windows: [win(.claude, used: 100), win(.claude, .weekly, used: 30)])
    static let codexGood = ProviderFacts(installed: true, signIn: .signedIn, windows: [win(.codex, used: 10), win(.codex, .weekly, used: 20)])
    static let fallback = ModelChoice(provider: .codex, model: nil)

    static func decide(chosen: ProviderFacts = claudeFull, fallbackFacts: ProviderFacts = codexGood, fallback: ModelChoice? = fallback,
                       explicit: Bool = false, fresh: Bool = true) -> FallbackDecision {
        FallbackOnWake.decide(chosen: .claude, chosenFacts: chosen, fallback: fallback, fallbackFacts: fallbackFacts,
                              explicitModel: explicit, isFreshWake: fresh, now: now)
    }

    // MARK: each condition alone blocks; the pass case

    @Test func passCaseSwitchesAndBuildsTheCard() throws {
        guard case let .useFallback(card) = Self.decide() else { Issue.record("expected a switch"); return }
        #expect(card.fallback.provider == .codex && card.chosen == .claude && card.resetsAt == Self.reset)
        #expect(card.text == "Using Codex · Claude " + UsageText.line(Self.win(.claude, used: 100)))
        #expect(card.text.hasPrefix("Using Codex · Claude resets "))
        #expect(card.buttonText == "Use Claude")
    }

    @Test func notAFreshWakeNeverSwitches() { #expect(Self.decide(fresh: false) == .keep(.notFreshWake)) }
    @Test func anExplicitModelNeverSwitches() { #expect(Self.decide(explicit: true) == .keep(.explicitModel)) }
    @Test func noFallbackSetNeverSwitches() { #expect(Self.decide(fallback: nil) == .keep(.noFallback)) }
    @Test func fallbackOnTheSameProviderNeverSwitches() {
        #expect(Self.decide(fallback: ModelChoice(provider: .claude, model: "haiku")) == .keep(.sameProvider))
    }

    @Test func chosenWindowMustBeAt100() {
        var f = Self.claudeFull; f.windows = [Self.win(.claude, used: 99.9), Self.win(.claude, .weekly, used: 50)]
        #expect(Self.decide(chosen: f) == .keep(.chosenNotExhausted))
    }
    @Test func chosenWindowMustBeFresh() {
        var f = Self.claudeFull; f.windows = [Self.win(.claude, used: 100, readAgo: 31 * 60)]   // read 31 min ago: old
        #expect(f.windows[0].state == .old)
        #expect(Self.decide(chosen: f) == .keep(.chosenNotExhausted))
    }
    @Test func chosenResetMustBeInTheFuture() {
        var f = Self.claudeFull
        f.windows = [Self.win(.claude, used: 100, reset: Self.now.addingTimeInterval(-5))]   // past reset: percent dropped
        #expect(Self.decide(chosen: f) == .keep(.chosenNotExhausted))
        f.windows = [Self.win(.claude, used: 100, reset: nil)]
        #expect(Self.decide(chosen: f) == .keep(.chosenNotExhausted))
        f.windows = []
        #expect(Self.decide(chosen: f) == .keep(.chosenNotExhausted))
    }
    @Test func aStaleStoredFlagIsReclassifiedAgainstTheClock() {
        // A window stored as fresh at 100 % whose reset has since passed must not count.
        let stale = UsageWindow(provider: .claude, kind: .fiveHour, usedPercent: 100, resetsAt: Self.now.addingTimeInterval(-1),
                                windowMins: 300, readAt: Self.now.addingTimeInterval(-60), state: .fresh)
        var f = Self.claudeFull; f.windows = [stale]
        #expect(Self.decide(chosen: f) == .keep(.chosenNotExhausted))
    }

    @Test func fallbackMustBeInstalled() {
        var f = Self.codexGood; f.installed = false
        #expect(Self.decide(fallbackFacts: f) == .keep(.fallbackNotInstalled))
    }
    @Test func fallbackMustBeEnabled() {
        var f = Self.codexGood; f.enabled = false
        #expect(Self.decide(fallbackFacts: f) == .keep(.fallbackDisabled))
    }
    @Test(arguments: [SeatSignIn.notSignedIn, .unknown])
    func fallbackMustBeSignedInAndUnknownIsNotSignedIn(state: SeatSignIn) {
        var f = Self.codexGood; f.signIn = state
        #expect(Self.decide(fallbackFacts: f) == .keep(.fallbackNotSignedIn))
    }
    @Test func fallbackWindowsMustBeFresh() {
        var f = Self.codexGood
        f.windows = [Self.win(.codex, used: 10, readAgo: 3 * 3_600), Self.win(.codex, .weekly, used: 20)]   // five-hour is old
        #expect(Self.decide(fallbackFacts: f) == .keep(.fallbackWindowsNotFresh))
        f.windows = [Self.win(.codex, used: 10, reset: Self.now.addingTimeInterval(-60)), Self.win(.codex, .weekly, used: 20)]   // past reset
        #expect(Self.decide(fallbackFacts: f) == .keep(.fallbackWindowsNotFresh))
        f.windows = []   // never read at all
        #expect(Self.decide(fallbackFacts: f) == .keep(.fallbackWindowsNotFresh))
        f.windows = [.empty(.codex, .fiveHour), .empty(.codex, .weekly)]
        #expect(Self.decide(fallbackFacts: f) == .keep(.fallbackWindowsNotFresh))
    }
    @Test func fallbackWindowsMustBeUnder100() {
        var f = Self.codexGood
        f.windows = [Self.win(.codex, used: 10), Self.win(.codex, .weekly, used: 100)]
        #expect(Self.decide(fallbackFacts: f) == .keep(.fallbackAtLimit))
        f.windows = [Self.win(.codex, used: 100), Self.win(.codex, .weekly, used: 5)]
        #expect(Self.decide(fallbackFacts: f) == .keep(.fallbackAtLimit))
    }
    @Test func aNeverReadFallbackWindowIsIgnoredWhenAnotherIsFresh() {
        var f = Self.codexGood; f.windows = [Self.win(.codex, used: 10), .empty(.codex, .weekly)]
        guard case .useFallback = Self.decide(fallbackFacts: f) else { Issue.record("expected a switch"); return }
    }

    @Test func theLaterOfTwoExhaustedResetsIsTheOneShown() throws {
        var f = Self.claudeFull
        let later = Self.now.addingTimeInterval(86_400)
        f.windows = [Self.win(.claude, used: 100), Self.win(.claude, .weekly, used: 100, reset: later)]
        guard case let .useFallback(card) = Self.decide(chosen: f) else { Issue.record("expected a switch"); return }
        #expect(card.resetsAt == later)
    }

    // MARK: limited state, structured only

    @Test func limitedUntilComesFromUsageWindowsOnly() {
        #expect(UsageLimitRule.limitedUntil(Self.claudeFull.windows, now: Self.now) == Self.reset)
        #expect(UsageLimitRule.limitedUntil(Self.codexGood.windows, now: Self.now) == nil)
        #expect(UsageLimitRule.limitedUntil([], now: Self.now) == nil)
        // Past reset or old reading: not limited (the percent is no longer true).
        #expect(UsageLimitRule.limitedUntil([Self.win(.claude, used: 100, reset: Self.now.addingTimeInterval(-1))], now: Self.now) == nil)
        #expect(UsageLimitRule.limitedUntil([Self.win(.claude, used: 100, readAgo: 7_200)], now: Self.now) == nil)
        let info = SeatRuntimeInfo(installed: true, limitedUntil: UsageLimitRule.limitedUntil(Self.claudeFull.windows, now: Self.now))
        #expect(info.limitLabel?.hasPrefix("Limited until ") == true)
    }

    // MARK: test switch

    @Test func testSwitchIsOffByDefaultAndForcesClaudeTo100WhenOn() {
        let defaults = UserDefaults(suiteName: "routing-test-" + UUID().uuidString)!
        #expect(!UsageTestSwitch.isOn(env: [:], defaults: defaults))
        #expect(UsageTestSwitch.isOn(env: [UsageTestSwitch.envName: "1"], defaults: defaults))
        defaults.set(true, forKey: UsageTestSwitch.defaultsKey)
        #expect(UsageTestSwitch.isOn(env: [:], defaults: defaults))
        let real = [Self.win(.claude, used: 5), Self.win(.codex, used: 7)]
        #expect(UsageTestSwitch.apply(real, on: false, now: Self.now) == real)
        let forced = UsageTestSwitch.apply(real, on: true, now: Self.now)
        #expect(forced.filter { $0.provider == .codex } == [real[1]])   // Codex untouched
        let claude = forced.filter { $0.provider == .claude }
        #expect(claude.count == 2 && claude.allSatisfy { $0.state == .fresh && $0.usedPercent == 100 && ($0.resetsAt ?? .distantPast) > Self.now })
        #expect(claude.first { $0.kind == .fiveHour }?.resetsAt == Self.reset)   // keeps a real future reset
        #expect(UsageLimitRule.limitedUntil(forced, now: Self.now) != nil)
    }

    // MARK: routing.json

    @Test func routingFileRoundTripsChoicesOnlyAndHasNoSecretFields() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("routing-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RoutingStore(url: dir.appendingPathComponent("nested/routing.json"))
        #expect(store.load() == RoutingFile())   // missing file
        let file = RoutingFile(projects: ["/Users/x/app": ProjectRouting(defaultModel: ModelChoice(provider: .claude, model: "opus"),
                                                                       fallbackModel: ModelChoice(provider: .codex, model: nil))],
                               disabledProviders: [.codex])
        store.save(file)
        #expect(store.load() == file)
        let raw = try String(contentsOf: store.url, encoding: .utf8)
        var keys = Set<String>()
        func walk(_ v: Any) {
            if let d = v as? [String: Any] { for (k, x) in d { keys.insert(k); walk(x) } }
            if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(try JSONSerialization.jsonObject(with: Data(raw.utf8)))
        let allowed: Set<String> = ["version", "projects", "/Users/x/app", "defaultModel", "fallbackModel", "provider", "model", "disabledProviders"]
        #expect(keys.isSubset(of: allowed), "\(keys.subtracting(allowed))")
        let banned = try NSRegularExpression(pattern: "token|secret|password|cookie|api_?key|credential|email", options: .caseInsensitive)
        for k in keys { #expect(banned.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) == nil, "\(k)") }
    }

    @Test func oddRoutingFilesNeverCrashOrInventAFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("routing-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("routing.json")
        for body in ["{{{", "[]", #"{"projects":"x"}"#, #"{"projects":{"/a":{"fallbackModel":{"provider":"gemini"}}}}"#] {
            try body.write(to: url, atomically: true, encoding: .utf8)
            #expect(RoutingStore(url: url).load().projects["/a"]?.fallbackModel == nil)
        }
    }
}

/// The wiring: a fresh wake in AgentRegistry consults routing.json and the rule; nothing else changes.
@Suite @MainActor struct RoutingWakeTests {
    func make(fallbackSet: Bool = true) throws -> (AgentRegistry, WorkspaceModel, AgentStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("routing-wake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AgentStore(url: dir.appendingPathComponent("agents.json"))
        let ws = WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("workspace.json")))
        // Temp Claude and Codex dirs: a wake must never write into the real ~/.codex.
        let reg = AgentRegistry(store: store, paths: AgentPaths(root: dir), workspace: ws,
                                claudeDir: dir.appendingPathComponent("claude"), codexDir: dir.appendingPathComponent("codex"))
        if fallbackSet {
            reg.routingStore.save(RoutingFile(projects: ["/tmp": ProjectRouting(defaultModel: nil, fallbackModel: ModelChoice(provider: .codex, model: nil))]))
        }
        reg.clock = { RoutingTests.now }
        reg.usageWindows = { [RoutingTests.win(.claude, used: 100), RoutingTests.win(.claude, .weekly, used: 10),
                              RoutingTests.win(.codex, used: 10), RoutingTests.win(.codex, .weekly, used: 10)] }
        reg.providerFacts = { _ in (true, .signedIn) }
        return (reg, ws, store, dir)
    }

    @Test func freshWakeUsesTheFallbackForThePaneOnlyAndSavedAgentIsUntouched() throws {
        let (reg, _, store, dir) = try make(); defer { try? FileManager.default.removeItem(at: dir) }
        reg.save(Agent(name: "lead-app", role: .lead, repo: "/tmp", provider: .claude))
        _ = try #require(reg.wake("lead-app"))
        #expect(reg.agent(named: "lead-app")?.seatProvider == .codex)
        #expect(reg.fallbackCards["lead-app"]?.buttonText == "Use Claude")
        #expect(store.load().first?.provider == .claude)   // on disk it is still a Claude seat
        reg.save(try #require(reg.agent(named: "lead-app")))   // an edit while awake must not persist the switch either
        #expect(store.load().first?.provider == .claude)
        let pane = try #require(reg.panes["lead-app"])
        reg.paneClosed(pane)
        #expect(reg.agent(named: "lead-app")?.seatProvider == .claude && reg.fallbackCards["lead-app"] == nil)
    }

    @Test func aRunningSeatNeverSwitches() throws {
        let (reg, _, _, dir) = try make(); defer { try? FileManager.default.removeItem(at: dir) }
        reg.routingStore.save(RoutingFile())   // no fallback yet: it wakes as Claude
        reg.save(Agent(name: "lead-app", role: .lead, repo: "/tmp", provider: .claude))
        _ = try #require(reg.wake("lead-app"))
        reg.routingStore.save(RoutingFile(projects: ["/tmp": ProjectRouting(defaultModel: nil, fallbackModel: ModelChoice(provider: .codex, model: nil))]))
        _ = reg.wake("lead-app")   // already awake: focus only
        #expect(reg.agent(named: "lead-app")?.seatProvider == .claude && reg.fallbackCards.isEmpty)
    }

    @Test func noFallbackExplicitModelOrDutySeatsWakeAsBefore() throws {
        let (reg, _, _, dir) = try make(fallbackSet: false); defer { try? FileManager.default.removeItem(at: dir) }
        reg.save(Agent(name: "lead-a", role: .lead, repo: "/tmp", provider: .claude))
        _ = reg.wake("lead-a")
        #expect(reg.agent(named: "lead-a")?.seatProvider == .claude)
        reg.routingStore.save(RoutingFile(projects: ["/tmp": ProjectRouting(defaultModel: nil, fallbackModel: ModelChoice(provider: .codex, model: nil))]))
        reg.save(Agent(name: "helper-1-app", role: .helper, repo: "/tmp", provider: .claude))
        _ = reg.wake("helper-1-app", explicitModel: true)
        #expect(reg.agent(named: "helper-1-app")?.seatProvider == .claude && reg.fallbackCards["helper-1-app"] == nil)
    }
}
