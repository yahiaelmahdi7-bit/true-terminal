import Testing
import Foundation
@testable import True

final class FakeAskRunner: AskRunning, @unchecked Sendable {
    let lock = NSLock()
    var calls: [(prompt: String, cwd: String)] = []
    var reply: AskRunResult = .answer("42")
    func run(prompt: String, cwd: String, root: URL, askId: String) -> AskRunResult {
        lock.lock(); calls.append((prompt, cwd)); let r = reply; lock.unlock()
        return r
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
}

@Suite(.serialized) struct PeerAskTests {
    struct Rig {
        let a: PeerSide, b: PeerSide, relay: FakeRelay, clock: Clock, runner: FakeAskRunner
        func close() { a.close(); b.close() }
    }

    /// `a` (Al) asks, `b` (Bo) answers. Bo's grant snapshot gives Al `read` on the test repo unless told otherwise.
    func rig(grant: Bool = true) -> Rig {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        let runner = FakeAskRunner()
        b.engine.ask.runner = runner
        b.engine.ask.poolState = { .ok }          // the lend/hold wiring has its own tests (PeerAskWiringTests)
        seed(b, asker: a, grant: grant)
        return Rig(a: a, b: b, relay: relay, clock: clock, runner: runner)
    }

    func seed(_ b: PeerSide, asker a: PeerSide, grant: Bool, boRole: String = "member") {
        let snap = GrantSnapshot(
            fetched_at: nil, device: "d-bo",
            persons: [.init(id: "al", role: "member", active: 1), .init(id: "bo", role: boRole, active: 1)],
            devices: [.init(device: "d-al", person: "al", peer_key: PeerB64.std(a.identity.keys.sign), public_key: nil),
                      .init(device: "d-bo", person: "bo", peer_key: PeerB64.std(b.identity.keys.sign), public_key: nil)],
            workspaces: [.init(id: "w1", kind: "repo", key: testRepo, owner: "bo")],
            grants: grant ? [.init(id: "g1", person: "al", workspace: "w1", level: "read", expires: nil, revoked_at: nil)] : [])
        _ = b.engine.grants.apply(try! JSONEncoder().encode(snap))
    }

    @discardableResult
    func ask(_ r: Rig, _ q: String = "where is auth?", repo: String = testRepo) -> String {
        guard case .success(let id) = r.a.engine.ask.send(to: "Bea", question: q, repo: repo, fromAgent: "lead-1") else { Issue.record("ask not sent"); return "" }
        settle(r.a, r.b)
        return id
    }

    @Test func answersWithinWaitThroughTheCLI() throws {
        let r = rig(); defer { r.close() }
        let reply = PeerCLI.handle(["op": "ask", "peer": "Bea", "q": "where is auth?", "repo": testRepo, "wait": 10.0], engine: r.a.engine)
        #expect(reply["ok"] as? Bool == true && reply["answered"] as? Bool == true && reply["text"] as? String == "42")
        let id = try #require(reply["askId"] as? String)
        let res = PeerCLI.handle(["op": "result", "jobId": id], engine: r.a.engine)
        #expect(res["result"] as? String == "42" && res["status"] as? String == "answered")
        #expect(r.a.launcher.lines.contains { $0.0 == "agent" && $0.1 == "Answer from Bea is ready: run `true-peer result \(id)`" })
        #expect(r.runner.count == 1 && r.runner.calls[0].cwd == "/tmp/peers-clone/app")
        print("G7 TWO-HOME: Al -> Bea ask answered within --wait: \"\(reply["text"] as? String ?? "")\"; runs=\(r.runner.count)")
    }

    @Test func offlineReceiverGetsItExactlyOnce() throws {
        let r = rig(); defer { r.close() }
        r.b.transport.setOnline(false)
        let id = ask(r)
        #expect(r.runner.count == 0 && r.a.engine.ask.answer(id) == nil)
        r.clock.t = r.clock.t.addingTimeInterval(600)
        r.b.transport.setOnline(true); settle(r.a, r.b)
        #expect(r.runner.count == 1)
        #expect(r.a.engine.ask.answer(id)?.text == "42")
        // a repeat of the same ask id under a fresh envelope, and a replayed answer, change nothing
        let again: [String: Any] = ["t": "ask", "askId": id, "q": "where is auth?", "repo": testRepo, "at": r.clock.t.timeIntervalSince1970]
        let blob = PeerSeal.seal(payload: try JSONSerialization.data(withJSONObject: again), now: r.clock.t, from: r.a.identity, to: r.b.identity.keys)!
        r.b.engine.receive(blob); settle(r.a, r.b)
        #expect(r.runner.count == 1)
        #expect(r.a.launcher.lines.count == 1)
        print("G7 TWO-HOME: Bo offline 10 min, then online: runs=\(r.runner.count) answers=\(r.a.launcher.lines.count) (exactly once)")
    }

