import Testing
import Foundation
import CryptoKit
@testable import True

@Suite(.serialized) struct PeerCryptoTests {
    let a = PeerIdentity.generate(), b = PeerIdentity.generate()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = Data(#"{"t":"job","x":1}"#.utf8)

    func open(_ blob: Data, as me: PeerIdentity? = nil, at: Date? = nil) -> Result<PeerSeal.Opened, PeerSeal.Drop> {
        PeerSeal.open(blob, me: me ?? b, now: at ?? t0, pinned: { $0 == a.mailboxId ? a.keys : nil })
    }
    func sealed() -> Data { PeerSeal.seal(payload: payload, now: t0, from: a, to: b.keys)! }
    func tampered(_ f: (inout PeerEnvelope) -> Void) -> Data {
        var e = try! JSONDecoder().decode(PeerEnvelope.self, from: sealed()); f(&e)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; return try! enc.encode(e)
    }
    func dropOf(_ r: Result<PeerSeal.Opened, PeerSeal.Drop>) -> PeerSeal.Drop? { if case .failure(let d) = r { return d }; return nil }
    func rejected(_ d: Data) -> Bool { if case .failure = open(d) { return true }; return false }

    @Test func identityAndMailboxId() throws {
        #expect(a.mailboxId.count == 32 && a.mailboxId == a.mailboxId.lowercased())
        #expect(a.mailboxId == PeerCrypto.sha256Hex(a.keys.sign).prefix(32).description)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("true-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = PeerIdentity.loadOrCreate(root: dir), two = PeerIdentity.loadOrCreate(root: dir)
        #expect(one.mailboxId == two.mailboxId)
        let f = (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("identity.json").path))[.posixPermissions] as? NSNumber
        let d = (try FileManager.default.attributesOfItem(atPath: dir.path))[.posixPermissions] as? NSNumber
        #expect(f?.intValue == 0o600 && d?.intValue == 0o700)
    }

    @Test func envelopeRoundTrip() throws {
        let o = try open(sealed()).get()
        #expect(o.payload == payload && o.pinned && o.envelope.from == a.mailboxId && o.envelope.to == b.mailboxId)
        #expect(PeerSeal.seal(payload: Data(count: PeerSeal.maxBlob), now: t0, from: a, to: b.keys) == nil)   // too big
    }

    @Test func eachTamperedFieldIsRejected() {
        #expect(rejected(tampered { $0.ct = PeerB64.std(Data(repeating: 1, count: 40)) }))
        #expect(rejected(tampered { $0.sig = PeerB64.std(Data(repeating: 2, count: 64)) }))
        #expect(rejected(tampered { $0.from = b.mailboxId }))
        #expect(rejected(tampered { $0.to = a.mailboxId }))
        #expect(rejected(tampered { $0.ts += 1 }))
        #expect(rejected(tampered { $0.id = UUID().uuidString.lowercased() }))
        #expect(rejected(tampered { $0.sp = PeerB64.std(b.keys.sign) }))
        #expect(rejected(Data("not json".utf8)))
    }

    @Test func wrongRecipientAndWrongSenderKeys() {
        let c = PeerIdentity.generate()
        #expect(dropOf(open(sealed(), as: c)) == .wrongRecipient)
        // Pinned keys for `a` that are actually someone else's: signature fails.
        let wrong = PeerSeal.open(sealed(), me: b, now: t0, pinned: { _ in c.keys })
        #expect(dropOf(wrong) == .badSignature)
    }

    @Test func staleAndFutureTimestamps() {
        let old = PeerSeal.seal(payload: payload, now: t0.addingTimeInterval(-8 * 24 * 3600), from: a, to: b.keys)!
        #expect(dropOf(open(old)) == .stale)
        #expect({ if case .success = open(PeerSeal.seal(payload: payload, now: t0.addingTimeInterval(-6 * 24 * 3600), from: a, to: b.keys)!) { return true }; return false }())
        let future = PeerSeal.seal(payload: payload, now: t0.addingTimeInterval(10 * 60), from: a, to: b.keys)!
        #expect(dropOf(open(future)) == .stale)
    }

    @Test func unknownSenderOnlyWhenIntroduced() {
        let blob = sealed()
        #expect(dropOf(PeerSeal.open(blob, me: b, now: t0, pinned: { _ in nil })) == .unknownSender)
        let intro = PeerSeal.seal(payload: payload, now: t0, from: a, to: b.keys, introduce: true)!
        if case .success(let o) = PeerSeal.open(intro, me: b, now: t0, pinned: { _ in nil }) {
            #expect(!o.pinned && o.sender == a.keys)
        } else { Issue.record("introduced envelope should open") }
    }

