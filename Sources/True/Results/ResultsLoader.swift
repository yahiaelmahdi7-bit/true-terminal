import Foundation

/// A **result**: the final answer of one **turn** (everything from one real user prompt up to the next).
struct TurnResult: Identifiable, Equatable, Sendable {
    /// 0 = newest.
    var id: Int
    /// The answer as Claude wrote it (raw Markdown).
    var markdown: String
    /// First ~80 characters of the prompt that started the turn, one line.
    var prompt: String
    /// Timestamp of the answer's last block.
    var date: Date?
}

/// Pure: Claude Code transcript lines (JSONL) to results.
enum TranscriptParser {
    /// Results of the last `limit` turns that have one, newest first. `atFileStart: false` means the
    /// data is a tail whose first turn may be cut off, so that turn is dropped.
    static func parse(_ data: Data, atFileStart: Bool = true, limit: Int = 20) -> [TurnResult] {
        var turns: [Turn] = []
        var current: Turn?

        for slice in data.split(separator: 10, omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(slice))) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  (obj["isSidechain"] as? Bool) != true,
                  (obj["isCompactSummary"] as? Bool) != true,
                  (obj["isApiErrorMessage"] as? Bool) != true else { continue }
            let message = obj["message"] as? [String: Any]
            let content = message?["content"]
            let date = (obj["timestamp"] as? String).flatMap(parseDate)

            if type == "user" {
                guard (obj["isMeta"] as? Bool) != true, let prompt = promptText(content) else { continue }
                if let c = current { turns.append(c) }
                current = Turn(prompt: prompt)
            } else {
                if current == nil { current = Turn(prompt: "") }   // tail began mid-turn
                guard let blocks = content as? [[String: Any]] else { continue }
                for b in blocks {
                    switch b["type"] as? String {
                    case "tool_use":
                        current?.afterTool = []
                    case "text":
                        guard let t = b["text"] as? String,
                              !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        current?.last = (t, date)
                        current?.afterTool.append((t, date))
                    default: break
                    }
                }
            }
        }
        if let c = current { turns.append(c) }
        if !atFileStart, !turns.isEmpty { turns.removeFirst() }

        var out: [TurnResult] = []
        for t in turns.reversed() {
            guard let r = t.result else { continue }
            out.append(TurnResult(id: out.count, markdown: r.text, prompt: oneLine(t.prompt, 80), date: r.date))
            if out.count == limit { break }
        }
        return out
    }

    private struct Turn {
        var prompt: String
        var afterTool: [(String, Date?)] = []
        var last: (String, Date?)?
        /// Text after the last tool call, joined; else the last text block; else no result.
        var result: (text: String, date: Date?)? {
            if !afterTool.isEmpty {
                return (afterTool.map(\.0).joined(separator: "\n\n"), afterTool.last?.1)
            }
            return last.map { ($0.0, $0.1) }
        }
    }

    /// A real prompt's text (String content, or text blocks); nil for tool results and empty content.
    static func promptText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return nil }
        if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return nil }
        let texts = blocks.compactMap { b -> String? in
            (b["type"] as? String) == "text" ? b["text"] as? String : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func oneLine(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Reads a transcript from its END in chunks, so a tens-of-MB file costs about one chunk.
enum ResultsLoader {
    static let chunk = 1 << 20

    /// nil when the file can't be read. Stops at `limit` results or the start of the file.
    static func load(url: URL, limit: Int = 20, chunk: Int = ResultsLoader.chunk) -> [TurnResult]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        var window = UInt64(max(1, chunk))
        while true {
            let start = size > window ? size - window : 0
            guard (try? h.seek(toOffset: start)) != nil, var data = try? h.read(upToCount: Int(size - start)) else {
                return nil
            }
            if start > 0 {   // drop the partial first line
                guard let nl = data.firstIndex(of: 10) else {
                    window *= 2; continue
                }
                data = data.subdata(in: data.index(after: nl)..<data.endIndex)
            }
            let results = TranscriptParser.parse(data, atFileStart: start == 0, limit: limit)
            if results.count >= limit || start == 0 { return results }
            window *= 2
        }
    }
}
