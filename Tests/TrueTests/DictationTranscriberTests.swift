import Testing
import Foundation
@testable import True

@Suite struct DictationTranscriberTests {
    private func tmp() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// A fake whisper-cli: a shell script with the given body.
    private func fake(_ dir: URL, _ body: String) -> String {
        let p = dir.appendingPathComponent("fake-whisper")
        try? "#!/bin/sh\n\(body)\n".write(to: p, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        return p.path
    }
    private func wav(_ dir: URL) -> URL {
        let u = dir.appendingPathComponent("c.wav"); try? Data([0, 1]).write(to: u); return u
    }
    private func run(_ t: Transcriber, _ w: URL, secs: Double = 5, vocab: String = "Jev") -> DictationResult {
        t.transcribe(wav: w, seconds: secs, model: "/m", language: "auto", vocabulary: vocab)
    }

    @Test func successDeletesWav() {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let w = wav(d)
        let r = run(Transcriber(binary: fake(d, "echo ' hello world'")), w)
        #expect(r == .text("hello world"))
        #expect(!FileManager.default.fileExists(atPath: w.path))
    }

    @Test func argvHasFlagsAndVocabulary() {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let a = Transcriber().argv(wav: wav(d), model: "/m.bin", language: "en", vocabulary: "LEDGER, Jev", outBase: "/o")
        #expect(a.contains("-nt"))
        #expect(a.contains("-otxt"))
        #expect(a[a.firstIndex(of: "--prompt")! + 1] == "LEDGER, Jev")
        #expect(a[a.firstIndex(of: "-l")! + 1] == "en")
        // And it reaches the real process: the fake echoes its own argv.
        let r = run(Transcriber(binary: fake(d, "echo \"$@\"")), wav(d), vocab: "UAE Pass")
        if case .text(let t) = r { #expect(t.contains("--prompt UAE Pass")); #expect(t.contains("-nt")) } else { Issue.record("no text: \(r)") }
    }

    @Test func nonZeroExit() {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let w = wav(d)
        #expect(run(Transcriber(binary: fake(d, "exit 3")), w) == .failure("Transcription failed (exit 3)."))
        #expect(!FileManager.default.fileExists(atPath: w.path))
    }

    @Test func emptyOutputIsHeardNothing() {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        #expect(run(Transcriber(binary: fake(d, "echo '[BLANK_AUDIO]'")), wav(d)) == .failure("Heard nothing"))
        #expect(run(Transcriber(binary: fake(d, "true")), wav(d)) == .failure("Heard nothing"))
    }

    @Test func hangTimesOutAndIsKilled() throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let pidFile = d.appendingPathComponent("pid")
        let w = wav(d)
        var t = Transcriber(binary: fake(d, "echo $$ > \(pidFile.path); exec sleep 60"))
        t.timeoutBase = 4; t.timeoutPerSecond = 0
        let start = Date()
        #expect(run(t, w) == .failure("Transcription timed out."))
        #expect(Date().timeIntervalSince(start) < 8)
        // Under suite-wide load the first exec of a fresh script can take longer than the timeout, so the pid
        // file may not exist; when it does, the process must be gone.
        let pidText = (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        usleep(200_000)
        if let pid = pidText.flatMap({ Int32($0) }) { #expect(kill(pid, 0) != 0) }   // gone
        #expect(!FileManager.default.fileExists(atPath: w.path))
    }

    @Test func badLanguage() {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let r = Transcriber(binary: "/nonexistent").transcribe(wav: wav(d), seconds: 3, model: "/m", language: "fr", vocabulary: "")
        #expect(r == .failure("Language must be auto or en."))
    }

    @Test func timeoutFormula() {
        let t = Transcriber()
        #expect(t.timeout(forSeconds: 10) == 65)
        #expect(t.timeout(forSeconds: 300) == 210)
    }

    @Test func cleaner() {
        #expect(DictationCleaner.clean("[BLANK_AUDIO]\n", seconds: 3) == "")
        #expect(DictationCleaner.clean(" Hello [Music] there\n(music)\n", seconds: 3) == "Hello there")
        #expect(DictationCleaner.clean("Thank you.", seconds: 1.2) == "")
        #expect(DictationCleaner.clean("Thanks for watching!", seconds: 1.9) == "")
        #expect(DictationCleaner.clean("Thank you.", seconds: 5) == "Thank you.")
        #expect(DictationCleaner.isSilent(samples: [Float](repeating: 0, count: 16_000), seconds: 1))
        #expect(DictationCleaner.isSilent(samples: [Float](repeating: 0.3, count: 4000), seconds: 0.25))
        #expect(!DictationCleaner.isSilent(samples: [Float](repeating: 0.1, count: 16_000), seconds: 1))
    }

    @Test func realWhisperJFK() throws {
        let bin = DictationSettings.binaryPath, model = DictationSettings.defaultModelPath
        guard FileManager.default.isExecutableFile(atPath: bin), DictationSettings.modelValid(model) else {
            print("SKIP realWhisperJFK: whisper-cli or model absent"); return
        }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/jfk.wav")
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let w = d.appendingPathComponent("jfk.wav"); try FileManager.default.copyItem(at: src, to: w)
        let r = Transcriber().transcribe(wav: w, seconds: 11, model: model, language: "en", vocabulary: DictationSettings.defaultVocabulary)
        guard case .text(let t) = r else { Issue.record("\(r)"); return }
        #expect(t.contains("And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country."))
        #expect(!FileManager.default.fileExists(atPath: w.path))
    }
}
