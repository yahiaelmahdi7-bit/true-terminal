import Foundation

/// Run 39 — the seam between "pair on this network" and the real network. Shaped like `NearbyAdvertising`: the live one is
/// `PeerLanNetwork` (Network.framework); tests and the UI logic drive a fake. Everything is called on the main actor.

enum PeerLanBrowseState: Equatable, Sendable {
    case ready
    /// Local Network permission refused (`.waiting(.dns(-65570))`).
    case denied
    /// Any other `.waiting` / `.failed`; the coordinator decides when it has lasted long enough to tell the user.
    case waiting
}

enum PeerLanBrowseEvent: Sendable {
    /// `id` is the transport's own handle for this result (one per interface, so several ids can carry one tag).
    case found(id: String, name: String, txt: [String: String])
    case removed(id: String)
    case state(PeerLanBrowseState)
}

/// One TCP connection carrying whole frames. Callbacks arrive on the main actor.
@MainActor
protocol PeerLanConnection: AnyObject {
    /// The remote address with no port or interface (rate-limit key).
    var remote: String { get }
    var onReady: (() -> Void)? { get set }
    var onFrame: ((Data) -> Void)? { get set }
    /// Fires once: closed by either side, failed, or a bad frame arrived.
    var onClose: (() -> Void)? { get set }
    func start()
    func send(_ payload: Data)
    func close()
}

@MainActor
protocol PeerLanTransport: AnyObject {
    var onBrowse: ((PeerLanBrowseEvent) -> Void)? { get set }
    var onIncoming: ((PeerLanConnection) -> Void)? { get set }
    var isOpen: Bool { get }
    /// Idempotent. `open: true` advertises `name` + `txt` and browses; `false` stops both.
    func sync(open: Bool, name: String, txt: [String: String])
    /// A connection to a browse result; nil if that result is gone. The caller calls `start()`.
    func connect(to id: String) -> PeerLanConnection?
}

/// Length-prefixed frames: 4-byte big-endian length, then that many JSON bytes. The length is checked before anything
/// is allocated for the body.
enum PeerLanFrame {
    static let maxBytes = 8 * 1024

    static func length(header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let n = header.reduce(0) { ($0 << 8) | Int($1) }
        return (1...maxBytes).contains(n) ? n : nil
    }

    static func wrap(_ payload: Data) -> Data? {
        guard (1...maxBytes).contains(payload.count) else { return nil }
        let n = UInt32(payload.count)
        return Data([UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)]) + payload
    }
}

/// At most `limit` connections per remote address per minute.
struct PeerLanRateLimiter {
    var limit = 5
    var window: TimeInterval = 60
    private var seen: [String: [Date]] = [:]

    mutating func allow(_ remote: String, now: Date) -> Bool {
        var q = (seen[remote] ?? []).filter { now.timeIntervalSince($0) < window }
        guard q.count < limit else { seen[remote] = q; return false }
        q.append(now); seen[remote] = q
        if seen.count > 200 { seen = seen.filter { !$0.value.isEmpty && now.timeIntervalSince($0.value.last!) < window } }
        return true
    }
}
