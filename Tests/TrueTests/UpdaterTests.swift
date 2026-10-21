import Testing
import Foundation
@testable import True

/// Run 31: the self-restart engine, driven through its seams (inputs, clock, restart action). Nothing here quits an app.
@MainActor
struct UpdaterTests {
    private final class World {
        var inputs = UpdateLogic.RestartInputs(idleSeconds: 300)
        var now = Date(timeIntervalSince1970: 2_000_000)
        var restarts = 0
    }

    private func make(_ w: World, staged: Bool = true) -> Updater {
        let d = UserDefaults(suiteName: "updater-tests-\(UUID().uuidString)")!
        let info: [String: Any] = ["TrueUpdateRepo": "o/r", "CFBundleShortVersionString": "1.0.0"]
        let u = Updater(info: info, defaults: d, inputs: { w.inputs }, now: { w.now },
                        sleeper: { _ in try? await Task.sleep(for: .seconds(3600)) },
                        restart: { w.restarts += 1 }, observeSources: false)
        if staged { u.setStagedForTest("1.1.0") }
        return u
    }

    @Test func stagedAndSafeArmsCountdown() {
        let w = World(), u = make(w)
        u.evaluateRestart()
        #expect(u.countdownEnd == w.now.addingTimeInterval(60))
        #expect(u.countdownVersion == "1.1.0")
    }

    @Test func nothingStagedStaysQuiet() {
        let w = World(), u = make(w, staged: false)
        u.evaluateRestart()
        #expect(u.countdownEnd == nil)
    }

    @Test func inputDuringCountdownCancelsSilently() {
        let w = World(), u = make(w)
        u.evaluateRestart()
        w.inputs.idleSeconds = 1
        u.countdownTick()
        #expect(u.countdownEnd == nil)
        #expect(u.restartDeferrals == 0)   // silent: not counted as a user cancellation
        #expect(w.restarts == 0)
    }

    @Test func workingSessionDuringCountdownCancels() {
        let w = World(), u = make(w)
        u.evaluateRestart()
        w.inputs.working = 1
        u.countdownTick()
        #expect(u.countdownEnd == nil)
    }

    @Test func countdownEndRestartsOnce() {
        let w = World(), u = make(w)
        u.evaluateRestart()
        w.now = w.now.addingTimeInterval(59); u.countdownTick()
        #expect(w.restarts == 0)
        w.inputs.idleSeconds = 400
        w.now = w.now.addingTimeInterval(2); u.countdownTick()
        #expect(w.restarts == 1)
        #expect(u.countdownEnd == nil)
    }

    @Test func userCancelBlocksNextAttemptForFourHours() {
        let w = World(), u = make(w)
        u.evaluateRestart()
        u.cancelCountdownByUser()
        #expect(u.countdownEnd == nil && u.restartDeferrals == 1)
        w.now = w.now.addingTimeInterval(3 * 3600); u.evaluateRestart()
        #expect(u.countdownEnd == nil)
        w.now = w.now.addingTimeInterval(2 * 3600); u.evaluateRestart()
        #expect(u.countdownEnd != nil)
    }

    @Test func threeCancelsLeaveOnlyThePill() {
        let w = World(), u = make(w)
        for _ in 0..<3 {
            u.evaluateRestart()
            u.cancelCountdownByUser()
            w.now = w.now.addingTimeInterval(5 * 3600)
        }
        #expect(u.restartDeferrals == 3)
        u.evaluateRestart()
        #expect(u.countdownEnd == nil)
    }
}
