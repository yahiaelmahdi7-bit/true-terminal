import Foundation

/// One phone watching one pane. PTY bytes land in `pending`; a writer thread drains it. A viewer that
/// falls more than 1 MB behind does not get the backlog — it is dropped and the next thing it receives
/// is a fresh screen snapshot (see ``RemoteBackpressure``).
final class RemoteViewer: @unchecked Sendable {
    enum Work: Equatable { case none, snapshot, data([UInt8]) }
    let pane: UUID
    let wake = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var needsSnapshot = true     // a viewer's first delivery is always a snapshot
    private(set) var closed = false

    init(pane: UUID) { self.pane = pane }

    func push(_ bytes: [UInt8]) {
        lock.lock()
        if !needsSnapshot {
            if RemoteBackpressure.shouldSnapshot(pendingBytes: pending.count + bytes.count) {
                pending = []; needsSnapshot = true
            } else { pending += bytes }
        }
        lock.unlock()
        wake.signal()
    }

    /// Snapshot first (it supersedes anything queued), else up to 64 KB of stream.
    func take() -> Work {
        lock.lock(); defer { lock.unlock() }
        if needsSnapshot { needsSnapshot = false; pending = []; return .snapshot }
        if pending.isEmpty { return .none }
        let n = min(pending.count, 65_536)
        let chunk = Array(pending.prefix(n))
        pending.removeFirst(n)
        return .data(chunk)
    }

    func close() { lock.lock(); closed = true; lock.unlock(); wake.signal() }
}

/// Fan-out of a pane's PTY bytes to its remote viewers. `publish` is called from the terminal's data
/// path, so with no viewers it is one lock + one dictionary miss.
final class RemoteHub: @unchecked Sendable {
    static let shared = RemoteHub()
    private let lock = NSLock()
    private var viewers: [UUID: [RemoteViewer]] = [:]

    func subscribe(_ pane: UUID) -> RemoteViewer {
        let v = RemoteViewer(pane: pane)
        lock.lock(); viewers[pane, default: []].append(v); lock.unlock()
        return v
    }

    func unsubscribe(_ v: RemoteViewer) {
        lock.lock()
        viewers[v.pane]?.removeAll { $0 === v }
        if viewers[v.pane]?.isEmpty == true { viewers[v.pane] = nil }
        lock.unlock()
        v.close()
    }

    func publish(_ pane: UUID, _ slice: ArraySlice<UInt8>) {
        lock.lock(); let list = viewers[pane]; lock.unlock()
        guard let list, !list.isEmpty else { return }
        let bytes = Array(slice)
        for v in list { v.push(bytes) }
    }

    var viewerCount: Int { lock.lock(); defer { lock.unlock() }; return viewers.values.reduce(0) { $0 + $1.count } }
}

/// What the server needs from True, behind a protocol so the server never imports AppKit state.
protocol RemoteBackend: Sendable {
    func tabsJSON() -> Data
    /// nil when the pane does not exist (closed, or never was).
    func snapshot(pane: UUID) -> (cols: Int, rows: Int, bytes: [UInt8])?
    func input(pane: UUID, bytes: [UInt8]) -> Bool
    /// One whole prompt (or control) through PaneDelivery. Returns the `PaneDelivery.Outcome` raw value, nil for an unknown pane.
    /// `attachments` are resolved file paths, pasted ahead of the text.
    func paneInput(pane: UUID, intent: PaneInputIntent, text: String, attachments: [String]) -> String?
}

extension RemoteBackend {
    func paneInput(pane: UUID, intent: PaneInputIntent, text: String, attachments: [String]) -> String? { nil }
}

/// What the phone composer may ask for. Wire names are the raw values.
enum PaneInputIntent: String, Sendable, CaseIterable {
    case prompt, stage, control, submitOnly, approve, deny

    var deliveryIntent: PaneDelivery.Intent {
        switch self {
        case .prompt: return .prompt
        case .stage: return .stage
        case .control: return .control
        case .submitOnly: return .submitOnly
        case .approve: return .answer(approve: true)
        case .deny: return .answer(approve: false)
        }
    }
}

extension PaneDelivery.Outcome {
    var wire: String {
        switch self {
        case .landed: return "landed"
        case .staged: return "staged"
        case .unverified: return "unverified"
        case .stuckInComposer: return "stuckInComposer"
        case .noPane: return "noPane"
        case .promptGone: return "promptGone"
        }
    }
}
