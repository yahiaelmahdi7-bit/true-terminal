import Foundation
import CryptoKit

/// The checks the app and the lifeline both use: version compare, sha256, ed25519 signature, staged-app vetting, swap.
/// Pure or file-only; no network, no UI. Moved out of `UpdateLogic` / `UpdateInstaller` so `TrueLifeline` can import them.
public enum UpdateCore {
    /// Numeric parts of `1.2.3` / `v1.2.3` / `1.2.3-dev`. A suffix after `-` or `+` is dropped; nil if no number leads.
    public static func parts(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let cut = t.firstIndex(where: { $0 == "-" || $0 == "+" }) { t = String(t[..<cut]) }
        let nums = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return nums.map { $0! }
    }

    /// Numeric semver compare, missing parts count as 0 (`1.2` == `1.2.0`). -1 / 0 / 1; nil if either does not parse.
    public static func compare(_ a: String, _ b: String) -> Int? {
        guard let x = parts(a), let y = parts(b) else { return nil }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    public static func isNewer(_ remote: String, than local: String) -> Bool { compare(remote, local) == 1 }

    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Streams the file, so a big zip is never held in memory.
    public static func sha256Hex(fileAt url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The hash from a `shasum` line (`<64 hex>  True-macOS.zip`) or a bare hash. Lower-cased; nil if it is not 64 hex.
    public static func expectedHash(fromSumFile text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).first else { return nil }
        let h = first.lowercased()
        return h.count == 64 && h.allSatisfy(\.isHexDigit) ? h : nil
    }

    public static func verify(actual: String?, sumFile: String) -> Bool {
        guard let actual, let want = expectedHash(fromSumFile: sumFile) else { return false }
        return actual.lowercased() == want
    }


    public enum SigPolicy: Sendable {
        /// No `TrueUpdatePublicKey` in the plist: local/dev build, signatures are not enforced.
        case none
        case key(Curve25519.Signing.PublicKey)
        /// A key is present but unusable: fail closed, apply nothing.
        case badKey
    }

    public static func sigPolicy(from info: [String: Any]?) -> SigPolicy {
        guard let raw = info?[pubKeyKey] as? String else { return .none }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .none }
        guard let d = Data(base64Encoded: t), d.count == 32, let k = try? Curve25519.Signing.PublicKey(rawRepresentation: d) else { return .badKey }
        return .key(k)
    }

    public enum SigCheck: Equatable, Sendable { case valid, missing, malformed, invalid }

    /// `sigText` is the .sig asset: one base64 line, 64 raw bytes. The signature covers the exact bytes of the zip.
    public static func verifySignature(zip: Data, sigText: String?, publicKey: Curve25519.Signing.PublicKey) -> SigCheck {
        guard let sigText, !sigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missing }
        guard let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)), sig.count == 64 else { return .malformed }
        return publicKey.isValidSignature(sig, for: zip) ? .valid : .invalid
    }


    /// nil = this staged app may replace the running one; otherwise the one-line reason to abandon.
    public static func stagedProblem(info: [String: Any]?, ownBundleID: String, ownVersion: String, osVersion: String) -> String? {
        guard let info else { return "staged app has no Info.plist" }
        guard (info["CFBundleIdentifier"] as? String) == ownBundleID else { return "staged bundle id differs" }
        if let min = info["LSMinimumSystemVersion"] as? String {
            guard let c = compare(min, osVersion), c <= 0 else { return "staged app needs macOS \(min)" }
        }
        guard let v = info["CFBundleShortVersionString"] as? String, isNewer(v, than: ownVersion) else { return "staged version is not newer" }
        return nil
    }

    public static let pubKeyKey = "TrueUpdatePublicKey"
}

public struct UpdateFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Blocking file work for one install; runs off the main actor. Every failure throws before the live bundle is touched,
/// except the swap itself, which restores the backup if the second rename fails.
public enum UpdateInstaller {
    public static let stagedAppName = "True.app"

    /// Where a verified update waits for the next quit: next to the live bundle so the swap is a same-volume rename.
    public static func stagedDir(for bundle: URL) -> URL { bundle.deletingLastPathComponent().appendingPathComponent(".True-staged", isDirectory: true) }

