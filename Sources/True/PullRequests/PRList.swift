import Foundation

struct PRRow: Equatable, Sendable, Encodable {
    var number: Int
    var title: String
    var author: String
    var headRef: String
    var head: String
    var additions: Int
    var deletions: Int
    var isDraft: Bool
    var url: String
    var gate: String
    var held: Bool
    var holdWhy: String
    /// The PR's commit oids (not part of the CLI/JSON output); the review screen needs them for the same gate word as the list.
    var commits: [String] = []

    private enum CodingKeys: String, CodingKey {
        case number, title, author, headRef, head, additions, deletions, isDraft, url, gate, held, holdWhy
    }
}

enum PRList {
    static let command = ["pr", "list", "--state", "open", "--limit", "50", "--json",
                          "number,title,author,headRefName,headRefOid,additions,deletions,isDraft,updatedAt,url,commits"]

    /// `builder/<name>/...` branches show the agent's name; anything else the GitHub login.
    static func author(headRef: String, login: String) -> String {
        guard headRef.hasPrefix("builder/") else { return login }
        let rest = headRef.dropFirst("builder/".count).split(separator: "/").first.map(String.init) ?? ""
        return rest.isEmpty ? login : rest
    }

    /// Decodes `gh pr list` JSON; the gate word and Held come from local files only (no extra GitHub calls).
    static func rows(json: String, gates: GateReader, held: (Int) -> HoldEntry?) -> [PRRow]? {
        struct Wire: Decodable {
            struct Author: Decodable { let login: String? }
            struct Commit: Decodable { let oid: String }
            let number: Int, title: String, headRefName: String, headRefOid: String
            let author: Author?, additions: Int?, deletions: Int?, isDraft: Bool?, url: String?, commits: [Commit]?
        }
        guard let items = try? JSONDecoder().decode([Wire].self, from: Data(json.utf8)) else { return nil }
        return items.map { w in
            let hold = held(w.number)
            return PRRow(number: w.number, title: w.title,
                         author: author(headRef: w.headRefName, login: w.author?.login ?? ""),
                         headRef: w.headRefName, head: w.headRefOid, additions: w.additions ?? 0, deletions: w.deletions ?? 0,
                         isDraft: w.isDraft ?? false, url: w.url ?? "",
                         gate: gates.word(head: w.headRefOid, commits: (w.commits ?? []).map(\.oid)).rawValue,
                         held: hold != nil, holdWhy: hold?.why ?? "",
                         commits: (w.commits ?? []).map(\.oid))
        }
    }

    static func load(ctx: PRContext) async -> (rows: [PRRow]?, error: String) {
        let r = await ctx.gh(command, timeout: 30)
        guard r.ok else { return (nil, PRCopy.ghFailure(r, other: "Could not load PRs.")) }
        guard let rows = rows(json: r.out, gates: ctx.gates, held: ctx.held) else { return (nil, "Could not load PRs.") }
        return (rows, "")
    }
}

/// `gh` present, recent enough, signed in. nil = fine; else the plain text to show.
enum PRPreflight {
    static let floor = [2, 92, 0]

    static func check(runner: PRRunner, cwd: String) async -> String? {
        let version = await runner.run(PRCommand(tool: .gh, args: ["--version"], cwd: cwd, timeout: 10))
        if version.missing { return PRCopy.ghMissing }
        guard version.ok, let v = parseVersion(version.out) else { return PRCopy.updateGH }
        if v.lexicographicallyPrecedes(floor) { return PRCopy.updateGH }
        let auth = await runner.run(PRCommand(tool: .gh, args: ["auth", "status", "--hostname", "github.com"], cwd: cwd, timeout: 15))
        if auth.ok { return nil }
        let failure = PRCopy.ghFailure(auth, other: PRCopy.signedOut)
        return failure
    }

    /// "gh version 2.92.0 (2026-04-28)" -> [2, 92, 0]
    static func parseVersion(_ text: String) -> [Int]? {
        guard let r = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return text[r].split(separator: ".").compactMap { Int($0) }
    }
}
