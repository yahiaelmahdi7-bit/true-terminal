import Testing
import Foundation
@testable import True

/// Two handshake machines wired back to back, each acting on its own real (temp) engine.
final class Duo {
    typealias M = PeerLanHandshake
    let relay = FakeRelay(), clock = Clock()
    let s: PeerSide, r: PeerSide
    var sm: M, rm: M
    var toR: [Data] = [], toS: [Data] = []
    var sOut: [M.Action] = [], rOut: [M.Action] = []
    var sPrompt: (String, String)?, rPrompt: (String, String)?
    var sOutcome: PeerLanOutcome?, rOutcome: PeerLanOutcome?
    var rPairFails = false
    var sSecret: Data?
    var tamperToR: ((PeerLanMsg) -> PeerLanMsg?)?
    var rDoneErr: String?

    init(sName: String = "Sol", rName: String = "Rae", rExisting: String? = nil) {
        s = PeerSide(sName, relay: relay, clock: clock); r = PeerSide(rName, relay: relay, clock: clock)
        let c = clock
        sm = M(role: .sender, me: s.identity, ownName: sName, now: { c.now() })
        rm = M(role: .receiver, me: r.identity, ownName: rName, now: { c.now() })
        if let rExisting { // R already has a peer with that label
            let other = PeerSide("Third", relay: relay, clock: clock)
            _ = r.engine.pairWithInvite(other.engine.invite(), label: rExisting)
            other.engine.drain()
        }
    }
    func close() { s.close(); r.close() }

    func feedS(_ e: M.Event) { run(sm.handle(e), side: .sender) }
    func feedR(_ e: M.Event) { run(rm.handle(e), side: .receiver) }

    private func run(_ acts: [M.Action], side: M.Role) {
        for a in acts {
            if side == .sender { sOut.append(a) } else { rOut.append(a) }
            switch a {
            case .send(let m):
                if side == .sender { if let t = tamperToR.map({ $0(m) }) ?? m { toR.append(t.data()) } } else {
                    if m.t == "done" { rDoneErr = m.err }
                    toS.append(m.data())
                }
            case .makeInvite:
                let raw = s.engine.invite(); sSecret = PeerInvite.parse(raw)?.secret
                feedS(.inviteReady(raw))
            case .pair(let raw, let name):
                if rPairFails { feedR(.pairResult(ok: false, err: "nope")); break }
                let label = PeerLanLabel.safe(name, existing: r.engine.peerLinks().map(\.label))
                switch r.engine.pairWithInvite(raw, label: label) {
                case .success: feedR(.pairResult(ok: true, err: nil))
                case .failure(let e): feedR(.pairResult(ok: false, err: "\(e)"))
                }
            case .cancelInvite(let sec): s.engine.cancelInvite(sec)
            case .prompt(let c, let n): if side == .sender { sPrompt = (c, n) } else { rPrompt = (c, n) }
            case .finished(let o): if side == .sender { sOutcome = o } else { rOutcome = o }
            case .close, .arm: break
            }
        }
    }

    func pump() {
        var n = 0
        while (!toR.isEmpty || !toS.isEmpty) && n < 200 {
            if !toR.isEmpty { feedR(.frame(toR.removeFirst())) }
            if !toS.isEmpty { feedS(.frame(toS.removeFirst())) }
            n += 1
        }
    }
    /// S begins; both prompts appear.
    func toPrompts() { feedR(.begin); feedS(.begin); pump() }
}

@Suite(.serialized) struct PeerLanHandshakeTests {
    @Test func codeIsIdenticalOnBothSides() throws {
        let d = Duo(); defer { d.close() }
        d.toPrompts()
        let sp = try #require(d.sPrompt), rp = try #require(d.rPrompt)
        #expect(sp.0 == rp.0 && sp.0.count == 6 && sp.0.allSatisfy(\.isNumber))
        #expect(sp.1 == "Rae" && rp.1 == "Sol")
        #expect(d.sm.code == d.rm.code)
    }

