import Testing
import Foundation
@testable import True

/// Synthetic transcript lines.
enum TL {
    static func j(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }
    static func user(_ text: String, extra: [String: Any] = [:]) -> String {
        j(["type": "user", "message": ["role": "user", "content": text]].merging(extra) { $1 })
    }
    static func text(_ t: String, extra: [String: Any] = [:]) -> String {
        j(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": t]]]].merging(extra) { $1 })
    }
    static func tool(_ id: String, _ name: String, _ input: [String: String]) -> String {
        j(["type": "assistant", "message": ["role": "assistant",
            "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }
    static func result(_ id: String, _ text: String, error: Bool = false) -> String {
        var b: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": text]
        if error { b["is_error"] = true }
        return j(["type": "user", "message": ["role": "user", "content": [b]]])
    }
    static func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
}

@Suite struct TurnDigestTests {
    @Test func buildsLastTurnWithPairing() {
        let d = TL.data([
            TL.user("first prompt"), TL.text("old answer"),
            TL.user("fix the bug"),
            TL.tool("t1", "Bash", ["command": "swift test"]), TL.result("t1", "ok\n  all   passed"),
            TL.tool("t2", "Edit", ["file_path": "/a/b.swift"]), TL.result("t2", "boom", error: true),
            TL.text("All done."),
        ])
        let (g, had) = TurnDigestBuilder.build(d, stopMessage: nil)
        #expect(had && g.asked == "fix the bug")
        #expect(g.steps.count == 2 && g.steps[0].tool == "Bash" && g.steps[0].what == "swift test")
        #expect(g.steps[0].result == "ok all passed" && !g.steps[0].failed)
        #expect(g.steps[1].failed && g.steps[1].result == "boom")
        #expect(g.edited && g.answer == "All done.")
    }

    @Test func tailStartingMidTurnHasNoPrompt() {
        let d = TL.data([TL.tool("t1", "Bash", ["command": "ls"]), TL.result("t1", "x"), TL.text("hi")])
        let (g, had) = TurnDigestBuilder.build(d, stopMessage: nil)
        #expect(!had && g.asked == "" && g.steps.count == 1)
    }

    @Test func stopMessageWinsOverTranscriptText() {
        let d = TL.data([TL.user("q"), TL.text("transcript text")])
        #expect(TurnDigestBuilder.build(d, stopMessage: "stop text").digest.answer == "stop text")
        #expect(TurnDigestBuilder.build(d, stopMessage: "  ").digest.answer == "transcript text")
    }

    @Test func sidechainMetaAndCompactLinesIgnored() {
        let d = TL.data([
            TL.user("real"),
            TL.user("sidechain prompt", extra: ["isSidechain": true]),
            TL.user("meta", extra: ["isMeta": true]),
            TL.user("summary", extra: ["isCompactSummary": true]),
            TL.text("sub answer", extra: ["isSidechain": true]),
            TL.text("api error", extra: ["isApiErrorMessage": true]),
        ])
        let g = TurnDigestBuilder.build(d, stopMessage: nil).digest
        #expect(g.asked == "real" && g.answer == "" && g.steps.isEmpty && !g.edited)
    }

    @Test func emptyAnswerStaysEmpty() {
        let g = TurnDigestBuilder.build(TL.data([TL.user("q")]), stopMessage: "").digest
        #expect(g.answer == "")
    }

    @Test func thirtyStepCapKeepsNewestAndPairing() {
        var lines = [TL.user("go")]
        for i in 1...35 {
            lines += [TL.tool("t\(i)", "Bash", ["command": "cmd\(i)"]), TL.result("t\(i)", "r\(i)", error: i == 35)]
        }
        let g = TurnDigestBuilder.build(TL.data(lines), stopMessage: nil).digest
        #expect(g.steps.count == 30 && g.steps.first?.n == 6 && g.steps.last?.n == 35)
        #expect(g.steps.first?.result == "r6" && g.steps.last?.failed == true)
    }

    @Test func limitsApply() {
        let long = String(repeating: "a", count: 2_000)
        let answer = String(repeating: "x", count: 4_000)
        let d = TL.data([TL.user(long), TL.tool("t", "Bash", ["command": "c"]),
                         TL.result("t", String(repeating: "y", count: 500))])
        let g = TurnDigestBuilder.build(d, stopMessage: answer).digest
        #expect(g.asked.count == 1_500 && g.steps[0].result.count == 240)
        #expect(g.answer.count == 800 + 3 + 2_200 && g.answer.contains(" … "))
    }

    @Test func loadGrowsWindowUntilPromptInside() throws {
        var lines = [TL.user("the ask")]
        for i in 0..<40 { lines += [TL.tool("t\(i)", "Bash", ["command": "echo \(i)"]), TL.result("t\(i)", String(repeating: "z", count: 300))] }
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "td-\(UUID().uuidString).jsonl")
        try TL.data(lines).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let g = try #require(TurnDigestBuilder.load(url: url, stopMessage: "done", chunk: 1_024))
        #expect(g.asked == "the ask" && g.steps.count == 30)
        // A cap smaller than the turn stops growing: no prompt, but a digest all the same.
        let capped = try #require(TurnDigestBuilder.load(url: url, stopMessage: "done", chunk: 1_024, maxWindow: 2_048))
        #expect(capped.asked == "")
        #expect(TurnDigestBuilder.load(url: url.appendingPathExtension("missing"), stopMessage: nil) == nil)
    }
}

@Suite struct RedactTests {
    @Test func stripsEachSecretShape() {
        let samples = [
            "sk-abcdefgh12345678", "sk-ant-api03-abcdefgh12345678", "ghp_abcdefgh12345678", "gho_abcdefgh12345678",
            "github_pat_11ABCDEFG0abcdefgh", "AKIAABCDEFGHIJKLMNOP", "xoxb-1234567890-abcdef", "xoxp-1234567890-abcdef",
            "Bearer abcdefgh12345678.xyz",
            "-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----",
            "API_KEY=hunter2", "github_token=abc123", "MY_SECRET=s3", "DB_PASSWORD=pw",
            "sk_live_abcdefgh12345678", "rk_test_abcdefgh12345678", "whsec_abcdefgh12345678", "ghs_abcdefgh12345678",
            "AIzaabcdefgh1234567890abcdefgh12345678",
            "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZSJ9.abcdefgh12345678",
            "\"apiKey\": \"hunter2\"", "'password': 'hunter2'", "apikey: hunter2", "client_secret:hunter2",
        ]
        for s in samples {
            let out = Redact.secrets("before \(s) after")
            #expect(out.contains("[redacted]"), "\(s)")
            #expect(out.hasPrefix("before ") && out.hasSuffix(" after") || s.contains("PRIVATE"), "\(s)")
            #expect(!out.contains("abcdefgh1234") && !out.contains("hunter2") && !out.contains("MIIabc"), "\(s)")
        }
    }

    @Test func leavesOrdinaryTextAlone() {
        let t = "swift test passed; edited Sources/a.swift; sk is short; PATH=/usr/bin"
        #expect(Redact.secrets(t) == t)
    }

    @Test func digestRedactsAskedStepsAnswer() {
        let g = TurnDigest(asked: "use API_KEY=abc", steps: [TurnStep(n: 1, tool: "Bash", what: "curl -H 'Bearer abcdefgh12345678'", result: "sk-abcdefgh12345678", failed: false)],
                           edited: false, answer: "token ghp_abcdefgh12345678").redacted
        let all = g.asked + g.steps[0].what + g.steps[0].result + g.answer
        #expect(!all.contains("abcdefgh") && !all.contains("API_KEY=abc") && all.contains("[redacted]"))
    }
}
