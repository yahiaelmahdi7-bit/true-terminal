import Foundation

/// The control socket (`~/.true/control.sock`): how an agent, from inside its own pane, asks True to
/// do something — today, to *summon* another agent. Request/response, one JSON line each way:
/// `{"op":"status"}` / `{"op":"summon","agent":"…","message":"…","from":"…"}` /
/// `{"op":"spawn","name":"…","promptFile":"…","repo":"…","worktree":true,"model":"…","from":"…"}`. The client is the
/// `truectl` script (`AgentControl.truectl`), which tags `from` with `$TRUE_AGENT`.
enum ControlRequest: Equatable, Sendable {
    case status
    case summon(agent: String, message: String, from: String?)
    case spawn(SpawnRequest)
    case inbox

    /// Anything malformed returns nil — the socket is a doorbell, never a crash surface.
    static func parse(_ line: Data) -> ControlRequest? {
        struct Wire: Decodable { let op: String; let agent: String?; let message: String?; let from: String?
                             let name: String?; let promptFile: String?; let repo: String?; let worktree: Bool?; let model: String? }
        guard let w = try? JSONDecoder().decode(Wire.self, from: line) else { return nil }
        switch w.op {
        case "status":
            return .status
        case "summon":
            guard let agent = w.agent, let message = w.message else { return nil }
            return .summon(agent: agent, message: message, from: w.from)
        case "inbox":
            return .inbox
        case "spawn":
            guard let name = w.name, let promptFile = w.promptFile else { return nil }
            return .spawn(SpawnRequest(name: name, promptFile: promptFile, repo: w.repo, worktree: w.worktree ?? false,
                                       model: w.model ?? "sonnet", from: w.from))
        default:
            return nil
        }
    }
}

struct ControlResponse: Encodable, Equatable, Sendable {
    struct Row: Encodable, Equatable, Sendable {
        let name: String, role: String, repo: String, status: String, awake: Bool
    }
    var ok: Bool
    var error: String?
    var outcome: String?
    var agents: [Row]?
    /// The Hub snapshot (project → sessions) on `status`; every session on this Mac, not just seats.
    var hub: [HubRow]?
    /// The Watcher's open items on `inbox`.
    var inbox: [InboxRow]?
    struct InboxRow: Encodable, Equatable, Sendable {
        let id: String, title: String, repo: String, level: String, state: String, note: String
    }
    /// The builder id on `spawn`.
    var builderID: String?

    static func failure(_ message: String) -> ControlResponse { ControlResponse(ok: false, error: message) }

    /// One line, trailing newline — the wire format `truectl` reads.
    func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)).map { $0 + Data("\n".utf8) } ?? Data("{\"ok\":false}\n".utf8)
    }
}

enum AgentControl {
    /// Who may summon whom. A human (no caller, or a name that is no agent) may reach anyone; a
    /// global reaches only the LEADS on its team, a lead only the HELPERS on its team, a helper no one.
    /// Enforced here, not in the role card: a card is advice, this is the door.
    static func mayReach(caller: String?, target: Agent, agents: [Agent]) -> Bool {
        if target.role == .watcher { return false }
        guard let caller, let c = agents.first(where: { $0.name == caller }) else { return true }
        switch c.role {
        case .global: return target.role == .lead && c.team.contains(target.name)
        case .lead: return target.role == .helper && c.team.contains(target.name)
        case .helper, .watcher: return false
        }
    }

    /// What lands in the target's pane. A summoned agent is told who to answer, since the brief is
    /// its only context for that.
    static func deliveredText(message: String, from: String?) -> String {
        guard let from, !from.isEmpty else { return message }
        return message + "\n\n(Summoned by `\(from)`. When you finish or get blocked, reply to `\(from)` with the SendMessage tool — a one-line summary, what changed, the verification output.)"
    }

    @MainActor private static func agentRows(_ registry: AgentRegistry) -> [ControlResponse.Row] {
        registry.crew.map {
            ControlResponse.Row(name: $0.name, role: $0.role.rawValue, repo: $0.repoName,
                                status: registry.statusOf($0.name).rawValue, awake: registry.isAwake($0.name))
        }
    }

    /// How long a summon may wait for a sleeping agent to boot. `talk` gives up on its own after 60 s
    /// of no SessionStart; this is the backstop for a callback that never comes at all.
    static let summonTimeout: Duration = .seconds(90)

    /// Replies exactly once, whichever of `talk`'s callback and the timeout comes first.
    @MainActor private final class Once {
        private var done = false
        func run(_ body: () -> Void) { guard !done else { return }; done = true; body() }
    }

