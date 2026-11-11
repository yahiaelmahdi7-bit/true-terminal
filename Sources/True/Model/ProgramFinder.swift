import Foundation
import Darwin

/// Shared discovery for GUI-launched helpers. File lookup never waits for a shell or a probe.
final class ProgramFinder: @unchecked Sendable {
    static let shared = ProgramFinder()
    static let programs = ["git", "claude", "codex", "gh", "tailscale"]
    static let begin = "__TRUE_PATH_BEGIN__", end = "__TRUE_PATH_END__"

    enum State: String, Sendable {
        case ready = "Ready"
        case notInstalled = "Not installed"
        case notWorking = "Installed but not working"
        case notSignedIn = "Not signed in"
    }
    struct Result: Equatable, Sendable {
        let path: String?
        let state: State
        /// Set by the one sign-in reader (`SignInProbe`) for claude and codex; Unknown for every other program.
        var signIn: SeatSignIn = .unknown
        var plan: String?
        var email: String?
        var line: String { state.rawValue }
    }
    struct Output: Sendable {
        let status: Int32
        let text: String
        let timedOut: Bool
    }
    typealias Runner = @Sendable (String, [String], [String: String], TimeInterval) -> Output?

    private let lock = NSLock()
    private let refreshLock = NSLock()
    private let shell: String
    private let environment: [String: String]
    private let roots: [String]
    private let tailscaleCopies: [String]
    private let runner: Runner
    private let shellTimeout: TimeInterval
    /// Per-probe limit for `--version` and status calls. Tests pass a generous ceiling so a loaded Mac never reads as "not working".
    private let probeTimeout: TimeInterval
    private let securityPath: String
    private var directories: [String]
    private var results: [String: Result] = [:]
    private var started = false
    private var pendingFailures = Set<String>()

