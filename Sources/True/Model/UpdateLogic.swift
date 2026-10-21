import Foundation
import CryptoKit

/// Built-in auto-update, the pure half: version compare, release-feed parsing, checksum, the checks a staged app must
/// pass, and the install-vs-notify decision. No network, no disk writes, no clocks here; `Updater` does the side effects.
/// The updater exists only in a build whose Info.plist carries `TrueUpdateRepo` (the public build); without it, nothing runs.
enum UpdateLogic {
    static let repoKey = "TrueUpdateRepo"
    static let autoKey = "update.auto"
    static let zipName = "True-macOS.zip"
    static let sumName = "True-macOS.zip.sha256"
    static let sigName = "True-macOS.zip.sig"
    static let pubKeyKey = "TrueUpdatePublicKey"
    /// Install a staged update while quitting (default on). Off = swap right after download, pill only.
    static let installKey = "update.install.auto"
    static let lastCheckKey = "update.lastCheck"
    static let etagKey = "update.etag"
    static let etagVersionKey = "update.etagVersion"
    static let launchCountKey = "update.launchCount"
    static let askedKey = "update.askedAuto"
    /// Restart True by itself to adopt a staged update once it is safe (default follows `installKey`).
    static let autoRestartKey = "update.autoRestart"
    /// Countdown cancellations in a row; reset by a successful restart.
    static let restartDeferralsKey = "update.restartDeferrals"
    static let restartLastDeferralKey = "update.restartLastDeferral"
    static let restartCountdown: TimeInterval = 60
    static let restartIdleFloor: TimeInterval = 120
    static let restartDeferralWindow: TimeInterval = 4 * 3600
    static let restartMaxDeferrals = 3
    /// Relaunches never hit GitHub again within this long of the last check.
    static let minGap: TimeInterval = 3600
    static let firstCheckDelay: TimeInterval = 30
    static let interval: TimeInterval = 6 * 3600
    /// A release zip is tens of MB; anything past this is not ours.
    static let maxZipBytes: Int64 = 600 * 1024 * 1024

    // MARK: inert unless the plist says so

