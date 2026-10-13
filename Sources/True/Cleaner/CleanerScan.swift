import Foundation
import CryptoKit

enum ContextKind: String, Sendable {
    case global = "Global", claudeMd = "CLAUDE.md", handoff = "Handoff"
}

/// Why a row can't be selected.
enum ContextLock: Equatable, Sendable {
    /// A `HANDOFF-<tok>.md` whose owning session is running.
    case live
    /// Modified minutes ago; a session may still be writing it.
    case inUse
    var reason: String { self == .live ? "live session" : "in use" }
}

/// One context file as read at scan time. `size` + `mtime` are what Apply re-checks before writing.
struct ContextFile: Identifiable, Equatable, Sendable {
    /// Resolved real path (symlinks followed), so each file appears once.
    let path: String
    let kind: ContextKind
    /// The project root it was found under, abbreviated (`~/Projects/mizan`), or "Global".
    let project: String
    let content: String
    let size: Int
    let mtime: Date
    let sha: String
    let lock: ContextLock?
    var id: String { path }
    var tokens: Int { size / 4 }
    /// Global is opt-in; locked rows can't be selected at all.
    var defaultChecked: Bool { lock == nil && kind != .global }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Finds the context files. Pure filesystem reads — call off the main actor; nothing watches disk.
/// Every location is injected so tests run against a temp tree.
struct ContextScanner: Sendable {
    var home: String = NSHomeDirectory()
    var now: @Sendable () -> Date = { Date() }
    static let minBytes = 400
    static let inUseWindow: TimeInterval = 10 * 60

    /// `roots` are project folders; `home` itself is added by the caller when wanted.
    func scan(roots: [String]) -> [ContextFile] {
        var seen = Set<String>()
        var out: [ContextFile] = []
        func add(_ path: String, kind: ContextKind, project: String) {
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard !seen.contains(real), let f = read(real, kind: kind, project: project) else { return }
            seen.insert(real)
            out.append(f)
        }
        add(home + "/.claude/CLAUDE.md", kind: .global, project: "Global")
        for root in roots {
            let r = ProjectList.standardize(root, home: home)
            let project = ProjectList.abbreviate(r, home: home)
            add(r + "/CLAUDE.md", kind: .claudeMd, project: project)
            add(r + "/.claude/CLAUDE.md", kind: .claudeMd, project: project)
            add(r + "/HANDOFF.md", kind: .handoff, project: project)
            for dir in [r + "/.claude", r + "/studio-docs"] {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                for n in names.sorted() where n.hasPrefix("HANDOFF") && n.hasSuffix(".md") {
                    add(dir + "/" + n, kind: .handoff, project: project)
                }
            }
        }
        return out
    }

    private func read(_ path: String, kind: ContextKind, project: String) -> ContextFile? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let mtime = attrs[.modificationDate] as? Date,
              let data = FileManager.default.contents(atPath: path),
              data.count >= Self.minBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lock: ContextLock?
        if now().timeIntervalSince(mtime) < Self.inUseWindow { lock = .inUse }
        if kind == .handoff, isLiveHandoff(path) { lock = .live }
        return ContextFile(path: path, kind: kind, project: project, content: text, size: data.count,
                           mtime: mtime, sha: sha256Hex(data), lock: lock)
    }

    /// Same rule as `~/.claude/hooks/handoff-inject.sh`: `HANDOFF-<tok>.md` is live while
    /// `~/.claude/state/live-<tok>` names a pid that still exists (EPERM counts: it exists, it's not ours).
    private func isLiveHandoff(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("HANDOFF-"), name.hasSuffix(".md") else { return false }
        let tok = String(name.dropFirst("HANDOFF-".count).dropLast(".md".count))
        guard !tok.isEmpty,
              let s = try? String(contentsOfFile: home + "/.claude/state/live-" + tok, encoding: .utf8),
              let field = s.split(whereSeparator: \.isWhitespace).first, let pid = Int32(field) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
