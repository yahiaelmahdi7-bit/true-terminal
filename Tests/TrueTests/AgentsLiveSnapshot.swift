import AppKit
import SwiftUI
import Testing
@testable import True

/// Opt-in, read-only run against THIS Mac's real home. Skipped unless TRUE_LIVE=1 and TRUE_LIVE_OUT=<dir>:
///   TRUE_LIVE=1 TRUE_LIVE_OUT=<dir> swift test --filter AgentsLiveSnapshot
/// Reads ~/.claude/builders, ~/.true (agents.json, workspace.json, turns, missions), ~/.codex/sessions and the
/// Claude allowance (python reader, no probe). Writes only inside <dir>.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TRUE_LIVE"] == "1"
                && !(ProcessInfo.processInfo.environment["TRUE_LIVE_OUT"] ?? "").isEmpty, "TRUE_LIVE not set"))
struct AgentsLiveSnapshot {
    static let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_LIVE_OUT"] ?? "/dev/null")
    static let home = URL(fileURLWithPath: NSHomeDirectory())

    /// Seats on disk: agents that were awake at the last workspace save, status from their turn records.
    static func seats() -> [SeatSnapshot] {
        let root = home.appendingPathComponent(".true")
        let agents = ((try? Data(contentsOf: root.appendingPathComponent("agents.json")))
            .flatMap { try? JSONDecoder().decode(AgentsFile.self, from: $0) })?.agents ?? []
        let ws = (try? Data(contentsOf: root.appendingPathComponent("workspace.json")))
            .flatMap { try? JSONDecoder().decode(WorkspaceState.self, from: $0) }
        let turns = AgentTurnStore(directory: root.appendingPathComponent("turns")).allRecords()
        var out: [SeatSnapshot] = []
        for t in ws?.tabs ?? [] {
            for (pane, r) in t.resume ?? [:] {
                guard case let .agent(name) = r, let a = agents.first(where: { $0.name == name }) else { continue }
                let open = turns.contains { $0.seat == name && $0.isOpen }
                out.append(SeatSnapshot(name: name, pane: pane, project: a.repoName, model: a.model.rawValue,
                                        effort: a.effort.rawValue, status: open ? .working : .idle, event: nil))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    static func builders(now: Date) -> [BuilderSnapshot] {
        HubScanner.builders(in: home.appendingPathComponent(".claude/builders")).map { b in
            var tool: (tool: String, detail: String?)?
            var browser: String?
            if b.state.isLive, let dir = b.dir {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("stream.jsonl")
                if let h = try? FileHandle(forReadingFrom: url) {
                    let size = (try? h.seekToEnd()) ?? 0
                    try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
                    let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
                    try? h.close()
                    tool = AgentActivityBuilder.lastTool(inStreamTail: text)
                    let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                    if let t = tool, let l = ActivityPhrase.browserLabel(tool: t.tool, detail: t.detail),
                       let mtime, now.timeIntervalSince(mtime) <= BrowserMemory.window { browser = l }
                }
            }
            return BuilderSnapshot(record: b, lastTool: tool, browser: browser)
        }
    }

    static func missions() -> [MissionJobSnapshot] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: MissionRunner.liveRoot, includingPropertiesForKeys: nil)) ?? []
        return folders.sorted { $0.path < $1.path }.flatMap { AgentActivityBuilder.missionJobs(folder: $0) }
    }

    static func claudeUsage(now: Date) throws -> [UsageWindow] {
        let script = out.appendingPathComponent("allowance_reader.py")
        try AllowanceReader.source.write(to: script, atomically: true, encoding: .utf8)
        guard let data = UsageStore.run(script.path, "read") else { return [] }
        return UsageParsing.claude(data, now: now)
    }

    static func shot<V: View>(_ name: String, scheme: ColorScheme, _ content: V) throws {
        NSAppearance.current = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let view = content.frame(width: 312).background(scheme == .dark ? Theme.Token.bg0 : Color(white: 0.93))
            .environment(\.colorScheme, scheme)
        let r = ImageRenderer(content: view); r.scale = 2
        let tiff = try #require(r.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent(name))
    }

    @Test func snapshot() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let now = Date()
        let rows = AgentActivityBuilder.ordered(AgentActivityBuilder.rows(
            seats: Self.seats(), needsYou: [], builders: Self.builders(now: now), missions: Self.missions(),
            browser: BrowserMemory(), now: now))

        // (a) agents.json
        let agentJSON: [[String: Any]] = rows.map { ["kind": $0.kind.rawValue, "name": $0.name, "project": $0.project,
            "provider": $0.provider, "model": $0.model, "status": $0.status, "phrase": $0.activity] }
        try JSONSerialization.data(withJSONObject: agentJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.out.appendingPathComponent("agents.json"))

        // (b) usage.json, read the way the app does (Claude: allowance reader; Codex: newest rollout tail)
        let claude = try Self.claudeUsage(now: now)
        let codexHit = UsageParsing.codexLatestWithSource(
            sessions: Self.home.appendingPathComponent(".codex/sessions"), now: now)
        let iso = ISO8601DateFormatter()
        func entry(_ w: UsageWindow, source: String?) -> [String: Any] {
            var d: [String: Any] = ["provider": w.provider.rawValue, "window": w.kind.rawValue,
                                    "freshness": w.state.rawValue]
            d["percent"] = w.usedPercent ?? NSNull()
            d["resets_at"] = w.resetsAt.map { iso.string(from: $0) } ?? NSNull()
            d["read_at"] = w.readAt.map { iso.string(from: $0) } ?? NSNull()
            if let source { d["source_file"] = source }
            return d
        }
        let usageJSON = claude.map { entry($0, source: nil) }
            + (codexHit?.windows ?? []).map { entry($0, source: codexHit?.file.path) }
        try JSONSerialization.data(withJSONObject: usageJSON, options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.out.appendingPathComponent("usage.json"))

        // (c) the panel from the live snapshot
        let codexOn = ProgramFinder.shared.resolve("codex") != nil
        let usage = UsagePanelData(providers: codexOn ? [.claude, .codex] : [.claude],
                                   windows: claude + (codexHit?.windows ?? []))
        let git = PaneGitReader.read(folder: Self.home.appendingPathComponent("Projects/true").path)
        for (tag, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
            let running = rows.filter { $0.kind != .mission && $0.status != "done" && $0.status != "failed" }.count
            let panel = VStack(alignment: .trailing, spacing: 8) {
                AgentsPill(running: running, needsYou: rows.contains { $0.needsYou },
                           idle: AgentsPill.isIdle(running: running, usage: usage), solid: true)
                PanePanelView(status: git, solid: true, agents: rows, usage: usage,
                              places: PlaceSource.live(folder: Self.home.path).rows())
            }.padding(8)
            try Self.shot("panel-live-\(tag).png", scheme: scheme, panel)
        }
    }
}
