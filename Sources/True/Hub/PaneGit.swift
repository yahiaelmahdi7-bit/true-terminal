import AppKit
import Foundation

/// Strings for the pane panel and task screen chrome (added beside `TaskDetailCopy`, same enum).
extension TaskDetailCopy {
    static let panelChanges = "Changes", panelCommit = "Commit", commitAll = "Commit all changes", cancel = "Cancel"
    static let messageHint = "What changed?", nothingToCommit = "Nothing to commit", commitFailed = "Couldn't commit"
    static let writeMessage = "Write a message first", done = "Done", showInFinder = "Show folder in Finder"
    static let currentBranch = "Current branch", thisMac = "This Mac", ownerLabel = "Owner", providerLabel = "Provider"
    static let branchLabel = "Branch", commitsLabel = "Commits", loading = "Loading…", nextLabel = "Next"
    static let showMore = "Show more", noReport = "No report yet", noDiff = "No preview for this file"
    static func openIn(_ editor: String) -> String { "Open in \(editor)" }
    static func committed(_ count: Int) -> String { "Committed \(files(count))" }
    static func sized(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

/// What the pill and panel show for one folder.
struct PaneGitStatus: Equatable, Sendable {
    var isRepo = false
    var branch = ""
    var added = 0
    var removed = 0
    var files = 0
    /// No counts when both are zero: a clean repo shows no "+0 −0".
    var showsCounts: Bool { added > 0 || removed > 0 }
    static let notGit = PaneGitStatus()
}

/// Read-only git for the pane panel. Call from a utility task, never from `body`.
enum PaneGitReader {
    static let maxUntracked = 2_000
    static func read(folder: String) -> PaneGitStatus {
        let git = TaskGit(folder: folder, deadline: Date().addingTimeInterval(5))
        guard git.value(["rev-parse", "--is-inside-work-tree"]) == "true" else { return .notGit }
        var branch = git.value(["branch", "--show-current"]) ?? ""
        if branch.isEmpty { branch = git.value(["rev-parse", "--short", "HEAD"]) ?? "" }
        var added = 0, removed = 0, files = 0
        let tracked = git.run(["diff", "--no-ext-diff", "--no-textconv", "--numstat", "HEAD", "--"])
        if tracked.code == 0 {
            for line in tracked.text.split(separator: "\n") {
                let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard f.count == 3 else { continue }
                files += 1
                added += Int(f[0]) ?? 0; removed += Int(f[1]) ?? 0   // "-" (binary) counts 0
            }
        }
        let root = git.value(["rev-parse", "--show-toplevel"]) ?? folder
        for path in git.names(["ls-files", "--others", "--exclude-standard", "-z"]).prefix(maxUntracked) {
            files += 1
            added += lines(in: URL(fileURLWithPath: root).appendingPathComponent(path))
        }
        return PaneGitStatus(isRepo: true, branch: branch, added: added, removed: removed, files: files)
    }

    /// Line count; binary files and files over 1 MB count 0.
    static func lines(in url: URL) -> Int {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return 0 }
        if data.prefix(8192).contains(0) { return 0 }
        return data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (data.last != nil && data.last != 10 ? 1 : 0)
    }
}

/// Commits everything in a folder. Never pushes; never touches a remote. Returns one plain line.
enum PaneCommit {
    static func commit(folder: String, message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return TaskDetailCopy.writeMessage }
        let git = TaskGit(folder: folder, deadline: Date().addingTimeInterval(60))
        guard git.value(["rev-parse", "--is-inside-work-tree"]) == "true" else { return TaskDetailCopy.notGit }
        let status = git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        guard status.code == 0 else { return TaskDetailCopy.commitFailed }
        let count = status.text.split(separator: "\0").count
        guard count > 0 else { return TaskDetailCopy.nothingToCommit }
        guard git.run(["add", "-A"]).code == 0, git.run(["commit", "-m", text]).code == 0 else { return TaskDetailCopy.commitFailed }
        return TaskDetailCopy.committed(count)
    }
}

struct PaneEditor: Equatable, Sendable, Identifiable {
    var id: String          // bundle id
    var name: String
    var url: URL
    static let known: [(id: String, name: String)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"), ("com.microsoft.VSCode", "VS Code"),
        ("dev.zed.Zed", "Zed"), ("com.apple.dt.Xcode", "Xcode")]
    static func installed(find: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> [PaneEditor] {
        known.compactMap { k in find(k.id).map { PaneEditor(id: k.id, name: k.name, url: $0) } }
    }
    static let lastKey = "true.panel.lastEditor"
    static func preferred(in list: [PaneEditor], last: String?) -> PaneEditor? { list.first { $0.id == last } ?? list.first }
    func open(folder: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
