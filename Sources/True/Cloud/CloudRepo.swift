import Foundation

/// Runs a helper tool; `(status, output incl. stderr)`. A seam so the sync and land plans test without a network or a repo.
typealias CloudRun = @Sendable (_ exe: String, _ args: [String]) -> (status: Int32, out: String)

let cloudRunLive: CloudRun = { exe, args in
    guard let r = Subprocess.exec(exe, args, timeout: nil, mergeStderr: true) else { return (-1, "can't launch \(exe)") }
    return (r.status, String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

struct CloudRepoError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// Mac -> VPS repo sync. The factory spec leaves syncing out of scope, so True does it over the same ssh door the
/// VPS is administered through (key `~/.ssh/hermes_vps`, Tailscale only):
///   1. `git bundle create` of the local HEAD (a file, no remote needed, nothing pushed anywhere shared),
///   2. `scp` it to /tmp on streambox,
///   3. `ssh` as root runs git AS the service user (`runuser -u truefactory`) so the clone stays owned by it:
///      init the repo under FACTORY_REPOS if missing, then fetch the bundle into the private ref `refs/true/sync`.
/// The job is then created with `base` = the synced commit sha, so the VPS clone's checked-out branch is never touched.
/// Committed work only: uncommitted changes are not in a bundle (the UI says so).
struct CloudSync: Sendable {
    var host = "root@100.120.234.70"
    var key = NSHomeDirectory() + "/.ssh/hermes_vps"
    var reposDir = "/var/lib/true-factory/repos"
    var serviceUser = "truefactory"
    var run: CloudRun = cloudRunLive

    struct Result: Equatable { var repoName: String; var sha: String; var dirty: Bool }

    /// The VPS directory name for a local folder: must match the factory's `[A-Za-z0-9][A-Za-z0-9._-]*`.
    static func repoName(forPath path: String) -> String {
        let raw = URL(fileURLWithPath: path).lastPathComponent
        var s = String(raw.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || "._-".contains($0) ? $0 : "-" })
        while let f = s.first, !(f.isLetter || f.isNumber) { s.removeFirst() }
        return s.isEmpty ? "repo" : s
    }

    private var sshOpts: [String] { ["-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "IdentitiesOnly=yes"] }

    static func remoteScript(repoPath: String, bundle: String, user: String) -> String {
        // Both paths come in as positional args ($0/$1) of the inner sh, so nothing user-controlled is spliced into code.
        "set -e; chmod 644 \(shq(bundle)); " +
        "runuser -u \(shq(user)) -- sh -c 'set -e; [ -d \"$0/.git\" ] || git init -q \"$0\"; git -C \"$0\" fetch -q \"$1\" +HEAD:refs/true/sync' \(shq(repoPath)) \(shq(bundle)); " +
        "rm -f \(shq(bundle))"
    }

    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func sync(localRepo: String, progress: @Sendable (CloudSendStep) -> Void = { _ in }) throws -> Result {
        progress(.packing)
        let git = "/usr/bin/git"
        let head = run(git, ["-C", localRepo, "rev-parse", "--verify", "HEAD"])
        guard head.status == 0, head.out.count >= 40 else { throw CloudRepoError(message: "\(localRepo) is not a git repo with a commit") }
        let sha = String(head.out.prefix(40))
        let dirty = !run(git, ["-C", localRepo, "status", "--porcelain"]).out.isEmpty
        let name = Self.repoName(forPath: localRepo)
        let local = NSTemporaryDirectory() + "true-cloud-\(sha.prefix(12)).bundle"
        let remote = "/tmp/true-cloud-\(sha.prefix(12)).bundle"
        defer { try? FileManager.default.removeItem(atPath: local) }
        let b = run(git, ["-C", localRepo, "bundle", "create", "-q", local, "HEAD"])
        guard b.status == 0 else { throw CloudRepoError(message: "Couldn't bundle the repo: \(b.out)") }
        progress(.uploading)
        let cp = run("/usr/bin/scp", sshOpts + ["-q", local, "\(host):\(remote)"])
        guard cp.status == 0 else { throw CloudRepoError(message: "Couldn't copy the repo to the cloud: \(cp.out)") }
        let script = Self.remoteScript(repoPath: "\(reposDir)/\(name)", bundle: remote, user: serviceUser)
        let ssh = run("/usr/bin/ssh", sshOpts + [host, script])
        guard ssh.status == 0 else { throw CloudRepoError(message: "Cloud repo update failed: \(ssh.out)") }
        return Result(repoName: name, sha: sha, dirty: dirty)
    }
}

/// "Land": apply a job's diff to the local repo WITHOUT touching the checked-out branch. A sibling worktree
/// `<repo>-cloud-<jobid>` on a new branch `cloud/<jobid>` (from the commit the job started at, else HEAD) gets the
/// patch and one commit. main is never written to and nothing is pushed.
struct CloudLand: Sendable {
    var run: CloudRun = cloudRunLive

    struct Result: Equatable { var branch: String; var path: String }

    static func branch(forJob id: String) -> String { "cloud/" + id }
    static func worktreePath(repo: String, jobID: String) -> String {
        let url = URL(fileURLWithPath: repo)
        return url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-cloud-\(jobID)").path
    }

    func land(localRepo: String, jobID: String, title: String, baseSha: String?, diff: String) throws -> Result {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudRepoError(message: "This job changed nothing, so there's nothing to land") }
        let git = "/usr/bin/git"
        let branch = Self.branch(forJob: jobID), path = Self.worktreePath(repo: localRepo, jobID: jobID)
        guard !FileManager.default.fileExists(atPath: path) else { throw CloudRepoError(message: "Already landed: \(path)") }
        var start = "HEAD"
        if let baseSha, run(git, ["-C", localRepo, "cat-file", "-e", baseSha + "^{commit}"]).status == 0 { start = baseSha }
        let add = run(git, ["-C", localRepo, "worktree", "add", "-q", "-b", branch, path, start])
        guard add.status == 0 else { throw CloudRepoError(message: "Couldn't create branch \(branch): \(add.out)") }
        func undo() {
            _ = run(git, ["-C", localRepo, "worktree", "remove", "--force", path])
            _ = run(git, ["-C", localRepo, "branch", "-D", branch])
        }
        let patch = NSTemporaryDirectory() + "true-cloud-\(jobID).patch"
        defer { try? FileManager.default.removeItem(atPath: patch) }
        do { try (diff.hasSuffix("\n") ? diff : diff + "\n").write(toFile: patch, atomically: true, encoding: .utf8) }
        catch { undo(); throw CloudRepoError(message: "Couldn't write the patch") }
        let apply = run(git, ["-C", path, "apply", "--index", "--whitespace=nowarn", patch])
        guard apply.status == 0 else { undo(); throw CloudRepoError(message: "The diff doesn't apply cleanly: \(apply.out)") }
        let commit = run(git, ["-C", path, "commit", "-q", "-m", "Cloud job \(jobID): \(title)"])
        guard commit.status == 0 else { undo(); throw CloudRepoError(message: "Couldn't commit: \(commit.out)") }
        return Result(branch: branch, path: path)
    }
}
