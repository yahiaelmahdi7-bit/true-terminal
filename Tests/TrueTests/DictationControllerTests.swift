import Testing
import Foundation
@testable import True

@MainActor private final class FakePane: DictationPane {
    var bracketed = false
    var received: [String] = []     // the bytes pasteText would send, as text
    func pasteText(_ text: String) {
        // Mirrors TrueTerminalView.pasteText: sanitise, wrap when bracketed.
        let t = TerminalDrop.sanitizedPaste(text, bracketed: bracketed)
        received.append(bracketed ? "\u{1B}[200~\(t)\u{1B}[201~" : t)
    }
}

private final class FakeRecorder: DictationRecording, @unchecked Sendable {
    var onCap: (@Sendable () -> Void)?
    var onConfigChange: (@Sendable () -> Void)?
    var started = false, stopped = false, cancelled = false
    var samples = [Float](repeating: 0.1, count: 32_000)
    func start() throws { started = true }
    func stop() -> (samples: [Float], seconds: Double) { stopped = true; return (samples, Double(samples.count) / 16_000) }
    func cancel() { cancelled = true; stopped = true }
}

@MainActor private final class Rig {
    let pane = FakePane()
    let paneID = UUID()
    var focused: UUID?
    var paneAlive = true
    let rec = FakeRecorder()
    var clip: [String] = []
    var transcript: DictationResult = .text("hello there")
    var gate: AsyncStream<Void>.Continuation?
    var mic = MicStatus.authorized
    var bin = "/bin/sh"
    var model = "/etc/hosts"
    var lang = "auto"
    var requested = false
    var transcribeCalls = 0
    var ctl: DictationController!
    init(hold: Duration = .milliseconds(30), cap: Duration = .seconds(60), hold_transcribe: Bool = false) {
        focused = paneID
        var env = DictationEnv()
        env.enabled = { true }
        env.focusedPane = { [unowned self] in focused }
        env.pane = { [unowned self] id in paneAlive && id == paneID ? pane : nil }
        env.makeRecorder = { [unowned self] in rec }
        env.micStatus = { [unowned self] in mic }
        env.requestMic = { [unowned self] in requested = true }
        env.binaryPath = { [unowned self] in bin }
        env.modelPath = { [unowned self] in model }
        env.language = { [unowned self] in lang }
        env.writeWav = { _ in URL(fileURLWithPath: "/tmp/none.wav") }
        env.clipboard = { [unowned self] in clip.append($0) }
        env.holdDelay = hold; env.maxSeconds = cap; env.messageDuration = .seconds(30)
        let (stream, cont) = AsyncStream<Void>.makeStream()
        gate = cont
        let slow = hold_transcribe
        env.transcribe = { [unowned self] _, _, _, _, _ in
            await MainActor.run { self.transcribeCalls += 1 }
            if slow { for await _ in stream { break } }
            return await MainActor.run { self.transcript }
        }
        ctl = DictationController(env: env)
    }
    func holdPastDelay() async { ctl.keyDown(); _ = await eventually(.seconds(40)) { ctl.isRecording } }
    func settle() async { _ = await eventually(.seconds(40)) { ctl.isIdle } }
}

@MainActor @Suite struct DictationControllerTests {
    @Test func insertsIntoKeyDownPaneEvenWhenFocusMoved() async {
        let r = Rig(); await r.holdPastDelay()
        #expect(r.rec.started)
        r.focused = UUID()      // focus moved elsewhere while talking
        r.ctl.keyUp(); await r.settle()
        #expect(r.pane.received == ["hello there"])
        #expect(r.ctl.pill == nil)
    }

    @Test func closedPaneGoesToClipboard() async {
        let r = Rig(); await r.holdPastDelay()
        r.paneAlive = false
        r.ctl.keyUp(); await r.settle()
        #expect(r.clip == ["hello there"])
        #expect(r.ctl.pill == .message("Pane closed, text not sent"))
    }

    @Test func bracketedWrapAndPlainNewlines() async {
        let r = Rig(); r.transcript = .text("line one\nline two"); r.pane.bracketed = true
        await r.holdPastDelay(); r.ctl.keyUp(); await r.settle()
        #expect(r.pane.received == ["\u{1B}[200~line one\nline two\u{1B}[201~"])
        let r2 = Rig(); r2.transcript = .text("line one\nline two")
        await r2.holdPastDelay(); r2.ctl.keyUp(); await r2.settle()
        #expect(r2.pane.received == ["line one line two"])
    }

