import Foundation
import Observation

/// The Hub's Crew tab core: Claude Code sub-agent definitions (`*.md` with YAML frontmatter), parsed,
/// grouped and scanned. "Crew agent" is NOT a True seat (`Agent`, ~/.true/agents.json). Pure except
/// `CrewScanner`, which only reads directories it is handed (tests use temp dirs).

struct CrewAgent: Equatable, Sendable, Identifiable {
    var name: String
    /// Text before the first `Examples:` / `<example>` / newline, capped ~160 chars on a word boundary.
    var summary: String
    /// The whole description (literal `\n` turned into newlines), for the tooltip.
    var fullDescription: String
    /// `inherit` when the file names none.
    var model: String
    /// Frontmatter `color` (blue, red, …), lower-cased; nil when absent.
    var color: String?
    var id: String { name }
}

enum CrewParser {
    /// nil = not a crew agent file (no frontmatter / not UTF-8). Never throws, never crashes.
    static func parse(_ data: Data, filename: String) -> CrewAgent? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let close = lines[(open + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        // key: value, with indented lines continuing the previous value (YAML folded/plain scalars).
        var fields: [String: String] = [:]
        var last: String?
        for line in lines[(open + 1)..<close] {
            if let first = line.first, first == " " || first == "\t", let k = last {
                fields[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard !k.isEmpty else { continue }
                fields[k] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                last = k
            }
        }
        let base = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
        let name = unquote(fields["name"] ?? "")
        let rawDesc = unquote(fields["description"] ?? "")
        let model = unquote(fields["model"] ?? "")
        let color = unquote(fields["color"] ?? "").lowercased()
        return CrewAgent(name: name.isEmpty ? base : name, summary: summary(of: rawDesc),
                         fullDescription: rawDesc.replacingOccurrences(of: "\\n", with: "\n"),
                         model: model.isEmpty ? "inherit" : model, color: color.isEmpty ? nil : color)
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, f == "\"" || f == "'", t.last == f {
            t = String(t.dropFirst().dropLast())
            if f == "\"" { t = t.replacingOccurrences(of: "\\\"", with: "\"") }
        }
        return t
    }

    static func summary(of desc: String, limit: Int = 160) -> String {
        var s = desc
        for marker in ["Examples:", "<example>", "\\n", "\n"] {
            if let r = s.range(of: marker) { s = String(s[..<r.lowerBound]) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > limit else { return s }
        let cut = String(s.prefix(limit))
        // Word boundary: drop the partial last word unless that would leave nothing.
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > limit / 2 {
            return String(cut[..<sp]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut + "…"
    }
}

struct CrewGroup: Equatable, Sendable, Identifiable {
    var title: String
    var agents: [CrewAgent]
    var id: String { title }
}

enum CrewGrouping {
    static let projectOrder = ["Lead", "Engineering", "Design", "Security", "Knowledge", "Other"]

    /// `true-swift-engineer` → `swift-engineer`: strip the first segment when it is the repo's name or
    /// shared by at least two of the project's agents (so a bare `cto` is left alone).
    static func stripped(_ name: String, repo: String, prefixes: [String: Int]) -> String {
        guard let dash = name.firstIndex(of: "-") else { return name }
        let p = String(name[..<dash]).lowercased()
        guard p == repo.lowercased() || (prefixes[p] ?? 0) >= 2 else { return name }
        return String(name[name.index(after: dash)...])
    }

    static func family(of s: String) -> String {
        let n = s.lowercased()
        if ["cto", "ceo", "coo", "cfo", "cmo"].contains(n) || n.contains("lead") { return "Lead" }
        if n.contains("security") { return "Security" }
        if n.contains("designer") { return "Design" }
        if n.contains("knowledge") || n.contains("writer") || n.contains("keeper") { return "Knowledge" }
        if n == "engineer" || n.hasSuffix("-engineer") || n.contains("architect") { return "Engineering" }
        return "Other"
    }

    static func project(_ agents: [CrewAgent], repo: String) -> [CrewGroup] {
        var prefixes: [String: Int] = [:]
        for a in agents { if let d = a.name.firstIndex(of: "-") { prefixes[String(a.name[..<d]).lowercased(), default: 0] += 1 } }
        var buckets: [String: [CrewAgent]] = [:]
        for a in agents { buckets[family(of: stripped(a.name, repo: repo, prefixes: prefixes)), default: []].append(a) }
        return projectOrder.compactMap { t in
            buckets[t].map { CrewGroup(title: t, agents: sorted($0)) }
        }
    }

    /// Prefix before the first `-` becomes a team when ≥ `threshold` agents share it; the rest are General (first).
    static func global(_ agents: [CrewAgent], excluding taken: Set<String> = [], threshold: Int = 3) -> [CrewGroup] {
        let pool = agents.filter { !taken.contains($0.name) }
        func prefix(_ a: CrewAgent) -> String? { a.name.firstIndex(of: "-").map { String(a.name[..<$0]).lowercased() } }
        var counts: [String: Int] = [:]
        for a in pool { if let p = prefix(a) { counts[p, default: 0] += 1 } }
        var general: [CrewAgent] = []
        var teams: [String: [CrewAgent]] = [:]
        for a in pool {
            if let p = prefix(a), counts[p, default: 0] >= threshold { teams[p, default: []].append(a) } else { general.append(a) }
        }
        var out: [CrewGroup] = general.isEmpty ? [] : [CrewGroup(title: "General", agents: sorted(general))]
        out += teams.keys.sorted().map { CrewGroup(title: $0.prefix(1).uppercased() + $0.dropFirst(), agents: sorted(teams[$0] ?? [])) }
        return out
    }

    private static func sorted(_ a: [CrewAgent]) -> [CrewAgent] {
        a.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum CrewStarter {
    /// Typed, never submitted: the trailing space is the point.
    static func text(for agent: CrewAgent) -> String { "Use the \(agent.name) agent to " }
}

struct CrewSnapshot: Equatable, Sendable {
    /// Repo folder name; nil when the cwd is in no repo.
    var projectTitle: String?
    var project: [CrewGroup]
    var global: [CrewGroup]
    var isEmpty: Bool { project.isEmpty && global.isEmpty }
    var header: String { projectTitle.map { "Crew for \($0)" } ?? "Crew" }
}

enum CrewScanner {
    static let globalDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/agents")

    /// `*.md` files directly in `dir` (directories and other extensions skipped); unparseable ones dropped.
    static func agents(in dir: URL) -> [CrewAgent] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.compactMap { n in
            var isDir: ObjCBool = false
            let url = dir.appendingPathComponent(n)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  let data = try? Data(contentsOf: url) else { return nil }
            return CrewParser.parse(data, filename: n)
        }
    }

    static func load(cwd: String, globalDir: URL = globalDir,
                     hasGit: (String) -> Bool = { FileManager.default.fileExists(atPath: $0 + "/.git") }) -> CrewSnapshot {
        // Reuses the Hub's project key; a cwd with no .git anywhere above it has no project crew.
        let key = HubProject.key(forCwd: cwd, hasGit: hasGit)
        let repo = hasGit(key) ? key : nil
        let projectAgents = repo.map { agents(in: URL(fileURLWithPath: $0).appendingPathComponent(".claude/agents")) } ?? []
        let title = repo.map { ($0 as NSString).lastPathComponent }
        return CrewSnapshot(projectTitle: title,
                            project: CrewGrouping.project(projectAgents, repo: title ?? ""),
                            global: CrewGrouping.global(agents(in: globalDir), excluding: Set(projectAgents.map(\.name))))
    }
}

/// Last scan, kept across tab switches so the Crew tab never flickers empty. No watchers or timers:
/// `refresh` runs only when the Crew tab is visible and the focused project changes (driven by a
/// view `.task(id:)`, which cancels itself when the view goes away).
@MainActor
@Observable
final class CrewStore {
    static let shared = CrewStore()
    private(set) var snapshot: CrewSnapshot?

    func refresh(cwd: String) async {
        let s = await Task.detached(priority: .utility) { CrewScanner.load(cwd: cwd) }.value
        if s != snapshot { snapshot = s }
    }
}
