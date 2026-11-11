import Foundation
import Darwin
import Testing
@testable import True

extension MissionsTests {
    struct GitWorld {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mission-tests-" + UUID().uuidString)
        var repo: URL { root.appendingPathComponent("owner") }
        var remote: URL { root.appendingPathComponent("remote.git") }
        var folder: URL { root.appendingPathComponent("missions/demo") }
        var gate: MissionGitMergeGate { MissionGitMergeGate(folder: folder, resolveClone: { _ in repo.path }) }
        func git(_ args: [String], in directory: URL? = nil) throws -> String {
            let result = PeerLauncherLive.git(args, in: (directory ?? repo).path)
            guard result.0 == 0 else { throw PeerError.invalid(result.1) }
            return result.1
        }
        func setup(check: String? = "true") throws {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try git(["init", "--bare", remote.path], in: root)
            _ = try git(["init", "-b", "main"])
            _ = try git(["config", "user.name", "Test"])
            _ = try git(["config", "user.email", "test@localhost"])
            try Data("base\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
            _ = try git(["add", "."]); _ = try git(["commit", "-m", "base"])
            _ = try git(["remote", "add", "origin", remote.path])
            _ = try git(["push", "origin", "main:mission/demo"])
            try mission(check: check)
            _ = try git(["checkout", "-b", "peer/demo/1-work"])
            try Data("job\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
            _ = try git(["commit", "-am", "work"])
            _ = try git(["fetch", repo.path, "refs/heads/peer/demo/1-work:refs/heads/peer/demo/1-work"], in: remote)
            _ = try git(["checkout", "main"])
        }
        func mission(check: String?) throws {
            let text = "# Mission: Test\n" + (check.map { "check: " + $0 + "\n" } ?? "") + "## Work\nrepo: repo\nwhere: Bea\ncheck: exit 99\n"
            try Data(text.utf8).write(to: folder.appendingPathComponent("mission.md"))
        }
        var launch: MissionLaunch {
            MissionLaunch(key: "mission-demo-0-0", job: MissionJob(title: "Work", line: 3, repo: "repo"),
                          base: "mission/demo", branch: "peer/demo/1-work")
        }
        func remoteHead() throws -> String { try git(["rev-parse", "refs/heads/mission/demo"], in: remote) }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func reason(_ answer: MissionMergeAnswer) -> String {
            switch answer {
            case .inputRequired(let reason): return reason
            case .fix(let note): return note
            case .merged: Issue.record("Expected input-required"); return ""
            }
        }
        func merged(_ answer: MissionMergeAnswer) {
            if case .merged = answer {} else { Issue.record("Expected merged") }
        }
    }

    @Test func gitGreenPushesOnlyMissionAndCrashReplayDoesNotMergeTwice() throws {
        let w = GitWorld(); defer { w.clean() }; try w.setup()
        let main = try w.git(["rev-parse", "main"])
        w.merged(try w.gate.merge(w.launch, at: .mine, check: "exit 99"))
        let pushed = try w.remoteHead()
        w.merged(try w.gate.merge(w.launch, at: .mine, check: nil))
        #expect(try w.remoteHead() == pushed)
        #expect(try w.git(["rev-parse", "main"]) == main)
        #expect(try w.git(["rev-list", "--count", "refs/heads/mission/demo"], in: w.remote) == "3")
        #expect(try w.git(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ").count == 2)
    }

    @Test func gitConflictAndRedCheckExplainTheFixAndDoNotPush() throws {
        let w = GitWorld(); defer { w.clean() }; try w.setup(check: "echo failing-check; exit 3")
        let head = try w.remoteHead()
        #expect(try w.reason(w.gate.merge(w.launch, at: .mine, check: "true")).contains("failing-check"))
        #expect(try w.remoteHead() == head)
        try w.mission(check: "true")
        try Data("conflict\n".utf8).write(to: w.repo.appendingPathComponent("file.txt"))
        _ = try w.git(["commit", "-am", "conflicting base"])
        _ = try w.git(["push", "origin", "HEAD:mission/demo"])
        let updated = try w.remoteHead()
        #expect(try w.reason(w.gate.merge(w.launch, at: .mine, check: nil)) == "rebase on " + w.git(["rev-parse", "--short", updated]))
        #expect(try w.remoteHead() == updated)
        #expect(try w.git(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ").count == 2)
    }

    @Test func gitMissingCheckRemoteAndPushRefusalAskForInput() throws {
        let w = GitWorld(); defer { w.clean() }; try w.setup(check: nil)
        #expect(try w.reason(w.gate.merge(w.launch, at: .mine, check: "true")).contains("the user"))
        try w.mission(check: "true")
        let hook = w.remote.appendingPathComponent("hooks/update")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        #expect(try w.reason(w.gate.merge(w.launch, at: .mine, check: nil)) == "can't merge: no shared remote")
        _ = try w.git(["remote", "remove", "origin"])
        #expect(try w.reason(w.gate.merge(w.launch, at: .mine, check: nil)) == "can't merge: no shared remote")
    }

    @Test func gitCheckHasNoTokensAndPeerConsentPersistsOncePerMission() throws {
        let w = GitWorld(); defer { w.clean() }
        setenv("MISSION_TEST_TOKEN", "private-test-value", 1)
        defer { unsetenv("MISSION_TEST_TOKEN") }
        try w.setup(check: "test -z \"$MISSION_TEST_TOKEN\" && test -z \"$GITHUB_TOKEN\" && test -z \"$SSH_AUTH_SOCK\"")
        let gate = w.gate, head = try w.remoteHead()
        #expect(try w.reason(gate.merge(w.launch, at: .peer("Bea"), check: nil)) == "First merge from Bea: 1 files, +1 -1. Merge?")
        #expect(try w.remoteHead() == head)
        #expect(throws: (any Error).self) { try gate.approve(job: "Unknown") }
        try gate.approve(job: "Work")
        w.merged(try w.gate.merge(w.launch, at: .peer("Bea"), check: nil))
        _ = try w.git(["checkout", "peer/demo/1-work"])
        try Data("more\n".utf8).write(to: w.repo.appendingPathComponent("new.txt"))
        _ = try w.git(["add", "."]); _ = try w.git(["commit", "-m", "more work"])
        _ = try w.git(["fetch", w.repo.path, "refs/heads/peer/demo/1-work:refs/heads/peer/demo/1-work"], in: w.remote)
        _ = try w.git(["checkout", "main"])
        w.merged(try w.gate.merge(w.launch, at: .peer("Bea"), check: nil))
    }

    @Test func checkTimeoutKillsTheWholeGroupAndFreesTheLock() throws {
        let w = GitWorld(); defer { w.clean() }; try w.setup()
        let pidFile = w.root.appendingPathComponent("grandchild.pid").path
        try w.mission(check: "{ sleep 600 & echo $! > '\(pidFile)'; wait; }")
        let gate = MissionGitMergeGate(folder: w.folder, resolveClone: { _ in w.repo.path }, checkTimeout: 2)
        let start = Date()
        let answer = try gate.merge(w.launch, at: .mine, check: nil)
        #expect(Date().timeIntervalSince(start) < 15)
        #expect(w.reason(answer).contains("check timed out"))
        // The per-repo lock and worktree are freed: a second merge takes them right away.
        try w.mission(check: "true")
        w.merged(try gate.merge(w.launch, at: .mine, check: nil))
        // The sleeping grandchild that kept the pipe open is gone.
        guard let pidText = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            Issue.record("grandchild pid was not recorded"); return
        }
        var alive = true
        for _ in 0..<200 where Darwin.kill(pid, 0) == 0 { usleep(10_000) }
        alive = Darwin.kill(pid, 0) == 0
        #expect(!alive)
    }

