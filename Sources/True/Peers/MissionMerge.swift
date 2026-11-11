import Foundation
import Darwin

/// Owner-side Git transport. All refs are explicit; the owner's checkout and local branches are untouched.
final class MissionGitMergeGate: MissionMergeGate {
    let folder: URL
    private let resolve: (String) -> String?
    private let checkTimeout: TimeInterval
    private let mutex = NSRecursiveLock()
    private struct Consent: Codable {
        var approved: Set<String> = []
        var pending: [String: String] = [:]
    }
    init(folder: URL, resolveClone: @escaping (String) -> String?, checkTimeout: TimeInterval = 20 * 60) {
        self.folder = folder; resolve = resolveClone; self.checkTimeout = checkTimeout
    }
    private var consentURL: URL { folder.appendingPathComponent("merge-consent.json") }
    private func consent() throws -> Consent {
        if !FileManager.default.fileExists(atPath: consentURL.path) { return Consent() }
        return try JSONDecoder().decode(Consent.self, from: Data(contentsOf: consentURL))
    }
    func approve(job: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        var value = try consent()
        guard let peer = value.pending[job] else { throw PeerError.invalid("No merge waiting for approval") }
        value.approved.insert(peer); value.pending.removeValue(forKey: job)
        try JSONEncoder().encode(value).write(to: consentURL, options: .atomic)
    }
    private func ownerFile() throws -> MissionFile {
        let text = try String(contentsOf: folder.appendingPathComponent("mission.md"), encoding: .utf8)
        // Destinations were validated by the runner; recover their labels without trusting job-supplied metadata.
        let labels = text.components(separatedBy: "\n").compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("where:") ? String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) : nil
        }
        return try MissionFile.parse(text, peers: labels)
    }
    private func git(_ args: [String], _ repo: String) -> (Int32, String) {
        PeerLauncherLive.git(["-c", "core.hooksPath=/dev/null"] + args, in: repo)
    }
    private func withRepo<T>(_ repo: String, _ body: (String) throws -> T) throws -> T {
        guard let clone = resolve(repo) else { throw PeerError.invalid("can't merge: no shared remote") }
        let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], clone)
        guard common.0 == 0 else { throw PeerError.invalid("can't merge: no shared remote") }
        let fd = open(common.1 + "/true-mission.lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw PeerError.invalid("Couldn't lock the repo") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw PeerError.invalid("Couldn't lock the repo") }
        return try body(clone)
    }
    private func validBase(_ base: String, repo: String) -> Bool {
        base != "main" && base != "master" && git(["check-ref-format", "refs/heads/" + base], repo).0 == 0
    }
    /// Publish the initial mission base before any launcher needs origin/<mission branch>.
    func prepare(_ mission: MissionFile, id: String) throws {
        for repo in Set(mission.jobs.filter { !$0.isHuman }.map(\.repo)) {
            try withRepo(repo) { clone in
                let base = mission.into ?? "mission/\(id)"
                guard validBase(base, repo: clone) else { throw PeerError.invalid("Choose a mission branch away from main") }
                guard git(["fetch", "origin"], clone).0 == 0 else { throw PeerError.invalid("can't merge: no shared remote") }
                if git(["ls-remote", "--exit-code", "--heads", "origin", "refs/heads/" + base], clone).0 == 0 { return }
                let head = git(["ls-remote", "--symref", "origin", "HEAD"], clone)
                let source = head.1.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") })?
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first.map(String.init)
                guard let source else { throw PeerError.invalid("can't merge: no shared remote") }
                let startingRef = "refs/remotes/origin/" + source.dropFirst("refs/heads/".count)
                guard git(["push", "origin", startingRef + ":refs/heads/" + base], clone).0 == 0,
                      git(["fetch", "origin"], clone).0 == 0 else { throw PeerError.invalid("can't merge: no shared remote") }
            }
        }
    }
    func merge(_ launch: MissionLaunch, at destination: MissionDestination, check: String?) throws -> MissionMergeAnswer {
        mutex.lock(); defer { mutex.unlock() }
        let mission = try ownerFile()
        guard let check = mission.check, !check.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .inputRequired("the user, add check: to the mission")
        }
        let base = mission.into ?? "mission/\(folder.lastPathComponent)"
        do {
            return try withRepo(launch.job.repo) { clone in
                guard validBase(base, repo: clone), launch.base == base,
                      launch.branch.hasPrefix("peer/\(folder.lastPathComponent)/"),
                      git(["check-ref-format", "refs/heads/" + launch.branch], clone).0 == 0 else {
                    return .inputRequired("Choose a mission branch away from main")
                }
                // Fetch exact heads, avoiding stale remote-tracking refs and ambiguous branch/tag names.
                let jobRef = "refs/true-missions/\(folder.lastPathComponent)/job"
                let baseRef = "refs/true-missions/\(folder.lastPathComponent)/base"
                guard git(["fetch", "--no-tags", "origin", "+refs/heads/\(launch.branch):\(jobRef)", "+refs/heads/\(base):\(baseRef)"], clone).0 == 0 else {
                    return .inputRequired("can't merge: no shared remote")
                }
                let sha = git(["rev-parse", jobRef], clone).1
                if git(["merge-base", "--is-ancestor", sha, baseRef], clone).0 == 0 { return .merged }
                if case .peer(let peer) = destination {
                    var value = try consent()
                    if !value.approved.contains(peer) {
                        value.pending[launch.job.title] = peer
                        try JSONEncoder().encode(value).write(to: consentURL, options: .atomic)
                        let stat = git(["diff", "--numstat", baseRef + "..." + sha], clone)
                        guard stat.0 == 0 else { return .inputRequired("Couldn't read the diff") }
                        let rows = stat.1.split(separator: "\n").map { $0.split(separator: "\t") }
                        let added = rows.reduce(0) { $0 + (Int($1.first ?? "") ?? 0) }
                        let removed = rows.reduce(0) { $0 + ($1.count > 1 ? Int($1[1]) ?? 0 : 0) }
                        return .inputRequired("First merge from \(peer): \(rows.count) files, +\(added) -\(removed). Merge?")
                    }
                }
                let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("true-mission-" + UUID().uuidString)
                guard git(["worktree", "add", "--detach", worktree.path, baseRef], clone).0 == 0 else { return .inputRequired("Couldn't make a merge worktree") }
                defer { _ = git(["worktree", "remove", "--force", worktree.path], clone) }
                let merged = git(["-c", "user.name=True", "-c", "user.email=true@localhost", "merge", "--no-edit", "--no-ff", sha], worktree.path)
                guard merged.0 == 0 else {
                    let short = git(["rev-parse", "--short", baseRef], clone).1
                    return .fix("rebase on \(short)")
                }
                let home = FileManager.default.temporaryDirectory.appendingPathComponent("true-check-home-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: home) }
                let env = ["PATH": ProgramFinder.shared.path, "HOME": home.path,
                           "LANG": "en_US.UTF-8", "TMPDIR": FileManager.default.temporaryDirectory.path]
                let outcome = Self.runCheck("/bin/sh", ["-c", "cd \"$1\" && " + check, "mission-check", worktree.path],
                                             env: env, timeout: checkTimeout)
                if outcome.timedOut {
                    return .inputRequired("check timed out after \(Self.timeoutText(checkTimeout))")
                }
                guard outcome.status == 0 else {
                    let output = outcome.output
                    let tail = output.split(separator: "\n").suffix(8).joined(separator: "\n")
                    return .fix(PeerMask.text(tail.isEmpty ? "Check failed" : tail))
                }
                guard git(["push", "origin", "HEAD:refs/heads/" + base], worktree.path).0 == 0 else {
                    return .inputRequired("can't merge: no shared remote")
                }
                return .merged
            }
        } catch PeerError.invalid(let reason) { return .inputRequired(reason) }
    }

    private static func timeoutText(_ timeout: TimeInterval) -> String {
        let minutes = Int((timeout / 60).rounded())
        return minutes >= 1 ? "\(minutes) min" : "\(Int(timeout))s"
    }

    /// Runs the check command in its own process group and kills the whole group on timeout (TERM, then KILL after a
    /// short grace). Subprocess's timeout only signals `/bin/sh`; grandchildren keep the output pipe open forever, so
    /// the group must die for the call to return and for the per-repo lock and worktree to be released.
    private static func runCheck(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval)
        -> (status: Int32, output: String, timedOut: Bool) {
        let pipe = Pipe()
        let write = pipe.fileHandleForWriting
        let read = pipe.fileHandleForReading

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return (-1, "", false) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            posix_spawnattr_destroy(&attr); return (-1, "", false)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, write.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, write.fileDescriptor, 2)

        let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        defer { for p in argv { free(p) } }
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in envp { free(p) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, exe, &actions, &attr, argv, envp) == 0
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        try? write.close()
        guard spawned else { try? read.close(); return (-1, "", false) }

        let box = CheckOutputBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = read.readDataToEndOfFile()
            try? read.close()
            done.signal()
        }

        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            _ = Darwin.kill(-pid, SIGTERM)
            Thread.sleep(forTimeInterval: 1)
            if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(-pid, SIGKILL) }
            done.wait()
        }
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 1
        return (code, String(decoding: box.data, as: UTF8.self), timedOut)
    }
}

/// Mutable capture for the check reader thread; the semaphore orders the write before the caller reads it back.
private final class CheckOutputBox: @unchecked Sendable {
    var data = Data()
}
