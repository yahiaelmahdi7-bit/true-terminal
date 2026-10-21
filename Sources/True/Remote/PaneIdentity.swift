import Foundation

/// Which repo, branch and Claude session a pane is on, for the phone's Panes list. Everything is read
/// from files and the kernel (no `git` subprocess): `tabsJSON` runs on the main actor on every poll.
struct PaneIdentity: Equatable, Sendable {
    var cwd = ""
    var repo: String?
    var branch: String?
    var worktree = false
    var sessionID: String?
    var token = ""
    var topic: String?
}

extension PaneIdentity {
    // MARK: Pure parsing (paths / Data in, values out; unit-tested with temp dirs)

    struct GitInfo: Equatable, Sendable {
        var repo: String
        var branch: String
        var worktree: Bool
        /// The HEAD file whose mtime moves when the branch changes (cache key).
        var headPath: String
    }

    /// Walks up from `cwd` to the nearest `.git` (directory, or the file a worktree/submodule leaves).
    /// A worktree reports its MAIN repo's name.
    nonisolated static func gitInfo(cwd: String) -> GitInfo? {
        guard !cwd.isEmpty else { return nil }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<40 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return head(of: dotGit, repo: dir.lastPathComponent, worktree: false)
                }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
                else { return nil }
                let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitdir = URL(fileURLWithPath: raw, relativeTo: dir).standardizedFileURL
                // <main>/.git/worktrees/<name>
                if gitdir.deletingLastPathComponent().lastPathComponent == "worktrees" {
                    let main = gitdir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    return head(of: gitdir, repo: main.lastPathComponent, worktree: true)
                }
                return head(of: gitdir, repo: dir.lastPathComponent, worktree: false)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private nonisolated static func head(of gitdir: URL, repo: String, worktree: Bool) -> GitInfo? {
        let headURL = gitdir.appendingPathComponent("HEAD")
        guard let text = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        return GitInfo(repo: repo, branch: branch(fromHead: text), worktree: worktree, headPath: headURL.path)
    }

    /// `ref: refs/heads/feat/x` → `feat/x`; a detached sha → its first 7 characters.
    nonisolated static func branch(fromHead text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("ref:") {
            let ref = t.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        return String(t.prefix(7))
    }

    /// The first `# ` heading of a handoff file.
    nonisolated static func handoffTopic(_ data: Data) -> String? {
        guard let text = String(data: data.prefix(16_384), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("# ") {
            let t = collapse(String(line.dropFirst(2)))
            if !t.isEmpty { return String(t.prefix(120)) }
        }
        return nil
    }

    /// Where Claude keeps a cwd's transcripts: every non-alphanumeric becomes `-`.
    nonisolated static func transcriptSlug(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    /// The opening prompt from the head of a transcript (first `user` line with text), ≤ 120 chars.
    nonisolated static func transcriptPrompt(_ head: Data) -> String? {
        for raw in head.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
                  obj["type"] as? String == "user", obj["isMeta"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            var text: String?
            if let s = message["content"] as? String { text = s }
            else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
            }
            guard let text else { continue }
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let t = collapse(first)
            if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("Caveat:") { continue }
            return t.count > 120 ? String(t.prefix(119)) + "…" : t
        }
        return nil
    }

    private nonisolated static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private nonisolated static func readHead(_ path: String, bytes: Int = 65_536) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        return try? h.read(upToCount: bytes)
    }

    private nonisolated static func mtime(_ path: String) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
    }

    /// The identity keys of an `/api/tabs` pane row; absent values are omitted.
    func addKeys(to row: inout [String: Any]) {
        if let repo { row["repo"] = repo }
        if let branch { row["branch"] = branch }
        row["worktree"] = worktree
        if let sessionID { row["sessionID"] = sessionID }
        if let topic { row["topic"] = topic }
    }

    // MARK: Resolution (main actor: asks the live terminal registry)

    private struct Key: Equatable {
        var cwd: String; var head: Double; var handoff: Double; var session: String?
    }
    @MainActor private static var cache: [UUID: (key: Key, value: PaneIdentity)] = [:]

    @MainActor
    static func resolve(pane: UUID, recordedCwd: String) -> PaneIdentity {
        let cwd = TerminalRegistry.shared.cwd(of: pane) ?? recordedCwd
        let found = SessionSnapshot.probe(pane).found
        return build(pane: pane, cwd: cwd, sessionID: found?.sessionID, claudeCwd: found?.cwd,
                     claudeDir: AgentLaunch.claudeConfigDir)
    }

    /// Split from `resolve` so tests can drive it without a terminal.
    @MainActor
    static func build(pane: UUID, cwd: String, sessionID: String?, claudeCwd: String?, claudeDir: URL) -> PaneIdentity {
        let token = EmbeddedTerminal.burnToken(pane)
        let git = gitInfo(cwd: cwd)
        let handoffPaths = [cwd, claudeCwd].compactMap { $0 }.filter { !$0.isEmpty }
            .map { $0 + "/.claude/HANDOFF-\(token).md" }
        let handoff = handoffPaths.first { FileManager.default.fileExists(atPath: $0) }
        let key = Key(cwd: cwd, head: git.map { mtime($0.headPath) } ?? 0,
                      handoff: handoff.map(mtime) ?? 0, session: sessionID)
        if let hit = cache[pane], hit.key == key { return hit.value }

        var topic: String?
        if let handoff, let d = readHead(handoff, bytes: 16_384) { topic = handoffTopic(d) }
        if topic == nil, let sessionID {
            let slugCwd = claudeCwd ?? cwd
            let path = claudeDir.appendingPathComponent("projects/\(transcriptSlug(slugCwd))/\(sessionID).jsonl").path
            if let d = readHead(path) { topic = transcriptPrompt(d) }
        }
        let id = PaneIdentity(cwd: cwd, repo: git?.repo, branch: git?.branch, worktree: git?.worktree ?? false,
                              sessionID: sessionID, token: token, topic: topic)
        cache[pane] = (key, id)
        return id
    }

    /// Forget panes that are gone.
    @MainActor static func prune(keeping live: Set<UUID>) { cache = cache.filter { live.contains($0.key) } }
}
