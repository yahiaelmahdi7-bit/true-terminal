import AppKit
import TrueUpdateCore

/// Start health, run once, first thing at launch (see TrueApp.startHealth, its FIRST stored property).
/// It must finish before anything reads workspace/agents/projects/closed.json, because the lifeline may have asked
/// for the saved state to be put back. `order` records that: "boot" first, then each state-file read.
enum SafetyBoot {
    /// Files are located from any thread, so every touch of `recorded` goes through this lock.
    private static let orderLock = NSLock()
    nonisolated(unsafe) private static var recorded: [String] = []
    static var order: [String] { orderLock.withLock { recorded } }
    nonisolated(unsafe) private(set) static var outcome = StartHealth.Outcome(safeMode: false, restored: false, backedUp: false)
    nonisolated(unsafe) private(set) static var didRun = false

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    /// The hidden headless modes honour a temp HOME and must not touch the real health file.
    static func headlessRequested(_ a: [String] = CommandLine.arguments) -> Bool {
        a.contains("--ot0-spike") || a.contains("--ot2-drive") || a.contains("--ot2-stills")
    }

    @discardableResult
    static func run() -> Bool {
        orderLock.withLock { recorded.append("boot") }
        guard !headlessRequested(), Bundle.main.bundleURL.pathExtension == "app" else { return true }
        didRun = true
        outcome = StartHealth.begin(paths: .standard, runningVersion: version, bundlePath: Bundle.main.bundleURL.path,
                                    optionHeld: NSEvent.modifierFlags.contains(.option))
        return true
    }

    /// Called where each of the four files is first located. Proof of order lives in SafetyBootOrderTests.
    static func noteRead(_ name: String) { orderLock.withLock { recorded.append(name) } }
    static func resetOrderForTest() { orderLock.withLock { recorded = [] } }
}

/// Read-only. Add-ons (Step 4) will ask this and nothing else.
enum SafeMode {
    static var isOn: Bool { SafetyBoot.outcome.safeMode }
    static var restored: Bool { SafetyBoot.outcome.restored }
}
