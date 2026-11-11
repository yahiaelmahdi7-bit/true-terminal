import Testing
import Foundation
@testable import True

// The M1 scripted drill: a frozen log of real peer jobs replayed through two real in-process PeerEngines with fault
// injection. It MEASURES (never bends to pass). Gated on TRUE_DRILL=1; fixture from TRUE_DRILL_FIXTURE
// (default ~/.foundry/heldout/peers/m1.json, outside the repo, never copied or printed beyond job ids).
// The drill owns its fakes (launcher, timers, side) so a later edit to the shared fakes cannot move its injection points.
// Assumptions: a null fixture target is a repo job on its project. Cards are sent at pairing (as on connect) and never
// re-announced by the drill: a Card older than PeerCaps.staleAfter can't refuse "no clone", and the drill counts that.

// MARK: fixture

private struct DrillFixture: Decodable {
    struct Job: Decodable {
        let id: String
        let t: Double
        let dur: Double
        let mode: String
        let from: String?
        let project: String
        let peer: String?
        let onBranch: Bool
        let target: String?
        let outcome: String
        let cause: String?
    }
    let jobs: [Job]
}

private enum DrillPlan: String { case clean, kill, limit, error, stop, removed, noClone, fetchFailed, pathNotAllowed }

// MARK: fakes (all in this file)

/// A fake scheduler: engines hand it (delay, closure); the drill fires them as the fake clock reaches them.
private final class DrillTimers: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(at: Date, f: @Sendable () -> Void)] = []
    let clock: Clock
    init(clock: Clock) { self.clock = clock }
    func schedule(_ delay: TimeInterval, _ f: @escaping @Sendable () -> Void) {
        lock.lock(); items.append((clock.now().addingTimeInterval(delay), f)); lock.unlock()
    }
    func next() -> Date? { lock.lock(); defer { lock.unlock() }; return items.map(\.at).min() }
    @discardableResult func fireDue() -> Bool {
        lock.lock()
        let now = clock.now()
        let due = items.filter { $0.at <= now }
        items.removeAll { $0.at <= now }
        lock.unlock()
        for d in due { d.f() }
        return !due.isEmpty
    }
}

private final class DrillLauncher: PeerLauncher, @unchecked Sendable {
    struct Launch { var agent: String; var prompt: String; var resume: String?; var pane: UUID? }
    private let lock = NSLock()
    private var counter = 0
    private let tag: String
    private var _clones: [String: String] = [:]
    private var _failNextPrepare = 0
    private var _launches: [Launch] = []
    private var _sessions: [UUID: String] = [:]
    private var _builderSessions: [String: String] = [:]
    private var _dead: Set<UUID> = []
    var canRunBackground: Bool { true }
    var canResumeBackground: Bool { true }
    init(tag: String) { self.tag = tag }

    func setClones(_ c: [String: String]) { lock.lock(); _clones = c; lock.unlock() }
    var failNextPrepare: Int { get { lock.lock(); defer { lock.unlock() }; return _failNextPrepare } set { lock.lock(); _failNextPrepare = newValue; lock.unlock() } }
    var launches: [Launch] { lock.lock(); defer { lock.unlock() }; return _launches }
    func kill(pane: UUID) { lock.lock(); _dead.insert(pane); lock.unlock() }
    func builderSession(_ name: String) -> String? { lock.lock(); defer { lock.unlock() }; return _builderSessions[name] }
    func session(pane: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return _sessions[pane] }
    private func fresh() -> String { counter += 1; return "sess-\(tag)-\(counter)" }

