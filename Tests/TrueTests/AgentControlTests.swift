import Testing
import Foundation
import Darwin
@testable import True

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("true-control-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct ControlRequestTests {
    func line(_ s: String) -> Data { Data(s.utf8) }

    @Test func parsesStatusAndSummon() {
        #expect(ControlRequest.parse(line(#"{"op":"status"}"#)) == .status)
        #expect(ControlRequest.parse(line(#"{"op":"summon","agent":"lead-x","message":"hi","from":"designer"}"#))
                == .summon(agent: "lead-x", message: "hi", from: "designer"))
        #expect(ControlRequest.parse(line(#"{"op":"summon","agent":"lead-x","message":"hi"}"#))
                == .summon(agent: "lead-x", message: "hi", from: nil))
    }

    @Test func malformedIsNil() {
        for bad in ["", "nope", #"{"op":"dance"}"#, #"{"op":"summon","agent":"x"}"#, #"{"agent":"x"}"#, "[1]"] {
            #expect(ControlRequest.parse(line(bad)) == nil, "\(bad)")
        }
    }

    @Test func responseIsOneLineAndDecodesBack() throws {
        let r = ControlResponse(ok: true, outcome: "landed",
                                agents: [.init(name: "lead-x", role: "lead", repo: "x", status: "asleep", awake: false)])
        let data = r.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n") && text.dropLast().allSatisfy { $0 != "\n" })
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["ok"] as? Bool == true && obj["outcome"] as? String == "landed" && obj["error"] == nil)
        #expect((obj["agents"] as? [[String: Any]])?.first?["name"] as? String == "lead-x")
        #expect(String(decoding: ControlResponse.failure("bad request").encoded(), as: UTF8.self)
                == "{\"error\":\"bad request\",\"ok\":false}\n")
    }
}

@Suite struct ControlPolicyTests {
    let g = Agent(name: "designer", role: .global, repo: "", team: ["lead-a"])
    let la = Agent(name: "lead-a", role: .lead, repo: "/p/a", team: ["helper-1-a"])
    let lb = Agent(name: "lead-b", role: .lead, repo: "/p/b")
    let ha = Agent(name: "helper-1-a", role: .helper, repo: "/p/a")
    let hb = Agent(name: "helper-1-b", role: .helper, repo: "/p/b")
    var all: [Agent] { [g, la, lb, ha, hb] }

    @Test func humanReachesAnyone() {
        for t in all {
            #expect(AgentControl.mayReach(caller: nil, target: t, agents: all))
            #expect(AgentControl.mayReach(caller: "not-an-agent", target: t, agents: all))
        }
    }

    @Test func globalSummonsOnlyItsLeads() {
        #expect(AgentControl.mayReach(caller: "designer", target: la, agents: all))
        #expect(!AgentControl.mayReach(caller: "designer", target: lb, agents: all))
        #expect(!AgentControl.mayReach(caller: "designer", target: ha, agents: all))
        var sneaky = g; sneaky.team = ["helper-1-a"]                 // a hand-edited team never widens the rule
        #expect(!AgentControl.mayReach(caller: "designer", target: ha, agents: [sneaky, la, ha]))
    }

    @Test func leadSummonsOnlyItsHelpers() {
        #expect(AgentControl.mayReach(caller: "lead-a", target: ha, agents: all))
        #expect(!AgentControl.mayReach(caller: "lead-a", target: hb, agents: all))
        #expect(!AgentControl.mayReach(caller: "lead-a", target: lb, agents: all))
    }

    @Test func helperSummonsNoOne() {
        for t in all { #expect(!AgentControl.mayReach(caller: "helper-1-a", target: t, agents: all)) }
    }

    @Test func deliveredTextNamesTheSummoner() {
        #expect(AgentControl.deliveredText(message: "do it", from: nil) == "do it")
        let t = AgentControl.deliveredText(message: "do it", from: "designer")
        #expect(t.hasPrefix("do it\n\n(Summoned by `designer`."))
        #expect(t.contains("reply to `designer` with the SendMessage tool"))
    }

    @Test func truectlScriptCarriesSocketAndSubcommands() {
        let s = AgentControl.truectl(socketPath: "/tmp/x/control.sock")
        #expect(s.hasPrefix("#!/usr/bin/env python3") && s.contains("\"/tmp/x/control.sock\""))
        #expect(s.contains("\"status\"") && s.contains("\"summon\"") && s.contains("TRUE_AGENT"))
        #expect(!s.contains("__SOCKET__"))
    }

    @Test func pathsLiveUnderTheRoot() {
        let p = AgentPaths(root: URL(fileURLWithPath: "/tmp/r"))
        #expect(p.controlSocketPath == "/tmp/r/control.sock" && p.truectlPath == "/tmp/r/bin/truectl")
    }
}

private func connectAndAsk(_ sock: String, _ request: String) -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        _ = sock.utf8CString.withUnsafeBytes { memcpy(dst.baseAddress, $0.baseAddress, min($0.count, dst.count)) }
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return "connect failed" }
    let out = Array((request + "\n").utf8)
    _ = write(fd, out, out.count)
    var got = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while !got.contains(0x0A) {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        got.append(contentsOf: buf[0..<n])
    }
    return String(decoding: got, as: UTF8.self)
}

