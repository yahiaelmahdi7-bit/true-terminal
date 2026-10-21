import Testing
import Foundation
@testable import True

/// Every helper-process runner must give back its pipe. True polls lsof / ps / git every few seconds, so one
/// leaked descriptor per run hits the 256 limit in minutes and crashes the app ("Too many open files").
@Suite(.serialized) struct FDLeakTests {
    static func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }

    static func leaked(_ body: () -> Void) -> Int {
        body()                                   // warm up lazy Foundation state
        let before = openFDs()
        for _ in 0..<50 { body() }
        return openFDs() - before
    }

    @Test func siteHTTPRunGivesBackItsPipe() {
        #expect(Self.leaked { _ = SiteHTTP.run("/bin/echo", ["x"]) } < 5)
    }

    @Test func systemRunnerGivesBackItsPipe() {
        #expect(Self.leaked { _ = GitSignals.systemRunner(["echo", "x"]) } < 5)
    }

    @Test func runnerFromATaskGivesBackItsPipe() async {
        let before = Self.openFDs()
        for _ in 0..<50 { _ = await Task.detached { SiteHTTP.run("/bin/echo", ["x"]) }.value }
        #expect(Self.openFDs() - before < 5)
    }

    @Test func fileLimitIsRaised() {
        Subprocess.raiseFileLimit()
        var l = rlimit(); getrlimit(RLIMIT_NOFILE, &l)
        #expect(l.rlim_cur >= min(8192, l.rlim_max))
    }

    @Test func execKeepsStatusAndMergedOutput() {
        let r = Subprocess.exec("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], mergeStderr: true)
        #expect(r?.status == 3)
        #expect(String(decoding: r?.out ?? Data(), as: UTF8.self) == "out\nerr\n")
        #expect(Subprocess.run("/bin/sh", ["-c", "exit 1"]) == nil)
        #expect(Subprocess.exec("/no/such/tool", []) == nil)
    }

    @Test func timeoutKillsAHungTool() {
        let t = Date()
        #expect(Subprocess.run("/bin/sleep", ["30"], timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(t) < 5)
    }
}
