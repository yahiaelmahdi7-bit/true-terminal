import Testing
import Foundation
@testable import True

/// G7 polish: the ask's lend / hold checks read G6 (the local lend file and Steward's allowance board), never the live ~/.true.
@Suite(.serialized) struct PeerAskWiringTests {
    final class Board: @unchecked Sendable {
        let lock = NSLock()
        private var _body: Data?, _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func set(_ rows: [[String: Any]]?) {
            lock.lock(); _body = rows.map { try! JSONSerialization.data(withJSONObject: ["pool_enabled": true, "now": 1, "devices": $0]) }; lock.unlock()
        }
        var fetch: @Sendable () throws -> Data { { [self] in
            lock.lock(); defer { lock.unlock() }
            _calls += 1
            guard let b = _body else { throw PeerError.invalid("Steward unreachable") }
            return b
        } }
    }
    static func row(_ d: String, headroom: Double?, lend: String = "on") -> [String: Any] {
        ["device": d, "lend": lend, "headroom": headroom as Any? ?? NSNull()]
    }

    func snapshot(device: String, asker a: PeerSide, owners: [(String, PeerSide)], grant: Bool = true) -> GrantSnapshot {
        var devs: [GrantSnapshot.Device] = [.init(device: "d-al", person: "al", peer_key: PeerB64.std(a.identity.keys.sign), public_key: nil)]
        for (d, s) in owners { devs.append(.init(device: d, person: "bo", peer_key: PeerB64.std(s.identity.keys.sign), public_key: nil)) }
        return GrantSnapshot(
            fetched_at: nil, device: device,
            persons: [.init(id: "al", role: "member", active: 1), .init(id: "bo", role: "member", active: 1)],
            devices: devs,
            workspaces: [.init(id: "w1", kind: "repo", key: testRepo, owner: "bo")],
            grants: grant ? [.init(id: "g1", person: "al", workspace: "w1", level: "read", expires: nil, revoked_at: nil)] : [])
    }
    func apply(_ s: GrantSnapshot, to side: PeerSide) { _ = side.engine.grants.apply(try! JSONEncoder().encode(s)) }

    struct Rig {
        let a: PeerSide, b: PeerSide, relay: FakeRelay, clock: Clock, runner: FakeAskRunner, board: Board, home: URL
        func close() { a.close(); b.close(); try? FileManager.default.removeItem(at: home) }
    }
    /// Bo's Mac (device d-bo): its own temp home, a fake Steward board, the REAL lend/hold closures.
    func rig(lendFile: String? = nil, board rows: [[String: Any]]?) -> Rig {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ask-home-\(UUID().uuidString.prefix(6))")
        try! FileManager.default.createDirectory(at: home.appendingPathComponent(".true/group"), withIntermediateDirectories: true)
        if let lendFile { try! (lendFile + "\n").write(to: home.appendingPathComponent(".true/group/lend"), atomically: true, encoding: .utf8) }
        b.engine.home = home.path
        let runner = FakeAskRunner(); b.engine.ask.runner = runner
        let board = Board(); board.set(rows); b.engine.allowanceFetch = board.fetch
        apply(snapshot(device: "d-bo", asker: a, owners: [("d-bo", b)]), to: b)
        return Rig(a: a, b: b, relay: relay, clock: clock, runner: runner, board: board, home: home)
    }
    func ask(_ r: Rig) -> String {
        guard case .success(let id) = r.a.engine.ask.send(to: "Bea", question: "where is auth?", repo: testRepo, fromAgent: "lead-1") else { Issue.record("not sent"); return "" }
        settle(r.a, r.b)
        return id
    }

    @Test func lendFileOffRefusesAndStartsNothing() {
        let r = rig(lendFile: "off", board: [Self.row("d-bo", headroom: 50)]); defer { r.close() }
        let id = ask(r)
        #expect(r.a.engine.ask.answer(id)?.text == "refused: Bea's Mac is not lending right now")
        #expect(r.runner.count == 0)
        print("G7 WIRING: lend file off -> \(r.a.engine.ask.answer(id)?.text ?? "nil"); runs=\(r.runner.count)")
    }

