import Testing
import Foundation
@testable import True

/// Run 36a step 4 (A4): a builder's stream.jsonl becomes activity items. The fixture is a trimmed real
/// `~/.claude/builders/fdos-migration-m1-*/stream.jsonl` (same line shapes, shortened strings).
@Suite(.serialized) struct PeerStreamTests {
    static let fixture = [
        #"{"type":"system","subtype":"hook_started"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":""}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git status --short && npm test","timeout":120000}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Relay requested: commit the step in progress, then write relay.md."}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/repo/a.swift"}}]}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
        #"{"type":"result","is_error":true,"result":"Credit balance is too low token=abc12345"}"#,
    ]
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func fixtureYieldsToolAndAssistantItemsInOrder() {
        let everything = Self.fixture.flatMap { PeerStream.items(line: $0, at: at, level: .everything) }
        #expect(everything.map(\.kind) == [.tool, .assistant, .tool, .status])
        #expect(everything[0].text == "Bash · git status --short && npm test")
        #expect(everything[1].text.hasPrefix("Relay requested"))
        #expect(everything[2].text == "Read · /repo/a.swift")
        #expect(everything[3].text.hasPrefix("Ended with an error: Credit balance") && !everything[3].text.contains("abc12345"))
        let activity = Self.fixture.flatMap { PeerStream.items(line: $0, at: at, level: .activity) }
        #expect(activity[0].text == "Bash")                     // never a command at Activity
        #expect(Self.fixture.flatMap { PeerStream.items(line: $0, at: at, level: .status) }.isEmpty)
    }

    func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    final class Lines: @unchecked Sendable {
        let lock = NSLock(); private var v: [String] = []
        func add(_ l: [String]) { lock.lock(); v += l; lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return v }
    }
    func wait(_ lines: Lines, count: Int) async {
        for _ in 0..<100 where lines.all.count < count { try? await Task.sleep(nanoseconds: 50_000_000) }
    }
    func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.close()
    }

    @Test func tailerFollowsGrowthAndARotatedFile() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stream.jsonl")
        try Data("one\ntw".utf8).write(to: url)
        let got = Lines()
        let t = PeerStreamTailer(path: url.path) { got.add($0) }
        defer { t.stop() }
        await wait(got, count: 1)
        #expect(got.all == ["one"])                                // the partial line waits
        try append("o\nthree\n", to: url)
        await wait(got, count: 3)
        #expect(got.all == ["one", "two", "three"])
        // `builder resume` rotates the file: the old one is moved away, a new one appears.
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("stream.1.jsonl"))
        try Data("four\n".utf8).write(to: url)
        await wait(got, count: 4)
        #expect(got.all.last == "four")
        try append("five\n", to: url)
        await wait(got, count: 5)
        #expect(got.all.last == "five")
    }

    @Test func engineStreamsBuilderStepsToTheSender() async throws {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        defer { a.close(); b.close() }
        pairUp(a, b)
        b.knobs.share = .everything
        guard case .success(let id) = a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "do it", mode: .background, fromAgent: "lead-1") else { Issue.record("delegate failed"); return }
        a.engine.watchJob(jobId: id); settle(a, b)
        let name = try #require(b.launcher.builders.first)
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stream.jsonl")
        try Data((Self.fixture[2] + "\n" + Self.fixture[4] + "\n").utf8).write(to: url)
        b.engine.builderUpdate(name: name, running: true, dir: dir.path)
        for _ in 0..<100 { try await Task.sleep(nanoseconds: 50_000_000); clock.t += 3; b.engine.flushActivity(id); settle(a, b)
            if a.engine.activity(jobId: id).contains(where: { $0.kind == .assistant }) { break } }
        let got = a.engine.activity(jobId: id).filter { $0.kind == .tool || $0.kind == .assistant }
        #expect(got.map(\.kind) == [.tool, .assistant])
        #expect(got.first?.text == "Bash · git status --short && npm test")
    }
}
