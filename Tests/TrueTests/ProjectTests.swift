import Testing
import Foundation
@testable import True

private func tempDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("true-projects-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func mk(_ root: URL, _ rel: String) {
    try? FileManager.default.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
}

private func proj(_ name: String, parent: String = "~/Projects") -> Project {
    Project(name: name, path: "/tmp/x/\(parent.replacingOccurrences(of: "~", with: "home"))/\(name)", parent: parent)
}

@Suite struct ProjectMatcherTests {
    private func names(_ ps: [Project]) -> [String] { ps.map(\.name) }

    @Test func tierOrdering() {
        let all = [proj("xmixzxaxn"), proj("app-mizan"), proj("mizan-app"), proj("mizan")]
        #expect(names(ProjectMatcher.rank(all, query: "mizan")) == ["mizan", "mizan-app", "app-mizan", "xmixzxaxn"])
    }

    @Test func boundaryBeatsScattered() {
        let all = [proj("fooxdxx"), proj("finance-desk")]
        // "fd": f at start + d after "-" beats f...d scattered
        #expect(names(ProjectMatcher.rank(all, query: "fd")).first == "finance-desk")
        let camel = [proj("scatteredmoreoftrouble"), proj("myTrueApp")]
        #expect(names(ProjectMatcher.rank(camel, query: "ta")).first == "myTrueApp")
    }

    @Test func caseInsensitive() {
        #expect(names(ProjectMatcher.rank([proj("Prism")], query: "PRISM")) == ["Prism"])
    }

    @Test func typoFallback() {
        let all = [proj("finance-desk"), proj("mizan"), proj("prism")]
        #expect(names(ProjectMatcher.rank(all, query: "finace")) == ["finance-desk"])
        #expect(names(ProjectMatcher.rank(all, query: "fnance")) == ["finance-desk"])
        #expect(names(ProjectMatcher.rank(all, query: "mezan")) == ["mizan"])
        #expect(names(ProjectMatcher.rank(all, query: "mizna")) == ["mizan"])   // transposition
    }

    @Test func typoRanksBelowRealMatches() {
        // "mezan" typo-matches mizan; "mezanine" is a real prefix match and must come first.
        let all = [proj("mizan"), proj("mezanine")]
        #expect(names(ProjectMatcher.rank(all, query: "mezan")) == ["mezanine", "mizan"])
    }

    @Test func nonsenseDoesNotMatch() {
        let all = [proj("finance-desk"), proj("mizan"), proj("prism")]
        #expect(ProjectMatcher.rank(all, query: "zqxwv").isEmpty)
        #expect(ProjectMatcher.rank(all, query: "kubernetes").isEmpty)
        // Too short for typo tolerance: 2 chars only match as subsequences.
        #expect(ProjectMatcher.rank(all, query: "qz").isEmpty)
    }

    @Test func parentPathIsWeakerFallback() {
        let all = [proj("alpha", parent: "~/studio-builds"), proj("studio-tools", parent: "~/Projects")]
        #expect(names(ProjectMatcher.rank(all, query: "studio")) == ["studio-tools", "alpha"])
    }

    @Test func recencyBreaksTies() {
        let a = proj("app-one"), b = proj("app-two")
        #expect(names(ProjectMatcher.rank([a, b], query: "app", recent: [b.path])) == ["app-two", "app-one"])
    }

    @Test func emptyQueryRecentsThenAlpha() {
        let a = proj("alpha"), b = proj("Bravo"), c = proj("charlie"), d = proj("delta")
        let out = ProjectMatcher.rank([d, c, b, a], query: "", recent: [c.path, a.path])
        #expect(names(out) == ["charlie", "alpha", "Bravo", "delta"])
    }

    @Test func damerauLevenshtein() {
        func d(_ a: String, _ b: String) -> Int { ProjectMatcher.damerauLevenshtein(Array(a), Array(b)) }
        #expect(d("mizan", "mezan") == 1)
        #expect(d("ab", "ba") == 1)
        #expect(d("", "abc") == 3)
        #expect(d("kitten", "sitting") == 3)
    }
}