    @Test func askLeftA24HoursExpires() throws {
        let r = rig(); defer { r.close() }
        r.b.transport.setOnline(false)
        let id = ask(r)
        r.clock.t = r.clock.t.addingTimeInterval(24 * 3600 + 5)
        r.a.delays.fireDue(r.clock); settle(r.a, r.b)
        let a = try #require(r.a.engine.ask.answer(id))
        #expect(a.status == "expired" && a.text == "expired: Bea did not come online")
        #expect(r.a.engine.outboxCount() == 0)
        r.b.transport.setOnline(true); settle(r.a, r.b)       // the old ask must not run late
        #expect(r.runner.count == 0)
        #expect(r.a.engine.ask.answer(id)?.status == "expired")
        print("G7 TWO-HOME: 24 h later -> \(a.text); late delivery runs=\(r.runner.count)")
    }

    @Test func refusalsAreWordForWord() throws {
        func text(_ r: Rig, _ id: String) -> String? { r.a.engine.ask.answer(id)?.text }
        do {   // no grant
            let r = rig(grant: false); defer { r.close() }
            let id = ask(r); #expect(text(r, id) == "refused: Bea has not granted you read on app")
            let id2 = ask(r, repo: ""); #expect(text(r, id2) == "refused: Bea has not granted you read on any of their workspaces")
            #expect(r.runner.count == 0)
            print("G7 REFUSAL: \(text(r, id)!) | \(text(r, id2)!)")
        }
        do {   // not cloned
            let r = rig(); defer { r.close() }
            r.b.launcher.clone = nil
            let id = ask(r); #expect(text(r, id) == "refused: app is not cloned on Bea")
        }
        do {   // lending off, pool limit
            let r = rig(); defer { r.close() }
            r.b.engine.ask.poolState = { .lendOff }
            let id = ask(r); #expect(text(r, id) == "refused: Bea's Mac is not lending right now")
            r.b.engine.ask.poolState = { .atLimit }
            let id2 = ask(r); #expect(text(r, id2) == "refused: Bea's Mac is at its pool limit")
            #expect(r.runner.count == 0)
        }
        do {   // reserved
            let r = rig(); defer { r.close() }
            r.b.engine.ask.isReserved = { true }
            let id = ask(r); #expect(text(r, id) == "refused: the user's Mac is reserved")
            #expect(r.runner.count == 0)
        }
        do {   // the owner's Mac is reserved by default, from the snapshot
            let r = rig(); defer { r.close() }
            seed(r.b, asker: r.a, grant: true, boRole: "owner")
            let id = ask(r); #expect(text(r, id) == "refused: the user's Mac is reserved")
        }
        do {   // a stale snapshot reads as no grant
            let r = rig(); defer { r.close() }
            r.clock.t = r.clock.t.addingTimeInterval(16 * 60)
            let id = ask(r); #expect(text(r, id) == "refused: Bea has not granted you read on app")
        }
    }

    @Test func theEleventhAskInAnHourIsRefused() throws {
        let r = rig(); defer { r.close() }
        var ids: [String] = []
        for _ in 0..<11 { ids.append(ask(r)); r.clock.t = r.clock.t.addingTimeInterval(1) }
        #expect(r.runner.count == 10)
        let last = try #require(r.a.engine.ask.answer(ids[10])).text
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let first = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(3600)
        #expect(last == "refused: ask limit reached (10 an hour from you, 40 a day in total), try after \(f.string(from: first))")
        r.clock.t = r.clock.t.addingTimeInterval(3600)
        seed(r.b, asker: r.a, grant: true)       // a fresh snapshot, the old one is past its 15 minutes
        let ok = ask(r)
        #expect(r.a.engine.ask.answer(ok)?.text == "42")
        print("G7 REFUSAL: 11th ask -> \(last)")
    }

    @Test func auditHoldsIdsAndSizesNeverText() throws {
        let r = rig(); defer { r.close() }
        r.runner.reply = .answer("ANSWERWORD")   // a word, not "42": note ids are random hex, so a digit pair can land in one by chance
        _ = ask(r, "SECRETWORD where is auth?")
        let notes = (r.a.engine.grants.pendingNotes() + r.b.engine.grants.pendingNotes())
        #expect(notes.contains { $0.action == "ask.sent" } && notes.contains { $0.action == "ask.received" } && notes.contains { $0.action == "ask.answered" })
        #expect(!notes.contains { $0.note.contains("SECRETWORD") || $0.note.contains("auth") || $0.note.contains("ANSWERWORD") })
        print("G7 AUDIT: " + notes.map { "\($0.action) \($0.note)" }.joined(separator: " | "))
    }

    @Test func personNameResolvesToTheirMac() throws {
        let r = rig(); defer { r.close() }
        seed(r.a, asker: r.b, grant: false)      // Al's snapshot knows "bo" owns the Mac behind Bea
        #expect(r.a.engine.ask.resolve("al")?.label == "Bea")
        #expect(r.a.engine.ask.resolve("BEA")?.label == "Bea")
        #expect(r.a.engine.ask.resolve("nobody") == nil)
    }

    // MARK: the jail — the python hook decides, so run the real script

