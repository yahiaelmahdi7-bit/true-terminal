import Foundation
import Testing
@testable import True

@Suite struct ContextMeterTests {
    func claudeLine(_ model: String, input: Int, read: Int, write: Int, side: Bool = false, type: String = "assistant") -> String {
        """
        {"type":"\(type)","isSidechain":\(side),"message":{"model":"\(model)","usage":{"input_tokens":\(input),"cache_read_input_tokens":\(read),"cache_creation_input_tokens":\(write),"output_tokens":99}}}
        """
    }

    @Test func claudeAddsInputReadAndWriteOfTheLastTurn() {
        let tail = [claudeLine("claude-opus-5-5", input: 1, read: 1, write: 1),
                    claudeLine("claude-opus-5-5", input: 10_000, read: 80_000, write: 10_000)].joined(separator: "\n")
        let r = ContextMeter.claude(tail: tail)
        #expect(r?.used == 100_000)
        #expect(r?.size == 1_000_000)
        #expect(r?.percent == 10)
    }

    @Test func claudeSkipsHalfLineSidechainSyntheticAndUserLines() {
        let tail = ["partial\":1}}",   // first line of a tail, cut in half
                    claudeLine("claude-opus-5-5", input: 5, read: 500_000, write: 100_000),
                    claudeLine("claude-opus-5-5", input: 900_000, read: 0, write: 0, side: true),
                    claudeLine("<synthetic>", input: 0, read: 0, write: 0),
                    claudeLine("claude-opus-5-5", input: 1, read: 1, write: 1, type: "user")].joined(separator: "\n")
        #expect(ContextMeter.claude(tail: tail)?.used == 600_005)
        #expect(ContextMeter.claude(tail: tail)?.percent == 60)
    }

    @Test func claudeUnknownSizeMeansNoMeter() {
        #expect(ContextMeter.claude(tail: claudeLine("claude-sonnet-4-6", input: 5, read: 5, write: 5)) == nil)
        #expect(ContextMeter.claude(tail: claudeLine("brand-new-model", input: 5, read: 5, write: 5)) == nil)
        #expect(ContextMeter.claude(tail: "") == nil)
        #expect(ContextMeter.claude(tail: "not json at all") == nil)
    }

    @Test func claudeOverTheWindowClamps() {
        let r = ContextMeter.claude(tail: claudeLine("claude-haiku-5-5", input: 1_200_000, read: 0, write: 0))
        #expect(r?.fraction == 1)
        #expect(r?.label == "100%")
    }

    func codexLine(last: String, window: String) -> String {
        """
        {"timestamp":"2026-11-07T23:19:06.451Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999999,"total_tokens":999999},"last_token_usage":\(last),"model_context_window":\(window)}}}
        """
    }

    @Test func codexReadsLastUsageAgainstItsWindow() {
        let tail = [codexLine(last: "{\"input_tokens\":1,\"total_tokens\":1}", window: "237500"),
                    codexLine(last: "{\"input_tokens\":200000,\"output_tokens\":2250,\"total_tokens\":202250}", window: "237500")]
            .joined(separator: "\n")
        let r = ContextMeter.codex(tail: tail)
        #expect(r?.used == 202_250)
        #expect(r?.size == 237_500)
        #expect(r?.percent == 85)
    }

    @Test func codexFallsBackToInputPlusOutputAndNeedsAWindow() {
        #expect(ContextMeter.codex(tail: codexLine(last: "{\"input_tokens\":100,\"output_tokens\":50}", window: "1000"))?.used == 150)
        #expect(ContextMeter.codex(tail: codexLine(last: "{\"input_tokens\":100,\"total_tokens\":100}", window: "null")) == nil)
        #expect(ContextMeter.codex(tail: "{\"payload\":{\"type\":\"other\"}}") == nil)
    }

    @Test func tailOfAFileIsTheEndAndCutsAtTheByteCount() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (String(repeating: "x", count: 5000) + "\nlast line\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(ContextMeter.tail(of: url, bytes: 20) == "\(String(repeating: "x", count: 9))\nlast line\n")
        #expect(ContextMeter.tail(of: url.appendingPathExtension("missing")) == nil)
    }

    @Test func onlyConfirmedModelsHaveASize() {
        for id in ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] {
            #expect(ModelPrices.contextTokens(for: id) == 1_000_000)
        }
        #expect(ModelPrices.contextTokens(for: "claude-opus-5-5-20261101") == 1_000_000)
        for p in ModelPrices.table where p.contextTokens != nil { #expect(p.provider == .claude) }
        #expect(ModelPrices.contextTokens(for: "claude-opus-5") == nil)
        #expect(ModelPrices.contextTokens(for: "gpt-5.5") == nil)
    }

    @Test func percentShowsOnlyFromNinetyAndBarIs32Wide() {
        #expect(ContextReading(used: 89, size: 100)?.showsPercent == false)
        #expect(ContextReading(used: 90, size: 100)?.showsPercent == true)
        #expect(ContextReading(used: 95, size: 100)?.label == "95%")
        #expect(ContextMeterView.barWidth == 32)
    }

    @MainActor @Test func seatWithATranscriptGetsAReadingAndOneWithoutGetsNil() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.jsonl")
        try (claudeLine("claude-opus-5-5", input: 100_000, read: 400_000, write: 100_000) + "\n").write(to: file, atomically: true, encoding: .utf8)
        let ws = WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("workspace.json")))
        let reg = AgentRegistry(store: AgentStore(url: dir.appendingPathComponent("agents.json")), paths: AgentPaths(root: dir),
                                workspace: ws, claudeDir: dir)
        let withT = UUID(), without = UUID()
        await reg.readContext(pane: withT, transcript: file.path)
        await reg.readContext(pane: without, transcript: dir.appendingPathComponent("missing.jsonl").path)
        func row(_ pane: UUID) -> ActivityRow {
            let s = SeatSnapshot(name: "a", pane: pane, project: "true", model: "opus", effort: "high", status: .working,
                                 event: nil, context: reg.contexts[pane])
            return AgentActivityBuilder.rows(seats: [s], needsYou: [], builders: [], missions: [], browser: BrowserMemory(), now: Date())[0]
        }
        #expect(row(withT).context?.percent == 60)
        #expect(row(without).context == nil)
        reg.paneClosed(withT)
        #expect(reg.contexts[withT] == nil)
    }
}
