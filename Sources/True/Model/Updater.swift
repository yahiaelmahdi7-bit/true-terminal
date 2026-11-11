import AppKit
import Foundation
import Observation
import os
import TrueUpdateCore

/// Built-in auto-update, the side-effect half (pure rules live in `UpdateLogic`). Inert unless Info.plist has
/// `TrueUpdateRepo` or `TrueUpdateFeed` (team builds: a private feed on Steward, which wins when both are set). Checks GitHub Releases or the feed at launch +30 s and every 24 h, downloads + verifies + stages the new app,
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
    /// When the self-restart countdown ends; non-nil exactly while the toast is up.
    private(set) var countdownEnd: Date?
    /// Version the countdown is about (for the toast text).
    private(set) var countdownVersion: String?

    @ObservationIgnored private let log = Logger(subsystem: "True", category: "update")
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var handled: String?   // newest version already installed, staged or announced this run
    @ObservationIgnored private let info: [String: Any]?
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let inputs: @MainActor () -> UpdateLogic.RestartInputs
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleeper: (TimeInterval) async -> Void
    @ObservationIgnored private let restartAction: @MainActor () -> Void
    @ObservationIgnored private let observeSources: Bool
    @ObservationIgnored private let safety: SafetyPaths
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var observing = false

    init(info: [String: Any]? = Bundle.main.infoDictionary, defaults: UserDefaults = .standard,
         inputs: @escaping @MainActor () -> UpdateLogic.RestartInputs = { UpdateLogic.RestartInputs.live() },
         now: @escaping () -> Date = Date.init,
         sleeper: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         restart: @escaping @MainActor () -> Void = { BuildFreshnessWatcher.shared.restart() },
         observeSources: Bool = true,
         bundleURL: URL = Bundle.main.bundleURL, safety: SafetyPaths = .standard) {
        self.safety = safety; self.info = info; self.defaults = defaults; self.bundleURL = bundleURL
        self.inputs = inputs; self.now = now; self.sleeper = sleeper; self.restartAction = restart; self.observeSources = observeSources
        lastChecked = (defaults.object(forKey: UpdateLogic.lastCheckKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// nil = this build never updates itself.
    var repo: String? { UpdateLogic.repo(from: info) }
    /// Team builds: base URL of the private feed, or nil. Wins over `repo`. A feed with no update public key beside it is
    /// not used at all (nil): a team build never installs unsigned code.
    var feedBase: URL? {
        if case .none = UpdateLogic.sigPolicy(from: info) { return nil }
        return UpdateLogic.feedBase(from: info)
    }
    /// A `TrueUpdateFeed` that is present but not acceptable (bad scheme, plain http off the tailnet) stays inert; it never falls back to GitHub.
    private var feedRequested: Bool { !((info?[UpdateLogic.feedKey] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var enabled: Bool { feedBase != nil || (!feedRequested && repo != nil) }
    var ownVersion: String { (info?["CFBundleShortVersionString"] as? String) ?? "0" }
    var autoInstall: Bool { defaults.object(forKey: UpdateLogic.installKey) as? Bool ?? true }
    /// "Restart to update when idle": follows the install switch until the person sets it themselves.
    var autoRestart: Bool { autoInstall && (defaults.object(forKey: UpdateLogic.autoRestartKey) as? Bool ?? true) }
    var restartDeferrals: Int { defaults.integer(forKey: UpdateLogic.restartDeferralsKey) }
    var autoCheck: Bool { defaults.object(forKey: UpdateLogic.autoKey) as? Bool ?? true }

    func start() {
        guard enabled, loop == nil else { return }
        adoptOrCleanStaged()
        evaluateRestart()
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

    /// Test seam: pretend an update is staged.
    func setStagedForTest(_ v: String) { stagedVersion = v }

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
        let team = feedBase
        guard !checking, let feed = team.flatMap({ UpdateLogic.feedURL(base: $0) }) ?? (feedRequested ? nil : repo.flatMap { UpdateLogic.feedURL(repo: $0) }) else { return }
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
            switch UpdateLogic.parseFeed(data, origin: team) {
            case .skip: if manual { status = "You're up to date" }; remember(etag)
            case .invalid(let why): throw UpdateFailure(why)
            case .release(let r):
                if BadVersions.load(safety).contains(r.version) { log.notice("update: \(r.version, privacy: .public) is on the bad list; skipped"); if manual { status = "You're up to date (\(ownVersion))" }; remember(etag); return }
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
        let bundle = bundleURL
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
            let lock = SafetyNet.lockURL(for: bundle)
            guard InstallLock.acquire(lock) else { throw UpdateFailure("another install holds the lock; retrying next cycle") }
            defer { InstallLock.release(lock) }
            try UpdateInstaller.swapKeepingPrevious(live: bundle, with: staged.app)
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
        evaluateRestart()
    }

    // MARK: restart to update by itself

    /// Is the self-restart path switched on and not worn out by cancellations.
    private var restartEnabled: Bool { UpdateLogic.autoRestartAllowed(setting: autoRestart, deferrals: restartDeferrals) }

    private func decision() -> UpdateLogic.RestartDecision {
        let i = inputs()
        let last = (defaults.object(forKey: UpdateLogic.restartLastDeferralKey) as? Double).map(Date.init(timeIntervalSince1970:))
        return UpdateLogic.restartDecision(staged: stagedVersion != nil, autoRestart: restartEnabled, working: i.working, peerJobs: i.peerJobs,
                                           builders: i.builders, modal: i.modal, idleSeconds: i.idleSeconds,
                                           now: now(), lastDeferral: last)
    }

    /// One look at the world. Called on every observed change, never on a loop. While nothing is staged it does nothing.
    func evaluateRestart() {
        guard stagedVersion != nil, restartEnabled else { cancelCountdown(reason: "nothing to do"); return }
        observeIfNeeded()
        let d = decision()
        if countdownEnd != nil {
            if d != .restartAfterCountdown { cancelCountdown(reason: "not idle any more") }
            return
        }
        switch d {
        case .restartAfterCountdown: armCountdown()
        case .wait(let why):
            // Input and dialogs fire no observable event, so one bounded re-look instead of a poll.
            let idle = inputs().idleSeconds
            let after = why == "recent input" ? max(5, UpdateLogic.restartIdleFloor - idle + 1) : 60
            recheckTask?.cancel()
            recheckTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.sleeper(after)
                if !Task.isCancelled { self.evaluateRestart() }
            }
        case .no: break
        }
    }

    private func armCountdown() {
        guard let v = stagedVersion else { return }
        recheckTask?.cancel(); recheckTask = nil
        countdownEnd = now().addingTimeInterval(UpdateLogic.restartCountdown)
        countdownVersion = v
        log.notice("update: auto-restart armed (v\(v, privacy: .public))")
        countdownTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.countdownEnd != nil {
                await self.sleeper(1)
                if Task.isCancelled { break }
                self.countdownTick()
            }
        }
    }

    /// The 1 s beat that exists only while the toast is up: re-check safety, then restart when time is up.
    func countdownTick() {
        guard let end = countdownEnd else { return }
        if decision() != .restartAfterCountdown { cancelCountdown(reason: "not idle any more"); return }
        if now() >= end { restartNow() }
    }

    /// "Cancel" on the toast: blocks another attempt for 4 h; three in a row leave only the pill.
    func cancelCountdownByUser() {
        guard countdownEnd != nil else { return }
        defaults.set(restartDeferrals + 1, forKey: UpdateLogic.restartDeferralsKey)
        defaults.set(now().timeIntervalSince1970, forKey: UpdateLogic.restartLastDeferralKey)
        cancelCountdown(reason: "cancelled by user")
    }

    /// "Now" on the toast, and the end of the countdown.
    func restartNow() {
        guard countdownEnd != nil, let v = countdownVersion else { return }
        log.notice("update: auto-restart now (v\(v, privacy: .public))")
        defaults.set(0, forKey: UpdateLogic.restartDeferralsKey)
        defaults.removeObject(forKey: UpdateLogic.restartLastDeferralKey)
        clearCountdown()
        restartAction()   // spawns the relauncher, sets installOnNextQuit, quits normally
    }

    private func cancelCountdown(reason: String) {
        recheckTask?.cancel(); recheckTask = nil
        guard countdownEnd != nil else { return }
        clearCountdown()
        log.notice("update: auto-restart cancelled (\(reason, privacy: .public))")
    }

    private func clearCountdown() {
        countdownTask?.cancel(); countdownTask = nil
        countdownEnd = nil; countdownVersion = nil
    }

    /// Re-arms itself on each change, only while an update is staged: the same sources WorkAwake watches, plus `stagedVersion`.
    private func observeIfNeeded() {
        guard observeSources, !observing else { return }
        observing = true
        withObservationTracking {
            let h = HubStore.shared, r = AgentRegistry.shared
            _ = (h.peers, h.builders, r.status, r.latest, r.panes, self.stagedVersion)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observing = false
                self.evaluateRestart()
            }
        }
    }

    // MARK: staged update

    /// A staged update left by an earlier run: keep it if still newer than this app, otherwise sweep the folder.
    func adoptOrCleanStaged() {
        let dir = UpdateInstaller.stagedDir(for: bundleURL)
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
        let bundle = bundleURL
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
            let lock = SafetyNet.lockURL(for: bundle)
            guard InstallLock.acquire(lock) else { log.notice("update: another install holds the lock; trying at the next quit"); return }
            defer { InstallLock.release(lock) }
            // The old copy goes to .True-previous (the sweep never touches it) and stays until the next install replaces it.
            try UpdateInstaller.swapKeepingPrevious(live: bundle, with: staged)
            try? FileManager.default.removeItem(at: dir)
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

extension UpdateLogic.RestartInputs {
    /// The real app: Claude sessions under True, active inbound peer jobs, running builders, any dialog, seconds since input.
    @MainActor static func live() -> UpdateLogic.RestartInputs {
        var i = UpdateLogic.RestartInputs()
        i.working = BuildFreshnessWatcher.shared.workingCount()
        // Only touch the peer engine on a Mac that is already paired; reading it must not create keys.
        if FileManager.default.fileExists(atPath: PeerEngine.standardRoot.appendingPathComponent("peers.json").path) {
            i.peerJobs = PeerService.engine.inboundJobs().filter { [.accepted, .working, .needsYou].contains($0.status) }.count
        }
        i.builders = HubStore.shared.builders.filter { $0.state == .running }.count
        let app: NSApplication? = NSApp   // nil outside a running app (tests)
        i.modal = app?.modalWindow != nil || app?.windows.contains { $0.attachedSheet != nil } == true
        i.idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
        return i
    }
}
