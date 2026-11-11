import Testing
@testable import True

@MainActor
struct PeerBuildersTests {
    private func peer(_ state: BuilderState) -> BuilderRecord {
        var r = TriageFixture.builder("peer-alex-\(state.rawValue)", "true", state)
        r.dir = "/tmp/\(r.id)"
        return r
    }

    @Test func queuedWaitingAndUnknownBuildersKeepThePeerJobOpen() {
        for state in [BuilderState.running, .queued, .waiting, .other] {
            let u = PeerBuilders.updates([peer(state)])
            #expect(u.count == 1 && u[0].state == state, "\(state) must not end the peer job")
        }
    }

    @Test func finishedBuildersEndThePeerJob() {
        for state in [BuilderState.done, .failed, .killed, .died, .paused, .held, .landed, .unlanded] {
            #expect(PeerBuilders.updates([peer(state)]).first?.state == state, "\(state)")
        }
    }

    @Test func waitingPassesItsReasonAndResetTime() {
        var r = peer(.waiting); r.waitReason = "Usage limit"; r.resumeAt = 1_800_000_000; r.runs = 2
        let u = PeerBuilders.updates([r]).first
        #expect(u?.state == .waiting && u?.waitReason == "Usage limit" && u?.resumeAt == r.resumeAt && u?.runs == 2)
    }

    @Test func nonPeerBuildersAreIgnored() {
        #expect(PeerBuilders.updates([TriageFixture.builder("true-run40", "true", .running)]).isEmpty)
    }
}
