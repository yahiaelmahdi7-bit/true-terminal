import Testing
import Foundation
@testable import True

/// Replies with a fixed body; optionally holds each request until `release()` so tests can interleave events.
private func body(_ outcome: String, conf: Double = 0.9, proof: Double = 0.1, contradiction: Double = 0.05) -> Data {
    Data("""
    {"model":"jev-latest","answers":{
     "outcome":{"type":"choice","choice":"\(outcome)","confidence":\(conf),"probabilities":{"\(outcome)":\(conf)}},
     "proof":{"type":"noul","noul":\(proof)},
     "contradiction":{"type":"noul","noul":\(contradiction)},
     "next_safe":{"type":"noul","noul":0.5}}}
    """.utf8)
}

private let fixedDigest = TurnDigest(asked: "ship it API_KEY=abc123", steps: [TurnStep(n: 1, tool: "Bash", what: "ls", result: "ok", failed: false)],
                                     edited: true, answer: "done")

@MainActor
@Suite struct OverseerStoreTests {
    private func tmp() -> URL { URL(fileURLWithPath: NSTemporaryDirectory() + "ov-\(UUID().uuidString)") }

    private func make(_ t: FakeJev, enabled: @escaping () -> Bool = { true }, key: String? = "k",
                      dir: URL? = nil) -> OverseerStore {
        OverseerStore(jev: JevClient(transport: t, keyProvider: { key }, env: [:]), enabled: enabled,
                      log: OverseerLog(dir: dir ?? tmp()), cwdFor: { _ in "/Users/example/Projects/true" },
                      loadDigest: { _, _ in fixedDigest })
    }

    private func stop(_ pane: UUID, session: String? = "s1") -> PaneEvent {
        PaneEvent(pane: pane, kind: .stop, message: "done", at: Date(), transcript: "/tmp/x.jsonl", session: session)
    }
    private func prompt(_ pane: UUID) -> PaneEvent { PaneEvent(pane: pane, kind: .progress, message: "prompt", at: Date()) }

