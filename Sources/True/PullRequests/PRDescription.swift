import Foundation

/// The PR text, built from files that already exist. No model, no text box. A missing piece says
/// "not recorded"; nothing is invented.
enum PRDescription {
    struct Commit: Equatable, Sendable { var sha: String; var subject: String }

    /// `git log --reverse --format='%H %s'` lines.
    static func commits(fromLog log: String) -> [Commit] {
        log.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let sha = parts.first, GateReader.isSha(sha) else { return nil }
            return Commit(sha: sha, subject: parts.count > 1 ? parts[1] : "")
        }
    }

    /// First paragraph of a builder's `result.md` (or a seat's handoff): bold markers stripped, max 1200 chars.
    static func summary(fromResult text: String?) -> String? {
        guard let text else { return nil }
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for p in paragraphs {
            let lines = p.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            let joined = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                .replacingOccurrences(of: "**", with: "")
            if !joined.isEmpty { return String(joined.prefix(1200)) }
        }
        return nil
    }

    static func build(result: String?, commits: [Commit], head: String, gates: GateReader) -> String {
        let short = { (s: String) in String(s.prefix(7)) }
        var out = (summary(fromResult: result) ?? "Summary not recorded.") + "\n\n## What changed\n"
        out += commits.isEmpty ? "- not recorded\n" : commits.map { "- \(short($0.sha)) \($0.subject)" }.joined(separator: "\n") + "\n"
        out += "\n## Gate\n"
        if let g = gates.result(head), g.commit == head, !g.dirty {
            if g.passed {
                let tests = gates.testCount(g).map { "\($0) tests" } ?? "tests not recorded"
                out += "- Gate: passed on \(short(head)) (clean run), \(tests), \(Int(g.duration.rounded())) s."
                out += g.run_id.isEmpty ? "\n" : " Run \(String(g.run_id.prefix(8))).\n"
                out += "- Flaky: \(g.flaky.isEmpty ? "none" : g.flaky.joined(separator: ", ")). Failed: none.\n"
            } else {
                let why = g.reason.isEmpty ? (g.failed.first ?? "no reason recorded") : g.reason
                out += "- Gate: failed (\(why)).\n"
            }
        } else if let old = commits.reversed().first(where: { $0.sha != head && gates.result($0.sha) != nil }) {
            out += "- Gate: last run on \(short(old.sha)), not this commit.\n"
        } else {
            out += "- Gate: not run.\n"
        }
        out += "Built by True from the builder's result and the gate file. Edit on GitHub if needed.\n"
        return out
    }
}
