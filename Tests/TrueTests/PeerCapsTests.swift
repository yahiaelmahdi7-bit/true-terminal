import Testing
import Foundation
@testable import True

/// Run 36a step 2 (A1 + A2): caps announced, persisted and reloaded; unknown peers wait then "need the update"; own-path guard.
@Suite(.serialized) struct PeerCapsTests {
    func rig() -> (a: PeerSide, b: PeerSide, clock: Clock) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        return (a, b, clock)
    }

    @Test func capsExchangedOnPairing() throws {
        let (a, b, _) = rig(); defer { a.close(); b.close() }
        let bea = try #require(a.engine.peerLinks().first)
        let c = try #require(a.engine.peerCaps(bea.mailboxId))
        #expect(c.features.contains("watch"))
        #expect(c.home == NSHomeDirectory())
        #expect(a.engine.capsState(mailbox: bea.mailboxId, feature: "watch") == .yes)
        #expect(a.engine.capsState(mailbox: bea.mailboxId, feature: "files") == .no)
        #expect(b.engine.peerLinks().first.flatMap { b.engine.peerCaps($0.mailboxId) } != nil)
    }

    @Test func connectedCardRefreshesBeforeItCanGoStaleWithoutChangingJobs() throws {
        let (a, b, clock) = rig(); defer { a.close(); b.close() }
        let id = try a.engine.delegate(peer: "Bea", repo: testRepo, title: "Work", brief: "x", mode: .pane).get()
        settle(a, b)
        let before = b.engine.inboundJobs()
        for _ in 0..<5 {
            clock.t = clock.t.addingTimeInterval(PeerCaps.staleAfter / 2)
            a.delays.fireDue(clock); b.delays.fireDue(clock); settle(a, b)
            let card = try #require(a.engine.peerCaps(b.identity.mailboxId))
            #expect(!card.isStale(at: clock.now()) && card.updated == clock.now())
        }
        #expect(b.engine.inboundJobs() == before && a.engine.result(jobId: id)?.status == .accepted)
        if case .failure(.invalid(let reason)) = a.engine.delegate(peer: "Bea", repo: "https://github.com/acme/missing", title: "Missing", brief: "x", mode: .pane) {
            #expect(reason.contains("true-peer offer"))
        } else { Issue.record("A fresh Card must refuse a missing clone") }
    }

    @Test func cloneAndCardFieldChangesAreAnnouncedAndOfflineRefreshStops() throws {
        let (a, b, clock) = rig(); defer { a.close(); b.close() }
        b.knobs.lanes = 3
        b.launcher.remotes.append("https://github.com/acme/new.git")
        clock.t = clock.t.addingTimeInterval(PeerCaps.staleAfter / 2)
        b.delays.fireDue(clock); settle(a, b)
        let card = try #require(a.engine.peerCaps(b.identity.mailboxId))
        #expect(card.repos.contains(try #require(PeerRepo.hash("https://github.com/acme/new"))))
        #expect(card.lanesTotal == 3)
        let scans = b.launcher.cloneRemoteCalls
        b.transport.setOnline(false); settle(a, b)
        let before = a.engine.peerCaps(b.identity.mailboxId)?.updated
        clock.t = clock.t.addingTimeInterval(600); b.delays.fireDue(clock); settle(a, b)
        #expect(a.engine.peerCaps(b.identity.mailboxId)?.updated == before)
        #expect(b.launcher.cloneRemoteCalls == scans)
        b.transport.setOnline(true); settle(a, b)
        #expect(b.launcher.cloneRemoteCalls == scans + 1)
        #expect(a.engine.peerCaps(b.identity.mailboxId)?.updated == clock.now())
    }

    @Test func aCardChangeDoesNotPostponeTheHeartbeat() throws {
        let (a, b, clock) = rig(); defer { a.close(); b.close() }
        clock.t = clock.t.addingTimeInterval(PeerCaps.staleAfter / 2 - 1)
        b.engine.home = "/Users/new-home"; settle(a, b)
        #expect(a.engine.peerCaps(b.identity.mailboxId)?.updated == clock.now())
        clock.t = clock.t.addingTimeInterval(1)
        b.delays.fireDue(clock); settle(a, b)
        #expect(a.engine.peerCaps(b.identity.mailboxId)?.updated == clock.now())
    }

    final class CardTap: @unchecked Sendable {
        let lock = NSLock()
        private var cards: [PeerCaps] = []
        func add(_ card: PeerCaps) { lock.lock(); cards.append(card); lock.unlock() }
        var all: [PeerCaps] { lock.lock(); defer { lock.unlock() }; return cards }
    }

    @Test func statusChangesDoNotScanClonesAndOnlyLaneChangesSendCards() throws {
        let (a, b, clock) = rig(); defer { a.close(); b.close() }
        b.knobs.desk = true
        let tap = CardTap()
        a.transport.hub.rewrite = { to, blob in
            if to == a.identity.mailboxId,
               case .success(let opened) = PeerSeal.open(blob, me: a.identity, now: clock.now(), pinned: { $0 == b.identity.mailboxId ? b.identity.keys : nil }),
               let obj = try? JSONSerialization.jsonObject(with: opened.payload) as? [String: Any],
               obj["t"] as? String == "caps", let card = PeerCaps.parse(obj) { tap.add(card) }
            return (to, blob)
        }
        let scans = b.launcher.cloneRemoteCalls
        clock.t = clock.t.addingTimeInterval(PeerEngine.cardWindow + 1)   // past the pairing Card's 15 s send window
        let id = try a.engine.delegate(peer: "Bea", repo: testRepo, title: "Work", brief: "x", mode: .pane).get()
        settle(a, b)
        let pane = try #require(b.engine.inboundJobs().first?.pane)
        #expect(tap.all.map { $0.lanesFree } == [1])
        for n in 0..<50 {
            b.engine.paneEvent(pane: pane, kind: n % 2 == 0 ? .need : .progress)
            settle(a, b)
        }
        #expect(b.launcher.cloneRemoteCalls == scans)
        #expect(tap.all.count == 1)
        clock.t = clock.t.addingTimeInterval(PeerEngine.cardWindow + 1)
        _ = a.engine.stopJob(jobId: id); settle(a, b)
        #expect(tap.all.map { $0.lanesFree } == [1, 2])
        #expect(b.launcher.cloneRemoteCalls == scans)
        clock.t = clock.t.addingTimeInterval(PeerCaps.staleAfter / 2)
        b.delays.fireDue(clock); settle(a, b)
        #expect(b.launcher.cloneRemoteCalls == scans + 1)
        #expect(tap.all.count == 3 && tap.all.last?.lanesFree == 2)
    }

    @Test func acceptedOfferRefreshesCloneCacheBeforeTheHeartbeat() throws {
        let (a, b, clock) = rig(); defer { a.close(); b.close() }
        let url = "https://github.com/acme/new.git"
        let scans = b.launcher.cloneRemoteCalls
        clock.t = clock.t.addingTimeInterval(PeerEngine.cardWindow + 1)
        let id = try a.engine.offer(peer: "Bea", url: url).get(); settle(a, b)
        b.engine.acceptOffer(id); settle(a, b)
        #expect(b.launcher.cloned.map { $0.url } == [url])
        #expect(b.launcher.cloneRemoteCalls == scans + 1)
        let card = try #require(a.engine.peerCaps(b.identity.mailboxId))
        #expect(card.repos.contains(try #require(PeerRepo.hash(url))))
        #expect(card.updated == clock.now())
        // Cache reads and unchanged Cards never scan or send.
        let deliveries = a.transport.hub.delivered
        for _ in 0..<50 { _ = b.engine.ownCaps(); b.engine.sendCapsToAll() }
        settle(a, b)
        #expect(b.launcher.cloneRemoteCalls == scans + 1 && a.transport.hub.delivered == deliveries)
    }

    @Test func capsSurviveRestart() throws {
        let (a, b, _) = rig(); defer { a.close(); b.close() }
        let bea = try #require(a.engine.peerLinks().first)
        let reloaded = PeerEngine(root: a.root, identity: a.identity, launcher: FakeLauncher(), transport: a.transport, ownName: "Al")
        #expect(reloaded.peerCaps(bea.mailboxId)?.features == ["watch", "m1", "chat-reply-v1", "dirs-v1"])
        #expect(FileManager.default.fileExists(atPath: a.root.appendingPathComponent("caps.json").path))
    }

    @Test func unknownWaitsThenNeedsUpdate() {
        let (a, b, clock) = rig(); defer { a.close(); b.close() }
        #expect(a.engine.capsState(mailbox: "stranger", feature: "watch") == .wait)
        clock.t = clock.t.addingTimeInterval(59)
        #expect(a.engine.capsState(mailbox: "stranger", feature: "watch") == .wait)
        clock.t = clock.t.addingTimeInterval(2)
        #expect(a.engine.capsState(mailbox: "stranger", feature: "watch") == .no)
        #expect(a.engine.needsUpdateMessage(peer: "Alex") == "Alex needs to update True")
    }

    @Test func ownPathGuard() throws {
        let (a, b, clock) = rig(); defer { a.close(); b.close() }
        clock.t = clock.t.addingTimeInterval(PeerEngine.cardWindow + 1)
        // A path under our own home that exists here, while the peer announced a different home → rejected.
        let dir = NSHomeDirectory() + "/Documents"      // exists on any Mac and is not on the never-list
        a.engine.home = NSHomeDirectory()
        // The peer's announced home is its real home (same process) — make it differ by re-announcing.
        b.engine.home = "/Users/alex"
        b.engine.sendCapsToAll(); settle(a, b)
        let r = a.engine.delegate(peer: "Bea", title: "T", brief: "b", mode: .pane, fromAgent: "x", dir: dir)
        guard case .failure(let e) = r else { Issue.record("expected rejection"); return }
        #expect("\(e)".contains("That is a path on your Mac"))
        // A path that doesn't exist locally, or a ~/ path, passes the guard.
        if case .failure(let e2) = a.engine.delegate(peer: "Bea", title: "T", brief: "b", mode: .pane, fromAgent: "x", dir: "/Users/alex/nope-\(UUID().uuidString)") { Issue.record("rejected missing path: \(e2)") }
        if case .failure(let e3) = a.engine.delegate(peer: "Bea", title: "T", brief: "b", mode: .pane, fromAgent: "x", dir: "~/Documents/FAB") { Issue.record("rejected ~ path: \(e3)") }
        // Homes match again: allowed.
        clock.t = clock.t.addingTimeInterval(PeerEngine.cardWindow + 1)
        b.engine.home = NSHomeDirectory(); b.engine.sendCapsToAll(); settle(a, b)
        if case .failure(let e4) = a.engine.delegate(peer: "Bea", title: "T", brief: "b", mode: .pane, fromAgent: "x", dir: dir) { Issue.record("rejected with matching homes: \(e4)") }
    }
}

