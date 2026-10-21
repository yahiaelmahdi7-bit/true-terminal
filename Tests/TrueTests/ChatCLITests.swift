import Testing
import Foundation
@testable import True

@Suite(.serialized) struct ChatCLITests {
    func rig() -> (a: PeerSide, b: PeerSide, bus: ChatBus) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        _ = b.attachChat()
        return (a, b, a.attachChat())
    }
    func ok(_ r: [String: Any]) -> Bool { r["ok"] as? Bool == true }
    func call(_ side: PeerSide, _ op: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        PeerCLI.handle(["op": op].merging(extra) { $1 }, engine: side.engine)
    }

    @Test func joinSendTailListLeaveEndToEnd() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        #expect(ok(call(r.a, "chat.join", ["channel": "#sam", "from": "pm"])))
        #expect(ok(call(r.a, "chat.join", ["channel": "#bea", "from": "pm"])))
        r.a.sink.awake = ["pm", "dev"]
        let s = call(r.a, "chat.send", ["channel": "#here", "text": "standup", "from": "dev"])
        #expect(ok(s) && s["id"] is String)
        #expect(r.a.sink.lines("pm") == ["[#here dev@al] standup"] && r.a.sink.lines("dev").isEmpty)
        // human default sender
        _ = call(r.a, "chat.send", ["channel": "#here", "text": "hi from a shell"])
        #expect(r.a.sink.lines("pm").last == "[#here human@al] hi from a shell")
        // tail returns the messages + the file path for -f
        let t = call(r.a, "chat.tail", ["channel": "#here", "n": 1])
        #expect((t["messages"] as? [[String: Any]])?.map { $0["text"] as? String } == ["hi from a shell"])
        #expect((t["path"] as? String)?.hasSuffix("chat/here.jsonl") == true)
        // list
        let l = call(r.a, "chat.list", ["from": "pm"])
        let names = (l["channels"] as? [[String: Any]])?.compactMap { $0["channel"] as? String } ?? []
        #expect(names.contains("#here") && names.contains("#bea"))
        #expect((l["joined"] as? [String])?.sorted() == ["#bea", "#sam"])
        #expect((l["presence"] as? [[String: Any]])?.contains { $0["who"] as? String == "human@al" } == true)
        // leave
        #expect((call(r.a, "chat.leave", ["channel": "#sam", "from": "pm"])["channels"] as? [String]) == ["#bea"])
    }

    @Test func sendToAPeerChannelCrossesTheRelay() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        r.b.engine.chat?.join("dev", "#al")
        #expect(ok(call(r.a, "chat.send", ["channel": "#bea", "text": "over the wire", "from": "pm"])))
        r.a.engine.flushChat(); settle(r.a, r.b)
        #expect(r.b.sink.lines("dev") == ["[#al pm@al] over the wire"])
    }

    @Test func refusalsAreReadable() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        #expect(!ok(call(r.a, "chat.send", ["channel": "nope", "text": "x"])))
        #expect(!ok(call(r.a, "chat.send", ["channel": "#here"])))
        #expect(!ok(call(r.a, "chat.send", ["channel": "@dev@nobody", "text": "x"])))
        #expect(!ok(call(r.a, "chat.join", ["channel": "@dev"])))
        #expect(!ok(call(r.a, "chat.tail", ["channel": "wat"])))
        #expect(!ok(call(r.a, "chat.bogus")))
        let bare = PeerSide("Cy", relay: FakeRelay(), clock: Clock()); defer { bare.close() }     // no bus attached
        #expect(call(bare, "chat.list")["error"] as? String == "chat isn't running")
    }

    @Test func theClientScriptIsValidPythonAndNamesEveryOp() throws {
        let src = ChatCLI.script(socketPath: "/tmp/x.sock")
        for word in ["send", "join", "leave", "tail", "list", "chat.send", "chat.tail", "chat.list", "TRUE_AGENT"] {
            #expect(src.contains(word))
        }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("true-chat-\(UUID().uuidString).py")
        try src.write(to: f, atomically: true, encoding: .utf8); defer { try? FileManager.default.removeItem(at: f) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-I", "-m", "py_compile", f.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func sendCarriesReAndTailShowsIt() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let s = call(r.a, "chat.send", ["channel": "#here", "text": "42", "from": "dev", "re": "q-9"])
        #expect(ok(s))
        let t = call(r.a, "chat.tail", ["channel": "#here", "n": 1])
        #expect((t["messages"] as? [[String: Any]])?.first?["re"] as? String == "q-9")
    }

    // MARK: Run 33 — chat.ask / true-ask

    /// Run the shipped script's `wait_answer(path, id, timeout)` under python3; prints the text or "NONE".
    func waitAnswer(path: String, id: String, timeout: Int) -> String {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("true-ask-\(UUID().uuidString).py")
        try? ChatCLI.script(socketPath: "/nonexistent.sock").write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", "import runpy,sys; m=runpy.run_path(sys.argv[1], run_name='lib'); r=m['wait_answer'](sys.argv[2], sys.argv[3], int(sys.argv[4])); print('NONE' if r is None else r)",
                       script.path, path, id, String(timeout)]
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func askReturnsOnAReMatchAndTimesOutOtherwise() async {
        let r = rig(); defer { r.a.close(); r.b.close() }
        let brain = FakeBrain()
        let oracle = Oracle(engine: r.a.engine, bus: r.bus, brain: brain)
        let res = call(r.a, "chat.ask", ["text": "what is Run 33?", "from": "human"])
        #expect(ok(res))
        let id = res["id"] as! String, path = res["path"] as! String
        await oracle.waitIdle()
        #expect(brain.asked == [[]])                                    // local ask: unrestricted
        #expect(waitAnswer(path: path, id: id, timeout: 5).hasPrefix("director.plan() builds the plan."))
        #expect(waitAnswer(path: path, id: "someone-else", timeout: 1) == "NONE")
    }

    @Test func askRefusesAnUnknownTarget() {
        let r = rig(); defer { r.a.close(); r.b.close() }
        #expect(!ok(call(r.a, "chat.ask", ["text": "q", "to": "@ghost", "from": "human"])))          // no such seat here
        #expect(!ok(call(r.a, "chat.ask", ["text": "q", "to": "@oracle@nobody", "from": "human"])))  // no such peer
        #expect(!ok(call(r.a, "chat.ask", ["text": "  ", "from": "human"])))
        #expect(!ok(call(r.a, "chat.ask", ["text": "q", "to": "#here", "from": "human"])))
    }

    @Test func aPlainShellOnAPeersMacGetsTheAnswerBack() async {
        let o = OracleTests().rig(); defer { o.a.close(); o.b.close() }
        let res = PeerCLI.handle(["op": "chat.ask", "text": "where is it?", "to": "@oracle@bea", "from": "human"], engine: o.a.engine)
        #expect(ok(res))
        o.a.engine.flushChat(); settle(o.a, o.b)
        await o.oracle.waitIdle()
        o.b.engine.flushChat(); settle(o.a, o.b)
        #expect(o.abus.tail("@human").last?.re == res["id"] as? String)                  // "human" isn't a pane; chat.ask made it a seat
        #expect(waitAnswer(path: res["path"] as! String, id: res["id"] as! String, timeout: 5).contains("Sources: finance-director-os/SPEC.md"))
    }

    @Test func theInstalledScriptsAreOneBodyTwoNames() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("true-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(root: root)
        ChatCLI.install(paths: paths)
        #expect((try? String(contentsOfFile: ChatCLI.askScriptPath(paths), encoding: .utf8)) == (try? String(contentsOfFile: ChatCLI.scriptPath(paths), encoding: .utf8)))
        #expect(FileManager.default.isExecutableFile(atPath: ChatCLI.askScriptPath(paths)))
    }
}
