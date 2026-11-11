import Foundation
import AppKit

/// Panes opened from the phone, so the Mac can tag them "from iPhone" for 10 minutes.
final class RemoteOrigin: @unchecked Sendable {
    static let shared = RemoteOrigin()
    static let window: TimeInterval = 600
    private let lock = NSLock()
    private var panes: [UUID: Date] = [:]

    func mark(_ pane: UUID, now: Date = Date()) {
        lock.lock(); panes[pane] = now; lock.unlock()
    }

    func isRecent(_ pane: UUID, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = panes[pane] else { return false }
        if now.timeIntervalSince(t) >= Self.window { panes[pane] = nil; return false }
        return true
    }
}

/// Builders the phone started. A name counts while the Hub shows it running; a fresh launch counts for 60 s
/// before the Hub has had time to list it.
final class PhoneBuilders: @unchecked Sendable {
    private let lock = NSLock()
    private var launched: [String: Date] = [:]

    func mark(_ name: String, now: Date = Date()) { lock.lock(); launched[name] = now; lock.unlock() }

    func running(records: [(name: String, running: Bool)], now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        launched = launched.filter { now.timeIntervalSince($0.value) < 6 * 3600 }
        return launched.filter { name, t in
            let matches = records.filter { $0.name == name || $0.name.contains(name) }
            return matches.isEmpty ? now.timeIntervalSince(t) < 60 : matches.contains { $0.running }
        }.count
    }
}

/// A pane that is asking but belongs to no seat (a plain `claude` run). `projectKey` is `HubProject.key(forCwd:)`.
struct LoosePane: Equatable {
    var pane: UUID; var name: String; var cwd: String; var projectKey: String
    var question: String; var tool: String?; var detail: String?
}

/// Whether a need is a permission prompt or a question. Deterministic on what the hook already sends.
enum NeedKind {
    static func classify(question: String, tool: String?) -> String {
        if let t = tool, !t.isEmpty { return "permission" }
        return question.lowercased().contains("permission") ? "permission" : "question"
    }
}

/// The Hub as JSON, from the Mac Hub's own groups (HubModel.build): same grouping, order, counts and status labels.
enum RemoteHubJSON {
    static func make(groups: [HubProjectGroup], seatStatus: (String) -> AgentStatus, seatPane: (String) -> UUID?,
                     ask: (UUID) -> (question: String, tool: String?, detail: String?)? = { _ in nil },
                     loosePanes: [LoosePane] = [],
                     now: Double) -> [String: Any] {
        var projects: [[String: Any]] = groups.map { g in
            var rows: [[String: Any]] = g.seats.map { a in
                let st = seatStatus(a.name)
                var r: [String: Any] = ["kind": "seat", "id": "seat-\(a.name)", "name": a.name, "status": st.label,
                                        "statusKey": st.rawValue, "model": a.model.rawValue]
                if let p = seatPane(a.name) {
                    r["pane"] = p.uuidString
                    if st == .needsYou, let q = ask(p) {
                        r["question"] = String(q.question.prefix(300))
                        r["needKind"] = NeedKind.classify(question: q.question, tool: q.tool)
                        if let t = q.tool, !t.isEmpty { r["tool"] = String(t.prefix(300)) }
                        if let d = q.detail, !d.isEmpty { r["detail"] = String(d.prefix(300)) }
                    }
                }
                return r
            }
            rows += g.background.map { b in
                ["kind": "background", "id": "builder-\(b.id)", "name": b.name, "status": b.statusLabel,
                 "statusKey": b.status.rawValue, "builderId": b.id, "acked": b.acked, "model": b.model,
                 "elapsed": b.elapsed(now: now), "branch": b.branch ?? NSNull(),
                 "ended": b.ended ?? NSNull(), "fresh": HubTriage.isLive(b.ended ?? b.started, now: now)] as [String: Any]
            }
            rows += g.others.map { p in
                let st: AgentStatus = p.busy ? .working : .idle
                return ["kind": "other", "id": "peer-\(p.pid)", "name": p.displayName, "status": st.label,
                        "statusKey": st.rawValue, "cwd": p.cwd, "updated": p.updatedAt] as [String: Any]
            }
            return ["key": g.key, "title": g.title, "summary": g.summary, "working": g.working, "needsYou": g.needsYou,
                    "failed": g.failed, "rows": rows]
        }
        // A plain `claude` pane (no seat) that is asking: it has no seat row, so it gets a "pane" row in its
        // project group — otherwise the phone never hears about it (no notification, no Live Activity).
        let seatPanes = Set(groups.flatMap(\.seats).compactMap { seatPane($0.name) })
        var extraNeeds = 0
        for lp in loosePanes where !seatPanes.contains(lp.pane) {
            var r: [String: Any] = ["kind": "pane", "id": "pane-\(lp.pane.uuidString)", "name": lp.name,
                                    "status": AgentStatus.needsYou.label, "statusKey": AgentStatus.needsYou.rawValue,
                                    "pane": lp.pane.uuidString, "cwd": lp.cwd, "question": String(lp.question.prefix(300)),
                                    "needKind": NeedKind.classify(question: lp.question, tool: lp.tool)]
            if let t = lp.tool, !t.isEmpty { r["tool"] = String(t.prefix(300)) }
            if let d = lp.detail, !d.isEmpty { r["detail"] = String(d.prefix(300)) }
            let key = lp.projectKey
            if let i = projects.firstIndex(where: { ($0["key"] as? String) == key }) {
                projects[i]["rows"] = ((projects[i]["rows"] as? [[String: Any]]) ?? []) + [r]
                projects[i]["needsYou"] = ((projects[i]["needsYou"] as? Int) ?? 0) + 1
            } else {
                projects.insert(["key": key, "title": HubProject.title(key), "summary": "1 needs you", "working": 0,
                                 "needsYou": 1, "failed": 0, "rows": [r]], at: 0)
            }
            extraNeeds += 1
        }
        let w = groups.reduce(0) { $0 + $1.working }, n = groups.reduce(0) { $0 + $1.needsYou } + extraNeeds
        let f = groups.reduce(0) { $0 + $1.failed }
        var parts: [String] = []
        if w > 0 { parts.append("\(w) working") }
        if n > 0 { parts.append("\(n) needs you") }
        if f > 0 { parts.append("\(f) failed") }
        return ["now": now, "working": w, "needsYou": n, "failed": f, "summary": parts.joined(separator: " · "),
                "projects": projects]
    }

