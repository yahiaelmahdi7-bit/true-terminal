import Foundation

/// "AI fill": one headless Claude Code call turns a one-line description into a full agent profile.
/// Everything except `run` is pure so it can be tested without spawning anything.
enum AgentFill {
    struct FillError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Profile: Decodable, Equatable {
        let role: String
        let model: String
        let effort: String
        let permission: String
        let symbol: String
        let charter: String
    }

    static let schema: String = {
        func strEnum(_ v: [String]) -> [String: Any] { ["type": "string", "enum": v] }
        let obj: [String: Any] = [
            "type": "object",
            "properties": [
                "role": strEnum(AgentRole.allCases.map(\.rawValue)),
                "model": strEnum(AgentModel.allCases.map(\.rawValue)),
                "effort": strEnum(AgentEffort.allCases.map(\.rawValue)),
                "permission": strEnum(AgentPermission.allCases.map(\.rawValue)),
                "symbol": strEnum(BuilderDraft.symbols),
                "charter": ["type": "string"],
            ],
            "required": ["role", "model", "effort", "permission", "symbol", "charter"],
            "additionalProperties": false,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }()

    static func prompt(request: String, draft: BuilderDraft) -> String {
        let repoLine = draft.repo.isEmpty
            ? "No repo is chosen yet."
            : "The agent works in the repo \(URL(fileURLWithPath: draft.repo).lastPathComponent) at \(draft.repo)."
        let roleLine = draft.editing != nil
            ? "The role is fixed to \(draft.role.rawValue); return exactly that role."
            : "Choose the role: lead (coordinates helpers) or helper (does focused work) or global (works across repos and hands work to repo leads)."
        return """
        Design a Claude Code agent profile for this request: \(request)

        \(repoLine)
        \(roleLine)

        Pick the model by task weight: haiku = search and read-only sweeps, sonnet = routine implementation and tests, opus = architecture and hard debugging, fable = highest-stakes judgment. Pick the effort level the same way. Pick the permission by how much autonomy the request implies: default = ask before acting, acceptEdits = edit files freely, plan = read-only planning, auto = fully autonomous.
        Pick the symbol from the allowed list that best fits the agent.

        The charter is an extensive standing brief in markdown, 120 to 250 words, with these headings: Mission, Scope (files and areas it may and may not touch), Working rules, Definition of done. Write it in second person, concrete, no filler.
        """
    }

    static func argv(claude: String, schema: String, prompt: String) -> [String] {
        [claude, "-p", "--model", "sonnet", "--output-format", "json", "--json-schema", schema,
         "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--no-session-persistence",
         "--tools", "", "--setting-sources", "user", prompt]
    }

    static func parse(_ data: Data) throws -> Profile {
        struct Outer: Decodable {
            let subtype: String?
            let is_error: Bool?
            let result: String?
            let structured_output: Profile?
        }
        let outer: Outer
        do { outer = try JSONDecoder().decode(Outer.self, from: data) }
        catch { throw FillError(message: "Claude returned something unreadable.") }
        let detail = outer.result.map { $0.isEmpty ? "" : ": \($0)" } ?? ""
        if outer.is_error == true || (outer.subtype != nil && outer.subtype != "success") {
            throw FillError(message: "Claude could not fill the profile\(detail)")
        }
        guard let p = outer.structured_output else {
            throw FillError(message: "Claude returned no profile\(detail)")
        }
        return p
    }

    static func apply(_ p: Profile, to draft: inout BuilderDraft) {
        if draft.editing == nil, let r = AgentRole(rawValue: p.role) { draft.role = r }
        if let m = AgentModel(rawValue: p.model) { draft.model = m }
        if let e = AgentEffort(rawValue: p.effort) { draft.effort = e }
        if let perm = AgentPermission(rawValue: p.permission) { draft.permission = perm }
        if BuilderDraft.symbols.contains(p.symbol) { draft.symbol = p.symbol }
        draft.charter = p.charter
    }

    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    }

    static func resolveClaude() -> String? {
        if let c = cache.get() { return c }
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var found = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { fm.isExecutableFile(atPath: $0) }
        if found == nil {
            if let data = Subprocess.exec("/bin/zsh", ["-lic", "whence -p claude"])?.out {
                let s = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !s.isEmpty, fm.isExecutableFile(atPath: s) { found = s }
            }
        }
        if let found { cache.set(found) }
        return found
    }

    private final class ErrBox: @unchecked Sendable { var data = Data() }

    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private(set) var timedOut = false
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func attach(_ p: Process) {
            lock.lock(); process = p; let c = cancelled; lock.unlock()
            if c { p.terminate() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let p = process; lock.unlock()
            p?.terminate()
        }
        func timeout() {
            lock.lock(); timedOut = true; let p = process; lock.unlock()
            p?.terminate()
        }
        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    }

    @MainActor
    static func run(request: String, draft: BuilderDraft) async throws -> Profile {
        let repo = draft.repo
        let text = prompt(request: request, draft: draft)
        let job = Job()
        let data: Data = try await withTaskCancellationHandler {
            try await Task.detached { try execute(prompt: text, repo: repo, job: job) }.value
        } onCancel: { job.cancel() }
        return try parse(data)
    }

    private static func execute(prompt: String, repo: String, job: Job) throws -> Data {
        guard let claude = resolveClaude() else {
            throw FillError(message: "Couldn't find the claude command. Install Claude Code first.")
        }
        var args = argv(claude: claude, schema: schema, prompt: prompt)
        let exe = args.removeFirst()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var isDir: ObjCBool = false
        let dir = !repo.isEmpty && FileManager.default.fileExists(atPath: repo, isDirectory: &isDir) && isDir.boolValue
            ? repo : NSHomeDirectory()
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env: [String: String] = [:]
        for (k, v) in ProcessInfo.processInfo.environment
        where k != "CLAUDECODE" && !k.hasPrefix("CLAUDE_CODE_") { env[k] = v }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { throw FillError(message: "Couldn't start claude: \(error.localizedDescription)") }
        job.attach(p)
        let timer = DispatchWorkItem { job.timeout() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timer)
        let errBox = ErrBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            try? err.fileHandleForReading.close()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        try? out.fileHandleForReading.close()
        p.waitUntilExit()
        group.wait()
        timer.cancel()
        if job.wasCancelled { throw CancellationError() }
        if job.didTimeOut { throw FillError(message: "Claude took longer than 90 seconds.") }
        if data.isEmpty {
            let msg = String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FillError(message: msg.isEmpty ? "Claude exited with no output." : msg)
        }
        return data
    }
}
