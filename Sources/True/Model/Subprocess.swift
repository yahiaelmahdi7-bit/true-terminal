import Foundation

/// The one way True runs a short helper tool (lsof, ps, git, tailscale, security…) and reads its output.
/// Closes the pipe's read end itself instead of waiting for the Process/Pipe objects to be freed: True polls
/// these every few seconds, and one descriptor left behind per run used up the 256-file limit and crashed the app.
enum Subprocess {
    /// Run to completion: (exit status, stdout). nil when it can't launch. stderr is dropped unless `mergeStderr`.
    /// `timeout` nil = wait as long as it takes (installs, clones).
    static func exec(_ exe: String, _ args: [String], timeout: TimeInterval? = 10, mergeStderr: Bool = false,
                     env: [String: String]? = nil) -> (status: Int32, out: Data)? {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        if let env { p.environment = env }
        let pipe = Pipe(), out = pipe.fileHandleForReading
        p.standardOutput = pipe; p.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        defer { try? out.close() }
        do { try p.run() } catch { try? pipe.fileHandleForWriting.close(); return nil }
        // Weak: a cancelled work item still lives until its deadline, and must not hold the Process (and pipe) that long.
        let killer = DispatchWorkItem { [weak p] in if p?.isRunning == true { p?.terminate() } }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer) }
        let data = out.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, data)
    }

    /// stdout of a run that exited 0; nil on launch failure, non-zero exit or timeout.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval? = 10) -> Data? {
        exec(exe, args, timeout: timeout).flatMap { $0.status == 0 ? $0.out : nil }
    }

    /// Soft RLIMIT_NOFILE → min(hard, 8192). macOS starts GUI apps at 256, and every pane's pty, socket and pipe counts.
    static func raiseFileLimit(to want: rlim_t = 8192) {
        var l = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &l) == 0, l.rlim_cur < want else { return }
        l.rlim_cur = min(want, l.rlim_max)
        setrlimit(RLIMIT_NOFILE, &l)
    }

    static func string(_ exe: String, _ args: [String], timeout: TimeInterval? = 10) -> String? {
        run(exe, args, timeout: timeout).map { String(decoding: $0, as: UTF8.self) }
    }
}