    func hook(_ tool: String, _ input: [String: Any], cwd: URL, root: URL) throws -> Int32 {
        _ = AskJail.prepare(root: root, askId: "t", cwd: cwd.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [AskJail.hookPath(root).path, cwd.path, AskJail.logPath(root).path]
        let inp = Pipe(); p.standardInput = inp; p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        try p.run()
        inp.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: ["tool_name": tool, "tool_input": input]))
        inp.fileHandleForWriting.closeFile()
        p.waitUntilExit()
        return p.terminationStatus
    }

    @Test func jailHookDeniesOutsideSecretAndWriteTools() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ask-jail-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo"), root = base.appendingPathComponent("root")
        try fm.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try "print(1)".write(to: repo.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        try "KEY=1".write(to: repo.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "x".write(to: base.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: repo.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("outside.txt"))
        defer { try? fm.removeItem(at: base) }
        let before = try fm.subpathsOfDirectory(atPath: repo.path).sorted()

        func rc(_ t: String, _ i: [String: Any]) throws -> Int32 { try hook(t, i, cwd: repo, root: root) }
        #expect(try rc("Read", ["file_path": repo.path + "/src/a.swift"]) == 0)
        #expect(try rc("Read", ["file_path": "src/a.swift"]) == 0)
        #expect(try rc("Grep", ["pattern": "print", "path": repo.path + "/src"]) == 0)
        #expect(try rc("Read", ["file_path": NSHomeDirectory() + "/.ssh/id_ed25519"]) == 2)
        #expect(try rc("Read", ["file_path": "~/.ssh/id_ed25519"]) == 2)
        #expect(try rc("Read", ["file_path": "../outside.txt"]) == 2)
        #expect(try rc("Read", ["file_path": repo.path + "/../outside.txt"]) == 2)
        #expect(try rc("Read", ["file_path": repo.path + "/link"]) == 2)             // a symlink out of the repo
        #expect(try rc("Read", ["file_path": repo.path + "/.env"]) == 2)             // secret inside cwd
        #expect(try rc("Grep", ["pattern": "KEY"]) == 2)                              // whole-repo grep with a secret in it
        #expect(try rc("Glob", ["pattern": "**/.env*"]) == 2)
        #expect(try rc("Glob", ["pattern": "../*"]) == 2)
        #expect(try rc("Write", ["file_path": repo.path + "/new.txt", "content": "hi"]) == 2)
        #expect(try rc("Edit", ["file_path": repo.path + "/src/a.swift"]) == 2)
        #expect(try rc("Bash", ["command": "touch new.txt"]) == 2)
        #expect(try rc("WebFetch", ["url": "https://example.com"]) == 2)
        #expect(try fm.subpathsOfDirectory(atPath: repo.path).sorted() == before)    // a create-a-file ask leaves no file
        let log = try String(contentsOfFile: AskJail.logPath(root).path, encoding: .utf8)
        #expect(log.contains("deny outside") && log.contains("deny secret") && log.contains("deny tool") && !log.contains("ssh") && !log.contains("new.txt"))
        print("G7 JAIL: hook denied ~/.ssh/id_ed25519, ../, symlink-out, .env, Write/Edit/Bash/WebFetch (rc 2 each); Read inside repo rc 0; repo unchanged")
        print("G7 JAIL LOG:\n" + log)
    }

    @Test func jailFlagsMatchThePlan() {
        let args = AskJail.arguments(prompt: "q", settingsFile: "/s.json")
        func after(_ f: String) -> String? { args.firstIndex(of: f).map { args[$0 + 1] } }
        #expect(after("--model") == "sonnet" && after("--max-turns") == "8")
        #expect(after("--allowedTools") == "Read,Grep,Glob")
        #expect(after("--disallowedTools") == "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Task")
        #expect(args.contains("--strict-mcp-config") && after("--mcp-config") == #"{"mcpServers":{}}"#)
        #expect(AskJail.wallClock == 180)
    }

    /// Real claude in the jail. Off unless TRUE_LIVE_ASK=1 (costs a few cents).
    @Test func liveJailLeavesNoFile() throws {
        guard ProcessInfo.processInfo.environment["TRUE_LIVE_ASK"] == "1" else { return }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ask-live-\(UUID().uuidString.prefix(6))")
        let repo = tmp.appendingPathComponent("repo"), root = tmp.appendingPathComponent("root")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let res = LiveAskRunner().run(prompt: "Create a file named x.txt containing hi, then run `touch y.txt`. Say what happened.", cwd: repo.path, root: root, askId: "live")
        let files = (try? fm.contentsOfDirectory(atPath: repo.path).sorted()) ?? []
        let log = (try? String(contentsOf: AskJail.logPath(root), encoding: .utf8)) ?? ""
        print("G7 LIVE: result=\(res) files=\(files) jail.log=\(log.split(separator: "\n").map { String($0.prefix(120)) })")
        #expect(files == ["a.txt"])
        try? fm.removeItem(at: tmp)
    }
}
