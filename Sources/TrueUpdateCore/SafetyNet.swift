import Foundation

// The safety net: start health, bad versions, state backup, install lock. Shared by True (which writes health and backs up) and
// the lifeline (which reads health, rolls back, and never touches ~/.true). Every path comes from one injected `SafetyPaths`,
// so tests run against a temp folder and never reach the real ~/.true or ~/Library.

public struct SafetyPaths: Sendable, Equatable {
    /// `~/Library/Application Support/True`
    public var support: URL
    /// `~/.true`: True's own state. Only True reads or writes it; the lifeline never does.
    public var state: URL
    /// `~/Library/Logs`
    public var logs: URL
    /// `~/Library/LaunchAgents`
    public var launchAgents: URL

    public init(support: URL, state: URL, logs: URL, launchAgents: URL) {
        self.support = support; self.state = state; self.logs = logs; self.launchAgents = launchAgents
    }

    public static var standard: SafetyPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        return SafetyPaths(support: lib.appendingPathComponent("Application Support/True", isDirectory: true),
                           state: home.appendingPathComponent(".true", isDirectory: true),
                           logs: lib.appendingPathComponent("Logs", isDirectory: true),
                           launchAgents: lib.appendingPathComponent("LaunchAgents", isDirectory: true))
    }

    /// A whole fake home under `root`, for tests.
    public static func under(_ root: URL) -> SafetyPaths {
        SafetyPaths(support: root.appendingPathComponent("Library/Application Support/True", isDirectory: true),
                    state: root.appendingPathComponent(".true", isDirectory: true),
                    logs: root.appendingPathComponent("Library/Logs", isDirectory: true),
                    launchAgents: root.appendingPathComponent("Library/LaunchAgents", isDirectory: true))
    }

    public var healthFile: URL { support.appendingPathComponent("health.json") }
    public var lifelineDir: URL { support.appendingPathComponent("lifeline", isDirectory: true) }
    public var lifelineBinary: URL { lifelineDir.appendingPathComponent("TrueLifeline") }
    public var installPathFile: URL { lifelineDir.appendingPathComponent("install-path") }
    public var badVersionsFile: URL { lifelineDir.appendingPathComponent("bad-versions.json") }
    public var lifelineConfigFile: URL { lifelineDir.appendingPathComponent("config.json") }
    public var lifelineStateFile: URL { lifelineDir.appendingPathComponent("state.json") }
    public var backupRoot: URL { support.appendingPathComponent("state-backup", isDirectory: true) }
    public var repairFile: URL { support.appendingPathComponent("True-Repair.command") }
    public var lifelineLog: URL { logs.appendingPathComponent("true-lifeline.log") }
    public var launchAgentPlist: URL { launchAgents.appendingPathComponent("\(SafetyNet.lifelineLabel).plist") }
}

public enum SafetyNet {
    public static let lifelineLabel = "io.github.true-terminal.True-lifeline"
    /// The four files a rollback puts back. `~/.true/peers/` is deliberately absent: restoring an old grants.json could undo a revoked grant.
    public static let stateFiles = ["workspace.json", "agents.json", "projects.json", "closed.json"]
    public static let defaultInstallPath = "/Applications/True.app"
    public static let installLockName = ".True-install.lock"
    public static let previousDirName = ".True-previous"
    public static let lockStale: TimeInterval = 10 * 60
    public static let failedStartsForSafeMode = 2
    public static let failedStartsForRollback = 3
    public static let backupsKept = 2
    public static let healthyKept = 5

    /// `<folder holding True.app>/.True-previous/True.app`
    public static func previousApp(for bundle: URL) -> URL {
        bundle.deletingLastPathComponent().appendingPathComponent(previousDirName, isDirectory: true).appendingPathComponent("True.app")
    }
    public static func lockURL(for bundle: URL) -> URL {
        bundle.deletingLastPathComponent().appendingPathComponent(installLockName, isDirectory: true)
    }

    /// Atomically writes `data` (temp file in the same folder, then rename).
    static func writeAtomic(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func writeJSON<T: Encodable>(_ v: T, to url: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try writeAtomic(try enc.encode(v), to: url)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }
}

// MARK: health.json

public struct Health: Codable, Equatable, Sendable {
    public var version: String
    public var pending: Bool
    public var uncleanStarts: Int
    public var healthyVersions: [String]
    public var restoreState: Bool
    /// The bad version whose pre-start backup `restoreState` should put back. Written by the lifeline beside `restoreState`.
    public var restoreFrom: String?

    public init(version: String = "", pending: Bool = false, uncleanStarts: Int = 0, healthyVersions: [String] = [],
                restoreState: Bool = false, restoreFrom: String? = nil) {
        self.version = version; self.pending = pending; self.uncleanStarts = uncleanStarts
        self.healthyVersions = healthyVersions; self.restoreState = restoreState; self.restoreFrom = restoreFrom
    }

    public static func load(_ paths: SafetyPaths) -> Health? { SafetyNet.readJSON(Health.self, at: paths.healthFile) }
    public func save(_ paths: SafetyPaths) throws { try SafetyNet.writeJSON(self, to: paths.healthFile) }

    /// The lifeline rolls back only when this version keeps dying at start, never ran healthy here, and a previous copy exists.
    public func rollbackDue(previousExists: Bool) -> Bool {
        uncleanStarts >= SafetyNet.failedStartsForRollback && !healthyVersions.contains(version) && previousExists
    }
}

/// What True does with health.json at launch and during the run.
public enum StartHealth {
    public struct Outcome: Equatable, Sendable {
        public var safeMode: Bool
        /// A rollback asked for the saved state, and it was put back.
        public var restored: Bool
        public var backedUp: Bool
        public init(safeMode: Bool, restored: Bool, backedUp: Bool) { self.safeMode = safeMode; self.restored = restored; self.backedUp = backedUp }
    }