    /// A builder id is a folder name under ~/.claude/builders: plain characters only, and it must be one the Hub knows.
    static func isValidBuilderID(_ id: String, known: [BuilderRecord]) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 80,
              id.unicodeScalars.allSatisfy({ ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "-" || $0 == "_" })
        else { return false }
        return known.contains { $0.id == id }
    }

    /// Mark a builder acknowledged: the same `acked: true` the builder CLI writes into meta.json. Id must be known.
    static func ack(id: String, known: [BuilderRecord]) -> Bool {
        guard isValidBuilderID(id, known: known), let rec = known.first(where: { $0.id == id }), rec.state != .running,
              let dir = rec.dir else { return false }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        obj["acked"] = true
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return false }
        return (try? out.write(to: url, options: .atomic)) != nil
    }
}

private final class JevBox: @unchecked Sendable { var reply: JevReply? }

struct RemoteCommandsLive: RemoteCommands {
    private static func onMain<T: Sendable>(_ f: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { f() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { f() } }
    }

    private var logURL: URL { CommandBarLog.standard.dir.appendingPathComponent("remote.jsonl") }

    func environment() -> BarEnvironment { Self.onMain { BarEnvironmentProvider.live() } }
    func isExecutable(_ name: String) -> Bool { BarEnvironmentProvider.onPath(name) }
    var jevEnabled: Bool { TerminalSettings.jevRouting }

