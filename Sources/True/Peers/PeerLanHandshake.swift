import Foundation
import CryptoKit

/// Run 39 — the pairing handshake as a pure state machine. No sockets, no timers, no engine: it is fed events and returns
/// actions, so every branch is tested without a network. Commit-then-reveal: S (sender) commits to a nonce before it sees R's,
/// so a man in the middle cannot pick a nonce that makes two connections show the same code.
struct PeerLanMsg: Codable, Equatable {
    struct Keys: Codable, Equatable { var sign: String; var ka: String }
    var t: String
    var v: Int?
    var name: String?
    var keys: Keys?
    var commit: String?
    var nR: String?
    var nS: String?
    var env: String?
    var ok: Bool?
    var err: String?
    var reason: String?

    func data() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

enum PeerLanOutcome: Equatable {
    case paired
    case declined
    case busy
    case cancelled
    case timedOut
    case failed
}

struct PeerLanHandshake {
    enum Role { case sender, receiver }
    enum Phase: Equatable {
        case start
        case awaitHello              // S: sent hello, waiting for R's; R: waiting for S's
        case awaitReveal             // R only
        case checkCode               // both: code known, waiting on the person (S also waits for R's accept)
        case awaitInvite             // R only, after Accept
        case awaitDone               // S only, invite sent
        case finished(PeerLanOutcome)
    }
    enum Event {
        case begin
        case frame(Data)
        case userConfirm
        case userCancel
        case timeout
        case connectionLost
        case windowClosed
        case inviteReady(String)
        case pairResult(ok: Bool, err: String?)
    }
    enum Action: Equatable {
        case send(PeerLanMsg)
        case close
        /// Show the code and the other Mac's name.
        case prompt(code: String, name: String)
        /// S: ask the engine for an invite, then feed `.inviteReady`.
        case makeInvite
        /// R: pair with the invite under `name` (the driver makes it a safe label), then feed `.pairResult`.
        case pair(raw: String, name: String)
        case cancelInvite(Data)
        /// Replace the one running timer (nil = stop it).
        case arm(TimeInterval?)
        case finished(PeerLanOutcome)
    }

    static let version = 1
    static let frameSeconds: TimeInterval = 10
    static let receiverPromptSeconds: TimeInterval = 90
    static let senderPromptSeconds: TimeInterval = 120
    static let receiverInviteSeconds: TimeInterval = 120
    static let inviteSilenceSeconds: TimeInterval = 10
    static let inviteSkew: TimeInterval = 120

    let role: Role
    private(set) var phase: Phase = .start
    private let me: PeerIdentity
    private let ownName: String
    private let now: () -> Date
    private let nonce: Data
    private var theirKeys: PeerKeys?
    private var theirName = ""
    private var theirNonce: Data?
    private var commit: Data?
    private(set) var code: String?
    private var accepted = false      // S: R's accept arrived
    private var confirmed = false     // S: person pressed Pair
    private var inviteSecret: Data?

    init(role: Role, me: PeerIdentity, ownName: String, nonce: Data = PeerCrypto.randomBytes(16), now: @escaping () -> Date = { Date() }) {
        self.role = role; self.me = me; self.ownName = ownName; self.nonce = nonce; self.now = now
    }

    var otherName: String { theirName }
    var theirMailbox: String? { theirKeys?.mailboxId }
    var isFinished: Bool { if case .finished = phase { return true }; return false }
    var hasLiveInvite: Bool { inviteSecret != nil }
    /// S: the person already pressed Pair and we are waiting for R.
    var waitingForAccept: Bool { role == .sender && confirmed && !accepted }

    // MARK: code

