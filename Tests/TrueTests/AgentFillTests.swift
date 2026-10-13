import Testing
import Foundation
@testable import True

@Suite struct AgentFillTests {
    let good = Data("""
    {"type":"result","subtype":"success","is_error":false,"result":"ok","structured_output":
     {"role":"helper","model":"opus","effort":"high","permission":"plan","symbol":"scope","charter":"## Mission\\nFind bugs."}}
    """.utf8)

    @Test func argvHasEveryFlagOnce() {
        let a = AgentFill.argv(claude: "/x/claude", schema: "{}", prompt: "P")
        #expect(a[0] == "/x/claude")
        for f in ["-p", "--model", "--output-format", "--json-schema", "--strict-mcp-config", "--mcp-config",
                  "--no-session-persistence", "--tools", "--setting-sources"] {
            #expect(a.filter { $0 == f }.count == 1)
        }
        #expect(a.contains("{}") && a.last == "P")
        #expect(!a.contains("--bare"))
    }

    @Test func schemaListsAllKeysAndSymbols() {
        let s = AgentFill.schema
        for k in ["role", "model", "effort", "permission", "symbol", "charter"] { #expect(s.contains("\"\(k)\"")) }
        for sym in BuilderDraft.symbols { #expect(s.contains("\"\(sym)\"")) }
        #expect(s.contains("acceptEdits"))
    }

    @Test func parseSuccess() throws {
        let p = try AgentFill.parse(good)
        #expect(p.model == "opus" && p.role == "helper" && p.symbol == "scope")
    }

    @Test func parseFailuresThrow() {
        let err = Data(#"{"subtype":"error_during_execution","is_error":true,"result":"boom"}"#.utf8)
        #expect(throws: AgentFill.FillError.self) { try AgentFill.parse(err) }
        let none = Data(#"{"subtype":"success","is_error":false}"#.utf8)
        #expect(throws: AgentFill.FillError.self) { try AgentFill.parse(none) }
        #expect(throws: AgentFill.FillError.self) { try AgentFill.parse(Data("nope".utf8)) }
    }

    @Test func applySetsFields() throws {
        var d = BuilderDraft(repo: "/tmp/app")
        AgentFill.apply(try AgentFill.parse(good), to: &d)
        #expect(d.role == .helper && d.model == .opus && d.effort == .high && d.permission == .plan)
        #expect(d.symbol == "scope" && d.charter.contains("Mission"))
    }

    @Test func applyKeepsRoleWhenEditing() throws {
        var d = BuilderDraft(editing: Agent(name: "lead-app", role: .lead, repo: "/tmp/app"))
        AgentFill.apply(try AgentFill.parse(good), to: &d)
        #expect(d.role == .lead && d.model == .opus)
    }

    @Test func applyIgnoresUnknowns() {
        var d = BuilderDraft(repo: "/tmp/app")
        let p = AgentFill.Profile(role: "boss", model: "gpt", effort: "huge", permission: "yolo",
                                  symbol: "not.a.symbol", charter: "c")
        AgentFill.apply(p, to: &d)
        #expect(d.role == .lead && d.model == .sonnet && d.effort == .medium && d.permission == .default)
        #expect(d.symbol == "crown" && d.charter == "c")
    }

    @Test func promptMentionsRepoAndFixedRole() {
        let d = BuilderDraft(editing: Agent(name: "helper-1-app", role: .helper, repo: "/tmp/myapp"))
        let p = AgentFill.prompt(request: "review PRs", draft: d)
        #expect(p.contains("myapp") && p.contains("review PRs"))
        #expect(p.contains("fixed to helper"))
        #expect(!AgentFill.prompt(request: "x", draft: BuilderDraft(repo: "/tmp/myapp")).contains("fixed to"))
    }
}
