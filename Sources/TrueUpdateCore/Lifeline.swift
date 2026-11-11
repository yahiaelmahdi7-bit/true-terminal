import Foundation

/// The lifeline's own copy of the feed URL and update public key, written by True next to the helper.
public struct LifelineConfig: Codable, Equatable, Sendable {
    public var feedURL: String
    public var publicKey: String
    public init(feedURL: String, publicKey: String) { self.feedURL = feedURL; self.publicKey = publicKey }
}

/// What the lifeline remembers between runs (`lifeline/state.json`).
public struct LifelineState: Codable, Equatable, Sendable {
    public var firstRun: Double?
    public var lastFeedRead: Double?          // last attempt, for the 6 h rhythm
    public var lastFeedContact: Double?       // last success, for "3 days with no contact"
    public var lastNotified: Double?
    public var feedSeen: [String: Double] = [:]      // feed version -> when first seen
    public var installedAt: [String: Double] = [:]   // version -> last install, for the 24 h limit
    /// A newer version is staged and waiting only for True to quit: the next run skips the 6 h rhythm.
    public var finishPending: Bool? = nil
    public init() {}
}

/// The outside world, behind seams so tests use a temp root, a fake process list, a local feed and no osascript.
public struct LifelineSeams: Sendable {
    /// Output of `ps -axo pid=,comm=` (sees every login on the Mac).
    public var processList: @Sendable () -> String
    /// Reads a URL (feed JSON or an asset). Throws on any failure.
    public var fetch: @Sendable (URL) throws -> Data
    public var notify: @Sendable (String) -> Void
    public var now: @Sendable () -> Date
    public var osVersion: String
    public init(processList: @escaping @Sendable () -> String, fetch: @escaping @Sendable (URL) throws -> Data,
                notify: @escaping @Sendable (String) -> Void, now: @escaping @Sendable () -> Date = Date.init, osVersion: String) {
        self.processList = processList; self.fetch = fetch; self.notify = notify; self.now = now; self.osVersion = osVersion
    }
}

/// A feed release as the lifeline reads it: the team feed only, assets under the feed's own origin.
public struct LifelineRelease: Equatable, Sendable {
    public var version: String
    public var zip: URL, sum: URL, sig: URL?
}

public enum LifelineFeed {
    /// `<feed>/releases/latest`. https from anywhere; plain http only for a tailnet IP (the zip is signature-verified anyway).
    public static func latestURL(_ raw: String) -> URL? {
        guard let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let host = u.host,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else { return nil }
        switch u.scheme {
        case "https": break
        case "http": guard isTailnet(host) else { return nil }
        default: return nil
        }
        var s = u.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/releases/latest")
    }

    static func isTailnet(_ host: String) -> Bool {
        let p = host.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return false }
        let n = p.map { s in s.count <= 3 && s.allSatisfy(\.isASCII) && s.allSatisfy(\.isNumber) ? Int(s) : nil }
        guard n.allSatisfy({ $0 != nil && $0! <= 255 }) else { return false }
        return n[0] == 100 && (64...127).contains(n[1]!)
    }

    public static func parse(_ data: Data, feed: URL) -> LifelineRelease? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (o["draft"] as? Bool) != true, (o["prerelease"] as? Bool) != true,
              let tag = o["tag_name"] as? String, let parts = UpdateCore.parts(tag) else { return nil }
        let assets = (o["assets"] as? [[String: Any]]) ?? []
        func url(_ name: String) -> URL? {
            guard let u = assets.first(where: { ($0["name"] as? String) == name }).flatMap({ $0["browser_download_url"] as? String }).flatMap(URL.init(string:)),
                  u.scheme == feed.scheme, u.host?.lowercased() == feed.host?.lowercased(), u.port == feed.port else { return nil }
            return u
        }
        guard let zip = url("True-macOS.zip"), let sum = url("True-macOS.zip.sha256") else { return nil }
        return LifelineRelease(version: parts.map(String.init).joined(separator: "."), zip: zip, sum: sum, sig: url("True-macOS.zip.sig"))
    }
}