    /// Signature (when the build has a key) and checksum first, THEN unzip, vet the app, leave it in `dir` as `True.app`.
    /// Nothing is unpacked from a zip that fails either check.
    public static func stage(zip: URL, sumFile: URL, sigFile: URL?, policy: UpdateCore.SigPolicy, work: URL, bundle: URL,
                      ownBundleID: String, ownVersion: String, osVersion: String) throws -> (app: URL, dir: URL, version: String) {
        let fm = FileManager.default
        switch policy {
        case .badKey: throw UpdateFailure("embedded update key is unusable")
        case .none: break
        case .key(let key):
            guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe) else { throw UpdateFailure("cannot read the download") }
            let sigText = sigFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let r = UpdateCore.verifySignature(zip: data, sigText: sigText, publicKey: key)
            guard r == .valid else { throw UpdateFailure("signature check failed (\(r))") }
        }
        let sumText = (try? String(contentsOf: sumFile, encoding: .utf8)) ?? ""
        guard UpdateCore.verify(actual: UpdateCore.sha256Hex(fileAt: zip), sumFile: sumText) else { throw UpdateFailure("checksum mismatch") }

        let dir = stagedDir(for: bundle)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var ok = false
        defer { if !ok { try? fm.removeItem(at: dir) } }
        let unpack = dir.appendingPathComponent("unpacked", isDirectory: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path]).status == 0 else { throw UpdateFailure("unzip failed") }
        let apps = ((try? fm.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let unpacked = apps.first else { throw UpdateFailure("zip does not hold exactly one app") }

        let plist = NSDictionary(contentsOf: unpacked.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        if let why = UpdateCore.stagedProblem(info: plist, ownBundleID: ownBundleID, ownVersion: ownVersion, osVersion: osVersion) { throw UpdateFailure(why) }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", unpacked.path]).status == 0 else { throw UpdateFailure("staged app fails codesign") }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", unpacked.path])
        let app = dir.appendingPathComponent(stagedAppName)
        try fm.moveItem(at: unpacked, to: app)
        try? fm.removeItem(at: unpack)
        ok = true
        return (app, dir, plist?["CFBundleShortVersionString"] as? String ?? "")
    }

    /// Move `live` into `backupDir`, move `staged` to `live`'s path, drop the backup. If the second move fails the
    /// backup goes back. `staged` and `backupDir` must be on the same volume as `live`.
    public static func swap(live: URL, with staged: URL, backupDir: URL, keepBackup: Bool = false) throws {
        let fm = FileManager.default
        let backup = backupDir.appendingPathComponent("previous-\(live.lastPathComponent)")
        try fm.moveItem(at: live, to: backup)
        do {
            try fm.moveItem(at: staged, to: live)
        } catch {
            try? fm.removeItem(at: live)
            try fm.moveItem(at: backup, to: live)
            throw UpdateFailure("could not move the new app into place; kept the old one")
        }
        if !keepBackup { try? fm.removeItem(at: backup) }
    }

    /// Like `swap`, but the old copy ends up at `<folder holding live>/.True-previous/True.app` and stays there until the NEXT
    /// install replaces it. The older previous copy is set aside first and dropped only after the new swap succeeded, so a failed
    /// swap loses nothing. A missing `live` (reinstall) just moves `staged` into place.
    public static func swapKeepingPrevious(live: URL, with staged: URL) throws {
        let fm = FileManager.default
        let previous = SafetyNet.previousApp(for: live)
        let prevDir = previous.deletingLastPathComponent()
        let aside = prevDir.deletingLastPathComponent().appendingPathComponent(".True-previous-old-\(UUID().uuidString)")
        let hadOld = fm.fileExists(atPath: previous.path)
        if hadOld { try fm.moveItem(at: previous, to: aside) }
        func restoreOld() { if hadOld { try? fm.removeItem(at: previous); try? fm.moveItem(at: aside, to: previous) } }
        guard fm.fileExists(atPath: live.path) else {
            do { try fm.moveItem(at: staged, to: live) } catch { restoreOld(); throw UpdateFailure("could not move the new app into place") }
            if hadOld { try? fm.removeItem(at: aside) }
            return
        }
        do {
            try fm.createDirectory(at: prevDir, withIntermediateDirectories: true)
            try fm.moveItem(at: live, to: previous)
        } catch { restoreOld(); throw error }
        do {
            try fm.moveItem(at: staged, to: live)
        } catch {
            try? fm.removeItem(at: live)
            try? fm.moveItem(at: previous, to: live)
            restoreOld()
            throw UpdateFailure("could not move the new app into place; kept the old one")
        }
        if hadOld { try? fm.removeItem(at: aside) }
    }

    @discardableResult
    public static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (127, "") }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()   // drain before wait so a chatty child never blocks
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }
}