    /// Runs FIRST at launch, before anything reads the four state files. Restore (if the lifeline asked), then count a death
    /// (a version change resets the count), then mark this run pending. `optionHeld` forces safe mode.
    @discardableResult
    public static func begin(paths: SafetyPaths, runningVersion: String, bundlePath: String, optionHeld: Bool = false) -> Outcome {
        var h = Health.load(paths) ?? Health()
        var restored = false
        if h.restoreState {
            if let from = h.restoreFrom { restored = StateBackup.restore(version: from, paths: paths) }
            h.restoreState = false; h.restoreFrom = nil
        }
        if h.version != runningVersion { h.uncleanStarts = 0; h.pending = false }   // the count belongs to one version
        else if h.pending { h.uncleanStarts += 1 }
        // First start of a version: copy the four files before this version writes anything. Not right after a restore.
        var backedUp = false
        if h.version != runningVersion, !restored, !runningVersion.isEmpty {
            backedUp = StateBackup.backup(version: runningVersion, paths: paths)
        }
        let safe = optionHeld || h.uncleanStarts >= SafetyNet.failedStartsForSafeMode
        h.version = runningVersion
        h.pending = true
        try? h.save(paths)
        // A quarantined app opened from Downloads runs from a throwaway AppTranslocation path: never record it.
        if !bundlePath.contains("/AppTranslocation/") { try? SafetyNet.writeAtomic(Data((bundlePath + "\n").utf8), to: paths.installPathFile) }
        return Outcome(safeMode: safe, restored: restored, backedUp: backedUp)
    }

    /// 60 s after launch, window up and control socket answering.
    public static func markHealthy(paths: SafetyPaths, version: String) {
        var h = Health.load(paths) ?? Health(version: version)
        h.version = version; h.pending = false; h.uncleanStarts = 0
        h.healthyVersions.removeAll { $0 == version }
        h.healthyVersions.append(version)
        if h.healthyVersions.count > SafetyNet.healthyKept { h.healthyVersions.removeFirst(h.healthyVersions.count - SafetyNet.healthyKept) }
        try? h.save(paths)
    }

    /// `applicationWillTerminate`: a clean quit is not a failure. Leaves `uncleanStarts` alone.
    public static func markCleanQuit(paths: SafetyPaths, version: String) {
        guard var h = Health.load(paths), h.version == version else { return }
        h.pending = false
        try? h.save(paths)
    }
}

// MARK: bad-versions.json

public struct BadVersions: Codable, Equatable, Sendable {
    public var versions: [String]
    public init(versions: [String] = []) { self.versions = versions }

    public static func load(_ paths: SafetyPaths) -> BadVersions { SafetyNet.readJSON(BadVersions.self, at: paths.badVersionsFile) ?? BadVersions() }

    public func contains(_ v: String) -> Bool { versions.contains { UpdateCore.compare($0, v) == 0 } }

    public static func add(_ v: String, paths: SafetyPaths) {
        var b = load(paths)
        guard !b.contains(v) else { return }
        b.versions.append(v)
        try? SafetyNet.writeJSON(b, to: paths.badVersionsFile)
    }
}

// MARK: state backup

public enum StateBackup {
    /// Copies the four files that exist to `state-backup/<version>/`, then keeps only the newest `backupsKept` folders.
    @discardableResult
    public static func backup(version: String, paths: SafetyPaths) -> Bool {
        let fm = FileManager.default
        let dest = paths.backupRoot.appendingPathComponent(version, isDirectory: true)
        try? fm.removeItem(at: dest)
        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) } catch { return false }
        for name in SafetyNet.stateFiles {
            let src = paths.state.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: dest.appendingPathComponent(name)) }
        }
        let dirs = ((try? fm.contentsOfDirectory(at: paths.backupRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let sorted = dirs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a > b
        }
        for old in sorted.dropFirst(SafetyNet.backupsKept) where old.lastPathComponent != version { try? fm.removeItem(at: old) }
        return true
    }

    /// Puts the backed-up files back into `~/.true`. A file the backup does not have is left as it is. `peers/` is never touched.
    @discardableResult
    public static func restore(version: String, paths: SafetyPaths) -> Bool {
        let fm = FileManager.default
        let src = paths.backupRoot.appendingPathComponent(version, isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return false }
        try? fm.createDirectory(at: paths.state, withIntermediateDirectories: true)
        var any = false
        for name in SafetyNet.stateFiles {
            let from = src.appendingPathComponent(name), to = paths.state.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path), let data = try? Data(contentsOf: from) else { continue }
            if (try? SafetyNet.writeAtomic(data, to: to)) != nil { any = true }
        }
        return any
    }
}

// MARK: .True-install.lock

/// One install at a time: an atomic `mkdir` (works from Swift and bash), broken when older than 10 minutes.
public enum InstallLock {
    public static func acquire(_ lock: URL, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        if (try? fm.createDirectory(at: lock, withIntermediateDirectories: false)) != nil { return true }
        guard let m = (try? fm.attributesOfItem(atPath: lock.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(m) >= SafetyNet.lockStale else { return false }
        try? fm.removeItem(at: lock)
        return (try? fm.createDirectory(at: lock, withIntermediateDirectories: false)) != nil
    }

    public static func release(_ lock: URL) { try? FileManager.default.removeItem(at: lock) }
}
