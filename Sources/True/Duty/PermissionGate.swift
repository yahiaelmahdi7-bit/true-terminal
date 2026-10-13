import Foundation

/// The four-level permission gate (SPEC Run 15 §4). Pure: Jev's reply is passed in, never fetched here.
enum PermissionGate {
    /// Provisional floors (code constants, calibrated on unseen labelled cases).
    enum Policy {
        static let dangerFloor = 0.5
        static let safeFloor = 0.85
    }

    static let extra: [(id: String, text: String)] = [
        ("p_secrets", "Does `text` read, print, copy, move or change a password, API key, token or other credential?"),
        ("p_money", "Does `text` spend money or change a paid plan, subscription, billing or payments?"),
        ("p_local", "Does `text` only change files inside the repository at `repo`, with no network access?"),
        ("p_undo", "Could every change in `text` be undone afterwards with a local git command such as git restore or git revert?"),
        ("p_scope", "Does `text` only fix the problem in `problem`, without changing anything unrelated to it?"),
    ]

    static var questions: [String: JevQuestion] {
        var q: [String: JevQuestion] = [:]
        for d in DangerQuestions.all + extra { q[d.id] = .noul(d.text) }
        return q
    }

    static func state(text: String, repo: String, problem: String) -> [String: Any] {
        ["text": text, "repo": repo, "problem": problem]
    }

    struct Decision: Equatable, Sendable {
        var level: PermissionLevel
        var reasons: [String]
    }

    static func decide(text: String, denyText: String? = nil, reply: JevReply?, ceiling: PermissionLevel = .askFirst,
                       preapproved: Bool = false) -> Decision {
        let denied = DenyList.hits(denyText ?? text)
        if !denied.isEmpty { return Decision(level: .handOff, reasons: denied.map { "deny-list: \($0)" }) }
        guard let reply else { return Decision(level: PermissionLevel.strictest(.askFirst, ceiling), reasons: ["Jev unavailable"]) }
        func p(_ id: String) -> Double? { reply.answers[id]?.noul }
        let dangerIDs = DangerQuestions.all.map(\.id) + ["p_secrets", "p_money"]
        let dangers = dangerIDs.compactMap { id in p(id).map { (id, $0) } }
        if let worst = dangers.max(by: { $0.1 < $1.1 }), worst.1 >= Policy.dangerFloor {
            return Decision(level: .handOff, reasons: ["\(worst.0) \(String(format: "%.2f", worst.1))"])
        }
        var level = PermissionLevel.askFirst
        var reasons: [String] = []
        let safe = ["p_local", "p_undo", "p_scope"].compactMap(p)
        if dangers.count < dangerIDs.count || safe.count < 3 { reasons.append("answer missing") }
        else if safe.min()! >= Policy.safeFloor, preapproved { level = .actIfPreapproved; reasons.append("pre-approved") }
        return Decision(level: PermissionLevel.strictest(level, ceiling), reasons: reasons)
    }
}
