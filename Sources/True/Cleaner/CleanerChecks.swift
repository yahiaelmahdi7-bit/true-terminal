import Foundation

/// Pure post-processing of a rewrite: sanitize, the lean gate, and the dropped-fact check.
enum CleanerChecks {
    /// Output at or above this fraction of the original's bytes counts as "Lean" (nothing worth applying).
    static let leanRatio = 0.97

    // MARK: Sanitize

    /// Trim, strip one wrapping fence, keep the original's first line (the handoff board reads it as
    /// the title). Empty → error.
    static func sanitize(_ raw: String, original: String) -> Result<String, CleanerError> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripWrappingFence(text, original: original)
        guard !text.isEmpty else { return .failure(CleanerError(message: "Empty output")) }

        let orig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let origFirst = firstLine(orig)
        guard !origFirst.isEmpty else { return .success(text) }
        var lines = text.components(separatedBy: "\n")
        let outFirst = lines[0].trimmingCharacters(in: .whitespaces)
        if outFirst == origFirst { return .success(text) }
        if isHeading(origFirst) && isHeading(outFirst) {
            lines[0] = origFirst
        } else if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == origFirst }) {
            lines.remove(at: i)                      // present but not first: move it to the top
            lines.insert(origFirst, at: 0)
        } else {
            lines.insert(contentsOf: [origFirst, ""], at: 0)
        }
        return .success(lines.joined(separator: "\n"))
    }

    private static func firstLine(_ s: String) -> String {
        (s.components(separatedBy: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    private static func isHeading(_ line: String) -> Bool { line.hasPrefix("#") }

    /// One ``` fence around the whole output. Skipped when the original itself opens with a fence, since
    /// then a leading fence is real content.
    private static func stripWrappingFence(_ text: String, original: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"),
              !original.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 2, lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return text }
        lines.removeFirst(); lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Lean

    static func isLean(original: String, output: String) -> Bool {
        Double(output.utf8.count) >= leanRatio * Double(original.utf8.count)
    }

    // MARK: Dropped facts

    private static func regex(_ p: String) -> NSRegularExpression {
        // Patterns are literals below; a typo is a programmer error caught by the tests.
        try! NSRegularExpression(pattern: p)
    }
    private static let backticks = regex("(?<!`)`([^`\\n]+)`(?!`)")
    private static let urls = regex("https?://[^\\s)>\\]\"'`]+")
    private static let paths = regex("(?<![\\w/.:~-])(?:~/|/Users/|/opt/|/private/|/Library/)[^\\s`)\"'>\\]]+")
    private static let uuids = regex("\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b")
    private static let hex = regex("(?<![\\w-])[0-9a-fA-F]{8,}(?![\\w-])")

    /// Facts in `original` (backticked spans, URLs, absolute/home paths, hex/UUID ids) that do not appear
    /// verbatim in `output`, in first-seen order. Hex runs need a digit AND a letter, so dates and plain
    /// words don't count as ids.
    static func droppedFacts(original: String, output: String) -> [String] {
        var seen = Set<String>()
        var dropped: [String] = []
        func consider(_ fact: String) {
            let f = trimTrailingPunctuation(fact)
            guard f.count >= 2, seen.insert(f).inserted, !output.contains(f) else { return }
            dropped.append(f)
        }
        let ns = original as NSString
        let all = NSRange(location: 0, length: ns.length)
        var hits: [(Int, String)] = []
        func collect(_ re: NSRegularExpression, group: Int = 0, filter: (String) -> Bool = { _ in true }) {
            for m in re.matches(in: original, range: all) {
                let s = ns.substring(with: m.range(at: group))
                if filter(s) { hits.append((m.range.location, s)) }
            }
        }
        collect(backticks, group: 1)
        collect(urls)
        collect(paths)
        collect(uuids)
        collect(hex) { s in s.contains(where: \.isNumber) && s.contains(where: \.isLetter) }
        for (_, s) in hits.sorted(by: { $0.0 < $1.0 }) { consider(s) }
        return dropped
    }

    private static func trimTrailingPunctuation(_ s: String) -> String {
        var f = s
        while let l = f.last, ".,;:!?".contains(l) { f.removeLast() }
        return f
    }
}
