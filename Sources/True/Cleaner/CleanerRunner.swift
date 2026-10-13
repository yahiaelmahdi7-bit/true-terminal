import Foundation

/// Runs the headless `claude` and returns its stdout. A protocol so tests never touch the real binary.
protocol CleanerRunning: Sendable {
    func run(binary: URL, argv: [String], stdin: Data, cwd: URL, env: [String: String],
             timeout: TimeInterval) async throws -> String
}

struct CleanerError: Error, Equatable, Sendable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Everything about *how* `claude` is launched for a rewrite. Pure, so it is tested without running anything.
enum CleanerLaunch {
    static let timeout: TimeInterval = 240

    /// First executable candidate that is not the `claude-burn` launcher wrapper. A GUI app's PATH lacks
    /// these folders, so they are listed explicitly.
    static func candidates(env: [String: String] = ProcessInfo.processInfo.environment,
                           home: String = NSHomeDirectory()) -> [String] {
        var c: [String] = []
        if let b = env["CLAUDE_BIN"], !b.isEmpty { c.append(b) }
        c += [home + "/.local/bin/claude", home + "/.claude/local/claude",
              "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return c
    }

    static func resolveBinary(candidates: [String]) -> URL? {
        for c in candidates {
            guard FileManager.default.isExecutableFile(atPath: c) else { continue }
            let resolved = URL(fileURLWithPath: c).resolvingSymlinksInPath()
            if resolved.lastPathComponent == "claude-burn" { continue }
            return URL(fileURLWithPath: c)
        }
        return nil
    }

    /// Verified on this Mac: uses the Max login, loads none of the user's hooks/plugins/MCP/CLAUDE.md.
    /// No `--bare` — it skips keychain reads, so the Max-plan login would fail.
    static func argv(model: AgentModel) -> [String] {
        ["-p", "--model", model.rawValue, "--setting-sources", "project", "--strict-mcp-config",
         "--tools", "", "--no-session-persistence", "--system-prompt", CleanerPrompt.text]
    }

    /// True's environment minus anything that makes the child think it is nested in, or steered by,
    /// another Claude session (`CLAUDECODE`, `CLAUDE_CODE_*`) or the burn-control hooks (`BURN_*`).
    static func scrubbedEnv(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        env.filter { k, _ in k != "CLAUDECODE" && !k.hasPrefix("CLAUDE_CODE_") && !k.hasPrefix("BURN_") }
    }

    /// An empty folder as cwd: a repo cwd would load that repo's CLAUDE.md and settings into the run.
    static func emptyDir(home: String = NSHomeDirectory()) -> URL {
        let d = URL(fileURLWithPath: home).appendingPathComponent(".true/cleaner/empty")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

/// Reference box so the process can be terminated from the cancellation/timeout paths.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var timedOut = false
    var out = Task<Data, Never> { Data() }
    var err = Task<Data, Never> { Data() }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Real runner. Completion is callback-driven (terminationHandler); the only timer is the 240 s
/// timeout, which exists just while a job runs.
struct ProcessCleanerRunner: CleanerRunning {
    func run(binary: URL, argv: [String], stdin: Data, cwd: URL, env: [String: String],
             timeout: TimeInterval) async throws -> String {
        let box = ProcessBox()
        let p = box.process
        p.executableURL = binary
        p.arguments = argv
        p.environment = env
        p.currentDirectoryURL = cwd
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe

        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            box.markTimedOut(); box.terminate()
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                p.terminationHandler = { _ in c.resume() }
                do { try p.run() } catch { c.resume(throwing: error); return }
                // Drain both pipes concurrently so a full pipe never stalls the child.
                let outH = outPipe.fileHandleForReading, errH = errPipe.fileHandleForReading
                box.out = Task.detached { (try? outH.readToEnd()) ?? Data() }
                box.err = Task.detached { (try? errH.readToEnd()) ?? Data() }
                let inH = inPipe.fileHandleForWriting
                Task.detached { try? inH.write(contentsOf: stdin); try? inH.close() }
            }
        } onCancel: { box.terminate() }
        try Task.checkCancellation()

        let out = await box.out.value, err = await box.err.value
        if box.didTimeOut { throw CleanerError(message: "Timed out after \(Int(timeout)) s") }
        guard p.terminationStatus == 0 else {
            let tail = String(decoding: err.suffix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CleanerError(message: "claude exited \(p.terminationStatus)" + (tail.isEmpty ? "" : ": \(tail)"))
        }
        return String(decoding: out, as: UTF8.self)
    }
}
