import Foundation
import CryptoKit

/// Peers identity, invites and the sealed envelope (Run 29). CryptoKit only. The relay carries these bytes and
/// nothing it does can make them readable, forgeable, replayable or redirectable: keys are pinned at pairing.

enum PeerB64 {
    static func std(_ d: Data) -> String { d.base64EncodedString() }
    static func fromStd(_ s: String) -> Data? { Data(base64Encoded: s) }
    /// URL-safe, no padding.
    static func url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func fromURL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// A peer's two public keys. Pinned at pairing; the only thing that decides who a message is from.
struct PeerKeys: Codable, Equatable, Sendable {
    var sign: Data
    var ka: Data
    var mailboxId: String { PeerCrypto.mailboxId(signPub: sign) }
}

/// This install's two key pairs, in `~/.true/peers/identity.json` (0600, dir 0700) — no Keychain, so a re-signed build never prompts.
struct PeerIdentity: @unchecked Sendable {
    let signing: Curve25519.Signing.PrivateKey
    let agreement: Curve25519.KeyAgreement.PrivateKey

    static func generate() -> PeerIdentity {
        PeerIdentity(signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey())
    }
    var keys: PeerKeys { PeerKeys(sign: signing.publicKey.rawRepresentation, ka: agreement.publicKey.rawRepresentation) }
    var mailboxId: String { keys.mailboxId }

    private struct File: Codable { var sign: String; var ka: String }

    static func loadOrCreate(root: URL) -> PeerIdentity {
        let url = root.appendingPathComponent("identity.json")
        if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d),
           let s = PeerB64.fromStd(f.sign), let k = PeerB64.fromStd(f.ka),
           let sp = try? Curve25519.Signing.PrivateKey(rawRepresentation: s),
           let kp = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: k) {
            return PeerIdentity(signing: sp, agreement: kp)
        }
        let id = generate()
        let f = File(sign: PeerB64.std(id.signing.rawRepresentation), ka: PeerB64.std(id.agreement.rawRepresentation))
        PeerEngine.write((try? JSONEncoder().encode(f)) ?? Data(), to: url)
        return id
    }

    /// Ed25519 over the relay challenge. The host is signed in so a hello can't be replayed to another relay.
    func helloSignature(nonce: String, host: String) -> Data {
        (try? signing.signature(for: Data("true-relay-v1|\(nonce)|\(host)".utf8))) ?? Data()
    }
}

enum PeerCrypto {
    /// Lowercase hex of the first 16 bytes of SHA-256(signing public key).
    static func mailboxId(signPub: Data) -> String {
        SHA256.hash(data: signPub).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        let rc = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        precondition(rc == errSecSuccess, "no secure randomness")
        return Data(b)
    }
}

/// `true-peer:v1:<mailboxId>.<KA pub>.<sign pub>.<secret 16B>` — the joiner pins the keys from here, never from the relay.
struct PeerInvite: Equatable, Sendable {
    static let prefix = "true-peer:v1:"
    var mailboxId: String
    var kaPub: Data
    var signPub: Data
    var secret: Data

    var string: String {
        Self.prefix + [mailboxId, PeerB64.url(kaPub), PeerB64.url(signPub), PeerB64.url(secret)].joined(separator: ".")
    }
    var keys: PeerKeys { PeerKeys(sign: signPub, ka: kaPub) }

    static func parse(_ raw: String) -> PeerInvite? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix), s.count < 400 else { return nil }
        let parts = s.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let ka = PeerB64.fromURL(parts[1]), let sp = PeerB64.fromURL(parts[2]),
              let secret = PeerB64.fromURL(parts[3]), ka.count == 32, sp.count == 32, secret.count == 16,
              parts[0] == PeerCrypto.mailboxId(signPub: sp) else { return nil }
        return PeerInvite(mailboxId: parts[0], kaPub: ka, signPub: sp, secret: secret)
    }
}

/// The outer envelope. `sp`/`ka` ride along only on `pair-request` (the inviter has no pinned keys for a joiner yet);
/// `sp` is checked against `from`, and both are covered by the signature.
struct PeerEnvelope: Codable, Equatable, Sendable {
    var v: Int
    var from: String
    var to: String
    var id: String
    var ts: Int
    var ct: String
    var sig: String
    var sp: String?
    var ka: String?

