import Foundation

/// Every True publishes its own plan use inside the Peers Card it already sends (no new service). The app's
/// `UsageStore` is the one reader (Claude via `allowance_reader.py`, Codex via rollouts); this turns its windows into
/// the Card's `UsageShare`, keeps the latest in a lock-guarded box the Peers queue can read, and nudges the engine
/// when the numbers move. The Card heartbeat (every 5 min) carries it even when nothing moved.
enum UsageSharing {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var latest: UsageShare?
    nonisolated(unsafe) private static var timerStarted = false

    /// What the Card carries right now (nil until a first reading).
    static var current: UsageShare? { lock.lock(); defer { lock.unlock() }; return latest }

    /// Pure: windows → share. Unread / reset windows are left out; nil when nothing readable remains.
    static func share(from windows: [UsageWindow]) -> UsageShare? {
        func pct(_ p: UsageProvider, _ k: UsageKind) -> (Double, Double)? {
            guard let w = windows.first(where: { $0.provider == p && $0.kind == k }), let u = w.usedPercent, let r = w.readAt,
                  w.state == .fresh || w.state == .old else { return nil }
            return (u.rounded(), r.timeIntervalSince1970)
        }
        let cw = pct(.claude, .weekly), cf = pct(.claude, .fiveHour), xw = pct(.codex, .weekly), xf = pct(.codex, .fiveHour)
        guard let read = [cw, cf, xw, xf].compactMap({ $0?.1 }).max() else { return nil }
        return UsageShare(claudeWeekly: cw?.0, claudeFiveH: cf?.0, codexWeekly: xw?.0, codexFiveH: xf?.0, readAt: read)
    }

    /// Called after every store read. Sends a fresh Card only when a percent changed (readAt alone never triggers one).
    static func publish(_ windows: [UsageWindow], notify: () -> Void = { PeerService.liveEngine?.cardInputsChanged() }) {
        let s = share(from: windows)
        lock.lock()
        let changed = moved(latest, s)
        latest = s
        lock.unlock()
        if changed { notify() }
    }

    /// A new Card is worth sending only when a percent differs; a newer `readAt` alone is not.
    static func moved(_ old: UsageShare?, _ new: UsageShare?) -> Bool {
        var o = old, n = new
        o?.readAt = 0; n?.readAt = 0
        return o != n
    }

    /// Re-read usage every 5 minutes for as long as the app runs, pill on screen or not, so a Mac nobody is looking at
    /// still publishes. Started once, when the Peers engine is created.
    static func startTimer() {
        lock.lock(); let already = timerStarted; timerStarted = true; lock.unlock()
        guard !already else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { UsageStore.shared.refresh() }
            Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
                MainActor.assumeIsolated { UsageStore.shared.refresh() }
            }
        }
    }
}
