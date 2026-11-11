import Foundation

enum DictationResult: Equatable {
    case text(String)
    case failure(String)
}

/// Runs `whisper-cli` on a 16 kHz WAV. The WAV (and any -otxt side file) is deleted on every path.
struct Transcriber: Sendable {
    var binary = DictationSettings.binaryPath
    /// timeout = base + perAudioSecond x seconds, capped.
    var timeoutBase = 60.0
    var timeoutPerSecond = 0.5
    var timeoutCap = 210.0
    var killGrace = 2.0

    func timeout(forSeconds s: Double) -> Double { min(timeoutCap, timeoutBase + timeoutPerSecond * s) }

    func argv(wav: URL, model: String, language: String, vocabulary: String, outBase: String) -> [String] {
        var a = ["-m", model, "-f", wav.path, "-nt", "-np", "-otxt", "-of", outBase, "-l", language]
        let v = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { a += ["--prompt", v] }
        return a
    }

    func transcribe(wav: URL, seconds: Double, model: String, language: String, vocabulary: String) -> DictationResult {
        let outBase = wav.deletingPathExtension().path
        let txt = outBase + ".txt"
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(atPath: txt)
        }
        guard language == "auto" || language == "en" else { return .failure("Language must be auto or en.") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = argv(wav: wav, model: model, language: language, vocabulary: vocabulary, outBase: outBase)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        // Read via handlers (no thread parks in read(2)), so a daemonised child holding the pipe cannot leak one.
        let buf = LockedData()
        out.fileHandleForReading.readabilityHandler = { h in buf.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return .failure("Transcription failed (exit -1).") }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        if done.wait(timeout: .now() + timeout(forSeconds: seconds)) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + killGrace) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + killGrace) }
            return .failure("Transcription timed out.")
        }
        // Let the last bytes arrive, bounded.
        Thread.sleep(forTimeInterval: 0.05)
        guard p.terminationStatus == 0 else { return .failure("Transcription failed (exit \(p.terminationStatus)).") }
        let fileText = (try? String(contentsOfFile: txt, encoding: .utf8)) ?? ""
        let raw = fileText.isEmpty ? (String(data: buf.value, encoding: .utf8) ?? "") : fileText
        let cleaned = DictationCleaner.clean(raw, seconds: seconds)
        return cleaned.isEmpty ? .failure("Heard nothing") : .text(cleaned)
    }
}

final class LockedData: @unchecked Sendable {
    private let l = NSLock(); private var d = Data()
    func append(_ x: Data) { l.lock(); d.append(x); l.unlock() }
    var value: Data { l.lock(); defer { l.unlock() }; return d }
}
