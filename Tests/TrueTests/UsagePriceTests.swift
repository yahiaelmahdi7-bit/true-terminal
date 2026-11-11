import Foundation
import Testing
@testable import True

/// Dollar math per request. Every expected number below can be checked by hand from the $/1M rates.
@Suite struct UsagePriceTests {
    private func claudeLine(id: String, model: String, input: Int = 0, output: Int = 0, cr: Int = 0,
                            w5: Int? = nil, w1: Int? = nil, legacyWrite: Int? = nil) -> String {
        var cc = ""
        var total = legacyWrite ?? 0
        if w5 != nil || w1 != nil {
            cc = #","cache_creation":{"ephemeral_5m_input_tokens":\#(w5 ?? 0),"ephemeral_1h_input_tokens":\#(w1 ?? 0)}"#
            total = (w5 ?? 0) + (w1 ?? 0)
        }
        return #"{"type":"assistant","timestamp":"2026-11-09T10:00:00.000Z","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(total),"cache_read_input_tokens":\#(cr),"output_tokens":\#(output)\#(cc)}}}"# + "\n"
    }

    private func claudeDollars(_ lines: String) -> [UsageBucket] {
        let f = UsageFixture()
        f.write("-p/s.jsonl", lines)
        let s = f.scanner(); s.scan()
        return s.buckets()
    }

    private func near(_ a: Double?, _ b: Double) -> Bool { a != nil && abs(a! - b) < 1e-9 }

    // MARK: cache read rates

    @Test func cacheReadUsesEachModelsOwnRate() {
        // 1M cache-read tokens each.
        for (model, want) in [("claude-fable-5-1", 0.25), ("claude-fable-5", 1.0), ("claude-opus-5-5", 0.20), ("claude-sonnet-5-5", 0.10)] {
            let b = claudeDollars(claudeLine(id: "m", model: model, cr: 1_000_000))
            #expect(near(b[0].dollars, want), "\(model)")
        }
    }

    // MARK: cache write split

    @Test func oneHourWriteAndFiveMinuteWriteArePricedApart() {
        // Sonnet 5.5: 5m 2.50, 1h 4. 1M of each = 6.50.
        let b = claudeDollars(claudeLine(id: "m", model: "claude-sonnet-5-5", w5: 1_000_000, w1: 1_000_000))
        #expect(near(b[0].dollars, 6.5))
        #expect(b[0].tokens.cacheWrite == 2_000_000)
    }

    @Test func aMissingCacheCreationObjectPricesAllWritesAtTheFiveMinuteRate() {
        let b = claudeDollars(claudeLine(id: "m", model: "claude-sonnet-5-5", legacyWrite: 1_000_000))
        #expect(near(b[0].dollars, 2.5))
    }

    // MARK: haiku 5.5 long prompt tier

    @Test func haikuPromptAtTheBoundaryIsShortOneOverIsLongAndOutputToo() {
        // prompt = input + cache read + cache write. 100,000 exactly -> short; 100,001 -> long.
        // Both have 1,000,000 output tokens: short 0.50, long 2.50.
        let short = claudeDollars(claudeLine(id: "s", model: "claude-haiku-5-5", input: 40_000, output: 1_000_000, cr: 30_000, w5: 30_000))
        // 40000*0.10 + 30000*0.01 + 30000*0.125 + 1M*0.50 = 4000+300+3750 (micro-dollars) + 500000
        let wantShort: Double = (4_000.0 + 300 + 3_750 + 500_000) / 1e6
        #expect(near(short[0].dollars, wantShort))
        let long = claudeDollars(claudeLine(id: "l", model: "claude-haiku-5-5", input: 40_001, output: 1_000_000, cr: 30_000, w5: 30_000))
        // 40001*0.50 + 30000*0.05 + 30000*0.625 + 1M*2.50
        let wantLong: Double = (20_000.5 + 1_500 + 18_750 + 2_500_000) / 1e6
        #expect(near(long[0].dollars, wantLong))
    }