@Suite struct ProjectListTests {
    private func config(_ root: URL, roots: [String] = [], pinned: [String] = [], exclude: [String] = [])
        -> ProjectConfig {
        ProjectConfig(version: 1, roots: roots.map { root.path + "/" + $0 },
                      pinned: pinned.map { root.path + "/" + $0 }, exclude: exclude, recent: [])
    }

    @Test func buildsFromRootsPinnedHiddenExcludeMissingAndDedupes() throws {
        let home = tempDir(); defer { try? FileManager.default.removeItem(at: home) }
        for d in ["Projects/alpha", "Projects/beta", "Projects/.hidden", "Projects/old.builders",
                  "Projects/axon-lanes", "Loose/solo", "Loose/.git-thing"] { mk(home, d) }
        try "x".write(to: home.appendingPathComponent("Projects/file.txt"), atomically: true, encoding: .utf8)
        let cfg = config(home, roots: ["Projects"],
                         pinned: ["Loose/solo", "Projects/alpha", "Gone/missing", "Projects/alpha/../alpha", "Projects/.hidden"],
                         exclude: ["*.builders", "axon-lanes"])
        let list = ProjectList.build(cfg, home: home.path)
        let names = list.map(\.name)
        #expect(names == ["alpha", "beta", "solo"])          // root children sorted, pinned after, deduped
        #expect(list.map(\.path).allSatisfy { $0.hasPrefix(home.standardizedFileURL.path) })
        #expect(list[0].parent.hasSuffix("Projects"))
    }

    @Test func tildeExpandsAndAbbreviates() {
        #expect(ProjectList.expand("~/Projects", home: "/Users/z") == "/Users/z/Projects")
        #expect(ProjectList.expand("~", home: "/Users/z") == "/Users/z")
        #expect(ProjectList.expand("/opt/x", home: "/Users/z") == "/opt/x")
        #expect(ProjectList.abbreviate("/Users/z/Projects", home: "/Users/z") == "~/Projects")
        #expect(ProjectList.abbreviate("/opt/x", home: "/Users/z") == "/opt/x")
    }

    @Test func tildePathsResolveAgainstHome() {
        let home = tempDir(); defer { try? FileManager.default.removeItem(at: home) }
        mk(home, "Projects/one")
        let cfg = ProjectConfig(version: 1, roots: ["~/Projects"], pinned: [], exclude: [], recent: [])
        #expect(ProjectList.build(cfg, home: home.path).map(\.name) == ["one"])
    }

    @Test func branchReadsHeadDirectly() throws {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        mk(d, "repo/.git")
        try "ref: refs/heads/feature/x\n".write(to: d.appendingPathComponent("repo/.git/HEAD"), atomically: true, encoding: .utf8)
        #expect(ProjectList.branch(of: d.path + "/repo") == "feature/x")
        try "0123456789abcdef\n".write(to: d.appendingPathComponent("repo/.git/HEAD"), atomically: true, encoding: .utf8)
        #expect(ProjectList.branch(of: d.path + "/repo") == "0123456")
        mk(d, "plain")
        #expect(ProjectList.branch(of: d.path + "/plain") == nil)
    }

