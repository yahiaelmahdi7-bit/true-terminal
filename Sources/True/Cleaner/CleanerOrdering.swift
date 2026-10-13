import Foundation

/// Orders the rewrite queue by how padded each file looks to Jev, so the biggest wins land first.
/// It never skips a file and never shows a score: a 25%-cut file scored 0.48 next to 4%-cut files at
/// 0.44, so a skip threshold would lose real savings.
enum CleanerOrdering {
    static let maxInFlight = 8
    static let perCallTimeout: TimeInterval = 5
    /// The whole triage may hold the queue back this long, however many files there are.
    static let overallTimeout: TimeInterval = 5
    static let unscored = 1.0

    static let question: JevQuestion = .score(
        "How much of `file` could be deleted without losing any fact, path, command, decision or status the reader needs?",
        focus: "Judge filler (emphasis, generic advice, repetition), not whether the facts are still true.",
        levels: [
            "Already lean: nearly every line states a project-specific fact, path, command, decision or status; removing lines would lose information.",
            "Mostly lean: a few emphasis words, one repeated point, or a single generic reminder could go.",
            "Noticeable padding: several lines of loud emphasis (IMPORTANT, NEVER in capitals, bold warnings), generic good-practice advice, or rules stated twice.",
            "Heavily padded: whole sections are generic advice any engineer already follows, motivational framing, or the same rule repeated in several places.",
        ])

    private final class Scores: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: Double] = [:]
        func set(_ sha: String, _ v: Double) { lock.withLock { map[sha] = v } }
        var snapshot: [String: Double] { lock.withLock { map } }
    }

    /// One score per unique content (keyed by sha), at most `maxInFlight` calls at once. Files Jev did not
    /// score in time are simply absent.
    static func scores(for files: [ContextFile], jev: JevClient,
                       maxInFlight: Int = maxInFlight, perCall: TimeInterval = perCallTimeout,
                       overall: TimeInterval = overallTimeout) async -> [String: Double] {
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.sha).inserted }
        let scores = Scores()
        await withTaskGroup(of: Void.self) { top in
            top.addTask {
                await withTaskGroup(of: Void.self) { pool in
                    var it = unique.makeIterator()
                    func launch() {
                        guard !Task.isCancelled, let f = it.next() else { return }
                        pool.addTask {
                            let r = await jev.ask(state: ["file": f.content], questions: ["pad": question], timeout: perCall)
                            if let s = r?.answers["pad"]?.score { scores.set(f.sha, s) }
                        }
                    }
                    for _ in 0..<maxInFlight { launch() }
                    while await pool.next() != nil { launch() }
                }
            }
            top.addTask { try? await Task.sleep(for: .seconds(overall)) }
            _ = await top.next()
            top.cancelAll()
        }
        return scores.snapshot
    }

    /// Stable sort by score descending; unscored files count as 1.0, so all-unscored keeps scan order.
    static func sorted(_ files: [ContextFile], scores: [String: Double]) -> [ContextFile] {
        files.enumerated()
            .sorted { a, b in
                let sa = scores[a.element.sha] ?? unscored, sb = scores[b.element.sha] ?? unscored
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.element)
    }

    static func order(_ files: [ContextFile], jev: JevClient?) async -> [ContextFile] {
        guard let jev, files.count > 1 else { return files }
        return sorted(files, scores: await scores(for: files, jev: jev))
    }
}
