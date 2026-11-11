import Foundation

/// The Hub's Work board (pure, no IO): the same `TriageBucket`s `HubTriage.build` makes, folded into tiles.
/// Needs you: at most `HubLayout.maxNeedsYouTiles`, same-kind items share a tile, failures group by cause, the
/// overflow is one "N more" tile. Running: one tile per job. Done today: a strip. The backlog is only a count.

/// Where a job runs, as the chip on a Running tile.
enum HubWhere: Equatable {
    case cloud, myMac, otherMac(String)
    var label: String {
        switch self {
        case .cloud: return "Cloud"
        case .myMac: return "My Mac"
        case .otherMac(let name): return name
        }
    }
    var symbol: String {
        switch self {
        case .cloud: return "icloud"
        case .myMac: return "laptopcomputer"
        case .otherMac: return "person.2"
        }
    }
}

extension TriageItem {
    var runsOn: HubWhere { isCloud ? .cloud : machine.isEmpty ? .myMac : .otherMac(machine) }
}

struct HubTile: Identifiable, Equatable {
    enum Kind: Equatable { case single, group, failures, more }
    var id: String
    var kind: Kind
    var tone: TriageTone
    var title: String
    /// One quiet line under the title (project, cause, live step).
    var detail: String
    /// The tile's one main button.
    var button: String
    /// A second word-button; none today (Retry stays hidden until a retry engine exists).
    var secondary = ""
    /// What the tile stands for; its detail sheet lists these.
    var items: [TriageItem]
    var count: Int { items.count }
}

struct HubBoard: Equatable {
    var needsYou: [HubTile]
    /// Items behind the Needs-you tiles, overflow included.
    var needsYouCount: Int
    var running: [HubTile]
    var done: [TriageItem]
    var backlogCount: Int
    /// Nothing needs you and nothing runs: the empty Hub (finished jobs may still sit in the Done strip).
    var isEmpty: Bool { needsYou.isEmpty && running.isEmpty }
}

extension HubTriage {
    /// Group titles by kind (noun + the row's button), plain words. Anything unlisted falls back to "N <noun> need you".
    static func groupWords(noun: String, action: String, count n: Int) -> (title: String, button: String) {
        switch (noun, action) {
        case ("builders", "Review gates"): return ("\(n) reviews waiting", "Review")
        case ("builders", _): return ("\(n) builders need a go-ahead", "Give go-ahead")
        case ("cloud jobs", _): return ("\(n) cloud questions", "Answer")
        case ("panes", _): return ("\(n) panes need a look", "Look")
        case ("peer jobs", _): return ("\(n) requests from peers", "Look")
        case ("agents", _): return ("\(n) agents need you", "Look")
        default: return ("\(n) \(noun) need you", "Open")
        }
    }

    /// A row's button in one plain verb ("Review gates" -> "Review").
    static func plainVerb(_ label: String) -> String {
        switch label {
        case "": return "Open"
        case "Review gates": return "Review"
        default: return label
        }
    }

    /// One plain status line: "finished 1m ago", "<what> · 15m ago" for things waiting on you.
    static func plainStatus(_ i: TriageItem, now: Double) -> String {
        let age = HubTriage.age(now - i.at)
        let ago = age == "now" ? "just now" : "\(age) ago"
        if i.tone == .failed { return i.subtitle }
        if i.tone == .done || i.subtitle.hasPrefix("Finished") || i.actionLabel == "Review gates" || i.subtitle.contains("finished in") {
            return "finished \(ago)"
        }
        if i.tone == .needsYou { return [i.subtitle, ago].filter { !$0.isEmpty }.joined(separator: " · ") }
        return i.subtitle
    }

    /// Why a failed item failed, in one lowercase phrase. Items with the same phrase and kind share a tile.
    static func failureCause(_ i: TriageItem) -> String {
        let s = i.subtitle.lowercased()
        if s.contains("died") { return "died" }
        if s.contains("stopped") { return "stopped" }
        if s.contains("stuck") { return "looks stuck" }
        if i.isCloud, !i.subtitle.isEmpty, i.subtitle != "Failed" { return "failed: " + i.subtitle }
        if i.noun == "panes" { return "hit an error" }
        return "failed"
    }

    /// The board for the given buckets. `maxNeeds` is the Needs-you tile cap (including a "more" tile).
    static func board(_ buckets: [TriageBucket], maxNeeds: Int = HubLayout.maxNeedsYouTiles) -> HubBoard {
        func items(_ s: TriageSection) -> [TriageItem] {
            (buckets.first { $0.section == s }?.entries ?? []).flatMap { e -> [TriageItem] in
                switch e {
                case .row(let i): return [i]
                case .group(_, _, _, _, let xs): return xs
                }
            }
        }
        let needs = items(.needsYou)
        var order: [String] = []
        var bucketed: [String: [TriageItem]] = [:]
        for i in needs {
            let key = i.tone == .failed ? "fail|\(i.noun)|\(failureCause(i))" : "kind|\(i.noun)|\(i.actionLabel)"
            if bucketed[key] == nil { order.append(key) }
            bucketed[key, default: []].append(i)
        }
        let all: [HubTile] = order.map { key in
            let xs = bucketed[key]!
            let first = xs[0]
            let failed = first.tone == .failed
            if xs.count == 1 {
                return HubTile(id: "tile:\(first.id)", kind: failed ? .failures : .single, tone: first.tone, title: first.title,
                               detail: [first.project, first.subtitle].filter { !$0.isEmpty }.joined(separator: " · "),
                               button: failed ? "See what broke" : plainVerb(first.actionLabel),
                               items: xs)
            }
            if failed {
                let cause = failureCause(first)
                let words = cause.hasPrefix("failed: ") ? "failed" : cause
                let names = xs.prefix(3).map(\.title).joined(separator: ", ")
                let why = cause.hasPrefix("failed: ") ? String(cause.dropFirst(8)) + " · " : ""
                return HubTile(id: "tile:\(key)", kind: .failures, tone: .failed, title: "\(xs.count) \(first.noun) \(words)",
                               detail: why + names, button: "See what broke", items: xs)
            }
            let w = groupWords(noun: first.noun, action: first.actionLabel, count: xs.count)
            return HubTile(id: "tile:\(key)", kind: .group, tone: first.tone, title: w.title,
                           detail: Array(Set(xs.map(\.project))).sorted().prefix(3).joined(separator: ", "), button: w.button, items: xs)
        }
        var shown = all
        if all.count > maxNeeds {
            let rest = Array(all[(maxNeeds - 1)...])
            let hidden = rest.flatMap(\.items)
            shown = Array(all[..<(maxNeeds - 1)]) + [HubTile(id: "tile:more", kind: .more, tone: .needsYou, title: "\(rest.count) more groups",
                                                              detail: rest.map(\.title).joined(separator: " · "), button: "Open", items: hidden)]
        }
        let running = items(.working).map {
            HubTile(id: "run:\($0.id)", kind: .single, tone: .working, title: $0.title,
                    detail: $0.activity.isEmpty ? $0.subtitle : $0.activity, button: plainVerb($0.actionLabel),
                    items: [$0])
        }
        return HubBoard(needsYou: shown, needsYouCount: needs.count, running: running, done: items(.review),
                        backlogCount: buckets.first { $0.section == .backlog }?.count ?? 0)
    }
}