    @Test func boardLendOffRefuses() {
        let r = rig(board: [Self.row("d-bo", headroom: 50, lend: "off")]); defer { r.close() }
        let id = ask(r)
        #expect(r.a.engine.ask.answer(id)?.text == "refused: Bea's Mac is not lending right now" && r.runner.count == 0)
    }

    @Test func noHeadroomUnknownOrUnreachableIsThePoolLimit() {
        let want = "refused: Bea's Mac is at its pool limit"
        for (label, rows) in [("headroom 0", [Self.row("d-bo", headroom: 0)]),
                              ("headroom unknown", [Self.row("d-bo", headroom: nil)]),
                              ("this device missing", [Self.row("d-other", headroom: 40)]),
                              ("board unreachable", nil)] as [(String, [[String: Any]]?)] {
            let r = rig(board: rows); defer { r.close() }
            let id = ask(r)
            #expect(r.a.engine.ask.answer(id)?.text == want && r.runner.count == 0, "\(label)")
            print("G7 WIRING: \(label) -> \(r.a.engine.ask.answer(id)?.text ?? "nil"); runs=\(r.runner.count)")
        }
    }

    @Test func headroomAndLendOnRunsAndTheBoardIsCached() {
        let r = rig(board: [Self.row("d-bo", headroom: 12.5)]); defer { r.close() }   // no lend file at all = on
        let id = ask(r)
        #expect(r.a.engine.ask.answer(id)?.text == "42" && r.runner.count == 1)
        _ = ask(r)
        #expect(r.runner.count == 2 && r.board.calls == 1)            // second ask inside 60 s: no second Steward read
        r.clock.t = r.clock.t.addingTimeInterval(61)
        r.board.set([Self.row("d-bo", headroom: 0)])
        let id3 = ask(r)
        #expect(r.board.calls == 2 && r.a.engine.ask.answer(id3)?.text == "refused: Bea's Mac is at its pool limit")
        print("G7 WIRING: headroom 12.5, lend on -> ran (runs=2, 1 board read in 60 s); after 61 s with headroom 0 -> pool limit")
    }

    @Test func twoMacsPickTheOneWithMoreHeadroomOnce() {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b1 = PeerSide("Bo1", relay: relay, clock: clock), b2 = PeerSide("Bo2", relay: relay, clock: clock)
        pairUp(a, b1, as: "Bea1"); pairUp(a, b2, as: "Bea2")
        let r1 = FakeAskRunner(), r2 = FakeAskRunner()
        let own = Board(); own.set([Self.row("d-b1", headroom: 30), Self.row("d-b2", headroom: 30)])
        for (side, dev, run) in [(b1, "d-b1", r1), (b2, "d-b2", r2)] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("ask-home-\(UUID().uuidString.prefix(6))")
            try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            side.engine.home = home.path; side.engine.ask.runner = run; side.engine.allowanceFetch = own.fetch
            apply(snapshot(device: dev, asker: a, owners: [(dev, side)]), to: side)
        }
        let mine = Board(); mine.set([Self.row("d-b1", headroom: 10), Self.row("d-b2", headroom: 50)])
        a.engine.allowanceFetch = mine.fetch
        apply(snapshot(device: "d-al", asker: a, owners: [("d-b1", b1), ("d-b2", b2)]), to: a)
        func send() -> String {
            guard case .success(let id) = a.engine.ask.send(to: "bo", question: "where is auth?", repo: testRepo, fromAgent: "lead-1") else { Issue.record("not sent"); return "" }
            settle(a, b1, b2); return id
        }
        let first = send()
        #expect(r2.count == 1 && r1.count == 0 && a.engine.ask.answer(first)?.text == "42")
        clock.t = clock.t.addingTimeInterval(61)            // the board moves: Bo1 now has more
        mine.set([Self.row("d-b1", headroom: 90), Self.row("d-b2", headroom: 20)])
        _ = send()
        #expect(r1.count == 1 && r2.count == 1)              // one Mac per ask, never both
        print("G7 WIRING: person 'bo' with two Macs: headroom 10/50 -> Bea2 only; after the board moved 90/20 -> Bea1 only (runs b1=\(r1.count) b2=\(r2.count))")
        for s in [a, b1, b2] { s.close() }
    }
}
