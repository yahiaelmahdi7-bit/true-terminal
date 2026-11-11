import Testing
import Foundation
import CryptoKit
@testable import TrueUpdateCore

final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 2_000_000_000) }
final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

/// A temp world: fake home (SafetyPaths.under), a fake installed True, a local "feed" served by the fetch seam. No network, no launchctl, no osascript.
struct Rig {
    let root: URL, paths: SafetyPaths, bundle: URL
    let key = Curve25519.Signing.PrivateKey()
    let clock = Clock()
    let feed = Box<[String: Data]>([:])
    let ps = Box("  1 /sbin/launchd\n")
    let notes = Box<[String]>([])
    /// Successive process-list answers; once empty, `ps` is used.
    let psSeq = Box<[String]>([])
    let zipFetches = Box(0)
    static let host = "https://feed.test"

    init(installed: String? = "1.0.0") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lifeline-\(UUID().uuidString)", isDirectory: true)
        paths = .under(root)
        bundle = root.appendingPathComponent("apps/True.app")
        try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.lifelineDir, withIntermediateDirectories: true)
        try SafetyNet.writeJSON(LifelineConfig(feedURL: Rig.host + "/team", publicKey: key.publicKey.rawRepresentation.base64EncodedString()), to: paths.lifelineConfigFile)
        try Data((bundle.path + "\n").utf8).write(to: paths.installPathFile)
        if let v = installed { try Rig.makeApp(at: bundle, version: v) }
    }

    static func makeApp(at app: URL, version: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/True"))
        let plist: [String: Any] = ["CFBundleIdentifier": "io.github.true-terminal.True", "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                    "CFBundleExecutable": "True", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]).status == 0)
    }

    var binary: URL { bundle.appendingPathComponent("Contents/MacOS/True") }
    func version() -> String? { (NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String }
    /// Breaks the seal without changing the version: the install now fails `codesign --verify --strict`.
    func damage() throws { var d = try Data(contentsOf: binary); d.append(0x42); try d.write(to: binary) }
    func bytes() throws -> Data { try Data(contentsOf: binary) }

    /// Puts a signed release on the local feed. `signWith` / `sumOverride` make the bad cases.
    func publish(_ version: String, tag: String? = nil, signWith: Curve25519.Signing.PrivateKey? = nil, sumOverride: String? = nil) throws {
        let work = root.appendingPathComponent("rel-\(version)")
        let app = work.appendingPathComponent("True.app"), zip = work.appendingPathComponent("True-macOS.zip")
        try Rig.makeApp(at: app, version: version)
        #expect(UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]).status == 0)
        let z = try Data(contentsOf: zip)
        let sig = try (signWith ?? key).signature(for: z).base64EncodedString()
        func asset(_ n: String) -> [String: Any] { ["name": n, "browser_download_url": "\(Rig.host)/dl/\(n)"] }
        let rel: [String: Any] = ["tag_name": "v\(tag ?? version)", "assets": [asset("True-macOS.zip"), asset("True-macOS.zip.sha256"), asset("True-macOS.zip.sig")]]
        feed.v[Rig.host + "/team/releases/latest"] = try JSONSerialization.data(withJSONObject: rel)
        feed.v[Rig.host + "/dl/True-macOS.zip"] = z
        feed.v[Rig.host + "/dl/True-macOS.zip.sha256"] = Data(((sumOverride ?? UpdateCore.sha256Hex(z)) + "  True-macOS.zip\n").utf8)
        feed.v[Rig.host + "/dl/True-macOS.zip.sig"] = Data(sig.utf8)
    }

    func lifeline() -> Lifeline {
        let feed = self.feed, ps = self.ps, notes = self.notes, clock = self.clock, psSeq = self.psSeq, zipFetches = self.zipFetches
        return Lifeline(paths: paths, seams: LifelineSeams(
            processList: { psSeq.v.isEmpty ? ps.v : psSeq.v.removeFirst() },
            fetch: { u in if u.lastPathComponent == "True-macOS.zip" { zipFetches.v += 1 }; guard let d = feed.v[u.absoluteString] else { throw URLError(.cannotConnectToHost) }; return d },
            notify: { notes.v.append($0) }, now: { clock.now }, osVersion: "15.0"))
    }
    @discardableResult func run() -> [String] { let l = lifeline(); l.run(); return l.actions }

    func setState(_ f: (inout LifelineState) -> Void) throws {
        var s = SafetyNet.readJSON(LifelineState.self, at: paths.lifelineStateFile) ?? LifelineState()
        f(&s); try SafetyNet.writeJSON(s, to: paths.lifelineStateFile)
    }
    func has(_ actions: [String], _ s: String) -> Bool { actions.contains { $0.contains(s) } }
}

struct LifelineTests {
    @Test func missingTrueIsReinstalled() throws {
        let r = try Rig(installed: nil)
        try r.publish("1.1.0")
        let a = r.run()
        #expect(r.version() == "1.1.0", "\(a)")
        #expect(r.has(a, "missing"))
    }

    @Test func damagedTrueIsReinstalled() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.1.0")
        let a = r.run()
        #expect(r.version() == "1.1.0", "\(a)")
        #expect(FileManager.default.fileExists(atPath: SafetyNet.previousApp(for: r.bundle).path), "the old copy is kept")
    }

    @Test func runningTrueIsNeverTouched_includingAnotherLogin() throws {
        for line in ["  123 /Users/me/apps/True.app/Contents/MacOS/True", " 9001 /Users/other/Applications/True.app/Contents/MacOS/True"] {
            let r = try Rig(); try r.damage(); try r.publish("1.1.0")
            r.ps.v = "  1 /sbin/launchd\n\(line)\n"
            let before = try r.bytes()
            let a = r.run()
            #expect(try r.bytes() == before, "\(line) \(a)")
            #expect(r.version() == "1.0.0")
            #expect(r.has(a, "True is running"))
        }
    }

    @Test func runningTrueIsNotRolledBackEither() throws {
        let r = try Rig(installed: "1.1.0")
        try Rig.makeApp(at: SafetyNet.previousApp(for: r.bundle), version: "1.0.0")
        try Health(version: "1.1.0", pending: true, uncleanStarts: 3).save(r.paths)
        r.ps.v = "55 \(r.binary.path)\n"
        let a = r.run()
        #expect(r.version() == "1.1.0", "\(a)")
    }

    @Test func noDowngrade() throws {
        let r = try Rig(installed: "2.0.0"); try r.damage(); try r.publish("1.5.0")
        let before = try r.bytes()
        let a = r.run()
        #expect(try r.bytes() == before)
        #expect(r.has(a, "older than installed"))
    }

    @Test func rollbackIsTheOnlyWayDown() throws {
        let r = try Rig(installed: "1.1.0")
        try Rig.makeApp(at: SafetyNet.previousApp(for: r.bundle), version: "1.0.0")
        try Health(version: "1.1.0", pending: true, uncleanStarts: 3).save(r.paths)
        let a = r.run()
        #expect(r.version() == "1.0.0", "\(a)")
        #expect(BadVersions.load(r.paths).contains("1.1.0"))
        let h = Health.load(r.paths)!
        #expect(h.restoreState && h.restoreFrom == "1.1.0" && !h.pending && h.uncleanStarts == 0)
    }

    @Test func noRollbackBelowThreeOrAfterHealthyOrWithoutPrevious() throws {
        func rig(_ h: Health, previous: Bool) throws -> Rig {
            let r = try Rig(installed: "1.1.0")
            if previous { try Rig.makeApp(at: SafetyNet.previousApp(for: r.bundle), version: "1.0.0") }
            try h.save(r.paths); return r
        }
        for (h, prev) in [(Health(version: "1.1.0", pending: true, uncleanStarts: 2), true),
                          (Health(version: "1.1.0", pending: true, uncleanStarts: 5, healthyVersions: ["1.1.0"]), true),
                          (Health(version: "1.1.0", pending: true, uncleanStarts: 3), false)] {
            let r = try rig(h, previous: prev); r.run()
            #expect(r.version() == "1.1.0")
            #expect(!BadVersions.load(r.paths).contains("1.1.0"))
        }
    }

    @Test func atMostOneInstallPerVersionPer24h() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.1.0")
        try r.setState { $0.installedAt["1.1.0"] = r.clock.now.timeIntervalSince1970 - 3600 }
        let before = try r.bytes()
        let a = r.run()
        #expect(try r.bytes() == before)
        #expect(r.has(a, "within 24 h"))
        r.clock.now.addTimeInterval(24 * 3600)   // 25 h after
        try r.setState { $0.lastFeedRead = nil }
        r.run()
        #expect(r.version() == "1.1.0")
    }

    @Test func badSignatureRefused() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.1.0", signWith: Curve25519.Signing.PrivateKey())
        let before = try r.bytes()
        let a = r.run()
        #expect(try r.bytes() == before, "\(a)")
        #expect(r.has(a, "signature"))
        #expect(r.notes.v.count == 1)
    }

    @Test func badSha256Refused() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.1.0", sumOverride: String(repeating: "0", count: 64))
        let before = try r.bytes()
        let a = r.run()
        #expect(try r.bytes() == before, "\(a)")
        #expect(r.has(a, "checksum"))
    }

    @Test func badListedFeedVersionSkipped() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.1.0")
        BadVersions.add("1.1.0", paths: r.paths)
        let before = try r.bytes()
        let a = r.run()
        #expect(try r.bytes() == before)
        #expect(r.has(a, "bad list"))
    }

    @Test func heldLockSkipsTheInstall() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.1.0")
        let lock = SafetyNet.lockURL(for: r.bundle)
        #expect(InstallLock.acquire(lock, now: r.clock.now))
        try FileManager.default.setAttributes([.modificationDate: r.clock.now.addingTimeInterval(-60)], ofItemAtPath: lock.path)   // the fake clock, 1 min old
        let before = try r.bytes()
        let a = r.run()
        #expect(try r.bytes() == before)
        #expect(r.has(a, "lock is held"))
    }

    @Test func staleLockIsBrokenAtTenMinutes() throws {
        for (age, installs) in [(9.0 * 60, false), (10.0 * 60, true), (11.0 * 60, true)] {
            let r = try Rig(); try r.damage(); try r.publish("1.1.0")
            let lock = SafetyNet.lockURL(for: r.bundle)
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.modificationDate: r.clock.now.addingTimeInterval(-age)], ofItemAtPath: lock.path)
            r.run()
            #expect((r.version() == "1.1.0") == installs, "age \(age)")
        }
    }

    @Test func staleInstallWaits48hThenUpdates() throws {
        let r = try Rig(); try r.publish("1.1.0")
        r.run()
        #expect(r.version() == "1.0.0", "True's own updater gets 48 h")
        r.clock.now.addTimeInterval(49 * 3600)
        r.run()
        #expect(r.version() == "1.1.0")
    }

    @Test func silentFeedNotifiesOncePerDayAfterThreeDays() throws {
        let r = try Rig()   // feed has nothing: every fetch fails
        try r.setState { $0.firstRun = r.clock.now.timeIntervalSince1970 - 4 * 24 * 3600 }
        r.run(); r.run()
        #expect(r.notes.v.count == 1)
        r.clock.now.addTimeInterval(25 * 3600); try r.setState { $0.lastFeedRead = nil }
        r.run()
        #expect(r.notes.v.count == 2)
        let fresh = try Rig()
        fresh.run()
        #expect(fresh.notes.v.isEmpty, "silent for under 3 days says nothing")
    }

    @Test func neverTouchesTheStateFolder() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.1.0")
        try FileManager.default.createDirectory(at: r.paths.state, withIntermediateDirectories: true)
        let f = r.paths.state.appendingPathComponent("workspace.json"); try Data("{}".utf8).write(to: f)
        r.run()
        #expect(try FileManager.default.contentsOfDirectory(atPath: r.paths.state.path) == ["workspace.json"])
    }
}

