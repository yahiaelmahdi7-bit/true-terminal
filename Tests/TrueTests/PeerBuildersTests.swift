import Testing
@testable import True

@MainActor
struct PeerBuildersTests {
    private func peer(_ state: BuilderState) -> BuilderRecord {
        var r = TriageFixture.builder("peer-mahmoud-\(state.rawValue)", "true", state)
        r.dir = "/tmp/\(r.id)"
        return r
    }

    @Test func queuedWaitingAndUnknownBuildersKeepThePeerJobOpen() {
        for state in [BuilderState.running, .queued, .waiting, .other] {
            let u = PeerBuilders.updates([peer(state)])
            #expect(u.count == 1 && u[0].running, "\(state) must not end the peer job")
        }
    }

    @Test func finishedBuildersEndThePeerJob() {
        for state in [BuilderState.done, .failed, .killed, .died, .paused, .held, .landed, .unlanded] {
            #expect(PeerBuilders.updates([peer(state)]).first?.running == false, "\(state)")
        }
    }

    @Test func nonPeerBuildersAreIgnored() {
        #expect(PeerBuilders.updates([TriageFixture.builder("true-run40", "true", .running)]).isEmpty)
    }
}