    @Test func codeDiffersWhenAnyKeyOrNonceDiffers() {
        let k1 = PeerIdentity.generate().keys.sign, k2 = PeerIdentity.generate().keys.sign, k3 = PeerIdentity.generate().keys.sign
        let n1 = PeerCrypto.randomBytes(16), n2 = PeerCrypto.randomBytes(16), n3 = PeerCrypto.randomBytes(16)
        let base = PeerLanHandshake.code(sSign: k1, rSign: k2, nS: n1, nR: n2)
        #expect(base == PeerLanHandshake.code(sSign: k1, rSign: k2, nS: n1, nR: n2))
        #expect(base != PeerLanHandshake.code(sSign: k3, rSign: k2, nS: n1, nR: n2))
        #expect(base != PeerLanHandshake.code(sSign: k1, rSign: k3, nS: n1, nR: n2))
        #expect(base != PeerLanHandshake.code(sSign: k1, rSign: k2, nS: n3, nR: n2))
        #expect(base != PeerLanHandshake.code(sSign: k1, rSign: k2, nS: n1, nR: n3))
    }

    @Test func codeIsZeroPaddedToSixDigits() {
        let a = PeerCrypto.randomBytes(32), b = PeerCrypto.randomBytes(32)
        var found: String?
        for _ in 0..<200_000 {
            let c = PeerLanHandshake.code(sSign: a, rSign: b, nS: PeerCrypto.randomBytes(16), nR: PeerCrypto.randomBytes(16))
            #expect(c.count == 6)
            if c.hasPrefix("000") { found = c; break }
        }
        #expect(found != nil)
        #expect(PeerLanHandshake.spaced("000042") == "000 042" && PeerLanHandshake.spaced("482913") == "482 913")
    }

    @Test func revealNotMatchingCommitCloses() {
        let d = Duo(); defer { d.close() }
        d.tamperToR = { m in var x = m; if x.t == "reveal" { x.nS = PeerB64.std(PeerCrypto.randomBytes(16)) }; return x }
        d.toPrompts()
        #expect(d.rOutcome == .failed && d.rPrompt == nil)
        #expect(d.rOut.contains(.close))
        #expect(d.s.engine.liveInviteCount() == 0)
    }

    @Test func badHelloIsRejected() {
        let d = Duo(); defer { d.close() }
        d.feedR(.begin)
        d.feedR(.frame(PeerLanMsg(t: "hello", v: 2, name: "X").data()))
        #expect(d.rOutcome == .failed)
        let e = Duo(); defer { e.close() }
        e.feedR(.begin); e.feedR(.frame(Data("not json".utf8)))
        #expect(e.rOutcome == .failed)
    }

    @Test func wrongFrameForTheStateClosesIt() {
        let d = Duo(); defer { d.close() }
        d.feedR(.begin)
        d.feedR(.frame(PeerLanMsg(t: "invite", env: "AAAA").data()))
        #expect(d.rOutcome == .failed)
    }

