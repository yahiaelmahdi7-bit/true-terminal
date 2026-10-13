import Foundation

/// One remembered open: when, and which folder.
struct RecentProject: Codable, Equatable, Sendable {
    var path: String
    var openedAt: Date
}

/// `~/.true/projects.json`: where the Open Project palette looks. Paths are stored with `~` and
/// expanded on read. Decoding is tolerant — a hand-edited file missing a field (or `version`) still loads.
struct ProjectConfig: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let recentCap = 50

    var version: Int
    /// Every direct sub-directory of these is a project.
    var roots: [String]
    /// Single folders that are projects on their own.
    var pinned: [String]
    /// Folder-name globs to skip (`*.builders`).
    var exclude: [String]
    var recent: [RecentProject]

    static let defaults = ProjectConfig(
        version: currentVersion,
        roots: ["~/Projects", "~/studio-builds"],
        pinned: ["~/Prism", "~/Prism-landing-lab", "~/Documents/LifeOS",
                 "~/Downloads/studio-shine-main", "~/auth2api"],
        exclude: ["*.builders", "axon-lanes"],
        recent: [])

    init(version: Int, roots: [String], pinned: [String], exclude: [String], recent: [RecentProject]) {
        self.version = version; self.roots = roots; self.pinned = pinned
        self.exclude = exclude; self.recent = recent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProjectConfig.defaults
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? ProjectConfig.currentVersion
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? d.roots
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? d.pinned
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? d.exclude
        recent = try c.decodeIfPresent([RecentProject].self, forKey: .recent) ?? []
    }

    /// Front of the list, de-duped by standardized path, capped.
    mutating func recordOpen(_ path: String, at date: Date = Date()) {
        let key = ProjectList.standardize(path)
        recent.removeAll { ProjectList.standardize($0.path) == key }
        recent.insert(RecentProject(path: ProjectList.abbreviate(key), openedAt: date), at: 0)
        if recent.count > Self.recentCap { recent.removeLast(recent.count - Self.recentCap) }
    }

    /// Adds a pinned folder unless it is already there.
    mutating func pin(_ path: String) {
        let key = ProjectList.standardize(path)
        guard !pinned.contains(where: { ProjectList.standardize($0) == key }) else { return }
        pinned.append(ProjectList.abbreviate(key))
    }
}

/// Reads/writes the projects file. Never throws to the caller. Missing file → defaults, written out.
/// Corrupt file → defaults, and the bad file is kept as `projects.json.corrupt` (never overwritten silently).
struct ProjectStore: Sendable {
    let url: URL

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/projects.json")
    }

    init(url: URL = ProjectStore.defaultURL) { self.url = url }

    func load() -> ProjectConfig {
        guard let data = try? Data(contentsOf: url) else {
            save(.defaults)
            return .defaults
        }
        if let cfg = try? Self.decoder.decode(ProjectConfig.self, from: data) { return cfg }
        let aside = url.deletingLastPathComponent().appendingPathComponent("projects.json.corrupt")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        save(.defaults)
        return .defaults
    }

    func save(_ config: ProjectConfig) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(config).write(to: url, options: .atomic)
        } catch {
            NSLog("True: projects save failed: \(error)")
        }
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
