import Foundation

/// How full a seat's conversation is: tokens in the last request against the model's context window.
/// Never built when the window size is unknown, so "no size" can only mean "no meter".
struct ContextReading: Equatable {
    let used: Int
    let size: Int
    /// 0 to 1, clamped (a request can report slightly over the window).
    var fraction: Double { min(1, max(0, Double(used) / Double(size))) }
    var percent: Int { Int((fraction * 100).rounded()) }
    /// Plain label: "62%".
    var label: String { "\(percent)%" }
    /// The percent is drawn only from 90%; the accessibility label carries it always.
    var showsPercent: Bool { fraction >= 0.9 }

    init?(used: Int, size: Int?) {
        guard let size, size > 0, used >= 0 else { return nil }
        self.used = used; self.size = size
    }
}

/// Pure readers over the tail of a transcript or rollout (the last bytes, not the file). No network, no files:
/// the caller hands in text, so the rules are fixture-testable. A line cut in half by the tail is skipped.
enum ContextMeter {
    /// How much of a file's end the callers read: enough for several large turns, never the whole file.
    static let tailBytes = 256 * 1024

    /// Claude: the last assistant turn's input + cache read + cache write, against the model's `contextTokens`.
    /// Sub-agent lines and the "<synthetic>" placeholder turns are skipped. nil = nothing readable or size unknown.
    static func claude(tail text: String) -> ContextReading? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"usage\"") {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
                  let m = o["message"] as? [String: Any], let model = m["model"] as? String, model != "<synthetic>",
                  let u = m["usage"] as? [String: Any] else { continue }
            func n(_ k: String) -> Int { (u[k] as? Int) ?? 0 }
            let used = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
            // The newest real turn decides; if its model has no confirmed size there is no meter (no older fallback).
            return ContextReading(used: used, size: ModelPrices.contextTokens(for: model))
        }
        return nil
    }

    /// Codex: the last `token_count` event's `last_token_usage` against its own `model_context_window`.
    /// Counts that request's input and output (`total_tokens` when present). nil when either number is missing.
    static func codex(tail text: String) -> ContextReading? {
        for line in text.split(separator: "\n").reversed() where line.contains("last_token_usage") {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let p = o["payload"] as? [String: Any], p["type"] as? String == "token_count",
                  let info = p["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] else { continue }
            let used = (last["total_tokens"] as? Int)
                ?? ((last["input_tokens"] as? Int ?? 0) + (last["output_tokens"] as? Int ?? 0))
            return ContextReading(used: used, size: info["model_context_window"] as? Int)
        }
        return nil
    }

    /// Claude's reading for a transcript file: reads only its tail. nil = unreadable file, nothing found, or unknown size.
    static func claude(transcript url: URL) -> ContextReading? { tail(of: url).flatMap { claude(tail: $0) } }

    /// The last `tailBytes` of a file as text; nil if unreadable. Read-only.
    static func tail(of url: URL, bytes: Int = tailBytes) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return nil }
        try? h.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        guard let data = try? h.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
