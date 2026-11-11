import Foundation
import Testing
@testable import True

/// A throwaway ~/.claude + ~/.codex, with a fixed clock.
final class UsageFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
    var claude: URL { root.appendingPathComponent("claude/projects") }
    var codex: URL { root.appendingPathComponent("codex/sessions") }
    var cache: URL { root.appendingPathComponent("cache") }
    static let now = ISO8601DateFormatter().date(from: "2026-11-09T12:00:00Z")!
    private var tick = 0.0

    init() {
        try? FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    }
    deinit {
        // Put permissions back so cleanup works after the unreadable tests.
        for u in [claude, codex, claude.deletingLastPathComponent()] { chmod(u.path, 0o755) }
        try? FileManager.default.removeItem(at: root)
    }

    func scanner(tz: String = "UTC", cached: Bool = false, now: Date = UsageFixture.now) -> UsageScanner {
        UsageScanner(claudeRoot: claude, codexRoot: codex, cacheDir: cached ? cache : nil,
                     timeZone: TimeZone(identifier: tz)!, now: { now })
    }

    /// Writes (or replaces in place) a file and gives it a new, recent modification time.
    @discardableResult
    func write(_ rel: String, base: URL? = nil, _ text: String, touch: Date? = nil) -> URL {
        let url = (base ?? claude).appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        stamp(url, touch)
        return url
    }
    func append(_ url: URL, _ text: String) {
        let h = try! FileHandle(forWritingTo: url)
        _ = try! h.seekToEnd(); try! h.write(contentsOf: Data(text.utf8)); try! h.close()
        stamp(url, nil)
    }
    func stamp(_ url: URL, _ date: Date?) {
        tick += 1
        try? FileManager.default.setAttributes([.modificationDate: date ?? Self.now.addingTimeInterval(-3600 + tick)], ofItemAtPath: url.path)
    }

    static func claudeLine(id: String, model: String = "claude-sonnet-4-5", ts: String = "2026-11-09T10:00:00.000Z",
                           input: Int = 10, output: Int = 20, cr: Int = 100, cw: Int = 50, text: String = "SECRET prompt text") -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","cwd":"/Users/example/Projects/private-name","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cw),"cache_read_input_tokens":\#(cr),"output_tokens":\#(output)}}}"# + "\n"
    }
    static func codexContext(_ model: String) -> String {
        #"{"timestamp":"2026-11-09T09:00:00.000Z","type":"turn_context","payload":{"model":"\#(model)","cwd":"/x"}}"# + "\n"
    }
    static func codexCount(ts: String, input: Int, cached: Int, output: Int) -> String {
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"total_tokens":\#(input + output)}}}}"# + "\n"
    }
}

private func sum(_ b: [UsageBucket], _ p: UsageProvider? = nil) -> UsageTokens {
    var t = UsageTokens()
    for x in b where p == nil || x.provider == p { t += x.tokens }
    return t
}

@Suite struct UsageScannerTests {
    // MARK: dedupe