    @MainActor
    static func handle(_ req: ControlRequest, registry: AgentRegistry, hub: HubStore = .shared,
                       runner: @escaping BuilderSpawn.Runner = BuilderSpawn.systemRunner,
                       reply: @escaping @Sendable (ControlResponse) -> Void) {
        switch req {
        case .status:
            // Fresh scan first: a lead asking "what is running?" must not get a 250 ms-old answer.
            Task { @MainActor in
                await hub.reload()
                let groups = HubModel.build(seats: registry.crew, seatStatus: { registry.statusOf($0) },
                                            seatAwake: { registry.isAwake($0) }, peers: hub.peers,
                                            builders: hub.builders, now: Date().timeIntervalSince1970)
                reply(ControlResponse(ok: true, agents: agentRows(registry),
                                      hub: HubModel.rows(groups, seatStatus: { registry.statusOf($0) },
                                                   seatVerdict: { OverseerStore.shared.verdict(forSession: $0.lastSessionID)?.kind.rawValue },
                                                   peerVerdict: { OverseerStore.shared.verdict(forSession: $0.sessionID)?.kind.rawValue })))
            }
        case .inbox:
            Task { @MainActor in
                let rows = WatcherStore.shared.needsYou.map {
                    ControlResponse.InboxRow(id: $0.id, title: $0.title, repo: $0.repo, level: $0.level?.rawValue ?? "",
                                             state: $0.state.rawValue, note: $0.note ?? "")
                }
                reply(ControlResponse(ok: true, inbox: rows))
            }
        case .spawn(let request):
            let caller = request.from.flatMap { registry.agent(named: $0) }
            // A helper works inside its lead's brief; only a lead or global starts background work.
            if let caller, caller.role == .helper {
                return reply(.failure("\(caller.name) may not spawn (helpers work inside their lead's brief)"))
            }
            let callerRepo = caller.flatMap { $0.repo.isEmpty ? nil : $0.repo }
            Task { @MainActor in
                switch await BuilderSpawn.run(request, callerRepo: callerRepo, runner: runner) {
                case .success(let id): reply(ControlResponse(ok: true, builderID: id))
                case .failure(let e): reply(.failure(e.message))
                }
            }
        case .summon(let agent, let message, let from):
            guard let target = registry.agent(named: agent) else { return reply(.failure("no agent named \(agent)")) }
            let caller = from.flatMap { registry.agent(named: $0) }?.name
            guard mayReach(caller: caller, target: target, agents: registry.agents) else {
                return reply(.failure("\(caller ?? "") may not summon \(target.name) (globals summon their leads, leads summon their helpers)"))
            }
            // `talk` ignores an empty body without calling back, which would read as a 90 s hang.
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return reply(.failure("empty message"))
            }
            let once = Once()
            registry.talk(target.name, deliveredText(message: message, from: caller)) { outcome in
                Task { @MainActor in
                    once.run { reply(ControlResponse(ok: true, outcome: String(describing: outcome))) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: summonTimeout)
                once.run { reply(.failure("timed out waiting for \(target.name) to boot")) }
            }
        }
    }

