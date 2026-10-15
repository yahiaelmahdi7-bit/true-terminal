import Testing
import Foundation
@testable import True

struct UpdateLogicTests {
    @Test func semverCompare() {
        #expect(UpdateLogic.compare("1.1.10", "1.1.2") == 1)
        #expect(UpdateLogic.compare("v1.1.2", "1.1.2") == 0)
        #expect(UpdateLogic.compare("1.1.2", "1.2") == -1)
        #expect(UpdateLogic.isNewer("v1.1.10", than: "1.1.2"))
        #expect(!UpdateLogic.isNewer("1.1.2", than: "1.1.2"))
        #expect(!UpdateLogic.isNewer("1.0.9", than: "1.1.0"))
        #expect(UpdateLogic.isNewer("0.0.1", than: "0.0.0-dev"))
        #expect(UpdateLogic.compare("junk", "1.0") == nil)
    }

    @Test func checksum() {
        let data = Data("hello".utf8)
        let h = UpdateLogic.sha256Hex(data)
        #expect(h == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(UpdateLogic.verify(actual: h, sumFile: "\(h)  True-macOS.zip\n"))
        #expect(UpdateLogic.verify(actual: h.uppercased(), sumFile: h))
        #expect(!UpdateLogic.verify(actual: h, sumFile: String(repeating: "0", count: 64)))
        #expect(!UpdateLogic.verify(actual: h, sumFile: "abc123"))
        #expect(!UpdateLogic.verify(actual: nil, sumFile: h))
        #expect(!UpdateLogic.verify(actual: h, sumFile: ""))
    }

    @Test func fileHashMatchesDataHash() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("true-upd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: f) }
        try Data("hello".utf8).write(to: f)
        #expect(UpdateLogic.sha256Hex(fileAt: f) == UpdateLogic.sha256Hex(Data("hello".utf8)))
    }

    @Test func installPlan() {
        #expect(UpdateLogic.plan(bundlePath: "/Applications/True.app", bundleWritable: true, parentWritable: true) == .install)
        #expect(UpdateLogic.plan(bundlePath: "/Applications/True.app", bundleWritable: false, parentWritable: true) == .notify)
        #expect(UpdateLogic.plan(bundlePath: "/Applications/True.app", bundleWritable: true, parentWritable: false) == .notify)
        let t = "/private/var/folders/x/AppTranslocation/ABC/d/True.app"
        #expect(UpdateLogic.isTranslocated(t))
        #expect(UpdateLogic.plan(bundlePath: t, bundleWritable: true, parentWritable: true) == .notify)
    }

    static func feed(_ patch: [String: Any] = [:], drop: [String] = []) -> Data {
        let a = "https://github.com/o/r/releases/download/v1.2.0/"
        var o: [String: Any] = [
            "tag_name": "v1.2.0", "draft": false, "prerelease": false, "html_url": "https://github.com/o/r/releases/tag/v1.2.0",
            "assets": [["name": "True-macOS.zip", "browser_download_url": a + "True-macOS.zip"],
                       ["name": "True-macOS.zip.sha256", "browser_download_url": a + "True-macOS.zip.sha256"]],
        ]
        for (k, v) in patch { o[k] = v }
        for k in drop { o[k] = nil }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    @Test func feedParsing() {
        guard case .release(let r) = UpdateLogic.parseFeed(Self.feed()) else { Issue.record("expected release"); return }
        #expect(r.version == "1.2.0" && r.tag == "v1.2.0" && r.zipURL.lastPathComponent == "True-macOS.zip")
        #expect(UpdateLogic.parseFeed(Self.feed(["draft": true])) == .skip)
        #expect(UpdateLogic.parseFeed(Self.feed(["prerelease": true])) == .skip)
        func invalid(_ d: Data) -> Bool { if case .invalid = UpdateLogic.parseFeed(d) { return true }; return false }
        #expect(invalid(Self.feed(["assets": []])))
        #expect(invalid(Self.feed(drop: ["tag_name"])))
        #expect(invalid(Self.feed(drop: ["html_url"])))
        #expect(invalid(Data("nope".utf8)))
        let evil = "https://evil.example.com/"
        #expect(invalid(Self.feed(["assets": [["name": "True-macOS.zip", "browser_download_url": evil + "a"],
                                              ["name": "True-macOS.zip.sha256", "browser_download_url": evil + "b"]]])))
    }

    @Test func inertWithoutPlistKey() {
        #expect(UpdateLogic.repo(from: nil) == nil)
        #expect(UpdateLogic.repo(from: [:]) == nil)
        #expect(UpdateLogic.repo(from: ["TrueUpdateRepo": "  "]) == nil)
        #expect(UpdateLogic.repo(from: ["TrueUpdateRepo": "../etc"]) == nil)
        #expect(UpdateLogic.repo(from: ["TrueUpdateRepo": "a/b/c"]) == nil)
        #expect(UpdateLogic.repo(from: ["TrueUpdateRepo": "yahiaelmahdi7-bit/true-terminal"]) == "yahiaelmahdi7-bit/true-terminal")
    }

    @MainActor @Test func updaterWithoutKeyIsInert() {
        let u = Updater(info: [:])
        #expect(!u.enabled && u.repo == nil)
        u.start()
        #expect(u.notice == nil)
    }

    @Test func stagedAppChecks() {
        let ok: [String: Any] = ["CFBundleIdentifier": "com.x.true", "CFBundleShortVersionString": "1.2.0", "LSMinimumSystemVersion": "14.0"]
        func problem(_ i: [String: Any]?, own: String = "1.1.2", os: String = "14.5") -> String? {
            UpdateLogic.stagedProblem(info: i, ownBundleID: "com.x.true", ownVersion: own, osVersion: os)
        }
        #expect(problem(ok) == nil)
        #expect(problem(nil) != nil)
        #expect(problem(ok.merging(["CFBundleIdentifier": "com.other"]) { $1 }) != nil)
        #expect(problem(ok.merging(["LSMinimumSystemVersion": "15.0"]) { $1 }) != nil)
        #expect(problem(ok, own: "1.2.0") != nil)
        #expect(problem(ok, own: "1.3.0") != nil)
    }

    @Test func swapReplacesAndRestores() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("true-swap-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let live = dir.appendingPathComponent("True.app"), staged = dir.appendingPathComponent("new.app"), backup = dir.appendingPathComponent("bk")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: live.appendingPathComponent("v"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("v"))
        try UpdateInstaller.swap(live: live, with: staged, backupDir: backup)
        #expect(try String(contentsOf: live.appendingPathComponent("v"), encoding: .utf8) == "new")
        #expect(!fm.fileExists(atPath: staged.path))
        #expect(try fm.contentsOfDirectory(atPath: backup.path).isEmpty)

        // Staged copy missing: the old app must come back untouched.
        #expect(throws: (any Error).self) {
            try UpdateInstaller.swap(live: live, with: dir.appendingPathComponent("gone.app"), backupDir: backup)
        }
        #expect(try String(contentsOf: live.appendingPathComponent("v"), encoding: .utf8) == "new")
    }
}
