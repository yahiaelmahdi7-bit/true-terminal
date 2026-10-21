import Foundation

/// The Hub's All view as a triage list (pure, no IO): what needs you first, what is working, what is done and
/// waiting for a look, and everything older. Built from the same models the old view used.

enum TriageSection: Int, CaseIterable, Identifiable {
    case needsYou, working, review, backlog
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .review: return "Done, to review"
        case .backlog: return "Backlog"
        }
    }
    var emptyText: String {
        switch self {
        case .needsYou: return "Nothing is waiting on you."
        case .working: return "Nothing is running."
        case .review: return "Nothing to review."
        case .backlog: return "Nothing older."
        }
    }
}

/// How a row looks: failed red, needs-you amber, working animated, done neutral.
enum TriageTone: Int {
    case needsYou, failed, working, done, idle
}

enum TriageAction: Equatable {
    case builder(String), cloud(String), watcher(String), seat(String), peer(Int32), pane(UUID), inbound(String)
}

struct TriageItem: Identifiable, Equatable {
    var id: String
    var section: TriageSection
    var tone: TriageTone
    var title: String
    var subtitle: String
    /// Project folder name, shown as a chip.
    var project: String
    /// Seconds since 1970 the row's clock runs from (start while working, end once finished).
    var at: Double
    var isCloud = false
    /// "Sonnet 5.5 · High" for a cloud job that recorded it; empty = none.
    var modelChip = ""
    /// The one button on the row; empty = none.
    var actionLabel: String
    var action: TriageAction
    /// Noun for a group of these ("builders", "cloud jobs"); the verb comes from the tone.
    var noun = "items"
    /// One line of "what it is doing now" for a Working card; empty = none.
    var activity = ""
}

/// One visible entry: a row, or a run of same-project rows folded into one.
enum TriageEntry: Identifiable, Equatable {
    case row(TriageItem)
    case group(id: String, project: String, tone: TriageTone, label: String, items: [TriageItem])

    var id: String {
        switch self {
        case .row(let i): return i.id
        case .group(let id, _, _, _, _): return id
        }
    }
}

struct TriageBucket: Identifiable, Equatable {
    var section: TriageSection
    var entries: [TriageEntry]
    var count: Int
    var id: Int { section.rawValue }
}

enum HubTriage {
    /// A run shorter than this stays as separate rows.
    static let groupMin = 3

    /// Needs you / Done-to-review only hold things that are live. Anything older than this drops to the Backlog.
    static let liveWindow: Double = 86_400

    /// True while `at` is inside the live window.
    static func isLive(_ at: Double, now: Double) -> Bool { now - at < liveWindow }

