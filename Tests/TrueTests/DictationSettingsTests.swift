import Testing
import Foundation
@testable import True

@Suite struct DictationSettingsTests {
    private func fresh() -> UserDefaults {
        let n = "dict-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: n)!
        d.removePersistentDomain(forName: n)
        return d
    }

    @Test func defaults() {
        let d = fresh()
        #expect(DictationSettings.enabled(d) == false)
        #expect(DictationSettings.key(d) == .rightOption)
        #expect(DictationSettings.key(d).keyCode == 61)
        #expect(DictationSettings.language(d) == "auto")
        #expect(DictationSettings.vocabulary(d).contains("Codex"))
        #expect(DictationSettings.modelPath(d).hasSuffix("/.cache/whisper/ggml-large-v3-turbo-q5_0.bin"))
    }

    @Test func modelValidation() throws {
        let f = NSTemporaryDirectory() + "m-\(UUID().uuidString)"
        #expect(!DictationSettings.modelValid(f))
        FileManager.default.createFile(atPath: f, contents: Data())
        #expect(!DictationSettings.modelValid(f))
        try Data([1]).write(to: URL(fileURLWithPath: f))
        #expect(DictationSettings.modelValid(f))
        try? FileManager.default.removeItem(atPath: f)
    }

    @Test func micStringsReworded() throws {
        for p in ["scripts/package.sh", "scripts/public/scripts/package.sh"] {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path) { continue }   // the public tree has only scripts/package.sh
            let s = try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8)
            #expect(s.contains("True uses the microphone only while you hold the dictation key"))
        }
    }
}