    /// SHA-256("true-lan-v1" ‖ S.sign ‖ R.sign ‖ nS ‖ nR) → first 4 bytes big-endian, mod 1 000 000, six digits.
    static func code(sSign: Data, rSign: Data, nS: Data, nR: Data) -> String {
        var h = SHA256()
        h.update(data: Data("true-lan-v1".utf8)); h.update(data: sSign); h.update(data: rSign); h.update(data: nS); h.update(data: nR)
        let d = Array(h.finalize())
        let n = (UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])) % 1_000_000
        return String(format: "%06d", n)
    }

    /// "482913" → "482 913".
    static func spaced(_ code: String) -> String { code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code }

    // MARK: driving

    mutating func handle(_ e: Event) -> [Action] {
        if isFinished { return [] }
        switch e {
        case .begin: return begin()
        case .frame(let d): return frame(d)
        case .userConfirm: return userConfirm()
        case .userCancel: return abort(.cancelled, bye: role == .receiver ? "declined" : "cancel")
        case .windowClosed: return abort(.cancelled, bye: "closed")
        case .timeout: return timeout()
        case .connectionLost:
            return finish(.failed, close: false, cancelInvite: true)
        case .inviteReady(let raw): return inviteReady(raw)
        case .pairResult(let ok, let err): return pairResult(ok: ok, err: err)
        }
    }

    private mutating func begin() -> [Action] {
        guard phase == .start else { return [] }
        phase = .awaitHello
        let a: [Action]
        switch role {
        case .sender:
            commit = Data(SHA256.hash(data: nonce))
            var m = hello(); m.commit = PeerB64.std(commit!)
            a = [.send(m)]
        case .receiver: a = []
        }
        return a + [.arm(Self.frameSeconds)]
    }

    private func hello() -> PeerLanMsg {
        let k = me.keys
        return PeerLanMsg(t: "hello", v: Self.version, name: ownName, keys: .init(sign: PeerB64.std(k.sign), ka: PeerB64.std(k.ka)))
    }

    private mutating func fail(_ err: String? = nil) -> [Action] {
        var out: [Action] = []
        if role == .receiver, case .awaitInvite = phase, let err { out.append(.send(PeerLanMsg(t: "done", ok: false, err: err))) }
        return out + finish(.failed, close: true, cancelInvite: true)
    }

    private mutating func finish(_ o: PeerLanOutcome, close: Bool, cancelInvite: Bool) -> [Action] {
        phase = .finished(o)
        var out: [Action] = [.arm(nil)]
        if cancelInvite, let s = inviteSecret { out.append(.cancelInvite(s)); inviteSecret = nil }
        if close { out.append(.close) }
        out.append(.finished(o))
        return out
    }

    private mutating func abort(_ o: PeerLanOutcome, bye reason: String) -> [Action] {
        [.send(PeerLanMsg(t: "bye", reason: reason))] + finish(o, close: true, cancelInvite: true)
    }

    private mutating func timeout() -> [Action] {
        switch (role, phase) {
        case (.receiver, .checkCode):
            return [.send(PeerLanMsg(t: "bye", reason: "timeout"))] + finish(.timedOut, close: true, cancelInvite: false)
        case (.sender, .checkCode):
            return abort(.timedOut, bye: "timeout")
        default:
            return finish(.timedOut, close: true, cancelInvite: true)
        }
    }

    // MARK: frames

    private static func decodeKeys(_ k: PeerLanMsg.Keys?) -> PeerKeys? {
        guard let k, let s = PeerB64.fromStd(k.sign), let a = PeerB64.fromStd(k.ka), s.count == 32, a.count == 32 else { return nil }
        return PeerKeys(sign: s, ka: a)
    }

    private mutating func frame(_ d: Data) -> [Action] {
        guard let m = try? JSONDecoder().decode(PeerLanMsg.self, from: d) else { return fail() }
        if m.t == "bye" {
            let o: PeerLanOutcome = m.reason == "busy" ? .busy : m.reason == "timeout" ? .timedOut : m.reason == "closed" ? .cancelled : .declined
            return finish(role == .sender ? o : .cancelled, close: true, cancelInvite: true)
        }
        switch (role, phase, m.t) {
        case (.receiver, .awaitHello, "hello"): return receiverHello(m)
        case (.sender, .awaitHello, "hello"): return senderGotHello(m)
        case (.receiver, .awaitReveal, "reveal"): return receiverReveal(m)
        case (.sender, .checkCode, "accept"):
            accepted = true
            return confirmed ? [.makeInvite] : []
        case (.receiver, .awaitInvite, "invite"): return receiverInvite(m)
        case (.sender, .awaitDone, "done"):
            if m.ok == true { return finish(.paired, close: true, cancelInvite: false) }
            return finish(.failed, close: true, cancelInvite: true)
        default: return fail()
        }
    }

    private mutating func receiverHello(_ m: PeerLanMsg) -> [Action] {
        guard m.v == Self.version, let keys = Self.decodeKeys(m.keys), let c = m.commit.flatMap(PeerB64.fromStd), c.count == 32,
              let name = m.name, name.utf8.count <= 200 else { return fail() }
        theirKeys = keys; theirName = name; commit = c
        phase = .awaitReveal
        var reply = hello(); reply.nR = PeerB64.std(nonce)
        return [.send(reply), .arm(Self.frameSeconds)]
    }

    private mutating func senderGotHello(_ m: PeerLanMsg) -> [Action] {
        guard m.v == Self.version, let keys = Self.decodeKeys(m.keys), let nR = m.nR.flatMap(PeerB64.fromStd), nR.count == 16,
              let name = m.name, name.utf8.count <= 200 else { return fail() }
        theirKeys = keys; theirName = name; theirNonce = nR
        let c = Self.code(sSign: me.keys.sign, rSign: keys.sign, nS: nonce, nR: nR)
        code = c; phase = .checkCode
        return [.send(PeerLanMsg(t: "reveal", nS: PeerB64.std(nonce))), .prompt(code: c, name: name), .arm(Self.senderPromptSeconds)]
    }

    private mutating func receiverReveal(_ m: PeerLanMsg) -> [Action] {
        guard let nS = m.nS.flatMap(PeerB64.fromStd), nS.count == 16, let c = commit, let keys = theirKeys,
              PeerCrypto.constantTimeEqual(Data(SHA256.hash(data: nS)), c) else { return fail() }
        theirNonce = nS
        let cd = Self.code(sSign: keys.sign, rSign: me.keys.sign, nS: nS, nR: nonce)
        code = cd; phase = .checkCode
        return [.prompt(code: cd, name: theirName), .arm(Self.receiverPromptSeconds)]
    }

    private mutating func userConfirm() -> [Action] {
        guard phase == .checkCode else { return [] }
        switch role {
        case .receiver:
            phase = .awaitInvite
            return [.send(PeerLanMsg(t: "accept")), .arm(Self.receiverInviteSeconds)]
        case .sender:
            confirmed = true
            return accepted ? [.makeInvite] : []
        }
    }

    // MARK: invite

    private mutating func inviteReady(_ raw: String) -> [Action] {
        guard role == .sender, phase == .checkCode, confirmed, accepted, let keys = theirKeys else { return [] }
        guard let inv = PeerInvite.parse(raw) else { return fail() }
        inviteSecret = inv.secret
        let body = (try? JSONSerialization.data(withJSONObject: ["invite": raw])) ?? Data()
        guard let env = PeerSeal.seal(payload: body, now: now(), from: me, to: keys, introduce: true) else { return fail() }
        phase = .awaitDone
        return [.send(PeerLanMsg(t: "invite", env: PeerB64.std(env))), .arm(Self.inviteSilenceSeconds)]
    }

    private mutating func receiverInvite(_ m: PeerLanMsg) -> [Action] {
        guard let keys = theirKeys, let env = m.env.flatMap(PeerB64.fromStd) else { return failWithDone("malformed") }
        switch PeerSeal.open(env, me: me, now: now(), pinned: { _ in nil }) {
        case .failure: return failWithDone("bad envelope")
        case .success(let o):
            guard o.sender == keys, PeerCrypto.mailboxId(signPub: keys.sign) == o.envelope.from else { return failWithDone("wrong sender") }
            guard abs(TimeInterval(o.envelope.ts) - now().timeIntervalSince1970) <= Self.inviteSkew else { return failWithDone("stale") }
            guard let obj = try? JSONSerialization.jsonObject(with: o.payload) as? [String: Any], let raw = obj["invite"] as? String,
                  let inv = PeerInvite.parse(raw), inv.keys == keys else { return failWithDone("invite mismatch") }
            return [.pair(raw: raw, name: theirName), .arm(nil)]
        }
    }

    private mutating func failWithDone(_ why: String) -> [Action] {
        [.send(PeerLanMsg(t: "done", ok: false, err: why))] + finish(.failed, close: true, cancelInvite: false)
    }

    private mutating func pairResult(ok: Bool, err: String?) -> [Action] {
        guard role == .receiver, phase == .awaitInvite else { return [] }
        if ok { return [.send(PeerLanMsg(t: "done", ok: true))] + finish(.paired, close: true, cancelInvite: false) }
        return failWithDone(err ?? "couldn't pair")
    }
}
