import Foundation
import Observation

/// One line of the agent list: a seat, a builder or a mission job. Plain words only; ids stay out of the text.
struct ActivityRow: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case seat, builder, mission }
    var kind: Kind
    var id: String
    var name: String
    /// working | waiting | needs-you | done | failed
    var status: String
    var activity: String
    var project: String
    var provider: String
    var model: String
    var effort: String?
    var browser: String?
    var needsYou: Bool
    var since: Date?
    /// Not encoded: how a click finds the thing (seat pane or builder id).
    var pane: UUID? = nil
    /// Not encoded: how full the seat's context is. nil = unknown size or not read, so no meter.
    var context: ContextReading? = nil

    private enum CodingKeys: String, CodingKey {
        case kind, id, name, status, activity, project, provider, model, effort, browser, needsYou, since
    }
}

/// Input snapshots for the pure builder, so the rules are testable without a window.
struct SeatSnapshot {
    var name: String
    var pane: UUID
    var project: String
    var model: String
    var effort: String
    var status: AgentStatus
    var event: PaneEvent?
    var context: ContextReading? = nil
}

struct BuilderSnapshot {
    var record: BuilderRecord
    var lastTool: (tool: String, detail: String?)?
    var browser: String?
}

/// Everything the task screen needs to open one mission job.
struct MissionTaskInfo {
    var job: MissionJob
    var progress: MissionJobProgress
    var base: String
    var branch: String
}

struct MissionJobSnapshot {
    var mission: String
    var title: String
    var state: MissionJobState
    var tool: String?
    var info: MissionTaskInfo? = nil
}

enum AgentActivityBuilder {
    static func rows(seats: [SeatSnapshot], needsYou: Set<UUID>, builders: [BuilderSnapshot],
                     missions: [MissionJobSnapshot], browser: BrowserMemory, now: Date) -> [ActivityRow] {
        var out: [ActivityRow] = []
        for s in seats {
            let needs = needsYou.contains(s.pane)
            var status = "working", activity = ActivityPhrase.phrase(tool: s.event?.tool, detail: s.event?.detail)
            if needs {
                status = "needs-you"
                activity = "Needs you: " + firstLine(s.event?.message)
            } else {
                switch s.status {
                case .idle, .asleep: status = "waiting"; activity = "Waiting"
                case .done: status = "done"; activity = "Done"
                case .failed: status = "failed"; activity = "Failed"
                case .needsYou: status = "waiting"; activity = "Waiting"
                case .working: break
                }
            }
            out.append(ActivityRow(kind: .seat, id: s.pane.uuidString, name: s.name, status: status, activity: activity,
                                   project: s.project, provider: "claude", model: s.model, effort: s.effort,
                                   browser: browser.label(for: "seat:" + s.name, now: now), needsYou: status == "needs-you",
                                   since: s.event?.at, pane: s.pane, context: s.context))
        }
        for b in builders where b.record.state.isLive {
            let r = b.record
            let needs = r.state == .waiting || r.rawStatus == "needs-you"
            var status = needs ? "needs-you" : "working", activity = "Working"
            if let t = b.lastTool { activity = ActivityPhrase.phrase(tool: t.tool, detail: t.detail) }
            if r.state == .queued { status = "waiting"; activity = "Waiting" }
            if needs { activity = r.state == .waiting ? "Waiting for a limit" : "Needs you" }
            out.append(ActivityRow(kind: .builder, id: r.id, name: r.name, status: status, activity: activity,
                                   project: (r.originCwd as NSString).lastPathComponent, provider: "claude",
                                   model: r.model, effort: nil, browser: b.browser, needsYou: needs,
                                   since: Date(timeIntervalSince1970: r.started)))
        }
        let live: Set<MissionJobState> = [.starting, .running, .needsYou, .waiting, .paused, .blocked]
        for m in missions where live.contains(m.state) {
            let status: String
            switch m.state {
            case .needsYou: status = "needs-you"
            case .starting, .running: status = "working"
            default: status = "waiting"
            }
            let activity = status == "needs-you" ? "Needs you" : status == "working" ? "Working" : "Waiting"
            out.append(ActivityRow(kind: .mission, id: m.mission + "/" + m.title, name: m.title, status: status,
                                   activity: activity, project: m.mission, provider: "claude", model: m.tool ?? "",
                                   effort: nil, browser: nil, needsYou: m.state == .needsYou, since: nil))
        }
        return out
    }

    /// Needs-you first, then seats, then builders, then mission jobs (stable inside each group).
    static func ordered(_ rows: [ActivityRow]) -> [ActivityRow] {
        func rank(_ r: ActivityRow) -> Int { (r.needsYou ? 0 : 10) + (r.kind == .seat ? 0 : r.kind == .builder ? 1 : 2) }
        return rows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    static func firstLine(_ s: String?) -> String {
        let line = (s ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Waiting for you" : String(t.prefix(80))
    }

    /// The last `tool_use` in the tail of a Claude stream file (lenient: skips lines it cannot read).
    static func lastTool(inStreamTail text: String) -> (tool: String, detail: String?)? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"tool_use\"") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            for c in content.reversed() where c["type"] as? String == "tool_use" {
                guard let name = c["name"] as? String else { continue }
                let input = c["input"] as? [String: Any] ?? [:]
                let detail = (input["file_path"] ?? input["command"] ?? input["pattern"] ?? input["url"]) as? String
                return (name, detail)
            }
        }
        return nil
    }

    /// Read-only: last event line of one mission folder plus its brief's job tools.
    static func missionJobs(folder: URL) -> [MissionJobSnapshot] {
        struct Event: Decodable { var jobs: [String: MissionJobProgress] }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("events.jsonl")),
              let last = data.split(separator: 10).last,
              let ev = try? JSONDecoder().decode(Event.self, from: Data(last)) else { return [] }
        let text = (try? String(contentsOf: folder.appendingPathComponent("mission.md"), encoding: .utf8)) ?? ""
        let file = try? MissionFile.parse(text, peers: [])
        let mission = file?.name.isEmpty == false ? file!.name : folder.lastPathComponent
        let id = folder.lastPathComponent
        return ev.jobs.keys.sorted().map { title in
            let p = ev.jobs[title]!
            let idx = file?.jobs.firstIndex { $0.title == title }
            var info: MissionTaskInfo?
            if let file, let idx {
                info = MissionTaskInfo(job: file.jobs[idx], progress: p, base: file.into ?? "mission/\(id)",
                                       branch: PeerNaming.missionBranch(id: id, job: title, index: idx, attempt: p.attempt))
            }
            return MissionJobSnapshot(mission: mission, title: title, state: p.state, tool: idx.flatMap { file?.jobs[$0].tool }, info: info)
        }
    }
}