/// Lead-review fixes 1-4.
struct LifelineReviewTests {
    static let runningLine = "  77 /Users/me/apps/True.app/Contents/MacOS/True\n"

    @Test func trueOpenedDuringTheDownloadIsNotSwapped() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.1.0")
        r.psSeq.v = ["  1 /sbin/launchd\n", Self.runningLine]      // first read: not running; read again before the swap: running
        let before = try r.bytes()
        let a = r.run()
        #expect(try r.bytes() == before, "\(a)")
        #expect(r.has(a, "True is running"), "\(a)")
        #expect(!r.notes.v.isEmpty)
        let s = SafetyNet.readJSON(LifelineState.self, at: r.paths.lifelineStateFile)
        #expect(s?.installedAt.isEmpty ?? true)
        #expect(!FileManager.default.fileExists(atPath: SafetyNet.lockURL(for: r.bundle).path), "lock released")
    }

    @Test func zipHoldingAnOlderVersionThanItsTagIsRefused() throws {
        let r = try Rig(installed: "2.0.0"); try r.publish("1.0.0", tag: "3.0.0")
        r.clock.now.addTimeInterval(49 * 3600)
        try r.setState { $0.feedSeen["3.0.0"] = r.clock.now.timeIntervalSince1970 - 49 * 3600 }
        let before = try r.bytes()
        let a = r.run()
        #expect(try r.bytes() == before, "\(a)")
        #expect(r.version() == "2.0.0")
        #expect(r.has(a, "older than installed"), "\(a)")
        #expect(!r.notes.v.isEmpty)
    }

    @Test func zipHoldingABadListedVersionIsRefused() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.2.0", tag: "1.3.0")
        BadVersions.add("1.2.0", paths: r.paths)
        let before = try r.bytes()
        let a = r.run()
        #expect(try r.bytes() == before, "\(a)")
        #expect(r.has(a, "bad list"), "\(a)")
    }

    @Test func quitTrueFinishesWithoutWaitingSixHours() throws {
        let r = try Rig(); try r.publish("1.1.0")
        r.run()                                           // first sight of 1.1.0
        r.clock.now.addTimeInterval(49 * 3600)
        r.ps.v = Self.runningLine
        let a1 = r.run()
        #expect(r.version() == "1.0.0" && r.has(a1, "staged"), "\(a1)")
        r.ps.v = "  1 /sbin/launchd\n"
        r.clock.now.addTimeInterval(20 * 60)               // True quit twenty minutes later
        let a2 = r.run()
        #expect(r.version() == "1.1.0", "\(a2)")
        #expect(SafetyNet.readJSON(LifelineState.self, at: r.paths.lifelineStateFile)?.finishPending != true)
    }

    @Test func oldStateJsonWithoutFinishPendingStillLoads() throws {
        let r = try Rig()
        try Data(#"{"firstRun":1,"feedSeen":{},"installedAt":{}}"#.utf8).write(to: r.paths.lifelineStateFile)
        let s = SafetyNet.readJSON(LifelineState.self, at: r.paths.lifelineStateFile)
        #expect(s != nil && s?.firstRun == 1)
    }

    @Test func aRefusalOnTheTagClearsFinishPending() throws {
        let r = try Rig(); try r.publish("1.1.0")
        BadVersions.add("1.1.0", paths: r.paths)
        r.clock.now.addTimeInterval(49 * 3600)
        try r.setState { $0.feedSeen["1.1.0"] = r.clock.now.timeIntervalSince1970 - 49 * 3600; $0.finishPending = true }
        let a = r.run()
        #expect(r.has(a, "bad list"), "\(a)")
        #expect(SafetyNet.readJSON(LifelineState.self, at: r.paths.lifelineStateFile)?.finishPending != true, "\(a)")
    }

    @Test func aNewerTagHoldingTheInstalledVersionIsNotReinstalled() throws {
        let r = try Rig(installed: "1.2.0"); try r.publish("1.2.0", tag: "1.3.0")
        r.clock.now.addTimeInterval(49 * 3600)
        try r.setState { $0.feedSeen["1.3.0"] = r.clock.now.timeIntervalSince1970 - 49 * 3600 }
        let a = r.run()
        #expect(!r.has(a, "installed 1.2.0 at"), "\(a)")
        #expect(r.has(a, "the version already installed"), "\(a)")
        #expect(!FileManager.default.fileExists(atPath: SafetyNet.previousApp(for: r.bundle).path), "the fallback copy stays as it was: \(a)")
    }

    @Test func aDamagedAppCanStillBeReinstalledAtTheSameVersion() throws {
        let r = try Rig(installed: "1.2.0"); try r.damage(); try r.publish("1.2.0")
        let a = r.run()
        #expect(r.has(a, "installed 1.2.0 at"), "\(a)")
    }

    @Test func damagedAndRunningFetchesTheZipOncePerRhythm() throws {
        let r = try Rig(); try r.damage(); try r.publish("1.1.0")
        r.ps.v = Self.runningLine
        r.run()
        r.clock.now.addTimeInterval(15 * 60)
        let a = r.run()
        #expect(r.zipFetches.v == 1, "\(a)")
        #expect(r.has(a, "skipped"), "\(a)")
        r.ps.v = "  1 /sbin/launchd\n"                    // not running: installs as before
        r.clock.now.addTimeInterval(15 * 60)
        r.run()
        #expect(r.version() == "1.1.0")
    }
}