    private func settle(_ store: OverseerStore, _ extra: () -> Bool = { true }) async {
        for _ in 0..<200 {
            if store.judging == 0 && extra() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func stopProducesVerdict() async {
        let s = make(FakeJev(.reply(200, body("finished", proof: 0.9))))
        let pane = UUID()
        s.handle(stop(pane))
        await settle(s)
        let v = s.verdicts[pane]
        #expect(v?.kind == .verified && v?.sessionID == "s1" && v?.cwd == "/Users/example/Projects/true")
        #expect(s.verdict(forSession: "s1")?.kind == .verified)
    }

    @Test func newPromptAndCloseClear() async {
        let s = make(FakeJev(.reply(200, body("blocked"))))
        let a = UUID(), b = UUID()
        s.handle(stop(a)); s.handle(stop(b))
        await settle(s)
        #expect(s.verdicts.count == 2)
        s.handle(prompt(a)); #expect(s.verdicts[a] == nil)
        s.paneClosed(b); #expect(s.verdicts[b] == nil)
    }

    @Test func errorEventsAreNotJudged() async {
        let t = FakeJev(.reply(200, body("blocked")))
        let s = make(t)
        s.handle(PaneEvent(pane: UUID(), kind: .error, message: "x", at: Date(), transcript: "/tmp/x.jsonl", session: "s"))
        await settle(s)
        #expect(t.requests.isEmpty && s.verdicts.isEmpty)
    }

    @Test func lateReplyAfterNewPromptIsDropped() async {
        let t = FakeJev(.reply(200, body("blocked")))
        let s = make(t)
        let pane = UUID()
        s.handle(stop(pane))
        s.handle(prompt(pane))          // the user typed again before Jev answered
        await settle(s)
        #expect(t.requests.count == 1 && s.verdicts[pane] == nil)
    }

    @Test func toggleOffMakesNoCall() async {
        let t = FakeJev(.reply(200, body("blocked")))
        let s = make(t, enabled: { false })
        s.handle(stop(UUID()))
        await settle(s)
        #expect(t.requests.isEmpty && s.verdicts.isEmpty)
    }

    @Test func clearAllDropsVerdictsAndInFlight() async {
        let t = FakeJev(.reply(200, body("blocked")))
        let s = make(t)
        let a = UUID(), b = UUID()
        s.handle(stop(a)); await settle(s)
        s.handle(stop(b)); s.clearAll()
        await settle(s)
        #expect(s.verdicts.isEmpty)
    }

    @Test func jevNilMeansNoVerdictAndNoLog() async {
        let dir = tmp()
        let s = make(FakeJev(.fail), dir: dir)
        let pane = UUID()
        s.handle(stop(pane)); await settle(s)
        #expect(s.verdicts[pane] == nil)
        #expect(!FileManager.default.fileExists(atPath: OverseerLog(dir: dir).file.path))
        let keyless = make(FakeJev(.reply(200, body("blocked"))), key: nil)
        keyless.handle(stop(pane)); await settle(keyless)
        #expect(keyless.verdicts[pane] == nil)
    }

    @Test func oneCallPerPaneInFlight() async {
        let t = FakeJev(.reply(200, body("blocked")))
        let s = make(t)
        let pane = UUID()
        s.handle(stop(pane)); s.handle(stop(pane))
        #expect(s.judging == 1)
        await settle(s)
        #expect(t.requests.count == 1)
    }

    @Test func sixInFlightOverall() async {
        let t = FakeJev(.reply(200, body("blocked")))
        let s = make(t)
        for _ in 0..<8 { s.handle(stop(UUID())) }
        #expect(s.judging == OverseerStore.maxInFlight)
        await settle(s)
        #expect(t.requests.count == 6 && s.verdicts.count == 6)
    }

    @Test func logIsRedactedPrivateAndComplete() async throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = make(FakeJev(.reply(200, body("finished", proof: 0.1))), dir: dir)
        let log = OverseerLog(dir: dir)
        s.handle(stop(UUID()))
        // OverseerLog creates the file empty, then writes the line: wait for the newline, not just the file
        await settle(s) { (try? String(contentsOf: log.file, encoding: .utf8))?.hasSuffix("\n") == true }
        let text = try String(contentsOf: log.file, encoding: .utf8)
        #expect(!text.contains("abc123") && text.contains("[redacted]"))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(obj["verdict"] as? String == "unverified")
        let answers = try #require(obj["answers"] as? [String: Any])
        #expect(Set(answers.keys) == ["outcome", "proof", "contradiction", "next_safe"])
        #expect(obj["latencyMs"] != nil && obj["state"] != nil && obj["session"] as? String == "s1")
        func mode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int) ?? 0 }
        #expect(mode(log.file) == 0o600 && mode(dir) == 0o700)
    }

    @Test func logRotatesOverFiveMegabytes() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = OverseerLog(dir: dir)
        let rec = OverseerLog.Record(at: Date(), pane: UUID(), session: nil, cwd: nil, judgment: OverseerJudgment(),
                                     latencyMs: 1, digest: fixedDigest.redacted)
        log.append(rec)
        let h = try FileHandle(forWritingTo: log.file)
        try h.truncate(atOffset: UInt64(OverseerLog.maxBytes + 10))
        try h.close()
        log.append(rec)
        #expect(FileManager.default.fileExists(atPath: log.rotated.path))
        #expect(((try? FileManager.default.attributesOfItem(atPath: log.file.path))?[.size] as? Int ?? 0) < 100_000)
    }
}

@Suite struct OverseerWireTests {
    private func line(_ s: String) -> Data { Data(s.utf8) }
    private let pane = UUID()