    func resolveClone(repo: String) -> String? { lock.lock(); defer { lock.unlock() }; return _clones.first { PeerRepo.same($0.key, repo) }?.value }
    func cloneRemotes() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(_clones.keys) }
    func prepareWorktree(clone: String, base: String, branch: String, worktree: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if _failNextPrepare > 0 { _failNextPrepare -= 1; return "Couldn't fetch the repo" }
        return nil
    }
    func launchPane(agentName: String, label: String, cwd: String, flags: [String], rolePath: String, firstPrompt: String) -> UUID? {
        launchPane(agentName: agentName, label: label, cwd: cwd, flags: flags, rolePath: rolePath, firstPrompt: firstPrompt, resumeSession: nil)
    }
    func launchPane(agentName: String, label: String, cwd: String, flags: [String], rolePath: String, firstPrompt: String, resumeSession: String?) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        let p = UUID()
        _sessions[p] = resumeSession ?? fresh()
        _launches.append(Launch(agent: agentName, prompt: firstPrompt, resume: resumeSession, pane: p))
        return p
    }
    func launchBackground(agentName: String, parent: String, cwd: String, prompt: String) -> String? {
        launchBackground(agentName: agentName, parent: parent, cwd: cwd, prompt: prompt, resumeSession: nil)
    }
    func launchBackground(agentName: String, parent: String, cwd: String, prompt: String, resumeSession: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        _builderSessions[agentName] = resumeSession ?? fresh()
        _launches.append(Launch(agent: agentName, prompt: prompt, resume: resumeSession, pane: nil))
        return nil
    }
    func sessionId(forPane pane: UUID) -> String? { session(pane: pane) }
    func headSHA(worktree: String) -> String? { "abc1234" }
    func remoteURL(ofRepoAt path: String) -> String? { nil }
    func deliverLine(agent: String, line: String) {}
    func stop(panes: [UUID], builders: [String]) { lock.lock(); _dead.formUnion(panes); lock.unlock() }
    func deliverToPane(_ pane: UUID, line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_dead.contains(pane) else { return false }
        _launches.append(Launch(agent: "deliver", prompt: line, resume: nil, pane: pane))
        return true
    }
    func atPermissionPrompt(pane: UUID) -> Bool { false }
    func cloneRepo(url: String, into path: String) -> String? { "Cloning isn't available here" }
    func paneAlive(_ pane: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return !_dead.contains(pane) }
    func installedTools() -> [String: Bool] { [:] }
}

private final class DrillKnobs: @unchecked Sendable {
    private let lock = NSLock()
    private var d: [String]
    init(_ d: [String]) { self.d = d }
    var dirs: [String] { get { lock.lock(); defer { lock.unlock() }; return d } set { lock.lock(); d = newValue; lock.unlock() } }
}

private final class DrillSide: @unchecked Sendable {
    let root: URL, identity: PeerIdentity, launcher: DrillLauncher, transport: RelayTestTransport, engine: PeerEngine, knobs: DrillKnobs
    init(_ name: String, tag: String, relay: FakeRelay, clock: Clock, timers: DrillTimers, dirs: [String], mode: PeerInboundMode) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("true-drill-\(UUID().uuidString)")
        identity = PeerIdentity.generate()
        launcher = DrillLauncher(tag: tag)
        transport = relay.transport(for: identity.mailboxId)
        let k = DrillKnobs(dirs); knobs = k
        engine = PeerEngine(root: root, identity: identity, launcher: launcher, transport: transport, inboundMode: { mode },
                            ownName: name, steering: { true }, share: { .activity }, allowedDirs: { k.dirs }, chatOn: { false },
                            sharedRepos: { [:] }, setSharedRepos: { _ in }, desk: { true }, lanes: { 2 }, projectsRoot: root.path + "/Projects",
                            now: { clock.now() }, scheduler: { d, f in timers.schedule(d, f) })
    }
    func builderDir(_ name: String) -> String { root.appendingPathComponent("builders/\(name)").path }
}

