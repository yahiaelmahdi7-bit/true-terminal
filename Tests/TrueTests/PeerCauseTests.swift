import Testing
import Foundation
@testable import True

/// 100x Stage 2a: every failed job gets one cause, from plain string rules.
struct PeerCauseTests {
    static let notes: [String] = Array(repeating: "Stopped by sender", count: 7)
        + Array(repeating: "Peer removed", count: 3)
        + Array(repeating: "No local clone of https://github.com/example/app.git", count: 2)
        + ["Couldn't fetch the repo (fatal: repository 'https://github.com/example/app.git/' not found)",
           "Directory not allowed: ~/Desktop", "Directory not allowed: /Users/someone",
           "Hit an error: server_error", "Hit an error", "Hit an error"]

    @Test func eighteenHistoricalNotes() {
        #expect(Self.notes.count == 18)
        var counts: [PeerCause: Int] = [:]
        for n in Self.notes { counts[PeerLogic.cause(note: n), default: 0] += 1 }
        let line = PeerCause.allCases.compactMap { c in counts[c].map { "\($0) \(c.rawValue)" } }.joined(separator: ", ")
        print("18-note split: \(line)")
        #expect(counts[.senderStop] == 7 && counts[.peerRemoved] == 3 && counts[.repoSetup] == 3)
        #expect(counts[.preflight] == 2 && counts[.api] == 1 && counts[.unknown] == 2)
        #expect(counts.values.reduce(0, +) == 18)
    }

    @Test func otherRules() {
        #expect(PeerLogic.cause(note: "Hit an error: connection timed out") == .network)
        #expect(PeerLogic.cause(note: "Hit an error: it broke") == .agent)
        #expect(PeerLogic.cause(note: "Ended without a result") == .engine)
        #expect(PeerLogic.cause(note: "Stopped after 3 restarts") == .engine)
        #expect(PeerLogic.cause(note: "Ended without a result: usage limit reached") == .api)
    }

    func job(_ note: String, _ status: PeerStatus, at: Date) -> SentJob {
        SentJob(jobId: UUID().uuidString, peerLabel: "Bo", peerMailbox: "m", title: "t", repo: "r", base: "main", mode: .pane,
                fromAgent: "a", status: status, note: note, created: at, updated: at)
    }

    @Test func statsLine() {
        let now = Date()
        #expect(PeerLogic.statsLine([], now: now) == "No jobs sent in the last 7 days.")
        let jobs = [job("Stopped by sender", .canceled, at: now), job("Peer removed", .failed, at: now),
                    job("Hit an error", .failed, at: now), job("Finished", .done, at: now),
                    job("Peer removed", .failed, at: now.addingTimeInterval(-30 * 86400))]
        #expect(PeerLogic.statsLine(jobs, now: now) == "7 days: 4 sent, 3 failed · engine 1 · peer-removed 1 · sender-stop 1")
    }

    @Test func oldRecordDecodes() throws {
        let j = job("Peer removed", .failed, at: Date())
        var o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(j)) as! [String: Any]
        o["cause"] = nil
        let back = try JSONDecoder().decode(SentJob.self, from: JSONSerialization.data(withJSONObject: o))
        #expect(back.cause == nil && back.effectiveCause == .peerRemoved)
    }
}