    @Test func paneEventParsesWithAndWithoutTranscript() {
        let old = PaneEvent.parse(line: line(#"{"pane":"\#(pane.uuidString)","event":"stop","message":"x"}"#))
        #expect(old?.transcript == nil && old?.session == nil)
        let new = PaneEvent.parse(line: line(#"{"pane":"\#(pane.uuidString)","event":"stop","message":"x","transcript":"/t.jsonl","session":"abc"}"#))
        #expect(new?.transcript == "/t.jsonl" && new?.session == "abc")
        let blank = PaneEvent.parse(line: line(#"{"pane":"\#(pane.uuidString)","event":"stop","transcript":"","session":""}"#))
        #expect(blank?.transcript == nil && blank?.session == nil)
    }

    @Test func hubRowEncodesVerdict() throws {
        let with = HubRow(project: "p", kind: "seat", name: "n", status: "idle", verdict: "blocked")
        let obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as? [String: Any])
        #expect(obj["verdict"] as? String == "blocked")
        let without = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            HubRow(project: "p", kind: "seat", name: "n", status: "idle"))) as? [String: Any])
        #expect(without["verdict"] == nil)
    }

    /// Real forwarder → real socket. Runs python3 only (never claude).
    private func forward(_ payload: String) throws -> PaneEvent? {
        let root = URL(fileURLWithPath: "/tmp/ov-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(root: root)
        AgentHooks.installPaneHooks(paths: paths)
        let sock = "/tmp/ov-\(UUID().uuidString.prefix(8)).sock"
        let got = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var event: PaneEvent? }
        let box = Box()
        let listener = AgentEventSocket(path: sock) { box.event = $0; got.signal() }
        guard listener.start() else { return nil }
        defer { listener.stop() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", paths.forwarderPath]
        p.environment = ["TRUE_PANE_ID": pane.uuidString, "TRUE_EVENTS_SOCK": sock, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
        let stdin = Pipe(); p.standardInput = stdin
        p.standardOutput = Pipe()
        try p.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        guard got.wait(timeout: .now() + 3) == .success else { return nil }
        return box.event
    }

    @Test func forwarderAddsTranscriptAndSessionOnStopOnly() throws {
        let stop = try #require(try forward(#"{"hook_event_name":"Stop","last_assistant_message":"done","transcript_path":"/t/x.jsonl","session_id":"sess-1"}"#))
        #expect(stop.kind == .stop && stop.message == "done" && stop.transcript == "/t/x.jsonl" && stop.session == "sess-1")
        let bare = try #require(try forward(#"{"hook_event_name":"Stop","last_assistant_message":"x","transcript_path":7}"#))
        #expect(bare.transcript == nil && bare.session == nil)
        let other = try #require(try forward(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","transcript_path":"/t/x.jsonl","session_id":"sess-1"}"#))
        #expect(other.transcript == nil)
    }
}

@MainActor
@Suite struct YourMoveRowTests {
    @Test func folderTitleIsSaidOnceAndVerifiedIsLeftOut() {
        let a = UUID(), b = UUID(), c = UUID()
        let at = Date(timeIntervalSince1970: 1_000)
        let cwd = "/tmp/true-overseer-nogit/true"
        let v: [UUID: OverseerVerdict] = [
            a: OverseerVerdict(kind: .unverified, reason: "r", at: at, sessionID: nil, cwd: cwd),
            b: OverseerVerdict(kind: .blocked, reason: "r", at: at, sessionID: nil, cwd: cwd),
            c: OverseerVerdict(kind: .verified, reason: "r", at: at, sessionID: nil, cwd: cwd),
        ]
        let rows = YourMoveRow.build(v, seatName: { $0 == b ? "lead" : nil }, tabTitle: { _ in "true" })
        #expect(rows.map(\.pane) == [b, a])
        #expect(rows[0].name == "lead" && rows[0].project == "true")
        #expect(rows[1].name == "true" && rows[1].project.isEmpty)
        #expect(rows[1].spoken == "true, Unverified, r")
    }
}
