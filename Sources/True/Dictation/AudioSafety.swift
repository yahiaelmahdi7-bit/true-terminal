@preconcurrency import AVFoundation

/// Lifted from the removed voice code. Axon crash lesson:
/// never hand AVFAudio a 0 Hz / 0 ch format; `installTap` raises an uncatchable NSException and the process aborts.
/// Validation is the only defence. `nil` = the input device is not ready (post-sleep, unplugged, Bluetooth handoff): refuse.
enum AudioSafety {
    static func safeTapFormat(_ format: AVAudioFormat) -> AVAudioFormat? {
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return format
    }
}

extension AVAudioNode {
    func safeTapFormat(bus: AVAudioNodeBus = 0) -> AVAudioFormat? { AudioSafety.safeTapFormat(outputFormat(forBus: bus)) }
}

enum AudioSetupError: LocalizedError {
    case inputNotReady
    var errorDescription: String? { "Mic unavailable (no input device or 0 Hz format). Try again after reconnecting." }
}
