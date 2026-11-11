import Foundation
import CryptoKit
import TrueUpdateCore

/// Built-in auto-update, the pure half: version compare, release-feed parsing, checksum, the checks a staged app must
/// pass, and the install-vs-notify decision. No network, no disk writes, no clocks here; `Updater` does the side effects.
/// The updater exists only in a build whose Info.plist carries `TrueUpdateRepo` (the public build); without it, nothing runs.
enum UpdateLogic {
    static let repoKey = "TrueUpdateRepo"
    /// Team builds: base URL of a private feed (Steward). When set it wins over `TrueUpdateRepo`; the app still needs the signing key.
    static let feedKey = "TrueUpdateFeed"
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

    /// `a.b.c.d` with four decimal parts and a first part of 100 and a second of 64...127: tailnet (100.64.0.0/10). No names, no IPv6.
    static func isTailnetHost(_ host: String) -> Bool {
        let p = host.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return false }
        let n = p.map { s in s.count <= 3 && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) ? Int(s) : nil }
        guard n.allSatisfy({ $0 != nil && $0! <= 255 }) else { return false }
        return n[0] == 100 && (64...127).contains(n[1]!)
    }

    /// The team feed base from Info.plist, or nil. https from any host; plain http only for a tailnet IP (the zip is
    /// signature-verified anyway). No credentials, query or fragment in it.
    static func feedBase(from info: [String: Any]?) -> URL? {
        guard let raw = (info?[feedKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let u = URL(string: raw), let host = u.host, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else { return nil }
        switch u.scheme {
        case "https": return u
        case "http": return isTailnetHost(host) ? u : nil
        default: return nil
        }
    }

    /// `<feed>/releases/latest`.
    static func feedURL(base: URL) -> URL? {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/releases/latest")
    }

    /// A team-feed asset must come from the feed's own scheme, host and port, under the feed's path.
    static func sameOrigin(_ u: URL, as base: URL) -> Bool {
        u.scheme == base.scheme && u.host?.lowercased() == base.host?.lowercased() && u.port == base.port
            && u.path.hasPrefix(base.path.hasSuffix("/") ? base.path : base.path + "/")
    }

    // MARK: versions

    static func parts(_ s: String) -> [Int]? { UpdateCore.parts(s) }
    static func compare(_ a: String, _ b: String) -> Int? { UpdateCore.compare(a, b) }
    static func isNewer(_ remote: String, than local: String) -> Bool { UpdateCore.isNewer(remote, than: local) }

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

    /// `origin` set = a team feed: assets must live under that base URL (any scheme the base itself was allowed). Nil = GitHub.
    static func parseFeed(_ data: Data, origin: URL? = nil) -> Feed {
        let trusted: (URL) -> Bool = { u in origin.map { sameOrigin(u, as: $0) } ?? trustedAsset(u) }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .invalid("feed is not JSON") }
        if (o["draft"] as? Bool) == true || (o["prerelease"] as? Bool) == true { return .skip }
        guard let tag = o["tag_name"] as? String, let p = parts(tag) else { return .invalid("no usable tag_name") }
        let assets = (o["assets"] as? [[String: Any]]) ?? []
        func url(_ name: String) -> URL? {
            assets.first { ($0["name"] as? String) == name }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        }
        guard let zip = url(zipName), let sum = url(sumName), trusted(zip), trusted(sum) else {
            return .invalid("release \(tag) has no \(zipName) + \(sumName)")
        }
        let sig = url(sigName).flatMap { trusted($0) ? $0 : nil }
        guard let page = (o["html_url"] as? String).flatMap(URL.init(string:)), origin == nil ? page.scheme == "https" : sameOrigin(page, as: origin!) else { return .invalid("no release page") }
        return .release(Release(tag: tag, version: p.map(String.init).joined(separator: "."), pageURL: page, zipURL: zip, sumURL: sum, sigURL: sig))
    }

    // MARK: checksum

    static func sha256Hex(_ data: Data) -> String { UpdateCore.sha256Hex(data) }
    static func sha256Hex(fileAt url: URL) -> String? { UpdateCore.sha256Hex(fileAt: url) }
    static func expectedHash(fromSumFile text: String) -> String? { UpdateCore.expectedHash(fromSumFile: text) }
    static func verify(actual: String?, sumFile: String) -> Bool { UpdateCore.verify(actual: actual, sumFile: sumFile) }

    // MARK: Ed25519 signature (key lives in the maintainer's Keychain; only the public half ships in Info.plist)

    typealias SigPolicy = UpdateCore.SigPolicy
    typealias SigCheck = UpdateCore.SigCheck
    static func sigPolicy(from info: [String: Any]?) -> SigPolicy { UpdateCore.sigPolicy(from: info) }
    static func verifySignature(zip: Data, sigText: String?, publicKey: Curve25519.Signing.PublicKey) -> SigCheck {
        UpdateCore.verifySignature(zip: zip, sigText: sigText, publicKey: publicKey)
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

    static func stagedProblem(info: [String: Any]?, ownBundleID: String, ownVersion: String, osVersion: String) -> String? {
        UpdateCore.stagedProblem(info: info, ownBundleID: ownBundleID, ownVersion: ownVersion, osVersion: osVersion)
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
                                idleSeconds: Double, now: Date, lastDeferral: Date?) -> RestartDecision {
        guard staged, autoRestart else { return .no }
        if let d = lastDeferral, now.timeIntervalSince(d) < restartDeferralWindow { return .wait("cancelled recently") }
        if working > 0 { return .wait("Claude sessions working") }
        if peerJobs > 0 { return .wait("peer job active") }
        if builders > 0 { return .wait("builder running") }
        if modal { return .wait("dialog open") }
        if idleSeconds < restartIdleFloor { return .wait("recent input") }
        return .restartAfterCountdown
    }

    /// What the world looks like to `restartDecision`; read fresh each time by `Updater`.
    struct RestartInputs: Equatable {
        var working = 0, peerJobs = 0, builders = 0
        var modal = false
        var idleSeconds = 0.0
    }
}
