import Foundation
import Testing
@testable import True

@Suite struct ActivityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func seat(_ name: String, status: AgentStatus, tool: String? = nil, detail: String? = nil,
              kind: PaneEventKind = .progress, message: String = "") -> SeatSnapshot {
        let pane = UUID()
        return SeatSnapshot(name: name, pane: pane, project: "true", model: "opus", effort: "high", status: status,
                            event: PaneEvent(pane: pane, kind: kind, message: message, at: now, tool: tool, detail: detail))
    }

    func record(_ id: String, state: BuilderState, raw: String = "") -> BuilderRecord {
        var r = BuilderRecord.parse(Data(#"{"id":"\#(id)","name":"\#(id)","started":1,"status":"running"}"#.utf8), alive: { _ in true })!
        r.state = state; r.rawStatus = raw
        return r
    }

    @Test func phraseTableAndFallback() {
        #expect(ActivityPhrase.phrase(tool: "Edit", detail: "/a/b/Foo.swift") == "Editing Foo.swift")
        #expect(ActivityPhrase.phrase(tool: "Bash", detail: "swift test --filter x") == "Running tests")
        #expect(ActivityPhrase.phrase(tool: "Mystery", detail: nil) == "Working")
        #expect(ActivityPhrase.phrase(tool: "MCP", detail: "playwright:click") == "Using the browser")
    }

    @Test func seatNeedsYouComesOnlyFromTheQueue() {
        let working = seat("a", status: .working, tool: "Read", detail: "/x/Y.swift")
        let ask = seat("b", status: .needsYou, kind: .need, message: "Run rm?\nsecond line")
        let rows = AgentActivityBuilder.rows(seats: [working, ask], needsYou: [ask.pane], builders: [], missions: [],
                                             browser: BrowserMemory(), now: now)
        #expect(rows[0].status == "working" && rows[0].activity == "Reading Y.swift" && !rows[0].needsYou)
        #expect(rows[1].status == "needs-you" && rows[1].activity == "Needs you: Run rm?")
        // The same seat without a queue entry is not needs-you.
        let none = AgentActivityBuilder.rows(seats: [ask], needsYou: [], builders: [], missions: [],
                                             browser: BrowserMemory(), now: now)
        #expect(!none[0].needsYou)
    }

    @Test func idleAndDoneSeats() {
        let rows = AgentActivityBuilder.rows(seats: [seat("i", status: .idle), seat("d", status: .done)], needsYou: [],
                                             builders: [], missions: [], browser: BrowserMemory(), now: now)
        #expect(rows.map(\.activity) == ["Waiting", "Done"])
    }

    @Test func buildersAndMissionJobsOnlyWhenLive() {
        let live = BuilderSnapshot(record: record("t3", state: .running), lastTool: ("Grep", nil), browser: "Browser")
        let held = BuilderSnapshot(record: record("h", state: .held), lastTool: nil, browser: nil)
        let wait = BuilderSnapshot(record: record("w", state: .waiting), lastTool: nil, browser: nil)
        let jobs = [MissionJobSnapshot(mission: "M", title: "one", state: .running, tool: nil),
                    MissionJobSnapshot(mission: "M", title: "two", state: .merged, tool: nil),
                    MissionJobSnapshot(mission: "M", title: "three", state: .needsYou, tool: nil)]
        let rows = AgentActivityBuilder.rows(seats: [], needsYou: [], builders: [live, held, wait], missions: jobs,
                                             browser: BrowserMemory(), now: now)
        #expect(rows.map(\.name) == ["t3", "w", "one", "three"])
        #expect(rows[0].activity == "Searching the code" && rows[0].browser == "Browser" && !rows[0].needsYou)
        #expect(rows[1].needsYou && rows[3].needsYou)
        let ordered = AgentActivityBuilder.ordered(rows).map(\.name)
        #expect(ordered == ["w", "three", "t3", "one"])
    }

    @Test func browserRuleTenMinuteWindow() {
        var m = BrowserMemory()
        m.note(agent: "seat:a", label: "Browser", at: now)
        #expect(m.label(for: "seat:a", now: now.addingTimeInterval(599)) == "Browser")
        #expect(m.label(for: "seat:a", now: now.addingTimeInterval(601)) == nil)
    }

    @Test func streamTailLastToolUse() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/B.swift"}}]}}
        garbage "tool_use"
        {"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}
        """
        let t = AgentActivityBuilder.lastTool(inStreamTail: text)
        #expect(t?.tool == "Bash" && t?.detail == "swift build")
        #expect(AgentActivityBuilder.lastTool(inStreamTail: "") == nil)
    }

    @Test func missionJobsReadFromEventsAndFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("act-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Mission: Demo\n\n## Alpha\nrepo: /tmp\nbrief\n".write(to: dir.appendingPathComponent("mission.md"), atomically: true, encoding: .utf8)
        let ev = #"{"time":1,"state":"running","jobs":{"Alpha":{"state":"running"}}}"# + "\n"
        try ev.write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        let jobs = AgentActivityBuilder.missionJobs(folder: dir)
        #expect(jobs.count == 1 && jobs[0].title == "Alpha" && jobs[0].mission == "Demo" && jobs[0].state == .running)
        // The task screen opens the job from its snapshot.
        let info = try #require(jobs[0].info)
        let target = TaskTarget.mission(info, folder: "", provider: "Claude")
        #expect(target.id.hasPrefix("m-peer/"))
        let detail = target.load().detail
        #expect(detail.title == "Alpha" && !detail.finished)
    }
}
