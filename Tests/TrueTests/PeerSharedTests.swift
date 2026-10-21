import Testing
import Foundation
@testable import True

/// Run 34 — Shared projects. `a` ("Al") offers a repo to `b` (who calls them "Al" and whom Al calls "Bea").
@Suite(.serialized) struct PeerSharedTests {
    struct Rig {
        let a: PeerSide, b: PeerSide, abus: ChatBus, bbus: ChatBus
        func close() { a.close(); b.close() }
    }
    func rig(mode: PeerInboundMode = .bypass) -> Rig {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock, mode: mode)
        pairUp(a, b)
        return Rig(a: a, b: b, abus: a.attachChat(), bbus: b.attachChat())
    }
    /// Al offers and Bo accepts; returns the offer id.
    @discardableResult
    func share(_ r: Rig, url: String = testRepo, name: String = "demo") throws -> String {
        guard case .success(let id) = r.a.engine.offer(peer: "Bea", url: url, name: name, note: "my project") else { throw PeerError.invalid("offer") }
        settle(r.a, r.b)
        r.b.engine.acceptOffer(id); settle(r.a, r.b)
        return id
    }

    // MARK: step 1 — offer / accept / decline

    @Test func offerArrivesAsAPendingCardWithNothingCloned() throws {
        let r = rig(); defer { r.close() }
        guard case .success(let id) = r.a.engine.offer(peer: "Bea", url: testRepo, name: "Demo App", note: "have a look") else { Issue.record("offer failed"); return }
        settle(r.a, r.b)
        let card = try #require(r.b.engine.pendingOffers().first)
        #expect(card.id == id && card.incoming && card.status == .pending && card.url == testRepo && card.name == "Demo App" && card.note == "have a look")
        #expect(card.peerLabel == "Al")
        #expect(r.b.launcher.cloned.isEmpty && r.b.knobs.shares.isEmpty)
        #expect(r.a.engine.pendingOffers().first?.incoming == false)
    }

    @Test func acceptClonesRecordsAndJoinsTheRoomOnBothSides() throws {
        let r = rig(); defer { r.close() }
        let id = try share(r)
        let want = r.b.root.path + "/Projects/demo.peers/al"
        #expect(r.b.launcher.cloned.map(\.path) == [want] && r.b.launcher.cloned.first?.url == testRepo)
        let mine = try #require(r.b.knobs.shares.values.first?.first)
        #expect(mine == SharedRepo(url: testRepo, path: want, slug: "demo"))
        #expect(r.bbus.members("#demo") != [])
        // the sharer's True recorded it too (keyed by Bo's mailbox) and joined #demo
        let theirs = try #require(r.a.knobs.shares[r.b.identity.mailboxId]?.first)
        #expect(theirs.slug == "demo" && theirs.url == testRepo)
        #expect(r.abus.members("#demo") != [])
        #expect(r.b.engine.pendingOffers().first { $0.id == id }?.status == .accepted)
        #expect(r.a.engine.pendingOffers().first { $0.id == id }?.status == .accepted)
        #expect(r.a.engine.shares().count == 1 && r.b.engine.shares().first?.peer == "Al")
    }

    @Test func declineSendsANackAndRecordsNothing() throws {
        let r = rig(); defer { r.close() }
        guard case .success(let id) = r.a.engine.offer(peer: "Bea", url: testRepo, name: "demo") else { Issue.record("offer failed"); return }
        settle(r.a, r.b)
        r.b.engine.declineOffer(id, reason: "Not now"); settle(r.a, r.b)
        let theirs = try #require(r.a.engine.pendingOffers().first)
        #expect(theirs.status == .declined && theirs.reason == "Not now")
        #expect(r.a.knobs.shares.isEmpty && r.b.knobs.shares.isEmpty && r.b.launcher.cloned.isEmpty)
    }

    @Test func aFailedCloneIsShownAndNothingIsRecorded() throws {
        let r = rig(); defer { r.close() }
        r.b.launcher.cloneError = "Authentication failed"
        guard case .success(let id) = r.a.engine.offer(peer: "Bea", url: testRepo, name: "demo") else { Issue.record("offer failed"); return }
        settle(r.a, r.b)
        r.b.engine.acceptOffer(id); settle(r.a, r.b)
        let card = try #require(r.b.engine.pendingOffers().first)
        #expect(card.status == .failed && card.reason == "Authentication failed")
        #expect(r.b.knobs.shares.isEmpty && r.a.knobs.shares.isEmpty)
        #expect(r.a.engine.pendingOffers().first?.status == .pending)
        r.b.launcher.cloneError = nil                       // retry works from the failed card
        r.b.engine.acceptOffer(id); settle(r.a, r.b)
        #expect(r.b.knobs.shares.count == 1 && r.a.knobs.shares.count == 1)
    }

    @Test func badOffersAreRefusedOrDropped() throws {
        let r = rig(); defer { r.close() }
        if case .success = r.a.engine.offer(peer: "Bea", url: "not a url", name: "x") { Issue.record("bad url accepted") }
        if case .success = r.a.engine.offer(peer: "Bea", url: testRepo, name: "bad\u{7}name") { Issue.record("bad name accepted") }
        if case .success = r.a.engine.offer(peer: "Nobody", url: testRepo, name: "x") { Issue.record("unknown peer accepted") }
        let long = String(repeating: "n", count: 900)
        guard case .success = r.a.engine.offer(peer: "Bea", url: testRepo, name: "ok", note: long) else { Issue.record("offer failed"); return }
        settle(r.a, r.b)
        #expect(r.b.engine.pendingOffers().first?.note.count == 400)   // the sender trims to 400
    }

    @Test func aReplyForAnOfferWeNeverMadeIsDropped() throws {
        let r = rig(); defer { r.close() }
        let before = r.a.engine.dropCount
        let blob = PeerSeal.seal(payload: try JSONSerialization.data(withJSONObject: ["t": "offer", "id": "nope", "ack": true, "slug": "evil"]),
                                 now: Date(timeIntervalSince1970: 1_800_000_000), from: r.b.identity, to: r.a.identity.keys)!
        r.a.engine.receive(blob)
        #expect(r.a.engine.dropCount == before + 1 && r.a.knobs.shares.isEmpty)
    }

    @Test func removeShareDropsTheEntryAndMembershipButNotTheClone() throws {
        let r = rig(); defer { r.close() }
        try share(r)
        let path = try #require(r.b.knobs.shares.values.first?.first?.path)
        r.b.engine.removeShare(mailbox: r.a.identity.mailboxId, slug: "demo")
        #expect(r.b.knobs.shares.isEmpty && r.b.engine.shares().isEmpty)
        #expect(r.bbus.members("#demo") == [])
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

// MARK: step 2 — jobs on a shared repo are always approved one by one
extension PeerSharedTests {
    @Test func repoJobOnASharedRepoIsHeldEvenWithInboundBypass() throws {
        let r = rig(mode: .bypass); defer { r.close() }
        try share(r)
        guard case .success(let id) = r.a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "do it") else { Issue.record("delegate failed"); return }
        settle(r.a, r.b)
        let j = try #require(r.b.engine.inboundJobs().first)
        #expect(j.status == .queued && j.inboundMode == .ask && r.b.launcher.panes.isEmpty)
        #expect(r.a.engine.status(jobId: id).first?.status == .needsYou)
        r.b.engine.accept(j.id); settle(r.a, r.b)
        #expect(r.b.launcher.panes.count == 1)
        #expect(r.b.launcher.panes[0].flags == PeerInboundMode.ask.claudeFlags)
        #expect(r.b.launcher.panes[0].cwd.hasSuffix("/demo.peers/al.peers/" + PeerNaming.shortId(id)) || r.b.launcher.panes[0].cwd.contains(".peers/"))
    }

    @Test func aRepoJobOnAnUnsharedRepoStillFollowsTheGlobalMode() throws {
        let r = rig(mode: .bypass); defer { r.close() }
        try share(r)
        guard case .success = r.a.engine.delegate(peer: "Bea", repo: "https://github.com/acme/other.git", title: "Fix it", brief: "do it") else { Issue.record("delegate failed"); return }
        settle(r.a, r.b)
        #expect(r.b.engine.inboundJobs().first?.status == .accepted && r.b.launcher.panes.count == 1)
    }

    @Test func dirJobOnTheSharedPathIsHeldLikewiseAndRunsOnlyAfterApprove() throws {
        let r = rig(mode: .bypass); defer { r.close() }
        try share(r)
        let path = try #require(r.b.knobs.shares.values.first?.first?.path)
        let sub = path + "/src"; try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        guard case .success = r.a.engine.delegate(peer: "Bea", title: "Look", brief: "look", dir: sub) else { Issue.record("delegate failed"); return }
        settle(r.a, r.b)
        let j = try #require(r.b.engine.inboundJobs().first)
        #expect(j.status == .queued && j.inboundMode == .ask && r.b.launcher.panes.isEmpty)
        r.b.engine.accept(j.id); settle(r.a, r.b)
        #expect(r.b.launcher.panes.first?.cwd == URL(fileURLWithPath: sub).resolvingSymlinksInPath().path)   // allowed via the share, not peer.allowedDirs
        #expect(r.b.knobs.dirs.isEmpty)
    }

    @Test func aDirOutsideTheSharedPathIsNotOpenedUpByAShare() throws {
        let r = rig(mode: .bypass); defer { r.close() }
        try share(r)
        let other = r.b.root.path + "/elsewhere"; try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        guard case .success = r.a.engine.delegate(peer: "Bea", title: "Look", brief: "look", dir: other) else { Issue.record("delegate failed"); return }
        settle(r.a, r.b)
        #expect(r.b.engine.inboundJobs().first?.status == .failed && r.b.launcher.panes.isEmpty)
    }

    @Test func aShareOnlyOpensItsPathToThePeerThatOfferedIt() throws {
        let r = rig(mode: .ask); defer { r.close() }
        try share(r)
        let path = try #require(r.b.knobs.shares.values.first?.first?.path)
        // Same shares, but filed under a different peer: Al's dir job must not be allowed through it.
        r.b.knobs.shares = ["someone-else": r.b.knobs.shares.values.first!]
        guard case .success = r.a.engine.delegate(peer: "Bea", title: "Look", brief: "look", dir: path) else { Issue.record("delegate failed"); return }
        settle(r.a, r.b)
        let j = try #require(r.b.engine.inboundJobs().first)
        r.b.engine.accept(j.id); settle(r.a, r.b)
        #expect(r.b.engine.inboundJobs().first?.status == .failed)
    }

    @Test func afterRemoveShareJobsFollowTheGlobalModeAgain() throws {
        let r = rig(mode: .bypass); defer { r.close() }
        try share(r)
        r.b.engine.removeShare(mailbox: r.a.identity.mailboxId, slug: "demo")
        guard case .success = r.a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "do it") else { Issue.record("delegate failed"); return }
        settle(r.a, r.b)
        #expect(r.b.engine.inboundJobs().first?.status == .accepted)
    }
}
