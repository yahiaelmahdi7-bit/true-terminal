import Foundation

/// Dollars per million tokens, by model, as explicit rates (no multipliers). An unknown model is "unpriced", never
/// guessed and never mapped to a sibling: the first unpriced model to show up is the cue to add a verified row.
///
/// Sources, verified 2026-11-09:
///   https://platform.claude.com/docs/en/about-claude/pricing
///   https://developers.openai.com/api/docs/pricing
/// Context sizes (`contextTokens`), confirmed 2026-11-09 on Anthropic's models overview page:
///   https://platform.claude.com/docs/en/about-claude/models/overview  (row "Context window": 1M tokens for
///   Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5). Every other row stays nil: the page lists them only as links, and
///   an unconfirmed size is never guessed (nil = no context meter).
/// Rows not in those tables are deliberately absent (gpt-5.3-codex-spark is not published by OpenAI, so it is unpriced).
///
/// Prices are applied to ONE request at a time (see `dollars`), because the long-prompt tier and the 5m/1h cache-write
/// split only make sense per request; the scanner adds dollars, not tokens, into the day buckets.
enum ModelPrices {
    static let checkedOn = "2026-11-09"

    /// One complete rate set, $/1M tokens.
    struct Rates: Equatable {
        let input: Double
        let cacheWrite5m: Double
        /// nil for Codex: OpenAI logs and bills no cache write.
        let cacheWrite1h: Double?
        let cacheRead: Double
        let output: Double
    }

    struct Price: Equatable {
        /// A model id matches when it equals `id`, or is `id` plus a date ("-20250929") or "-latest".
        let id: String
        let provider: UsageProvider
        let base: Rates
        /// Above `longThreshold` prompt tokens the whole request (every column, output too) uses `long`.
        let long: Rates?
        let longThreshold: Int
        /// The model's context window in tokens; nil = not confirmed, so no context meter.
        var contextTokens: Int? = nil
    }

    private static func claude(_ id: String, _ input: Double, _ w5: Double, _ w1: Double, _ read: Double, _ output: Double,
                               long: Rates? = nil, threshold: Int = 0, context: Int? = nil) -> Price {
        Price(id: id, provider: .claude, base: Rates(input: input, cacheWrite5m: w5, cacheWrite1h: w1, cacheRead: read, output: output),
              long: long, longThreshold: threshold, contextTokens: context)
    }
    // Codex: no cache write column. A write count (always 0 in real logs) is charged as ordinary input, no premium.
    private static func openAI(_ id: String, _ input: Double, _ cached: Double, _ output: Double,
                               long: (Double, Double, Double)? = nil) -> Price {
        func r(_ i: Double, _ c: Double, _ o: Double) -> Rates {
            Rates(input: i, cacheWrite5m: i, cacheWrite1h: nil, cacheRead: c, output: o)
        }
        return Price(id: id, provider: .codex, base: r(input, cached, output),
                     long: long.map { r($0.0, $0.1, $0.2) }, longThreshold: 272_000)
    }

    private static let oneMillion = 1_000_000

