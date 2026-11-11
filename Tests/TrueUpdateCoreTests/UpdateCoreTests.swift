import Testing
import Foundation
@testable import TrueUpdateCore

struct UpdateCoreTests {
    @Test func semverCompare() {
        #expect(UpdateCore.compare("1.1.10", "1.1.2") == 1)
        #expect(UpdateCore.compare("v1.1.2", "1.1.2") == 0)
        #expect(UpdateCore.compare("1.1.2", "1.2") == -1)
        #expect(UpdateCore.isNewer("v1.1.10", than: "1.1.2"))
        #expect(!UpdateCore.isNewer("1.1.2", than: "1.1.2"))
        #expect(!UpdateCore.isNewer("1.0.9", than: "1.1.0"))
        #expect(UpdateCore.isNewer("0.0.1", than: "0.0.0-dev"))
        #expect(UpdateCore.compare("junk", "1.0") == nil)
    }

    @Test func checksum() {
        let data = Data("hello".utf8)
        let h = UpdateCore.sha256Hex(data)
        #expect(h == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        #expect(UpdateCore.verify(actual: h, sumFile: "\(h)  True-macOS.zip\n"))
        #expect(UpdateCore.verify(actual: h.uppercased(), sumFile: h))
        #expect(!UpdateCore.verify(actual: h, sumFile: String(repeating: "0", count: 64)))
        #expect(!UpdateCore.verify(actual: h, sumFile: "abc123"))
        #expect(!UpdateCore.verify(actual: nil, sumFile: h))
        #expect(!UpdateCore.verify(actual: h, sumFile: ""))
    }

    @Test func fileHashMatchesDataHash() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("true-upd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: f) }
        try Data("hello".utf8).write(to: f)
        #expect(UpdateCore.sha256Hex(fileAt: f) == UpdateCore.sha256Hex(Data("hello".utf8)))
    }

    @Test func stagedAppChecks() {
        let ok: [String: Any] = ["CFBundleIdentifier": "com.x.true", "CFBundleShortVersionString": "1.2.0", "LSMinimumSystemVersion": "14.0"]
        func problem(_ i: [String: Any]?, own: String = "1.1.2", os: String = "14.5") -> String? {
            UpdateCore.stagedProblem(info: i, ownBundleID: "com.x.true", ownVersion: own, osVersion: os)
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
