import Testing
import Foundation
@testable import True

/// Run 36a step 1 (A0): big results, the seal-size cut, failure reasons, the paths line.
@Suite(.serialized) struct PeerResultTests {
    struct Rig {
        let a: PeerSide, b: PeerSide
        func close() { a.close(); b.close() }
    }
    func rig() -> Rig {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        return Rig(a: a, b: b)
    }
    func send(_ r: Rig, mode: PeerMode = .pane) -> String? {
        guard case .success(let id) = r.a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "do it", mode: mode, fromAgent: "lead-1") else { return nil }
        settle(r.a, r.b)
        return id
    }
    func finish(_ r: Rig, _ id: String, text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: r.b.engine.resultPath(id)))
        r.b.engine.paneEvent(pane: r.b.launcher.pane, kind: .stop); settle(r.a, r.b)
    }

    @Test func sixtyKBResultArrivesWhole() throws {
        let r = rig(); defer { r.close() }
        let id = try #require(send(r))
        let text = String(repeating: "abcdefghi\n", count: 6_000)       // 60,000 bytes
        try finish(r, id, text: text)
        #expect(r.a.engine.result(jobId: id)?.result == text)
    }

    @Test func emojiResultIsCutByBytesWithNoteAndSealNeverFails() throws {
        let r = rig(); defer { r.close() }
        let id = try #require(send(r))
        try finish(r, id, text: String(repeating: "😀", count: 64 * 1024))
        let done = try #require(r.a.engine.result(jobId: id))
        #expect(done.status == .done)
        let res = try #require(done.result)
        #expect(res.hasSuffix("(cut — full result in result.md)"))
        #expect(res.utf8.count <= PeerValidate.maxResult + PeerValidate.cutNote.utf8.count)
    }

    @Test func escapeHeavyResultStillSeals() throws {
        let r = rig(); defer { r.close() }
        let id = try #require(send(r))
        try finish(r, id, text: String(repeating: "\"\n", count: 32 * 1024))   // 64 KB that JSON doubles
        let done = try #require(r.a.engine.result(jobId: id))
        #expect(done.status == .done && (done.result ?? "").hasSuffix("(cut — full result in result.md)"))
    }

    @Test func clipBytesNeverSplitsACharacter() {
        #expect(PeerValidate.clipBytes("aé😀b", 3) == "aé")
        #expect(PeerValidate.clipBytes("abc", 10) == "abc")
    }

    @Test func failedPaneReportsItsReason() throws {
        let r = rig(); defer { r.close() }
        let id = try #require(send(r))
        r.b.engine.paneEvent(pane: r.b.launcher.pane, kind: .error, message: "API Error: 529 overloaded"); settle(r.a, r.b)
        let job = try #require(r.a.engine.status(jobId: id).first)
        #expect(job.status == .failed)
        #expect(job.note.hasPrefix("Hit an error: API Error: 529 overloaded"))
    }

    @Test func failureReasonMasksSecrets() throws {
        let r = rig(); defer { r.close() }
        let id = try #require(send(r))
        r.b.engine.paneEvent(pane: r.b.launcher.pane, kind: .error, message: "401 bad token=abc123secretvalue"); settle(r.a, r.b)
        let job = try #require(r.a.engine.status(jobId: id).first)
        #expect(!job.note.contains("abc123secretvalue"))
        #expect(job.note.contains("‹masked›"))
    }

    @Test func failedBuilderReportsReasonFromStreamThenStderr() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bld-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("boom 1\nboom 2\nboom 3\nboom 4\n".utf8).write(to: dir.appendingPathComponent("stderr.log"))
        #expect(PeerEngine.builderFailureReason(dir: dir.path) == "boom 2 boom 3 boom 4")
        let line = #"{"type":"result","is_error":true,"result":"Credit balance is too low"}"#
        try Data(("{\"type\":\"assistant\"}\n" + line + "\n").utf8).write(to: dir.appendingPathComponent("stream.jsonl"))
        #expect(PeerEngine.builderFailureReason(dir: dir.path) == "Credit balance is too low")

        let r = rig(); defer { r.close() }
        let id = try #require(send(r, mode: .background))
        let name = try #require(r.b.launcher.builders.first)
        r.b.engine.builderUpdate(name: name, running: true, dir: dir.path)
        r.b.engine.builderUpdate(name: name, running: false, dir: dir.path); settle(r.a, r.b)
        #expect(r.a.engine.status(jobId: id).first?.note == "Ended without a result: Credit balance is too low")
    }

    @Test func roleCardsAndHelpCarryThePathsLine() {
        let line = PeerText.pathsLine(peer: "Sam")
        #expect(line == "Paths you give Sam are paths on Sam's Mac. To send your own files use `--with` or `put`.")
        #expect(PeerText.roleCard(label: "Sam", branch: "b", worktree: "/w", resultPath: "/r").contains(line))
        #expect(PeerText.roleCardDir(label: "Sam", dir: "/d", resultPath: "/r").contains(line))
        #expect(PeerText.roleCardDesk(label: "Sam", workDir: "/d").contains(line))
        #expect(PeerText.roleCardNoRepo(label: "Sam", workDir: "/d", resultPath: "/r").contains(line))
    }
}