    func jev(text: String, context: CommandContext, rule: RuleMatch?) -> JevReply? {
        let box = JevBox(), sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.reply = await CommandRouter.ask(text: text, context: context, rule: rule, jev: .shared,
                                                isExecutable: { BarEnvironmentProvider.onPath($0) })
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + CommandRouter.timeout + 1)
        return box.reply
    }

    /// Phone-started builders, for the 3-at-once cap.
    private static let phoneBuilders = PhoneBuilders()

    func launch(_ plan: Plan, route r: Route) -> RemoteLaunch {
        let rec = CommandBarLog.Record(event: .run, text: plan.argv.last ?? r.text, latencyMs: nil, route: r,
                                       door: RemoteBar.doorName(plan.door), background: false)
        CommandBarLog.standard.append(rec)
        return Self.onMain {
            let ws = WorkspaceModel.shared
            // Only a pane this very action created is tagged "from iPhone"; nothing else is marked or returned.
            var pane: UUID?
            switch plan.door {
            case .newClaudePane(let cwd):
                let cmd = CommandExecutor.startupCommand(argv: plan.argv, settings: AgentPaths.standard.paneSettingsPath)
                pane = ws.openProjectBeside(path: cwd ?? NSHomeDirectory(), startupCommand: cmd)
            case .newShellSplit(let cwd):
                // A new tab, not a split of whichever tab the Mac is looking at.
                let text = plan.argv.last ?? ""
                let new = ws.openShellTab(cwd: cwd ?? NSHomeDirectory())
                if plan.autoSubmit { PaneStartup.shared.set("\(text); exec \"${SHELL:-/bin/zsh}\" -l", for: new) }
                else {
                    Task { @MainActor in
                        for _ in 0..<20 {
                            try? await Task.sleep(for: .milliseconds(100))
                            if let v = TerminalRegistry.shared.view(for: new) { v.send(txt: text); return }
                        }
                    }
                }
                pane = new
            case .background(let name, _, _):
                CommandExecutor.run(plan, route: r, onBackground: { result in
                    if case .failure(let e) = result { CommandBarLog.logger.error("remote background spawn failed: \(e.message, privacy: .public)") }
                })
                return .background(name)
            case .seat(let n):
                CommandExecutor.run(plan, route: r)
                pane = AgentRegistry.shared.panes[n]
            case .trueAction(let a):
                let before = ws.allPanes
                CommandExecutor.run(plan, route: r)
                if a == .sleepSeat { return .done }
                pane = ws.allPanes.subtracting(before).first
                if a == .wakeSeat, let n = plan.argv.first { pane = AgentRegistry.shared.panes[n] }
            default:
                return .failed("not allowed from the phone")
            }
            guard let p = pane else { return .done }
            RemoteOrigin.shared.mark(p)
            return .pane(p)
        }
    }

    func markPhoneBuilder(_ name: String) { Self.phoneBuilders.mark(name) }

    func phoneBuildersRunning() -> Int {
        let records = Self.onMain { HubStore.shared.builders }
        return Self.phoneBuilders.running(records: records.map { ($0.name, $0.state == .running) })
    }

    func seatIsWorking(_ name: String) -> Bool { Self.onMain { AgentRegistry.shared.statusOf(name) == .working } }

    func history() -> [String] { CommandBarLog.standard.loadHistory() }
    func pushHistory(_ text: String) {
        let log = CommandBarLog.standard
        log.saveHistory(CommandBarLog.pushed(text, onto: log.loadHistory()))
    }

    func hubJSON() -> Data {
        return Self.onMain {
            let reg = AgentRegistry.shared, hub = HubStore.shared
            let now = Date().timeIntervalSince1970
            let groups = HubModel.build(seats: reg.crew, seatStatus: { reg.statusOf($0) }, seatAwake: { reg.isAwake($0) },
                                        peers: hub.peers, builders: hub.builders, now: now)
            let obj: [String: Any] = RemoteHubJSON.make(groups: groups, seatStatus: { reg.statusOf($0) }, seatPane: { reg.panes[$0] },
                                                 ask: { id in NeedsYouQueue.shared.rows.first { $0.paneID == id }.map { ($0.question, $0.tool, $0.detail) } },
                                                 loosePanes: Self.loosePanes(reg: reg),
                                                 now: now)
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
    }

    /// Needs-you rows whose pane is not a seat: named by repo (else folder), grouped like the Mac Hub would.
    @MainActor static func loosePanes(reg: AgentRegistry) -> [LoosePane] {
        let model = WorkspaceModel.shared
        return NeedsYouQueue.shared.rows.filter { reg.name(for: $0.paneID) == nil }.map { row in
            let recorded = model.state.tabs.lazy.compactMap { $0.cwds[row.paneID] }.first ?? ""
            let id = PaneIdentity.resolve(pane: row.paneID, recordedCwd: recorded)
            let cwd = id.cwd.isEmpty ? recorded : id.cwd
            let name = id.repo ?? (cwd.isEmpty ? "Claude" : (cwd as NSString).lastPathComponent)
            return LoosePane(pane: row.paneID, name: name, cwd: cwd, projectKey: HubProject.key(forCwd: cwd),
                             question: row.question, tool: row.tool, detail: row.detail)
        }
    }

    func builderDetail(id: String) -> Data? {
        let builders = Self.onMain { HubStore.shared.builders }
        guard RemoteHubJSON.isValidBuilderID(id, known: builders), let b = builders.first(where: { $0.id == id }) else { return nil }
        let obj: [String: Any] = ["id": b.id, "name": b.name, "status": b.statusLabel, "acked": b.acked,
                                  "canAck": b.state != .running, "text": String(HubScanner.detail(of: b).prefix(20_000))]
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    func ackBuilder(id: String) -> Bool {
        let builders = Self.onMain { HubStore.shared.builders }
        let ok = RemoteHubJSON.ack(id: id, known: builders)
        if ok { Task { @MainActor in await HubStore.shared.reload() } }
        return ok
    }

    func record(_ line: [String: Any]) {
        let fm = FileManager.default
        let dir = CommandBarLog.standard.dir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(10)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close()
        }
    }
}