    @Test func happyPathPairsAndAcceptingOrderDoesNotMatter() {
        for senderFirst in [true, false] {
            let d = Duo(); defer { d.close() }
            d.toPrompts()
            if senderFirst { d.feedS(.userConfirm); d.pump(); #expect(d.sm.waitingForAccept); d.feedR(.userConfirm) }
            else { d.feedR(.userConfirm); d.pump(); d.feedS(.userConfirm) }
            d.pump(); d.s.engine.drain(); d.r.engine.drain()
            #expect(d.rOutcome == .paired && d.sOutcome == .paired)
            #expect(d.r.engine.peerLinks().first?.label == "Sol")
            #expect(d.sSecret != nil)
        }
    }

    @Test func declineCancelAndTimeoutsCreateNoInvite() {
        // Receiver declines (userCancel) → sender hears bye
        var d = Duo()
        d.toPrompts(); d.feedR(.userCancel); d.pump()
        #expect(d.sOutcome == .declined && d.rOutcome == .cancelled && d.s.engine.liveInviteCount() == 0)
        d.close()
        // Sender cancels
        d = Duo(); d.toPrompts(); d.feedS(.userConfirm); d.feedS(.userCancel); d.pump()
        #expect(d.rOutcome == .cancelled && d.s.engine.liveInviteCount() == 0)
        d.close()
        // Receiver's 90 s prompt timer
        d = Duo(); d.toPrompts(); d.feedR(.timeout); d.pump()
        #expect(d.rOutcome == .timedOut && d.sOutcome != nil && d.s.engine.liveInviteCount() == 0)
        d.close()
        // Sender's 120 s timer
        d = Duo(); d.toPrompts(); d.feedS(.timeout); d.pump()
        #expect(d.sOutcome == .timedOut && d.rOutcome != nil && d.s.engine.liveInviteCount() == 0)
        d.close()
        // Silence waiting for the other hello
        d = Duo(); d.feedS(.begin); d.feedS(.timeout)
        #expect(d.sOutcome == .timedOut)
        d.close()
    }

    @Test func busyByeReadsAsBusy() {
        let d = Duo(); defer { d.close() }
        d.feedS(.begin)
        d.feedS(.frame(PeerLanMsg(t: "bye", reason: "busy").data()))
        #expect(d.sOutcome == .busy)
    }

    // MARK: the invite envelope

    /// Drive to the point where R has accepted and waits for the invite; return a fresh invite from `from` addressed to R.
    private func rReady(_ d: Duo) { d.toPrompts(); d.feedR(.userConfirm); d.pump() }

    private func envFrame(_ d: Duo, from: PeerIdentity, introduce: Bool = true, inviteOf: PeerSide? = nil, ts: Date? = nil) -> Data {
        let inv = (inviteOf ?? d.s).engine.invite()
        let body = try! JSONSerialization.data(withJSONObject: ["invite": inv])
        let env = PeerSeal.seal(payload: body, now: ts ?? d.clock.now(), from: from, to: d.r.identity.keys, introduce: introduce)!
        return PeerLanMsg(t: "invite", env: PeerB64.std(env)).data()
    }

    @Test func envelopeFromTheWrongKeyIsRefused() {
        let d = Duo(); defer { d.close() }
        rReady(d)
        d.feedR(.frame(envFrame(d, from: PeerIdentity.generate())))   // sealed by a stranger, invite is S's
        #expect(d.rOutcome == .failed && d.rDoneErr != nil && d.r.engine.peerLinks().isEmpty)
    }

    @Test func inviteWhoseKeysDifferFromTheHelloIsRefused() {
        let d = Duo(); defer { d.close() }
        rReady(d)
        let other = PeerSide("Other", relay: d.relay, clock: d.clock); defer { other.close() }
        d.feedR(.frame(envFrame(d, from: d.s.identity, inviteOf: other)))   // right sender, someone else's invite
        #expect(d.rOutcome == .failed && d.rDoneErr == "invite mismatch" && d.r.engine.peerLinks().isEmpty)
    }

    @Test func staleEnvelopeIsRefused() {
        let d = Duo(); defer { d.close() }
        rReady(d)
        d.feedR(.frame(envFrame(d, from: d.s.identity, ts: d.clock.now().addingTimeInterval(-600))))
        #expect(d.rOutcome == .failed && d.rDoneErr == "stale" && d.r.engine.peerLinks().isEmpty)
    }

    @Test func envelopeWithoutIntroductionIsRefused() {
        let d = Duo(); defer { d.close() }
        rReady(d)
        d.feedR(.frame(envFrame(d, from: d.s.identity, introduce: false)))
        #expect(d.rOutcome == .failed && d.r.engine.peerLinks().isEmpty)
    }

    @Test func wrongFromIsRefused() throws {
        let d = Duo(); defer { d.close() }
        rReady(d)
        // Re-wrap a good envelope with a different `from`: the signature no longer covers it.
        let m = try JSONDecoder().decode(PeerLanMsg.self, from: envFrame(d, from: d.s.identity))
        var env = try JSONDecoder().decode(PeerEnvelope.self, from: PeerB64.fromStd(m.env!)!)
        env.from = PeerIdentity.generate().mailboxId
        let bad = PeerLanMsg(t: "invite", env: PeerB64.std(try JSONEncoder().encode(env)))
        d.feedR(.frame(bad.data()))
        #expect(d.rOutcome == .failed && d.r.engine.peerLinks().isEmpty)
    }

    // MARK: cancel paths after the invite exists

    @Test func pairFailureSendsDoneErrAndSenderCancelsTheInvite() {
        let d = Duo(); defer { d.close() }
        d.rPairFails = true
        d.toPrompts(); d.feedR(.userConfirm); d.feedS(.userConfirm); d.pump()
        #expect(d.rOutcome == .failed && d.rDoneErr == "nope")
        #expect(d.sOutcome == .failed)
        #expect(d.s.engine.liveInviteCount() == 0 && !d.s.engine.wantsRelay)
        #expect(d.r.engine.peerLinks().isEmpty)
    }

    @Test func connectionLostAfterTheInviteCancelsIt() {
        let d = Duo(); defer { d.close() }
        d.toPrompts(); d.feedR(.userConfirm); d.pump()
        d.feedS(.userConfirm)                               // S sends the invite; do not deliver it
        #expect(d.s.engine.liveInviteCount() == 1)
        d.feedS(.connectionLost)
        #expect(d.sOutcome == .failed && d.s.engine.liveInviteCount() == 0)
    }

    @Test func silenceAfterTheInviteCancelsIt() {
        let d = Duo(); defer { d.close() }
        d.toPrompts(); d.feedR(.userConfirm); d.pump()
        d.feedS(.userConfirm)
        #expect(d.s.engine.liveInviteCount() == 1)
        d.feedS(.timeout)
        #expect(d.sOutcome == .timedOut && d.s.engine.liveInviteCount() == 0)
    }

    @Test func windowCloseMidHandshakeSaysByeAndStops() {
        let d = Duo(); defer { d.close() }
        d.toPrompts()
        d.feedR(.windowClosed)
        #expect(d.rOut.contains(.send(PeerLanMsg(t: "bye", reason: "closed"))) && d.rOut.contains(.close) && d.rOutcome == .cancelled)
        d.pump()
        #expect(d.sOutcome == .cancelled)
    }

    // MARK: labels

    @Test func hostileNamesBecomePeerAndCollisionsGetASuffix() {
        #expect(PeerLanLabel.safe("Bob\nEvil", existing: []) == "Peer")
        #expect(PeerLanLabel.safe(String(repeating: "x", count: 80), existing: []) == "Peer")
        #expect(PeerLanLabel.safe("Bea", existing: ["bea"]) == "Bea 2")
        #expect(PeerLanLabel.safe("Bea", existing: ["Bea", "Bea 2"]) == "Bea 3")
    }

    @Test func labelCollisionLeavesTheExistingPeerAlone() {
        let d = Duo(sName: "Sol", rName: "Rae", rExisting: "Sol"); defer { d.close() }
        let before = d.r.engine.peerLinks()
        d.toPrompts(); d.feedR(.userConfirm); d.feedS(.userConfirm); d.pump(); d.r.engine.drain()
        let after = d.r.engine.peerLinks()
        #expect(after.count == before.count + 1 && Set(after.map(\.label)) == ["Sol", "Sol 2"])
        #expect(after.first { $0.label == "Sol" }?.mailboxId == before.first?.mailboxId)
    }
}
