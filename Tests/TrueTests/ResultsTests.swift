import Testing
import Foundation
@testable import True

@Suite struct ResultsTests {
    // MARK: fixtures
    static func line(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }
    static func prompt(_ t: String, meta: Bool = false, ts: String = "2026-09-30T10:00:00.000Z") -> String {
        line(["type": "user", "timestamp": ts, "isSidechain": false, "isMeta": meta, "message": ["role": "user", "content": t]])
    }
    static func text(_ t: String, side: Bool = false, ts: String = "2026-09-30T10:00:01.000Z") -> String {
        line(["type": "assistant", "timestamp": ts, "isSidechain": side,
              "message": ["role": "assistant", "content": [["type": "text", "text": t]]]])
    }
    static func tool(side: Bool = false) -> String {
        line(["type": "assistant", "timestamp": "2026-09-30T10:00:02.000Z", "isSidechain": side,
              "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t", "name": "Bash", "input": [:]]]]])
    }
    static func toolResult() -> String {
        line(["type": "user", "timestamp": "2026-09-30T10:00:03.000Z", "isSidechain": false,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "ok"]]]])
    }
    static func parse(_ lines: [String]) -> [TurnResult] { TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8)) }

    // MARK: parser
    @Test func finalTextOnlyAfterLastTool() {
        let r = Self.parse([Self.prompt("do it"), Self.text("narration"), Self.tool(), Self.toolResult(), Self.text("FINAL")])
        #expect(r.count == 1)
        #expect(r[0].markdown == "FINAL")
        #expect(r[0].prompt == "do it")
        #expect(r[0].date != nil)
    }

    @Test func twoTextBlocksAfterLastToolAreJoined() {
        let r = Self.parse([Self.prompt("p"), Self.tool(), Self.text("one"), Self.text("two")])
        #expect(r[0].markdown == "one\n\ntwo")
    }

    @Test func turnEndingOnToolFallsBackToLastText() {
        let r = Self.parse([Self.prompt("p"), Self.text("first"), Self.text("last"), Self.tool()])
        #expect(r[0].markdown == "last")
    }

    @Test func turnWithNoTextIsSkipped() {
        let r = Self.parse([Self.prompt("a"), Self.tool(), Self.prompt("b"), Self.text("B")])
        #expect(r.map(\.markdown) == ["B"])
    }

    @Test func sidechainMetaAndToolResultsDoNotSplitOrLeak() {
        let r = Self.parse([Self.prompt("real"), Self.text("hidden", side: true), Self.prompt("meta", meta: true),
                            Self.toolResult(), Self.text("answer"), Self.text("sub", side: true)])
        #expect(r.count == 1)
        #expect(r[0].markdown == "answer")
        #expect(r[0].prompt == "real")
    }

    @Test func promptArrayOfTextBlocksStartsATurn() {
        let p = Self.line(["type": "user", "timestamp": "2026-09-30T10:00:00.000Z", "isSidechain": false,
                           "message": ["content": [["type": "text", "text": "hello"]]]])
        let r = Self.parse([Self.prompt("x"), Self.text("X"), p, Self.text("H")])
        #expect(r.map(\.markdown) == ["H", "X"])
    }

    @Test func garbageLineIsSkipped() {
        let r = Self.parse([Self.prompt("p"), "{not json", Self.text("ok")])
        #expect(r.map(\.markdown) == ["ok"])
    }

    static func manyTurns(_ n: Int, pad: String = "") -> [String] {
        (0..<n).flatMap { [prompt("prompt \($0) \(pad)"), text("answer \($0)")] }
    }

    @Test func capsAtTwentyNewestFirst() {
        let r = Self.parse(Self.manyTurns(30))
        #expect(r.count == 20)
        #expect(r.first?.markdown == "answer 29")
        #expect(r.last?.markdown == "answer 10")
        #expect(r.map(\.id) == Array(0..<20))
    }

    @Test func chunkedTailReadMatchesFullParse() throws {
        let lines = Self.manyTurns(60, pad: String(repeating: "x", count: 300))
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("results-\(UUID()).jsonl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = 4096
        #expect(data.count > chunk * 4)
        let tail = try #require(ResultsLoader.load(url: url, chunk: chunk))
        let full = TranscriptParser.parse(data)
        #expect(tail == full)
        #expect(tail.count == 20)
        // A file smaller than a chunk reads whole.
        #expect(ResultsLoader.load(url: url, limit: 100, chunk: 1 << 30)?.count == 60)
        #expect(ResultsLoader.load(url: url.appendingPathExtension("nope")) == nil)
    }

    // MARK: probe
    @Test func probeStripsMarkdownAndCollapsesWhitespace() {
        #expect(ResultsProbe.build("## **Done**:   the  `build` is [green](http://x)") == "Done: the build is green")
        #expect(ResultsProbe.build("```\n```\n- first item here ok") == "first item here ok")
        #expect(ResultsProbe.build("| a | b |") == "a b")
        #expect(ResultsProbe.build("   \n\n") == nil)
    }

    @Test func probeExtendsShortFirstLineAndCaps() {
        #expect(ResultsProbe.build("Done.\nAll tests pass now") == "Done. All tests pass now")
        let long = String(repeating: "word ", count: 30)
        #expect(ResultsProbe.build(long)?.count == 40)
    }

    // MARK: buffer matching
    @Test func matchAcrossWrappedRow() {
        let rows = ["nothing", "⏺ All tests pass and the", "  build is green now", "$"]
        let hit = ResultsProbe.find("All tests pass and the build is green", in: rows)
        #expect(hit?.first == 1)
        #expect(hit?.last == 2)
    }

    @Test func lastOccurrenceWins() {
        let rows = ["Done here", "x", "Done here", "y"]
        #expect(ResultsProbe.find("Done here", in: rows)?.first == 2)
    }

    @Test func notFoundIsNil() {
        #expect(ResultsProbe.find("missing", in: ["a", "b"]) == nil)
        #expect(ResultsProbe.find("", in: ["a"]) == nil)
    }

    @Test func wordCutMidWayByTerminalWrapStillMatches() {
        #expect(ResultsProbe.find("transcript ready", in: ["transcr", "ipt ready"])?.first == 0)
    }

    // MARK: markdown blocks
    @Test func blocksParse() {
        let md = "# T\n\npara one\nstill one\n\n- a\n- b\n  more\n\n1. x\n\n```swift\nlet a = 1\n```\n\n| h | i |\n|---|---|\n| 1 | 2 |"
        let b = MarkdownBlock.parse(md)
        #expect(b[0] == .heading(level: 1, text: "T"))
        #expect(b[1] == .paragraph("para one\nstill one"))
        #expect(b[2] == .list([.init(marker: "•", text: "a", indent: 0), .init(marker: "•", text: "b\nmore", indent: 0)]))
        #expect(b[3] == .list([.init(marker: "1.", text: "x", indent: 0)]))
        #expect(b[4] == .code("let a = 1"))
        #expect(b[5] == .table(["| h | i |", "|---|---|", "| 1 | 2 |"]))
    }

    @Test func transcriptURLUsesTheSlugRule() {
        let u = AgentLaunch.transcriptURL(id: "ID", cwd: "/Users/example/.x/proj", claudeDir: URL(fileURLWithPath: "/c"))
        #expect(u.path == "/c/projects/-Users-example--x-proj/ID.jsonl")
    }
}
