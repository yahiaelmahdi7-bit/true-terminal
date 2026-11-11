import Testing
import Foundation
@testable import True

/// G4+: join answers, doctor, mesh. Every Mac here is a PeerSide on the in-memory relay with its own temp home.
@Suite(.serialized) struct PeerDoctorTests {
    func join(_ side: PeerSide, _ code: String, name: String = "Bea") -> [String: Any] {
        PeerCLI.handle(["op": "join", "code": code, "name": name, "wait": 3.0], engine: side.engine)
    }

    @Test func joinWithOwnReusedOrExpiredCodeFailsInPlainWords() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock), c = PeerSide("Cy", relay: relay, clock: clock)
        defer { a.close(); b.close(); c.close() }
        // own
        let mine = a.engine.invite()
        let own = join(a, mine)
        print("own code      rc=\(own["ok"] as? Bool == true ? 0 : 1) \(own["error"] ?? own["message"] ?? "")")
        #expect(own["ok"] as? Bool == false && (own["error"] as? String)?.contains("yours") == true)
        // fine, then reused
        let code = b.engine.invite()
        let first = join(a, code)
        print("first join    rc=\(first["ok"] as? Bool == true ? 0 : 1) \(first["message"] ?? first["error"] ?? "")")
        #expect(first["ok"] as? Bool == true && first["paired"] as? Bool == true)
        let reused = join(c, code, name: "Bo")
        print("reused code   rc=\(reused["ok"] as? Bool == true ? 0 : 1) \(reused["error"] ?? reused["message"] ?? "")")
        #expect(reused["ok"] as? Bool == false && (reused["error"] as? String)?.contains("already used or has expired") == true)
        #expect(c.engine.peerLinks().isEmpty)                       // the waiting link was dropped
        // expired
        let old = b.engine.invite()
        clock.t = clock.t.addingTimeInterval(PeerEngine.inviteLife + 60)
        let expired = join(c, old, name: "Bo")
        print("expired code  rc=\(expired["ok"] as? Bool == true ? 0 : 1) \(expired["error"] ?? expired["message"] ?? "")")
        #expect(expired["ok"] as? Bool == false && (expired["error"] as? String)?.contains("already used or has expired") == true)
        // garbage
        let junk = join(c, "hello")
        #expect(junk["ok"] as? Bool == false && (junk["error"] as? String)?.contains("doesn't look like an invite") == true)
    }

    @Test func doctorShowsWaitingLinkAndFixtureDrops() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock)
        defer { a.close() }
        // a joined an invite whose owner never answers → "waiting for the other side"
        let ghost = PeerIdentity.generate()
        let inv = PeerInvite(mailboxId: ghost.mailboxId, kaPub: ghost.keys.ka, signPub: ghost.keys.sign, secret: PeerCrypto.randomBytes(16))
        _ = a.engine.pairWithInvite(inv.string, label: "Sam")
        let stamp = Int(clock.t.timeIntervalSince1970)
        try """
        \(stamp - 50) dropped: replay
        \(stamp - 40) dropped: unknown kind: caps
        \(stamp - 30) dropped: payload
        \(stamp - 20) dropped: signature
        \(stamp - 10) dropped: unknown sender
        \(stamp - 5) dropped: event payload

        """.write(to: a.root.appendingPathComponent("drops.log"), atomically: true, encoding: .utf8)
        let r = PeerCLI.handle(["op": "doctor"], engine: a.engine)
        let lines = try #require(r["lines"] as? [String])
        print(lines.joined(separator: "\n"))
        #expect(lines.contains { $0.hasPrefix("Sam: waiting for the other side") })
        #expect(lines.contains { $0.contains("unknown sender") } && lines.contains { $0.contains("event payload") })
        #expect(!lines.contains { $0.hasPrefix("  ") && $0.hasSuffix("replay") })           // only the last 5 are listed
        #expect(lines.contains { $0.contains("unknown kind: 1") || $0.contains("for an unknown kind of message: 1") })
    }

    @Test func anOlderTrueIsNamedWhenUnknownKindsAreDropped() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        a.engine.build = TrueBuild(commit: "aaaaaaa", date: "2026-10-20")
        b.engine.build = TrueBuild(commit: "bbbbbbb", date: "2026-11-03")
        try pairUp(a, b).get()
        settle(a, b)
        let body = try JSONSerialization.data(withJSONObject: ["t": "from-the-future"])
        a.engine.receive(try #require(PeerSeal.seal(payload: body, now: clock.t, from: b.identity, to: a.identity.keys)))
        let lines = a.engine.doctorLines()
        print(lines.joined(separator: "\n"))
        #expect(lines.contains { $0.contains("Their True: bbbbbbb, 2026-11-03") })
        #expect(lines.contains("This Mac's True is older than Bea's. Install the latest kit."))
        #expect(lines.contains { $0.contains("unknown kind: from-the-future") })
        #expect(lines.contains("Dropped for an unknown kind of message: 1."))
        #expect(a.engine.peerCaps(b.identity.mailboxId)?.buildCommit == "bbbbbbb")
    }

    @Test func aPeerWithNoStatusCardIsFlaggedAsPossiblyOld() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        try pairUp(a, b).get()
        a.engine.forgetCaps(b.identity.mailboxId)
        clock.t = clock.t.addingTimeInterval(3600)
        let lines = a.engine.doctorLines()
        #expect(lines.contains { $0.contains("hasn't sent a status card") })
        #expect(lines.contains { $0.contains("before 27 Oct") })
    }

    @Test func meshPrintsTheFullGridBothWays() throws {
        let relay = FakeRelay(), clock = Clock()
        let names = ["Al", "Bo", "Cy", "Di"]
        let s = names.map { PeerSide($0, relay: relay, clock: clock) }
        defer { s.forEach { $0.close() } }
        for i in 0..<4 { for j in (i + 1)..<4 { _ = s[i].engine.pairWithInvite(s[j].engine.invite(), label: names[j]); for x in s { settle(x) } } }
        for x in s { #expect(x.engine.peerLinks().filter { $0.confirmed }.count == 3) }
        let run = s[0].engine.meshStart()
        for _ in 0..<6 { settle(s[0], s[1], s[2], s[3]) }
        let (lines, done) = s[0].engine.meshReport(run)
        print(lines.joined(separator: "\n"))
        #expect(done)
        let grid = lines.prefix(5)
        #expect(grid.count == 5 && !lines.joined().contains("no answer") && !lines.joined().contains("not paired"))
        // 4 rows × 3 off-diagonal cells, each timed
        #expect(grid.dropFirst().allSatisfy { $0.components(separatedBy: " ms").count - 1 == 3 })
        #expect(lines.contains { $0.hasPrefix("Bo: answered") && $0.contains("Sees: ") })
        // nobody was asked to Accept, nothing launched
        for x in s { #expect(x.launcher.panes.isEmpty && x.engine.inboundJobs().isEmpty) }
    }

    @Test func meshSaysWhoDidNotAnswer() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        try pairUp(a, b).get()
        b.transport.setOnline(false)
        let r = PeerCLI.handle(["op": "mesh", "wait": 0.3], engine: a.engine)
        let lines = try #require(r["lines"] as? [String])
        print(lines.joined(separator: "\n"))
        #expect(lines.contains { $0.hasPrefix("Bea: no answer") })
    }

    @Test func noInviteCodeReachesAnyFileOrLog() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        let reply = PeerCLI.handle(["op": "invite"], engine: a.engine)
        let code = try #require(reply["code"] as? String)
        let parsed = try #require(PeerInvite.parse(code))
        let needles = [code, parsed.secret.base64EncodedString(), PeerB64.url(parsed.secret), PeerB64.std(parsed.secret)]
        _ = join(b, code)
        _ = join(b, code, name: "Again")
        settle(a, b)
        _ = a.engine.doctorLines(); _ = b.engine.doctorLines()
        for root in [a.root, b.root] {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for f in files {
                guard let d = try? Data(contentsOf: f), let text = String(data: d, encoding: .isoLatin1) else { continue }
                for n in needles { #expect(!text.contains(n), "\(f.lastPathComponent) holds an invite secret") }
            }
        }
    }
}
