import Foundation

/// Is anything on this Mac working? `busy == false` means every process True can see is idle, so the
/// Mac may follow its normal display/system sleep timers. `reasons` names what kept it busy (logged).
struct IdleVerdict: Equatable, Sendable {
    var busy: Bool
    var reasons: [String]
}

/// Pure core of the work-gated KeepAwake. The only IO is the injectable `alive` probe, called at
/// evaluation time: a pid that died with no file event must never pin the Mac awake.
///
/// WORK is any of:
///  a. a peer session whose file says busy AND whose pid is alive (any Claude session, in True or not);
///  b. a `running` builder whose claude pid is alive (pid 0 = launch in progress, counts as busy);
///  c. an awake seat whose status is `.working` and whose last hook event is under `seatStale` old
///     (older = the stop hook never fired, e.g. a crash; a genuinely long tool call is still covered
///     by (a) because the Claude CLI keeps its session file "busy").
/// NOT work: `.needsYou` (waiting on the human), idle/done/failed/asleep, dead pids, and plain shell
/// commands in panes — a `tail -f`, ssh or htop would pin the Mac awake forever.
enum IdleGate {
    static let seatStale: TimeInterval = 20 * 60

    struct Seat: Sendable {
        var name: String
        var status: AgentStatus
        var lastEventAt: Date?
    }

    static func evaluate(peers: [PeerSession], builders: [BuilderRecord], seats: [Seat], now: Date,
                         alive: (Int32) -> Bool = { PeerSession.isAlive($0) }) -> IdleVerdict {
        var reasons: [String] = []
        for b in builders where b.state == .running && (b.claudePID == 0 || alive(b.claudePID)) {
            reasons.append("builder \(b.name.isEmpty ? b.id : b.name)")
        }
        for p in peers where p.busy && alive(p.pid) {
            reasons.append("session \(p.name.isEmpty ? "pid \(p.pid)" : p.name)")
        }
        for s in seats where s.status == .working {
            if let at = s.lastEventAt, now.timeIntervalSince(at) < seatStale { reasons.append("seat \(s.name)") }
        }
        return IdleVerdict(busy: !reasons.isEmpty, reasons: reasons)
    }
}