@Suite struct ChatReplyCapsCompatTests {
    @Test func aCaps_withTheNewFeatureStillDecodesOnTheOldShape() throws {
        let json = #"{"version":"1.4","features":["watch","m1","chat-reply-v1"],"home":"~"}"#
        let c = try JSONDecoder().decode(PeerCaps.self, from: Data(json.utf8))
        #expect(c.features.contains("chat-reply-v1"))
        let old = try JSONDecoder().decode(PeerCaps.self, from: Data(#"{"version":"1.4","features":["watch","m1"],"home":"~"}"#.utf8))
        #expect(!old.features.contains("chat-reply-v1"))
    }
}

/// 100x 2c: the sender refuses a folder the peer's fresh Card doesn't allow; everything else sends as today.
@Suite(.serialized) struct DirPreflightTests {
    func make() throws -> (a: PeerSide, b: PeerSide, clock: Clock, root: String, mb: String, send: (String) -> Result<String, PeerError>) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dirs-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/ok", withIntermediateDirectories: true)
        b.knobs.dirs = [root + "/ok"]
        pairUp(a, b)
        let mb = a.engine.peerLinks().first!.mailboxId
        return (a, b, clock, root, mb, { d in a.engine.delegate(peer: "Bea", title: "T", brief: "x", mode: .pane, dir: d) })
    }

    @Test func receiverAnnouncesItsRootsAndTheFlag() throws {
        let t = try make(); defer { t.a.close(); t.b.close() }
        let c = try #require(t.a.engine.peerCaps(t.mb))
        #expect(c.features.contains("dirs-v1"))
        #expect(c.dirs == [PeerDirs.realDirectory(t.root + "/ok")!])
    }

    @Test func aFreshMissIsRefusedBeforeAnythingIsSent() throws {
        let t = try make(); defer { t.a.close(); t.b.close() }
        let before = t.a.transport.hub.delivered
        if case .failure(.invalid(let why)) = t.send(t.root + "/nope") { #expect(why == "Bea doesn't allow \(t.root)/nope") }
        else { Issue.record("expected a refusal") }
        #expect(t.a.transport.hub.delivered == before)
    }

    @Test func insideOrSymlinkedRootIsSent() throws {
        let t = try make(); defer { t.a.close(); t.b.close() }
        try FileManager.default.createDirectory(atPath: t.root + "/ok/sub", withIntermediateDirectories: true)
        #expect((try? t.send(t.root + "/ok/sub").get()) != nil)
        #expect(PeerDirs.outsideRoots(PeerDirs.realDirectory(t.root + "/ok")!, roots: t.a.engine.peerCaps(t.mb)!.dirs!, peerHome: "/Users/x") == false)
    }

    @Test func staleCapsSendAnyway() throws {
        let t = try make(); defer { t.a.close(); t.b.close() }
        t.clock.t = t.clock.t.addingTimeInterval(PeerCaps.dirsFreshFor + 1)
        let r = t.send(t.root + "/nope")
        if case .failure(.invalid(let why)) = r { #expect(!why.contains("doesn't allow")) }
    }

    @Test func oldCapsWithoutDirsSendAsToday() throws {
        let t = try make(); defer { t.a.close(); t.b.close() }
        var old = try #require(t.a.engine.peerCaps(t.mb)); old.dirs = nil; old.features = ["watch", "m1"]
        t.a.engine.setPeerCaps(t.mb, old)
        if case .failure(.invalid(let why)) = t.send(t.root + "/nope") { #expect(!why.contains("doesn't allow")) }
    }

    @Test func tildeAndItsRealPathCompareEqual() {
        #expect(PeerDirs.outsideRoots("~/x/y", roots: ["/Users/bo/x"], peerHome: "/Users/bo") == false)
        #expect(PeerDirs.outsideRoots("/Users/bo/x", roots: ["/Users/bo/x"], peerHome: "/Users/bo") == false)
        #expect(PeerDirs.outsideRoots("~/z", roots: ["/Users/bo/x"], peerHome: "/Users/bo") == true)
        #expect(PeerDirs.outsideRoots("~/z", roots: ["/Users/bo/x"], peerHome: "") == false)   // unknown home never refuses
    }

    @Test func oldDecoderIgnoresDirsAndNewDecoderReadsOldCards() throws {
        let j = #"{"version":"1.4","features":["watch","m1","dirs-v1"],"home":"~","dirs":["/a"]}"#
        #expect(try JSONDecoder().decode(PeerCaps.self, from: Data(j.utf8)).dirs == ["/a"])
        #expect(try JSONDecoder().decode(PeerCaps.self, from: Data(#"{"version":"1.4","features":["watch"],"home":"~"}"#.utf8)).dirs == nil)
        #expect(PeerCaps.parse(["version": "1.4", "features": ["watch"], "home": "~", "dirs": ["relative", "/ok"]])?.dirs == ["/ok"])
    }

    @Test func aCardOverBudgetDropsDirsWholeNeverHalf() {
        let big = (0..<20).map { "/" + String(repeating: "d", count: 190) + "\($0)" }
        let base: [String: Any] = ["t": "caps", "version": "1.4", "features": ["watch"], "home": "/", "pad": String(repeating: "p", count: 3000)]
        let c = CardLimits.fit(base, folders: [:], agents: [], dirs: big)
        #expect(c["dirs"] == nil)
    }
}