/// Counts the job messages each receiver gets, per jobId (a re-send would count twice; resume requests are another kind).
private final class DrillCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String: PeerIdentity] = [:]
    private var counts: [String: Int] = [:]
    func watch(_ s: DrillSide) { lock.lock(); ids[s.identity.mailboxId] = s.identity; lock.unlock() }
    func count(_ jobId: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[jobId] ?? 0 }
    func see(to: String, blob: Data, sender: PeerKeys, now: Date) {
        lock.lock(); let me = ids[to]; lock.unlock()
        guard let me, case .success(let o) = PeerSeal.open(blob, me: me, now: now, pinned: { _ in sender }),
              let obj = try? JSONSerialization.jsonObject(with: o.payload) as? [String: Any],
              obj["t"] as? String == "job", let id = obj["jobId"] as? String else { return }
        lock.lock(); counts[id, default: 0] += 1; lock.unlock()
    }
}

// MARK: one simulated job

private enum DrillAct { case send, finish, stop, fault, remove, fix }

private final class JobSim {
    let fx: DrillFixture.Job, idx: Int, plan: DrillPlan
    let sendAt: Date, plannedEnd: Date, deadline: Date, runSeconds: TimeInterval
    var recv: DrillSide
    var label = "Bea"
    var jobId: String?
    var actions: [(at: Date, act: DrillAct)] = []
    var activations = 0
    var activatedBuilder: String?, activatedPane: UUID?
    var startAt: Date?
    var firstSession: String?
    var fixScheduled = false
    var closed = false
    var cls = "", status = "", reason = ""
    var refused: String?
    var stopsShownAsFailed = false
    var stopFailure: String?
    init(fx: DrillFixture.Job, idx: Int, plan: DrillPlan, t0: Date, recv: DrillSide) {
        self.fx = fx; self.idx = idx; self.plan = plan; self.recv = recv
        runSeconds = min(fx.dur, 1800)
        sendAt = t0.addingTimeInterval(fx.t)
        plannedEnd = sendAt.addingTimeInterval(runSeconds)
        deadline = sendAt.addingTimeInterval(fx.dur + 7200)
    }
    var isBackground: Bool { fx.mode == "background" }
    var isDir: Bool { plan == .pathNotAllowed || fx.target == "dir" }
}

// MARK: the world

private final class DrillWorld {
    let clock = Clock(), relay = FakeRelay(), counter = DrillCounter()
    let timers: DrillTimers
    let a: DrillSide, b: DrillSide
    var ghosts: [DrillSide] = []
    let tmp: URL, t0: Date
    let projects = ["p1", "p2", "p3", "p4"]
    init() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("true-drill-dirs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("allowed"), withIntermediateDirectories: true)
        t0 = clock.now()
        timers = DrillTimers(clock: clock)
        a = DrillSide("Al", tag: "A", relay: relay, clock: clock, timers: timers, dirs: [], mode: .bypass)
        b = DrillSide("Bo", tag: "B", relay: relay, clock: clock, timers: timers, dirs: [tmp.appendingPathComponent("allowed").path], mode: .bypass)
        var clones: [String: String] = [:]
        for p in projects { clones[Self.url(p)] = b.root.appendingPathComponent("clones/\(p)").path }
        b.launcher.setClones(clones)
        counter.watch(b)
        let c = counter, ak = a.identity.keys, ck = clock
        relay.rewrite = { to, blob in c.see(to: to, blob: blob, sender: ak, now: ck.now()); return (to, blob) }
        pair(b, label: "Bea")
    }
    static func url(_ project: String) -> String { "https://github.com/acme/\(project).git" }
    var sides: [DrillSide] { [a, b] + ghosts }
    func settle() { for _ in 0..<5 { for s in sides { s.engine.drain() } } }
    func pair(_ s: DrillSide, label: String) {
        _ = a.engine.pairWithInvite(s.engine.invite(), label: label)
        settle()
        a.engine.sendCapsToAll(); s.engine.sendCapsToAll()
        settle()
    }
    func addGhost() -> DrillSide {
        let g = DrillSide("Gus", tag: "G\(ghosts.count)", relay: relay, clock: clock, timers: timers, dirs: [], mode: .bypass)
        var clones: [String: String] = [:]
        for p in projects { clones[Self.url(p)] = g.root.appendingPathComponent("clones/\(p)").path }
        g.launcher.setClones(clones)
        counter.watch(g)
        ghosts.append(g)
        pair(g, label: "Gus")
        return g
    }
    func close() {
        for s in sides { try? FileManager.default.removeItem(at: s.root) }
        try? FileManager.default.removeItem(at: tmp)
    }
}

