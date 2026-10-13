import Testing
import Foundation
@testable import True

/// Fake runner: records every call, returns a scripted answer per stdin, tracks peak concurrency.
final class FakeRunner: CleanerRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(argv: [String], stdin: String, cwd: URL, env: [String: String])] = []
    private var active = 0
    private(set) var peak = 0
    var reply: @Sendable (String) throws -> String = { $0 }
    var delay: Duration = .milliseconds(30)

    private func begin(_ c: (argv: [String], stdin: String, cwd: URL, env: [String: String])) {
        lock.withLock { calls.append(c); active += 1; peak = max(peak, active) }
    }
    private func end() { lock.withLock { active -= 1 } }

    func run(binary: URL, argv: [String], stdin: Data, cwd: URL, env: [String: String],
             timeout: TimeInterval) async throws -> String {
        let text = String(decoding: stdin, as: UTF8.self)
        begin((argv, text, cwd, env))
        defer { end() }
        try await Task.sleep(for: delay)
        return try reply(text)
    }
}

private func files(_ texts: [String]) -> [ContextFile] {
    let home = cleanerTemp()
    for (i, t) in texts.enumerated() { cleanerWrite(home.appendingPathComponent("p\(i)/CLAUDE.md"), t) }
    return ContextScanner(home: home.path).scan(roots: (0..<texts.count).map { home.path + "/p\($0)" })
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var finished: [String: Result<RewriteOutcome, CleanerError>] = [:]
    private(set) var started: [String] = []
    func handle(_ sha: String, _ e: JobEvent) {
        lock.lock(); defer { lock.unlock() }
        switch e { case .started: started.append(sha); case .finished(let r): finished[sha] = r }
    }
}

@Suite struct CleanerEngineTests {
    private func engine(_ r: FakeRunner) -> CleanerEngine {
        CleanerEngine(runner: r, binary: URL(fileURLWithPath: "/fake/claude"),
                      cwd: URL(fileURLWithPath: "/fake/empty"), env: ["K": "V"])
    }

    @Test func identicalContentSharesOneJob() async {
        let fs = files([bigText, bigText, bigText + "different\n"])
        #expect(fs.count == 3)
        let r = FakeRunner()
        r.reply = { _ in "# Title\nshort" }
        let ev = Events()
        await engine(r).rewrite(fs, model: .sonnet) { ev.handle($0, $1) }
        #expect(r.calls.count == 2)
        #expect(ev.finished.count == 2)
        #expect(r.calls[0].argv == CleanerLaunch.argv(model: .sonnet))
        #expect(r.calls[0].cwd.path == "/fake/empty")
        #expect(r.calls[0].env == ["K": "V"])
        #expect(Set(r.calls.map(\.stdin)) == [bigText, bigText + "different\n"])
    }

    @Test func atMostThreeAtOnce() async {
        let fs = files((0..<8).map { bigText + "unique \($0)\n" })
        let r = FakeRunner()
        let ev = Events()
        await engine(r).rewrite(fs, model: .opus) { ev.handle($0, $1) }
        #expect(r.calls.count == 8)
        #expect(r.peak == 3)
        #expect(ev.finished.count == 8)
    }

    @Test func outcomeCarriesDroppedFactsAndLean() async throws {
        let orig = bigText + "Use `keepme` and `dropme`.\n"
        let fs = files([orig])
        let r = FakeRunner()
        r.reply = { _ in "```\n# Title\nUse `keepme`.\n```" }
        let ev = Events()
        await engine(r).rewrite(fs, model: .opus) { ev.handle($0, $1) }
        let o = try #require(try ev.finished[fs[0].sha]?.get())
        #expect(o.output == "# Title\nUse `keepme`.")
        #expect(o.dropped == ["dropme"])
        #expect(!o.isLean)

        let r2 = FakeRunner()   // echo back unchanged → lean
        let ev2 = Events()
        await engine(r2).rewrite(fs, model: .opus) { ev2.handle($0, $1) }
        #expect(try #require(try ev2.finished[fs[0].sha]?.get()).isLean)
    }

    @Test func runnerFailureAndEmptyOutputBecomeErrors() async {
        let fs = files([bigText, bigText + "b\n"])
        let r = FakeRunner()
        r.reply = { t in
            if t == bigText { throw CleanerError(message: "boom") }
            return "   "
        }
        let ev = Events()
        await engine(r).rewrite(fs, model: .opus) { ev.handle($0, $1) }
        #expect(ev.finished[fs[0].sha] == .failure(CleanerError(message: "boom")))
        #expect(ev.finished[fs[1].sha] == .failure(CleanerError(message: "Empty output")))
    }

    @Test func cancellationSkipsQueuedJobs() async {
        let fs = files((0..<6).map { bigText + "u\($0)\n" })
        let r = FakeRunner()
        r.delay = .seconds(5)
        let ev = Events()
        let e = engine(r)
        let t = Task { await e.rewrite(fs, model: .opus) { ev.handle($0, $1) } }
        try? await Task.sleep(for: .milliseconds(150))
        t.cancel()
        await t.value
        #expect(r.calls.count == 3)
        #expect(ev.finished.isEmpty)
    }
}