    @Test func worktreeGitFileIsFollowed() throws {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        mk(d, "real-gitdir"); mk(d, "wt")
        try "ref: refs/heads/wt-branch\n".write(to: d.appendingPathComponent("real-gitdir/HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: \(d.path)/real-gitdir\n".write(to: d.appendingPathComponent("wt/.git"), atomically: true, encoding: .utf8)
        #expect(ProjectList.branch(of: d.path + "/wt") == "wt-branch")
    }

    @Test func handoffDetection() throws {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        mk(d, "a/.claude"); mk(d, "b/.claude"); mk(d, "c")
        try "x".write(to: d.appendingPathComponent("a/.claude/HANDOFF-abc.md"), atomically: true, encoding: .utf8)
        try "x".write(to: d.appendingPathComponent("b/.claude/notes.md"), atomically: true, encoding: .utf8)
        #expect(ProjectList.hasHandoff(at: d.path + "/a"))
        #expect(!ProjectList.hasHandoff(at: d.path + "/b"))
        #expect(!ProjectList.hasHandoff(at: d.path + "/c"))
    }
}

@Suite struct ProjectStoreTests {
    @Test func recentsDedupeCapAndFrontOrder() {
        var c = ProjectConfig.defaults
        c.recordOpen("/tmp/a", at: Date(timeIntervalSince1970: 1))
        c.recordOpen("/tmp/b", at: Date(timeIntervalSince1970: 2))
        c.recordOpen("/tmp/a/../a", at: Date(timeIntervalSince1970: 3))
        #expect(c.recent.map(\.path) == ["/tmp/a", "/tmp/b"])
        #expect(c.recent[0].openedAt == Date(timeIntervalSince1970: 3))
        for i in 0..<80 { c.recordOpen("/tmp/p\(i)") }
        #expect(c.recent.count == ProjectConfig.recentCap)
        #expect(c.recent[0].path == "/tmp/p79")
    }

    @Test func pinDedupes() {
        var c = ProjectConfig(version: 1, roots: [], pinned: [], exclude: [], recent: [])
        c.pin("/tmp/zed"); c.pin("/tmp/zed/")
        #expect(c.pinned == ["/tmp/zed"])
    }

    @Test func roundTrip() {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let store = ProjectStore(url: d.appendingPathComponent("projects.json"))
        var c = ProjectConfig.defaults
        c.pin("/tmp/extra")
        c.recordOpen("/tmp/extra", at: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(c)
        #expect(store.load() == c)
    }

    @Test func missingFileWritesDefaults() {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let url = d.appendingPathComponent("sub/projects.json")
        #expect(ProjectStore(url: url).load() == .defaults)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(ProjectConfig.defaults.roots == ["~/Projects", "~/studio-builds"])
        #expect(ProjectConfig.defaults.exclude == ["*.builders", "axon-lanes"])
    }

    @Test func missingVersionAndFieldsStillLoad() throws {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let url = d.appendingPathComponent("projects.json")
        try #"{"roots":["~/Only"]}"#.write(to: url, atomically: true, encoding: .utf8)
        let c = ProjectStore(url: url).load()
        #expect(c.version == ProjectConfig.currentVersion)
        #expect(c.roots == ["~/Only"])
        #expect(c.pinned == ProjectConfig.defaults.pinned)
        #expect(c.recent.isEmpty)
    }

    @Test func corruptFileFallsBackAndIsKept() throws {
        let d = tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let url = d.appendingPathComponent("projects.json")
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(ProjectStore(url: url).load() == .defaults)
        let kept = d.appendingPathComponent("projects.json.corrupt")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "{ not json")
    }
}

@Suite struct PaneStartupTests {
    @Test func claudeCommandKeepsAShellAfterClaudeExits() {
        let cmd = PaneStartup.claudeCommand(settings: "/Users/me/.true/hooks/pane.settings.json")
        #expect(cmd == #"command -v claude >/dev/null && claude --dangerously-skip-permissions --settings '/Users/me/.true/hooks/pane.settings.json'; exec "${SHELL:-/bin/zsh}" -l"#)
        #expect(PaneStartup.shellArgs(for: cmd) == ["-l", "-i", "-c", cmd])
    }

    /// A path with a quote or space still reaches claude as one argument.
    @Test func claudeCommandQuotesTheSettingsPath() {
        #expect(PaneStartup.claudeCommand(settings: "/tmp/it's here.json")
                .hasPrefix(#"command -v claude >/dev/null && claude --dangerously-skip-permissions --settings '/tmp/it'\''s here.json'; "#))
    }

    @Test @MainActor func startupCommandIsConsumedOnce() {
        let s = PaneStartup()
        let pane = UUID()
        #expect(s.take(pane) == nil)
        s.set("echo hi", for: pane)
        #expect(s.take(pane) == "echo hi")
        #expect(s.take(pane) == nil)
    }
}