    @Test func missionCLIRoundTripUsesRunnerAndFolderLease() throws {
        let w = World(); defer { w.clean() }
        func service() -> MissionService {
            MissionService(root: w.root, launcher: w.launcher, now: { Date(timeIntervalSince1970: 100) },
                           scheduler: w.scheduler.enqueue, peers: { ["alex"] }, route: { _, _ in .mine }, gate: { _ in w.gate })
        }
        let cli = service(); defer { cli.close() }
        let bad = cli.handle(["op": "mission.start", "source": "# Mission: Broken\n## Job"])
        #expect(bad["ok"] as? Bool == false && (bad["error"] as? String)?.hasPrefix("Line 2:") == true)
        let started = cli.handle(["op": "mission.start", "source": Self.example])
        let id = try #require(started["missionId"] as? String)
        #expect(started["ok"] as? Bool == true && w.launcher.starts.count == 2)
        let second = service(); defer { second.close() }
        #expect(second.handle(["op": "mission.status", "missionId": id])["ok"] as? Bool == false)
        let status = cli.handle(["op": "mission.status", "missionId": id])
        let rows = try #require(status["jobs"] as? [[String: String]])
        #expect(rows.count == 3 && rows[0]["title"] == "Wave 1a: period locks" && rows[0]["mac"] == "My Mac")
        #expect(cli.handle(["op": "mission.cancel", "missionId": id])["state"] as? String == "canceled")
        cli.close()
        second.recover()
        #expect(second.handle(["op": "mission.status", "missionId": id])["state"] as? String == "canceled")
        #expect(w.launcher.starts.count == 2)
    }
}

extension MissionsTests {
    @Test func gitPreparationPublishesDefaultBaseAndRejectsMain() throws {
        let w = GitWorld(); defer { w.clean() }; try w.setup()
        _ = try w.git(["symbolic-ref", "HEAD", "refs/heads/mission/demo"], in: w.remote)
        var mission = try MissionFile.parse("# Mission: New\ncheck: true\n## Work\nrepo: repo", peers: [])
        try w.gate.prepare(mission, id: "new")
        #expect(try w.git(["rev-parse", "refs/heads/mission/new"], in: w.remote) == w.remoteHead())
        mission.into = "main"
        #expect(throws: (any Error).self) { try w.gate.prepare(mission, id: "new") }
        #expect(PeerLauncherLive.git(["rev-parse", "--verify", "refs/heads/main"], in: w.remote.path).0 != 0)
    }

