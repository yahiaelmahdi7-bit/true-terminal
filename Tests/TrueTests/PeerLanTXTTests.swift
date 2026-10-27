import Testing
import Foundation
@testable import True

@MainActor
@Suite(.serialized) struct PeerLanTXTTests {
    let mid = PeerIdentity.generate().mailboxId

    @Test func roundTripAndTagMatch() throws {
        let ad = PeerLanTXT.makeAd(mailboxId: mid)
        let txt = PeerLanTXT.encode(ad)
        #expect(txt["v"] == "1" && txt["s"]?.count == 16 && txt["t"]?.count == 16)
        #expect(Set(txt.keys) == ["v", "s", "t"])                       // no keys, no stable id
        let back = try #require(PeerLanTXT.decode(txt))
        #expect(back == ad)
        #expect(PeerLanTXT.matches(back, mailboxId: mid))
        #expect(!PeerLanTXT.matches(back, mailboxId: PeerIdentity.generate().mailboxId))
    }

    @Test func freshSaltEachSessionSoTheTagChanges() {
        let a = PeerLanTXT.makeAd(mailboxId: mid), b = PeerLanTXT.makeAd(mailboxId: mid)
        #expect(a.salt != b.salt && a.tag != b.tag)
    }

    @Test func hostileTXTIsIgnored() {
        let good = PeerLanTXT.encode(PeerLanTXT.makeAd(mailboxId: mid))
        var bad = good; bad["v"] = "2"; #expect(PeerLanTXT.decode(bad) == nil)
        bad = good; bad["v"] = nil; #expect(PeerLanTXT.decode(bad) == nil)
        bad = good; bad["s"] = String(good["s"]!.dropLast()); #expect(PeerLanTXT.decode(bad) == nil)
        bad = good; bad["t"] = good["t"]! + "00"; #expect(PeerLanTXT.decode(bad) == nil)
        bad = good; bad["t"] = String(repeating: "z", count: 16); #expect(PeerLanTXT.decode(bad) == nil)
        bad = good; bad["s"] = nil; #expect(PeerLanTXT.decode(bad) == nil)
        #expect(PeerLanTXT.decode([:]) == nil)
    }

    @Test func serviceNameCutsOnUTF8ByteBoundary() {
        let long = String(repeating: "é", count: 40)       // 80 bytes
        let n = PeerLanTXT.serviceName(long)
        #expect(n.utf8.count <= 63 && n.utf8.count > 0 && n.allSatisfy { $0 == "é" })
        #expect(PeerLanTXT.serviceName("Ali's MacBook") == "Ali's MacBook")
        #expect(PeerLanTXT.serviceName("") == "True")
    }

    @Test func frameLengthCheckedBeforeAllocation() {
        #expect(PeerLanFrame.length(header: Data([0, 0, 0x20, 0x00])) == 8192)
        #expect(PeerLanFrame.length(header: Data([0, 0, 0x20, 0x01])) == nil)       // 8 KB + 1
        #expect(PeerLanFrame.length(header: Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil)
        #expect(PeerLanFrame.length(header: Data([0, 0, 0, 0])) == nil)
        #expect(PeerLanFrame.length(header: Data([0, 0, 1])) == nil)
        #expect(PeerLanFrame.wrap(Data(repeating: 1, count: 8193)) == nil)
        #expect(PeerLanFrame.wrap(Data("hi".utf8)) == Data([0, 0, 0, 2]) + Data("hi".utf8))
    }

