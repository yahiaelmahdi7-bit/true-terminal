import Foundation
import Observation
import os

/// Holds the Mac awake only while agents work (see `IdleGate` for what counts). Hold is immediate; release
/// waits for `grace` of CONTINUOUS idle, which covers a lead finishing before its builder starts and
/// claude-burn's relaunch gap. Event-driven: observation of the Hub/registry state re-evaluates on change;
/// the only timer is a 60 s tick that exists solely while held (or in the grace window) to catch pids that
/// died with no file event. Released = no timer, 0% CPU.
@MainActor
final class WorkAwake {
    static let shared = WorkAwake(backend: KeepAwake.shared)
    static let reason = "True: agents working"

    let grace: TimeInterval
    let tickInterval: TimeInterval
    private let backend: PowerAssertion
    private let verdict: @MainActor (Date) -> IdleVerdict
    private let reload: @MainActor () async -> Void
    private let now: () -> Date
    private let sleeper: (TimeInterval) async -> Void
    private let log = Logger(subsystem: "True", category: "keepawake")

    private(set) var idleSince: Date?
    private var tick: Task<Void, Never>?
    var tickRunning: Bool { tick != nil }
    var held: Bool { backend.held }

    init(backend: PowerAssertion, grace: TimeInterval = 120, tickInterval: TimeInterval = 60,
         verdict: @escaping @MainActor (Date) -> IdleVerdict = WorkAwake.liveVerdict,
         reload: @escaping @MainActor () async -> Void = { await HubStore.shared.reload() },
         now: @escaping () -> Date = Date.init,
         sleeper: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.backend = backend; self.grace = grace; self.tickInterval = tickInterval
        self.verdict = verdict; self.reload = reload; self.now = now; self.sleeper = sleeper
    }

    /// Launch: evaluate once and start watching. Idempotent enough (observation re-arms itself).
    func start() { evaluate(); observe() }

    static func liveVerdict(_ at: Date) -> IdleVerdict {
        let r = AgentRegistry.shared
        let seats = r.agents.filter { r.isAwake($0.name) }.map { a in
            IdleGate.Seat(name: a.name, status: r.status[a.name] ?? .idle,
                          lastEventAt: r.panes[a.name].flatMap { r.latest[$0]?.at })
        }
        return IdleGate.evaluate(peers: HubStore.shared.peers, builders: HubStore.shared.builders, seats: seats, now: at)
    }

    /// One decision. Called on every observed change and on each tick.
    func evaluate() {
        if WatcherStore.active { WatcherStore.shared.checkStuck() }
        let t = now()
        let v = verdict(t)
        if v.busy {
            idleSince = nil
            if !backend.held {
                backend.hold(reason: Self.reason)
                log.info("hold: \(v.reasons.joined(separator: ", "), privacy: .public)")
            }
            startTick()
        } else if backend.held {
            let since = idleSince ?? t
            idleSince = since
            if t.timeIntervalSince(since) >= grace {
                backend.release()
                idleSince = nil
                stopTick()
                log.info("release: idle for \(Int(t.timeIntervalSince(since)))s")
            } else {
                startTick()
            }
        } else {
            idleSince = nil
            stopTick()
        }
    }

    /// Re-arms itself on each change: tracking fires once, then we look again.
    private func observe() {
        withObservationTracking {
            let h = HubStore.shared, r = AgentRegistry.shared
            _ = (h.peers, h.builders, r.status, r.latest, r.panes)
        } onChange: { [weak self] in
            Task { @MainActor in self?.evaluate(); self?.observe() }
        }
    }

    private func startTick() {
        guard tick == nil else { return }
        tick = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                // Wake for the end of the grace window if it is sooner than the next regular tick.
                var wait = self.tickInterval
                if let since = self.idleSince { wait = min(wait, max(1, self.grace - self.now().timeIntervalSince(since))) }
                await self.sleeper(wait)
                if Task.isCancelled { break }
                await self.reload()
                self.evaluate()
            }
        }
    }

    private func stopTick() { tick?.cancel(); tick = nil }
}
