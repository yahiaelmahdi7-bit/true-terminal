import Testing
import Foundation
@testable import True
import TrueUpdateCore

/// The True side of the safety net: .True-previous survives launches, and start health runs before any state file is read.
@MainActor
struct SafetyWiringTests {
    private func app(_ at: URL, _ version: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: at)
        try fm.createDirectory(at: at.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: at.appendingPathComponent("Contents/MacOS/True"))
        let plist: [String: Any] = ["CFBundleIdentifier": "io.github.true-terminal.True", "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                    "CFBundleExecutable": "True", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"]
        try (plist as NSDictionary).write(to: at.appendingPathComponent("Contents/Info.plist"))
        #expect(UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", at.path]).status == 0)
    }
    private func updater(bundle: URL, root: URL) -> Updater {
        Updater(info: ["CFBundleIdentifier": "io.github.true-terminal.True", "CFBundleShortVersionString": "1.0.0", "TrueUpdateRepo": "o/r"],
                defaults: UserDefaults(suiteName: "sw-\(UUID().uuidString)")!, restart: {}, observeSources: false,
                bundleURL: bundle, safety: .under(root))
    }
    private func root() throws -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("sw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true); return r
    }

    @Test func quitInstallKeepsTheOldCopyInTrueDotPrevious_andLaunchingTwiceKeepsIt() throws {
        let r = try root(), live = r.appendingPathComponent("apps/True.app")
        try app(live, "1.0.0")
        try app(UpdateInstaller.stagedDir(for: live).appendingPathComponent("True.app"), "1.1.0")
        let u = updater(bundle: live, root: r)
        u.adoptOrCleanStaged()            // launch: adopts the newer staged copy
        u.installStagedAtQuit()
        let prev = SafetyNet.previousApp(for: live)
        func v(_ a: URL) -> String? { (NSDictionary(contentsOf: a.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String }
        #expect(v(live) == "1.1.0")
        #expect(v(prev) == "1.0.0")
        #expect(!FileManager.default.fileExists(atPath: UpdateInstaller.stagedDir(for: live).path))
        // two more launches (the sweep runs each time) leave it alone
        updater(bundle: live, root: r).adoptOrCleanStaged()
        updater(bundle: live, root: r).adoptOrCleanStaged()
        #expect(v(prev) == "1.0.0")
        // the next install replaces it
        try app(UpdateInstaller.stagedDir(for: live).appendingPathComponent("True.app"), "1.2.0")
        let u2 = Updater(info: ["CFBundleIdentifier": "io.github.true-terminal.True", "CFBundleShortVersionString": "1.1.0", "TrueUpdateRepo": "o/r"],
                         defaults: UserDefaults(suiteName: "sw-\(UUID().uuidString)")!, restart: {}, observeSources: false, bundleURL: live, safety: .under(r))
        u2.adoptOrCleanStaged(); u2.installStagedAtQuit()
        #expect(v(live) == "1.2.0" && v(prev) == "1.1.0")
    }

    @Test func installLockBlocksTheQuitInstall() throws {
        let r = try root(), live = r.appendingPathComponent("apps/True.app")
        try app(live, "1.0.0"); try app(UpdateInstaller.stagedDir(for: live).appendingPathComponent("True.app"), "1.1.0")
        #expect(InstallLock.acquire(SafetyNet.lockURL(for: live)))
        let u = updater(bundle: live, root: r); u.adoptOrCleanStaged(); u.installStagedAtQuit()
        let v = (NSDictionary(contentsOf: live.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
        #expect(v == "1.0.0")
    }

    // MARK: order: start health before any state read

    /// TrueApp's stored properties initialise in source order, before init() and before any scene or delegate callback.
    @Test func startHealthIsDeclaredBeforeModelAndRegistry() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/True/TrueApp.swift")
        let lines = try String(contentsOf: src, encoding: .utf8).components(separatedBy: "\n")
        func at(_ s: String) -> Int? { lines.firstIndex { $0.contains(s) } }
        let boot = try #require(at("private let startHealth = SafetyBoot.run()"))
        #expect(boot < (try #require(at("private let model = WorkspaceModel.shared"))))
        #expect(boot < (try #require(at("private let registry = AgentRegistry.shared"))))
        #expect(boot < (try #require(at("@NSApplicationDelegateAdaptor"))))
    }

    /// Every default location of the four files records itself; "boot" must come first.
    @Test func bootIsRecordedBeforeTheFirstStateFileRead() {
        SafetyBoot.resetOrderForTest(); SafetyBoot.run()
        _ = WorkspaceStore.defaultURL; _ = ProjectStore.defaultURL; _ = ClosedStack.defaultURL
        _ = AgentStore(url: URL(fileURLWithPath: "/nonexistent/agents.json"))
        let o = SafetyBoot.order
        #expect(o.first == "boot")
        for f in SafetyNet.stateFiles { #expect(o.contains(f), "\(f) read is not recorded") }
    }

    /// State files are located from any thread. Without the lock these appends corrupt the array or lose entries.
    /// Lives here because this suite runs one test at a time, so the reset in the test above cannot land mid-hammer.
    @Test func noteReadFromManyThreadsKeepsEveryEntry() {
        let label = "hammer-\(UUID().uuidString)", threads = 16, each = 5_000
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<each { SafetyBoot.noteRead(label) }
        }
        #expect(SafetyBoot.order.filter { $0 == label }.count == threads * each)
    }

    @Test func headlessModesSkipStartHealth() {
        for a in ["--ot0-spike", "--ot2-drive", "--ot2-stills"] { #expect(SafetyBoot.headlessRequested(["True", a])) }
        #expect(!SafetyBoot.headlessRequested(["True"]))
    }
}
