import Testing
import Foundation
@testable import True

@Suite struct IdleGateTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func peer(_ pid: Int32, busy: Bool, name: String = "finance-desk") -> PeerSession {
        PeerSession(pid: pid, sessionID: "s", cwd: "/tmp", name: name, kind: "cli", busy: busy, updatedAt: 0)
    }
    func builder(_ pid: Int32, state: BuilderState = .running, name: String = "true-hub-design") -> BuilderRecord {
        BuilderRecord(id: "b", name: name, cwd: "/tmp", originCwd: "/tmp", model: "sonnet", sessionID: "",
                      claudePID: pid, started: 0, ended: nil, state: state, acked: false, parent: nil,
                      branch: nil, worktree: nil, cost: nil, budget: nil, dir: nil)
    }
    func verdict(peers: [PeerSession] = [], builders: [BuilderRecord] = [], seats: [IdleGate.Seat] = [],
                 alive: Set<Int32> = [1, 2]) -> IdleVerdict {
        IdleGate.evaluate(peers: peers, builders: builders, seats: seats, now: now, alive: { alive.contains($0) })
    }

    @Test func busyAlivePeerIsBusy() {
        let v = verdict(peers: [peer(1, busy: true)])
        #expect(v.busy); #expect(v.reasons == ["session finance-desk"])
    }
    @Test func busyDeadPeerIsIdle() { #expect(!verdict(peers: [peer(9, busy: true)]).busy) }
    @Test func idlePeerIsIdle() { #expect(!verdict(peers: [peer(1, busy: false)]).busy) }
    @Test func runningAliveBuilderIsBusy() {
        let v = verdict(builders: [builder(2)])
        #expect(v.busy); #expect(v.reasons == ["builder true-hub-design"])
    }
    @Test func runningDeadBuilderIsIdle() { #expect(!verdict(builders: [builder(9)]).busy) }
    @Test func builderLaunchInProgressIsBusy() { #expect(verdict(builders: [builder(0)]).busy) }
    @Test func finishedBuilderIsIdle() { #expect(!verdict(builders: [builder(1, state: .done)]).busy) }
    @Test func freshWorkingSeatIsBusy() {
        let v = verdict(seats: [.init(name: "lead", status: .working, lastEventAt: now.addingTimeInterval(-60))])
        #expect(v.busy); #expect(v.reasons == ["seat lead"])
    }
    @Test func staleWorkingSeatIsIdle() {
        #expect(!verdict(seats: [.init(name: "lead", status: .working, lastEventAt: now.addingTimeInterval(-25 * 60))]).busy)
    }
    @Test func needsYouSeatIsIdle() {
        #expect(!verdict(seats: [.init(name: "lead", status: .needsYou, lastEventAt: now)]).busy)
    }
    @Test func reasonsListEverything() {
        let v = verdict(peers: [peer(1, busy: true)], builders: [builder(2)],
                        seats: [.init(name: "lead", status: .working, lastEventAt: now)])
        #expect(v.reasons == ["builder true-hub-design", "session finance-desk", "seat lead"])
    }
}

@MainActor final class FakePower: PowerAssertion {
    private(set) var held = false
    private(set) var holds = 0
    func hold(reason: String) { held = true; holds += 1 }
    func release() { held = false }
}

@Suite @MainActor struct WorkAwakeTests {
    final class Env { var busy = false; var clock = Date(timeIntervalSince1970: 0) }

    func make() -> (WorkAwake, FakePower, Env) {
        let env = Env(), fake = FakePower()
        // The sleeper never returns: these tests drive evaluate() by hand, the tick only has to exist.
        let w = WorkAwake(backend: fake, verdict: { _ in IdleVerdict(busy: env.busy, reasons: env.busy ? ["x"] : []) },
                          reload: {}, now: { env.clock }, sleeper: { _ in try? await Task.sleep(for: .seconds(3600)) })
        return (w, fake, env)
    }

    @Test func busyHoldsImmediately() {
        let (w, fake, env) = make(); env.busy = true; w.evaluate()
        #expect(fake.held)
    }
    @Test func idleInsideGraceStaysHeld() {
        let (w, fake, env) = make(); env.busy = true; w.evaluate()
        env.busy = false; w.evaluate()
        env.clock += 119; w.evaluate()
        #expect(fake.held)
    }
    @Test func idleForGraceReleases() {
        let (w, fake, env) = make(); env.busy = true; w.evaluate()
        env.busy = false; w.evaluate()
        env.clock += 120; w.evaluate()
        #expect(!fake.held)
    }
    @Test func busyInsideGraceCancelsRelease() {
        let (w, fake, env) = make(); env.busy = true; w.evaluate()
        env.busy = false; w.evaluate()
        env.clock += 100; env.busy = true; w.evaluate()
        env.busy = false; env.clock += 10; w.evaluate()     // the window restarts here
        env.clock += 119; w.evaluate()
        #expect(fake.held)
        env.clock += 1; w.evaluate()
        #expect(!fake.held)
    }
    @Test func reholdsAfterRelease() {
        let (w, fake, env) = make(); env.busy = true; w.evaluate()
        env.busy = false; w.evaluate(); env.clock += 120; w.evaluate()
        #expect(!fake.held)
        env.busy = true; w.evaluate()
        #expect(fake.held); #expect(fake.holds == 2)
    }
    @Test func tickRunsOnlyWhileHeld() {
        let (w, _, env) = make()
        env.busy = false; w.evaluate(); #expect(!w.tickRunning)
        env.busy = true; w.evaluate(); #expect(w.tickRunning)
        env.busy = false; w.evaluate(); #expect(w.tickRunning)      // grace window
        env.clock += 120; w.evaluate(); #expect(!w.tickRunning)
    }
}
