import Testing
import Foundation
@testable import True

/// Scores each file by a marker in its content ("S=2.5"), counts peak concurrency.
final class ScoreJev: JevTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    private(set) var calls = 0
    let delay: Duration
    let stall: Bool
    init(delay: Duration = .milliseconds(20), stall: Bool = false) { self.delay = delay; self.stall = stall }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        lock.withLock { active += 1; peak = max(peak, active); calls += 1 }
        defer { lock.withLock { active -= 1 } }
        if stall { try await Task.sleep(for: .seconds(30)) }
        try await Task.sleep(for: delay)
        let obj = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let file = (obj["state"] as? [String: String])?["file"] ?? ""
        var answers: [String: Any] = [:]
        if let r = file.range(of: #"S=([0-9.]+)"#, options: .regularExpression) {
            answers["pad"] = ["type": "score", "score": Double(file[r].dropFirst(2)) ?? 0, "confidence": 0.5]
        }
        return (200, try JSONSerialization.data(withJSONObject: ["answers": answers]))
    }
}

private func files(_ texts: [String]) -> [ContextFile] {
    let home = cleanerTemp()
    for (i, t) in texts.enumerated() { cleanerWrite(home.appendingPathComponent("p\(i)/CLAUDE.md"), t) }
    let all = ContextScanner(home: home.path).scan(roots: (0..<texts.count).map { home.path + "/p\($0)" })
    // scan order is by path, which is p0, p1, ... — keep it deterministic for the assertions
    return all.sorted { $0.path < $1.path }
}

private func pad(_ marker: String) -> String { marker + " " + String(repeating: "x", count: 500) }

@Suite struct CleanerOrderingTests {
    @Test func sortsByScoreDescendingAndStably() {
        let fs = files([pad("a S=0.4"), pad("b S=2.5"), pad("c S=0.4"), pad("d S=3.0")])
        let scores = Dictionary(uniqueKeysWithValues: zip(fs.map(\.sha), [0.4, 2.5, 0.4, 3.0]))
        let out = CleanerOrdering.sorted(fs, scores: scores).map(\.path)
        #expect(out == [fs[3], fs[1], fs[0], fs[2]].map(\.path))   // ties (0.4) keep scan order
    }

    @Test func missingScoreCountsAsOne() {
        let fs = files([pad("a"), pad("b"), pad("c")])
        let out = CleanerOrdering.sorted(fs, scores: [fs[2].sha: 2.0, fs[0].sha: 0.2]).map(\.path)
        #expect(out == [fs[2], fs[1], fs[0]].map(\.path))    // 2.0, unscored 1.0, 0.2
    }

    @Test func allUnscoredKeepsScanOrder() {
        let fs = files([pad("a"), pad("b"), pad("c")])
        #expect(CleanerOrdering.sorted(fs, scores: [:]).map(\.path) == fs.map(\.path))
    }

    @Test func questionUsesTheVerbatimLevels() {
        guard case .score(let levels) = CleanerOrdering.question.kind else { Issue.record("not a score"); return }
        #expect(levels.count == 4 && levels[0].hasPrefix("Already lean:") && levels[3].hasPrefix("Heavily padded:"))
        #expect(CleanerOrdering.question.focus?.hasPrefix("Judge filler") == true)
    }

    @Test func scoresPerUniqueContentWithAtMostEightInFlight() async {
        var texts = (0..<20).map { pad("f\($0) S=\(Double($0) / 10)") }
        texts.append(texts[0])            // identical copy: scored once
        let fs = files(texts)
        let t = ScoreJev(delay: .milliseconds(40))
        let jev = JevClient(transport: t, keyProvider: { "k" }, env: [:])
        let s = await CleanerOrdering.scores(for: fs, jev: jev)
        #expect(s.count == 20 && t.calls == 20)
        #expect(t.peak <= 8 && t.peak > 1)
    }

    @Test func triageNeverHoldsTheQueueBeyondTheOverallDeadline() async {
        let fs = files([pad("a S=1"), pad("b S=2"), pad("c S=3")])
        let jev = JevClient(transport: ScoreJev(stall: true), keyProvider: { "k" }, env: [:])
        let start = Date()
        let s = await CleanerOrdering.scores(for: fs, jev: jev, perCall: 5, overall: 0.3)
        #expect(s.isEmpty)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func orderFallsThroughWithoutJevOrKey() async {
        let fs = files([pad("a S=0.1"), pad("b S=3")])
        #expect(await CleanerOrdering.order(fs, jev: nil).map(\.path) == fs.map(\.path))
        let keyless = JevClient(transport: ScoreJev(), keyProvider: { nil }, env: [:])
        #expect(await CleanerOrdering.order(fs, jev: keyless).map(\.path) == fs.map(\.path))
        let real = JevClient(transport: ScoreJev(), keyProvider: { "k" }, env: [:])
        #expect(await CleanerOrdering.order(fs, jev: real).map(\.path) == [fs[1], fs[0]].map(\.path))
    }
}