    /// `owner/name` from Info.plist, or nil (updater fully inert, no network). Only a plain GitHub slug is accepted.
    static func repo(from info: [String: Any]?) -> String? {
        guard let raw = (info?[repoKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        let ok: (Substring) -> Bool = { p in
            !p.isEmpty && p != "." && p != ".." && p.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
        }
        guard parts.count == 2, parts.allSatisfy(ok) else { return nil }
        return raw
    }

    static func feedURL(repo: String) -> URL? { URL(string: "https://api.github.com/repos/\(repo)/releases/latest") }

    // MARK: versions

    /// Numeric parts of `1.2.3` / `v1.2.3` / `1.2.3-dev`. A suffix after `-` or `+` is dropped; nil if no number leads.
    static func parts(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let cut = t.firstIndex(where: { $0 == "-" || $0 == "+" }) { t = String(t[..<cut]) }
        let nums = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return nums.map { $0! }
    }

    /// Numeric semver compare, missing parts count as 0 (`1.2` == `1.2.0`). -1 / 0 / 1; nil if either does not parse.
    static func compare(_ a: String, _ b: String) -> Int? {
        guard let x = parts(a), let y = parts(b) else { return nil }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    static func isNewer(_ remote: String, than local: String) -> Bool { compare(remote, local) == 1 }

    // MARK: the release feed

    struct Release: Equatable {
        var tag: String
        var version: String
        var pageURL: URL
        var zipURL: URL
        var sumURL: URL
        /// Absent on releases cut before signing (v1.1.2 and older); a build that holds a public key refuses those.
        var sigURL: URL? = nil
    }

    enum Feed: Equatable {
        case release(Release)
        /// A draft or prerelease: ignored, not an error.
        case skip
        case invalid(String)
    }

    /// Hosts a release asset may be served from (GitHub's own).
    static func trustedAsset(_ u: URL) -> Bool {
        guard u.scheme == "https", let h = u.host?.lowercased() else { return false }
        return h == "github.com" || h.hasSuffix(".github.com") || h == "githubusercontent.com" || h.hasSuffix(".githubusercontent.com")
    }

    static func parseFeed(_ data: Data) -> Feed {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .invalid("feed is not JSON") }
        if (o["draft"] as? Bool) == true || (o["prerelease"] as? Bool) == true { return .skip }
        guard let tag = o["tag_name"] as? String, let p = parts(tag) else { return .invalid("no usable tag_name") }
        let assets = (o["assets"] as? [[String: Any]]) ?? []
        func url(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }
        guard let zip = url(zipName), let sum = url(sumName), trustedAsset(zip), trustedAsset(sum) else {
            return .invalid("release \(tag) has no \(zipName) + \(sumName)")
        }
        let sig = url(sigName).flatMap { trustedAsset($0) ? $0 : nil }
        guard let page = (o["html_url"] as? String).flatMap(URL.init(string:)), page.scheme == "https" else { return .invalid("no release page") }
        return .release(Release(tag: tag, version: p.map(String.init).joined(separator: "."), pageURL: page, zipURL: zip, sumURL: sum, sigURL: sig))
    }

    // MARK: checksum

    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Streams the file, so a big zip is never held in memory.
    static func sha256Hex(fileAt url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The hash from a `shasum` line (`<64 hex>  True-macOS.zip`) or a bare hash. Lower-cased; nil if it is not 64 hex.
    static func expectedHash(fromSumFile text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).first else { return nil }
        let h = first.lowercased()
        return h.count == 64 && h.allSatisfy(\.isHexDigit) ? h : nil
    }

    static func verify(actual: String?, sumFile: String) -> Bool {
        guard let actual, let want = expectedHash(fromSumFile: sumFile) else { return false }
        return actual.lowercased() == want
    }

    // MARK: Ed25519 signature (key lives in the maintainer's Keychain; only the public half ships in Info.plist)

    enum SigPolicy {
        /// No `TrueUpdatePublicKey` in the plist: local/dev build, signatures are not enforced.
        case none
        case key(Curve25519.Signing.PublicKey)
        /// A key is present but unusable: fail closed, apply nothing.
        case badKey
    }

    static func sigPolicy(from info: [String: Any]?) -> SigPolicy {
        guard let raw = info?[pubKeyKey] as? String else { return .none }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .none }
        guard let d = Data(base64Encoded: t), d.count == 32, let k = try? Curve25519.Signing.PublicKey(rawRepresentation: d) else { return .badKey }
        return .key(k)
    }

    enum SigCheck: Equatable { case valid, missing, malformed, invalid }

    /// `sigText` is the .sig asset: one base64 line, 64 raw bytes. The signature covers the exact bytes of the zip.
    static func verifySignature(zip: Data, sigText: String?, publicKey: Curve25519.Signing.PublicKey) -> SigCheck {
        guard let sigText, !sigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missing }
        guard let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)), sig.count == 64 else { return .malformed }
        return publicKey.isValidSignature(sig, for: zip) ? .valid : .invalid
    }

    // MARK: check rhythm

    /// Seconds until the first check after launch: 30 s, pushed out so a relaunch never lands within `minGap` of the last check.
    static func launchDelay(lastCheck: Date?, now: Date) -> TimeInterval {
        guard let last = lastCheck else { return firstCheckDelay }
        let since = now.timeIntervalSince(last)
        guard since >= 0, since < minGap else { return firstCheckDelay }
        return (minGap - since) + firstCheckDelay
    }

    /// 6 h plus or minus up to 10 %; `jitter` in -1...1.
    static func loopDelay(jitter: Double) -> TimeInterval { interval * (1 + 0.1 * min(1, max(-1, jitter))) }

    /// Send If-None-Match only for an ETag recorded under this same running version (an update invalidates it).
    static func conditionalETag(stored: String?, storedFor: String?, ownVersion: String) -> String? {
        guard let stored, !stored.isEmpty, storedFor == ownVersion else { return nil }
        return stored
    }

    // MARK: first-run question

    /// Ask "Keep True up to date automatically?" once, from the second launch of a fresh install.
    static func promptDue(launchCount: Int, answered: Bool) -> Bool { launchCount >= 2 && !answered }

    // MARK: the staged app

    /// nil = this staged app may replace the running one; otherwise the one-line reason to abandon.
    static func stagedProblem(info: [String: Any]?, ownBundleID: String, ownVersion: String, osVersion: String) -> String? {
        guard let info else { return "staged app has no Info.plist" }
        guard (info["CFBundleIdentifier"] as? String) == ownBundleID else { return "staged bundle id differs" }
        if let min = info["LSMinimumSystemVersion"] as? String {
            guard let c = compare(min, osVersion), c <= 0 else { return "staged app needs macOS \(min)" }
        }
        guard let v = info["CFBundleShortVersionString"] as? String, isNewer(v, than: ownVersion) else { return "staged version is not newer" }
        return nil
    }

    // MARK: install or notify

    enum Plan: Equatable { case install, notify }

    /// Install only when we can really swap the bundle: not App-Translocated, and both the bundle and the folder it sits
    /// in are writable (a rename needs the folder). Anything else: tell the user and link the release page.
    static func plan(bundlePath: String, bundleWritable: Bool, parentWritable: Bool) -> Plan {
        isTranslocated(bundlePath) || !bundleWritable || !parentWritable ? .notify : .install
    }

    static func isTranslocated(_ path: String) -> Bool { path.contains("/AppTranslocation/") }

    // MARK: restart to update by itself

    enum RestartDecision: Equatable {
        case restartAfterCountdown
        case wait(String)
        case no
    }

    /// Is a self-restart on the table at all: the switch is on and the person has not cancelled the countdown three times running.
    static func autoRestartAllowed(setting: Bool, deferrals: Int) -> Bool { setting && deferrals < restartMaxDeferrals }

    /// May True restart itself now? `.wait` carries the first blocker, for the log; the engine re-asks on the next event.
    static func restartDecision(staged: Bool, autoRestart: Bool, working: Int, peerJobs: Int, builders: Int, modal: Bool,
                                novaBusy: Bool, idleSeconds: Double, now: Date, lastDeferral: Date?) -> RestartDecision {
        guard staged, autoRestart else { return .no }
        if let d = lastDeferral, now.timeIntervalSince(d) < restartDeferralWindow { return .wait("cancelled recently") }
        if working > 0 { return .wait("Claude sessions working") }
        if peerJobs > 0 { return .wait("peer job active") }
        if builders > 0 { return .wait("builder running") }
        if novaBusy { return .wait("Nova turn in flight") }
        if modal { return .wait("dialog open") }
        if idleSeconds < restartIdleFloor { return .wait("recent input") }
        return .restartAfterCountdown
    }

    /// What the world looks like to `restartDecision`; read fresh each time by `Updater`.
    struct RestartInputs: Equatable {
        var working = 0, peerJobs = 0, builders = 0
        var modal = false, novaBusy = false
        var idleSeconds = 0.0
    }
}