    @Test func eachRequestIsPricedOnItsOwnNotOnTheDayTotal() {
        // Two requests on one day: 60k prompt (short) and 150k prompt (long), no output.
        let b = claudeDollars(claudeLine(id: "a", model: "claude-haiku-5-5", input: 60_000)
                              + claudeLine(id: "b", model: "claude-haiku-5-5", input: 150_000))
        let each: Double = 60_000.0 * 0.10 / 1e6 + 150_000.0 * 0.50 / 1e6      // 0.006 + 0.075 = 0.081
        #expect(b.count == 1 && near(b[0].dollars, each))
        // Pricing the 210k day total as one request would give 210k * 0.50 = 0.105.
        let asOne: Double = 210_000.0 * 0.50 / 1e6
        #expect(!near(b[0].dollars, asOne))
    }

    // MARK: Codex

    private func codexDollars(model: String, turns: [(input: Int, cached: Int, output: Int)]) -> [UsageBucket] {
        let f = UsageFixture()
        var text = UsageFixture.codexContext(model)
        var i = 0, c = 0, o = 0
        for (n, t) in turns.enumerated() {
            i += t.input; c += t.cached; o += t.output
            text += UsageFixture.codexCount(ts: "2026-11-09T10:0\(n):00.000Z", input: i, cached: c, output: o)
        }
        f.write("2026/11/09/rollout-x.jsonl", base: f.codex, text)
        let s = f.scanner(); s.scan()
        return s.buckets()
    }

    @Test func codexSplitsCachedFromUncachedInput() {
        // gpt-5.5 short: 5 | 0.50 | 30. Input 200k of which 80k cached, output 100k:
        // 120k*5 + 80k*0.5 + 100k*30 = 0.60 + 0.04 + 3.00 = 3.64
        let b = codexDollars(model: "gpt-5.5", turns: [(200_000, 80_000, 100_000)])
        #expect(near(b[0].dollars, 3.64))
        #expect(b[0].tokens.input == 120_000 && b[0].tokens.cacheRead == 80_000)
    }

    @Test func codexLongTierStartsAboveTwoSeventyTwoThousandInputTokens() {
        // Input counts cached + uncached. 272,000 -> short (5 / 0.5 / 30); 272,001 -> long (10 / 1 / 45).
        let short = codexDollars(model: "gpt-5.5", turns: [(272_000, 172_000, 1_000_000)])
        let wantShort: Double = (100_000.0 * 5 + 172_000.0 * 0.5 + 1_000_000.0 * 30) / 1e6
        #expect(near(short[0].dollars, wantShort))
        let long = codexDollars(model: "gpt-5.5", turns: [(272_001, 172_000, 1_000_000)])
        let wantLong: Double = (100_001.0 * 10 + 172_000.0 * 1 + 1_000_000.0 * 45) / 1e6
        #expect(near(long[0].dollars, wantLong))
    }

    // MARK: matching and unpriced

    @Test func longestIdWins() {
        #expect(ModelPrices.price(for: "gpt-5.6-sol")?.id == "gpt-5.6-sol")
        #expect(ModelPrices.price(for: "claude-opus-4-8")?.id == "claude-opus-4-8")
        #expect(ModelPrices.price(for: "claude-sonnet-5-5")?.id == "claude-sonnet-5-5")
        #expect(ModelPrices.price(for: "claude-sonnet-5-5-20261001")?.id == "claude-sonnet-5-5")
        #expect(ModelPrices.price(for: "claude-opus-4-8")?.base.input == 5)
        #expect(ModelPrices.price(for: "claude-sonnet-5-5")?.base.cacheRead == 0.10)
    }

    @Test func sparkAndUnknownModelsStayUnpriced() {
        #expect(ModelPrices.price(for: "gpt-5.3-codex-spark") == nil)
        #expect(ModelPrices.price(for: "gpt-5.3-codex") == nil)
        #expect(ModelPrices.price(for: "claude-brand-new-9") == nil)
        let b = codexDollars(model: "gpt-5.3-codex-spark", turns: [(1000, 0, 100)])
        #expect(b[0].dollars == nil && b[0].tokens.input == 1000)
    }
}