    init(shell: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
         roots: [String]? = nil, tailscaleCopies: [String]? = nil,
         shellTimeout: TimeInterval = 5, probeTimeout: TimeInterval = 2, securityPath: String = SignInProbe.defaultSecurity, runner: @escaping Runner = ProgramFinder.run) {
        let home = environment["HOME"] ?? NSHomeDirectory()
        self.shell = shell ?? environment["SHELL"] ?? Self.loginShell()
        self.environment = environment
        self.roots = roots ?? Self.fixedRoots(home: home)
        self.tailscaleCopies = tailscaleCopies ?? [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            home + "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        self.runner = runner
        self.securityPath = securityPath
        self.shellTimeout = min(5, max(0.01, shellTimeout))
        self.probeTimeout = max(0.01, probeTimeout)
        directories = Self.unique(Self.pathParts(environment["PATH"] ?? "") + self.roots)
    }

    private static func loginShell() -> String {
        guard let shell = getpwuid(getuid())?.pointee.pw_shell else { return "/bin/zsh" }
        let path = String(cString: shell)
        return path.isEmpty ? "/bin/zsh" : path
    }

    static func claudeCandidates(environment: [String: String], home: String) -> [String] {
        let override = environment["CLAUDE_BIN"].flatMap { $0.isEmpty ? nil : $0 }
        return (override.map { [$0] } ?? []) + [home + "/.local/bin/claude", home + "/.claude/local/claude",
                                                    "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    static func fixedRoots(home: String) -> [String] {
        [home + "/.local/bin", home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
         "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }
    private static func pathParts(_ text: String) -> [String] {
        text.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") && !$0.contains("\n") }
    }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    var path: String { lock.lock(); defer { lock.unlock() }; return directories.joined(separator: ":") }

    func candidates(_ name: String) -> [String] {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return [] }
        lock.lock(); let dirs = directories; lock.unlock()
        return dirs.map { $0 + "/" + name } + (name == "tailscale" ? tailscaleCopies : [])
    }
    func resolve(_ name: String) -> String? {
        lock.lock(); let cached = results[name]; lock.unlock()
        if let cached { return cached.path }
        return candidates(name).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func cachedResult(_ name: String) -> Result? {
        lock.lock(); defer { lock.unlock() }; return results[name]
    }

    /// Called by the existing app launch hook. Only schedules work; even a wedged rc file cannot hold launch.
    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { self.refresh() }
    }

    /// Worker-thread entry, also injectable for fixture tests. Failed runs are the only refresh trigger after launch.
    func failedToRun(_ name: String) {
        lock.lock()
        guard pendingFailures.insert(name).inserted else { lock.unlock(); return }
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            self.refreshAfterFailure(name)
            self.lock.lock(); self.pendingFailures.remove(name); self.lock.unlock()
        }
    }

    func refreshAfterFailure(_ name: String) {
        refresh(only: name)
    }
    private func refresh(only name: String? = nil) {
        refreshLock.lock(); defer { refreshLock.unlock() }
        let command = "printf '\\n" + Self.begin + "\\n'; /usr/bin/printenv PATH; printf '" + Self.end + "\\n'"
        var discovered: [String] = []
        if let out = runner(shell, ["-lic", command], environment, shellTimeout), out.status == 0, !out.timedOut {
            let lines = out.text.components(separatedBy: .newlines)
            if let a = lines.firstIndex(of: Self.begin), let b = lines[(a + 1)...].firstIndex(of: Self.end), b == a + 2 {
                discovered = Self.pathParts(lines[a + 1])
            }
        }
        if discovered.isEmpty, let out = runner("/bin/launchctl", ["getenv", "PATH"], environment, 2),
           out.status == 0, !out.timedOut {
            discovered = Self.pathParts(out.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        lock.lock()
        directories = Self.unique(discovered + Self.pathParts(environment["PATH"] ?? "") + roots)
        if let name { results.removeValue(forKey: name) } else { results.removeAll() }
        lock.unlock()
        for program in name.map({ [$0] }) ?? Self.programs {
            let result = inspect(program)
            lock.lock(); results[program] = result; lock.unlock()
        }
    }

    /// Probes are bounded and run off the main thread. Authentication failures need positive evidence:
    /// an unsupported status command, daemon failure, or malformed output is never called a missing login.
    func inspect(_ name: String) -> Result {
        guard let exe = resolve(name) else { return Result(path: nil, state: .notInstalled) }
        var env = environment; env["PATH"] = path
        guard let version = runner(exe, ["--version"], env, probeTimeout), version.status == 0, !version.timedOut else {
            return Result(path: exe, state: .notWorking)
        }
        var state = State.ready
        if name == "tailscale" {
            if let out = runner(exe, ["status", "--json"], env, probeTimeout), !out.timedOut, out.status == 0,
               let json = try? JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any],
               let backend = json["BackendState"] as? String {
                if backend == "NeedsLogin" { state = .notSignedIn }
            } else { state = .notWorking }
        } else if name == "claude" || name == "codex" {
            // One reader for sign-in (config-dir env, Keychain cross-check, plan/email extras): SignInProbe.
            let provider: SeatProvider = name == "claude" ? .claude : .codex
            let home = environment["HOME"] ?? NSHomeDirectory()
            let dir = URL(fileURLWithPath: home).appendingPathComponent(provider == .claude ? ".claude" : ".codex")
            let reading = SignInProbe.read(provider: provider, exe: exe, directory: dir, configDir: nil, base: env, run: runner,
                                           security: securityPath, timeout: probeTimeout)
            // An odd answer leaves the program "Ready" (installed and working); only a confirmed logout is "Not signed in".
            if reading.signIn == .notSignedIn { state = .notSignedIn }
            return Result(path: exe, state: state, signIn: reading.signIn, plan: reading.plan, email: reading.email)
        }
        // git has no login; gh has no offline status check. Both intentionally have only availability states.
        return Result(path: exe, state: state)
    }

    /// A separate process group and regular output file keep descendants and full pipes from defeating the cap.
    /// The waiter is always joined; timeout kills the whole group and reaps the child before returning.
    static func run(_ exe: String, _ args: [String], _ env: [String: String], _ timeout: TimeInterval) -> Output? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("true-program-" + UUID().uuidString)
        let fd = open(file.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd); try? FileManager.default.removeItem(at: file) }
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fd, 1)
        posix_spawn_file_actions_adddup2(&actions, fd, 2)
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, exe, &actions, &attr, argv, envp) == 0 else { return nil }
        let child = pid
        final class Exit: @unchecked Sendable { var status: Int32 = 0 }
        let exit = Exit(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while waitpid(child, &exit.status, 0) < 0 && errno == EINTR {}
            done.signal()
        }
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        // Also clean up an rc file that left a background descendant after the shell exited.
        kill(-child, SIGKILL)
        if timedOut { done.wait() }
        lseek(fd, 0, SEEK_SET)
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &bytes, bytes.count)
        let text = count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
        let status: Int32 = (exit.status & 0x7f) == 0 ? (exit.status >> 8) & 0xff : -1
        return Output(status: status, text: text, timedOut: timedOut)
    }
}
