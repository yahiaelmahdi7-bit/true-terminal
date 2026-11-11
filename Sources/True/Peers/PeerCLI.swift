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
        ChatCLI.install(paths: paths)
        AllowanceReader.install(paths: paths)
        MissionCLI.install(paths: paths)
    }

    // MARK: request handling (pure given an engine — unit-tested)

    static func handle(_ req: [String: Any], engine: PeerEngine) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        func row(_ j: SentJob) -> [String: Any] {
            var r: [String: Any] = ["jobId": j.jobId, "peer": j.peerLabel, "title": j.title, "status": j.status.rawValue,
                                    "note": j.note, "mode": j.mode.rawValue]
            if PeerStatusText.isWaitingForAccept(j) { r["line"] = PeerStatusText.waitingForAccept(name: j.peerLabel, since: j.created) }
            if let b = j.branch { r["branch"] = b }
            if let s = j.sha { r["sha"] = s }
            return r
        }
        if (req["op"] as? String)?.hasPrefix("mission.") == true { return engine.missionService().handle(req) }
        switch req["op"] as? String {
        case "list":
            return ["ok": true, "peers": engine.peerLinks().map { $0.label }]
        case "delegate":
            guard let peer = req["peer"] as? String,
                  let title = req["title"] as? String, let brief = req["brief"] as? String else { return fail("peer, title and a brief are required") }
            let repo = (req["repo"] as? String) ?? ""
            let dir = (req["dir"] as? String) ?? ""
            let mode: PeerMode = (req["background"] as? Bool) == true ? .background : .pane
            switch engine.delegate(peer: peer, repo: repo, title: title, brief: brief, base: (req["base"] as? String) ?? "main",
                                   mode: mode, fromAgent: (req["from"] as? String) ?? "agent", dir: dir) {
            case .success(let id): return ["ok": true, "jobId": id]
            case .failure(let e): return fail("\(e)")
            }
        case "resend":
            guard let id = req["jobId"] as? String else { return fail("a job id is required") }
            switch engine.resend(jobId: id, dir: req["dir"] as? String) {
            case .success(let new): return ["ok": true, "jobId": new]
            case .failure(let e): return fail("\(e)")
            }
        case "status":
            let id = req["jobId"] as? String
            let rows = engine.status(jobId: id).map(row)
            if let id, rows.isEmpty { return fail("no job \(id)") }
            return ["ok": true, "jobs": rows]
        case "ask":
            guard let who = req["peer"] as? String, let q = req["q"] as? String else { return fail("a person or Mac and a question are required") }
            let id: String
            switch engine.ask.send(to: who, question: q, repo: (req["repo"] as? String) ?? "", re: req["re"] as? String, fromAgent: (req["from"] as? String) ?? "agent") {
            case .success(let v): id = v
            case .failure(let e): return fail("\(e)")
            }
            let deadline = Date().addingTimeInterval(min(240, max(0, (req["wait"] as? Double) ?? 0)))
            while true {
                if let a = engine.ask.answer(id) { return ["ok": true, "askId": id, "answered": true, "status": a.status, "text": a.text] }
                if Date() >= deadline { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            return ["ok": true, "askId": id, "answered": false]
        case "result":
            if let id = req["jobId"] as? String, engine.result(jobId: id) == nil {
                guard let a = engine.ask.answer(id) else { return (engine.ask.isPending(id) ? ["ok": true, "status": "waiting", "result": "No answer yet.", "note": "No answer yet."] : fail("no such job")) }
                return ["ok": true, "status": a.status, "result": a.text, "fetch": ""]
            }
            guard let id = req["jobId"] as? String, let j = engine.result(jobId: id) else { return fail("no such job") }
            var r = row(j)
            r["ok"] = true
            r["result"] = j.result ?? ""
            r["fetch"] = j.branch.map { PeerNaming.fetchCommand(branch: $0) } ?? ""
            return r
        case "say":
            guard let id = req["jobId"] as? String, let text = req["text"] as? String else { return fail("a job id and some text are required") }
            switch engine.say(jobId: id, text: text, fromAgent: (req["from"] as? String) ?? "agent") {
            case .success: return ["ok": true]
            case .failure(let e): return fail("\(e)")
            }
        case "stop":
            guard let id = req["jobId"] as? String else { return fail("a job id is required") }
            switch engine.stopJob(jobId: id) {
            case .success: return ["ok": true]
            case .failure(let e): return fail("\(e)")
            }
        case "resume":
            guard let id = req["jobId"] as? String else { return fail("a job id is required") }
            switch engine.resumeJob(jobId: id) {
            case .success: return ["ok": true]
            case .failure(let e): return fail("\(e)")
            }
        case "invite":
            return ["ok": true, "code": engine.invite()]
        case "join":
            guard let code = req["code"] as? String, let name = req["name"] as? String else { return fail("a code and --name are required") }
            let link: PeerLink
            switch engine.pairWithInvite(code, label: name) {
            case .success(let l): link = l
            case .failure(.invalid(let m)): return fail(m == "That invite is from this Mac" ? "That code is yours. Send it to the other person to enter on their Mac." : m)
            }
            let deadline = Date().addingTimeInterval(min(60, max(0, (req["wait"] as? Double) ?? 15)))
            while true {
                switch engine.joinState(mailbox: link.mailboxId) {
                case .paired(let who): return ["ok": true, "paired": true, "message": "Paired with \(who)."]
                case .refused(let why): return fail(why)
                case .waiting: break
                }
                if Date() >= deadline { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            return ["ok": true, "paired": false, "message": "Sent. Waiting for the other side to answer. Run true-peer doctor to check."]
        case "doctor":
            return ["ok": true, "lines": engine.doctorLines()]
        case "mesh":
            let run = engine.meshStart()
            let deadline = Date().addingTimeInterval(min(40, max(0, (req["wait"] as? Double) ?? 20)))
            while !engine.meshReport(run).done && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            return ["ok": true, "lines": engine.meshReport(run).lines]
        case "lanes":
            if let n = req["n"] as? Int { PeerSettings.lanes = max(1, min(4, n)) }
            return ["ok": true, "lanes": PeerSettings.lanes]
        case "offer":
            guard let peer = req["peer"] as? String, let url = req["url"] as? String else { return fail("a peer and a repo URL are required") }
            switch engine.offer(peer: peer, url: url, name: (req["name"] as? String) ?? "", note: (req["note"] as? String) ?? "") {
            case .success(let id): return ["ok": true, "offerId": id]
            case .failure(let e): return fail("\(e)")
            }
        case "shares":
            return ["ok": true, "shares": engine.shares().map { ["peer": $0.peer, "slug": $0.repo.slug, "url": $0.repo.url, "path": $0.repo.path] }]
        case "dirs":      // the directories this Mac lets friends work in (`peer.allowedDirs`), each with its real path
            return ["ok": true, "dirs": PeerSettings.allowedDirs.map { ["path": $0, "real": PeerDirs.realDirectory($0) ?? $0] }]
        case "stats":
            return ["ok": true, "line": PeerLogic.statsLine(engine.sentJobs(), days: (req["days"] as? Int) ?? 7, last: req["last"] as? Int)]
        case "tail":
            guard let id = req["jobId"] as? String, !engine.status(jobId: id).isEmpty else { return fail("no such job") }
            engine.watchJob(jobId: id)      // a lease: the peer streams while someone is looking
            return ["ok": true, "path": engine.eventsURL(id).path]
        default:
            if (req["op"] as? String)?.hasPrefix("chat.") == true { return ChatCLI.handle(req, engine: engine) }
            return fail("unknown op")
        }
    }

    // MARK: client script

    static func script(socketPath: String) -> String {
        #"""
        #!/usr/bin/env python3
        # true-peer — hand work to a paired friend's True (another Mac) and read it back.
        #   true-peer list                          paired peers you can delegate to
        #   true-peer delegate <peer> [--repo <path|git url>] --title T --brief-file F [--base B] [--background]
        #                                           prints the job id; no --repo = a job with no project (text result only)
        #   true-peer resend <jobId> [--dir <path>]  send a finished job again (new job) from its saved brief
        #   true-peer delegate <peer> --dir <path> --title T --brief-file F      work in a directory the friend allows (not with --repo)
        #   true-peer offer <url> [--name N] [--note TEXT] <peer>   offer a repo; the friend must accept it before anything is cloned
        #   true-peer shares                        accepted shared repos: slug  peer  url  path
        #   true-peer invite                        prints a one-use code (24 h) to give to one person
        #   true-peer join <code> --name <label>    redeem a code; <label> is what you call them
        #   true-peer doctor                        why a paired friend isn't getting anything: link, last fetch, outbox, drops, builds
        #   true-peer mesh                          ask every paired Mac, print who can reach whom and how fast (both ways)
        #   true-peer ask <person|mac> "<question>" [--repo R] [--wait 120] [--re <askId>]
        #                                           a short read-only question to a partner's Claude; prints the answer (--wait) or the ask id
        #   true-peer say <jobId> <text|->          send a follow-up into the friend's running job (- = read stdin)
        #   true-peer tail <jobId> [-f] [-n N]      the job's activity lines; -f keeps following until the job ends
        #   true-peer stop <jobId>                  ask the friend's True to end the job
        #   true-peer status [jobId]                one line per job: id  peer  status  title
        #   true-peer result <jobId>                the friend's result text + the branch to fetch
        # Paths you give <peer> are paths on <peer>'s Mac. To send your own files use `--with` or `put`.
        # Talks to True over ~/.true/peer.sock; tokens never leave True. Exit 0 ok, 1 refused, 2 True not running.
        import json, os, select, socket, sys, time

        DEFAULT_SOCK = __SOCKET__
        USAGE = ("usage: true-peer invite | true-peer join <code> --name <label> | true-peer doctor | true-peer mesh | true-peer mission start <file.md> | status <id> | cancel <id> | approve <id> <job title> | true-peer lanes [1-4] | true-peer resume <jobId> | true-peer list | true-peer delegate <peer> [--repo R] --title T --brief-file F [--base B] [--background] | "
                 "true-peer delegate <peer> --dir D --title T --brief-file F | true-peer resend <jobId> [--dir D] | true-peer say <jobId> <text|-> | "
                 "true-peer offer <url> [--name N] [--note T] <peer> | true-peer shares | true-peer tail <jobId> [-f] [-n N] | true-peer stop <jobId> | true-peer status [jobId] | true-peer stats [--days N | --last N] | true-peer result <jobId> | true-peer ask <person|mac> \"<question>\" [--repo R] [--wait 120] [--re ID]")

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

        def show(line):
            try:
                it = json.loads(line)
            except ValueError:
                return
            print("%s  %-9s %s" % (time.strftime("%H:%M:%S", time.localtime(it.get("t", 0))), it.get("kind", ""), it.get("text", "")))
            sys.stdout.flush()

        def tail(path, job, follow, n):
            try:
                f = open(path, "rb")
            except OSError:
                f = None
            if f:
                for line in f.read().splitlines()[-n:]:
                    show(line)
            if not follow:
                return
            # follow without polling: wait on a kqueue for the events file to grow, and stop once the job has ended
            kq = select.kqueue()
            while f is None:
                try:
                    f = open(path, "rb"); f.seek(0, 2)
                except OSError:
                    rows = call({"op": "status", "jobId": job}).get("jobs", [])
                    if rows and rows[0]["status"] in ("done", "failed", "declined"):
                        return
                    time.sleep(1)
            ev = select.kevent(f.fileno(), filter=select.KQ_FILTER_VNODE, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                               fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)
            while True:
                for line in f.read().splitlines():
                    show(line)
                rows = call({"op": "status", "jobId": job}).get("jobs", [])
                if rows and rows[0]["status"] in ("done", "failed", "declined"):
                    for line in f.read().splitlines():
                        show(line)
                    return
                kq.control([ev], 1, 30)

        def main(argv):
            if not argv:
                die(USAGE)
            if argv[0] in ("help", "-h", "--help"):
                print(USAGE)
                return
            cmd, args = argv[0], argv[1:]
            if cmd == "mission":
                if not args or args[0] not in ("start", "status", "cancel", "approve"):
                    die("usage: true-peer mission start <file.md> | status <id> | cancel <id> | approve <id> <job title>")
                verb, values = args[0], args[1:]
                if len(values) != (2 if verb == "approve" else 1):
                    die("choose a mission file or id, and a job title for approve")
                req = {"op": "mission." + verb}
                if verb == "start":
                    try:
                        req["source"] = open(os.path.expanduser(values[0]), encoding="utf-8").read()
                    except OSError as e:
                        die("cannot read mission file: %s" % e)
                else:
                    req["missionId"] = values[0]
                    if verb == "approve":
                        req["job"] = values[1]
                r = call(req)
                if verb == "start":
                    print(r["missionId"])
                elif verb == "status":
                    for j in r.get("jobs", []):
                        print("%s  %s  %s  %s" % (j["title"], j["mac"], j["state"], j["reason"]))
                else:
                    print("Approved" if verb == "approve" else "Canceled")
            elif cmd == "invite":
                print(call({"op": "invite"})["code"])
            elif cmd == "join":
                o, rest = opts(args, set())
                if len(rest) != 1 or not o.get("--name"):
                    die("usage: true-peer join <code> --name <label>")
                print(call({"op": "join", "code": rest[0], "name": o["--name"]})["message"])
            elif cmd in ("doctor", "mesh"):
                for line in call({"op": cmd}).get("lines", []):
                    print(line)
            elif cmd == "stats":
                o, rest = opts(args, set())
                req = {"op": "stats"}
                try:
                    if o.get("--days"): req["days"] = int(o["--days"])
                    if o.get("--last"): req["last"] = int(o["--last"])
                except ValueError:
                    die("usage: true-peer stats [--days N | --last N]")
                print(call(req)["line"])
            elif cmd == "list":
                for p in call({"op": "list"}).get("peers", []):
                    print(p)
            elif cmd == "delegate":
                o, rest = opts(args, {"--background"})
                if len(rest) != 1 or not all(k in o for k in ("--title", "--brief-file")):
                    die(USAGE)
                if o.get("--repo") and o.get("--dir"):
                    die("use --repo or --dir, not both")
                try:
                    brief = open(os.path.expanduser(o["--brief-file"]), encoding="utf-8").read()
                except OSError as e:
                    die("cannot read brief file: %s" % e)
                r = call({"op": "delegate", "peer": rest[0], "repo": o.get("--repo", ""), "dir": o.get("--dir", ""), "title": o["--title"], "brief": brief,
                          "base": o.get("--base", "main"), "background": "--background" in o, "from": os.environ.get("TRUE_AGENT") or "agent"})
                print(r["jobId"])
            elif cmd == "resend":
                o, rest = opts(args, set())
                if len(rest) != 1:
                    die(USAGE)
                print(call({"op": "resend", "jobId": rest[0], "dir": o.get("--dir", "")})["jobId"])
            elif cmd == "ask":
                o, rest = opts(args, set())
                if len(rest) != 2:
                    die(USAGE)
                try:
                    wait = float(o.get("--wait", 0))
                except ValueError:
                    die(USAGE)
                r = call({"op": "ask", "peer": rest[0], "q": rest[1], "repo": o.get("--repo", ""), "re": o.get("--re", ""), "wait": wait,
                          "from": os.environ.get("TRUE_AGENT") or "agent"})
                if r.get("answered"):
                    print(r["text"])
                    if r.get("status") != "answered":
                        sys.exit(1)
                else:
                    print(r["askId"])
            elif cmd == "offer":
                o, rest = opts(args, set())
                if len(rest) != 2:
                    die(USAGE)
                r = call({"op": "offer", "url": rest[0], "peer": rest[1], "name": o.get("--name", ""), "note": o.get("--note", "")})
                print(r["offerId"])
            elif cmd == "shares":
                for s in call({"op": "shares"}).get("shares", []):
                    print("%s  %s  %s  %s" % (s["slug"], s["peer"], s["url"], s["path"]))
            elif cmd == "say":
                if len(args) < 2:
                    die(USAGE)
                text = sys.stdin.read() if args[1] == "-" else " ".join(args[1:])
                call({"op": "say", "jobId": args[0], "text": text.strip(), "from": os.environ.get("TRUE_AGENT") or "agent"})
            elif cmd == "stop":
                if len(args) != 1:
                    die(USAGE)
                call({"op": "stop", "jobId": args[0]})
            elif cmd == "resume":
                if len(args) != 1:
                    die(USAGE)
                call({"op": "resume", "jobId": args[0]})
            elif cmd == "lanes":
                if len(args) > 1 or (args and not args[0].isdigit()):
                    die(USAGE)
                print(call({"op": "lanes", **({"n": int(args[0])} if args else {})}).get("lanes"))
            elif cmd == "tail":
                o, rest = opts(args, {"-f"})
                if len(rest) != 1:
                    die(USAGE)
                tail(call({"op": "tail", "jobId": rest[0]})["path"], rest[0], "-f" in o, int(o.get("-n", 20)))
            elif cmd == "status":
                for j in call({"op": "status", "jobId": args[0] if args else None}).get("jobs", []):
                    print("%s  %s  %s  %s" % (j["jobId"], j["peer"], j.get("line") or j["status"], j["title"]))
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
