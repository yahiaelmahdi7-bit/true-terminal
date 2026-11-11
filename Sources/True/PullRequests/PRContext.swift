import Foundation

/// Plain-words text shared by every PR path. Nothing here is a raw code or id.
enum PRCopy {
    static let signedOut = "Not signed in to GitHub."
    static let ghMissing = "GitHub CLI missing. Install it, then try again."
    static let network = "Could not reach GitHub."
    static let updateGH = "Update the GitHub CLI."
    static let held = "Held by the user. Release it to merge."
    static let releaseRefused = "Held. Only the user can release, in True."
    static let notLoaded = "Could not load this PR."
    static let changedWhileMerging = "The PR changed while merging. Nothing was merged."

    /// A failed `gh` call: network trouble reads as the network text, anything else as `other`.
    static func ghFailure(_ run: PRRun, other: String) -> String {
        if run.missing { return ghMissing }
        let text = (run.err + run.out).lowercased()
        if run.timedOut || ["error connecting", "dial tcp", "no such host", "timed out", "network is unreachable"].contains(where: text.contains) {
            return network
        }
        return other
    }
}

/// Everything a PR operation touches, injectable: the runner, the repo folder, the gate files, the Hold
/// list and the scratch folders. Tests point all of it at temp dirs and a fake runner.
struct PRContext: Sendable {
    var runner: PRRunner = .live
    var repoDir: String
    /// `owner/name`; keys the Hold list.
    var repo: String
    var gates = GateReader()
    var held: @Sendable (Int) -> HoldEntry?
    var prDir = NSHomeDirectory() + "/.true/pr"
    var gateWorktrees = NSHomeDirectory() + "/.true/pr-gate"
    var gateLock = PRGateLock.shared

    init(repoDir: String, repo: String, holds: PRHoldStore = PRHoldStore()) {
        self.repoDir = repoDir
        self.repo = repo
        self.held = { [repo] n in holds.entry(repo: repo, number: n) }
    }

    func gh(_ args: [String], timeout: TimeInterval = 15, maxBytes: Int? = nil) async -> PRRun {
        await runner.run(PRCommand(tool: .gh, args: args, cwd: repoDir, timeout: timeout, maxBytes: maxBytes))
    }

    func git(_ args: [String], in dir: String? = nil, timeout: TimeInterval = 15) async -> PRRun {
        await runner.run(PRCommand(tool: .git, args: args, cwd: dir ?? repoDir, timeout: timeout))
    }
}

/// `owner/name` from an origin URL (https or ssh form).
func prRepoSlug(fromRemote url: String) -> String? {
    var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasSuffix(".git") { s.removeLast(4) }
    let tail: Substring
    if let r = s.range(of: "github.com:") { tail = s[r.upperBound...] }
    else if let r = s.range(of: "github.com/") { tail = s[r.upperBound...] }
    else { return nil }
    let parts = tail.split(separator: "/").map(String.init)
    return parts.count == 2 ? parts.joined(separator: "/") : nil
}

/// One gate at a time (a click, `truectl pr gate`, or the post-merge main run).
actor PRGateLock {
    static let shared = PRGateLock()
    private var busy = false
    func tryTake() -> Bool { if busy { return false }; busy = true; return true }
    func release() { busy = false }
}