/// One lifeline run. Hard limits, in code: never touch a running True (any login), never downgrade except the rollback, at most one
/// install per version per 24 h, never touch ~/.true, install only what passes signature, sha256 and codesign.
public final class Lifeline: @unchecked Sendable {
    public static let feedEvery: TimeInterval = 6 * 3600
    public static let staleAfter: TimeInterval = 48 * 3600
    public static let installOnceEvery: TimeInterval = 24 * 3600
    public static let silentAfter: TimeInterval = 3 * 24 * 3600
    public static let notifyEvery: TimeInterval = 24 * 3600

    let paths: SafetyPaths
    let seams: LifelineSeams
    let fm = FileManager.default
    var state: LifelineState
    /// Everything this run did, for tests and the log.
    public private(set) var actions: [String] = []

    public init(paths: SafetyPaths, seams: LifelineSeams) {
        self.paths = paths; self.seams = seams
        state = SafetyNet.readJSON(LifelineState.self, at: paths.lifelineStateFile) ?? LifelineState()
    }

    // MARK: helpers

    func log(_ s: String) {
        actions.append(s)
        let line = "\(ISO8601DateFormatter().string(from: seams.now())) \(s)\n"
        try? fm.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: paths.lifelineLog) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)) }
        else { try? Data(line.utf8).write(to: paths.lifelineLog) }
    }

    func saveState() { try? SafetyNet.writeJSON(state, to: paths.lifelineStateFile) }
    var t: Double { seams.now().timeIntervalSince1970 }

    /// True is running if any process on the Mac, under any login, is a `…/Contents/MacOS/True`.
    public static func trueRunning(psOutput: String) -> Bool {
        psOutput.split(separator: "\n").contains { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let sp = s.firstIndex(of: " ") else { return false }
            return s[sp...].trimmingCharacters(in: .whitespaces).hasSuffix("/Contents/MacOS/True")
        }
    }

    func installedVersion(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    func damaged(_ app: URL) -> Bool { UpdateInstaller.run("/usr/bin/codesign", ["--verify", "--strict", app.path]).status != 0 }

    /// Refusals and the silent-feed rule go to one notification, at most once a day.
    func notifyOnce(_ msg: String) {
        if let last = state.lastNotified, t - last < Lifeline.notifyEvery { log("notify suppressed (once a day): \(msg)"); return }
        state.lastNotified = t
        seams.notify(msg)
        log("notified: \(msg)")
    }

    // MARK: the run

    public func run() {
        state.firstRun = state.firstRun ?? t
        defer { saveState() }
        let installPath = ((try? String(contentsOf: paths.installPathFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = URL(fileURLWithPath: installPath.isEmpty ? SafetyNet.defaultInstallPath : installPath)   // 1
        let running = Lifeline.trueRunning(psOutput: seams.processList())
        let exists = fm.fileExists(atPath: bundle.path)

        if !exists || damaged(bundle) {                                                                      // 2
            log(exists ? "damaged: \(bundle.path) fails codesign" : "missing: \(bundle.path)")
            // A damaged True that stays open must not re-download the zip every run: same rhythm as the feed read.
            if running, let last = state.lastFeedRead, t - last < Lifeline.feedEvery {
                log("True is running; feed read skipped (rhythm)"); return
            }
            installFromFeed(bundle: bundle, reason: .reinstall, running: running)
            return
        }
        if rollbackIfDue(bundle: bundle, running: running) { return }                                        // 3
        staleCheck(bundle: bundle, running: running)                                                         // 4
        contactCheck()
    }

    // 3
    func rollbackIfDue(bundle: URL, running: Bool) -> Bool {
        guard let h = Health.load(paths) else { return false }
        let previous = SafetyNet.previousApp(for: bundle)
        guard h.rollbackDue(previousExists: fm.fileExists(atPath: previous.path)) else { return false }
        if running { log("rollback due for \(h.version) but True is running; not touching it"); return false }
        if damaged(previous) { log("rollback due for \(h.version) but the previous copy fails codesign; skipped"); return false }
        if let pv = installedVersion(previous), let cur = installedVersion(bundle), UpdateCore.compare(pv, cur) != -1 {
            log("rollback skipped: previous copy \(pv) is not older than \(cur)"); return false
        }
        let lock = SafetyNet.lockURL(for: bundle)
        guard InstallLock.acquire(lock, now: seams.now()) else { log("rollback skipped: install lock is held"); return false }
        defer { InstallLock.release(lock) }
        let aside = bundle.deletingLastPathComponent().appendingPathComponent(".True-bad-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: bundle, to: aside)
            do { try fm.moveItem(at: previous, to: bundle) } catch { try? fm.moveItem(at: aside, to: bundle); throw error }
            try? fm.removeItem(at: aside)
        } catch { log("rollback failed, kept the current copy: \(error)"); return false }
        BadVersions.add(h.version, paths: paths)
        var n = h
        n.restoreState = true; n.restoreFrom = h.version; n.pending = false; n.uncleanStarts = 0
        try? n.save(paths)
        log("rolled back \(h.version) -> previous copy; \(h.version) is on the bad list; state restore requested")
        return true
    }

    // 4
    func staleCheck(bundle: URL, running: Bool) {
        // A staged update waiting only for True to quit skips the rhythm once True is stopped.
        let finishing = state.finishPending == true && !running
        if !finishing, let last = state.lastFeedRead, t - last < Lifeline.feedEvery { return }
        guard let rel = readFeed() else { return }
        let seen = state.feedSeen[rel.version] ?? t
        state.feedSeen[rel.version] = seen
        guard let own = installedVersion(bundle), UpdateCore.isNewer(rel.version, than: own) else { state.finishPending = nil; return }
        guard t - seen >= Lifeline.staleAfter else { log("feed has \(rel.version), installed \(own); True's own updater has until 48 h"); return }
        log("stale: installed \(own), feed \(rel.version) for over 48 h")
        install(rel, bundle: bundle, reason: .stale(installed: own), running: running)
    }

    func contactCheck() {
        let base = state.lastFeedContact ?? state.firstRun ?? t
        if t - base >= Lifeline.silentAfter { notifyOnce("True's updates cannot be reached. Open True on your home network.") }
    }

    /// Reads the feed; a single failure is logged only (being off the tailnet is normal).
    func readFeed() -> LifelineRelease? {
        state.lastFeedRead = t
        guard let cfg = SafetyNet.readJSON(LifelineConfig.self, at: paths.lifelineConfigFile),
              let url = LifelineFeed.latestURL(cfg.feedURL) else { log("no usable feed in config"); return nil }
        let feedBase = url.deletingLastPathComponent().deletingLastPathComponent()
        do {
            let data = try seams.fetch(url)
            state.lastFeedContact = t
            guard let rel = LifelineFeed.parse(data, feed: feedBase) else { log("feed answered but holds no usable release"); return nil }
            return rel
        } catch { log("feed read failed: \(error)"); return nil }
    }

    enum Reason { case reinstall, stale(installed: String) }

    func installFromFeed(bundle: URL, reason: Reason, running: Bool) {
        guard let rel = readFeed() else { return }
        install(rel, bundle: bundle, reason: reason, running: running)
    }

    func install(_ rel: LifelineRelease, bundle: URL, reason: Reason, running: Bool) {
        if BadVersions.load(paths).contains(rel.version) { state.finishPending = nil; log("feed version \(rel.version) is on the bad list; skipped"); return }
        // Never downgrade: a damaged or stale install may be replaced only by the same or a newer version.
        if let own = installedVersion(bundle), let c = UpdateCore.compare(rel.version, own), c < 0 { state.finishPending = nil; log("refused: feed \(rel.version) is older than installed \(own)"); return }
        if let at = state.installedAt[rel.version], t - at < Lifeline.installOnceEvery { log("skipped: \(rel.version) was already installed within 24 h"); return }
        guard let cfg = SafetyNet.readJSON(LifelineConfig.self, at: paths.lifelineConfigFile) else { return }
        let policy = UpdateCore.sigPolicy(from: ["TrueUpdatePublicKey": cfg.publicKey])
        guard case .key = policy else { log("refused: no usable public key"); return }
        let work = fm.temporaryDirectory.appendingPathComponent("true-lifeline-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { log("no scratch space: \(error)"); return }
        defer { try? fm.removeItem(at: work) }
        let staged: (app: URL, dir: URL, version: String)
        do {
            let zip = work.appendingPathComponent("True-macOS.zip"), sum = work.appendingPathComponent("True-macOS.zip.sha256"), sig = work.appendingPathComponent("True-macOS.zip.sig")
            try seams.fetch(rel.zip).write(to: zip)
            try seams.fetch(rel.sum).write(to: sum)
            if let s = rel.sig { try seams.fetch(s).write(to: sig) }
            // ownVersion "0": the downgrade rule was applied above; this lets a same-version reinstall through stagedProblem.
            staged = try UpdateInstaller.stage(zip: zip, sumFile: sum, sigFile: rel.sig == nil ? nil : sig, policy: policy, work: work, bundle: bundle,
                                               ownBundleID: "io.github.true-terminal.True", ownVersion: "0", osVersion: seams.osVersion)
        } catch {
            state.finishPending = nil
            log("refused \(rel.version): \(error)")
            notifyOnce("True could not verify an update and installed nothing.")
            return
        }
        // The version inside the zip is what gets installed: apply the same two rules to it, not just the feed's tag.
        if BadVersions.load(paths).contains(staged.version) {
            try? fm.removeItem(at: staged.dir); state.finishPending = nil
            log("refused: the zip holds \(staged.version), which is on the bad list")
            notifyOnce("True could not verify an update and installed nothing."); return
        }
        if let own = installedVersion(bundle), let c = UpdateCore.compare(staged.version, own), c < 0 {
            try? fm.removeItem(at: staged.dir); state.finishPending = nil
            log("refused: the zip holds \(staged.version), older than installed \(own)")
            notifyOnce("True could not verify an update and installed nothing."); return
        }
        // A stale swap must bring something newer: a newer tag on the installed version would re-swap every 6 h and overwrite the fallback copy.
        if case .stale = reason, let own = installedVersion(bundle), UpdateCore.compare(staged.version, own) == 0 {
            try? fm.removeItem(at: staged.dir); state.finishPending = nil
            log("refused: the zip holds \(staged.version), the version already installed")
            notifyOnce("True could not verify an update and installed nothing."); return
        }
        if running { state.finishPending = true; log("True is running; \(staged.version) staged"); notifyOnce("Quit True to finish updating."); return }
        let lock = SafetyNet.lockURL(for: bundle)
        guard InstallLock.acquire(lock, now: seams.now()) else { log("install lock is held; \(staged.version) stays staged"); return }
        defer { InstallLock.release(lock) }
        // The downloads above can take minutes: look again, under the lock, right before the swap.
        if Lifeline.trueRunning(psOutput: seams.processList()) {
            state.finishPending = true
            log("True is running; \(staged.version) staged"); notifyOnce("Quit True to finish updating."); return
        }
        do {
            try UpdateInstaller.swapKeepingPrevious(live: bundle, with: staged.app)
            try? fm.removeItem(at: staged.dir)
            state.installedAt[staged.version] = t
            state.finishPending = nil
            log("installed \(staged.version) at \(bundle.path)")
        } catch { log("install failed: \(error)") }
    }
}