    @Test func inviteFormatParseAndGarbage() throws {
        let secret = PeerCrypto.randomBytes(16)
        let inv = PeerInvite(mailboxId: a.mailboxId, kaPub: a.keys.ka, signPub: a.keys.sign, secret: secret)
        #expect(inv.string.hasPrefix("true-peer:v1:\(a.mailboxId).") && inv.string.split(separator: ".").count == 4)
        #expect(PeerInvite.parse(inv.string) == inv)
        #expect(PeerInvite.parse("  \(inv.string)\n") == inv)
        #expect(inv.keys == a.keys)
        for bad in ["", "garbage", "true-peer:v1:", "true-peer:v2:x.y.z.w", "true-peer:v1:\(a.mailboxId).a.b.c",
                    "true-peer:v1:\(b.mailboxId).\(PeerB64.url(a.keys.ka)).\(PeerB64.url(a.keys.sign)).\(PeerB64.url(secret))",   // id ≠ key
                    inv.string + ".extra", String(repeating: "a", count: 500)] {
            #expect(PeerInvite.parse(bad) == nil, "\(bad.prefix(40))")
        }
    }

    // MARK: pairing over the fake relay

    func tampered(invite s: String, secret: Data) -> String {
        let p = PeerInvite.parse(s)!
        return PeerInvite(mailboxId: p.mailboxId, kaPub: p.kaPub, signPub: p.signPub, secret: secret).string
    }

    @Test func pairingOk() throws {
        let relay = FakeRelay(), clock = Clock()
        let x = PeerSide("X", relay: relay, clock: clock), y = PeerSide("Y", relay: relay, clock: clock)
        defer { x.close(); y.close() }
        let link = try pairUp(x, y).get()
        #expect(link.keys == y.identity.keys)
        #expect(y.engine.peerLinks().map(\.mailboxId) == [x.identity.mailboxId] && y.engine.liveInviteCount() == 0)
    }

    @Test func wrongSecretExpiredAndReusedAreDroppedSilently() throws {
        let relay = FakeRelay(), clock = Clock()
        let inviter = PeerSide("I", relay: relay, clock: clock)
        let j1 = PeerSide("J1", relay: relay, clock: clock), j2 = PeerSide("J2", relay: relay, clock: clock)
        defer { inviter.close(); j1.close(); j2.close() }
        let inv = inviter.engine.invite()

        _ = j1.engine.pairWithInvite(tampered(invite: inv, secret: PeerCrypto.randomBytes(16)), label: "I")
        settle(inviter, j1)
        #expect(inviter.engine.peerLinks().isEmpty && inviter.engine.dropCount == 1)
        #expect(j1.engine.peerLinks().first?.confirmed == false)           // never confirmed

        _ = j1.engine.pairWithInvite(inv, label: "I"); settle(inviter, j1)  // the real one still works once
        #expect(inviter.engine.peerLinks().count == 1)
        _ = j2.engine.pairWithInvite(inv, label: "I"); settle(inviter, j2)  // reused
        #expect(inviter.engine.peerLinks().count == 1 && inviter.engine.dropCount == 2)

        let late = inviter.engine.invite()
        clock.t += PeerEngine.inviteLife + 60
        _ = j2.engine.pairWithInvite(late, label: "I"); settle(inviter, j2)  // expired
        #expect(inviter.engine.peerLinks().count == 1 && inviter.engine.dropCount == 3)
    }

    @Test func pinnedSendersPairRequestAndUnknownKindsAreDropped() throws {
        let relay = FakeRelay(), clock = Clock()
        let x = PeerSide("X", relay: relay, clock: clock), y = PeerSide("Y", relay: relay, clock: clock)
        defer { x.close(); y.close() }
        try pairUp(x, y).get()
        let before = y.engine.dropCount
        let body = try JSONSerialization.data(withJSONObject: ["t": "mystery"])
        y.engine.receive(PeerSeal.seal(payload: body, now: clock.now(), from: x.identity, to: y.identity.keys)!)
        #expect(y.engine.dropCount == before + 1)
        let stranger = PeerIdentity.generate()
        let job = craftedJob(from: stranger, to: y)
        y.engine.receive(job.blob)
        #expect(y.engine.dropCount == before + 2 && y.engine.inboundJobs().isEmpty)
    }
}
