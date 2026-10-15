import Foundation

/// `true-peer` — the agents' command-line door to Peers. A tiny python3 client (same family as
/// `truectl`) that speaks one JSON line over the 0600 unix socket `~/.true/peer.sock`.
/// Why a socket and a script (not an HTTP call from the agent): the pairing tokens never leave True —
/// the script only ever sees job ids and results. Why python3: it is already required by the hook
/// forwarder and `truectl`, so there is nothing new to install or break.
enum PeerCLI {
    static func socketPath(_ paths: AgentPaths) -> String { paths.root.appendingPathComponent("peer.sock").path }
    static func scriptPath(_ paths: AgentPaths) -> String { paths.binDir.appendingPathComponent("true-peer").path }

    static func install(paths: AgentPaths) {
        try? FileManager.default.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let path = scriptPath(paths)
        let body = script(socketPath: socketPath(paths))
        if (try? String(contentsOfFile: path, encoding: .utf8)) != body {
            try? body.write(toFile: path, atomically: true, encoding: .utf8)
        }
        chmod(path, 0o755)
    }

    // MARK: request handling (pure given an engine — unit-tested)

    static func handle(_ req: [String: Any], engine: PeerEngine) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        func row(_ j: SentJob) -> [String: Any] {
            var r: [String: Any] = ["jobId": j.jobId, "peer": j.peerLabel, "title": j.title, "status": j.status.rawValue,
                                    "note": j.note, "mode": j.mode.rawValue]
            if let b = j.branch { r["branch"] = b }
            if let s = j.sha { r["sha"] = s }
            return r
        }
        switch req["op"] as? String {
        case "list":
            return ["ok": true, "peers": engine.peerLinks().map { $0.label }]
        case "delegate":
            guard let peer = req["peer"] as? String, let repo = req["repo"] as? String,
                  let title = req["title"] as? String, let brief = req["brief"] as? String else { return fail("peer, repo, title and a brief are required") }
            let mode: PeerMode = (req["background"] as? Bool) == true ? .background : .pane
            switch engine.delegate(peer: peer, repo: repo, title: title, brief: brief, base: (req["base"] as? String) ?? "main",
                                   mode: mode, fromAgent: (req["from"] as? String) ?? "agent") {
            case .success(let id): return ["ok": true, "jobId": id]
            case .failure(let e): return fail("\(e)")
            }
        case "status":
            let id = req["jobId"] as? String
            let rows = engine.status(jobId: id).map(row)
            if let id, rows.isEmpty { return fail("no job \(id)") }
            return ["ok": true, "jobs": rows]
        case "result":
            guard let id = req["jobId"] as? String, let j = engine.result(jobId: id) else { return fail("no such job") }
            var r = row(j)
            r["ok"] = true
            r["result"] = j.result ?? ""
            r["fetch"] = j.branch.map { PeerNaming.fetchCommand(branch: $0) } ?? ""
            return r
        default:
            return fail("unknown op")
        }
    }

    // MARK: client script

    static func script(socketPath: String) -> String {
        #"""
        #!/usr/bin/env python3
        # true-peer — hand work to a paired friend's True (another Mac) and read it back.
        #   true-peer list                          paired peers you can delegate to
        #   true-peer delegate <peer> --repo <path|git url> --title T --brief-file F [--base B] [--background]
        #                                           prints the job id
        #   true-peer status [jobId]                one line per job: id  peer  status  title
        #   true-peer result <jobId>                the friend's result text + the branch to fetch
        # Talks to True over ~/.true/peer.sock; tokens never leave True. Exit 0 ok, 1 refused, 2 True not running.
        import json, os, socket, sys

        DEFAULT_SOCK = __SOCKET__
        USAGE = ("usage: true-peer list | true-peer delegate <peer> --repo R --title T --brief-file F [--base B] [--background] | "
                 "true-peer status [jobId] | true-peer result <jobId>")

        def die(msg, code=1):
            sys.stderr.write(msg + "\n")
            sys.exit(code)

        def call(req):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(60)
            try:
                s.connect(os.environ.get("TRUE_PEER_SOCK") or DEFAULT_SOCK)
            except (FileNotFoundError, ConnectionRefusedError):
                die("True is not running", 2)
            except OSError as e:
                die("cannot reach True: %s" % e, 2)
            s.sendall((json.dumps(req) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
            try:
                r = json.loads(buf.decode().strip() or "{}")
            except ValueError:
                die("bad reply from True", 2)
            if not r.get("ok"):
                die(r.get("error") or "failed")
            return r

        def opts(args, flags):
            out, rest, i = {}, [], 0
            while i < len(args):
                a = args[i]
                if a in flags:
                    out[a] = True
                elif a.startswith("--") and i + 1 < len(args):
                    out[a] = args[i + 1]; i += 1
                else:
                    rest.append(a)
                i += 1
            return out, rest

        def main(argv):
            if not argv:
                die(USAGE)
            cmd, args = argv[0], argv[1:]
            if cmd == "list":
                for p in call({"op": "list"}).get("peers", []):
                    print(p)
            elif cmd == "delegate":
                o, rest = opts(args, {"--background"})
                if len(rest) != 1 or not all(k in o for k in ("--repo", "--title", "--brief-file")):
                    die(USAGE)
                try:
                    brief = open(os.path.expanduser(o["--brief-file"]), encoding="utf-8").read()
                except OSError as e:
                    die("cannot read brief file: %s" % e)
                r = call({"op": "delegate", "peer": rest[0], "repo": o["--repo"], "title": o["--title"], "brief": brief,
                          "base": o.get("--base", "main"), "background": "--background" in o, "from": os.environ.get("TRUE_AGENT") or "agent"})
                print(r["jobId"])
            elif cmd == "status":
                for j in call({"op": "status", "jobId": args[0] if args else None}).get("jobs", []):
                    print("%s  %s  %s  %s" % (j["jobId"], j["peer"], j["status"], j["title"]))
            elif cmd == "result":
                if len(args) != 1:
                    die(USAGE)
                r = call({"op": "result", "jobId": args[0]})
                print("status: %s" % r["status"])
                if r.get("branch"):
                    print("branch: %s\nfetch: %s" % (r["branch"], r.get("fetch", "")))
                print()
                print(r.get("result") or r.get("note") or "")
            else:
                die(USAGE)

        main(sys.argv[1:])
        """#
        .replacingOccurrences(of: "__SOCKET__", with: AgentHooks.pythonString(socketPath))
    }
}

/// The peer socket: `LineSocketServer` + `PeerCLI.handle`. One thread parked in accept(), 0% idle.
/// The engine is fetched lazily (main actor), so this costs nothing until an agent runs `true-peer`.
final class PeerSocket: @unchecked Sendable {
    private let server: LineSocketServer

    init(path: String, engine: @escaping @Sendable () async -> PeerEngine) {
        server = LineSocketServer(path: path) { line, reply in
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                return reply(Self.encode(["ok": false, "error": "bad request"]))
            }
            let boxed = UncheckedBox(obj)
            Task.detached {
                let e = await engine()
                reply(Self.encode(PeerCLI.handle(boxed.value, engine: e)))
            }
        }
    }

    private struct UncheckedBox: @unchecked Sendable { let value: [String: Any]; init(_ v: [String: Any]) { value = v } }

    private static func encode(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o)).map { $0 + Data("\n".utf8) } ?? Data("{\"ok\":false}\n".utf8)
    }

    @discardableResult func start() -> Bool { server.start() }
    func stop() { server.stop() }
}