/// The live store. Read-only: it never starts, stops or answers anything.
@MainActor @Observable
final class AgentActivity {
    static let shared = AgentActivity()

    private(set) var rows: [ActivityRow] = []
    /// Mission job id (row id) -> what the task screen needs. Filled by `compute`.
    @ObservationIgnored private(set) var missionInfo: [String: MissionTaskInfo] = [:]
    @ObservationIgnored private(set) var builderNames: [String: BuilderRecord] = [:]
    @ObservationIgnored private var browser = BrowserMemory()
    @ObservationIgnored private var builderExtras: [String: (tool: (String, String?)?, browser: String?)] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tailing: Set<String> = []

    var ordered: [ActivityRow] { AgentActivityBuilder.ordered(rows) }
    /// Awake seats plus live builders; mission jobs do not count.
    var runningCount: Int { rows.filter { $0.kind != .mission && $0.status != "done" && $0.status != "failed" }.count }
    var needsYou: Bool { rows.contains { $0.needsYou } }

    func start() {
        guard !started else { return }
        started = true
        refresh()
    }

    func refresh(now: Date = Date()) {
        rows = compute(registry: .shared, hub: .shared, now: now)
        track()
    }

    /// One read of the current state; `registry` and `hub` are injectable so the control socket (and tests) can use their own.
    func compute(registry reg: AgentRegistry, hub: HubStore, now: Date = Date()) -> [ActivityRow] {
        let seats: [SeatSnapshot] = reg.panes.compactMap { name, pane in
            guard let a = reg.agent(named: name) else { return nil }
            let e = reg.latest[pane]
            if let e, let label = ActivityPhrase.browserLabel(tool: e.tool, detail: e.detail) {
                browser.note(agent: "seat:" + name, label: label, at: e.at)
            }
            return SeatSnapshot(name: name, pane: pane, project: a.repoName, model: a.model.rawValue,
                                effort: a.effort.rawValue, status: reg.statusOf(name), event: e,
                                context: reg.contexts[pane])
        }.sorted { $0.name < $1.name }
        let builders = hub.builders.map { b -> BuilderSnapshot in
            let x = builderExtras[b.id]
            return BuilderSnapshot(record: b, lastTool: x?.tool.map { (tool: $0.0, detail: $0.1) }, browser: x?.browser)
        }
        for b in hub.builders where b.state.isLive { tailBuilder(b) }
        let root = MissionRunner.liveRoot
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let missions = folders.sorted { $0.path < $1.path }.flatMap { AgentActivityBuilder.missionJobs(folder: $0) }
        missionInfo = Dictionary(missions.compactMap { m in m.info.map { (m.mission + "/" + m.title, $0) } }, uniquingKeysWith: { a, _ in a })
        builderNames = Dictionary(hub.builders.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let needs = Set(NeedsYouQueue.shared.rows.map(\.paneID))
        return AgentActivityBuilder.rows(seats: seats, needsYou: needs, builders: builders, missions: missions,
                                         browser: browser, now: now)
    }

    /// Re-run whenever the registry or hub changes; no timer.
    private func track() {
        withObservationTracking {
            let reg = AgentRegistry.shared
            _ = reg.status; _ = reg.panes; _ = reg.latest; _ = reg.contexts; _ = HubStore.shared.builders
            _ = NeedsYouQueue.shared.rows
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func tailBuilder(_ b: BuilderRecord) {
        guard let dir = b.dir, !tailing.contains(b.id) else { return }
        tailing.insert(b.id)
        let id = b.id
        Task.detached {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("stream.jsonl")
            var text = ""
            var mtime: Date?
            if let h = try? FileHandle(forReadingFrom: url) {
                let size = (try? h.seekToEnd()) ?? 0
                try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
                text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
                try? h.close()
                mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            }
            let tool = AgentActivityBuilder.lastTool(inStreamTail: text)
            let label = tool.flatMap { ActivityPhrase.browserLabel(tool: $0.tool, detail: $0.detail) }
            let fresh = mtime.map { Date().timeIntervalSince($0) <= BrowserMemory.window } ?? false
            await MainActor.run {
                let a = AgentActivity.shared
                a.tailing.remove(id)
                let new = (tool: tool.map { ($0.tool, $0.detail) }, browser: fresh ? label : nil)
                let old = a.builderExtras[id]
                a.builderExtras[id] = new
                if old?.tool?.0 != new.tool?.0 || old?.tool?.1 != new.tool?.1 || old?.browser != new.browser { a.refresh() }
            }
        }
    }
}
