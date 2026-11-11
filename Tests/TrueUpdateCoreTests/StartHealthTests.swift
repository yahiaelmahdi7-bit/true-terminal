import Testing
import Foundation
@testable import TrueUpdateCore

struct StartHealthTests {
    func tmp() -> SafetyPaths { .under(FileManager.default.temporaryDirectory.appendingPathComponent("sh-\(UUID().uuidString)", isDirectory: true)) }
    func put(_ p: SafetyPaths, _ name: String, _ s: String) throws {
        let f = p.state.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: f)
    }
    func read(_ p: SafetyPaths, _ name: String) -> String? { try? String(contentsOf: p.state.appendingPathComponent(name), encoding: .utf8) }
    @discardableResult func start(_ p: SafetyPaths, _ v: String = "1.0.0", option: Bool = false) -> StartHealth.Outcome {
        StartHealth.begin(paths: p, runningVersion: v, bundlePath: "/x/True.app", optionHeld: option)
    }

    @Test func twoCleanQuitsCountForNothing() {
        let p = tmp()
        start(p); StartHealth.markCleanQuit(paths: p, version: "1.0.0")
        start(p); StartHealth.markCleanQuit(paths: p, version: "1.0.0")
        let o = start(p)
        #expect(Health.load(p)?.uncleanStarts == 0)
        #expect(!o.safeMode)
    }

    @Test func deathsCountAndSafeModeIsTwoOrMore() {
        let p = tmp()
        #expect(!start(p).safeMode)          // first start
        #expect(!start(p).safeMode)          // died once: 1
        #expect(start(p).safeMode)           // died twice: 2
        #expect(start(p).safeMode)           // 3 stays in safe mode
        #expect(Health.load(p)?.uncleanStarts == 3)
    }

    @Test func optionHeldForcesSafeMode() { #expect(start(tmp(), option: true).safeMode) }

    @Test func versionChangeResetsTheCount() {
        let p = tmp()
        start(p); start(p); start(p)         // 1.0.0 now at 2
        let o = start(p, "1.1.0")
        #expect(Health.load(p)?.uncleanStarts == 0)
        #expect(!o.safeMode)
    }

    @Test func healthyVersionIsNeverRolledBack() {
        let p = tmp()
        start(p); StartHealth.markHealthy(paths: p, version: "1.0.0")
        start(p); start(p); start(p); start(p)   // dies 3 times after having been healthy
        let h = Health.load(p)!
        #expect(h.uncleanStarts >= 3)
        #expect(!h.rollbackDue(previousExists: true))
        #expect(start(p).safeMode)
        let q = tmp(); start(q); start(q); start(q); start(q)
        #expect(Health.load(q)!.rollbackDue(previousExists: true))
    }

    @Test func firstStartOfAVersionBacksUpTheFourFiles() throws {
        let p = tmp()
        for n in SafetyNet.stateFiles { try put(p, n, "old-\(n)") }
        try put(p, "peers.json", "keep")
        let o = start(p, "1.0.0")
        #expect(o.backedUp)
        for n in SafetyNet.stateFiles { #expect(try String(contentsOf: p.backupRoot.appendingPathComponent("1.0.0/\(n)")) == "old-\(n)") }
        #expect(!FileManager.default.fileExists(atPath: p.backupRoot.appendingPathComponent("1.0.0/peers.json").path))
        #expect(!start(p, "1.0.0").backedUp)
    }

    @Test func backupKeepsTheLastTwo() throws {
        let p = tmp(); try put(p, "workspace.json", "x")
        for v in ["1.0.0", "1.1.0", "1.2.0"] { StateBackup.backup(version: v, paths: p); Thread.sleep(forTimeInterval: 0.02) }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: p.backupRoot.path))
        #expect(names == ["1.1.0", "1.2.0"])
    }

    @Test func restorePutsFourFilesBackFromRestoreFromAndLeavesPeersAlone() throws {
        let p = tmp()
        for n in SafetyNet.stateFiles { try put(p, n, "good-\(n)") }
        try put(p, "peers/keys.json", "peer-secret")
        start(p, "1.1.0")                                        // backs up state/ as 1.1.0 "just before it wrote anything"
        for n in SafetyNet.stateFiles { try put(p, n, "BAD-\(n)") }   // the bad version scribbles
        try put(p, "peers/keys.json", "peer-newer")
        try Health(version: "1.1.0", pending: false, uncleanStarts: 0, restoreState: true, restoreFrom: "1.1.0").save(p)
        let o = start(p, "1.0.0")
        #expect(o.restored)
        for n in SafetyNet.stateFiles { #expect(read(p, n) == "good-\(n)", "\(n)") }
        #expect(read(p, "peers/keys.json") == "peer-newer")
        let h = Health.load(p)!
        #expect(!h.restoreState && h.restoreFrom == nil && h.uncleanStarts == 0)
    }

    @Test func restoreWithoutABackupChangesNothing() throws {
        let p = tmp(); try put(p, "workspace.json", "keep")
        try Health(version: "1.1.0", restoreState: true, restoreFrom: "1.1.0").save(p)
        #expect(!start(p, "1.0.0").restored)
        #expect(read(p, "workspace.json") == "keep")
    }

    @Test func installLockIsAtomicAndBreaksOnlyWhenOld() throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("lk-\(UUID().uuidString)")
        let now = Date()
        #expect(InstallLock.acquire(lock, now: now))
        #expect(!InstallLock.acquire(lock, now: now))
        #expect(InstallLock.acquire(lock, now: now.addingTimeInterval(601)))
        InstallLock.release(lock)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }
}

struct TranslocationTests {
    @Test func aTranslocatedLaunchLeavesInstallPathAlone() throws {
        let p = SafetyPaths.under(FileManager.default.temporaryDirectory.appendingPathComponent("tl-\(UUID().uuidString)", isDirectory: true))
        StartHealth.begin(paths: p, runningVersion: "1.0.0", bundlePath: "/Users/me/Applications/True.app")
        StartHealth.begin(paths: p, runningVersion: "1.0.0", bundlePath: "/private/var/folders/ab/xyz/AppTranslocation/ABCD/d/True.app")
        let s = try String(contentsOf: p.installPathFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(s == "/Users/me/Applications/True.app")
    }
}
