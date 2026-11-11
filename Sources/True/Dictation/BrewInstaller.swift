import Foundation

struct BrewResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case finished, cancelled, timedOut, launchFailed }
    var outcome: Outcome
    var status: Int32
    var lastLine: String

    var ok: Bool { outcome == .finished && status == 0 }
    /// One line for the UI when it did not work.
    var errorLine: String {
        switch outcome {
        case .cancelled: "Install cancelled."
        case .timedOut: "Install timed out after 20 minutes."
        case .launchFailed: "Could not start Homebrew."
        case .finished: "Install failed (exit \(status))" + (lastLine.isEmpty ? "." : ": \(lastLine)")
        }
    }
}

/// Runs `brew install whisper-cpp` (fixed argv, no shell). Output lines stream to `onLine`.
final class BrewInstaller: @unchecked Sendable {
    let brew: String
    let arguments: [String]
    let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(brew: String, arguments: [String] = ["install", "whisper-cpp"], timeout: TimeInterval = 20 * 60) {
        self.brew = brew; self.arguments = arguments; self.timeout = timeout
    }

    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    func run(onLine: @escaping @Sendable (String) -> Void) async -> BrewResult {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: self.runSync(onLine: onLine)) }
        }
    }

    private func runSync(onLine: @escaping @Sendable (String) -> Void) -> BrewResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        let state = LineState()
        pipe.fileHandleForReading.readabilityHandler = { h in
            for l in state.feed(h.availableData) { onLine(l) }
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        lock.lock(); process = p; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { return BrewResult(outcome: .cancelled, status: 0, lastLine: "") }
        do { try p.run() } catch { return BrewResult(outcome: .launchFailed, status: -1, lastLine: "") }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 3) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 3) }
        }
        Thread.sleep(forTimeInterval: 0.05)
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = state.flush() { onLine(rest) }
        lock.lock(); let c = cancelled; lock.unlock()
        let outcome: BrewResult.Outcome = timedOut ? .timedOut : (c ? .cancelled : .finished)
        return BrewResult(outcome: outcome, status: p.terminationStatus, lastLine: state.last)
    }
}

/// Splits streamed bytes into lines (\n or \r, as brew redraws progress with \r) and remembers the last non-empty one.
private final class LineState: @unchecked Sendable {
    private let l = NSLock()
    private var pending = ""
    private var lastLine = ""
    var last: String { l.lock(); defer { l.unlock() }; return lastLine }

    func feed(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        l.lock(); defer { l.unlock() }
        pending += String(decoding: data, as: UTF8.self)
        var parts = pending.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
        pending = parts.removeLast()
        let lines = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let x = lines.last { lastLine = x }
        return lines
    }

    func flush() -> String? {
        l.lock(); defer { l.unlock() }
        let x = pending.trimmingCharacters(in: .whitespacesAndNewlines); pending = ""
        if x.isEmpty { return nil }
        lastLine = x; return x
    }
}
