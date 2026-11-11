import Testing
import Foundation
import CryptoKit
@testable import True

/// A snapshot builder: person "bea" (operator) owns the device whose peer key is `peerKey`; "owner" (owner) owns this Mac.
private func snapshotJSON(peerKey: String?, ownerSeed: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
                          level: String? = "work", revoked: Bool = false, expires: Double? = nil,
                          workspaces: [(String, String, String)] = [("w1", "repo", "github.com/acme/app")]) -> Data {
    var devices: [[String: Any]] = [["device": "mac-a", "person": "owner", "peer_key": NSNull(),
                                     "public_key": PeerB64.std(ownerSeed.publicKey.rawRepresentation)]]
    if let pk = peerKey { devices.append(["device": "mac-b", "person": "bea", "peer_key": pk, "public_key": "x"]) }
    var grants: [[String: Any]] = []
    if let level {
        let g: [String: Any] = ["id": "g1", "person": "bea", "workspace": workspaces.first?.0 ?? "w1", "level": level,
                                "expires": expires ?? NSNull(), "revoked_at": revoked ? 1.0 : NSNull()]
        grants.append(g)
    }
    let o: [String: Any] = ["fetched_at": 1_800_000_000, "device": "mac-a",
                            "persons": [["id": "owner", "role": "owner", "active": 1], ["id": "bea", "role": "operator", "active": 1]],
                            "devices": devices,
                            "workspaces": workspaces.map { ["id": $0.0, "kind": $0.1, "key": $0.2, "owner": "owner"] },
                            "grants": grants]
    return try! JSONSerialization.data(withJSONObject: o)
}

private func decode(_ d: Data) -> GrantSnapshot { try! JSONDecoder().decode(GrantSnapshot.self, from: d) }

private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString)") }

private final class FakeTransport: GrantTransport, @unchecked Sendable {
    let lock = NSLock()
    var body: Data? = nil          // nil = Steward unreachable
    var fetches = 0
    var notes: [(String, String)] = []
    func fetchSnapshot() throws -> Data { lock.lock(); defer { lock.unlock() }; fetches += 1; if let b = body { return b }; throw PeerError.invalid("down") }
    func postAuditNote(action: String, note: String) throws { lock.lock(); notes.append((action, note)); lock.unlock() }
    func streamEvents(since: String?, onEvent: @escaping @Sendable (SSEEvent) -> Void) throws { throw PeerError.invalid("no stream") }
}

