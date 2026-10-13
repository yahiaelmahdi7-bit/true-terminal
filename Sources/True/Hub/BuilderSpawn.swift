import Foundation

/// `truectl spawn` (SPEC Run 7): a lead starts a detached `builder` run. This file only validates the
/// request and assembles the argv — True never builds anything itself, `~/.claude/bin/builder` does.
struct SpawnRequest: Equatable, Sendable {
    var name: String
    var promptFile: String
    var repo: String?
    var worktree: Bool
    var model: String
    var from: String?

    /// Where a background build may run. The socket is a doorbell, so the door checks the room too.
    static func allowedRoots(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/Projects", "\(home)/studio-builds", "\(home)/Prism"]
    }

    /// builder's own slug alphabet: lowercase letters, digits, dashes; starts alphanumeric; 1–40 chars.
    static func isValidName(_ n: String) -> Bool {
        guard (1...40).contains(n.utf8.count), let first = n.unicodeScalars.first else { return false }
        func ok(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("0"..."9").contains(c) }
        return ok(first) && n.unicodeScalars.allSatisfy { ok($0) || $0 == "-" }
    }

    static func builderPath(home: String = NSHomeDirectory()) -> String { "\(home)/.claude/bin/builder" }

    /// The argv to run, or the one-line reason it is refused. `callerRepo` is the repo of the calling
    /// agent — the default when `--repo` is omitted.
    func command(callerRepo: String?, home: String = NSHomeDirectory(),
                 fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                 isDirectory: (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }) -> Result<[String], SpawnError> {
        guard Self.isValidName(name) else {
            return .failure(.init("bad name \"\(name)\" (lowercase letters, digits and dashes, max 40)"))
        }
        guard AgentModel(rawValue: model) != nil else {
            return .failure(.init("unknown model \"\(model)\" (\(AgentModel.allCases.map(\.rawValue).joined(separator: ", ")))"))
        }
        let prompt = (promptFile as NSString).standardizingPath
        guard prompt.hasPrefix("/"), fileExists(prompt), !isDirectory(prompt) else {
            return .failure(.init("prompt file not found: \(promptFile)"))
        }
        guard let rawRepo = [repo, callerRepo].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return .failure(.init("no repo: pass --repo (the caller has no repo to default to)"))
        }
        let dir = (rawRepo as NSString).standardizingPath
        guard isDirectory(dir) else { return .failure(.init("repo is not a folder: \(rawRepo)")) }
        guard Self.allowedRoots(home: home).contains(where: { dir == $0 || dir.hasPrefix($0 + "/") }) else {
            return .failure(.init("repo must be under ~/Projects, ~/studio-builds or ~/Prism: \(rawRepo)"))
        }
        var argv = [Self.builderPath(home: home), "start", "--name", name, "--cwd", dir, "--prompt-file", prompt]
        if worktree { argv.append("--worktree") }
        argv += ["--model", model]
        if let from, !from.isEmpty { argv += ["--parent", from] }
        return .success(argv)
    }
}

struct SpawnError: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

enum BuilderSpawn {
    /// Runs an argv, returns (exit status, combined output). Injected so tests never start a build.
    typealias Runner = @Sendable ([String]) async -> (Int32, String)

    /// The id from builder's `STARTED <id> (pid …)` line; nil when the run did not start.
    static func startedID(in output: String) -> String? {
        for line in output.split(separator: "\n") where line.hasPrefix("STARTED ") {
            let parts = line.split(separator: " ")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return nil
    }

    /// Reply text for `truectl`: `.success(id)` or `.failure(error text)`.
    static func run(_ req: SpawnRequest, callerRepo: String?, runner: Runner, home: String = NSHomeDirectory(),
                    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                    isDirectory: (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }) async -> Result<String, SpawnError> {
        switch req.command(callerRepo: callerRepo, home: home, fileExists: fileExists, isDirectory: isDirectory) {
        case .failure(let e): return .failure(e)
        case .success(let argv):
            let (code, out) = await runner(argv)
            if let id = startedID(in: out) { return .success(id) }
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.init(text.isEmpty ? "builder exited \(code) with no output" : text))
        }
    }

    /// The real runner. Output goes to a temp FILE, never a pipe: the detached supervisor inherits the
    /// descriptors of the process that started it, so a pipe would never reach EOF. A kill guard bounds
    /// a wedged launch; the wait happens off the main actor.
    static let systemRunner: Runner = { argv in
        await Task.detached(priority: .utility) {
            OffMain.assertOffMain()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("true-spawn-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let sink = try? FileHandle(forWritingTo: tmp) else { return (1, "cannot create a temp file for builder output") }
            defer { try? sink.close() }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            p.environment = env
            p.standardOutput = sink
            p.standardError = sink
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return (127, "cannot run builder: \(error.localizedDescription)") }
            let guardTask = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: guardTask)
            p.waitUntilExit()
            guardTask.cancel()
            let out = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            return (p.terminationStatus, out)
        }.value
    }
}
