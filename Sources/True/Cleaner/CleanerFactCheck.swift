import Foundation

/// A block of the original that vanished from the rewrite and that Jev could not clear.
struct LostFact: Equatable, Sendable {
    let text: String
    /// The chip label: the first ~80 characters. The full text goes in the tooltip.
    var chip: String { text.count <= 80 ? text : String(text.prefix(80)) + "…" }
}

/// What Jev's fact check said about one rewrite. It only ever ADDS warnings to the regex checks.
enum FactCheck: Equatable, Sendable {
    /// Not run: lean or failed rows, or no Jev wired in.
    case notRun
    /// Jev answered and cleared everything (or nothing had vanished).
    case clean
    case flagged([LostFact])
    /// No Jev reply (no key, error, timeout): regex chips only.
    case off
    /// More than `maxBlocks` blocks vanished: too much to judge, review by eye.
    case largeRewrite(Int)

    var flags: [LostFact] { if case .flagged(let f) = self { return f }; return [] }
    /// Anything that should stop the row being pre-checked for apply.
    var blocksApply: Bool {
        switch self {
        case .flagged, .largeRewrite: return true
        default: return false
        }
    }
}

/// Finds blocks of the original that are neither present nor reworded in the output, then asks Jev
/// whether each is filler or still stated. Code owns the workflow; Jev only supplies judgments.
enum CleanerFactCheck {
    static let maxBlocks = 40
    static let flagBelow = 0.5
    static let minNormLength = 15
    static let diceCutoff = 0.6
    static let timeout: TimeInterval = 8

    // MARK: Blocks

    private static let markerPrefixes = ["#", "- ", "* ", "+ ", ">", "|"]

    private static func startsBlock(_ line: String) -> Bool {
        if markerPrefixes.contains(where: { line.hasPrefix($0) }) { return true }
        var digits = 0
        for ch in line {
            if ch.isASCII && ch.isNumber { digits += 1; continue }
            return digits > 0 && ch == "." && line.dropFirst(digits).hasPrefix(". ")
        }
        return false
    }

    /// A new block starts at a blank line or a line opening with `#`, `- `, `* `, `+ `, `<digits>. `, `>` or
    /// `|`; continuation lines are joined with one space.
    static func blocks(_ text: String) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        func flush() { if !cur.isEmpty { out.append(cur.joined(separator: " ")); cur = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if startsBlock(line) { flush() }
            cur.append(line)
        }
        flush()
        return out
    }

    private static let dropped = Set("*_`#>|")
    private static let leadingMarker = try! NSRegularExpression(pattern: #"^\s*(?:[-+]|\d+\.)\s+"#)

    /// lowercase → delete `* _ ` # > |` → drop a leading list marker → collapse whitespace → trim.
    static func norm(_ s: String) -> String {
        var t = String(s.lowercased().filter { !dropped.contains($0) })
        if let m = leadingMarker.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r = Range(m.range, in: t) { t.removeSubrange(r) }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 2·|common words (multiset)| / (|a| + |b|) over space-separated words of already-normalised text.
    static func dice(_ a: String, _ b: String) -> Double {
        let wa = a.split(separator: " "), wb = b.split(separator: " ")
        guard !wa.isEmpty || !wb.isEmpty else { return 0 }
        var counts: [Substring: Int] = [:]
        for w in wb { counts[w, default: 0] += 1 }
        var common = 0
        for w in wa where (counts[w] ?? 0) > 0 { counts[w]! -= 1; common += 1 }
        return 2 * Double(common) / Double(wa.count + wb.count)
    }

    /// Blocks of `original` that are gone from `output`: long enough to mean something, not a substring of
    /// the normalised output, and not close (Dice ≥ 0.6) to any single output block. A block repeated in the
    /// original is reported once (repetition is padding; the chips are keyed by text).
    static func vanished(original: String, output: String) -> [String] {
        let wholeOut = norm(output)
        let outBlocks = blocks(output).map(norm)
        var result: [String] = []
        var seen = Set<String>()
        for block in blocks(original) {
            let n = norm(block)
            guard n.count >= minNormLength, !wholeOut.contains(n), seen.insert(n).inserted else { continue }
            if outBlocks.contains(where: { dice(n, $0) >= diceCutoff }) { continue }
            result.append(block)
        }
        return result
    }

    // MARK: Jev

    static func fillerQuestion(_ i: Int) -> JevQuestion {
        .noul("Is `dropped[\(i)]` only emphasis, generic good-practice advice, motivational framing or a section heading, with no project-specific fact, path, command, number, decision or status?")
    }
    static func keptQuestion(_ i: Int) -> JevQuestion {
        .noul("Does `after` state the same information as `dropped[\(i)]`, possibly in different words?")
    }

    /// A block is flagged when Jev says it is neither filler nor still stated: max(filler, kept) < 0.5.
    /// A missing answer clears the block (Jev only adds flags on evidence).
    static func flag(filler: Double?, kept: Double?) -> Bool {
        guard let filler, let kept else { return false }
        return max(filler, kept) < flagBelow
    }

    static func run(original: String, output: String, jev: JevClient) async -> FactCheck {
        let gone = vanished(original: original, output: output)
        if gone.isEmpty { return .clean }
        if gone.count > maxBlocks { return .largeRewrite(gone.count) }
        let ids = Array(gone.indices)
        async let f = jev.ask(state: ["dropped": gone],
                              questions: Dictionary(uniqueKeysWithValues: ids.map { ("f\($0)", fillerQuestion($0)) }),
                              timeout: timeout)
        async let k = jev.ask(state: ["dropped": gone, "after": output],
                              questions: Dictionary(uniqueKeysWithValues: ids.map { ("k\($0)", keptQuestion($0)) }),
                              timeout: timeout)
        guard let filler = await f, let kept = await k else { return .off }
        let lost = ids.filter { i in
            flag(filler: filler.answers["f\(i)"]?.noul, kept: kept.answers["k\(i)"]?.noul)
        }.map { LostFact(text: gone[$0]) }
        return lost.isEmpty ? .clean : .flagged(lost)
    }
}