    var signedString: String { "\(v)|\(from)|\(to)|\(id)|\(ts)|\(ct)|\(sp ?? "")|\(ka ?? "")" }
}

enum PeerSeal {
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let skew: TimeInterval = 5 * 60
    /// Raw envelope bytes; base64 of this is exactly the relay's 192 KB limit.
    static let maxBlob = 144 * 1024

    enum Drop: Error, Equatable { case malformed, version, wrongRecipient, stale, unknownSender, badSignature, undecryptable }

    private static func key(mine: Curve25519.KeyAgreement.PrivateKey, theirs: Data, id: String, from: String, to: String) throws -> SymmetricKey {
        let their = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs)
        let shared = try mine.sharedSecretFromKeyAgreement(with: their)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(id.utf8),
                                              sharedInfo: Data("true-peer-v1|\(from)|\(to)".utf8), outputByteCount: 32)
    }

    /// Seal `payload` (JSON) to `to`. `introduce` adds our public keys (pair-request only).
    static func seal(payload: Data, id: String = UUID().uuidString.lowercased(), now: Date, from me: PeerIdentity,
                     to: PeerKeys, introduce: Bool = false) -> Data? {
        let toId = to.mailboxId, fromId = me.mailboxId
        guard let k = try? key(mine: me.agreement, theirs: to.ka, id: id, from: fromId, to: toId),
              let box = try? ChaChaPoly.seal(payload, using: k), let combined = Optional(box.combined) else { return nil }
        var env = PeerEnvelope(v: 1, from: fromId, to: toId, id: id, ts: Int(now.timeIntervalSince1970), ct: PeerB64.std(combined), sig: "",
                               sp: introduce ? PeerB64.std(me.keys.sign) : nil, ka: introduce ? PeerB64.std(me.keys.ka) : nil)
        guard let sig = try? me.signing.signature(for: Data(env.signedString.utf8)) else { return nil }
        env.sig = PeerB64.std(sig)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let out = try? enc.encode(env), out.count <= maxBlob else { return nil }
        return out
    }

    struct Opened { var envelope: PeerEnvelope; var payload: Data; var sender: PeerKeys; var pinned: Bool }

    /// Everything the receiver checks, in order. `pinned` returns the stored keys for a mailbox id (nil = unknown).
    /// Replay (the seen-set) is the caller's: it runs after this succeeds.
    static func open(_ data: Data, me: PeerIdentity, now: Date, pinned: (String) -> PeerKeys?) -> Result<Opened, Drop> {
        guard data.count <= maxBlob, let env = try? JSONDecoder().decode(PeerEnvelope.self, from: data) else { return .failure(.malformed) }
        guard env.v == 1 else { return .failure(.version) }
        guard env.to == me.mailboxId else { return .failure(.wrongRecipient) }
        let ts = TimeInterval(env.ts), t = now.timeIntervalSince1970
        guard ts <= t + skew, ts >= t - maxAge - skew else { return .failure(.stale) }
        var sender: PeerKeys
        var isPinned = true
        if let p = pinned(env.from) { sender = p }
        else if let sp = env.sp.flatMap(PeerB64.fromStd), let ka = env.ka.flatMap(PeerB64.fromStd), sp.count == 32, ka.count == 32,
                PeerCrypto.mailboxId(signPub: sp) == env.from {
            sender = PeerKeys(sign: sp, ka: ka); isPinned = false
        } else { return .failure(.unknownSender) }
        // A pinned sender's keys come from the pin only; introduced keys that differ are not honoured.
        guard let sigData = PeerB64.fromStd(env.sig), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: sender.sign),
              pub.isValidSignature(sigData, for: Data(env.signedString.utf8)) else { return .failure(.badSignature) }
        guard let ct = PeerB64.fromStd(env.ct), let k = try? key(mine: me.agreement, theirs: sender.ka, id: env.id, from: env.from, to: env.to),
              let box = try? ChaChaPoly.SealedBox(combined: ct), let plain = try? ChaChaPoly.open(box, using: k) else { return .failure(.undecryptable) }
        return .success(Opened(envelope: env, payload: plain, sender: sender, pinned: isPinned))
    }
}
