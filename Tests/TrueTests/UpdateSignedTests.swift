import Testing
import Foundation
import CryptoKit
@testable import True

struct UpdateSignedTests {
    // MARK: signature verify (throwaway keys)

    @Test func signatureVerdicts() {
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let zip = Data("pretend zip bytes".utf8)
        let sig = try! key.signature(for: zip).base64EncodedString()
        let pub = key.publicKey
        #expect(UpdateLogic.verifySignature(zip: zip, sigText: sig + "\n", publicKey: pub) == .valid)
        var bad = zip; bad[0] ^= 1
        #expect(UpdateLogic.verifySignature(zip: bad, sigText: sig, publicKey: pub) == .invalid)
        #expect(UpdateLogic.verifySignature(zip: zip, sigText: sig, publicKey: other.publicKey) == .invalid)
        #expect(UpdateLogic.verifySignature(zip: zip, sigText: nil, publicKey: pub) == .missing)
        #expect(UpdateLogic.verifySignature(zip: zip, sigText: " \n", publicKey: pub) == .missing)
        #expect(UpdateLogic.verifySignature(zip: zip, sigText: "not base64 !!", publicKey: pub) == .malformed)
        #expect(UpdateLogic.verifySignature(zip: zip, sigText: Data(repeating: 1, count: 10).base64EncodedString(), publicKey: pub) == .malformed)
    }

    @Test func policyFromPlist() {
        let key = Curve25519.Signing.PrivateKey().publicKey
        func kind(_ i: [String: Any]?) -> String {
            switch UpdateLogic.sigPolicy(from: i) { case .none: "none"; case .key: "key"; case .badKey: "bad" }
        }
        #expect(kind(nil) == "none")
        #expect(kind([:]) == "none")
        #expect(kind([UpdateLogic.pubKeyKey: ""]) == "none")
        #expect(kind([UpdateLogic.pubKeyKey: key.rawRepresentation.base64EncodedString()]) == "key")
        #expect(kind([UpdateLogic.pubKeyKey: "AAAA"]) == "bad")
        #expect(kind([UpdateLogic.pubKeyKey: "%%%"]) == "bad")
    }

    @Test func feedCarriesOptionalSig() {
        func tag(_ assets: [String]) -> UpdateLogic.Feed {
            let a = assets.map { ["name": $0, "browser_download_url": "https://github.com/o/r/releases/download/v1/\($0)"] }
            let o: [String: Any] = ["tag_name": "v1.2.0", "html_url": "https://github.com/o/r/releases/tag/v1.2.0", "assets": a]
            return UpdateLogic.parseFeed(try! JSONSerialization.data(withJSONObject: o))
        }
        if case .release(let r) = tag([UpdateLogic.zipName, UpdateLogic.sumName, UpdateLogic.sigName]) { #expect(r.sigURL != nil) } else { Issue.record("no release") }
        if case .release(let r) = tag([UpdateLogic.zipName, UpdateLogic.sumName]) { #expect(r.sigURL == nil) } else { Issue.record("v1.1.2-style release must still parse") }
    }

    // MARK: check scheduling

    @Test func launchDelayRespectsLastCheck() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UpdateLogic.launchDelay(lastCheck: nil, now: now) == 30)
        #expect(UpdateLogic.launchDelay(lastCheck: now.addingTimeInterval(-7200), now: now) == 30)
        // checked 10 min ago: wait out the rest of the hour, plus the usual 30 s
        #expect(UpdateLogic.launchDelay(lastCheck: now.addingTimeInterval(-600), now: now) == 3000 + 30)
        // clock went backwards: don't stall forever
        #expect(UpdateLogic.launchDelay(lastCheck: now.addingTimeInterval(600), now: now) == 30)
    }

    @Test func loopDelayIsSixHourlyWithJitter() {
        #expect(UpdateLogic.loopDelay(jitter: 0) == 6 * 3600)
        #expect(UpdateLogic.loopDelay(jitter: 1) == 6 * 3600 * 1.1)
        #expect(UpdateLogic.loopDelay(jitter: -1) == 6 * 3600 * 0.9)
        #expect(UpdateLogic.loopDelay(jitter: 50) == 6 * 3600 * 1.1)
    }

    @Test func etagOnlyForSameVersion() {
        #expect(UpdateLogic.conditionalETag(stored: "W/\"a\"", storedFor: "1.1.3", ownVersion: "1.1.3") == "W/\"a\"")
        #expect(UpdateLogic.conditionalETag(stored: "W/\"a\"", storedFor: "1.1.2", ownVersion: "1.1.3") == nil)
        #expect(UpdateLogic.conditionalETag(stored: nil, storedFor: "1.1.3", ownVersion: "1.1.3") == nil)
        #expect(UpdateLogic.conditionalETag(stored: "", storedFor: "1.1.3", ownVersion: "1.1.3") == nil)
    }