private func runTruectl(script: String, sock: String, from: String?, args: [String]) -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", script] + args
    var env = ["TRUE_CONTROL_SOCK": sock, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
    if let from { env["TRUE_AGENT"] = from }
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    try? p.run()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

/// Real socket, real registry (temp store, no panes), real `truectl` script. Never launches claude:
/// the only summons made are refused or unknown, and neither reaches `wake`.
@Suite @MainActor struct ControlSocketTests {
    func fixture() -> (AgentRegistry, AgentControlSocket, String, AgentPaths) {
        let dir = tempDir()
        let store = AgentStore(url: dir.appendingPathComponent("agents.json"))
        store.save([Agent(name: "designer", role: .global, repo: "", team: ["lead-a"]),
                    Agent(name: "lead-a", role: .lead, repo: "/p/a"),
                    Agent(name: "lead-b", role: .lead, repo: "/p/b")])
        let ws = WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("workspace.json")))
        let paths = AgentPaths(root: dir)
        let reg = AgentRegistry(store: store, paths: paths, workspace: ws, claudeDir: dir)
        let sock = "/tmp/tc-\(UUID().uuidString.prefix(8)).sock"
        // A hub over an empty temp ~/.claude: the tests never read the real sessions or builders.
        return (reg, AgentControlSocket(path: sock, registry: reg, hub: HubStore(claudeDir: dir)), sock, paths)
    }

    @Test func statusAndErrorsOverTheSocket() async throws {
        let (_, server, sock, _) = fixture()
        #expect(server.start())
        defer { server.stop() }

        let status = await Task.detached { connectAndAsk(sock, #"{"op":"status"}"#) }.value
        let obj = try #require(JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any])
        #expect(obj["ok"] as? Bool == true)
        let rows = try #require(obj["agents"] as? [[String: Any]])
        #expect(rows.compactMap { $0["name"] as? String } == ["designer", "lead-a", "lead-b"])
        #expect(rows.allSatisfy { $0["awake"] as? Bool == false && $0["status"] as? String == "asleep" })
        #expect(rows[0]["repo"] as? String == "Global" && rows[0]["role"] as? String == "global")

        let bad = await Task.detached { connectAndAsk(sock, "garbage") }.value
        #expect(bad == "{\"error\":\"bad request\",\"ok\":false}\n")
        let ghost = await Task.detached { connectAndAsk(sock, #"{"op":"summon","agent":"ghost","message":"hi"}"#) }.value
        #expect(ghost.contains("no agent named ghost") && ghost.contains("\"ok\":false"))
        let refused = await Task.detached {
            connectAndAsk(sock, #"{"op":"summon","agent":"lead-b","message":"hi","from":"designer"}"#)
        }.value
        #expect(refused.contains("designer may not summon lead-b") && refused.contains("\"ok\":false"))
    }

    @Test func truectlSpeaksTheProtocol() async throws {
        let (_, server, sock, paths) = fixture()
        #expect(server.start())
        defer { server.stop() }
        let a = Agent(name: "lead-a", role: .lead, repo: "/tmp")
        AgentHooks.install(for: a, all: [a], paths: paths)
        #expect(FileManager.default.isExecutableFile(atPath: paths.truectlPath))
        let script = paths.truectlPath

        let st = await Task.detached { runTruectl(script: script, sock: sock, from: nil, args: ["status"]) }.value
        #expect(st.0 == 0 && st.2.isEmpty)
        #expect(st.1.split(separator: "\n").map(String.init) == [
            "designer  global  asleep  asleep  Global", "lead-a  lead  asleep  asleep  a", "lead-b  lead  asleep  asleep  b"])

        let no = await Task.detached {
            runTruectl(script: script, sock: sock, from: "designer", args: ["summon", "lead-b", "hello", "there"])
        }.value
        #expect(no.0 == 1 && no.1.isEmpty && no.2.contains("may not summon lead-b"))

        let usage = await Task.detached { runTruectl(script: script, sock: sock, from: nil, args: []) }.value
        #expect(usage.0 == 1 && usage.1.isEmpty && usage.2.contains("usage"))

        let down = await Task.detached {
            runTruectl(script: script, sock: "/tmp/tc-none-\(UUID().uuidString.prefix(6)).sock", from: nil, args: ["status"])
        }.value
        #expect(down.0 == 2 && down.1.isEmpty && down.2.contains("True is not running"))
    }
}
