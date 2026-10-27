import Foundation
import CryptoKit

/// Run 39 — what a Mac says about itself on the local network. A per-session salt and a tag derived from the mailbox id:
/// no keys and no stable id ever go on the wire, so the same Mac can't be followed across networks or sessions.
enum PeerLanTXT {
    static let serviceType = "_true-peer._tcp"
    static let maxRows = 50

    struct Ad: Equatable, Sendable {
        var salt: Data   // 8 bytes
        var tag: Data    // 8 bytes
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    /// First 8 bytes of SHA-256(salt ‖ mailboxId bytes). `mailboxId` is the 32-hex id (16 bytes).
    static func tag(salt: Data, mailboxId: String) -> Data {
        Data(SHA256.hash(data: salt + (unhex(mailboxId) ?? Data(mailboxId.utf8))).prefix(8))
    }

    static func makeAd(mailboxId: String, salt: Data = PeerCrypto.randomBytes(8)) -> Ad {
        Ad(salt: salt, tag: tag(salt: salt, mailboxId: mailboxId))
    }

    static func encode(_ ad: Ad) -> [String: String] { ["v": "1", "s": hex(ad.salt), "t": hex(ad.tag)] }

    /// Strict: `v == "1"`, `s` and `t` exactly 16 lowercase/uppercase hex chars. Anything else is ignored.
    static func decode(_ txt: [String: String]) -> Ad? {
        guard txt["v"] == "1", let s = txt["s"], let t = txt["t"], s.count == 16, t.count == 16,
              let salt = unhex(s), let tg = unhex(t) else { return nil }
        return Ad(salt: salt, tag: tg)
    }

    /// Does this advertisement belong to the Mac with `mailboxId`?
    static func matches(_ ad: Ad, mailboxId: String) -> Bool { tag(salt: ad.salt, mailboxId: mailboxId) == ad.tag }

    /// A Bonjour service name is at most 63 UTF-8 bytes; cut on a character boundary.
    static func serviceName(_ name: String) -> String {
        var out = ""
        for ch in name {
            if (out + String(ch)).utf8.count > 63 { break }
            out.append(ch)
        }
        return out.isEmpty ? "True" : out
    }
}