    @Test func escStrippedAndNoTrailingNewline() async {
        let r = Rig(); r.transcript = .text("hi\u{1B}[31m there")
        await r.holdPastDelay(); r.ctl.keyUp(); await r.settle()
        let got = r.pane.received[0]
        #expect(!got.contains("\u{1B}"))
        #expect(!got.hasSuffix("\n") && !got.hasSuffix("\r"))
    }

    @Test func shortTapNeverRecords() async {
        let r = Rig(hold: .milliseconds(200))
        r.ctl.keyDown(); r.ctl.keyUp()
        try? await Task.sleep(for: .milliseconds(350))
        #expect(!r.rec.started); #expect(r.ctl.isIdle)
    }

    @Test func optionChordNeverRecordsAndLateChordDiscards() async {
        let r = Rig(hold: .milliseconds(200))
        r.ctl.keyDown(); r.ctl.otherKey()        // Option+B inside 300 ms
        try? await Task.sleep(for: .milliseconds(350))
        #expect(!r.rec.started); #expect(r.ctl.isIdle)
        let r2 = Rig(); await r2.holdPastDelay()
        r2.ctl.otherKey()                         // after the delay: stop and discard
        #expect(r2.rec.cancelled); #expect(r2.ctl.isIdle)
        r2.ctl.keyUp(); try? await Task.sleep(for: .milliseconds(50))
        #expect(r2.pane.received.isEmpty)
    }

    @Test func resignKeyMidHoldPastesNothing() async {
        let r = Rig(); await r.holdPastDelay()
        r.ctl.discard()
        #expect(r.rec.cancelled); #expect(r.ctl.isIdle); #expect(r.ctl.pill == nil)
        r.ctl.keyUp(); try? await Task.sleep(for: .milliseconds(50))
        #expect(r.pane.received.isEmpty); #expect(r.transcribeCalls == 0)
    }

    @Test func capStopsAndTranscribes() async {
        let r = Rig(cap: .milliseconds(100))
        r.ctl.keyDown()
        _ = await eventually(.seconds(40)) { r.transcribeCalls > 0 }
        await r.settle()
        #expect(r.rec.stopped); #expect(r.pane.received == ["hello there"])
    }

    @Test func holdDuringTranscriptionRefused() async {
        let r = Rig(hold_transcribe: true); await r.holdPastDelay()
        r.ctl.keyUp()
        #expect(r.ctl.pill == .transcribing(note: nil))
        r.ctl.keyDown()
        #expect(r.ctl.pill == .message("Still transcribing"))
        #expect(!r.ctl.isRecording)
        r.gate?.yield(); await r.settle()
        #expect(r.pane.received == ["hello there"])
    }

    @Test func missingBinaryModelLanguageMessages() {
        let r = Rig(); r.bin = "/nope/whisper-cli"; r.ctl.keyDown()
        #expect(r.ctl.pill == .message("Whisper is not installed. Set it up in Settings > Dictation."))
        let r2 = Rig(); r2.model = "/nope/m.bin"; r2.ctl.keyDown()
        #expect(r2.ctl.pill == .message("Speech model missing. Download it in Settings > Dictation."))
        let r3 = Rig(); r3.lang = "fr"; r3.ctl.keyDown()
        #expect(r3.ctl.pill == .message("Language must be auto or en."))
        for x in [r, r2, r3] { #expect(x.ctl.isIdle); #expect(!x.rec.started) }
    }

    @Test func micDeniedAndNotDeterminedAndNoPane() {
        let r = Rig(); r.mic = .denied; r.ctl.keyDown()
        #expect(r.ctl.pill == .message("Microphone blocked. Turn on True in System Settings > Privacy & Security > Microphone."))
        let r2 = Rig(); r2.mic = .notDetermined; r2.ctl.keyDown()
        #expect(r2.requested); #expect(r2.ctl.isIdle)
        let r3 = Rig(); r3.focused = nil; r3.ctl.keyDown()
        #expect(r3.ctl.pill == .message("Click a pane first"))
    }

    @Test func silentClipHeardNothing() async {
        let r = Rig(); r.rec.samples = [Float](repeating: 0, count: 32_000)
        await r.holdPastDelay(); r.ctl.keyUp()
        #expect(r.ctl.pill == .message("Heard nothing")); #expect(r.transcribeCalls == 0)
    }
}
