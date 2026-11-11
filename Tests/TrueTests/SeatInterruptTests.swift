import Foundation
import Testing
@testable import True

@Suite @MainActor struct SeatInterruptTests {
    @Test func recordedCodexScreenAndProse() {
        let facts = CodexSeat().screen
        #expect(facts.dialogVisible(CodexRecordings.dialog))
        #expect(!facts.dialogVisible(CodexRecordings.dialog + "\n› Ask Codex to do anything"))
        #expect(!facts.dialogVisible(CodexRecordings.dialog.replacingOccurrences(of: "› 1.", with: "1.")))
        #expect(!facts.dialogVisible("Would you like to run the following command?\n1. Yes, proceed\n2. No\nSome prose"))
        #expect(facts.isBusy(CodexRecordings.busy))
        #expect(facts.isBusy(CodexRecordings.busy + String(repeating: "\n    ", count: 40)))
        #expect(!facts.isBusy("• Working (means esc to interrupt)"))
        #expect(!facts.isBusy("The screen says esc to interrupt when busy."))
        #expect(!facts.isBusy(CodexRecordings.dialog))
        #expect(facts.answerKeys.approve == "\r" && facts.answerKeys.deny == "\u{1B}" && facts.interruptKey == "\u{1B}")
        #expect(ClaudeSeat().screen.isBusy("esc to interrupt"))
        #expect(!ClaudeSeat().screen.dialogVisible(CodexRecordings.dialog))
    }
    @Test func eventAndScreenFallbackLand() async {
        for useEvent in [true, false] {
            let engine = SeatInterrupt(), pane = UUID()
            var screen = CodexRecordings.busy, event: PaneEvent?, keys: [String] = []
            let result = await engine.perform(pane: pane, facts: CodexSeat().screen, working: { true }, read: { screen }, event: { event }, send: { keys.append($0) }, pause: {
                if useEvent { event = PaneEvent(pane: pane, kind: .idle, message: "", at: Date()) }
                else { screen = "› Ask Codex to do anything" }
            })
            #expect(result == .landed && keys == ["\u{1B}"])
        }
    }
    @Test func unverifiedNeverSendsASecondEscape() async {
        let engine = SeatInterrupt(), pane = UUID()
        var keys: [String] = []
        func attempt() async -> PaneDelivery.Outcome {
            await engine.perform(pane: pane, facts: CodexSeat().screen, working: { true }, read: { CodexRecordings.busy }, event: { nil }, send: { keys.append($0) }, pause: { await Task.yield() })
        }
        #expect(await attempt() == .unverified)
        #expect(await attempt() == .promptGone)
        #expect(keys == ["\u{1B}"])
        engine.reset(pane)
        #expect(await attempt() == .unverified && keys.count == 2)
    }
    @Test func nothingRunningAndNoTerminal() async {
        let engine = SeatInterrupt(), pane = UUID()
        var keys: [String] = []
        let none = await engine.perform(pane: pane, facts: CodexSeat().screen, working: { false }, read: { CodexRecordings.busy }, event: { nil }, send: { keys.append($0) })
        #expect(none == .promptGone && keys.isEmpty)
        let gone = await engine.perform(pane: pane, facts: CodexSeat().screen, working: { true }, read: { nil }, event: { nil }, send: { keys.append($0) })
        #expect(gone == .noPane && keys.isEmpty)
    }
    @Test func turnEndsOrDialogAppearsAtWriteBoundary() async {
        for dialog in [false, true] {
            let engine = SeatInterrupt(), pane = UUID()
            var reads = 0, keys: [String] = []
            let result = await engine.perform(pane: pane, facts: CodexSeat().screen, working: { true }, read: {
                reads += 1
                return reads == 1 ? CodexRecordings.busy : (dialog ? CodexRecordings.dialog : "› Ask Codex to do anything")
            }, event: { nil }, send: { keys.append($0) })
            #expect(result == .promptGone && keys.isEmpty)
        }
    }
    @Test func twoSimultaneousPressesAndANewPrompt() async {
        let engine = SeatInterrupt(), pane = UUID()
        var keys: [String] = [], second: PaneDelivery.Outcome?
        let first = Task {
            await engine.perform(pane: pane, facts: CodexSeat().screen, working: { true }, read: { CodexRecordings.busy }, event: { nil }, send: { keys.append($0) }, pause: {
                if second == nil {
                    second = await engine.perform(pane: pane, facts: CodexSeat().screen, working: { true }, read: { CodexRecordings.busy }, event: { nil }, send: { keys.append($0) })
                    engine.reset(pane) // a new prompt wins over the old verification
                }
                await Task.yield()
            })
        }
        #expect(await eventually { second != nil })
        #expect(await first.value == .promptGone && second == .promptGone && keys == ["\u{1B}"])
    }
}
