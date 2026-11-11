import Testing
import Foundation
@testable import True

@Suite struct DictationSetupTests {
    static func tmp() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ds-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func exe(_ u: URL, _ body: String = "true") {
        try? "#!/bin/sh\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }

    @Test func engineUserPathWins() {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let user = d.appendingPathComponent("mine"), a = d.appendingPathComponent("a"), b = d.appendingPathComponent("b")
        Self.exe(user); Self.exe(a); Self.exe(b)
        #expect(DictationEngine.resolve(userPath: user.path, candidates: [a.path, b.path]) == user.path)
    }

    @Test func engineFallsThroughToFirstExecutableCandidate() throws {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let notExec = d.appendingPathComponent("plain"), b = d.appendingPathComponent("b"), c = d.appendingPathComponent("c")
        try Data([1]).write(to: notExec); Self.exe(b); Self.exe(c)
        let missing = d.appendingPathComponent("gone").path
        #expect(DictationEngine.resolve(userPath: missing, candidates: [d.appendingPathComponent("none").path, notExec.path, b.path, c.path]) == b.path)
        #expect(DictationEngine.resolve(userPath: notExec.path, candidates: [c.path]) == c.path)
        #expect(DictationEngine.resolve(userPath: "", candidates: [notExec.path]) == nil)
    }

    @Test func modelResolutionOrder() throws {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let one = d.appendingPathComponent("one"), two = d.appendingPathComponent("two")
        for x in [one, two] { try FileManager.default.createDirectory(at: x, withIntermediateDirectories: true) }
        let dirs = [one.path, two.path], files = ["big.bin", "small.bin"]
        #expect(DictationModels.resolve(userPath: "", dirs: dirs, files: files) == nil)
        try Data([1]).write(to: two.appendingPathComponent("big.bin"))
        #expect(DictationModels.resolve(userPath: "", dirs: dirs, files: files) == two.path + "/big.bin")
        try Data([1]).write(to: one.appendingPathComponent("small.bin"))
        #expect(DictationModels.resolve(userPath: "", dirs: dirs, files: files) == one.path + "/small.bin")
        // Empty file does not count.
        FileManager.default.createFile(atPath: one.path + "/big.bin", contents: Data())
        #expect(DictationModels.resolve(userPath: "", dirs: dirs, files: files) == one.path + "/small.bin")
        // A valid user path beats the directories; an invalid one is ignored.
        let mine = d.appendingPathComponent("mine.bin"); try Data([1]).write(to: mine)
        #expect(DictationModels.resolve(userPath: mine.path, dirs: dirs, files: files) == mine.path)
        #expect(DictationModels.resolve(userPath: d.path + "/nope", dirs: dirs, files: files) == one.path + "/small.bin")
    }

    @Test func pinnedModels() {
        #expect(WhisperModel.best.sha256.count == 64 && WhisperModel.light.sha256.count == 64)
        #expect(WhisperModel.best.url.absoluteString == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")
        #expect(DictationModels.downloadDir.path.hasSuffix("/Library/Application Support/True/whisper"))
    }

    // MARK: downloader (file:// source, no network)

    private func source(_ dir: URL, _ bytes: [UInt8]) throws -> (URL, WhisperModel) {
        let u = dir.appendingPathComponent("src.bin")
        try Data(bytes).write(to: u)
        let m = WhisperModel(file: "tiny.bin", sha256: ModelDownloader.sha256(of: u)!, size: Int64(bytes.count), title: "T", sizeLabel: "1 B")
        return (u, m)
    }
    private func defaults() -> UserDefaults {
        let n = "dl-test-\(UUID().uuidString)"; let d = UserDefaults(suiteName: n)!; d.removePersistentDomain(forName: n); return d
    }

    @Test func goodHashLandsAtomicallyAndSetsPath() async throws {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let (src, m) = try source(d, Array(repeating: 7, count: 100_000))
        let target = d.appendingPathComponent("models"), ud = defaults()
        let dl = ModelDownloader(model: m, source: src, directory: target, defaults: ud, freeSpace: { _ in .max })
        let out = try await dl.run { _ in }
        #expect(out.path == target.appendingPathComponent("tiny.bin").path)
        #expect(ud.string(forKey: DictationSettings.modelKey) == out.path)
        #expect(DictationSettings.modelValid(out.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["tiny.bin"])
    }

    @Test func badHashLeavesNoFile() async throws {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let (src, good) = try source(d, Array(repeating: 7, count: 5000))
        let bad = WhisperModel(file: good.file, sha256: String(repeating: "0", count: 64), size: good.size, title: "T", sizeLabel: "")
        let target = d.appendingPathComponent("models"), ud = defaults()
        let dl = ModelDownloader(model: bad, source: src, directory: target, defaults: ud, freeSpace: { _ in .max })
        await #expect(throws: DownloadError.badHash) { try await dl.run { _ in } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(ud.string(forKey: DictationSettings.modelKey) == nil)
    }

    @Test func missingSourceFailsCleanly() async throws {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let (_, m) = try source(d, [1, 2, 3])
        let target = d.appendingPathComponent("models")
        let dl = ModelDownloader(model: m, source: d.appendingPathComponent("absent"), directory: target, defaults: defaults(), freeSpace: { _ in .max })
        do { _ = try await dl.run { _ in }; Issue.record("should have thrown") } catch {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func lowDiskRefusesBeforeDownloading() async throws {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let (src, m) = try source(d, [1, 2, 3])
        let target = d.appendingPathComponent("models")
        let dl = ModelDownloader(model: m, source: src, directory: target, defaults: defaults(), freeSpace: { _ in m.size + ModelDownloader.spaceMargin - 1 })
        await #expect(throws: DownloadError.lowDisk(needMB: (m.size + ModelDownloader.spaceMargin) / 1_000_000, haveMB: (m.size + ModelDownloader.spaceMargin - 1) / 1_000_000)) {
            try await dl.run { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let ok = ModelDownloader(model: m, source: src, directory: target, defaults: defaults(), freeSpace: { _ in m.size + ModelDownloader.spaceMargin })
        _ = try await ok.run { _ in }
    }

    // MARK: brew runner (fake brew script)

    @Test func brewSuccessSurfacesLastLine() async {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let b = d.appendingPathComponent("brew"); Self.exe(b, "echo 'Fetching whisper-cpp'; printf 'Pouring\\r50%%\\r'; echo '==> Summary'; exit 0")
        let seen = LockedData()
        let r = await BrewInstaller(brew: b.path).run { seen.append(Data(($0 + "\n").utf8)) }
        #expect(r.ok && r.status == 0 && r.lastLine == "==> Summary")
        #expect(String(decoding: seen.value, as: UTF8.self).contains("Fetching whisper-cpp"))
    }

    @Test func brewFailureReportsStatus() async {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let b = d.appendingPathComponent("brew"); Self.exe(b, "echo 'Error: no bottle'; exit 1")
        let r = await BrewInstaller(brew: b.path).run { _ in }
        #expect(!r.ok && r.status == 1 && r.lastLine == "Error: no bottle")
        #expect(r.errorLine == "Install failed (exit 1): Error: no bottle")
    }

    @Test func brewArgvIsFixedAndTimeoutKills() async {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let b = d.appendingPathComponent("brew"); Self.exe(b, "echo \"$@\"")
        let r = await BrewInstaller(brew: b.path).run { _ in }
        #expect(r.lastLine == "install whisper-cpp")
        let slow = d.appendingPathComponent("slow"); Self.exe(slow, "exec sleep 30")
        let t = await BrewInstaller(brew: slow.path, timeout: 0.3).run { _ in }
        #expect(t.outcome == .timedOut)
    }

    @Test func brewCancel() async {
        let d = Self.tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let slow = d.appendingPathComponent("slow"); Self.exe(slow, "exec sleep 30")
        let inst = BrewInstaller(brew: slow.path)
        Task { try? await Task.sleep(for: .milliseconds(300)); inst.cancel() }
        let r = await inst.run { _ in }
        #expect(r.outcome == .cancelled)
    }
}