    /// Everything on screen, in the four sections (always all four, so empty states can show).
    /// `openPanes` = the panes currently open in True (nil = unknown, no filtering); `dismissed` = row ids the user ×'d.
    @MainActor
    static func build(groups: [HubProjectGroup], seatStatus: (String) -> AgentStatus, cloud: [CloudJob],
                      watcher: [InboxItem], builders: [BuilderRecord] = [], yourMove: [YourMoveRow] = [],
                      openPanes: Set<UUID>? = nil, inbound: [InboundJob] = [], dismissed: Set<String> = [],
                      activity: (BuilderRecord) -> String? = { _ in nil }, now: Double) -> [TriageBucket] {
        var items: [TriageItem] = []
        for g in groups {
            for a in g.seats {
                let s = seatStatus(a.name)
                guard s == .needsYou || s == .working || s == .idle || s == .done else { continue }   // asleep seats live on the Agents tab
                let sec: TriageSection = s == .needsYou ? .needsYou : s == .working ? .working : .backlog
                items.append(TriageItem(id: "seat:\(a.name)", section: sec,
                                        tone: s == .needsYou ? .needsYou : s == .working ? .working : .idle,
                                        title: a.name, subtitle: "Agent · \(s.label)", project: g.title, at: now,
                                        actionLabel: "Open", action: .seat(a.name), noun: "agents",
                                        activity: s == .working ? "Agent working" : ""))
            }
            for b in g.background {
                var it = item(b, project: g.title, now: now)
                if it.section == .working { it.activity = activity(b) ?? "" }
                items.append(it)
            }
            for p in g.others {
                items.append(TriageItem(id: "peer:\(p.pid)", section: p.busy ? .working : .backlog,
                                        tone: p.busy ? .working : .idle, title: p.displayName,
                                        subtitle: "Claude session · \(hubKindLabel(p.kind))", project: g.title,
                                        at: p.updatedAt, actionLabel: "Reveal", action: .peer(p.pid), noun: "sessions",
                                        activity: p.busy ? "Claude session · \(hubKindLabel(p.kind))" : ""))
            }
        }
        for j in cloud where j.archived != true { items.append(item(j, now: now)) }
        let byID = Dictionary(builders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var covered: Set<String> = []
        for w in watcher {
            let it = item(w, builder: byID[w.subject], now: now)
            if w.source == "builders" { covered.insert("builder:\(w.subject)") }
            items.append(it)
        }
        // The watcher row already speaks for a builder that needs a look: don't list it twice.
        items.removeAll { covered.contains($0.id) && $0.section != .working }
        for r in yourMove {
            // The Overseer's verdict on a pane: stuck or asking is yours now; "says done, unchecked" is a review.
            // A pane that is no longer open in True has nothing left to answer.
            let open = openPanes?.contains(r.pane) ?? true
            let urgent = r.kind == .blocked || r.kind == .asksYou || r.kind == .asksToContinue
            let live = open && isLive(r.at.timeIntervalSince1970, now: now)
            items.append(TriageItem(id: "pane:\(r.pane.uuidString)", section: !live ? .backlog : urgent ? .needsYou : .review,
                                    tone: !live ? .idle : r.kind == .blocked ? .failed : .needsYou, title: r.name,
                                    subtitle: "\(r.kind.label) · \(r.reason)", project: r.project, at: r.at.timeIntervalSince1970,
                                    actionLabel: "Open", action: .pane(r.pane), noun: "panes"))
        }
        // A peer's job waiting on Accept is yours to answer; once accepted it is the peer-jobs list's business.
        for j in inbound where j.status == .queued && j.inboundMode == .ask {
            let repo = j.req.hasRepo ? (j.req.repo as NSString).lastPathComponent : "no project"
            items.append(TriageItem(id: "inbound:\(j.id)", section: .needsYou, tone: .needsYou, title: j.req.title,
                                    subtitle: "From \(j.peerLabel) · waiting for Accept", project: repo,
                                    at: j.received.timeIntervalSince1970, actionLabel: "Accept",
                                    action: .inbound(j.id), noun: "peer jobs"))
        }
        items.removeAll { dismissed.contains($0.id) && $0.section != .working }
        return TriageSection.allCases.map { sec in
            let mine = sorted(items.filter { $0.section == sec })
            // Working cards and the Backlog stay flat; only the inbox sections fold runs.
            let foldable = sec == .needsYou || sec == .review
            return TriageBucket(section: sec, entries: foldable ? fold(mine) : mine.map { .row($0) }, count: mine.count)
        }
    }

    /// A Watcher item as a row. Only a builder that finished/failed inside the live window and isn't acked is yours;
    /// a record that is gone, acked or old goes to the Backlog, as does everything about a git branch or a closed pane.
    static func item(_ w: InboxItem, builder: BuilderRecord?, now: Double) -> TriageItem {
        let repo = (w.repo as NSString).lastPathComponent
        let name = builder?.name ?? cleanName(w.title)
        func make(_ sec: TriageSection, _ tone: TriageTone, _ sub: String, _ label: String, at: Double) -> TriageItem {
            TriageItem(id: "watch:\(w.id)", section: sec, tone: sec == .backlog ? .idle : tone, title: name, subtitle: sub,
                       project: repo, at: at, actionLabel: label, action: .watcher(w.id), noun: "builders")
        }
        guard w.source == "builders", let b = builder, !b.acked else {
            return make(.backlog, .idle, w.title, "Open", at: w.at)
        }
        let at = b.state == .running ? w.at : (b.ended ?? b.started)
        switch w.kind {
        case "doneUnchecked": return make(isLive(at, now: now) && b.state == .done ? .needsYou : .backlog, .needsYou, "Finished: check its gates", "Review gates", at: at)
        case "failed", "died": return make(isLive(at, now: now) ? .needsYou : .backlog, .failed, w.kind == "died" ? "Died" : "Failed", "Open", at: at)
        case "paused": return make(isLive(at, now: now) && b.state == .paused ? .needsYou : .backlog, .needsYou, "Paused, needs a go-ahead", "Open", at: at)
        case "stuck": return make(b.state == .running ? .needsYou : .backlog, .needsYou, "Looks stuck", "Open", at: w.at)
        default: return make(.backlog, .idle, w.title, "Open", at: w.at)
        }
    }

    /// "Builder feed-so…: check its gates" → the builder's name, no boilerplate.
    static func cleanName(_ title: String) -> String {
        var t = title
        if t.hasPrefix("Builder ") { t.removeFirst("Builder ".count) }
        for tail in [" finished: check its gates", " paused: needs a go-ahead", " looks stuck", " failed", " died"] where t.hasSuffix(tail) {
            t.removeLast(tail.count); break
        }
        return t
    }

    /// "now", "2m", "3h", "6d" — one coarse unit, never "136h 31m ago".
    static func age(_ seconds: Double) -> String {
        let m = Int(max(seconds, 0) / 60)
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        if m < 60 * 24 { return "\(m / 60)h" }
        return "\(m / 1440)d"
    }

    static func item(_ b: BuilderRecord, project: String, now: Double) -> TriageItem {
        let ran = hubElapsed(b.elapsed(now: now))
        let model = b.model.isEmpty ? "" : b.model.capitalized + " · "
        let at = b.state == .running ? b.started : (b.ended ?? b.started)
        func make(_ sec: TriageSection, _ tone: TriageTone, _ sub: String, _ label: String) -> TriageItem {
            TriageItem(id: "builder:\(b.id)", section: sec, tone: tone, title: b.name, subtitle: sub, project: project,
                       at: at, actionLabel: label, action: .builder(b.id), noun: "builders")
        }
        switch b.state {
        case .running: return make(.working, .working, "\(model)running \(ran)", "Open")
        case .paused: return make(isLive(at, now: now) ? .needsYou : .backlog, .needsYou, "\(model)paused, waiting for a go-ahead", "Open")
        case .done:
            let live = !b.acked && isLive(at, now: now)
            return make(live ? .review : .backlog, .done, "\(model)finished in \(ran)", live ? "Review gates" : "Open")
        case .failed, .killed, .died:
            let word = b.state == .failed ? "failed" : b.state == .killed ? "stopped" : "died"
            // A builder the user stopped himself is never his to answer.
            let live = !b.acked && b.state != .killed && isLive(at, now: now)
            return make(live ? .needsYou : .backlog, .failed, "\(model)\(word) after \(ran)", "Open")
        }
    }

    static func item(_ j: CloudJob, now: Double) -> TriageItem {
        let repo = (j.repo as NSString).lastPathComponent
        let unviewed = j.unviewed == true
        func make(_ sec: TriageSection, _ tone: TriageTone, _ sub: String, _ label: String, _ at: Double) -> TriageItem {
            TriageItem(id: "cloud:\(j.id)", section: sec, tone: tone, title: j.title, subtitle: sub, project: repo, at: at,
                       isCloud: true, modelChip: j.modelChip ?? "", actionLabel: label, action: .cloud(j.id), noun: "cloud jobs")
        }
        if j.needsYou { return make(.needsYou, .needsYou, j.needsYouReason ?? "Needs an answer to continue", "Answer", j.updatedAt) }
        if j.isWorking {
            var it = make(.working, .working, j.foremanStatus == "QUEUED" ? "Queued" : "Running \(hubElapsed(now - j.createdAt))", "Open", j.createdAt)
            it.activity = j.foremanStatus == "QUEUED" ? "Queued in the cloud" : "Running in the cloud"
            return it
        }
        let live = unviewed && isLive(j.updatedAt, now: now)
        if j.isFailed { return make(live ? .needsYou : .backlog, .failed, j.reason ?? "Failed", "Open", j.updatedAt) }
        return make(live ? .review : .backlog, .done, "Finished", live ? "Review" : "Open", j.updatedAt)
    }

    /// Loud tones first, then project clusters (newest project first), newest row first inside a cluster. Clustering
    /// is what lets consecutive rows of one project fold.
    static func sorted(_ items: [TriageItem]) -> [TriageItem] {
        var newest: [String: Double] = [:]
        for i in items { newest[i.project] = max(newest[i.project] ?? 0, i.at) }
        return items.sorted { a, b in
            if a.tone.rawValue != b.tone.rawValue { return a.tone.rawValue < b.tone.rawValue }
            if a.project != b.project {
                let (na, nb) = (newest[a.project] ?? 0, newest[b.project] ?? 0)
                return na != nb ? na > nb : a.project.lowercased() < b.project.lowercased()
            }
            return a.at != b.at ? a.at > b.at : a.id < b.id
        }
    }

    /// Runs of ≥ `groupMin` consecutive rows sharing project + tone + kind become one group.
    static func fold(_ items: [TriageItem]) -> [TriageEntry] {
        var out: [TriageEntry] = []
        var i = 0
        while i < items.count {
            var j = i + 1
            while j < items.count, items[j].project == items[i].project, items[j].tone == items[i].tone,
                  items[j].noun == items[i].noun, items[j].isCloud == items[i].isCloud { j += 1 }
            let run = Array(items[i..<j])
            if run.count >= groupMin {
                out.append(.group(id: "group:\(run[0].id)", project: run[0].project, tone: run[0].tone,
                                  label: groupLabel(run), items: run))
            } else {
                out.append(contentsOf: run.map { .row($0) })
            }
            i = j
        }
        return out
    }

    /// "6 builders finished" / "4 builders failed" / "3 builders working".
    static func groupLabel(_ run: [TriageItem]) -> String {
        let verb: String
        switch run[0].tone {
        case .failed: verb = "failed"
        case .working: verb = "working"
        case .needsYou: verb = "need you"
        case .done: verb = "finished"
        case .idle: verb = "idle"
        }
        return "\(run.count) \(run[0].noun) \(verb)"
    }

    // MARK: header counts + keyboard order

    static func count(_ buckets: [TriageBucket], tone: TriageTone) -> Int {
        buckets.filter { $0.section != .backlog }.reduce(0) { total, b in
            total + b.entries.reduce(0) { sub, e in
                switch e {
                case .row(let i): return sub + (i.tone == tone ? 1 : 0)
                case .group(_, _, let t, _, let items): return sub + (t == tone ? items.count : 0)
                }
            }
        }
    }

    /// First row id with this tone (what clicking "4 failed" jumps to).
    static func firstID(_ buckets: [TriageBucket], tone: TriageTone) -> String? {
        for b in buckets where b.section != .backlog {
            for e in b.entries {
                switch e {
                case .row(let i) where i.tone == tone: return i.id
                case .group(let id, _, let t, _, _) where t == tone: return id
                default: break
                }
            }
        }
        return nil
    }

    /// Ids in the order ↑↓ walks them: every entry, plus a group's children while it is expanded; the Backlog's rows
    /// only while it is open. The two-column layout walks the left column only (`includeWorking: false`).
    static func visibleIDs(_ buckets: [TriageBucket], expanded: Set<String>, backlogOpen: Bool, includeWorking: Bool = true) -> [String] {
        var out: [String] = []
        for b in buckets where (b.section != .backlog || backlogOpen) && (b.section != .working || includeWorking) {
            for e in b.entries {
                out.append(e.id)
                if case .group(let id, _, _, _, let items) = e, expanded.contains(id) { out.append(contentsOf: items.map(\.id)) }
            }
        }
        return out
    }

    /// The next id after `current` moving `delta` rows, clamped; nothing selected → the first (↓) or last (↑).
    static func move(_ ids: [String], from current: String?, by delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let at = ids.firstIndex(of: current) else { return delta >= 0 ? ids.first : ids.last }
        return ids[min(max(at + delta, 0), ids.count - 1)]
    }

    static func entry(_ buckets: [TriageBucket], id: String) -> (item: TriageItem?, groupID: String?)? {
        for b in buckets {
            for e in b.entries {
                switch e {
                case .row(let i) where i.id == id: return (i, nil)
                case .group(let gid, _, _, _, let items):
                    if gid == id { return (nil, gid) }
                    if let i = items.first(where: { $0.id == id }) { return (i, nil) }
                default: break
                }
            }
        }
        return nil
    }
}

/// Header status pill for the cloud factory.
enum CloudLink: Equatable {
    case connected, offline, checking
    static func of(error: String?, loaded: Bool) -> CloudLink { !loaded ? .checking : error == nil ? .connected : .offline }
    var label: String {
        switch self {
        case .connected: return "Cloud · connected"
        case .offline: return "Cloud · offline — retry"
        case .checking: return "Cloud · checking"
        }
    }
}