    @Test func missionCLIApprovesTheExistingJobWithoutLaunchingAgain() throws {
        let w = GitWorld(); defer { w.clean() }; try w.setup()
        let launcher = Launcher(), schedule = Schedule()
        let service = MissionService(root: w.folder.deletingLastPathComponent(), launcher: launcher,
                                     now: { Date(timeIntervalSince1970: 100) }, scheduler: schedule.enqueue,
                                     peers: { ["Bea"] }, route: { _, _ in .peer("Bea") }, gate: { _ in w.gate })
        defer { service.close() }
        #expect(service.handle(["op": "mission.status", "missionId": "demo"])["ok"] as? Bool == true)
        launcher.finish("Work")
        let waiting = service.handle(["op": "mission.status", "missionId": "demo"])
        #expect(waiting["state"] as? String == "needs-you")
        let approved = service.handle(["op": "mission.approve", "missionId": "demo", "job": "Work"])
        #expect(approved["ok"] as? Bool == true && approved["state"] as? String == "done")
        #expect(launcher.starts.count == 1)
    }

    @Test func missionScriptRoundTripWithFakeLauncher() throws {
        let w = World(); defer { w.clean() }
        let service = MissionService(root: w.root, launcher: w.launcher, now: { Date(timeIntervalSince1970: 100) },
                                     scheduler: w.scheduler.enqueue, peers: { ["alex"] }, route: { _, _ in .mine }, gate: { _ in w.gate })
        defer { service.close() }
        let temp = URL(fileURLWithPath: "/tmp/mcli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let script = temp.appendingPathComponent("true-peer.py"), file = temp.appendingPathComponent("mission.md")
        try PeerCLI.script(socketPath: "/tmp/unused.sock").write(to: script, atomically: true, encoding: .utf8)
        try Self.example.write(to: file, atomically: true, encoding: .utf8)
        let harness = temp.appendingPathComponent("wire.py")
        // Exercise the generated command parser and output with an injected JSON-line wire.
        // This also works in build sandboxes that prohibit binding Unix sockets.
        try """
        import json, sys
        namespace = {}
        exec(open(sys.argv[1]).read().rsplit("main(sys.argv[1:])", 1)[0], namespace)
        def call(req):
            print(json.dumps(req), flush=True)
            response = json.loads(sys.stdin.readline())
            if not response.get("ok"):
                raise RuntimeError(response.get("error"))
            return response
        namespace["call"] = call
        namespace["main"](sys.argv[2:])
        """.write(to: harness, atomically: true, encoding: .utf8)
        func cli(_ args: [String]) throws -> String {
            let process = Process(), output = Pipe(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [harness.path, script.path, "mission"] + args
            process.standardOutput = output; process.standardInput = input
            defer { try? output.fileHandleForReading.close(); try? input.fileHandleForWriting.close() }
            try process.run()
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte == Data([10]) { break }
                line.append(byte)
            }
            let request = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
            var reply = try JSONSerialization.data(withJSONObject: service.handle(request)); reply.append(10)
            try input.fileHandleForWriting.write(contentsOf: reply)
            try input.fileHandleForWriting.close()
            let text = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let id = try cli(["start", file.path])
        #expect(UUID(uuidString: id) != nil)
        let status = try cli(["status", id])
        #expect(status.split(separator: "\n").count == 3)
        #expect(status.contains("Wave 1a: period locks  My Mac  running"))
        #expect(try cli(["cancel", id]) == "Canceled")
        #expect(try cli(["status", id]).contains("canceled"))
    }
}

extension MissionsTests {
    @Test func missionBranchMetadataReachesReceiverAndSingleJobNamesStayUnchanged() throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }; pairUp(a, b)
        let launch = MissionLaunch(key: "mission-demo-0-0", job: MissionJob(title: "Work", line: 2, repo: testRepo),
                                   base: "mission/demo", branch: PeerNaming.missionBranch(id: "demo", job: "Work", index: 0), missionName: "Launch work")
        try MissionPeerLauncher(engine: a.engine).start(launch, at: .peer("Bea")); settle(a, b)
        #expect(b.engine.inboundJobs().first?.branch == "peer/demo/1-work")
        #expect(b.engine.inboundJobs().first?.req.missionName == "Launch work")
        #expect(a.engine.sentJobs().first?.missionName == "Launch work")
        #expect(PeerNaming.branch(label: "Bea", jobId: "abcdef12-1234-1234-1234-123456789abc") == "peer/bea/abcdef12")
        #expect(PeerNaming.missionBranch(id: "demo", job: "Work", index: 0, attempt: 1) != launch.branch)
    }
}

extension MissionsTests {
    @Test func missionPreparationFailureAsksWithoutLaunchingAndCanRetry() throws {
        let w = World(); defer { w.clean() }
        var available = false
        let service = MissionService(root: w.root, launcher: w.launcher, now: { Date(timeIntervalSince1970: 100) },
                                     scheduler: w.scheduler.enqueue, peers: { ["alex"] }, route: { _, _ in .mine },
                                     gate: { _ in w.gate }, prepare: { _, _, _ in
            if !available { throw PeerError.invalid("can't merge: no shared remote") }
        })
        defer { service.close() }
        let answer = service.handle(["op": "mission.start", "source": Self.example])
        let id = try #require(answer["missionId"] as? String)
        #expect(answer["state"] as? String == "needs-you" && w.launcher.starts.isEmpty)
        let rows = try #require(answer["jobs"] as? [[String: String]])
        #expect(rows[0]["reason"] == "can't merge: no shared remote")
        available = true
        // Recovery preserves the input-required jobs until an explicit retry, rather than resending them.
        service.close()
        let runner = try MissionRunner(id: id, root: w.root, peers: ["alex"], launcher: w.launcher, gate: w.gate,
                                       now: { Date(timeIntervalSince1970: 100) }, scheduler: w.scheduler.enqueue,
                                       route: { _, _ in .mine })
        defer { runner.close() }
        try runner.retryJob("Wave 1a: period locks")
        #expect(w.launcher.starts.count == 1)
    }
}
