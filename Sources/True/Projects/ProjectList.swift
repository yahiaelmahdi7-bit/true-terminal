import Foundation

/// One folder the palette can open.
struct Project: Equatable, Sendable, Identifiable {
    let name: String
    /// Standardized absolute path.
    let path: String
    /// The parent folder as shown (`~/Projects`).
    let parent: String
    var id: String { path }
}

/// Turns a `ProjectConfig` into the list of projects that exist right now. Pure filesystem reads —
/// call it off the main actor; nothing watches disk.
enum ProjectList {
    static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    static func standardize(_ path: String, home: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: expand(path, home: home)).standardizedFileURL.path
    }

    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func isExcluded(_ name: String, globs: [String]) -> Bool {
        globs.contains { fnmatch($0, name, 0) == 0 }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func build(_ config: ProjectConfig, home: String = NSHomeDirectory()) -> [Project] {
        var seen = Set<String>()
        var out: [Project] = []
        func add(_ path: String) {
            let p = standardize(path, home: home)
            let name = (p as NSString).lastPathComponent
            guard !name.isEmpty, !name.hasPrefix("."), !isExcluded(name, globs: config.exclude),
                  isDirectory(p), seen.insert(p).inserted else { return }
            let parent = abbreviate((p as NSString).deletingLastPathComponent, home: home)
            out.append(Project(name: name, path: p, parent: parent))
        }
        for root in config.roots {
            let r = standardize(root, home: home)
            let kids = (try? FileManager.default.contentsOfDirectory(atPath: r)) ?? []
            for k in kids.sorted() { add(r + "/" + k) }
        }
        for p in config.pinned { add(p) }
        return out
    }

    // MARK: Repo facts (plain file reads, no git process)

    /// The checked-out branch from `.git/HEAD` (short sha when detached). Handles a worktree/submodule
    /// `.git` file (`gitdir: …`). nil when the folder is not a repo.
    static func branch(of path: String) -> String? {
        var gitDir = path + "/.git"
        if !isDirectory(gitDir) {
            guard let s = try? String(contentsOfFile: gitDir, encoding: .utf8),
                  s.hasPrefix("gitdir:") else { return nil }
            let target = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/") ? target : path + "/" + target
        }
        guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        return line.isEmpty ? nil : String(line.prefix(7))
    }

    /// Unfinished work waiting: `<repo>/.claude/HANDOFF*.md` exists.
    static func hasHandoff(at path: String) -> Bool {
        let dir = path + "/.claude"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        return files.contains { $0.hasPrefix("HANDOFF") && $0.hasSuffix(".md") }
    }
}