    /// The client agents run. Prints nothing on stdout but its result; errors go to stderr.
    /// `TRUE_CONTROL_SOCK` overrides the baked-in socket (used by tests).
    static func truectl(socketPath: String) -> String {
        #"""
        #!/usr/bin/env python3
        # truectl — the command-line door to the running True app (control socket).
        #   truectl status                        one line per agent: name  role  status  awake|asleep  repo
        #   truectl inbox [--json]                the Watcher's open items: id  level  repo  title
        #   truectl status --json                 the raw reply (agents + the whole Hub: project → sessions)
        #   truectl summon <agent> <message...>   wake <agent> if asleep and deliver the brief ("-" = read stdin)
        #   truectl spawn --name N --prompt-file F [--repo R] [--worktree] [--model M]
        #                                         start a detached background build; prints "spawned <id>"
        # Sends one JSON line, waits for one reply line. stdout carries only the result; errors go to
        # stderr. Exit 0 ok, 1 refused/failed, 2 True is not running.
        import json, os, socket, sys

        DEFAULT_SOCK = __SOCKET__
        USAGE = ("usage: truectl status [--json] | truectl summon <agent> <message words... | -> | "
                 "truectl inbox [--json] | truectl spawn --name N --prompt-file F [--repo R] [--worktree] [--model M]")

        def die(msg, code=1):
            sys.stderr.write(msg + "\n")
            sys.exit(code)

        def call(wire):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(100)
            try:
                s.connect(os.environ.get("TRUE_CONTROL_SOCK") or DEFAULT_SOCK)
            except (FileNotFoundError, ConnectionRefusedError):
                die("True is not running", 2)
            except OSError as e:
                die("cannot reach True: %s" % e, 2)
            buf = b""
            try:
                s.sendall((json.dumps(wire) + "\n").encode())
                while b"\n" not in buf:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
            except socket.timeout:
                die("timed out waiting for True")
            finally:
                s.close()
            try:
                return json.loads(buf.split(b"\n")[0].decode())
            except ValueError:
                die("True sent no usable reply")

        def main(argv):
            if argv[:1] == ["status"] and argv[1:] in ([], ["--json"]):
                r = call({"op": "status"})
                if not r.get("ok"):
                    die(r.get("error") or "failed")
                if argv[1:]:
                    print(json.dumps(r, sort_keys=True))
                    return
                for a in r.get("agents") or []:
                    print("%s  %s  %s  %s  %s" % (a["name"], a["role"], a["status"],
                                                  "awake" if a["awake"] else "asleep", a["repo"]))
                # The Hub beyond the seats above: background builds and other live sessions.
                for h in r.get("hub") or []:
                    if h["kind"] != "seat":
                        print("hub  %s  %s  %s  %s" % (h["project"], h["kind"], h["name"], h["status"]))
            elif argv[:1] == ["inbox"] and argv[1:] in ([], ["--json"]):
                r = call({"op": "inbox"})
                if not r.get("ok"):
                    die(r.get("error") or "failed")
                if argv[1:]:
                    print(json.dumps(r, sort_keys=True))
                    return
                for i in r.get("inbox") or []:
                    print("%s  %s  %s  %s" % (i["id"], i["level"] or "-", i["repo"], i["title"]))
            elif argv[:1] == ["spawn"]:
                opts = {"name": None, "prompt-file": None, "repo": None, "model": None}
                worktree = False
                i = 1
                while i < len(argv):
                    flag = argv[i]
                    if flag == "--worktree":
                        worktree = True
                        i += 1
                    elif flag.startswith("--") and flag[2:] in opts and i + 1 < len(argv):
                        opts[flag[2:]] = argv[i + 1]
                        i += 2
                    else:
                        die(USAGE)
                if not opts["name"] or not opts["prompt-file"]:
                    die(USAGE)
                wire = {"op": "spawn", "name": opts["name"], "promptFile": os.path.abspath(opts["prompt-file"]),
                        "worktree": worktree, "from": os.environ.get("TRUE_AGENT")}
                if opts["repo"]:
                    wire["repo"] = os.path.abspath(opts["repo"])
                if opts["model"]:
                    wire["model"] = opts["model"]
                r = call(wire)
                if not r.get("ok"):
                    die(r.get("error") or "failed")
                print("spawned %s" % r.get("builderID"))
            elif argv[:1] == ["summon"] and len(argv) >= 3:
                agent = argv[1]
                message = sys.stdin.read() if argv[2:] == ["-"] else " ".join(argv[2:])
                r = call({"op": "summon", "agent": agent, "message": message,
                          "from": os.environ.get("TRUE_AGENT")})
                if not r.get("ok"):
                    die(r.get("error") or "failed")
                print("summoned %s (%s)" % (agent, r.get("outcome") or "unknown"))
            else:
                die(USAGE)

        main(sys.argv[1:])
        """#
        .replacingOccurrences(of: "__SOCKET__", with: AgentHooks.pythonString(socketPath))
    }
}

/// `LineSocketServer` + `ControlRequest`. Started once at launch, like the events socket.
final class AgentControlSocket: @unchecked Sendable {
    private let server: LineSocketServer

    init(path: String, registry: AgentRegistry, hub: HubStore? = nil, runner: @escaping BuilderSpawn.Runner = BuilderSpawn.systemRunner) {
        server = LineSocketServer(path: path) { line, reply in
            guard let req = ControlRequest.parse(line) else {
                return reply(ControlResponse.failure("bad request").encoded())
            }
            Task { @MainActor in
                AgentControl.handle(req, registry: registry, hub: hub ?? .shared, runner: runner) { reply($0.encoded()) }
            }
        }
    }

    @discardableResult
    func start() -> Bool { server.start() }
    func stop() { server.stop() }
}
