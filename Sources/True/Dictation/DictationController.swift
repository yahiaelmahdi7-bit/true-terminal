import AppKit
import AVFoundation
import SwiftUI

protocol DictationRecording: AnyObject {
    var onCap: (@Sendable () -> Void)? { get set }
    var onConfigChange: (@Sendable () -> Void)? { get set }
    func start() throws
    func stop() -> (samples: [Float], seconds: Double)
    func cancel()
}
extension AudioRecorder: DictationRecording {}

@MainActor protocol DictationPane: AnyObject { func pasteText(_ text: String) }
extension TrueTerminalView: DictationPane {}

enum MicStatus { case authorized, denied, notDetermined }

/// Everything the controller touches outside itself, so tests can swap it all.
@MainActor struct DictationEnv {
    var enabled: () -> Bool = { DictationSettings.enabled() }
    var focusedPane: () -> UUID? = {
        (NSApp.keyWindow?.firstResponder as? TrueTerminalView)?.paneID
    }
    var pane: (UUID) -> DictationPane? = { TerminalRegistry.shared.view(for: $0) }
    var makeRecorder: () -> DictationRecording = { AudioRecorder() }
    var micStatus: () -> MicStatus = {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
    var requestMic: () -> Void = { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
    var binaryPath: () -> String = { DictationSettings.binaryPath }
    var modelPath: () -> String = { DictationSettings.modelPath() }
    var language: () -> String = { DictationSettings.language() }
    var vocabulary: () -> String = { DictationSettings.vocabulary() }
    var writeWav: ([Float]) -> URL? = { WavWriter.write($0, sampleRate: 16_000) }
    var transcribe: @Sendable (URL, Double, String, String, String) async -> DictationResult = { wav, secs, model, lang, vocab in
        await Task.detached { Transcriber().transcribe(wav: wav, seconds: secs, model: model, language: lang, vocabulary: vocab) }.value
    }
    var clipboard: (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
    var holdDelay: Duration = .milliseconds(300)
    var maxSeconds: Duration = .seconds(300)
    var messageDuration: Duration = .seconds(3)
}

/// Push-to-talk: hold the key 300 ms in a True pane -> record -> release -> whisper -> paste into the pane that was
/// focused at key-down. Idle = no timers and no polling: the only Tasks exist during a hold / a message.
@MainActor @Observable
final class DictationController {
    static let shared = DictationController()

    enum Pill: Equatable { case listening, transcribing(note: String?), message(String) }
    private(set) var pill: Pill?

    private enum State { case idle, pending(UUID), recording(UUID), transcribing }
    private var state: State = .idle
    private var env: DictationEnv
    private var recorder: DictationRecording?
    private var holdTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var generation = 0
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(env: DictationEnv = DictationEnv()) { self.env = env }

    var isIdle: Bool { if case .idle = state { true } else { false } }
    var isRecording: Bool { if case .recording = state { true } else { false } }

    // MARK: install (event-driven; nothing runs until a key event)

    func start() {
        guard monitor == nil else { return }
        DictationFiles.sweep()    // launch-time file delete only, no timer
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handle(event)
            return event          // never consumed: Option still reaches the terminal for chords
        }
        let nc = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.discard() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.discard() }
        })
    }

    private func handle(_ e: NSEvent) {
        guard env.enabled() else { return }
        let key = DictationSettings.key()
        switch e.type {
        case .flagsChanged:
            if key.isModifier, e.keyCode == key.keyCode, let f = key.flag {
                if e.modifierFlags.contains(f) { keyDown() } else { keyUp() }
            } else { otherKey() }
        case .keyDown:
            if !key.isModifier, e.keyCode == key.keyCode { if !e.isARepeat { keyDown() } } else { otherKey() }
        case .keyUp:
            if !key.isModifier, e.keyCode == key.keyCode { keyUp() }
        default: break
        }
    }

    // MARK: state machine (called directly by tests)

    func keyDown() {
        guard env.enabled() else { return }
        switch state {
        case .transcribing: show("Still transcribing"); return
        case .pending, .recording: return
        case .idle: break
        }
        guard let pane = env.focusedPane() else { show("Click a pane first"); return }
        if let msg = preflight() { show(msg); return }
        state = .pending(pane)
        generation += 1
        let gen = generation
        holdTask = Task { [weak self, delay = env.holdDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.beginRecording(pane, gen)
        }
    }

    func keyUp() {
        switch state {
        case .pending: cancelHold(); state = .idle
        case .recording: finish(note: nil)
        default: break
        }
    }

    /// Any other key while pending or recording: an Option chord, not dictation. Cancels and discards.
    func otherKey() {
        switch state {
        case .pending, .recording: discard()
        default: break
        }
    }

    /// Resign key / deactivate / sleep / device change / mic prompt: stop the mic, paste nothing.
    func discard() {
        switch state {
        case .pending, .recording:
            cancelHold(); capTask?.cancel(); capTask = nil
            recorder?.cancel(); recorder = nil
            state = .idle; pill = nil
        default: break
        }
    }

    private func preflight() -> String? {
        let bin = env.binaryPath()
        if !FileManager.default.isExecutableFile(atPath: bin) {
            return "Whisper is not installed. Set it up in Settings > Dictation."
        }
        let model = env.modelPath()
        if !DictationSettings.modelValid(model) { return "Speech model missing. Download it in Settings > Dictation." }
        let lang = env.language()
        if lang != "auto" && lang != "en" { return "Language must be auto or en." }
        switch env.micStatus() {
        case .authorized: return nil
        case .denied: return "Microphone blocked. Turn on True in System Settings > Privacy & Security > Microphone."
        case .notDetermined: env.requestMic(); return ""   // the system prompt is the message; this take is discarded
        }
    }

    private func beginRecording(_ pane: UUID, _ gen: Int) {
        guard gen == generation, case .pending(let p) = state, p == pane else { return }
        let r = env.makeRecorder()
        r.onConfigChange = { [weak self] in Task { @MainActor in self?.discard() } }
        r.onCap = { [weak self] in Task { @MainActor in self?.capReached() } }
        do { try r.start() } catch {
            state = .idle; show("Mic unavailable (no input device or 0 Hz format). Try again after reconnecting."); return
        }
        recorder = r
        state = .recording(pane)
        pill = .listening
        capTask = Task { [weak self, cap = env.maxSeconds] in
            try? await Task.sleep(for: cap)
            guard !Task.isCancelled else { return }
            self?.capReached()
        }
    }

    private func capReached() { if isRecording { finish(note: "Stopped at 5 min") } }

    private func finish(note: String?) {
        guard case .recording(let paneID) = state, let r = recorder else { return }
        capTask?.cancel(); capTask = nil
        recorder = nil
        let (samples, seconds) = r.stop()
        if DictationCleaner.isSilent(samples: samples, seconds: seconds) {
            state = .idle; show("Heard nothing"); return
        }
        guard let wav = env.writeWav(samples) else { state = .idle; show("Transcription failed (exit -1)."); return }
        state = .transcribing
        pill = .transcribing(note: note)
        let model = env.modelPath(), lang = env.language(), vocab = env.vocabulary()
        let transcribe = env.transcribe
        Task { [weak self] in
            let result = await transcribe(wav, seconds, model, lang, vocab)
            self?.deliver(result, to: paneID)
        }
    }

    private func deliver(_ result: DictationResult, to paneID: UUID) {
        state = .idle
        switch result {
        case .failure(let msg): show(msg)
        case .text(let text):
            if let pane = env.pane(paneID) { pane.pasteText(text); pill = nil }
            else { env.clipboard(text); show("Pane closed, text not sent") }
        }
    }

    private func cancelHold() { holdTask?.cancel(); holdTask = nil; generation += 1 }

    /// A 3 s message pill. The Task exists only while a message is up. "" = nothing to say.
    private func show(_ text: String) {
        messageTask?.cancel(); messageTask = nil
        guard !text.isEmpty else { pill = nil; return }
        pill = .message(text)
        messageTask = Task { [weak self, d = env.messageDuration] in
            try? await Task.sleep(for: d)
            guard !Task.isCancelled else { return }
            if case .message = self?.pill { self?.pill = nil }
        }
    }
}

/// The small title-bar pill: listening · transcribing · a message for 3 s. Absent otherwise.
struct DictationPill: View {
    let controller: DictationController = .shared
    var body: some View {
        Group {
            if let p = controller.pill {
                HStack(spacing: 5) {
                    Circle().fill(Theme.text).frame(width: 5, height: 5)
                    Text(label(p)).lineLimit(1)
                }
                .font(.caption.weight(.medium)).foregroundStyle(Theme.text)
                .padding(.horizontal, 9).frame(minHeight: Theme.Hit.control)
                .background(Theme.hubCardFill, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                .help("Dictation")
            }
        }
        .onAppear { controller.start() }
    }
    private func label(_ p: DictationController.Pill) -> String {
        switch p {
        case .listening: "Listening"
        case .transcribing(let note): note.map { "\($0) · Transcribing" } ?? "Transcribing"
        case .message(let m): m
        }
    }
}