    @Test func streamedLinesSharingAMessageIdCountOnceLastWins() {
        let f = UsageFixture()
        f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m1", output: 5) + UsageFixture.claudeLine(id: "m1", output: 12)
                + UsageFixture.claudeLine(id: "m1", output: 40) + UsageFixture.claudeLine(id: "m2", output: 7))
        let s = f.scanner(); s.scan()
        let t = sum(s.buckets())
        #expect(t.output == 47)          // 40 (last of m1) + 7
        #expect(t.input == 20)           // two messages, 10 each
    }

    @Test func aResumedCopyInAnotherFileCountsOnce() {
        let f = UsageFixture()
        let lines = UsageFixture.claudeLine(id: "m1", output: 30) + UsageFixture.claudeLine(id: "m2", output: 8)
        f.write("-p/a.jsonl", lines)
        f.write("-p/b-resumed.jsonl", lines + UsageFixture.claudeLine(id: "m3", output: 2))
        let s = f.scanner(); s.scan()
        #expect(sum(s.buckets()).output == 40)
    }

    @Test func subAgentFilesCountWhenTheyHoldTheirOwnTurns() {
        let f = UsageFixture()
        f.write("-p/sess.jsonl", UsageFixture.claudeLine(id: "main", output: 10))
        f.write("-p/sess/subagents/agent-a1.jsonl", UsageFixture.claudeLine(id: "sub1", output: 5)
                + UsageFixture.claudeLine(id: "main", output: 10))     // a copy of a main-file turn
        let s = f.scanner(); let st = s.scan()
        #expect(sum(s.buckets()).output == 15)
        #expect(st.filesSeen[.claude] == 2)
    }

    @Test func theFullerCopyWinsAcrossFiles() {
        let f = UsageFixture()
        f.write("-p/a.jsonl", UsageFixture.claudeLine(id: "m1", output: 3))      // cut off mid-stream
        f.write("-p/b.jsonl", UsageFixture.claudeLine(id: "m1", output: 90))
        let s = f.scanner(); s.scan()
        #expect(sum(s.buckets()).output == 90)
    }

    // MARK: models, prices, bad lines

    @Test func anUnknownModelKeepsItsTokensAndIsUnpriced() {
        let f = UsageFixture()
        f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m1", model: "claude-brand-new-9", input: 1000, output: 1000, cr: 0, cw: 0)
                + UsageFixture.claudeLine(id: "m2", model: "claude-sonnet-4-5-20250929", input: 1_000_000, output: 0, cr: 0, cw: 0))
        let s = f.scanner(); s.scan()
        let b = s.buckets()
        let unknown = b.first { $0.model == "claude-brand-new-9" }!
        #expect(unknown.tokens.input == 1000 && unknown.dollars == nil)
        #expect(b.first { $0.model.hasPrefix("claude-sonnet") }!.dollars == 3.0)   // $3 per million input
        #expect(ModelPrices.price(for: "gpt-5.6-sol") != nil)
        #expect(ModelPrices.price(for: "claude-sonnet-4-5-20250929")?.id == "claude-sonnet-4-5")
        #expect(ModelPrices.price(for: "claude-opus-4-5")?.base.input == 5)
    }

    @Test func aCorruptLineIsCountedAndTheRestStillCounts() {
        let f = UsageFixture()
        f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m1", output: 4)
                + #"{"type":"assistant","message":{"usage":{"input_tokens":1, BROKEN"# + "\n"
                + #"{"type":"assistant","message":{"usage":{"input_tokens":1}}}"# + "\n"   // no id or model
                + UsageFixture.claudeLine(id: "m2", output: 6))
        let s = f.scanner(); let st = s.scan()
        #expect(sum(s.buckets()).output == 10)
        #expect(st.skipped[.claude]?[UsageSkip.corrupt] == 1)
        #expect(st.skipped[.claude]?[UsageSkip.missingFields] == 1)
    }

    @Test func theWordUsageInOrdinaryTextIsNotASkippedLine() {
        let f = UsageFixture()
        f.write("-p/s.jsonl", #"{"type":"user","message":"show me the \"usage\" numbers"}"# + "\n"
                + UsageFixture.claudeLine(id: "m1", text: #"the \"usage\" field"#))
        let s = f.scanner(); let st = s.scan()
        #expect(st.skipped[.claude] == nil)
        #expect(sum(s.buckets()).output == 20)
    }

    // MARK: growing, shrinking, replacing, vanishing

    @Test func aHalfWrittenLastLineIsReadNextTime() {
        let f = UsageFixture()
        let whole = UsageFixture.claudeLine(id: "m2", output: 9)
        let cut = String(whole.dropLast(30))
        let url = f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m1", output: 4) + cut)
        let s = f.scanner(); let st = s.scan()
        #expect(sum(s.buckets()).output == 4)
        #expect(st.skipped[.claude] == nil)                       // not corrupt, just not finished
        f.append(url, String(whole.suffix(30)))
        s.scan()
        #expect(sum(s.buckets()).output == 13)
    }

    @Test func aGrowingFileReadsOnlyTheNewBytes() {
        let f = UsageFixture()
        let url = f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m0", output: 0) + UsageFixture.claudeLine(id: "m1", output: 4))
        let s = f.scanner(); let first = s.scan()
        let second = s.scan()
        #expect(second.filesRead[.claude] == nil && second.bytesRead == 0)    // nothing new, nothing opened
        let added = UsageFixture.claudeLine(id: "m2", output: 6)
        f.append(url, added)
        let third = s.scan()
        #expect(third.bytesRead == Int64(added.utf8.count) && first.bytesRead > third.bytesRead)
        #expect(sum(s.buckets()).output == 10)
    }

    @Test func aShrunkFileDropsItsOldTurns() {
        let f = UsageFixture()
        let url = f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m1", output: 4) + UsageFixture.claudeLine(id: "m2", output: 6))
        let s = f.scanner(); s.scan()
        #expect(sum(s.buckets()).output == 10)
        f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m3", output: 1))
        _ = url
        s.scan()
        #expect(sum(s.buckets()).output == 1)
    }

    @Test func aReplacedFileWithANewInodeIsReadFromTheStart() throws {
        let f = UsageFixture()
        let url = f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m1", output: 4))
        let s = f.scanner(); s.scan()
        var st = stat(); stat(url.path, &st); let oldInode = st.st_ino
        // A bigger file moved over the old one: new inode, size grew, so only the inode says "replaced".
        let other = f.write("-p/other.tmp", UsageFixture.claudeLine(id: "x1", output: 100) + UsageFixture.claudeLine(id: "x2", output: 200))
        _ = try FileManager.default.replaceItemAt(url, withItemAt: other)
        f.stamp(url, nil)
        stat(url.path, &st)
        #expect(st.st_ino != oldInode)
        s.scan()
        #expect(sum(s.buckets()).output == 300)    // m1 is gone, not added to
    }

    @Test func aVanishedFileTakesItsTurnsWithIt() throws {
        let f = UsageFixture()
        let url = f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m1", output: 4))
        f.write("-p/keep.jsonl", UsageFixture.claudeLine(id: "m2", output: 6))
        let s = f.scanner(); s.scan()
        try FileManager.default.removeItem(at: url)
        s.scan()
        #expect(sum(s.buckets()).output == 6)
    }

    @Test func anUnreadableFileIsSkippedAndCounted() {
        let f = UsageFixture()
        let bad = f.write("-p/locked.jsonl", UsageFixture.claudeLine(id: "m1", output: 4))
        f.write("-p/fine.jsonl", UsageFixture.claudeLine(id: "m2", output: 6))
        chmod(bad.path, 0)
        let s = f.scanner(); let st = s.scan()
        #expect(sum(s.buckets()).output == 6)
        #expect(st.skipped[.claude]?[UsageSkip.unreadableFile] == 1)
        #expect(st.filesRead[.claude] == 1)
    }

    @Test func anUnreadableFolderIsReportedAndAMissingOneIsNot() {
        let f = UsageFixture()
        f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m1", output: 4))
        try? FileManager.default.removeItem(at: f.codex)
        chmod(f.claude.path, 0)
        let s = f.scanner(); let st = s.scan()
        #expect(st.folders[.claude] == .unreadable)
        #expect(st.folders[.codex] == .absent)
        #expect(st.skipped[.claude]?[UsageSkip.unreadableFolder] == 1)
        chmod(f.claude.path, 0o755)
    }

    // MARK: days

    @Test func theDayChangesAtLocalMidnight() {
        let f = UsageFixture()
        // New York is UTC-5 on 9 Nov 2026: local midnight is 05:00Z.
        f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "a", ts: "2026-11-09T04:59:59.999Z", output: 1)
                + UsageFixture.claudeLine(id: "b", ts: "2026-11-09T05:00:00.000Z", output: 2))
        let s = f.scanner(tz: "America/New_York"); s.scan()
        let days = Dictionary(uniqueKeysWithValues: s.buckets().map { ($0.day, $0.tokens.output) })
        #expect(days == ["2026-11-08": 1, "2026-11-09": 2])
    }

    @Test func aSpringForwardDayIsTwentyThreeHoursLong() {
        let f = UsageFixture()
        // 8 Mar 2026, New York: 02:00 EST jumps to 03:00 EDT. Local midnights are 05:00Z (8th) and 04:00Z (9th).
        f.write("-p/s.jsonl",
                UsageFixture.claudeLine(id: "a", ts: "2026-03-08T04:59:59Z", output: 1)
                + UsageFixture.claudeLine(id: "b", ts: "2026-03-08T05:00:00Z", output: 2)
                + UsageFixture.claudeLine(id: "c", ts: "2026-03-09T03:59:59Z", output: 4)
                + UsageFixture.claudeLine(id: "d", ts: "2026-03-09T04:00:00Z", output: 8))
        let now = ISO8601DateFormatter().date(from: "2026-03-09T12:00:00Z")!
        let s = f.scanner(tz: "America/New_York", now: now)
        // The fixture's file times follow its own clock; pin them to this test's.
        f.stamp(f.claude.appendingPathComponent("-p/s.jsonl"), now.addingTimeInterval(-60))
        s.scan()
        let days = Dictionary(uniqueKeysWithValues: s.buckets().map { ($0.day, $0.tokens.output) })
        #expect(days == ["2026-03-07": 1, "2026-03-08": 6, "2026-03-09": 8])
    }

    @Test func aFallBackDayIsTwentyFiveHoursLong() {
        let f = UsageFixture()
        // 1 Nov 2026, New York: 02:00 EDT falls back to 01:00 EST. Midnights are 04:00Z (1st) and 05:00Z (2nd).
        f.write("-p/s.jsonl",
                UsageFixture.claudeLine(id: "a", ts: "2026-11-01T03:59:59Z", output: 1)
                + UsageFixture.claudeLine(id: "b", ts: "2026-11-02T04:59:59Z", output: 2)
                + UsageFixture.claudeLine(id: "c", ts: "2026-11-02T05:00:00Z", output: 4))
        let s = f.scanner(tz: "America/New_York"); s.scan()
        let days = Dictionary(uniqueKeysWithValues: s.buckets().map { ($0.day, $0.tokens.output) })
        #expect(days == ["2026-10-31": 1, "2026-11-01": 2, "2026-11-02": 4])
    }

    @Test func turnsOlderThanNinetyTwoDaysAreDropped() {
        let f = UsageFixture()
        f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "old", ts: "2026-07-01T10:00:00Z", output: 99)
                + UsageFixture.claudeLine(id: "new", ts: "2026-11-08T10:00:00Z", output: 1))
        let s = f.scanner(); s.scan()
        #expect(sum(s.buckets()).output == 1)
    }

    // MARK: Codex

    @Test func codexTurnsAreTheStepsOfTheRunningTotalAndRepeatsCountOnce() {
        let f = UsageFixture()
        f.write("2026/11/09/rollout-a.jsonl", base: f.codex,
                UsageFixture.codexContext("gpt-5-codex")
                + UsageFixture.codexCount(ts: "2026-11-09T09:01:00Z", input: 100, cached: 20, output: 5)
                + UsageFixture.codexCount(ts: "2026-11-09T09:01:01Z", input: 100, cached: 20, output: 5)   // same total again
                + UsageFixture.codexCount(ts: "2026-11-09T09:02:00Z", input: 300, cached: 50, output: 25))
        let s = f.scanner(); s.scan()
        let t = sum(s.buckets(), .codex)
        #expect(t.input == 250 && t.cacheRead == 50 && t.output == 25)
        #expect(s.buckets().first?.model == "gpt-5-codex")
    }

    @Test func aResumedCodexRolloutCountsOnce() {
        let f = UsageFixture()
        let head = UsageFixture.codexContext("gpt-5-codex") + UsageFixture.codexCount(ts: "2026-11-09T09:01:00Z", input: 100, cached: 0, output: 5)
        f.write("2026/11/09/rollout-a.jsonl", base: f.codex, head)
        f.write("2026/11/09/rollout-b.jsonl", base: f.codex, head + UsageFixture.codexCount(ts: "2026-11-09T09:05:00Z", input: 150, cached: 0, output: 9))
        let s = f.scanner(); s.scan()
        let t = sum(s.buckets(), .codex)
        #expect(t.input == 150 && t.output == 9)
    }

    // MARK: cache, privacy, network

    @Test func theCacheSurvivesARestartAndKeepsNoNamesOrText() throws {
        let f = UsageFixture()
        f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "m1", output: 4))
        let first = f.scanner(cached: true); first.scan()
        let second = f.scanner(cached: true)
        let st = second.scan()
        #expect(st.bytesRead == 0 && st.filesRead[.claude] == nil)
        #expect(sum(second.buckets()).output == 4)
        let raw = try String(contentsOf: f.cache.appendingPathComponent("cache.json"), encoding: .utf8)
        #expect(!raw.contains("SECRET") && !raw.contains("private-name") && !raw.contains(f.root.lastPathComponent))
        #expect(!FileManager.default.fileExists(atPath: f.cache.appendingPathComponent("cache.json.tmp").path))
    }

    @Test func usageSourcesNeverTouchTheNetwork() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/True/Usage")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 3)
        for u in files {
            let text = try String(contentsOf: u, encoding: .utf8)
            #expect(!text.contains("URLSession"), "\(u.lastPathComponent)")
            #expect(!text.contains("URL(string: \"http"), "\(u.lastPathComponent)")
            #expect(!text.contains("URL(string:\"http"), "\(u.lastPathComponent)")
            #expect(!text.contains("NWConnection") && !text.contains("CFNetwork"), "\(u.lastPathComponent)")
        }
    }

    // MARK: truectl

    @Test func truectlUsageIsWiredEndToEnd() {
        #expect(ControlRequest.parse(Data(#"{"op":"usage","days":3}"#.utf8)) == .usage(days: 3))
        #expect(ControlRequest.parse(Data(#"{"op":"usage"}"#.utf8)) == .usage(days: 7))
        #expect(ControlRequest.parse(Data(#"{"op":"usage","days":5000}"#.utf8)) == .usage(days: 92))
        let s = AgentControl.truectl(socketPath: "/tmp/x/control.sock")
        #expect(s.contains("truectl usage [--days 7] [--json]") && s.contains("\"usage\""))
    }

    @Test func theReplyKeepsOnlyTheAskedDaysAndNamesWhatIsUnpriced() {
        let f = UsageFixture()
        f.write("-p/s.jsonl", UsageFixture.claudeLine(id: "a", ts: "2026-11-01T10:00:00Z", output: 1)
                + UsageFixture.claudeLine(id: "b", model: "mystery-1", ts: "2026-11-09T10:00:00Z", output: 2))
        let s = f.scanner(); let st = s.scan()
        let r = UsageReply.make(buckets: s.buckets(), stats: st, days: 7, today: UsageFixture.now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(r.days.map(\.day) == ["2026-11-09"])
        #expect(r.unpriced == ["mystery-1"])
    }
}
