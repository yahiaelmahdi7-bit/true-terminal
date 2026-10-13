import Foundation

/// Pure helpers for "Show in Terminal": build a short search probe from an answer's Markdown, and find it
/// in the terminal's rows.
enum ResultsProbe {
    static let length = 40
    static let minimum = 12

    /// First non-empty line of the answer, Markdown stripped, whitespace collapsed, ~40 chars. Under ~12
    /// chars, the next line joins it. nil when there is nothing searchable.
    static func build(_ markdown: String) -> String? {
        var lines = markdown.split(whereSeparator: \.isNewline).map(String.init)
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        var out = ""
        for line in lines {
            let s = strip(line)
            if s.isEmpty { continue }
            out = out.isEmpty ? s : out + " " + s
            if out.count >= minimum { break }
        }
        return out.isEmpty ? nil : String(out.prefix(length))
    }

    /// One line of Markdown as Claude Code's terminal would show it: no heading hashes, list markers,
    /// emphasis stars, backticks or table pipes; link text only.
    static func strip(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for c in ["**", "__", "*", "`", "|"] { s = s.replacingOccurrences(of: c, with: c == "|" ? " " : "") }
        return collapse(s)
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Rows (first, last) of the LAST occurrence of `probe` in `rows`. Rows are joined so a match may
    /// wrap across them: first with a space, then (a word cut mid-way by the terminal) with nothing.
    static func find(_ probe: String, in rows: [String]) -> (first: Int, last: Int)? {
        let needle = collapse(probe)
        guard !needle.isEmpty else { return nil }
        for sep in [" ", ""] {
            var joined = ""
            var starts: [(offset: Int, row: Int)] = []
            var count = 0
            for (i, raw) in rows.enumerated() {
                let r = collapse(raw.replacingOccurrences(of: "\u{0}", with: " "))
                if r.isEmpty { continue }
                if !starts.isEmpty { joined += sep; count += sep.count }
                starts.append((count, i))
                joined += r; count += r.count
            }
            guard let range = joined.range(of: needle, options: .backwards) else { continue }
            let a = joined.distance(from: joined.startIndex, to: range.lowerBound)
            let b = joined.distance(from: joined.startIndex, to: range.upperBound) - 1
            func row(at o: Int) -> Int { starts.last { $0.offset <= o }?.row ?? 0 }
            return (row(at: a), row(at: b))
        }
        return nil
    }
}
