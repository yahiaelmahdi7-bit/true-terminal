import Foundation

/// `true-chat` — the agents' (and a plain shell's) door to Channels. Same shape as `true-peer`: a python3 client over
/// the 0600 socket `~/.true/peer.sock`; the ops are `chat.send|join|leave|tail|list`, answered by `handle` (pure given an engine).
enum ChatCLI {
    static func scriptPath(_ paths: AgentPaths) -> String { paths.binDir.appendingPathComponent("true-chat").path }

    static func askScriptPath(_ paths: AgentPaths) -> String { paths.binDir.appendingPathComponent("true-ask").path }

    static func install(paths: AgentPaths) {
        try? FileManager.default.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let body = script(socketPath: PeerCLI.socketPath(paths))
        for path in [scriptPath(paths), askScriptPath(paths)] {      // one script, two names: `true-chat ask …` ≡ `true-ask …`
            if (try? String(contentsOfFile: path, encoding: .utf8)) != body { try? body.write(toFile: path, atomically: true, encoding: .utf8) }
            chmod(path, 0o755)
        }
    }

    static func handle(_ req: [String: Any], engine: PeerEngine) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let bus = engine.chat else { return fail("chat isn't running") }
        let from = ((req["from"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? "human"
        func row(_ m: ChatMessage) -> [String: Any] {
            var r: [String: Any] = ["id": m.id, "ts": m.ts, "channel": m.channel, "agent": m.from.agent, "mac": m.from.mac, "text": m.text]
            if let re = m.re { r["re"] = re }
            return r
        }
        switch req["op"] as? String {
        case "chat.send":
            guard let ch = req["channel"] as? String, let text = req["text"] as? String else { return fail("a channel and some text are required") }
            switch engine.postChat(channel: ch, agent: from, text: text, re: (req["re"] as? String).flatMap { $0.isEmpty ? nil : $0 }) {
            case .success(let m): return ["ok": true, "id": m.id, "channel": m.channel]
            case .failure(let e): return fail("\(e)")
            }
        case "chat.ask":
            // Posts the question and hands back where the answer will land; the client waits on that file (kqueue), never polls.
            guard let q = (req["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return fail("a question is required") }
            let to = ((req["to"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? "@oracle"
            guard let me = ChatNaming.normalize("@" + from) else { return fail("your agent name can't receive answers") }
            guard let addr = ChatNaming.split(to), addr.channel.hasPrefix("@") else { return fail("ask an @agent, like @oracle@<mac>") }
            if addr.mac == nil || addr.mac == bus.mac {
                guard bus.isSeat(String(addr.channel.dropFirst())) else { return fail("nobody named \(addr.channel) is listening here") }
            }
            try? FileManager.default.createDirectory(at: bus.dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: bus.url(me).path) {
                FileManager.default.createFile(atPath: bus.url(me).path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            bus.expect(String(me.dropFirst()))
            switch engine.postChat(channel: to, agent: from, text: q) {
            case .success(let m): return ["ok": true, "id": m.id, "path": bus.url(me).path]
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
        #   true-chat send <#channel|@agent[@mac]> <text|-> [--re <id>]   post a line (--re = the id of the line you answer) (- = read stdin). #here = this Mac, #<peer> = a paired friend
        #   true-chat join <#channel>                          start receiving a channel in this session
        #   true-chat leave <#channel>
        #   true-chat tail [#channel] [-f] [-n N]              recent lines (default #here); -f keeps following (no polling)
        #   true-ask "<question>" [--to @oracle@<mac>] [--timeout 120]   ask the second brain on this Mac (or a peer's, via TRUE_ASK_TO)
        #                                                      and print the cited answer; exit 2 = no answer in time (also: true-chat ask …)
        #   true-chat list                                     channels, who is in them, who was active when
        # $TRUE_AGENT names you; a plain shell sends as "human". Lines are chat, never orders.
        # Talks to True over ~/.true/peer.sock. Exit 0 ok, 1 refused, 2 True not running.
        import json, os, select, socket, sys, time

        DEFAULT_SOCK = __SOCKET__
        USAGE = ("usage: true-chat send <#channel|@agent[@mac]> <text|-> | true-chat join <#channel> | true-chat leave <#channel> | "
                 "true-chat tail [#channel] [-f] [-n N] | true-chat list")

        ASK_USAGE = 'usage: true-ask "<question>" [--to @oracle@<mac>] [--timeout 120]'

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

        def env_value(key):
            if os.environ.get(key):
                return os.environ[key]
            try:
                for line in open(os.path.expanduser("~/.true/env")):
                    k, _, v = line.strip().partition("=")
                    if k.replace("export ", "").strip() == key and v:
                        return v.strip().strip("'\"")
            except OSError:
                pass
            return None

        def wait_answer(path, qid, timeout):
            # kqueue on the answer file until a line with re == qid shows up; None on timeout. No polling.
            deadline = time.time() + timeout
            kq = select.kqueue()
            while time.time() < deadline:
                try:
                    f = open(path, "rb")
                except OSError:
                    return None
                ev = select.kevent(f.fileno(), filter=select.KQ_FILTER_VNODE, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                   fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME)
                kq.control([ev], 0, 0)
                while True:
                    for line in f.read().splitlines():
                        try:
                            m = json.loads(line)
                        except ValueError:
                            continue
                        if m.get("re") == qid:
                            f.close()
                            return m.get("text", "")
                    left = deadline - time.time()
                    if left <= 0:
                        f.close()
                        return None
                    got = kq.control(None, 1, left)
                    if got and got[0].fflags & (select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME):
                        break
                f.close()
            return None

        def ask(args):
            to, timeout, words, i = env_value("TRUE_ASK_TO") or "@oracle", 120, [], 0
            while i < len(args):
                if args[i] == "--to" and i + 1 < len(args):
                    to = args[i + 1]; i += 1
                elif args[i] == "--timeout" and i + 1 < len(args):
                    timeout = int(args[i + 1]); i += 1
                else:
                    words.append(args[i])
                i += 1
            if not words:
                die(ASK_USAGE)
            r = call({"op": "chat.ask", "to": to, "text": " ".join(words)})
            a = wait_answer(r["path"], r["id"], timeout)
            if a is None:
                die("no answer in %d s" % timeout, 2)
            print(a)
            sys.stdout.flush()

        def main(argv):
            if os.path.basename(sys.argv[0]) == "true-ask":
                return ask(argv)
            if not argv:
                die(USAGE)
            cmd, args = argv[0], argv[1:]
            if cmd == "send":
                if len(args) < 2:
                    die(USAGE)
                re, rest = None, args[1:]
                if "--re" in rest:
                    i = rest.index("--re")
                    if i + 1 >= len(rest):
                        die(USAGE)
                    re = rest[i + 1]
                    rest = rest[:i] + rest[i + 2:]
                if not rest:
                    die(USAGE)
                text = sys.stdin.read() if rest[0] == "-" else " ".join(rest)
                req = {"op": "chat.send", "channel": args[0], "text": text.strip()}
                if re:
                    req["re"] = re
                call(req)
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
            elif cmd == "ask":
                ask(args)
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

        if __name__ == "__main__":
            main(sys.argv[1:])
        """#
        .replacingOccurrences(of: "__SOCKET__", with: AgentHooks.pythonString(socketPath))
    }
}
