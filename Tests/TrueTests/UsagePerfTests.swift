import Foundation
import Testing
@testable import True

/// Outside the default suite: `TRUE_USAGE_PERF=1 swift test --filter UsagePerf`. Writes about 2 GB of synthetic
/// history under a temp folder (removed after), scans it and checks the process stayed under 300 MB.
/// Run it alone: the number is the whole test process's peak, so other tests would add to it.
@Suite(.serialized) struct UsagePerf {
    static let on = ProcessInfo.processInfo.environment["TRUE_USAGE_PERF"] != nil

    @Test(.enabled(if: UsagePerf.on))
    func twoGigabytesScanUnderThreeHundredMegabytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude/projects/-perf"), codex = root.appendingPathComponent("codex/sessions/2026/11/09")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!

        // Real histories are mostly tool output: one turn line per ~6 KB of other lines. Written by a separate
        // python process so this process's peak memory is the scan's alone.
        let script = """
        import os, sys, time
        root, now = sys.argv[1], float(sys.argv[2])
        claude, codex = root + "/claude/projects/-perf", root + "/codex/sessions/2026/11/09"
        filler = '{"type":"user","message":{"content":"' + "x" * 5900 + '"}}\\n'
        written, n = 0, 0
        for i in range(40):
            path = (codex + "/rollout-%d.jsonl" if i % 4 == 3 else claude + "/s%d.jsonl") % i
            with open(path, "w") as f:
                size = 0
                while size < 50_000_000:
                    n += 1
                    if i % 4 == 3:
                        turn = '{"timestamp":"2026-11-09T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%d,"cached_input_tokens":%d,"cache_write_input_tokens":0,"output_tokens":%d,"total_tokens":%d}}}}\\n' % (n * 10, n, n, n * 11)
                    else:
                        turn = '{"type":"assistant","timestamp":"2026-11-09T10:00:00.000Z","message":{"id":"msg_%d","model":"claude-sonnet-4-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":50,"cache_read_input_tokens":100,"output_tokens":20}}}\\n' % n
                    chunk = filler + turn
                    f.write(chunk); size += len(chunk)
            written += size
            os.utime(path, (now - 60, now - 60))
        print(written, n)
        """
        let py = Process()
        py.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        py.arguments = ["python3", "-c", script, root.path, String(now.timeIntervalSince1970)]
        let out = Pipe(); py.standardOutput = out
        try py.run()
        let report = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")
        py.waitUntilExit()
        let written = Int(report.first ?? "0") ?? 0, n = Int(report.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        let targetBytes = 2_000_000_000
        #expect(written >= targetBytes)

        let scanner = UsageScanner(claudeRoot: root.appendingPathComponent("claude/projects"), codexRoot: root.appendingPathComponent("codex/sessions"),
                                   cacheDir: root.appendingPathComponent("cache"), timeZone: TimeZone(identifier: "UTC")!, now: { now })
        let first = scanner.scan()
        let again = scanner.scan()
        let mb = first.peakMemoryBytes / 1_048_576
        print("usage perf: \(written / 1_000_000) MB scanned in \(String(format: "%.1f", first.seconds)) s, peak \(mb) MB, rescan \(String(format: "%.2f", again.seconds)) s, turns \(n)")
        #expect(first.bytesRead >= Int64(targetBytes))
        #expect(first.peakMemoryBytes < 300 * 1_048_576, "peak \(mb) MB")
        #expect(again.bytesRead == 0 && again.seconds < 2)
        #expect(scanner.buckets().reduce(0) { $0 + $1.tokens.output } > 0)
    }
}