private func waitUntil(real: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(real)
    while !cond() { if Date() > end { return false }; Thread.sleep(forTimeInterval: 0.002) }
    return true
}

private func appendLine(_ path: String, _ line: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: url) {
        _ = try? h.seekToEnd(); try? h.write(contentsOf: Data((line + "\n").utf8)); try? h.close()
    } else {
        try? Data((line + "\n").utf8).write(to: url)
    }
}

private func limitText(now: Date) -> String {
    let reset = Date(timeIntervalSince1970: ceil((now.timeIntervalSince1970 + 3600) / 60) * 60)
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "h:mm a"
    return "Claude usage limit reached. Your limit resets at \(f.string(from: reset))"
}

// MARK: a replay

private struct DrillJobResult {
    var id: String, cause: String, injected: String, cls: String, status: String, reason: String
    var startDelay: Double?, resumes: Int, sameSession: Bool?, jobMessages: Int
    var plan: DrillPlan, resumeCase: Bool, sent: Bool
}

private struct DrillCriterion { var name: String; var pass: Bool; var detail: String }

private struct DrillRun {
    var jobs: [DrillJobResult] = []
    var landed = 0, refused = 0, stopped = 0, failed = 0, stopsShownAsFailed = 0
    var criteria: [DrillCriterion] = []
    var waitBeforeStop: [(id: String, seconds: Double, started: Bool)] = []
    var notInjectable: [(id: String, why: String)] = []
    var classes: [String] { jobs.map { "\($0.id)=\($0.cls)" } }
}

private final class DrillReplay {
    let w = DrillWorld()
    var sims: [JobSim] = []
    var notInjectable: [(id: String, why: String)] = []
    var iterations = 0

    init(fixture: DrillFixture) {
        var landedIdx = 0
        for (i, fx) in fixture.jobs.enumerated() {
            var plan = DrillPlan.clean
            switch fx.cause {
            case "stop": plan = .stop
            case "peer-removed": plan = .removed
            case "no-clone": plan = .noClone
            case "fetch-failed": plan = .fetchFailed
            case "path-not-allowed": plan = .pathNotAllowed
            case "error": plan = .error
            default:
                if fx.outcome == "landed" {
                    plan = landedIdx % 3 == 0 ? .kill : landedIdx % 3 == 1 ? .limit : .clean
                    landedIdx += 1
                }
            }
            let recv = plan == .removed ? w.addGhost() : w.b
            let s = JobSim(fx: fx, idx: i, plan: plan, t0: w.t0, recv: recv)
            if plan == .removed { s.label = "Gus" }
            s.actions.append((s.sendAt, .send))
            if plan == .stop { s.actions.append((s.plannedEnd, .stop)) }
            if plan == .removed { s.actions.append((s.sendAt.addingTimeInterval(max(60, s.runSeconds / 2)), .remove)) }
            sims.append(s)
        }
    }

    // MARK: engine access

    func rec(_ s: JobSim) -> InboundJob? { s.jobId.flatMap { id in s.recv.engine.inboundJobs().first { $0.id == id } } }
    func sentRec(_ s: JobSim) -> SentJob? { s.jobId.flatMap { w.a.engine.status(jobId: $0).first } }

    // MARK: actions

