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
    static let firstCheckDelay: TimeInterval = 30
    static let interval: TimeInterval = 24 * 3600
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
        guard let page = (o["html_url"] as? String).flatMap(URL.init(string:)), page.scheme == "https" else { return .invalid("no release page") }
        return .release(Release(tag: tag, version: p.map(String.init).joined(separator: "."), pageURL: page, zipURL: zip, sumURL: sum))
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
}