    static let table: [Price] = [
        // Claude: input | 5m write | 1h write | cache read | output
        claude("claude-fable-5-1", 10, 12.50, 20, 0.25, 50, context: oneMillion),
        claude("claude-fable-5", 10, 12.50, 20, 1, 50),
        claude("claude-opus-5-5", 4, 5, 8, 0.20, 20, context: oneMillion),
        claude("claude-opus-5", 5, 6.25, 10, 0.50, 25),
        claude("claude-opus-4-8", 5, 6.25, 10, 0.50, 25),
        claude("claude-opus-4-7", 5, 6.25, 10, 0.50, 25),
        claude("claude-opus-4-6", 5, 6.25, 10, 0.50, 25),
        claude("claude-opus-4-5", 5, 6.25, 10, 0.50, 25),
        claude("claude-opus-4-1", 15, 18.75, 30, 1.50, 75),
        claude("claude-opus-4", 15, 18.75, 30, 1.50, 75),
        claude("claude-sonnet-5-5", 2, 2.50, 4, 0.10, 10, context: oneMillion),
        claude("claude-sonnet-5", 2, 2.50, 4, 0.20, 10),
        claude("claude-sonnet-4-6", 3, 3.75, 6, 0.30, 15),
        claude("claude-sonnet-4-5", 3, 3.75, 6, 0.30, 15),
        claude("claude-sonnet-4", 3, 3.75, 6, 0.30, 15),
        // Haiku 5.5: a request whose prompt (input + cache read + cache write) is over 100,000 tokens is priced on the long rates.
        claude("claude-haiku-5-5", 0.10, 0.125, 0.20, 0.01, 0.50,
               long: Rates(input: 0.50, cacheWrite5m: 0.625, cacheWrite1h: 1, cacheRead: 0.05, output: 2.50), threshold: 100_000,
               context: oneMillion),
        claude("claude-haiku-4-5", 1, 1.25, 2, 0.10, 5),
        // Codex / OpenAI: input | cached input | output, long = request input over 272,000 tokens.
        // gpt-5.6-sol: promotional pricing until 2026-11-30 per OpenAI; re-check after.
        openAI("gpt-5.6-sol", 4, 0.40, 20, long: (8, 0.80, 30)),
        openAI("gpt-6.1-sol", 2, 0.10, 10, long: (4, 0.20, 15)),
        openAI("gpt-6-sol", 2, 0.20, 10, long: (4, 0.40, 15)),
        openAI("gpt-6-astra", 10, 1, 50, long: (20, 2, 75)),
        openAI("gpt-6-luna", 0.10, 0.01, 0.50, long: (0.20, 0.02, 0.75)),
        openAI("gpt-5.6-terra", 2, 0.20, 12, long: (4, 0.40, 18)),
        openAI("gpt-5.6-luna", 0.20, 0.02, 1.20, long: (0.40, 0.04, 1.80)),
        openAI("gpt-5.5", 5, 0.50, 30, long: (10, 1, 45)),
        openAI("gpt-5", 1.25, 0.125, 10),
        // From OpenAI's model pages; these models are shut down. No long tier.
        openAI("gpt-5.1-codex", 1.25, 0.125, 10),
        openAI("gpt-5.1-codex-mini", 0.25, 0.025, 2),
    ]

    static func price(for model: String) -> Price? {
        let m = model.lowercased()
        var best: Price?
        for p in table where matches(m, p.id) {
            if best == nil || p.id.count > best!.id.count { best = p }
        }
        return best
    }

    /// The model's context window, or nil when it is not confirmed (then no context meter is drawn).
    static func contextTokens(for model: String) -> Int? { price(for: model)?.contextTokens }

    private static func matches(_ model: String, _ id: String) -> Bool {
        if model == id { return true }
        guard model.hasPrefix(id + "-") else { return false }
        let rest = model.dropFirst(id.count + 1)
        return rest == "latest" || (rest.count == 8 && rest.allSatisfy(\.isNumber))
    }

    /// Estimated dollars for ONE request (one Claude message, one Codex token event); nil when the model has no row.
    /// `cacheWrite1h` is the part of `tokens.cacheWrite` written to the 1 hour cache; the rest is priced at the 5m rate
    /// (which is also what a missing `cache_creation` object means).
    /// Reasoning tokens are already inside Codex's output count, so output is charged once.
    static func dollars(model: String, tokens t: UsageTokens, cacheWrite1h: Int = 0) -> Double? {
        guard let p = price(for: model) else { return nil }
        var r = p.base
        if let long = p.long, t.input + t.cacheRead + t.cacheWrite > p.longThreshold { r = long }
        let w1 = min(max(0, cacheWrite1h), t.cacheWrite)
        let w5 = t.cacheWrite - w1
        let sum = Double(t.input) * r.input + Double(t.cacheRead) * r.cacheRead + Double(t.output) * r.output
            + Double(w5) * r.cacheWrite5m + Double(w1) * (r.cacheWrite1h ?? r.cacheWrite5m)
        return sum / 1_000_000
    }
}