    func perform(_ s: JobSim, _ act: DrillAct) {
        let now = w.clock.now()
        switch act {
        case .send:
            if s.plan == .fetchFailed { s.recv.launcher.failNextPrepare = 1 }
            let isDir = s.isDir
            var repo = "", dir = ""
            if isDir {
                if s.plan == .pathNotAllowed { dir = w.tmp.appendingPathComponent("outside/\(s.fx.id)").path }
                else { dir = w.tmp.appendingPathComponent("allowed/\(s.fx.project)").path }
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } else {
                repo = s.plan == .noClone ? "https://github.com/acme/\(s.fx.project)-fork-\(s.fx.id).git" : DrillWorld.url(s.fx.project)
            }
            let r = w.a.engine.delegate(peer: s.label, repo: repo, title: s.fx.id, brief: "Drill job \(s.fx.id)",
                                        base: s.fx.onBranch ? "feature-\(s.fx.id)" : "main", mode: s.isBackground ? .background : .pane,
                                        fromAgent: s.fx.from ?? "agent", dir: dir)
            switch r {
            case .success(let id): s.jobId = id
            case .failure(let e):
                if case .invalid(let m) = e { s.refused = m } else { s.refused = "\(e)" }
                s.cls = "refused"; s.status = "refused"; s.reason = s.refused ?? ""; s.closed = true
            }
        case .finish:
            guard let j = rec(s), !j.status.isFinal, let id = s.jobId else { return }
            try? Data("Drill result".utf8).write(to: URL(fileURLWithPath: s.recv.engine.resultPath(id)))
            if let b = j.builder, j.pane == nil { s.recv.engine.builderUpdate(name: b, running: false, dir: s.recv.builderDir(b)) }
            else if let p = j.pane { s.recv.engine.paneEvent(pane: p, kind: .stop) }
        case .stop:
            if case .failure(let e) = w.a.engine.stopJob(jobId: s.jobId ?? "") { s.stopFailure = "\(e)" }
        case .remove:
            w.a.engine.revoke(label: s.label)
        case .fix:
            if s.plan == .pathNotAllowed { s.recv.knobs.dirs = s.recv.knobs.dirs + [w.tmp.appendingPathComponent("outside").path] }
            if let id = s.jobId { _ = w.a.engine.resumeJob(jobId: id) }
        case .fault:
            guard let j = rec(s), !j.status.isFinal else { return }
            let limit = limitText(now: now)
            if let b = j.builder, j.pane == nil {
                let stream = s.recv.builderDir(b) + "/stream.jsonl"
                switch s.plan {
                case .limit: appendLine(stream, #"{"type":"result","is_error":true,"result":"\#(limit)"}"#)
                case .error: appendLine(stream, #"{"type":"result","is_error":true,"result":"Claude exited with an error"}"#)
                default: break                                                    // kill: dies with no result line
                }
                s.recv.engine.builderUpdate(name: b, running: false, dir: s.recv.builderDir(b))
            } else if let p = j.pane {
                switch s.plan {
                case .kill: s.recv.launcher.kill(pane: p); s.recv.engine.recoverInterrupted()
                case .limit: s.recv.engine.paneEvent(pane: p, kind: .error, message: limit)
                default: s.recv.engine.paneEvent(pane: p, kind: .error, message: "Claude exited with an error")
                }
            }
        }
    }

    /// The receiver launched (or relaunched) something: do what the real builder / pane would do, then arm the next scripted action.
    func activate(_ s: JobSim, _ j: InboundJob) {
        let now = w.clock.now()
        if let b = j.builder, j.pane == nil {
            let session = s.recv.launcher.builderSession(b) ?? "sess-orphan-\(b)"
            appendLine(s.recv.builderDir(b) + "/stream.jsonl", #"{"type":"system","subtype":"init","session_id":"\#(session)"}"#)
            s.recv.engine.builderUpdate(name: b, running: true, dir: s.recv.builderDir(b))
            s.activatedBuilder = b
            if s.firstSession == nil {
                _ = waitUntil { rec(s)?.sessionId != nil }
                s.firstSession = rec(s)?.sessionId
            }
        } else if let p = j.pane {
            s.recv.engine.paneEvent(pane: p, kind: .progress)
            s.activatedPane = p
            if s.firstSession == nil { s.firstSession = rec(s)?.sessionId ?? s.recv.launcher.session(pane: p) }
        }
        s.activations += 1
        if s.startAt == nil { s.startAt = now }
        switch s.plan {
        case .clean: s.actions.append((max(s.plannedEnd, now.addingTimeInterval(1)), .finish))
        case .kill, .limit, .error:
            if s.activations == 1 { s.actions.append((now.addingTimeInterval(max(60, s.runSeconds / 2)), .fault)) }
            else { s.actions.append((max(s.plannedEnd, now.addingTimeInterval(60)), .finish)) }
        case .fetchFailed, .pathNotAllowed: s.actions.append((max(s.plannedEnd, now.addingTimeInterval(60)), .finish))
        case .stop, .removed, .noClone: break
        }
    }

    /// Read engine state after a settle: close finished jobs, activate launches, notice needsYou. True when something changed.
    func observe() -> Bool {
        var changed = false
        for s in sims where !s.closed && s.jobId != nil {
            guard let st = sentRec(s) else { continue }
            if st.status.isFinal { close(s); changed = true; continue }
            guard let j = rec(s), !j.status.isFinal else { continue }
            if st.status == .needsYou, (s.plan == .fetchFailed || s.plan == .pathNotAllowed), !s.fixScheduled {
                s.fixScheduled = true
                s.actions.append((w.clock.now().addingTimeInterval(30), .fix)); changed = true
            }
            guard j.worktree != nil else { continue }
            if let b = j.builder, j.pane == nil, b != s.activatedBuilder { activate(s, j); changed = true }
            else if j.builder == nil || j.pane != nil, let p = j.pane, p != s.activatedPane { activate(s, j); changed = true }
        }
        return changed
    }

    func close(_ s: JobSim) {
        guard !s.closed else { return }
        s.closed = true
        guard let st = sentRec(s) else { s.cls = "failed"; s.status = "none"; s.reason = "no sender record"; return }
        s.status = st.status.rawValue; s.reason = st.note
        switch st.status {
        case .done: s.cls = "landed"
        case .canceled: s.cls = "stopped"
        case .failed where st.note.hasPrefix("Stopped by sender"): s.cls = "stopped"; s.stopsShownAsFailed = true
        default: s.cls = "failed"
        }
    }

    // MARK: the loop

    func run() {
        while sims.contains(where: { !$0.closed }) {
            iterations += 1
            if iterations > 200_000 { for s in sims where !s.closed { close(s) }; return }
            let open = sims.filter { !$0.closed }
            var next = open.map(\.deadline).min()!
            for s in open { if let a = s.actions.map(\.at).min() { next = min(next, a) } }
            if let t = w.timers.next() { next = min(next, t) }
            if next > w.clock.now() { w.clock.t = next }
            w.timers.fireDue()
            for s in open {
                let now = w.clock.now()
                let due = s.actions.filter { $0.at <= now }.sorted { $0.at < $1.at }
                s.actions.removeAll { $0.at <= now }
                for d in due where !s.closed { perform(s, d.act); w.settle(); if s.plan == .fetchFailed { s.recv.launcher.failNextPrepare = 0 } }
            }
            w.settle()
            var rounds = 0
            while observe(), rounds < 8 { w.settle(); rounds += 1 }
            let now = w.clock.now()
            for s in sims where !s.closed && now >= s.deadline { close(s) }
        }
    }

    // MARK: numbers

    func result() -> DrillRun {
        var run = DrillRun()
        let allLaunches = (w.sides.flatMap { $0.launcher.launches })
        for s in sims {
            let sent = s.jobId != nil
            let r = rec(s)
            let short = s.jobId.map { PeerNaming.shortId($0) } ?? "-"
            let resumeArgs = allLaunches.filter { l in
                guard let sid = l.resume, !sid.isEmpty else { return false }
                return l.agent.contains(short) || (s.jobId.map { l.prompt.contains($0) } ?? false)
            }.compactMap(\.resume)
            let resumes = r?.resumes ?? 0
            let same: Bool? = resumes > 0 ? (s.firstSession != nil && r?.sessionId == s.firstSession && resumeArgs.allSatisfy { $0 == s.firstSession }) : nil
            let delay = s.startAt.map { $0.timeIntervalSince(s.sendAt) }
            let jr = DrillJobResult(id: s.fx.id, cause: s.fx.cause ?? "none", injected: s.plan.rawValue, cls: s.cls, status: s.status, reason: s.reason,
                                    startDelay: delay, resumes: resumes, sameSession: same, jobMessages: s.jobId.map { w.counter.count($0) } ?? 0,
                                    plan: s.plan, resumeCase: [.kill, .limit, .error].contains(s.plan) && sent, sent: sent)
            run.jobs.append(jr)
            switch s.cls {
            case "landed": run.landed += 1
            case "refused": run.refused += 1
            case "stopped": run.stopped += 1
            default: run.failed += 1
            }
            if s.stopsShownAsFailed { run.stopsShownAsFailed += 1 }
            if s.plan == .stop { run.waitBeforeStop.append((s.fx.id, (s.startAt ?? s.plannedEnd).timeIntervalSince(s.sendAt), s.startAt != nil)) }
        }
        run.notInjectable = notInjectable

        // 1. failure rate
        let den = run.landed + run.failed + run.refused
        run.criteria.append(DrillCriterion(name: "1 failure-rate", pass: run.failed * 26 <= den, detail: "failed=\(run.failed) of \(den); bar <= 1/26"))
        // 2. resumes on the same session, zero re-sends
        let badResume = run.jobs.filter { $0.resumeCase && !($0.resumes >= 1 && $0.sameSession == true) }.map(\.id)
        let badSends = run.jobs.filter { $0.sent && $0.jobMessages != 1 }.map { "\($0.id)x\($0.jobMessages)" }
        run.criteria.append(DrillCriterion(name: "2 resume-same-session-no-resend", pass: badResume.isEmpty && badSends.isEmpty,
                                           detail: "notResumedOnSameSession=\(badResume) jobMessagesNotOne=\(badSends)"))
        // 3. refused reasons are plain
        var badReasons: [String] = []
        for j in run.jobs where j.cls == "refused" { if let why = Self.reasonProblem(j.reason) { badReasons.append("\(j.id): \(why)") } }
        run.criteria.append(DrillCriterion(name: "3 refused-reasons-plain", pass: badReasons.isEmpty, detail: "refused=\(run.refused) problems=\(badReasons)"))
        // 4. M1.4 lanes: independent overlapping jobs on one project start within 30 s
        var lateStarts: [String] = [], pairs = 0
        let eligible = sims.filter { $0.jobId != nil }.sorted { $0.sendAt < $1.sendAt }
        for (i, early) in eligible.enumerated() {
            for later in eligible[(i + 1)...] where later.fx.project == early.fx.project && later.sendAt < early.plannedEnd {
                let independent = early.fx.onBranch || later.fx.onBranch || (early.isBackground && later.isBackground)
                guard independent, later.plan != .fetchFailed, later.plan != .pathNotAllowed else { continue }
                pairs += 1
                let d = later.startAt.map { $0.timeIntervalSince(later.sendAt) }
                if d == nil || d! > 30 { lateStarts.append("\(later.fx.id)(after \(early.fx.id)): \(d.map { String(Int($0)) + "s" } ?? "never started")") }
            }
        }
        run.criteria.append(DrillCriterion(name: "4 m1.4-start-within-30s", pass: lateStarts.isEmpty, detail: "pairs=\(pairs) late=\(lateStarts)"))
        return run
    }

    static func reasonProblem(_ r: String) -> String? {
        let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "empty" }
        if t.count > 140 { return "over 140 chars" }
        for bad in ["Error Domain", "NSError", "(null)"] where t.contains(bad) { return "raw engine text: \(bad)" }
        let patterns = [#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
                        #"\b(?=[0-9a-f]*\d)[0-9a-f]{7,}\b"#, #"\w+\.(swift|m|mm|py|js|ts|c|cpp|h|rs):\d+"#]
        for p in patterns where t.range(of: p, options: .regularExpression) != nil { return "raw id / file:line" }
        return nil
    }
}

// MARK: the suite

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TRUE_DRILL"] == "1"))
struct PeersDrillM1Tests {
    static func fixtureURL() -> URL {
        if let p = ProcessInfo.processInfo.environment["TRUE_DRILL_FIXTURE"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.foundry/heldout/peers/m1.json")
    }
    static func reportURL(file: String = #filePath) -> URL {
        if let p = ProcessInfo.processInfo.environment["TRUE_DRILL_REPORT"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let repo = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent(".out/drill/m1-report.json")
    }

    @Test func m1Drill() throws {
        guard let data = try? Data(contentsOf: Self.fixtureURL()), let all = try? JSONDecoder().decode(DrillFixture.self, from: data) else {
            Issue.record("TRUE_DRILL=1 but the fixture is missing or unreadable at \(Self.fixtureURL().path)")
            return
        }
        let fixture = DrillFixture(jobs: all.jobs.filter { $0.outcome != "in-flight" }.sorted { $0.t < $1.t })
        var runs: [DrillRun] = []
        for k in 1...3 {
            let rp = DrillReplay(fixture: fixture)
            rp.run()
            var run = rp.result()
            rp.w.close()
            if let first = runs.first {
                let same = first.classes == run.classes
                let diff = zip(first.classes, run.classes).filter { $0 != $1 }.map { "\($0) vs \($1)" }
                run.criteria.append(DrillCriterion(name: "5 determinism", pass: same, detail: same ? "identical to run 1" : "differs from run 1: \(diff)"))
            } else {
                run.criteria.append(DrillCriterion(name: "5 determinism", pass: true, detail: "run 1 is the reference"))
            }
            runs.append(run)
            let bad = run.criteria.filter { !$0.pass }.map(\.name)
            print("DRILL M1 run=\(k) landed=\(run.landed) refused=\(run.refused) stopped=\(run.stopped) failed=\(run.failed) rate=\(run.failed)/\(run.landed + run.failed + run.refused) \(bad.isEmpty ? "PASS" : "FAIL \(bad)")")
            for j in run.jobs where j.cls == "failed" { print("DRILL M1 run=\(k) failed-job \(j.id) injected=\(j.injected) status=\(j.status)") }
        }
        Self.write(runs, to: Self.reportURL())
        for (i, run) in runs.enumerated() {
            for c in run.criteria { #expect(c.pass, "run \(i + 1) criterion \(c.name): \(c.detail)") }
        }
    }

    fileprivate static func write(_ runs: [DrillRun], to url: URL) {
        func num(_ d: Double?) -> Any { d.map { Double(Int($0 * 10)) / 10 } ?? NSNull() }
        let out: [[String: Any]] = runs.enumerated().map { i, run in
            ["run": i + 1,
             "jobs": run.jobs.map { j -> [String: Any] in
                ["id": j.id, "cause": j.cause, "injected": j.injected, "class": j.cls, "status": j.status, "reason": j.reason,
                 "startDelay": num(j.startDelay), "resumes": j.resumes, "sameSession": j.sameSession.map { $0 as Any } ?? NSNull(), "jobMessages": j.jobMessages]
             },
             "totals": ["landed": run.landed, "refused": run.refused, "stopped": run.stopped, "failed": run.failed,
                        "rate": "\(run.failed)/\(run.landed + run.failed + run.refused)", "stopsShownAsFailed": run.stopsShownAsFailed],
             "criteria": run.criteria.map { ["name": $0.name, "pass": $0.pass, "detail": $0.detail] },
             "waitBeforeStop": run.waitBeforeStop.map { ["id": $0.id, "seconds": num($0.seconds), "started": $0.started] },
             "notInjectable": run.notInjectable.map { ["id": $0.id, "why": $0.why] }]
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: ["runs": out], options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
    }
}
