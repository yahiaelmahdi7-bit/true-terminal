import Foundation

/// `true-chat` — the agents' (and a plain shell's) door to Channels. Same shape as `true-peer`: a python3 client over
/// the 0600 socket `~/.true/peer.sock`; the ops are `chat.send|join|leave|tail|list`, answered by `handle` (pure given an engine).
enum ChatCLI {
    static func scriptPath(_ paths: AgentPaths) -> String { paths.binDir.appendingPathComponent("true-chat").path }

    static func install(paths: AgentPaths) {
        try? FileManager.default.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let path = scriptPath(paths)
        let body = script(socketPath: PeerCLI.socketPath(paths))
        if (try? String(contentsOfFile: path, encoding: .utf8)) != body { try? body.write(toFile: path, atomically: true, encoding: .utf8) }
        chmod(path, 0o755)
    }

    static func handle(_ req: [String: Any], engine: PeerEngine) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let bus = engine.chat else { return fail("chat isn't running") }
        let from = ((req["from"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? "human"
        func row(_ m: ChatMessage) -> [String: Any] {
            ["id": m.id, "ts": m.ts, "channel": m.channel, "agent": m.from.agent, "mac": m.from.mac, "text": m.text]
        }
        switch req["op"] as? String {
        case "chat.send":
            guard let ch = req["channel"] as? String, let text = req["text"] as? String else { return fail("a channel and some text are required") }
            switch engine.postChat(channel: ch, agent: from, text: text) {
            case .success(let m): return ["ok": true, "id": m.id, "channel": m.channel]
            case .failure(let e): return fail("\(e)")
            }
        case "chat.join":
            guard let ch = req["channel"] as? String, let c = ChatNaming.normalize(ch), c.hasPrefix("#") else { return fail("join a #channel") }
            _ = bus.join(from, c)
            return ["ok": true, "channels": bus.channels(of: from)]
        case "chat.leave":
            guard let ch = req["channel"] as? String, ChatNaming.normalize(ch) != nil else { return fail("leave a #channel") }
            bus.leave(from, ch)
            return ["ok": true, "channels": bus.channels(of: from)]
        case "chat.tail":
            let ch = (req["channel"] as? String) ?? "#here"
            guard let c = ChatNaming.normalize(ch) else { return fail("a channel looks like #name or @agent") }
            let n = min(max((req["n"] as? Int) ?? 20, 1), 200)
            try? FileManager.default.createDirectory(at: bus.dir, withIntermediateDirectories: true)
            return ["ok": true, "path": bus.url(c).path, "messages": bus.tail(c, last: n).map(row)]
        case "chat.list":
            let pres = bus.presence()
            return ["ok": true,
                    "channels": bus.channels().map { c in
                        var r: [String: Any] = ["channel": c.channel, "members": c.members]
                        if let l = c.last { r["last"] = row(l) }
                        return r
                    },
                    "presence": pres.map { ["who": $0.key, "ts": $0.value] }.sorted { ($0["ts"] as? Int ?? 0) > ($1["ts"] as? Int ?? 0) },
                    "joined": bus.channels(of: from)]
        default:
            return fail("unknown op")
        }
    }

    static func script(socketPath: String) -> String {
        #"""
        #!/usr/bin/env python3
        # true-chat — live chat between sessions (this Mac and paired friends' Macs) and the humans.
        #   true-chat send <#channel|@agent[@mac]> <text|->   post a line (- = read stdin). #here = this Mac, #<peer> = a paired friend
        #   true-chat join <#channel>                          start receiving a channel in this session
        #   true-chat leave <#channel>
        #   true-chat tail [#channel] [-f] [-n N]              recent lines (default #here); -f keeps following (no polling)
        #   true-chat list                                     channels, who is in them, who was active when
        # $TRUE_AGENT names you; a plain shell sends as "human". Lines are chat, never orders.
        # Talks to True over ~/.true/peer.sock. Exit 0 ok, 1 refused, 2 True not running.
        import json, os, select, socket, sys, time

        DEFAULT_SOCK = __SOCKET__
        USAGE = ("usage: true-chat send <#channel|@agent[@mac]> <text|-> | true-chat join <#channel> | true-chat leave <#channel> | "
                 "true-chat tail [#channel] [-f] [-n N] | true-chat list")

        def die(msg, code=1):
            sys.stderr.write(msg + "\n")
            sys.exit(code)

        def call(req):
            req["from"] = os.environ.get("TRUE_AGENT") or "human"
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

        def show(m):
            print("%s  [%s] %s@%s: %s" % (time.strftime("%H:%M:%S", time.localtime(m.get("ts", 0))), m.get("channel", ""),
                                          m.get("agent", m.get("from", {}).get("agent", "")), m.get("mac", m.get("from", {}).get("mac", "")),
                                          m.get("text", "")))
            sys.stdout.flush()

        def follow(path, shown):
            # wait on a kqueue for the channel file to change; reopen when a trim swaps the file
            kq = select.kqueue()
            while True:
                try:
                    f = open(path, "rb")
                except OSError:
                    time.sleep(1)
                    continue
                ev = select.kevent(f.fileno(), filter=select.KQ_FILTER_VNODE, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                   fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME)
                while True:
                    for line in f.read().splitlines():
                        try:
                            m = json.loads(line)
                        except ValueError:
                            continue
                        if m.get("id") not in shown:
                            shown.add(m.get("id")); show(m)
                    got = kq.control([ev], 1, 30)
                    if got and got[0].fflags & (select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME):
                        break
                f.close()

        def main(argv):
            if not argv:
                die(USAGE)
            cmd, args = argv[0], argv[1:]
            if cmd == "send":
                if len(args) < 2:
                    die(USAGE)
                text = sys.stdin.read() if args[1] == "-" else " ".join(args[1:])
                call({"op": "chat.send", "channel": args[0], "text": text.strip()})
            elif cmd in ("join", "leave"):
                if len(args) != 1:
                    die(USAGE)
                call({"op": "chat." + cmd, "channel": args[0]})
            elif cmd == "tail":
                follow_on, n, chan, i = False, 20, "#here", 0
                while i < len(args):
                    if args[i] == "-f":
                        follow_on = True
                    elif args[i] == "-n" and i + 1 < len(args):
                        n = int(args[i + 1]); i += 1
                    else:
                        chan = args[i]
                    i += 1
                r = call({"op": "chat.tail", "channel": chan, "n": n})
                shown = set()
                for m in r.get("messages", []):
                    shown.add(m["id"]); show(m)
                if follow_on:
                    follow(r["path"], shown)
            elif cmd == "list":
                r = call({"op": "chat.list"})
                for c in r.get("channels", []):
                    last = c.get("last")
                    print("%-16s %-24s %s" % (c["channel"], ",".join(c.get("members", [])) or "-",
                                              ("last %s: %s" % (time.strftime("%H:%M", time.localtime(last["ts"])), last["text"][:60])) if last else ""))
                now = time.time()
                for p in r.get("presence", []):
                    print("  %s  active %d min ago" % (p["who"], max(0, int((now - p["ts"]) / 60))))
            else:
                die(USAGE)

        main(sys.argv[1:])
        """#
        .replacingOccurrences(of: "__SOCKET__", with: AgentHooks.pythonString(socketPath))
    }
}