    // MARK: first-run prompt

    @Test func promptOnceFromSecondLaunch() {
        #expect(!UpdateLogic.promptDue(launchCount: 0, answered: false))
        #expect(!UpdateLogic.promptDue(launchCount: 1, answered: false))
        #expect(UpdateLogic.promptDue(launchCount: 2, answered: false))
        #expect(UpdateLogic.promptDue(launchCount: 5, answered: false))   // missed launch 2: still asked, once
        #expect(!UpdateLogic.promptDue(launchCount: 2, answered: true))
    }

    // MARK: local end to end: fake v9.9.9, signed vs tampered

    /// A real ad-hoc signed `True.app` at `version`, zipped; returns (zip, workDir).
    private func fakeRelease(version: String, in root: URL) throws -> URL {
        let fm = FileManager.default
        let app = root.appendingPathComponent("build/True.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/True"))
        let plist: [String: Any] = ["CFBundleIdentifier": "io.test.True", "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                    "CFBundleExecutable": "True", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]).status == 0)
        let zip = root.appendingPathComponent(UpdateLogic.zipName)
        #expect(UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]).status == 0)
        return zip
    }

    @Test func tamperedZipRefusedSignedZipInstalls() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("true-e2e-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let zip = try fakeRelease(version: "9.9.9", in: root)
        let sum = root.appendingPathComponent("sum"), sig = root.appendingPathComponent("sig")
        let key = Curve25519.Signing.PrivateKey()
        let policy = UpdateLogic.SigPolicy.key(key.publicKey)

        // The live "installed" app, old version, in its own folder.
        let home = root.appendingPathComponent("Applications"), live = home.appendingPathComponent("True.app")
        try fm.createDirectory(at: live.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: live.appendingPathComponent("Contents/marker"))

        func attempt(zipFile: URL, sigText: String?, policy: UpdateLogic.SigPolicy) throws -> (app: URL, dir: URL, version: String) {
            if let sigText { try sigText.write(to: sig, atomically: true, encoding: .utf8) } else { try? fm.removeItem(at: sig) }
            try (UpdateLogic.sha256Hex(fileAt: zipFile) ?? "").write(to: sum, atomically: true, encoding: .utf8)
            return try UpdateInstaller.stage(zip: zipFile, sumFile: sum, sigFile: sigText == nil ? nil : sig, policy: policy, work: root, bundle: live,
                                             ownBundleID: "io.test.True", ownVersion: "1.1.2", osVersion: "15.0.0")
        }
        let good = try key.signature(for: Data(contentsOf: zip)).base64EncodedString()

        // Tampered: a byte flipped AFTER signing, checksum recomputed so only the signature can catch it.
        let evil = root.appendingPathComponent("evil.zip")
        var bytes = try Data(contentsOf: zip); bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: evil)
        #expect(throws: UpdateFailure.self) { _ = try attempt(zipFile: evil, sigText: good, policy: policy) }
        #expect(!fm.fileExists(atPath: UpdateInstaller.stagedDir(for: live).path), "nothing unpacked from a refused zip")
        // Missing sig, wrong key, bad base64, unusable key: all refused.
        #expect(throws: UpdateFailure.self) { _ = try attempt(zipFile: zip, sigText: nil, policy: policy) }
        #expect(throws: UpdateFailure.self) { _ = try attempt(zipFile: zip, sigText: good, policy: .key(Curve25519.Signing.PrivateKey().publicKey)) }
        #expect(throws: UpdateFailure.self) { _ = try attempt(zipFile: zip, sigText: "###", policy: policy) }
        #expect(throws: UpdateFailure.self) { _ = try attempt(zipFile: zip, sigText: good, policy: .badKey) }
        #expect(!fm.fileExists(atPath: UpdateInstaller.stagedDir(for: live).path))
        #expect(try String(contentsOf: live.appendingPathComponent("Contents/marker"), encoding: .utf8) == "old")

        // Signed and intact: staged, then swapped in at "quit".
        let staged = try attempt(zipFile: zip, sigText: good, policy: policy)
        #expect(staged.version == "9.9.9")
        #expect(fm.fileExists(atPath: UpdateInstaller.stagedDir(for: live).appendingPathComponent("True.app").path))
        try UpdateInstaller.swap(live: live, with: staged.app, backupDir: staged.dir, keepBackup: true)
        let info = NSDictionary(contentsOf: live.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        #expect(info?["CFBundleShortVersionString"] as? String == "9.9.9")
        #expect(fm.fileExists(atPath: staged.dir.appendingPathComponent("previous-True.app").path), "old app kept until next launch sweeps it")

        // A build with no key (dev) still accepts an unsigned zip: the old behaviour, checksum only.
        #expect(try attempt(zipFile: zip, sigText: nil, policy: .none).version == "9.9.9")
    }
}