    @Test func rateLimitIsFivePerMinutePerAddress() {
        var r = PeerLanRateLimiter()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<5 { let ok = r.allow("1.1.1.1", now: t); #expect(ok) }
        let blocked = r.allow("1.1.1.1", now: t.addingTimeInterval(30)), other = r.allow("2.2.2.2", now: t), later = r.allow("1.1.1.1", now: t.addingTimeInterval(61))
        #expect(!blocked && other && later)
    }

    // MARK: rows (coordinator)

    final class Rig {
        let relay = FakeRelay(), clock = Clock(), net = FakeLanNet(), timers = ManualTimers()
        let side: PeerSide, transport: FakeLanTransport, lan: PeerLanCoordinator
        @MainActor init() {
            side = PeerSide("Al", relay: relay, clock: clock)
            transport = FakeLanTransport(net: net, address: "me")
            lan = PeerLanCoordinator(transport: transport, engine: side.engine, timer: timers.factory)
        }
        func close() { side.close() }
        @MainActor func found(_ id: String, _ name: String, mailbox: String, salt: Data = PeerCrypto.randomBytes(8)) {
            lan.handle(.found(id: id, name: name, txt: PeerLanTXT.encode(PeerLanTXT.makeAd(mailboxId: mailbox, salt: salt))))
        }
    }

    @Test func rowsDedupeByTagDropOnRemovedAndHideOwn() {
        let r = Rig(); defer { r.close() }
        r.lan.open()
        #expect(r.transport.isOpen && r.transport.name == "Al")
        let other = PeerIdentity.generate().mailboxId
        let salt = PeerCrypto.randomBytes(8)
        r.found("en0", "Bo", mailbox: other, salt: salt); r.found("en1", "Bo", mailbox: other, salt: salt)
        #expect(r.lan.rows.count == 1 && r.lan.rows[0].name == "Bo" && !r.lan.rows[0].paired)
        r.found("own", "Al", mailbox: r.side.identity.mailboxId)            // our own advert is hidden
        #expect(r.lan.rows.count == 1)
        r.lan.handle(.removed(id: "en0")); #expect(r.lan.rows.count == 1)
        r.lan.handle(.removed(id: "en1")); #expect(r.lan.rows.isEmpty)
        r.lan.handle(.found(id: "bad", name: "X", txt: ["v": "9"])); #expect(r.lan.rows.isEmpty)
    }

    @Test func rowsCapAtFifty() {
        let r = Rig(); defer { r.close() }
        r.lan.open()
        for i in 0..<60 { r.found("id\(i)", "Mac \(i)", mailbox: PeerIdentity.generate().mailboxId) }
        #expect(r.lan.rows.count == 50)
    }

    @Test func pairedRowShowsPairedAfterPinning() {
        let r = Rig(); defer { r.close() }
        let other = PeerSide("Bo", relay: r.relay, clock: r.clock); defer { other.close() }
        r.lan.open()
        r.found("x", "Bo", mailbox: other.identity.mailboxId)
        #expect(r.lan.rows.first?.paired == false)
        pairUp(r.side, other)
        r.lan.handle(.removed(id: "x")); r.found("x", "Bo", mailbox: other.identity.mailboxId)
        #expect(r.lan.rows.first?.paired == true)
    }

    @Test func deniedAndCantSearchStates() {
        let r = Rig(); defer { r.close() }
        r.lan.open()
        r.lan.handle(.state(.denied)); #expect(r.lan.lanState == .denied)
        r.lan.handle(.state(.ready)); #expect(r.lan.lanState == .ok)
        r.lan.handle(.state(.waiting)); #expect(r.lan.lanState == .ok)           // not yet: under 10 s
        r.lan.handle(.state(.ready)); #expect(!r.timers.live(10))                // recovered: timer dropped
        r.lan.handle(.state(.waiting)); r.timers.fire(10)
        #expect(r.lan.lanState == .cantSearch)
    }

    @Test func closeStopsTheTransportAndClearsRows() {
        let r = Rig(); defer { r.close() }
        r.lan.open(); r.lan.open()
        r.found("x", "Bo", mailbox: PeerIdentity.generate().mailboxId)
        r.lan.close()
        #expect(!r.transport.isOpen && r.lan.rows.isEmpty)
        r.found("y", "Bo", mailbox: PeerIdentity.generate().mailboxId)           // events after close are ignored
        #expect(r.lan.rows.isEmpty)
    }
}
