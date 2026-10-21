import Testing
import Foundation
@testable import True

@Suite struct PaneIdentityTests {
    func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pane-id-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func write(_ s: String, _ u: URL) {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: u, atomically: true, encoding: .utf8)
    }

    @Test func plainRepoAndSubdirectory() {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        write("ref: refs/heads/feat/x\n", root.appendingPathComponent("axon/.git/HEAD"))
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("axon/Sources/a"), withIntermediateDirectories: true)
        let g = PaneIdentity.gitInfo(cwd: root.path + "/axon/Sources/a")
        #expect(g?.repo == "axon"); #expect(g?.branch == "feat/x"); #expect(g?.worktree == false)
    }

    @Test func worktreeReportsMainRepo() {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        write("ref: refs/heads/main\n", root.appendingPathComponent("true/.git/HEAD"))
        write("abcdef0123456789\n", root.appendingPathComponent("true/.git/worktrees/wt1/HEAD"))
        write("gitdir: \(root.path)/true/.git/worktrees/wt1\n", root.appendingPathComponent("wt1-dir/.git"))
        let g = PaneIdentity.gitInfo(cwd: root.path + "/wt1-dir")
        #expect(g?.repo == "true"); #expect(g?.worktree == true); #expect(g?.branch == "abcdef0")
    }

    @Test func noGit() {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(PaneIdentity.gitInfo(cwd: root.path) == nil)
        #expect(PaneIdentity.gitInfo(cwd: "") == nil)
    }

    @Test func handoffTopicIsFirstHeading() {
        let d = Data("intro\n\n#nope\n#  Phone   pane identity \n# second\n".utf8)
        #expect(PaneIdentity.handoffTopic(d) == "Phone pane identity")
        #expect(PaneIdentity.handoffTopic(Data("no heading".utf8)) == nil)
    }

    @Test func transcriptOpeningPrompt() {
        let lines = [#"{"type":"summary","x":1}"#,
                     #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: ignore"}}"#,
                     #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the   login\nbug please"}]}}"#,
                     #"{"type":"user","message":{"role":"user","content":"later"}}"#]
        #expect(PaneIdentity.transcriptPrompt(Data(lines.joined(separator: "\n").utf8)) == "Fix the login")
        let long = #"{"type":"user","message":{"content":"\#(String(repeating: "a", count: 300))"}}"#
        #expect(PaneIdentity.transcriptPrompt(Data(long.utf8))?.count == 120)
        #expect(PaneIdentity.transcriptSlug("/Users/example/.claude/x_y") == "-Users-example--claude-x-y")
    }

    @MainActor @Test func buildPrefersHandoffThenTranscriptAndIsFast() {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let pane = UUID(); let token = EmbeddedTerminal.burnToken(pane)
        let cwd = root.path + "/repo"
        write("ref: refs/heads/dev\n", root.appendingPathComponent("repo/.git/HEAD"))
        let claude = root.appendingPathComponent("claude")
        let slug = PaneIdentity.transcriptSlug(cwd)
        write(#"{"type":"user","message":{"content":"Opening prompt"}}"# + "\n", claude.appendingPathComponent("projects/\(slug)/S1.jsonl"))
        var id = PaneIdentity.build(pane: pane, cwd: cwd, sessionID: "S1", claudeCwd: cwd, claudeDir: claude)
        #expect(id.repo == "repo"); #expect(id.branch == "dev"); #expect(id.topic == "Opening prompt"); #expect(id.sessionID == "S1")

        write("# From handoff\n", root.appendingPathComponent("repo/.claude/HANDOFF-\(token).md"))
        id = PaneIdentity.build(pane: pane, cwd: cwd, sessionID: "S1", claudeCwd: cwd, claudeDir: claude)
        #expect(id.topic == "From handoff")

        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<100 { _ = PaneIdentity.build(pane: pane, cwd: cwd, sessionID: "S1", claudeCwd: cwd, claudeDir: claude) }
        let perCallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 100 / 1e6
        print("PANE-IDENTITY warm ms/call:", perCallMs)
        #expect(perCallMs < 5)

        var row: [String: Any] = [:]; id.addKeys(to: &row)
        #expect(row["repo"] as? String == "repo"); #expect(row["topic"] as? String == "From handoff")
        #expect(row["worktree"] as? Bool == false); #expect(row["sessionID"] as? String == "S1")
        var bare: [String: Any] = [:]; PaneIdentity().addKeys(to: &bare)
        #expect(bare["topic"] == nil); #expect(bare["repo"] == nil)
    }
}
