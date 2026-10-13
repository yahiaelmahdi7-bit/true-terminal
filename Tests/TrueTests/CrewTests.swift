import Testing
import Foundation
@testable import True

private func md(_ fm: String) -> Data { Data("---\n\(fm)\n---\nbody".utf8) }
private func agent(_ n: String) -> CrewAgent {
    CrewAgent(name: n, summary: "", fullDescription: "", model: "inherit", color: nil)
}
private func titles(_ g: [CrewGroup]) -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: g.map { ($0.title, $0.agents.map(\.name)) })
}

@Suite struct CrewParserTests {
    @Test func quotedAndUnquoted() throws {
        let q = try #require(CrewParser.parse(md("name: a\ndescription: \"Does \\\"x\\\" well\"\nmodel: sonnet\ncolor: Blue"), filename: "a.md"))
        #expect(q.summary == "Does \"x\" well" && q.model == "sonnet" && q.color == "blue")
        let u = try #require(CrewParser.parse(md("name: b\ndescription: Plain text"), filename: "b.md"))
        #expect(u.summary == "Plain text" && u.model == "inherit" && u.color == nil)
    }

    @Test func examplesCutAndLiteralNewline() throws {
        let a = try #require(CrewParser.parse(md("name: a\ndescription: \"Reviews code. Examples: <example>hi</example>\""), filename: "a.md"))
        #expect(a.summary == "Reviews code.")
        let b = try #require(CrewParser.parse(md("name: b\ndescription: \"First line\\nSecond\""), filename: "b.md"))
        #expect(b.summary == "First line" && b.fullDescription == "First line\nSecond")
        let c = try #require(CrewParser.parse(md("name: c\ndescription: Use it <example>x</example>"), filename: "c.md"))
        #expect(c.summary == "Use it")
    }

    @Test func capsOnWordBoundary() {
        let long = String(repeating: "word ", count: 80)
        let s = CrewParser.summary(of: long)
        #expect(s.count <= 161 && s.hasSuffix("word…"))
    }

    @Test func missingNameFallsBackToFilename() throws {
        let a = try #require(CrewParser.parse(md("description: hi"), filename: "my-agent.md"))
        #expect(a.name == "my-agent")
    }

    @Test func garbageIsNil() {
        #expect(CrewParser.parse(Data("no frontmatter at all".utf8), filename: "x.md") == nil)
        #expect(CrewParser.parse(Data([0xFF, 0xFE, 0x00]), filename: "x.md") == nil)
        #expect(CrewParser.parse(Data("---\nname: a\n".utf8), filename: "x.md") == nil)
    }

    @Test func scannerSkipsNonMdAndDirs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("logs.md"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try md("name: good").write(to: dir.appendingPathComponent("good.md"))
        try md("name: sh").write(to: dir.appendingPathComponent("run.sh"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("bad.md"))
        #expect(CrewScanner.agents(in: dir).map(\.name) == ["good"])
    }

    @Test func loadUsesProjectAndGlobalDirs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crew-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("app"), glob = root.appendingPathComponent("global")
        try FileManager.default.createDirectory(at: proj.appendingPathComponent(".claude/agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: glob, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try md("name: app-cto").write(to: proj.appendingPathComponent(".claude/agents/app-cto.md"))
        try md("name: app-cto").write(to: glob.appendingPathComponent("app-cto.md"))
        try md("name: solo").write(to: glob.appendingPathComponent("solo.md"))
        let snap = CrewScanner.load(cwd: proj.path + "/src", globalDir: glob, hasGit: { $0 == proj.path })
        #expect(snap.header == "Crew for app")
        #expect(titles(snap.project) == ["Lead": ["app-cto"]] && titles(snap.global) == ["General": ["solo"]])
        let none = CrewScanner.load(cwd: "/nowhere/x", globalDir: glob, hasGit: { _ in false })
        #expect(none.header == "Crew" && none.project.isEmpty)
    }
}

@Suite struct CrewGroupingTests {
    @Test func trueCrewFamilies() {
        let names = ["true-cto", "true-swift-engineer", "true-integrations-engineer", "true-ux-designer",
                     "true-ui-designer", "true-security", "true-knowledge-keeper"]
        let g = CrewGrouping.project(names.map(agent), repo: "true")
        #expect(g.map(\.title) == ["Lead", "Engineering", "Design", "Security", "Knowledge"])
        #expect(titles(g)["Engineering"] == ["true-integrations-engineer", "true-swift-engineer"])
        #expect(titles(g)["Design"] == ["true-ui-designer", "true-ux-designer"])
    }

    @Test func otherAndSecurityEngineer() {
        let g = CrewGrouping.project(["x-security-engineer", "x-misc", "x-cfo"].map(agent), repo: "x")
        #expect(titles(g) == ["Security": ["x-security-engineer"], "Other": ["x-misc"], "Lead": ["x-cfo"]])
    }

    @Test func globalTeamThreshold() {
        let three = CrewGrouping.global(["studio-a", "studio-b", "studio-c", "solo", "pair-x", "pair-y"].map(agent))
        #expect(three.map(\.title) == ["General", "Studio"])
        #expect(titles(three)["General"] == ["pair-x", "pair-y", "solo"])
        let two = CrewGrouping.global(["studio-a", "studio-b"].map(agent))
        #expect(two.map(\.title) == ["General"])
    }

    @Test func projectOverridesGlobal() {
        let g = CrewGrouping.global(["dup", "keep"].map(agent), excluding: ["dup"])
        #expect(titles(g) == ["General": ["keep"]])
    }

    @Test func starterText() {
        #expect(CrewStarter.text(for: agent("true-swift-engineer")) == "Use the true-swift-engineer agent to ")
    }

    @Test func displayNamesKeepRealIdInPrompt() {
        let cto = agent("true-cto")
        #expect(CrewDisplay.name("true-cto") == "CTO")
        #expect(CrewDisplay.name("true-swift-engineer") == "Swift Engineer")
        #expect(CrewDisplay.name("true-ui-designer") == "UI Designer")
        #expect(CrewStarter.text(for: cto) == "Use the true-cto agent to ")
        #expect(CrewDisplay.groupTitle("Lead") == "Leadership")
        #expect(CrewDisplay.groupTitle("Everywhere") == "All projects")
        #expect(CrewDisplay.model("inherit") == "Same model")
        #expect(CrewDisplay.model("sonnet") == "Sonnet")
        #expect(CrewDisplay.symbol(family: "Security") == "shield")
        #expect(CrewDisplay.symbol(family: "Other") == "person")
    }
}
