import Foundation
import Observation

/// What the live app knows when the bar reads a line.
struct BarEnvironment: Sendable {
    var focused: FocusedPane
    var projects: [Project]
    var recent: [String]
    var seats: [BarSeat]
}

/// State behind the Command bar (⌘K). Closed = zero Jev calls, zero timers. One read in flight at a time: typing
/// cancels the last one, and a cancelled read never touches the route. Jev down / slow / keyless, or the Settings
/// toggle off → the deterministic route (rules + pane-aware defaults) and the user can still run it.
@MainActor
@Observable
final class CommandBarStore {
    static let shared = CommandBarStore()

    private(set) var isOpen = false
    var text = "" { didSet { if text != oldValue, !settingFromHistory { textChanged() } } }
    private(set) var route: Route?
    private(set) var reading = false
    /// Destructive agent work waits for a second Return.
    private(set) var armed = false
    private(set) var history: [String] = []
    private(set) var lastError: String?

    @ObservationIgnored private let jev: JevClient
    @ObservationIgnored private let enabled: () -> Bool
    @ObservationIgnored private let log: CommandBarLog
    @ObservationIgnored private let environment: @MainActor () -> BarEnvironment
    @ObservationIgnored private let isExecutable: @Sendable (String) -> Bool
    @ObservationIgnored private let execute: @MainActor (Plan, Route) -> Void
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var historyIndex = -1
    @ObservationIgnored private var settingFromHistory = false
    @ObservationIgnored private(set) var context: CommandContext?
    @ObservationIgnored private var readStarted: Date?

    init(jev: JevClient = .shared,
         enabled: @escaping () -> Bool = { TerminalSettings.jevRouting },
         log: CommandBarLog = .standard,
         environment: @escaping @MainActor () -> BarEnvironment = { BarEnvironmentProvider.live() },
         isExecutable: @escaping @Sendable (String) -> Bool = { BarEnvironmentProvider.onPath($0) },
         execute: @escaping @MainActor (Plan, Route) -> Void = { CommandBarStore.liveExecute($0, $1) },
         debounce: Duration = CommandRouter.debounce) {
        self.jev = jev; self.enabled = enabled; self.log = log; self.environment = environment
        self.isExecutable = isExecutable; self.execute = execute; self.debounce = debounce
    }

    // MARK: Open / close

    func toggle() { isOpen ? close() : show() }

    func show() {
        text = ""
        route = nil
        armed = false
        lastError = nil
        historyIndex = -1
        history = log.loadHistory()
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        cancelRead(logging: true)
        isOpen = false
        armed = false
        TerminalFocus.refocus()
    }

    // MARK: Reading

    private func cancelRead(logging: Bool) {
        let was = reading
        readTask?.cancel()
        readTask = nil
        token += 1
        reading = false
        if logging, was, let started = readStarted {
            let rec = CommandBarLog.Record(event: .cancelled, text: text, latencyMs: Int(Date().timeIntervalSince(started) * 1000), route: route)
            let log = self.log
            Task.detached { log.append(rec) }
        }
        readStarted = nil
    }

    private func textChanged() {
        cancelRead(logging: true)
        armed = false
        guard isOpen else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { route = nil; context = nil; return }
        let env = environment()
        let ctx = CommandContext(focused: env.focused,
                                 projects: CommandRouter.candidates(text: t, projects: env.projects, recent: env.recent),
                                 seats: env.seats, all: env.projects)
        context = ctx
        let rule = CommandRules.match(t, projects: env.projects, seats: env.seats, recent: env.recent, isExecutable: isExecutable)
        route = CommandRouter.route(text: t, reply: nil, context: ctx, rule: rule)
        // A pure action phrase has nothing to judge; everything else gets one read.
        guard enabled(), !(rule?.kind == .trueAction && rule?.authoritative == true) else { return }
        reading = true
        let mine = token
        let jev = self.jev, delay = debounce, log = self.log, exec = self.isExecutable
        let started = Date()
        readStarted = started
        readTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let reply = await CommandRouter.ask(text: t, context: ctx, rule: rule, jev: jev, isExecutable: exec)
            guard let self, !Task.isCancelled, self.token == mine, self.isOpen else { return }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let routed = CommandRouter.route(text: t, reply: reply, context: ctx, rule: rule)
            self.route = routed
            self.reading = false
            self.readStarted = nil
            if reply != nil {
                let rec = CommandBarLog.Record(event: .read, text: t, reply: reply, latencyMs: ms, route: routed)
                await Task.detached { log.append(rec) }.value
            }
        }
    }

    // MARK: Keys

    /// Tab: the runner-up door.
    func takeRunnerUp() {
        guard let r = route, let ctx = context, let k = r.alternatives.first else { return }
        route = CommandRouter.switching(r, to: k, context: ctx)
        armed = false
    }

    /// The two-choice state: the user decides what Jev could not.
    func choose(_ k: CommandKind) {
        guard let r = route, let ctx = context else { return }
        route = CommandRouter.switching(r, to: k, context: ctx)
        armed = false
    }

    func historyUp() { stepHistory(+1) }
    func historyDown() { stepHistory(-1) }

    private func stepHistory(_ d: Int) {
        let i = historyIndex + d
        guard i >= -1, i < history.count else { return }
        historyIndex = i
        settingFromHistory = true
        text = i < 0 ? "" : history[i]
        settingFromHistory = false
        textChanged()
    }

    // MARK: Run

    /// What Return would do right now, for the view's "typed, not sent" note.
    var plan: Plan? {
        guard let r = route, let c = context else { return nil }
        return CommandExecutor.plan(route: r, background: false, context: c)
    }

    func run(background: Bool = false) {
        guard isOpen, let r = route, let ctx = context, !r.twoChoice else { return }
        let plan = CommandExecutor.plan(route: r, background: background, context: ctx,
                                        stamp: Int(Date().timeIntervalSince1970))
        guard plan.door != .nothing else { return }
        if plan.needsSecondReturn, !armed { armed = true; return }
        let rec = CommandBarLog.Record(event: .run, text: text, latencyMs: nil, route: r,
                                       door: String(describing: plan.door), background: background)
        let h = CommandBarLog.pushed(text, onto: history)
        history = h
        let log = self.log
        Task.detached { log.append(rec); log.saveHistory(h) }
        execute(plan, r)
        close()
    }

    @MainActor
    static func liveExecute(_ plan: Plan, _ route: Route) {
        CommandExecutor.run(plan, route: route, onBackground: { result in
            if case .failure(let e) = result { CommandBarLog.logger.error("background spawn failed: \(e.message, privacy: .public)") }
        })
    }
}
