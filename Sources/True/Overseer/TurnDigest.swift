import Foundation

/// One tool call in the last turn, with its result paired in by `tool_use_id`.
struct TurnStep: Equatable, Sendable {
    var n: Int
    var tool: String
    var what: String
    var result: String
    var failed: Bool

    var json: [String: Any] { ["n": n, "tool": tool, "what": what, "result": result, "failed": failed] }
}

/// The LAST turn of a Claude transcript, boiled down to what the Overseer asks Jev about.
struct TurnDigest: Equatable, Sendable {
    var asked: String
    var steps: [TurnStep]
    /// Code fact: an Edit / Write / MultiEdit / NotebookEdit ran in the turn.
    var edited: Bool
    var answer: String

    /// The Jev state object `{asked, steps, edited, answer}`.
    var state: [String: Any] {
        ["asked": asked, "steps": steps.map(\.json), "edited": edited, "answer": answer]
    }

    /// Characters in the state as sent, for the log line.
    var stateChars: Int {
        guard JSONSerialization.isValidJSONObject(state),
              let d = try? JSONSerialization.data(withJSONObject: state) else { return 0 }
        return String(decoding: d, as: UTF8.self).count
    }

    /// The same digest with `Redact.secrets` applied to asked / steps / answer.
    var redacted: TurnDigest {
        TurnDigest(asked: Redact.secrets(asked),
                   steps: steps.map { TurnStep(n: $0.n, tool: $0.tool, what: Redact.secrets($0.what),
                                               result: Redact.secrets($0.result), failed: $0.failed) },
                   edited: edited, answer: Redact.secrets(answer))
    }
}

/// Pure: transcript JSONL to the last turn's digest. Reuses `TranscriptParser.promptText` so "what counts as a
/// real prompt" has one definition.
enum TurnDigestBuilder {
    static let askedLimit = 1_500
    static let stepCap = 30
    static let resultLimit = 240
    static let answerLimit = 3_000
    static let answerHead = 800
    static let answerTail = 2_200
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    /// Reading stops growing the window here.
    static let maxWindow = 8 << 20

    /// `hadPrompt` is false when the data began mid-turn (no real user prompt inside), so `load` knows to widen.
    static func build(_ data: Data, stopMessage: String?) -> (digest: TurnDigest, hadPrompt: Bool) {
        var asked = ""
        var hadPrompt = false
        var steps: [TurnStep] = []
        var index: [String: Int] = [:]          // tool_use_id -> position in `steps`
        var total = 0                            // steps seen, for `n` (the cap drops the oldest)
        var edited = false
        var afterTool: [String] = []
        var lastText: String?

        for slice in data.split(separator: 10, omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(slice))) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  (obj["isSidechain"] as? Bool) != true,
                  (obj["isCompactSummary"] as? Bool) != true,
                  (obj["isApiErrorMessage"] as? Bool) != true else { continue }
            let content = (obj["message"] as? [String: Any])?["content"]

            if type == "user" {
                if let blocks = content as? [[String: Any]],
                   blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                    for b in blocks where (b["type"] as? String) == "tool_result" {
                        guard let id = b["tool_use_id"] as? String, let i = index[id] else { continue }
                        steps[i].result = tail(flatten(b["content"]), resultLimit)
                        steps[i].failed = (b["is_error"] as? Bool) == true
                    }
                    continue
                }
                guard (obj["isMeta"] as? Bool) != true, let prompt = TranscriptParser.promptText(content) else { continue }
                hadPrompt = true
                asked = String(prompt.prefix(askedLimit))
                steps = []; index = [:]; total = 0; edited = false; afterTool = []; lastText = nil
            } else {
                guard let blocks = content as? [[String: Any]] else { continue }
                for b in blocks {
                    switch b["type"] as? String {
                    case "tool_use":
                        afterTool = []
                        total += 1
                        let name = (b["name"] as? String) ?? ""
                        let input = ((b["input"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }
                        let s = ToolSummary.summarize(tool: name, input: input)
                        if editTools.contains(name) { edited = true }
                        steps.append(TurnStep(n: total, tool: s.tool, what: s.detail ?? "", result: "", failed: false))
                        if let id = b["id"] as? String { index[id] = steps.count - 1 }
                        if steps.count > stepCap {
                            steps.removeFirst()
                            index = index.compactMapValues { $0 > 0 ? $0 - 1 : nil }
                        }
                    case "text":
                        guard let t = b["text"] as? String,
                              !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        lastText = t
                        afterTool.append(t)
                    default: break
                    }
                }
            }
        }
        let fallback = afterTool.isEmpty ? (lastText ?? "") : afterTool.joined(separator: "\n\n")
        let stop = stopMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answer = clipAnswer(stop.isEmpty ? fallback : stop)
        return (TurnDigest(asked: asked, steps: steps, edited: edited, answer: answer), hadPrompt)
    }

    /// Reads from the END in growing windows until the last real prompt is inside (or the file starts, or the cap).
    static func load(url: URL, stopMessage: String?, chunk: Int = ResultsLoader.chunk,
                     maxWindow: Int = TurnDigestBuilder.maxWindow) -> TurnDigest? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        var window = UInt64(max(1, chunk))
        let cap = UInt64(max(1, maxWindow))
        while true {
            let start = size > window ? size - window : 0
            guard (try? h.seek(toOffset: start)) != nil, var data = try? h.read(upToCount: Int(size - start)) else { return nil }
            if start > 0 {   // drop the partial first line
                if let nl = data.firstIndex(of: 10) { data = data.subdata(in: data.index(after: nl)..<data.endIndex) }
                else if window < cap { window = min(window * 2, cap); continue }
                else { data = Data() }
            }
            let (digest, hadPrompt) = build(data, stopMessage: stopMessage)
            if hadPrompt || start == 0 || window >= cap { return digest }
            window = min(window * 2, cap)
        }
    }

    /// Over 3,000 chars: first 800 + " … " + last 2,200.
    static func clipAnswer(_ s: String) -> String {
        s.count > answerLimit ? String(s.prefix(answerHead)) + " … " + String(s.suffix(answerTail)) : s
    }

    private static func flatten(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return ""
    }

    /// Whitespace-collapsed, last `n` characters.
    private static func tail(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > n ? String(flat.suffix(n)) : flat
    }
}