@Suite(.serialized) struct GrantCacheTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: pure rules

    @Test func workAndAdminPassReadDoesNot() {
        let key = "PK1"
        for (level, ok) in [("work", true), ("admin", true), ("read", false)] {
            let v = GrantRules.check(decode(snapshotJSON(peerKey: key, level: level)), peerKey: key, target: .repo(testRepo), now: t0)
            #expect((v == .allow(person: "bea")) == ok, "\(level)")
            if !ok { #expect(v == .deny("Not allowed: no grant")) }
        }
    }

    @Test func expiredAndRevokedGrantsDenyEvenIfStillListed() {
        let key = "PK1"
        let expired = decode(snapshotJSON(peerKey: key, expires: t0.timeIntervalSince1970 - 1))
        #expect(GrantRules.check(expired, peerKey: key, target: .repo(testRepo), now: t0) == .deny("Not allowed: no grant"))
        let live = decode(snapshotJSON(peerKey: key, expires: t0.timeIntervalSince1970 + 60))
        #expect(GrantRules.check(live, peerKey: key, target: .repo(testRepo), now: t0) == .allow(person: "bea"))
        let revoked = decode(snapshotJSON(peerKey: key, revoked: true))
        #expect(GrantRules.check(revoked, peerKey: key, target: .repo(testRepo), now: t0) == .deny("Not allowed: no grant"))
        let none = decode(snapshotJSON(peerKey: key, level: nil))
        #expect(GrantRules.check(none, peerKey: key, target: .repo(testRepo), now: t0) == .deny("Not allowed: no grant"))
    }

    @Test func repoMatchesAcrossUrlSpellingsAndOtherRepoDenies() {
        let s = decode(snapshotJSON(peerKey: "PK1"))
        for url in ["https://github.com/acme/app.git", "git@github.com:acme/app.git", "ssh://git@GitHub.com/acme/app", "https://github.com/acme/app/"] {
            #expect(GrantRules.check(s, peerKey: "PK1", target: .repo(url), now: t0) == .allow(person: "bea"), "\(url)")
        }
        #expect(GrantRules.check(s, peerKey: "PK1", target: .repo("https://github.com/acme/other.git"), now: t0) == .deny("Not allowed: no grant"))
    }

    @Test func folderWorkspaceMatchesByRealPathPrefix() {
        let s = decode(snapshotJSON(peerKey: "PK1", workspaces: [("w1", "folder", "/work/site")]))
        let real: (String) -> String? = { $0 }
        #expect(GrantRules.check(s, peerKey: "PK1", target: .dir("/work/site"), now: t0, real: real) == .allow(person: "bea"))
        #expect(GrantRules.check(s, peerKey: "PK1", target: .dir("/work/site/sub/x"), now: t0, real: real) == .allow(person: "bea"))
        #expect(GrantRules.check(s, peerKey: "PK1", target: .dir("/work/site2"), now: t0, real: real) == .deny("Not allowed: no grant"))
        #expect(GrantRules.check(s, peerKey: "PK1", target: .dir("/work"), now: t0, real: real) == .deny("Not allowed: no grant"))
        // a repo job never matches a folder workspace
        #expect(GrantRules.check(s, peerKey: "PK1", target: .repo(testRepo), now: t0, real: real) == .deny("Not allowed: no grant"))
    }

    @Test func unmappedKeyIsNotInTheGroupAndScratchIsAllowedForMapped() {
        let s = decode(snapshotJSON(peerKey: "PK1"))
        #expect(GrantRules.check(s, peerKey: "OTHER", target: .repo(testRepo), now: t0) == .deny("Peer not in the group"))
        #expect(GrantRules.check(s, peerKey: "OTHER", target: .scratch, now: t0) == .deny("Peer not in the group"))
        #expect(GrantRules.check(s, peerKey: "PK1", target: .scratch, now: t0) == .allow(person: "bea"))
    }

    // MARK: cache: stale rule, persistence, switch

    @Test func offByDefaultNeverRefuses() {
        let c = GrantCache(dir: tmp(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        #expect(c.refusal(peerKey: "x", target: .repo(testRepo)) == nil)
    }

    @Test func staleRuleBoundaryAndMessage() {
        let clock = Clock()
        let c = GrantCache(dir: tmp(), now: { clock.now() })
        c.setEnforce(true)
        #expect(c.apply(snapshotJSON(peerKey: "PK1")))
        #expect(c.refusal(peerKey: "PK1", target: .repo(testRepo)) == nil)
        clock.t = t0.addingTimeInterval(15 * 60)                    // exactly 15 min: still fresh
        #expect(c.refusal(peerKey: "PK1", target: .repo(testRepo)) == nil)
        clock.t = t0.addingTimeInterval(15 * 60 + 1)
        c.noteFailure()
        let why = c.refusal(peerKey: "PK1", target: .repo(testRepo))
        #expect(why == GrantRules.stale(since: t0))
        #expect(why?.hasPrefix("Grants stale, Steward unreachable since ") == true)
        #expect(why?.range(of: #"since \d\d:\d\d$"#, options: .regularExpression) != nil)
        // Steward back: fresh again
        #expect(c.apply(snapshotJSON(peerKey: "PK1")))
        #expect(c.refusal(peerKey: "PK1", target: .repo(testRepo)) == nil)
    }

    @Test func enforcingWithNoSnapshotEverIsStale() {
        let c = GrantCache(dir: tmp(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        c.setEnforce(true)
        #expect(c.refusal(peerKey: "PK1", target: .repo(testRepo))?.hasPrefix("Grants stale") == true)
    }

    @Test func snapshotAndSwitchSurviveARestart() {
        let dir = tmp(), clock = Clock()
        let a = GrantCache(dir: dir, now: { clock.now() })
        a.setEnforce(true); _ = a.apply(snapshotJSON(peerKey: "PK1"))
        let b = GrantCache(dir: dir, now: { clock.now() })
        #expect(b.isEnforcing && b.snapshot != nil)
        #expect(b.refusal(peerKey: "PK1", target: .repo(testRepo)) == nil)          // known, not "unknown"
        #expect(b.refusal(peerKey: "NOPE", target: .repo(testRepo)) == "Peer not in the group")
        for f in ["grants.json", "group-enforce.json"] {
            let perm = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f).path))?[.posixPermissions] as? NSNumber
            #expect(perm?.intValue == 0o600, "\(f)")
        }
    }

    @Test func badBodyKeepsTheOldSnapshot() {
        let c = GrantCache(dir: tmp(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = c.apply(snapshotJSON(peerKey: "PK1"))
        #expect(!c.apply(Data("not json".utf8)))
        #expect(c.snapshot?.devices.count == 2)
    }

    // MARK: offline allowance

    @Test func offlineAllowanceNeedsTheOwnerKey() {
        let clock = Clock(), seed = Curve25519.Signing.PrivateKey()
        let c = GrantCache(dir: tmp(), now: { clock.now() })
        c.setEnforce(true)
        if case .success = c.allowOffline(for: 7200, signingKey: PeerB64.std(seed.rawRepresentation)) { Issue.record("no snapshot yet") }
        _ = c.apply(snapshotJSON(peerKey: "PK1", ownerSeed: seed))
        // wrong key
        if case .success = c.allowOffline(for: 7200, signingKey: PeerB64.std(Curve25519.Signing.PrivateKey().rawRepresentation)) { Issue.record("wrong key accepted") }
        if case .success = c.allowOffline(for: 7200, signingKey: "") { Issue.record("empty key accepted") }
        if case .success = c.allowOffline(for: 25 * 3600, signingKey: PeerB64.std(seed.rawRepresentation)) { Issue.record("over 24h accepted") }
        #expect(c.offlineUntil == nil)
        guard case .success(let until) = c.allowOffline(for: 7200, signingKey: PeerB64.std(seed.rawRepresentation)) else { Issue.record("owner refused"); return }
        #expect(until == t0.addingTimeInterval(7200))
        // 1 h later with Steward unreachable: stale rule waived, grant rules still apply
        clock.t = t0.addingTimeInterval(3600)
        #expect(c.refusal(peerKey: "PK1", target: .repo(testRepo)) == nil)
        #expect(c.refusal(peerKey: "NOPE", target: .repo(testRepo)) == "Peer not in the group")
        // allowance over
        clock.t = t0.addingTimeInterval(7201)
        #expect(c.offlineUntil == nil)
        #expect(c.refusal(peerKey: "PK1", target: .repo(testRepo))?.hasPrefix("Grants stale") == true)
    }

    @Test func offlineAllowanceRefusedWhenTheDeviceIsNotAnOwner() throws {
        let seed = Curve25519.Signing.PrivateKey()
        var o = try JSONSerialization.jsonObject(with: snapshotJSON(peerKey: "PK1", ownerSeed: seed)) as! [String: Any]
        o["persons"] = [["id": "owner", "role": "operator", "active": 1], ["id": "bea", "role": "operator", "active": 1]]
        let c = GrantCache(dir: tmp(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = c.apply(try JSONSerialization.data(withJSONObject: o))
        if case .success = c.allowOffline(for: 3600, signingKey: PeerB64.std(seed.rawRepresentation)) { Issue.record("non-owner accepted") }
    }

    @Test func offlineAllowanceSurvivesRestartOnlyIfItVerifies() throws {
        let dir = tmp(), seed = Curve25519.Signing.PrivateKey()
        let a = GrantCache(dir: dir, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = a.apply(snapshotJSON(peerKey: "PK1", ownerSeed: seed))
        guard case .success = a.allowOffline(for: 3600, signingKey: PeerB64.std(seed.rawRepresentation)) else { Issue.record("refused"); return }
        #expect(GrantCache(dir: dir, now: { Date(timeIntervalSince1970: 1_800_000_000) }).offlineUntil != nil)
        // forge: hand-edit the file to extend it
        let f = dir.appendingPathComponent("group-enforce.json")
        var st = try JSONDecoder().decode(GrantLocalState.self, from: Data(contentsOf: f))
        st.allow?.until += 86400
        try JSONEncoder().encode(st).write(to: f)
        #expect(GrantCache(dir: dir, now: { Date(timeIntervalSince1970: 1_800_000_000) }).offlineUntil == nil)
    }

    // MARK: sync

    @Test func refreshAppliesFailsAndFlushesAuditNotesOnTheNextSuccess() {
        let clock = Clock(), seed = Curve25519.Signing.PrivateKey(), tr = FakeTransport()
        let c = GrantCache(dir: tmp(), now: { clock.now() })
        let sync = GrantSync(cache: c, transport: tr, scheduler: { _, _ in }, runner: { $0() })
        tr.body = snapshotJSON(peerKey: "PK1", ownerSeed: seed)
        sync.refresh()
        #expect(c.snapshot != nil)
        c.setEnforce(true)
        _ = c.allowOffline(for: 3600, signingKey: PeerB64.std(seed.rawRepresentation))
        tr.body = nil
        sync.refresh()                                                  // Steward down: notes stay queued
        #expect(tr.notes.isEmpty && c.pendingNotes().count == 2)
        tr.body = snapshotJSON(peerKey: "PK1", ownerSeed: seed)
        sync.refresh()
        #expect(tr.notes.map(\.0) == ["enforce.on", "enforce.offline-allow"])
        #expect(c.pendingNotes().isEmpty)
    }

    @Test func groupsChangedRefetchesAndOtherEventsDoNot() {
        let tr = FakeTransport(); tr.body = snapshotJSON(peerKey: "PK1")
        let c = GrantCache(dir: tmp(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let sync = GrantSync(cache: c, transport: tr, scheduler: { _, _ in }, runner: { $0() })
        sync.handleEvent("audit.row"); #expect(tr.fetches == 0)
        sync.handleEvent("grants.changed"); #expect(tr.fetches == 1)
        sync.handleEvent("grants.changed"); #expect(tr.fetches == 2)
    }

    @Test func aBurstOfEventsCollapsesIntoOneRefetch() {
        let tr = FakeTransport(); tr.body = snapshotJSON(peerKey: "PK1")
        let c = GrantCache(dir: tmp(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        final class Held: @unchecked Sendable { var jobs: [@Sendable () -> Void] = [] }
        let held = Held()
        let sync = GrantSync(cache: c, transport: tr, scheduler: { _, _ in }, runner: { held.jobs.append($0) })
        for _ in 0..<50 { sync.handleEvent("grants.changed") }
        #expect(held.jobs.count == 1)
        held.jobs.forEach { $0() }
        #expect(tr.fetches == 1)
    }

    @Test func pollRefetchesEveryFortyFiveSeconds() {
        final class Sched: @unchecked Sendable { var next: (@Sendable () -> Void)?; var delay: TimeInterval = 0 }
        let sch = Sched(), tr = FakeTransport(); tr.body = snapshotJSON(peerKey: "PK1")
        let c = GrantCache(dir: tmp(), now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let sync = GrantSync(cache: c, transport: tr, scheduler: { d, f in sch.delay = d; sch.next = f }, runner: { $0() })
        sync.start(); defer { sync.stop() }
        #expect(sch.delay == 45)
        let before = tr.fetches
        sch.next?()
        #expect(tr.fetches == before + 1)
    }

    @Test func sseKindsParsesEventFields() {
        var p = SSEKinds()
        var got: [String] = []
        for line in ["id: 4", "event: grants.changed", "data: {}", "", ": keepalive", "", "event: other", "data: 1", ""] {
            if let k = p.feed(line) { got.append(k) }
        }
        #expect(got == ["grants.changed", "other"])
    }
}

// MARK: - engine level (a real PeerEngine receiving a real sealed job)

@Suite(.serialized) struct GrantEngineTests {
    func rig(on: Bool = true, level: String? = "work") -> (a: PeerSide, b: PeerSide, clock: Clock) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        b.engine.grants.setEnforce(on)
        let aKey = PeerB64.std(a.identity.keys.sign)
        _ = b.engine.grants.apply(snapshotJSON(peerKey: aKey, level: level))
        return (a, b, clock)
    }
    func send(_ a: PeerSide, _ b: PeerSide) -> String? {
        guard case .success(let id) = a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "do it", mode: .pane, fromAgent: "lead") else { return nil }
        settle(a, b); return id
    }

    @Test func grantsOffIsTodaysBehaviour() throws {
        let r = rig(on: false, level: nil); defer { r.a.close(); r.b.close() }
        let id = try #require(send(r.a, r.b))
        #expect(r.b.launcher.panes.count == 1)
        #expect(r.a.engine.status(jobId: id).first?.status == .accepted)
    }

    @Test func grantedJobRuns() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        _ = try #require(send(r.a, r.b))
        #expect(r.b.launcher.panes.count == 1)
    }

    @Test func revokedGrantRefusesWithPlainReasonAndRegrantRuns() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let aKey = PeerB64.std(r.a.identity.keys.sign)
        _ = r.b.engine.grants.apply(snapshotJSON(peerKey: aKey, level: nil))          // revoked: gone from the snapshot
        let id = try #require(send(r.a, r.b))
        #expect(r.b.launcher.panes.isEmpty)
        let job = try #require(r.b.engine.inboundJobs().first)
        #expect(job.status == .declined && job.note == "Not allowed: no grant")
        #expect(r.a.engine.status(jobId: id).first?.status == .failed)
        _ = r.b.engine.grants.apply(snapshotJSON(peerKey: aKey, level: "work"))       // re-granted
        _ = try #require(send(r.a, r.b))
        #expect(r.b.launcher.panes.count == 1)
    }

    @Test func unknownPeerKeyIsNotInTheGroup() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        _ = r.b.engine.grants.apply(snapshotJSON(peerKey: "SOMEONE-ELSE"))
        _ = try #require(send(r.a, r.b))
        #expect(r.b.launcher.panes.isEmpty)
        #expect(r.b.engine.inboundJobs().first?.note == "Peer not in the group")
    }

    @Test func staleRefusesNewJobsWhileARunningJobIsUntouched() throws {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let first = try #require(send(r.a, r.b))                                    // running before Steward goes away
        #expect(r.b.launcher.panes.count == 1)
        r.clock.t = r.clock.t.addingTimeInterval(16 * 60)
        r.b.engine.grants.noteFailure()
        let second = try #require(send(r.a, r.b))
        let jobs = r.b.engine.inboundJobs()
        #expect(jobs.count == 2)
        let refused = try #require(jobs.first { $0.id == second })
        #expect(refused.status == .declined && refused.note.hasPrefix("Grants stale, Steward unreachable since "))
        #expect(r.b.launcher.panes.count == 1 && r.b.launcher.stopped.0.isEmpty)    // the running one was not stopped
        let running = try #require(jobs.first { $0.id == first })
        #expect(!running.status.isFinal)
        r.b.engine.paneEvent(pane: r.b.launcher.pane, kind: .progress); settle(r.a, r.b)
        #expect(r.a.engine.status(jobId: first).first?.status == .working)         // and it still reports
    }

    @Test func revocationWhileQueuedStopsTheJobAtAccept() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock, mode: .ask)
        defer { a.close(); b.close() }
        pairUp(a, b)
        b.engine.grants.setEnforce(true)
        let aKey = PeerB64.std(a.identity.keys.sign)
        _ = b.engine.grants.apply(snapshotJSON(peerKey: aKey))
        let id = try #require(send(a, b))
        #expect(b.engine.inboundJobs().first?.status == .queued)
        _ = b.engine.grants.apply(snapshotJSON(peerKey: aKey, level: nil))
        b.engine.accept(id); settle(a, b)
        #expect(b.launcher.panes.isEmpty)
        #expect(b.engine.inboundJobs().first?.note == "Not allowed: no grant")
    }
}
