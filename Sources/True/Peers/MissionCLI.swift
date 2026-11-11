import Foundation

/// `true-mission` — start a mission from a template and watch it. Same shape as `true-chat`: a python3 client over the
/// 0600 socket `~/.true/peer.sock`; the ops are `mission.templates|start|status|cancel`, answered by `MissionService.handle`.
/// A person's step is finished with `true-group done <item>`; this tool never marks one done.
enum MissionCLI {
    static func scriptPath(_ paths: AgentPaths) -> String { paths.binDir.appendingPathComponent("true-mission").path }

    static func install(paths: AgentPaths) {
        try? FileManager.default.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let path = scriptPath(paths)
        let body = script(socketPath: PeerCLI.socketPath(paths))
        if (try? String(contentsOfFile: path, encoding: .utf8)) != body { try? body.write(toFile: path, atomically: true, encoding: .utf8) }
        chmod(path, 0o755)
    }

    static func script(socketPath: String) -> String {
        #"""
        #!/usr/bin/env python3
        # true-mission — start a mission from a template, and watch it.
        #   true-mission templates                                   the templates you can start
        #   true-mission start <template> --firm <name> [--person <id>] [--repo <url>]
        #                                                            fills the blanks and starts it; prints the mission id
        #   true-mission status <id>                                 each step: title  who  state  why
        #   true-mission cancel <id>
        # A step a person does shows "Waiting for <name>"; they finish it with: true-group done <item id>
        import json, os, socket, sys

        DEFAULT_SOCK = __SOCKET__
        USAGE = ("usage: true-mission templates | true-mission start <template> --firm <name> [--person <id>] [--repo <url>] | "
                 "true-mission status <id> | true-mission cancel <id>")

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

        def main(argv):
            if not argv or argv[0] in ("help", "-h", "--help"):
                print(USAGE)
                return
            cmd, args = argv[0], argv[1:]
            if cmd == "templates":
                for n in call({"op": "mission.templates"}).get("templates", []):
                    print(n)
            elif cmd == "start":
                if not args or args[0].startswith("-"):
                    die(USAGE)
                vars_, flags = {}, args[1:]
                i = 0
                while i < len(flags):
                    if flags[i] in ("--firm", "--person", "--repo") and i + 1 < len(flags):
                        vars_[flags[i][2:]] = flags[i + 1]
                        i += 2
                    else:
                        die(USAGE)
                if "firm" in vars_ and "repo" not in vars_:
                    vars_["repo"] = vars_["firm"]
                print(call({"op": "mission.start", "template": args[0], "vars": vars_})["missionId"])
            elif cmd in ("status", "cancel"):
                if len(args) != 1:
                    die(USAGE)
                r = call({"op": "mission." + cmd, "missionId": args[0]})
                if cmd == "status":
                    print("mission %s" % r.get("state", ""))
                    for j in r.get("jobs", []):
                        print("%s  %s  %s  %s" % (j["title"], j["mac"], j["state"], j["reason"]))
                else:
                    print("Canceled")
            else:
                die(USAGE)

        main(sys.argv[1:])
        """#
        .replacingOccurrences(of: "__SOCKET__", with: AgentHooks.pythonString(socketPath))
    }
}
