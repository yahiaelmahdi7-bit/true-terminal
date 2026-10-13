import Testing
import Foundation
@testable import True

private let home = "/Users/u"
private let files: Set<String> = ["/Users/u/Projects/app/brief.md"]
private let dirs: Set<String> = ["/Users/u/Projects/app", "/Users/u/Prism", "/Users/u/studio-builds/x", "/etc"]

private func command(_ r: SpawnRequest, callerRepo: String? = nil) -> Result<[String], SpawnError> {
    r.command(callerRepo: callerRepo, home: home, fileExists: { files.contains($0) || dirs.contains($0) }, isDirectory: { dirs.contains($0) })
}

private func req(name: String = "hub-run", repo: String? = "/Users/u/Projects/app", worktree: Bool = false,
                 model: String = "sonnet", from: String? = nil) -> SpawnRequest {
    SpawnRequest(name: name, promptFile: "/Users/u/Projects/app/brief.md", repo: repo, worktree: worktree, model: model, from: from)
}

@Suite struct SpawnParseTests {
    @Test func parsesEveryWireKey() {
        let line = #"{"op":"spawn","name":"n1","promptFile":"/p/f.md","repo":"/r","worktree":true,"model":"opus","from":"lead-a"}"#
        #expect(ControlRequest.parse(Data(line.utf8)) == .spawn(SpawnRequest(name: "n1", promptFile: "/p/f.md", repo: "/r", worktree: true, model: "opus", from: "lead-a")))
        #expect(ControlRequest.parse(Data(#"{"op":"spawn","name":"n1","promptFile":"/p/f.md"}"#.utf8))
                == .spawn(SpawnRequest(name: "n1", promptFile: "/p/f.md", repo: nil, worktree: false, model: "sonnet", from: nil)))
        #expect(ControlRequest.parse(Data(#"{"op":"spawn","name":"n1"}"#.utf8)) == nil)
    }
}

@Suite struct SpawnCommandTests {
    @Test func everyFlagInOrder() throws {
        let argv = try command(req(worktree: true, model: "opus", from: "lead-app")).get()
        #expect(argv == ["/Users/u/.claude/bin/builder", "start", "--name", "hub-run", "--cwd", "/Users/u/Projects/app",
                         "--prompt-file", "/Users/u/Projects/app/brief.md", "--worktree", "--model", "opus", "--parent", "lead-app"])
    }

    @Test func minimalOmitsWorktreeAndParent() throws {
        let argv = try command(req()).get()
        #expect(!argv.contains("--worktree") && !argv.contains("--parent") && argv.contains("sonnet"))
    }

    @Test func repoDefaultsToCallersRepo() throws {
        let argv = try command(req(repo: nil), callerRepo: "/Users/u/Projects/app").get()
        #expect(argv[argv.firstIndex(of: "--cwd")! + 1] == "/Users/u/Projects/app")
        if case .success = command(req(repo: nil)) { Issue.record("no repo and no caller must fail") }
    }

    @Test func refusals() {
        func msg(_ r: SpawnRequest) -> String { if case .failure(let e) = command(r) { return e.message } else { return "" } }
        for bad in ["", "Bad", "-x", "has space", "a/b", String(repeating: "a", count: 41)] {
            #expect(msg(req(name: bad)).contains("bad name"), "\(bad)")
        }
        #expect(SpawnRequest.isValidName("a") && SpawnRequest.isValidName("run-7") && SpawnRequest.isValidName(String(repeating: "a", count: 40)))
        #expect(msg(req(model: "gpt")).contains("unknown model"))
        var missing = req(); missing.promptFile = "/Users/u/Projects/app/nope.md"
        #expect(msg(missing).contains("prompt file not found"))
        #expect(msg(req(repo: "/etc")).contains("must be under"))
        #expect(msg(req(repo: "/Users/u/Projects/app/../../../../etc")).contains("must be under"))
        #expect(msg(req(repo: "/Users/u/ProjectsEvil")).contains("not a folder"))
        #expect(msg(req(repo: "/Users/u/Prism")) == "")
        #expect(msg(req(repo: "/Users/u/studio-builds/x")) == "")
    }
}

@Suite struct SpawnRunTests {
    @Test func startedLineGivesTheID() {
        #expect(BuilderSpawn.startedID(in: "noise\nSTARTED 20260930-abc (pid 5, model sonnet)\n") == "20260930-abc")
        #expect(BuilderSpawn.startedID(in: "ALREADY RUNNING x — do not relaunch") == nil)
    }

    @Test func runnerOutputBecomesIDOrErrorText() async {
        let ok = await BuilderSpawn.run(req(), callerRepo: nil, runner: { _ in (0, "STARTED id-9 (pid 1)\n") },
                                        home: home, fileExists: { files.contains($0) || dirs.contains($0) }, isDirectory: { dirs.contains($0) })
        #expect(ok == .success("id-9"))
        let dup = await BuilderSpawn.run(req(), callerRepo: nil, runner: { _ in (3, "ALREADY RUNNING id-1 — do not relaunch\n") },
                                         home: home, fileExists: { files.contains($0) || dirs.contains($0) }, isDirectory: { dirs.contains($0) })
        #expect(dup == .failure(SpawnError("ALREADY RUNNING id-1 — do not relaunch")))
    }
}

@Suite struct SpawnGuidanceTests {
    @Test func leadRoleCardTeachesSpawnStatusAndSummon() {
        let lead = Agent(name: "lead-app", role: .lead, repo: "/Users/u/Projects/app")
        let card = AgentLaunch.roleCard(lead, all: [lead])
        #expect(card.contains("truectl status") && card.contains("truectl spawn --name") && card.contains("--prompt-file"))
        #expect(card.contains("Background in the Hub") && card.contains("truectl summon"))
        let helper = Agent(name: "helper-1-app", role: .helper, repo: "/Users/u/Projects/app")
        #expect(!AgentLaunch.roleCard(helper, all: [lead, helper]).contains("truectl spawn"))
    }

    @Test func truectlScriptCarriesSpawnAndJson() {
        let s = AgentControl.truectl(socketPath: "/tmp/x/control.sock")
        #expect(s.contains("\"spawn\"") && s.contains("--prompt-file") && s.contains("--json") && s.contains("promptFile"))
    }
}
