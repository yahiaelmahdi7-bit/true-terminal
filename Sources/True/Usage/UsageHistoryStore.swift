import SwiftUI
import Observation

/// State of the Usage history sheet. One scan when the sheet opens (the scanner reads new bytes only); no timer, no watcher.
@MainActor @Observable
final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    var isOpen = false
    var loading = false
    var period = UsagePeriod.week
    var segment = UsageSegment.tokens
    private(set) var reply: UsageReply?
    private var windows: [UsageWindow] = []
    // Reset times recorded by ResetLog, loaded when the sheet opens.
    private var resetsSeen: [UsageProvider: [Date]] = [:]

    var history: UsageHistory {
        var r = reply ?? UsageReply(days: [], unpriced: [], skipped: [:], unreadable: [])
        r.windows = windows
        return UsageHistory.make(reply: r, period: period, today: Date(), resetsSeen: resetsSeen)
    }

    func open(windows: [UsageWindow]) {
        self.windows = windows
        isOpen = true
        loading = true
        Task {
            let r = await UsageService.shared.reply(days: UsagePeriod.quarter.days)
            resetsSeen = await Task.detached(priority: .utility) { ResetLog.shared.seen() }.value
            reply = r; loading = false
        }
    }
}

struct UsageHistorySheet: View {
    let store: UsageHistoryStore
    var body: some View {
        UsageHistoryView(history: store.history, segment: store.segment, loading: store.loading,
                         onSegment: { store.segment = $0 }, onPeriod: { store.period = $0 }, onDone: { store.isOpen = false })
    }
}
