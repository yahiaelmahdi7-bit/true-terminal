import Foundation

/// Local nicknames for teammates' Macs. Keyed by the peer's stable id (mailbox), stored on this Mac only
/// (`names.json` beside the Peers files) and never sent to a peer. `resolve` is the one place True names a teammate.
struct PeerNicknames: Equatable, Codable {
    static let maxLength = 40
    var byId: [String: String] = [:]

    /// The nickname if one is set, else the peer's own label.
    func resolve(id: String, label: String) -> String {
        byId[id].flatMap { $0.isEmpty ? nil : $0 } ?? label
    }

    /// Trimmed, no control characters, capped. Empty = no nickname.
    static func clean(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init)
            .reduce(into: "") { $0.append($1) }.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    /// A copy with `id` renamed; an empty name clears it back to the label.
    func setting(id: String, name: String) -> PeerNicknames {
        var c = self
        let n = Self.clean(name)
        if n.isEmpty { c.byId[id] = nil } else { c.byId[id] = n }
        return c
    }

    static func url(root: URL) -> URL { root.appendingPathComponent("names.json") }

    /// Reads only `names.json`. Missing or unreadable = none; never creates anything.
    static func load(root: URL = PeerEngine.standardRoot) -> PeerNicknames {
        (try? Data(contentsOf: url(root: root))).flatMap { try? JSONDecoder().decode(PeerNicknames.self, from: $0) } ?? PeerNicknames()
    }

    /// Writes only `names.json` (0600, atomic).
    func save(root: URL = PeerEngine.standardRoot) {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        PeerEngine.write((try? e.encode(self)) ?? Data(), to: Self.url(root: root))
    }
}
