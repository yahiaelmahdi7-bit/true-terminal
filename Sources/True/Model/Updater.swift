import AppKit
import Foundation
import Observation
import os

/// Built-in auto-update, the side-effect half (pure rules live in `UpdateLogic`). Inert unless Info.plist has
/// `TrueUpdateRepo`. Checks GitHub Releases at launch +30 s and every 24 h, downloads + verifies + stages the new app,
/// swaps it into place, and `BuildFreshnessWatcher` then shows "Restart to update". Any failure abandons the cycle.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// A newer release we could not install in place (read-only or translocated app): the pill links to its page.
    private(set) var notice: UpdateLogic.Release?
    private(set) var status = ""
    private(set) var checking = false
    /// Version of a verified update staged on disk, waiting for the next quit (or "restart now").
    private(set) var stagedVersion: String?
    private(set) var lastChecked: Date?
    /// The impatient path: "Restart to update" was pressed, so the quit that follows installs even if auto-install is off.
    @ObservationIgnored var installOnNextQuit = false

    @ObservationIgnored private let log = Logger(subsystem: "True", category: "update")
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var handled: String?   // newest version already installed, staged or announced this run
    @ObservationIgnored private let info: [String: Any]?
    @ObservationIgnored private let defaults: UserDefaults

    init(info: [String: Any]? = Bundle.main.infoDictionary, defaults: UserDefaults = .standard) {
        self.info = info; self.defaults = defaults
        lastChecked = (defaults.object(forKey: UpdateLogic.lastCheckKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// nil = this build never updates itself.
    var repo: String? { UpdateLogic.repo(from: info) }
    var enabled: Bool { repo != nil }
    var ownVersion: String { (info?["CFBundleShortVersionString"] as? String) ?? "0" }
    var autoInstall: Bool { defaults.object(forKey: UpdateLogic.installKey) as? Bool ?? true }
    var autoCheck: Bool { defaults.object(forKey: UpdateLogic.autoKey) as? Bool ?? true }

    func start() {
        guard enabled, loop == nil else { return }
        adoptOrCleanStaged()
        defaults.set(defaults.integer(forKey: UpdateLogic.launchCountKey) + 1, forKey: UpdateLogic.launchCountKey)
        loop = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(UpdateLogic.launchDelay(lastCheck: self.lastChecked, now: Date())))
            self.askAutoUpdateIfDue()
            while !Task.isCancelled {
                if self.autoCheck { await self.check(manual: false) }
                try? await Task.sleep(for: .seconds(UpdateLogic.loopDelay(jitter: .random(in: -1...1))))
            }
        }
    }

    func openNoticePage() { if let u = notice?.pageURL { NSWorkspace.shared.open(u) } }

    /// One-time "Keep True up to date automatically?" on the second launch. Yes turns both switches on, No turns both off.
    private func askAutoUpdateIfDue() {
        guard UpdateLogic.promptDue(launchCount: defaults.integer(forKey: UpdateLogic.launchCountKey), answered: defaults.bool(forKey: UpdateLogic.askedKey)) else { return }
        defaults.set(true, forKey: UpdateLogic.askedKey)
        let alert = NSAlert()
        alert.messageText = "Keep True up to date automatically?"
        alert.informativeText = "True checks for new versions and installs them when you quit. You can change this in Settings."
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        let yes = alert.runModal() == .alertFirstButtonReturn
        defaults.set(yes, forKey: UpdateLogic.autoKey)
        defaults.set(yes, forKey: UpdateLogic.installKey)
    }

    // MARK: check

    /// One full cycle. `manual` only changes how much is said in `status`.
    func check(manual: Bool) async {
        guard let repo, !checking, let feed = UpdateLogic.feedURL(repo: repo) else { return }
        checking = true
        defer { checking = false }
        if manual { status = "Checking…" }
        let now = Date()
        lastChecked = now
        defaults.set(now.timeIntervalSince1970, forKey: UpdateLogic.lastCheckKey)
        do {
            var req = URLRequest(url: feed, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("True/\(ownVersion)", forHTTPHeaderField: "User-Agent")
            // A 304 does not count against GitHub's rate limit. Only sent for an answer we fully handled under this version.
            if let tag = UpdateLogic.conditionalETag(stored: defaults.string(forKey: UpdateLogic.etagKey),
                                                     storedFor: defaults.string(forKey: UpdateLogic.etagVersionKey), ownVersion: ownVersion) {
                req.setValue(tag, forHTTPHeaderField: "If-None-Match")
            }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 304 { if manual { status = "You're up to date (\(ownVersion))" }; return }
            guard http?.statusCode == 200 else { throw UpdateFailure("feed answered \(http?.statusCode ?? 0)") }
            let etag = http?.value(forHTTPHeaderField: "ETag")
            switch UpdateLogic.parseFeed(data) {
            case .skip: if manual { status = "You're up to date" }; remember(etag)
            case .invalid(let why): throw UpdateFailure(why)
            case .release(let r):
                guard UpdateLogic.isNewer(r.version, than: ownVersion) else { if manual { status = "You're up to date (\(ownVersion))" }; remember(etag); return }
                if let h = handled, !UpdateLogic.isNewer(r.version, than: h) { if manual { status = "True \(h) is ready; restart to use it" }; return }
                try await apply(r)
                remember(etag)   // only after the release was fully handled, so a failed download retries next cycle
            }
        } catch {
            log.error("update: \(String(describing: error), privacy: .public)")
            if manual { status = "Couldn't check for updates" }
        }
    }

    private func remember(_ etag: String?) {
        defaults.set(etag, forKey: UpdateLogic.etagKey)
        defaults.set(etag == nil ? nil : ownVersion, forKey: UpdateLogic.etagVersionKey)
    }

    private func apply(_ r: UpdateLogic.Release) async throws {
        let bundle = Bundle.main.bundleURL
        let fm = FileManager.default
        let plan = UpdateLogic.plan(bundlePath: bundle.path, bundleWritable: fm.isWritableFile(atPath: bundle.path),
                                    parentWritable: fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path))
        guard bundle.pathExtension == "app" else { return }   // a bare `swift run` binary has nothing to replace
        if plan == .notify {
            handled = r.version; notice = r; status = "True \(r.version) is out"
            log.notice("update: \(r.version, privacy: .public) available, bundle not writable; notice shown")
            return
        }
        let policy = UpdateLogic.sigPolicy(from: info)
        if case .badKey = policy { throw UpdateFailure("embedded update key is unusable; refusing every update") }
        if case .key = policy, r.sigURL == nil { throw UpdateFailure("release \(r.tag) is not signed; refusing") }
        status = "Downloading True \(r.version)…"
        let work = fm.temporaryDirectory.appendingPathComponent("true-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let zip = try await download(r.zipURL, to: work.appendingPathComponent(UpdateLogic.zipName))
        let sum = try await download(r.sumURL, to: work.appendingPathComponent(UpdateLogic.sumName))
        let sig: URL? = try await { () async throws -> URL? in
            guard let s = r.sigURL else { return nil }
            return try await download(s, to: work.appendingPathComponent(UpdateLogic.sigName), maxBytes: 4096)
        }()
        let own = (info?["CFBundleIdentifier"] as? String) ?? "", ver = ownVersion
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let deferInstall = autoInstall
        let installed = try await Task.detached(priority: .utility) { () -> String in
            let staged = try UpdateInstaller.stage(zip: zip, sumFile: sum, sigFile: sig, policy: policy, work: work, bundle: bundle,
                                                   ownBundleID: own, ownVersion: ver, osVersion: os)
            if deferInstall { return staged.version }   // stays on disk until the next quit
            defer { try? FileManager.default.removeItem(at: staged.dir) }
            try UpdateInstaller.swap(live: bundle, with: staged.app, backupDir: staged.dir)
            return staged.version
        }.value
        handled = installed
        if deferInstall {
            stagedVersion = installed
            status = "True \(installed) will install when you quit"
            log.notice("update: staged \(installed, privacy: .public); installs at quit")
        } else {
            status = "True \(installed) is ready; restart to use it"
            log.notice("update: installed \(installed, privacy: .public); waiting for restart")
        }
        BuildFreshnessWatcher.shared.recheck()
    }

    // MARK: staged update

    /// A staged update left by an earlier run: keep it if still newer than this app, otherwise sweep the folder.
    private func adoptOrCleanStaged() {
        let dir = UpdateInstaller.stagedDir(for: Bundle.main.bundleURL)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let plist = NSDictionary(contentsOf: dir.appendingPathComponent("\(UpdateInstaller.stagedAppName)/Contents/Info.plist")) as? [String: Any]
        if autoInstall, enabled, let v = plist?["CFBundleShortVersionString"] as? String, UpdateLogic.isNewer(v, than: ownVersion) {
            stagedVersion = v; handled = v
        } else {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Called from applicationWillTerminate, i.e. only on a normal quit (a crash or force-kill never reaches it).
    /// Two renames; any failure leaves the old app in place and the staged copy for the next quit.
    func installStagedAtQuit() {
        guard stagedVersion != nil, autoInstall || installOnNextQuit else { return }
        let bundle = Bundle.main.bundleURL
        let dir = UpdateInstaller.stagedDir(for: bundle)
        let staged = dir.appendingPathComponent(UpdateInstaller.stagedAppName)
        let plist = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        if let why = UpdateLogic.stagedProblem(info: plist, ownBundleID: (info?["CFBundleIdentifier"] as? String) ?? "", ownVersion: ownVersion, osVersion: os) {
            log.error("update: staged copy rejected at quit: \(why, privacy: .public)")
            return
        }
        do {
            try UpdateInstaller.swap(live: bundle, with: staged, backupDir: dir, keepBackup: true)   // old copy is swept at next launch
            log.notice("update: installed \(self.stagedVersion ?? "", privacy: .public) at quit")
        } catch {
            log.error("update: install at quit failed, keeping the old app: \(String(describing: error), privacy: .public)")
        }
    }

    private func download(_ url: URL, to dest: URL, maxBytes: Int64 = UpdateLogic.maxZipBytes) async throws -> URL {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("True/\(ownVersion)", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure("download answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? 0
        guard size > 0, size <= maxBytes else { throw UpdateFailure("download has an odd size") }
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

struct UpdateFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Blocking file work for one install; runs off the main actor. Every failure throws before the live bundle is touched,
/// except the swap itself, which restores the backup if the second rename fails.
enum UpdateInstaller {
    static let stagedAppName = "True.app"

    /// Where a verified update waits for the next quit: next to the live bundle so the swap is a same-volume rename.
    static func stagedDir(for bundle: URL) -> URL { bundle.deletingLastPathComponent().appendingPathComponent(".True-staged", isDirectory: true) }

    /// Signature (when the build has a key) and checksum first, THEN unzip, vet the app, leave it in `dir` as `True.app`.
    /// Nothing is unpacked from a zip that fails either check.
    static func stage(zip: URL, sumFile: URL, sigFile: URL?, policy: UpdateLogic.SigPolicy, work: URL, bundle: URL,
                      ownBundleID: String, ownVersion: String, osVersion: String) throws -> (app: URL, dir: URL, version: String) {
        let fm = FileManager.default
        switch policy {
        case .badKey: throw UpdateFailure("embedded update key is unusable")
        case .none: break
        case .key(let key):
            guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe) else { throw UpdateFailure("cannot read the download") }
            let sigText = sigFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let r = UpdateLogic.verifySignature(zip: data, sigText: sigText, publicKey: key)
            guard r == .valid else { throw UpdateFailure("signature check failed (\(r))") }
        }
        let sumText = (try? String(contentsOf: sumFile, encoding: .utf8)) ?? ""
        guard UpdateLogic.verify(actual: UpdateLogic.sha256Hex(fileAt: zip), sumFile: sumText) else { throw UpdateFailure("checksum mismatch") }

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
        if let why = UpdateLogic.stagedProblem(info: plist, ownBundleID: ownBundleID, ownVersion: ownVersion, osVersion: osVersion) { throw UpdateFailure(why) }
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
    static func swap(live: URL, with staged: URL, backupDir: URL, keepBackup: Bool = false) throws {
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

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
