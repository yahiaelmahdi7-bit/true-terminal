import Foundation
import Observation

/// Where the Watcher puts things for the user. v1: the Hub reads the store directly; the digest is also kept as a line.
@MainActor protocol InboxChannel: AnyObject {
    func deliver(item: InboxItem)
    func deliver(digest: String)
}

/// The Hub's channel: the digest stays pinned (visible in the Watcher card) until the user opens it.
@Observable @MainActor
final class HubChannel: InboxChannel {
    var lastDigest: String?
    func deliver(item: InboxItem) {}
    func deliver(digest: String) { lastDigest = digest }
    func dismissDigest() { lastDigest = nil }
}

/// The Watcher's engine: signal -> screen -> wake gate -> dedupe -> (investigate) -> level -> Inbox.
/// Events only; no timers. Every outside effect is injected so tests run offline against temp dirs.
@Observable @MainActor
final class WatcherStore {
    static let shared = WatcherStore()
    /// Set once by the app; keeps tests and previews from touching ~/.true.
    nonisolated(unsafe) static var active = false

    struct Deps: @unchecked Sendable {
        var jev: JevClient = .shared
        var runner: Investigation.Runner = Investigation.systemRunner
        var spawn: BuilderSpawn.Runner = BuilderSpawn.systemRunner
        var git: @Sendable ([String]) -> String? = GitSignals.systemRunner
        var now: @Sendable () -> Date = { Date() }
        var root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".true/agents")
        var paths: Investigation.Paths = .standard()
        var builderBin: String = NSHomeDirectory() + "/.claude/bin/builder"
        var enabled: @Sendable () -> Bool = { UserDefaults.standard.object(forKey: "watcher.enabled") as? Bool ?? true }
    }

    private(set) var items: [InboxItem] = []
    private(set) var running: Set<String> = []
    private var approving: Set<String> = []
    private(set) var burnHookMissing = false
    var duty: Duty = Duty.watcherAgent().duty ?? Duty(job: Duty.watcherJob, triggers: [])
    let channel: InboxChannel
    private let d: Deps
    private let file: InboxFile
    private var home: URL { file.dir }

    init(deps: Deps = Deps(), channel: InboxChannel = HubChannel()) {
        d = deps; self.channel = channel
        file = InboxFile(dir: InboxFile.home(agent: Duty.watcherName, root: deps.root))
        file.ensureDir()
        _ = file.compactIfNeeded(now: deps.now().timeIntervalSince1970)
        events = file.events()
        items = Inbox.fold(events)
    }
    /// The folded log lives in memory; `emit` appends one line and folds, it never re-reads the file.
    private var events: [InboxEvent] = []

    var enabled: Bool { d.enabled() }
    private var now: Double { d.now().timeIntervalSince1970 }

    /// What the Hub shows: open items first (needs-you), nothing hidden by default.
    var needsYou: [InboxItem] { Inbox.needsYou(items, now: now) }

    private func emit(_ e: InboxEvent) {
        file.append(e)
        events.append(e)
        if file.compactIfNeeded(now: now) { events = file.events() }
        items = Inbox.fold(events)
    }

    // MARK: logs + ledger

    private func appendLine(_ name: String, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return }
        let u = home.appendingPathComponent(name)
        // Only the diagnostic logs rotate; ledger/lessons/state are read back for budgets and mutes.
        let cap = Self.rotating.contains(name) ? Self.logCap : Int.max
        JSONLog.append(Data((s + "\n").utf8), to: u, maxBytes: cap, keep: 2)
        if name == "ledger.jsonl", var t = todayCache, t.day == (obj["day"] as? String) { Self.accumulate(&t.total, obj); todayCache = t }
        if name == "lessons.jsonl" { lessonsCache = nil }
    }
    static let rotating: Set<String> = ["decisions.jsonl", "wake.jsonl"]
    static let logCap = 1 << 20
    private var todayCache: (day: String, total: Today)?
    private var lessonsCache: [[String: Any]]?
    /// Lessons change only through `appendLine`, so one read serves every `isMuted` until then.
    private func lessons() -> [[String: Any]] {
        if let c = lessonsCache { return c }
        let l = readLines("lessons.jsonl"); lessonsCache = l; return l
    }

    private func readLines(_ name: String) -> [[String: Any]] {
        guard let s = try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    struct Today: Equatable { var usd = 0.0; var fix = 0.0; var runs = 0; var jev = 0; var tokens = 0; var peakContext = 0; var perRepo: [String: Int] = [:] }

    /// Today's spend, local day; a new day starts at zero by construction.
    func today() -> Today {
        let key = Self.day(d.now())
        if let c = todayCache, c.day == key { return c.total }
        var t = Today()
        for l in readLines("ledger.jsonl") where (l["day"] as? String) == key { Self.accumulate(&t, l) }
        todayCache = (key, t)
        return t
    }

    private static func accumulate(_ t: inout Today, _ l: [String: Any]) {
        t.usd += (l["usd"] as? Double) ?? 0
        t.runs += (l["runs"] as? Int) ?? 0
        t.jev += (l["jev"] as? Int) ?? 0
        t.fix += (l["fix"] as? Double) ?? 0
        t.tokens += (l["tokens"] as? Int) ?? 0
        t.peakContext = max(t.peakContext, (l["tokens"] as? Int) ?? 0)
        if let r = l["repo"] as? String, ((l["runs"] as? Int) ?? 0) > 0 { t.perRepo[r, default: 0] += 1 }
    }

    /// `fix` (the approved builder's ceiling) is kept apart from `usd`, so it never eats the investigation budget.
    private func ledger(usd: Double = 0, fix: Double = 0, runs: Int = 0, jev: Int = 0, tokens: Int = 0, repo: String = "") {
        appendLine("ledger.jsonl", ["day": Self.day(d.now()), "at": now, "usd": usd, "fix": fix, "runs": runs, "jev": jev, "tokens": tokens, "repo": repo])
    }

    private func decision(_ what: String, _ detail: [String: Any] = [:]) {
        var o = detail; o["what"] = what; o["at"] = now
        appendLine("decisions.jsonl", o)
    }

    private func jevAsk(_ state: Any, _ q: [String: JevQuestion]) async -> JevReply? {
        let t = today()
        guard t.jev < duty.budget.jevCallsPerDay else { decision("jev-cap"); return nil }
        ledger(jev: 1)
        nonisolated(unsafe) let st = state
        return await d.jev.ask(state: st, questions: q, timeout: 8)
    }

    // MARK: pipeline

    /// One signal through the whole pipeline. Never throws; every stop is logged.
    func handle(_ s: WatcherSignal) async {
        guard enabled else { return }
        let t0 = now
        if let hit = Inbox.openItem(items, fingerprint: s.fingerprint, now: t0) {
            let sc = InjectionScreen.screen(s.evidence)
            emit(InboxEvent(.merged, id: hit.id, at: t0, evidence: Redact.secrets(sc.text),
                            note: sc.flagged ? "Contains instructions: not sent to the agent" : nil))
            decision("merged", ["item": hit.id]); return
        }
        if isMuted(s) { decision("muted", ["fp": s.fingerprint]); return }

        let screen = InjectionScreen.screen(s.evidence)
        let evidence = Redact.secrets(screen.text)
        if s.source == "git" { createCodeMade(s, evidence: evidence); return }

        let state: [String: Any] = ["source": s.source, "kind": s.kind, "facts": s.facts, "evidence": evidence]
        let reply = await jevAsk(state, WatcherQuestions.wakeQuestions)
        let wake = WatcherQuestions.decideWake(reply: reply, codeFact: s.codeFact, screenFlag: screen.flagged)
        appendLine("wake.jsonl", ["fp": s.fingerprint, "route": wake.route.rawValue, "worth": wake.worth ?? -1, "at": t0])
        if wake.route == .none { return }

        var item = makeItem(s, evidence: evidence)
        if wake.injection { item.note = "Contains instructions: not sent to the agent" }
        item.canInvestigate = wake.route != .none && !wake.injection && reply != nil && wake.worth != nil

        // dedupe against the repo's open items (≤ 8)
        let open = items.filter { $0.repo == s.repo && ($0.state == .open || $0.state == .approved) }.prefix(8)
        if !open.isEmpty {
            let st: [String: Any] = ["candidate": ["title": s.title, "evidence": String(evidence.prefix(600))],
                                      "open": open.map { ["title": $0.title, "evidence": String($0.evidence.prefix(600))] }]
            let r = await jevAsk(st, WatcherQuestions.dedupeQuestions(count: open.count))
            if let i = WatcherQuestions.bestMatch(reply: r, count: open.count) {
                let target = Array(open)[i]
                emit(InboxEvent(.merged, id: target.id, at: t0, evidence: evidence,
                                note: screen.flagged ? "Contains instructions: not sent to the agent" : nil))
                decision("deduped", ["into": target.id]); return
            }
        }
        emit(InboxEvent(.created, id: item.id, at: t0, item: item))
        channel.deliver(item: item)
        if wake.route == .investigate && item.canInvestigate { await investigate(item.id) }
    }

    private func makeItem(_ s: WatcherSignal, evidence: String) -> InboxItem {
        InboxItem(id: UUID().uuidString.prefix(8).lowercased().description, agent: Duty.watcherName, source: s.source, kind: s.kind,
                  subject: s.subject, repo: s.repo, fingerprint: s.fingerprint, title: s.title, evidence: evidence, report: nil,
                  level: nil, state: .open, seen: 1, at: now, cost: 0, note: nil, builderID: s.source == "builders" ? s.subject : nil,
                  lookedFixed: false, snoozeUntil: nil, canInvestigate: false)
    }

    /// Source 2 (git): code observed it, code writes the report. No Jev, no Claude.
    private func createCodeMade(_ s: WatcherSignal, evidence: String) {
        let item = makeItem(s, evidence: evidence)
        emit(InboxEvent(.created, id: item.id, at: now, item: item))
        let report = ItemReport(title: s.title, what: s.facts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"),
                                cause: "Commits were made here and never pushed.", sure: "high", evidence: [],
                                fix: .init(summary: "Review and push the branch when ready.", steps: ["Review the commits", "git push"],
                                           commands: ["git push"], files: []),
                                checked: ["git rev-list against the upstream"], unknowns: [])
        emit(InboxEvent(.reported, id: item.id, at: now, report: report, cost: 0))
        emit(InboxEvent(.levelled, id: item.id, at: now, level: PermissionGate.decide(text: report.fix.text, reply: nil).level))
        channel.deliver(item: items.first { $0.id == item.id } ?? item)
    }

    // MARK: investigation

    /// Everything in a report that could end up in an agent's brief, one string for the single deny-list entry point.
    static func denyText(_ r: ItemReport) -> String {
        ([r.title, r.what, r.cause] + r.evidence.flatMap { [$0.path, $0.lines, $0.quote] } + r.fix.commands + r.fix.steps + r.fix.files
            + [r.fix.summary, r.fix.text]).joined(separator: "\n")
    }

    /// Code, not the model, gathers the git facts (spec §3 step 4).
    /// Every `git` call goes through here: the process runs and is waited on off the main actor.
    private func git(_ argv: [String]) async -> String? {
        let g = d.git
        return await Task.detached(priority: .utility) { g(argv) }.value
    }

    private func gatherGitFacts(repo: String) async -> String {
        guard !repo.isEmpty else { return "" }
        let log = await git(["git", "-C", repo, "log", "--oneline", "-5"]) ?? ""
        let st = await git(["git", "-C", repo, "status", "--short", "-b"]) ?? ""
        return [log.isEmpty ? "" : "log:\n" + log, st.isEmpty ? "" : "status:\n" + st].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func investigate(_ id: String) async {
        guard enabled, let item = items.first(where: { $0.id == id }), item.canInvestigate, !running.contains(id) else { return }
        let t = today()
        let hhmm = { () -> String in let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: self.d.now()) }
        let resumeFrom = item.resumeSession
        let cap = min(duty.budget.perRunUSD, duty.budget.dailyUSD - t.usd)
        // A parked session is a continuation: dollars only, so the run and per-repo counts do not apply again.
        let overCount = resumeFrom == nil && (t.runs >= duty.budget.runsPerDay || (t.perRepo[item.repo] ?? 0) >= 3)
        if cap < 0.05 || overCount || !running.isEmpty {
            emit(InboxEvent(.reported, id: id, at: now, report: item.report, note: "Budget reached at \(hhmm())", resumeSession: resumeFrom))
            decision("budget-stop", ["item": id]); return
        }
        running.insert(id); defer { running.remove(id) }
        Investigation.prepare(paths: d.paths, duty: duty, memory: memory())
        let builderDir = items.first { $0.id == id }?.builderID.flatMap { bid in
            HubStoreBuilders.dir(bid) }
        let sig = WatcherSignal(source: item.source, kind: item.kind, subject: item.subject, repo: item.repo, facts: [:],
                                evidence: item.evidence, codeFact: false, title: item.title)
        let gitFacts = await gatherGitFacts(repo: item.repo)
        if !FileManager.default.fileExists(atPath: Investigation.hookPath) {
            burnHookMissing = true; decision("burn-hook-missing", ["item": id])
        } else { burnHookMissing = false }
        let firstPrompt = Investigation.prompt(signal: sig, evidence: item.evidence, gitFacts: gitFacts)

        // A cap is a checkpoint: resume the same session while there is daily budget and fewer than 4 continuations.
        var session = resumeFrom
        var continuations = 0
        var countRun = resumeFrom == nil     // the run is counted once, whichever way the chain ends
        var chainCost = 0.0
        func runsNow() -> Int { defer { countRun = false }; return countRun ? 1 : 0 }
        while true {
            let left = duty.budget.dailyUSD - today().usd
            let argv = Investigation.argv(paths: d.paths, maxBudgetUSD: min(duty.budget.perRunUSD, left), maxTurns: duty.budget.maxTurns,
                                          addDir: builderDir, resume: session)
            let (status, out) = await d.runner(argv, item.repo, session == nil ? firstPrompt : Investigation.continuePrompt, ["AGENT_BURN_MAIN": "1"])
            switch Investigation.parse(status: status, output: out) {
            case let .report(rep, cost, tokens):
                chainCost += cost
                ledger(usd: cost, runs: runsNow(), tokens: tokens, repo: item.repo)
                let clean = rep.mapped { Redact.secrets(InjectionScreen.strip($0)) }
                emit(InboxEvent(.reported, id: id, at: now, report: clean, cost: chainCost))
                let denyText = Self.denyText(clean)
                let reply = await jevAsk(PermissionGate.state(text: clean.fix.text, repo: item.repo, problem: clean.what), PermissionGate.questions)
                let pre = duty.preapproved.contains { $0.actionKind == item.kind && $0.repo == item.repo }
                let dec = PermissionGate.decide(text: clean.fix.text, denyText: denyText, reply: reply, ceiling: duty.ceiling, preapproved: pre)
                emit(InboxEvent(.levelled, id: id, at: now, level: dec.level))
                var answers: [String: Double] = [:]
                for (k, v) in reply?.answers ?? [:] { if let n = v.noul { answers[k] = n } }
                decision("level", ["item": id, "level": dec.level.rawValue, "why": dec.reasons, "answers": answers])
            case let .stopped(why, cost):
                // A context-size stop is not resumed: the same session would be just as full.
                ledger(usd: cost, runs: runsNow(), repo: item.repo)
                emit(InboxEvent(.reported, id: id, at: now, report: item.report, cost: chainCost + cost, note: why))
            case let .capped(reason, sid, cost, tokens):
                chainCost += cost
                ledger(usd: cost, runs: 0, tokens: tokens, repo: item.repo)
                session = sid
                let leftNow = duty.budget.dailyUSD - today().usd
                if leftNow >= 0.05 && continuations < 4 { continuations += 1; decision("continue", ["item": id, "why": reason, "n": continuations]); continue }
                if leftNow < 0.05 {
                    ledger(runs: runsNow(), repo: item.repo)
                    emit(InboxEvent(.reported, id: id, at: now, report: item.report, cost: chainCost,
                                    note: "Paused at the daily budget (\(hhmm())): Investigate continues where it stopped", resumeSession: sid))
                    decision("paused-budget", ["item": id])
                } else {
                    ledger(runs: runsNow(), repo: item.repo)
                    emit(InboxEvent(.reported, id: id, at: now, report: item.report, cost: chainCost,
                                    note: "\(reason); stopped after 4 continuations: Investigate continues where it stopped", resumeSession: sid))
                    decision("paused-continuations", ["item": id])
                }
            }
            break
        }
        if let it = items.first(where: { $0.id == id }) { channel.deliver(item: it) }
    }

    // MARK: approve / reject

    enum ApproveResult: Equatable { case started(String), handOff, refused(String) }

    func approve(_ id: String) async -> ApproveResult {
        guard let item = items.first(where: { $0.id == id }), let rep = item.report else { return .refused("Nothing to approve yet") }
        guard item.level == .askFirst else { return .handOff }
        guard item.state == .open else { return .refused("Already started") }
        guard approving.insert(id).inserted else { return .refused("Already starting") }
        defer { approving.remove(id) }
        // S1: the deny-list reads the EXACT brief that is written to fix.md (normalised), plus every report field.
        let brief = DenyList.normalize(rep.fix.text + "\n\nEvidence:\n"
            + rep.evidence.map { "\($0.path) \($0.lines): \($0.quote)" }.joined(separator: "\n")
            + "\n\nCommit on your branch only; do not push, deploy, send or delete; stop if the fix needs any of these.\n")
        let hits = (DenyList.hits(brief) + DenyList.hits(Self.denyText(rep))).filter { !$0.isEmpty }
        if !hits.isEmpty { decision("approve-refused", ["item": id, "hits": hits]); return .refused("Deny-list: \(Set(hits).sorted().joined(separator: ", "))") }
        let dir = home.appendingPathComponent("runs/\(id)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = dir.appendingPathComponent("fix.md")
        try? brief.write(to: f, atomically: true, encoding: .utf8)
        let argv = [d.builderBin, "start", "--name", "fix-\(id)", "--cwd", item.repo, "--model", "sonnet",
                    "--budget", String(format: "%.2f", duty.budget.fixUSD),
                    "--max-total", String(format: "%.2f", duty.budget.fixMaxUSD), "--worktree", "--prompt-file", f.path]
        let (code, out) = await d.spawn(argv)
        guard code == 0, let bid = BuilderSpawn.startedID(in: out) else { return .refused("Could not start the fix builder") }
        ledger(fix: duty.budget.fixUSD, repo: item.repo)
        emit(InboxEvent(.approved, id: id, at: now, cost: 0, builder: bid))
        decision("approved", ["item": id, "builder": bid])
        return .started(bid)
    }

    static let rejectReasons = ["Not a problem", "Already handled", "Wrong cause", "Not now"]

    func reject(_ id: String, reason: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let t = now
        switch reason {
        case "Not now":
            decision("rejected", ["item": id, "reason": reason])
            emit(InboxEvent(.snoozed, id: id, at: t, until: t + 24 * 3600)); return
        case "Already handled":
            emit(InboxEvent(.resolved, id: id, at: t, reason: reason))
        default:
            emit(InboxEvent(.rejected, id: id, at: t, reason: reason))
        }
        decision("rejected", ["item": id, "reason": reason])
        var lesson: [String: Any] = ["at": t, "reason": reason, "source": item.source, "kind": item.kind, "repo": item.repo, "title": item.title]
        if reason == "Not a problem" { lesson["muteUntil"] = t + 30 * 86400 }
        appendLine("lessons.jsonl", lesson)
        writeMemory()
    }

    private func isMuted(_ s: WatcherSignal) -> Bool {
        lessons().contains {
            ($0["source"] as? String) == s.source && ($0["kind"] as? String) == s.kind && ($0["repo"] as? String) == s.repo
                && (($0["muteUntil"] as? Double) ?? 0) > now
        }
    }

    // MARK: memory.md (≤ 60 lines, newest first, hand-editable Preferences)

    var hubChannel: HubChannel? { channel as? HubChannel }
    var memoryLessonCount: Int { lessons().count }

    func memory() -> String { (try? String(contentsOf: home.appendingPathComponent("memory.md"), encoding: .utf8)) ?? "" }

    func writeMemory() {
        let cur = memory()
        var prefs = "(Add things the Watcher should always know, one per line.)"
        if let a = cur.range(of: "## Preferences\n"), let b = cur.range(of: "\n## User told me") ?? cur.range(of: "\n## Lessons"), a.upperBound <= b.lowerBound {
            prefs = String(cur[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefLines = prefs.split(separator: "\n", omittingEmptySubsequences: false).prefix(20)
        let budget = max(0, 60 - 4 - prefLines.count)
        let lessons = readLines("lessons.jsonl").reversed().prefix(budget).map { l -> String in
            let r = (l["reason"] as? String) ?? "", t = (l["title"] as? String) ?? "", repo = ((l["repo"] as? String) ?? "") as NSString
            return "- \(r): \(t) (\(repo.lastPathComponent))"
        }
        let text = "# Watcher memory\n## Preferences\n" + prefLines.joined(separator: "\n") + "\n## User told me\n" + lessons.joined(separator: "\n") + "\n"
        try? text.write(to: home.appendingPathComponent("memory.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent("memory.md").path)
    }

    // MARK: events from the app

    /// Called on WorkAwake's existing tick and on builder changes: scan builders, handle new signals, run done checks.
    func checkStuck(builders given: [BuilderRecord]? = nil) {
        guard enabled, checkTask == nil else { return }       // a check is still running: skip this tick
        let builders = given ?? HubStore.shared.builders
        checkTask = Task { @MainActor in
            defer { self.checkTask = nil }
            await self.scan(builders: builders); await self.checkDone(builders: builders); await self.gitSweep(builders); self.digestIfDue()
        }
    }
    /// The check in flight (tests await it).
    private(set) var checkTask: Task<Void, Never>?

    func scan(builders: [BuilderRecord]) async {
        let handled = Set(items.map(\.fingerprint))
        let sigs = BuilderSignals.scan(builders, now: now, handled: handled, resultText: { b in
            b.dir.flatMap { try? String(contentsOfFile: $0 + "/result.md", encoding: .utf8) } })
        for s in sigs { await handle(s) }
    }

    /// Unpushed-work check, per repo at most every 10 minutes (events only, no timer). Only repos of builders
    /// started in the last 14 days and under the allowed roots.
    private var lastSweep: [String: Date] = [:]
    static let sweepGap: TimeInterval = 600
    func gitSweep(_ builders: [BuilderRecord]) async {
        let roots = SpawnRequest.allowedRoots()
        let cutoff = now - 14 * 86400
        let active = builders.filter { b in b.started >= cutoff && !b.originCwd.isEmpty
            && roots.contains { r in b.originCwd == r || b.originCwd.hasPrefix(r + "/") } }
        for repo in Set(active.map(\.originCwd)).sorted() {
            if let last = lastSweep[repo], d.now().timeIntervalSince(last) < Self.sweepGap { continue }
            lastSweep[repo] = d.now()
            await scanGit(repo: repo, builders: builders)
        }
    }

    func scanGit(repo: String, builders: [BuilderRecord]) async {
        let g = d.git, t = now
        let sigs = await Task.detached(priority: .utility) { GitSignals.check(repo: repo, builders: builders, now: t, run: g) }.value
        for s in sigs { await handle(s) }
    }

    func abandoned(pane: UUID, verdict: OverseerVerdict) {
        guard enabled, let s = AbandonedSignals.signal(pane: pane, verdict: verdict) else { return }
        Task { @MainActor in await self.handle(s) }
    }

    /// Quit snapshot of standing failures; replayed next launch.
    func snapshotPending(_ signals: [WatcherSignal]) {
        let u = home.appendingPathComponent("pending.jsonl")
        let text = signals.compactMap(AbandonedSignals.encode).joined(separator: "\n")
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }

    func replayPending() async {
        let u = home.appendingPathComponent("pending.jsonl")
        guard let s = try? String(contentsOf: u, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: u)
        for l in s.split(separator: "\n") { if let sig = AbandonedSignals.decode(String(l)) { await handle(sig) } }
    }

    // MARK: done check

    func checkDone(builders: [BuilderRecord]) async {
        for item in items where (item.state == .open || item.state == .approved) && !item.lookedFixed {
            if item.source == "git" {
                let parts = item.subject.split(separator: "@", maxSplits: 1).map(String.init)
                guard parts.count == 2, let up = GitSignals.parseBranches(await git(GitSignals.branchesArgv(repo: item.repo)) ?? "")
                        .first(where: { $0.branch == parts[1] })?.upstream else { continue }
                if GitSignals.parseAhead(await git(GitSignals.aheadArgv(repo: item.repo, upstream: up, branch: parts[1])) ?? "").isEmpty {
                    emit(InboxEvent(.resolved, id: item.id, at: now, reason: "Pushed")); decision("done-code", ["item": item.id])
                }
            } else if item.state == .approved, let bid = item.builderID, let fb = builders.first(where: { $0.id == bid }), fb.state == .done {
                emit(InboxEvent(.lookedFixed, id: item.id, at: now)); decision("done-code", ["item": item.id, "fixBuilder": bid])
            } else if item.source == "builders", let b = builders.first(where: { $0.id == item.subject }) {
                if b.acked { emit(InboxEvent(.resolved, id: item.id, at: now, reason: "Acknowledged")); continue }
                // Code decides the clear case: a later run of the same name in the same repo finished.
                if builders.contains(where: { $0.name == b.name && $0.originCwd == b.originCwd && $0.started > b.started && $0.state == .done }) {
                    emit(InboxEvent(.resolved, id: item.id, at: now, reason: "A later run finished")); decision("done-code", ["item": item.id])
                    continue
                }
                // Otherwise Jev looks at any later finished run in the same repo.
                guard let l = builders.first(where: { $0.originCwd == b.originCwd && $0.started > b.started && $0.state == .done }) else { continue }
                let st: [String: Any] = ["item": ["title": item.title, "evidence": String(item.evidence.prefix(600))],
                                         "later": ["name": l.name, "state": "done", "repo": l.originCwd]]
                let r = await jevAsk(st, WatcherQuestions.doneQuestions)
                if WatcherQuestions.looksFixed(reply: r) { emit(InboxEvent(.lookedFixed, id: item.id, at: now)) }
            }
        }
    }

    // MARK: digest

    func digestIfDue() {
        guard enabled else { return }
        let cal = Calendar.current
        guard cal.component(.hour, from: d.now()) >= duty.digest.notBefore else { return }
        let last = (readLines("state.jsonl").last?["lastDigest"] as? Double) ?? 0
        guard now - last >= Double(duty.digest.everyHours) * 3600 else { return }
        let open = needsYou.count
        let fixed = items.filter { $0.state == .resolved || $0.lookedFixed }.count
        let t = today()
        guard open > 0 || fixed > 0 || t.usd > 0 else { return }
        appendLine("state.jsonl", ["lastDigest": now])
        channel.deliver(digest: String(format: "%d open · %d fixed · $%.2f today", open, fixed, t.usd + t.fix))
    }
}

/// Builder dirs for `--add-dir` (read-only access to its stream and result).
enum HubStoreBuilders {
    @MainActor static func dir(_ id: String) -> String? { HubStore.shared.builders.first { $0.id == id }?.dir }
}
