import Foundation
import CryptoKit

/// H3 · one line in `peers/links-history.json`: a link that went away, who did it, and what we knew about them.
struct PeerLinkRecord: Codable, Equatable, Sendable, Identifiable {
    var who: String                 // "me" | "them"
    var at: Date
    var label: String
    var mailboxId: String
    var fingerprint: String
    var lastBuild: String?          // their True build when we last saw a card ("2026-11-02 · abc123")
    var heldJobs: Int
    var id: String { "\(mailboxId)|\(Int(at.timeIntervalSince1970))" }
    var byThem: Bool { who == "them" }
}

/// H6 · one entry in the "Peer problems" feed (`peers/problems.json`).
struct PeerProblem: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case jobFailed, jobDeclined, dropped, oracle, linkRemoved, needsUpdate }
    var id: String
    var at: Date
    var kind: Kind
    var peer: String
    var text: String
    var jobId: String? = nil
}

extension PeerKeys {
    /// What a person compares to be sure it is the same person: SHA-256 of both public keys, first 8 bytes, as `ab12 cd34 …`.
    var fingerprint: String {
        let h = SHA256.hash(data: sign + ka).prefix(8).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: h.count, by: 4).map { i in String(h.dropFirst(i).prefix(4)) }.joined(separator: " ")
    }
}

/// H2 · the lowest protocol version (`PeerCaps.version`) whose True reads each message kind. A kind missing from the
/// table is read by every version. The sender holds a kind the peer's card says it can't read.
enum PeerKindTable {
    /// Version numbers come from `git log -S currentVersion`: 1.3 = Run 36a (cards, watch), 1.4 = Missions M1 (resume, paused).
    /// Cards only exist from 1.3 on, so "caps" is never blocked: it is how the table learns anything.
    static let minVersion: [String: String] = ["watch": "1.3", "activity": "1.3", "offer": "1.3", "chat": "1.3", "resume": "1.4"]
    /// Dotted numeric compare: "1.10" > "1.4".
    static func atLeast(_ have: String, _ need: String) -> Bool {
        let a = have.split(separator: ".").map { Int($0) ?? 0 }, b = need.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }
    /// True when a fresh card says this peer's True can't read `kind`. No card, or a stale one, never blocks (it queues, as before).
    static func unreadable(kind: String, card: PeerCaps?, now: Date) -> Bool {
        guard let card, !card.isStale(at: now) else { return false }
        guard let need = minVersion[kind] else { return false }
        return !atLeast(card.version, need)
    }
}

/// H6 · the words on a peer row. Pure, so each state has a test.
enum PeerHealth {
    enum State: Equatable { case removedByThem(Date), older, silent(TimeInterval), neverHeard, heard(TimeInterval) }

    /// A peer sends a card every 5 min; three missed means something is wrong.
    static let silentAfter: TimeInterval = 15 * 60

    static func state(heard: Date?, sentCard: Bool, cardVersion: String?, ownVersion: String = PeerCaps.currentVersion,
                      linkAge: TimeInterval, now: Date) -> State {
        let ago = heard.map { max(0, now.timeIntervalSince($0)) }
        if let ago, ago >= silentAfter { return .silent(ago) }
        // Heard recently but old: no card after a minute, or a card from an older version.
        if ago != nil, (!sentCard && linkAge > PeerCaps.unknownGrace) || (cardVersion.map { !PeerKindTable.atLeast($0, ownVersion) } ?? false) { return .older }
        if let ago { return .heard(ago) }
        return .neverHeard
    }

    static func ago(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        return h < 48 ? "\(h) h ago" : "\(h / 24) days ago"
    }
    static func span(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(max(m, 1)) min" }
        return m / 60 < 48 ? "\(m / 60) h" : "\(m / 1440) days"
    }

    static func line(_ st: State, build: String?, flowing: Bool, tz: TimeZone = .current) -> String {
        switch st {
        case .removedByThem(let d): return "Link removed by them at \(PeerStatusText.time(d, tz: tz))"
        case .older: return "Their True is older — update True"
        case .silent(let s): return "Not heard for \(span(s))"
        case .neverHeard: return "Not heard yet"
        case .heard(let s):
            var parts = ["Heard \(ago(s))"]
            if let build { parts.append("True \(build)") }
            if flowing { parts.append("jobs flowing") }
            return parts.joined(separator: " · ")
        }
    }

    static func relayLine(connected: Bool) -> String { connected ? "Relay: connected" : "Relay: offline — retrying" }
}
