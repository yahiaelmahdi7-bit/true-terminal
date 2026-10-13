import Testing
import Foundation
@testable import True

@Suite struct CleanerLaunchTests {
    private func exe(_ url: URL) {
        try? "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func firstExecutableWinsAndMissingOnesAreSkipped() {
        let d = cleanerTemp()
        let a = d.appendingPathComponent("a"), b = d.appendingPathComponent("b")
        exe(b)
        #expect(CleanerLaunch.resolveBinary(candidates: [a.path, b.path])?.path == b.path)
        exe(a)
        #expect(CleanerLaunch.resolveBinary(candidates: [a.path, b.path])?.path == a.path)
    }

    @Test func claudeBurnIsSkippedEvenBehindASymlink() {
        let d = cleanerTemp()
        let burn = d.appendingPathComponent("claude-burn"), real = d.appendingPathComponent("claude")
        exe(burn); exe(real)
        let link = d.appendingPathComponent("claude-link")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: burn)
        #expect(CleanerLaunch.resolveBinary(candidates: [link.path, burn.path, real.path])?.path == real.path)
    }

    @Test func noneFoundIsNil() {
        #expect(CleanerLaunch.resolveBinary(candidates: ["/nonexistent/claude"]) == nil)
    }

    @Test func candidateOrder() {
        let c = CleanerLaunch.candidates(env: ["CLAUDE_BIN": "/x/claude"], home: "/h")
        #expect(c == ["/x/claude", "/h/.local/bin/claude", "/h/.claude/local/claude",
                      "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
        #expect(CleanerLaunch.candidates(env: [:], home: "/h").count == 4)
    }

    @Test func exactArgv() {
        #expect(CleanerLaunch.argv(model: .opus) == [
            "-p", "--model", "opus", "--setting-sources", "project", "--strict-mcp-config",
            "--tools", "", "--no-session-persistence", "--system-prompt", CleanerPrompt.text])
        #expect(CleanerLaunch.argv(model: .sonnet)[2] == "sonnet")
        #expect(!CleanerLaunch.argv(model: .fable).contains("--bare"))
    }

    @Test func envScrubbing() {
        let env = CleanerLaunch.scrubbedEnv([
            "PATH": "/usr/bin", "HOME": "/h", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_X": "y", "BURN_SOFT": "1", "BURN_HARD": "2", "CLAUDE_BIN": "/x", "ANTHROPIC_FOO": "k"])
        #expect(env == ["PATH": "/usr/bin", "HOME": "/h", "CLAUDE_BIN": "/x", "ANTHROPIC_FOO": "k"])
    }

    @Test func emptyDirIsCreatedAndEmpty() {
        let home = cleanerTemp()
        let d = CleanerLaunch.emptyDir(home: home.path)
        #expect(d.path == home.path + "/.true/cleaner/empty")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: d.path))?.isEmpty == true)
    }

    @Test func promptIsIntact() {
        #expect(CleanerPrompt.text.hasPrefix("You rewrite one context file"))
        #expect(CleanerPrompt.text.hasSuffix("no preamble, no explanation, no code fences."))
        #expect(CleanerPrompt.text.contains("CLAUDE.md — standing instructions"))
    }
}

@Suite struct CleanerChecksTests {
    private func ok(_ r: Result<String, CleanerError>) -> String { (try? r.get()) ?? "<error>" }

    @Test func stripsOneWrappingFence() {
        let out = ok(CleanerChecks.sanitize("```markdown\n# T\nbody\n```\n", original: "# T\nx"))
        #expect(out == "# T\nbody")
        // Inner code block survives when there is no wrapping fence.
        let inner = "# T\n```sh\nls\n```"
        #expect(ok(CleanerChecks.sanitize(inner, original: "# T\nx")) == inner)
    }

    @Test func fenceKeptWhenOriginalStartsWithOne() {
        let t = "```sh\nls\n```"
        #expect(ok(CleanerChecks.sanitize(t, original: t)) == t)
    }

    @Test func emptyIsError() {
        #expect(CleanerChecks.sanitize("  \n ", original: "# T") == .failure(CleanerError(message: "Empty output")))
        #expect(CleanerChecks.sanitize("```\n```", original: "# T") == .failure(CleanerError(message: "Empty output")))
    }

    @Test func differingHeadingIsReplaced() {
        #expect(ok(CleanerChecks.sanitize("# New\nbody", original: "# Old Title\nx")) == "# Old Title\nbody")
        #expect(ok(CleanerChecks.sanitize("# Same\nbody", original: "# Same\nx")) == "# Same\nbody")
    }

    @Test func missingFirstLineIsPrepended() {
        #expect(ok(CleanerChecks.sanitize("body only", original: "# Title\nx")) == "# Title\n\nbody only")
        #expect(ok(CleanerChecks.sanitize("Sure:\nbody", original: "plain title\nx")) == "plain title\n\nSure:\nbody")
    }

    @Test func firstLinePresentLaterMovesToTop() {
        #expect(ok(CleanerChecks.sanitize("preface\nplain title\nbody", original: "plain title\nx")) == "plain title\npreface\nbody")
    }

    @Test func leanGate() {
        let o = String(repeating: "a", count: 1000)
        #expect(CleanerChecks.isLean(original: o, output: String(repeating: "a", count: 970)))
        #expect(CleanerChecks.isLean(original: o, output: o))
        #expect(!CleanerChecks.isLean(original: o, output: String(repeating: "a", count: 969)))
    }

    @Test func droppedFactsExtraction() {
        let orig = """
        # T
        Run `swift test -j 4` then open https://example.com/a/b. Files in ~/.true/hooks and /Users/example/Projects/true,
        also /opt/homebrew/bin/claude. Commit 56e64941 and id 3f2a9c1e-1234-4abc-8def-0123456789ab.
        Date 20260930 is not an id, nor is the word defaced. Fenced:
        ```sh
        echo hi
        ```
        """
        let keepAll = orig
        #expect(CleanerChecks.droppedFacts(original: orig, output: keepAll).isEmpty)
        let dropped = CleanerChecks.droppedFacts(original: orig, output: "# T\nnothing")
        #expect(dropped.contains("swift test -j 4"))
        #expect(dropped.contains("https://example.com/a/b"))
        #expect(dropped.contains("~/.true/hooks"))
        #expect(dropped.contains("/Users/example/Projects/true"))
        #expect(dropped.contains("/opt/homebrew/bin/claude"))
        #expect(dropped.contains("56e64941"))
        #expect(dropped.contains("3f2a9c1e-1234-4abc-8def-0123456789ab"))
        #expect(!dropped.contains("20260930"))
        #expect(!dropped.contains("3f2a9c1e") && !dropped.contains("0123456789ab"))
        #expect(!dropped.contains("defaced"))
        #expect(!dropped.contains { $0.contains("`") })
    }

    @Test func partialKeepListsOnlyMissing() {
        let orig = "# T\nUse `foo` and `bar` at https://x.io/p."
        let d = CleanerChecks.droppedFacts(original: orig, output: "# T\nUse `foo` at https://x.io/p")
        #expect(d == ["bar"])
    }
}

/// The real runner against real processes (stand-ins for `claude`): pipe draining, timeout, exit errors.
@Suite struct ProcessCleanerRunnerLiveTests {
    private let runner = ProcessCleanerRunner()
    private let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    @Test func roundTripsInputBiggerThanAPipeBuffer() async throws {
        let big = String(repeating: "0123456789abcdef\n", count: 64_000)   // ~1 MB, 16× a pipe buffer
        let out = try await runner.run(binary: URL(fileURLWithPath: "/bin/cat"), argv: [], stdin: Data(big.utf8),
                                       cwd: tmp, env: [:], timeout: 30)
        #expect(out == big)
    }

    @Test func timeoutTerminatesTheChild() async {
        let start = Date()
        await #expect(throws: CleanerError.self) {
            try await runner.run(binary: URL(fileURLWithPath: "/bin/sleep"), argv: ["20"], stdin: Data(),
                                 cwd: tmp, env: [:], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func nonZeroExitCarriesTheStderrTail() async {
        do {
            _ = try await runner.run(binary: URL(fileURLWithPath: "/bin/sh"), argv: ["-c", "echo boom >&2; exit 3"],
                                     stdin: Data(), cwd: tmp, env: [:], timeout: 10)
            Issue.record("expected an error")
        } catch let e as CleanerError {
            #expect(e.message == "claude exited 3: boom")
        } catch { Issue.record("wrong error \(error)") }
    }
}
