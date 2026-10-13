import Foundation

/// Matching + ordering for the Open Project palette. Pure functions, no UI imports.
///
/// Tiers (a higher tier always beats a lower one): exact name > name prefix > subsequence in the name
/// > subsequence in the parent path > typo match. Inside the subsequence tiers a DP picks the best
/// alignment, rewarding word-boundary hits and consecutive runs.
enum ProjectMatcher {
    private static let exactTier = 100_000.0
    private static let prefixTier = 80_000.0
    private static let nameTier = 40_000.0
    private static let parentTier = 10_000.0
    private static let typoTier = 1_000.0

    /// Projects in display order. `recent` is paths, newest first.
    static func rank(_ projects: [Project], query: String, recent: [String] = []) -> [Project] {
        var age: [String: Int] = [:]
        for (i, p) in recent.enumerated() { age[ProjectList.standardize(p)] = age[ProjectList.standardize(p)] ?? i }
        let q = query.trimmingCharacters(in: .whitespaces)

        func byName(_ a: Project, _ b: Project) -> Bool {
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            return c == .orderedSame ? a.path < b.path : c == .orderedAscending
        }

        if q.isEmpty {
            let recents = projects.filter { age[$0.path] != nil }.sorted { age[$0.path]! < age[$1.path]! }
            let rest = projects.filter { age[$0.path] == nil }.sorted(by: byName)
            return recents + rest
        }

        let scored: [(Project, Double)] = projects.compactMap { p in
            score(name: p.name, parent: p.parent, query: q).map { (p, $0) }
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let ra = age[a.0.path] ?? Int.max, rb = age[b.0.path] ?? Int.max
            if ra != rb { return ra < rb }
            return byName(a.0, b.0)
        }.map(\.0)
    }

    /// nil = no match at all.
    static func score(name: String, parent: String, query: String) -> Double? {
        let q = Array(query.lowercased())
        let n = name.lowercased()
        if n == query.lowercased() { return exactTier }
        if n.hasPrefix(query.lowercased()) { return prefixTier - Double(n.count - q.count) }
        if let s = subsequenceScore(query: q, text: Array(name)) { return nameTier + s }
        if let s = subsequenceScore(query: q, text: Array(parent)) { return parentTier + s }
        if q.count >= 3, let d = typoDistance(query: q, name: Array(n)) { return typoTier - Double(d) * 100 }
        return nil
    }

    // MARK: Subsequence

    private static func isBoundary(_ t: [Character], _ j: Int) -> Bool {
        if j == 0 { return true }
        let prev = t[j - 1]
        if "-_. /".contains(prev) { return true }
        return prev.isLowercase && t[j].isUppercase   // camelCase hump
    }

    /// Best alignment score of `query` as a case-insensitive subsequence of `text`, nil if none.
    static func subsequenceScore(query q: [Character], text: [Character]) -> Double? {
        let m = q.count, n = text.count
        guard m > 0, m <= n else { return nil }
        let low = text.map { Character($0.lowercased()) }
        let neg = -Double.infinity
        // best[j] = best score with the CURRENT query char matched at text position j.
        var best = [Double](repeating: neg, count: n)
        for j in 0..<n where low[j] == q[0] {
            best[j] = 10 + (isBoundary(text, j) ? 30 : 0) - Double(min(j, 20)) * 0.5
        }
        for i in 1..<max(m, 1) {
            var next = [Double](repeating: neg, count: n)
            for j in i..<n where low[j] == q[i] {
                var top = neg
                for k in (i - 1)..<j where best[k] > neg {
                    let gap = Double(j - k - 1)
                    let s = best[k] + (k == j - 1 ? 15 : -min(gap, 10))
                    if s > top { top = s }
                }
                if top > neg { next[j] = top + 10 + (isBoundary(text, j) ? 30 : 0) }
            }
            best = next
        }
        let r = best.max() ?? neg
        return r > neg ? r : nil
    }

    // MARK: Typos

    /// Distance to the name (or its same-length prefix) when it is within tolerance, else nil.
    static func typoDistance(query q: [Character], name: [Character]) -> Int? {
        let limit = q.count <= 5 ? 1 : 2
        let d = min(damerauLevenshtein(q, name), damerauLevenshtein(q, Array(name.prefix(q.count))))
        return d <= limit ? d : nil
    }

    /// Optimal-string-alignment distance: insert, delete, substitute, swap two neighbours (each 1).
    static func damerauLevenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}
