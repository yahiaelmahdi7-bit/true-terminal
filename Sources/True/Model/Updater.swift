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

    @ObservationIgnored private let log = Logger(subsystem: "True", category: "update")
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var handled: String?   // newest version already installed or announced this run
    @ObservationIgnored private let info: [String: Any]?

    init(info: [String: Any]? = Bundle.main.infoDictionary) { self.info = info }

    /// nil = this build never updates itself.
    var repo: String? { UpdateLogic.repo(from: info) }
    var enabled: Bool { repo != nil }
    var ownVersion: String { (info?["CFBundleShortVersionString"] as? String) ?? "0" }

    func start() {
        guard enabled, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UpdateLogic.firstCheckDelay))
            while !Task.isCancelled {
                if UserDefaults.standard.object(forKey: UpdateLogic.autoKey) as? Bool ?? true { await self?.check(manual: false) }
                try? await Task.sleep(for: .seconds(UpdateLogic.interval))
            }
        }
    }

    func openNoticePage() { if let u = notice?.pageURL { NSWorkspace.shared.open(u) } }

    /// One full cycle. `manual` only changes how much is said in `status`.
    func check(manual: Bool) async {
        guard let repo, !checking, let feed = UpdateLogic.feedURL(repo: repo) else { return }
        checking = true
        defer { checking = false }
        if manual { status = "Checking…" }
        do {
            var req = URLRequest(url: feed, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("True/\(ownVersion)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure("feed answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
            switch UpdateLogic.parseFeed(data) {
            case .skip: if manual { status = "You're up to date" }
            case .invalid(let why): throw UpdateFailure(why)
            case .release(let r):
                guard UpdateLogic.isNewer(r.version, than: ownVersion) else { if manual { status = "You're up to date (\(ownVersion))" }; return }
                if let h = handled, !UpdateLogic.isNewer(r.version, than: h) { if manual { status = "True \(h) is ready; restart to use it" }; return }
                try await apply(r)
            }
        } catch {
            log.error("update: \(String(describing: error), privacy: .public)")
            if manual { status = "Couldn't check for updates" }
        }
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
        status = "Downloading True \(r.version)…"
        let work = fm.temporaryDirectory.appendingPathComponent("true-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let zip = try await download(r.zipURL, to: work.appendingPathComponent(UpdateLogic.zipName))
        let sum = try await download(r.sumURL, to: work.appendingPathComponent(UpdateLogic.sumName))
        let own = (info?["CFBundleIdentifier"] as? String) ?? "", ver = ownVersion
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let installed = try await Task.detached(priority: .utility) {
            try UpdateInstaller.stageAndInstall(zip: zip, sumFile: sum, work: work, bundle: bundle, ownBundleID: own, ownVersion: ver, osVersion: os)
        }.value
        handled = installed
        status = "True \(installed) is ready; restart to use it"
        log.notice("update: installed \(installed, privacy: .public); waiting for restart")
        BuildFreshnessWatcher.shared.recheck()
    }

    private func download(_ url: URL, to dest: URL) async throws -> URL {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("True/\(ownVersion)", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure("download answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? 0
        guard size > 0, size <= UpdateLogic.maxZipBytes else { throw UpdateFailure("download has an odd size") }
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
    /// Verify checksum, unzip, vet the staged app, swap it in. Returns the installed version.
    static func stageAndInstall(zip: URL, sumFile: URL, work: URL, bundle: URL, ownBundleID: String, ownVersion: String,
                                osVersion: String) throws -> String {
        let fm = FileManager.default
        let sumText = (try? String(contentsOf: sumFile, encoding: .utf8)) ?? ""
        guard UpdateLogic.verify(actual: UpdateLogic.sha256Hex(fileAt: zip), sumFile: sumText) else { throw UpdateFailure("checksum mismatch") }

        // Staged next to the live bundle so the swap is a same-volume rename.
        let stage = bundle.deletingLastPathComponent().appendingPathComponent(".True-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let unpack = stage.appendingPathComponent("unpacked", isDirectory: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path]).status == 0 else { throw UpdateFailure("unzip failed") }
        let apps = ((try? fm.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let staged = apps.first else { throw UpdateFailure("zip does not hold exactly one app") }

        let plist = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        if let why = UpdateLogic.stagedProblem(info: plist, ownBundleID: ownBundleID, ownVersion: ownVersion, osVersion: osVersion) { throw UpdateFailure(why) }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]).status == 0 else { throw UpdateFailure("staged app fails codesign") }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        try swap(live: bundle, with: staged, backupDir: stage)
        return plist?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Move `live` into `backupDir`, move `staged` to `live`'s path, drop the backup. If the second move fails the
    /// backup goes back. `staged` and `backupDir` must be on the same volume as `live`.
    static func swap(live: URL, with staged: URL, backupDir: URL) throws {
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
        try? fm.removeItem(at: backup)
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
