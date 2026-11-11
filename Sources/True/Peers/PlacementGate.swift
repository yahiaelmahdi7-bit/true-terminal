import Foundation

/// the receiving Mac's rule for a job that carries a placement id (`<item>@<version>`), and the runner's start check.
/// Pure rule code, no model. Steward, the clock and the files are injected so tests need no network and no sleeps.

enum PlacementID {
    /// `item@version` -> (item, version). nil for anything else (no @, empty item, non-numeric or negative version).
    static func parse(_ s: String) -> (item: String, version: Int)? {
        guard let at = s.lastIndex(of: "@") else { return nil }
        let item = String(s[s.startIndex..<at])
        guard !item.isEmpty, item.count <= 120, item.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0 != "/" }),
              let v = Int(s[s.index(after: at)...]), v >= 0 else { return nil }
        return (item, v)
    }
}

enum PlacementVerdict: Equatable, Sendable {
    case auto
    case accept(String)     // fall back to the Accept button; the string is the plain reason
}

struct PlacementEnv: Sendable {
    /// This Mac's Steward device id.
    var myDevice: @Sendable () -> String?
    /// Blocking `GET /items/{item}/placement` body. Throws when Steward is unreachable.
    var fetchPlacement: @Sendable (String) throws -> Data
    /// Blocking `GET /allowance` board body (`pool_enabled`, `devices[]` with `lend`, weekly/five-hour readings).
    var fetchBoard: @Sendable () throws -> Data
    /// Seconds since 1970 of the owner's last prompt on this Mac (`~/.true/group/last-prompt`), nil when unknown.
    var lastPrompt: @Sendable () -> Double?
    var now: @Sendable () -> Date
}

enum PlacementGate {
    static let ownerActiveWindow: TimeInterval = 15 * 60

    static func ownerActive(_ env: PlacementEnv) -> Bool {
        guard let lp = env.lastPrompt() else { return false }
        return env.now().timeIntervalSince1970 - lp < ownerActiveWindow
    }

    private static func obj(_ d: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
    private static func num(_ v: Any?) -> Double? { (v as? NSNumber).map(\.doubleValue) }

    /// Auto-accept only when ALL five hold; anything else is `.accept(reason)`.
    ///  1. Steward says this Mac is the runner at the id's current version.  2. The sender holds work/admin on the job's workspace.
    ///  3. Lend is on and `pool.enabled` is on.  4. The owner has not typed in the last 15 min.  5. The brief screens clean.
    static func decide(placementId: String?, title: String, brief: String, senderHoldsWork: Bool, env: PlacementEnv) -> PlacementVerdict {
        guard let raw = placementId else { return .accept("Not a placed job") }
        guard let id = PlacementID.parse(raw) else { return .accept("Placement id not understood") }
        guard let me = env.myDevice() else { return .accept("This Mac's device is unknown") }
        guard let body = try? env.fetchPlacement(id.item), let p = obj(body) else { return .accept("Steward could not confirm the placement") }
        guard (p["runner_device"] as? String) == me, num(p["placement_version"]).map({ Int($0) }) == id.version else {
            return .accept("Steward does not show this Mac as the runner at that version")
        }
        guard senderHoldsWork else { return .accept("The sender has no work grant here") }
        guard let board = (try? env.fetchBoard()).flatMap(obj) else { return .accept("Steward could not confirm lending") }
        guard (board["pool_enabled"] as? Bool) == true else { return .accept("Pooled work is off") }
        let mine = (board["devices"] as? [[String: Any]])?.first { ($0["device"] as? String) == me }
        guard (mine?["lend"] as? String) == "on" else { return .accept("Lending is off on this Mac") }
        guard !ownerActive(env) else { return .accept("You were at this Mac a moment ago") }
        guard !InjectionScreen.screen(title + "\n" + brief).flagged else { return .accept("The brief looks like it tries to steer the agent") }
        return .auto
    }

    // MARK: runner start check

    struct Reading: Equatable, Sendable { var weekly: Double?; var fiveH: Double?; var hold: Double? }

    static func ownReading(_ env: PlacementEnv) -> Reading {
        guard let me = env.myDevice(), let board = (try? env.fetchBoard()).flatMap(obj),
              let row = (board["devices"] as? [[String: Any]])?.first(where: { ($0["device"] as? String) == me }) else { return Reading() }
        return Reading(weekly: num(row["weekly_pct"]), fiveH: num(row["five_h_pct"]), hold: num(row["pooled_hold_weekly"]))
    }

    /// The runner's own check just before a placed job starts. Returns whether to start, and the starts.log line.
    /// Decline when the owner typed within 15 min, or this Mac's own weekly reading is at the pooled hold.
    static func startCheck(item: String, env: PlacementEnv) -> (start: Bool, why: String?, line: String) {
        let t = env.now()
        let r = ownReading(env)
        let active = ownerActive(env)
        let atHold = r.weekly != nil && r.hold != nil && r.weekly! >= r.hold!
        let start = !active && !atHold
        let lp = env.lastPrompt().map { iso(Date(timeIntervalSince1970: $0)) } ?? "none"
        func pct(_ v: Double?) -> String { v.map { String(format: "%g", $0) } ?? "?" }
        let line = "\(iso(t)) \(start ? "start" : "decline") item=\(item) last_prompt=\(lp) weekly=\(pct(r.weekly)) five_h=\(pct(r.fiveH))"
        let why = start ? nil : (active ? "You were at this Mac a moment ago" : "This Mac is at its pooled-work limit")
        return (start, why, line)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// `~/.true/group/starts.log`, one line per start/decline.
    static func appendStartLine(_ line: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: data) }
        else { try? data.write(to: url, options: .atomic) }
    }
}
