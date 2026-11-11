import Testing
import Foundation
@testable import True

/// 100x Stage 2b: an API hiccup pauses with backoff (1 / 5 / 15 min) instead of failing or resuming at once.
@Suite(.serialized) struct PeerTransientTests {
    func sides() -> (a: PeerSide, b: PeerSide, clock: Clock) {
        let relay = FakeRelay(), clock = Clock()
        let a = PeerSide("Al", relay: relay, clock: clock), b = PeerSide("Bo", relay: relay, clock: clock)
        pairUp(a, b)
        return (a, b, clock)
    }
    func send(_ a: PeerSide, mode: PeerMode) -> String? {
        if case .success(let id) = a.engine.delegate(peer: "Bea", repo: testRepo, title: "Fix it", brief: "x", mode: mode) { return id }
        return nil
    }
    func streamDir(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bld-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent("stream.jsonl"))
        return dir
    }
    let initLine = #"{"type":"system","subtype":"init","session_id":"sess-42"}"#
    let errLine = #"{"type":"result","is_error":true,"result":"API Error: 500 server_error"}"#

    @Test func transientRule() {
        for t in ["server_error", "API Error: 529 overloaded_error", "Internal 503", "rate_limit_error"] { #expect(PeerResume.isTransient(t), "\(t)") }
        for t in ["Usage limit reached, resets 3pm", "Service unavailable", "syntax error in foo.swift"] { #expect(!PeerResume.isTransient(t), "\(t)") }
        #expect([0, 1, 2, 3].map { PeerResume.backoff(resumes: $0) } == [60, 300, 900, 900])
    }

    @Test func agentJobPausesWithBackoffThenFailsWithApiCause() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let id = try #require(send(s.a, mode: .pane)); settle(s.a, s.b)
        s.b.launcher.sessions[s.b.launcher.pane] = "pane-session"
        for (n, wait) in [60.0, 300, 900].enumerated() {
            let pane = try #require(s.b.engine.inboundJobs().first?.pane)
            let t0 = s.clock.t
            s.b.engine.paneEvent(pane: pane, kind: .error, message: "API Error: 500 server_error")
            settle(s.a, s.b)
            let j = try #require(s.b.engine.inboundJobs().first)
            #expect(j.status == .paused && j.resumeAt == t0.addingTimeInterval(wait))
            #expect(s.b.launcher.resumeSessions.count == n)           // nothing resumed before the wait is over
            s.clock.t = t0.addingTimeInterval(wait)
            s.b.delays.fireDue(s.clock); settle(s.a, s.b)
            #expect(s.b.launcher.resumeSessions == Array(repeating: "pane-session", count: n + 1))
        }
        let pane = try #require(s.b.engine.inboundJobs().first?.pane)
        s.b.engine.paneEvent(pane: pane, kind: .error, message: "API Error: 500 server_error")
        settle(s.a, s.b)
        #expect(s.b.engine.inboundJobs().first?.status == .failed)
        let sent = try #require(s.a.engine.result(jobId: id))
        #expect(sent.status == .failed && sent.effectiveCause == .api)
    }

    @Test func agentJobWithoutSessionFailsWithApiCause() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let id = try #require(send(s.a, mode: .pane)); settle(s.a, s.b)
        s.b.engine.paneEvent(pane: s.b.launcher.pane, kind: .error, message: "API Error: 500 server_error")
        settle(s.a, s.b)
        let sent = try #require(s.a.engine.result(jobId: id))
        #expect(sent.status == .failed && sent.effectiveCause == .api && s.b.launcher.resumeSessions.isEmpty)
    }

    @Test func builderJobPausesOneMinuteThenResumesTheSameSession() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let id = try #require(send(s.a, mode: .background)); settle(s.a, s.b)
        let name = try #require(s.b.launcher.builders.first)
        let dir = try streamDir([initLine, errLine]); defer { try? FileManager.default.removeItem(at: dir) }
        s.b.engine.builderUpdate(name: name, running: true, dir: dir.path)
        let t0 = Date()
        while s.b.engine.inboundJobs().first?.sessionId == nil, Date().timeIntervalSince(t0) < 3 { usleep(20_000) }
        let start = s.clock.t
        s.b.engine.builderUpdate(name: name, running: false, dir: dir.path); settle(s.a, s.b)
        let j = try #require(s.b.engine.inboundJobs().first)
        #expect(j.status == .paused && j.resumeAt == start.addingTimeInterval(60) && s.b.launcher.resumeSessions.isEmpty)
        s.clock.t = start.addingTimeInterval(60)
        s.b.delays.fireDue(s.clock); settle(s.a, s.b)
        #expect(s.b.launcher.resumeSessions == ["sess-42"])
        #expect(s.a.engine.result(jobId: id)?.status != .failed)
    }

    @Test func builderJobWithoutSessionFailsWithApiCause() throws {
        let s = sides(); defer { s.a.close(); s.b.close() }
        let id = try #require(send(s.a, mode: .background)); settle(s.a, s.b)
        let name = try #require(s.b.launcher.builders.first)
        let dir = try streamDir([errLine]); defer { try? FileManager.default.removeItem(at: dir) }
        s.b.engine.builderUpdate(name: name, running: false, dir: dir.path); settle(s.a, s.b)
        let sent = try #require(s.a.engine.result(jobId: id))
        #expect(sent.status == .failed && sent.effectiveCause == .api)
    }
}
