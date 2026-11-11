import Foundation

enum PRTool: Equatable, Sendable {
    case git, gh
    /// An absolute path (the gate script).
    case file(String)
}

struct PRCommand: Equatable, Sendable {
    var tool: PRTool
    var args: [String]
    var cwd: String?
    var timeout: TimeInterval = 15
    /// Stop reading (and stop the process) past this many bytes of output.
    var maxBytes: Int? = nil
}

struct PRRun: Equatable, Sendable {
    var code: Int32
    var out: String = ""
    var err: String = ""
    var timedOut = false
    var truncated = false
    /// The program could not be found or started.
    var missing = false
    var ok: Bool { code == 0 && !timedOut && !missing }
    var trimmed: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// First non-empty line of the error text (else of the output): what a refusal shows.
    var firstLine: String {
        let text = err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? out : err
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }
}

/// Runs `git`/`gh` with an args array (never a shell string). Injectable: tests pass a fake.
struct PRRunner: Sendable {
    var run: @Sendable (PRCommand) async -> PRRun

    static let live = PRRunner.process(resolve: { ProgramFinder.shared.resolve($0) }, path: { ProgramFinder.shared.path })

    /// Programs are found through ProgramFinder (a GUI-launched True lacks `/opt/homebrew/bin` on PATH);
    /// the child gets that PATH too. Output goes to files so a big diff cannot fill a pipe.
    static func process(resolve: @escaping @Sendable (String) -> String?, path: @escaping @Sendable () -> String) -> PRRunner {
        PRRunner { command in
            await Task.detached(priority: .utility) { runProcess(command, resolve: resolve, path: path) }.value
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    private static func runProcess(_ c: PRCommand, resolve: (String) -> String?, path: () -> String) -> PRRun {
        let exe: String?
        switch c.tool {
        case .git: exe = resolve("git") ?? "/usr/bin/git"
        case .gh: exe = resolve("gh")
        case .file(let p): exe = p
        }
        guard let exe else { return PRRun(code: -127, missing: true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("true-pr-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let outURL = root.appendingPathComponent("out"), errURL = root.appendingPathComponent("err")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            let outH = try FileHandle(forWritingTo: outURL), errH = try FileHandle(forWritingTo: errURL)
            defer { try? outH.close(); try? errH.close() }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = c.args
            if let cwd = c.cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path()
            env["GIT_TERMINAL_PROMPT"] = "0"; env["GH_PROMPT_DISABLED"] = "1"; env["NO_COLOR"] = "1"
            p.environment = env
            p.standardOutput = outH; p.standardError = errH; p.standardInput = FileHandle.nullDevice
            try p.run()
            let deadline = Date().addingTimeInterval(c.timeout)
            var timedOut = false, truncated = false
            while p.isRunning {
                if Date() >= deadline { timedOut = true; break }
                if let cap = c.maxBytes, fileSize(outURL) > cap { truncated = true; break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            if p.isRunning {
                p.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            p.waitUntilExit()
            func read(_ url: URL, cap: Int?) -> String {
                guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
                defer { try? h.close() }
                let data = (try? h.read(upToCount: cap ?? Int.max)) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
            if let cap = c.maxBytes, fileSize(outURL) > cap { truncated = true }
            return PRRun(code: timedOut ? -2 : p.terminationStatus, out: read(outURL, cap: c.maxBytes),
                         err: read(errURL, cap: 65_536), timedOut: timedOut, truncated: truncated)
        } catch {
            return PRRun(code: -127, missing: true)
        }
    }
}
