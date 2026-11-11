import Foundation

/// Run 33 — Ask desk. One seat per Mac, `@oracle`, whose delivery is a closure: every line addressed to it is a question,
/// answered from the owner's second brain (never from a Claude pane) and sent back as a direct line with `re` = the question id.

struct BrainAnswer: Equatable, Sendable { var answer: String; var sources: [String] }

/// What one ask came back as. `down` = nothing answered at all, `busy` = it is there but did not finish in time,
/// `failed` = it answered with an error (never forwarded as an answer).
enum BrainReply: Equatable, Sendable { case down, busy, failed(String), answer(BrainAnswer) }

/// A fresh `GET /api/status`: project scopes plus the brain's own ask budget (seconds), when it reports one.
struct BrainStatus: Equatable, Sendable { var scopes: [String: String]; var askBudget: TimeInterval? }

protocol BrainTransport: Sendable {
    /// `timeout` = how long this ask may take (the brain's reported budget).
    func ask(question: String, projects: [String], timeout: TimeInterval) async -> BrainReply
    /// Liveness: a fresh status call (5 s), never cached. nil = unreachable.
    func status() async -> BrainStatus?
    /// Start the brain's launchd job if it has no process (never `kickstart -k`). Default: nothing.
    func wakeIfDown() async
}

extension BrainTransport { func wakeIfDown() async {} }

/// The ONE place that decides whether a brain reply is a failure. Uses the brain's typed `ok`/`reason` when present,
/// else the known failure strings (older brains).
enum BrainFailure {
    static let busyStrings = ["The local model is busy", "The local model timed out"]
    static let failStrings = ["The local model ran out of room", "I encountered an error generating"]

    static func classify(ok: Bool?, reason: String?, answer: String) -> BrainReply? {
        if let ok {
            if ok { return nil }
            return (reason == "busy" || reason == "timeout") ? .busy : .failed(reason ?? "error")
        }
        if busyStrings.contains(where: { answer.hasPrefix($0) }) { return .busy }
        if failStrings.contains(where: { answer.hasPrefix($0) }) || answer.hasPrefix("Error: ") { return .failed("error") }
        return nil
    }
}

/// The live brain: `http://127.0.0.1:8800`.
struct BrainHTTP: BrainTransport {
    var base = URL(string: "http://127.0.0.1:8800")!
    static let defaultAskBudget: TimeInterval = 180

    private func session(_ timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout
        return URLSession(configuration: c)
    }

    func ask(question: String, projects: [String], timeout: TimeInterval) async -> BrainReply {
        var req = URLRequest(url: base.appendingPathComponent("api/ask"), timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["question": question, "project_ids": projects, "caller": "oracle"])
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session(timeout).data(for: req) }
        catch let e as URLError { return e.code == .timedOut ? .busy : .down }
        catch { return .down }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let a = o["answer"] as? String else { return .failed("http") }
        if let f = BrainFailure.classify(ok: o["ok"] as? Bool, reason: o["reason"] as? String, answer: a) { return f }
        return .answer(BrainAnswer(answer: a, sources: (o["sources"] as? [String]) ?? []))
    }

    /// `launchctl print` shows a pid when the job is running; only a job with none gets a plain `kickstart`.
    func wakeIfDown() async {
        func launchctl(_ args: [String]) -> String? {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
            p.standardOutput = out; p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        }
        let target = "gui/\(getuid())/com.secondbrain.server"
        guard let info = launchctl(["print", target]), info.range(of: #"\bpid = \d+"#, options: .regularExpression) == nil else { return }
        _ = launchctl(["kickstart", target])
    }

    func status() async -> BrainStatus? {
        var req = URLRequest(url: base.appendingPathComponent("api/status"), timeoutInterval: 5)
        req.httpMethod = "GET"
        guard let (data, resp) = try? await session(5).data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ps = o["projects"] as? [[String: Any]] else { return nil }
        var out: [String: String] = [:]
        for p in ps { if let id = p["project_id"] as? String, let s = p["scope"] as? String { out[id.lowercased()] = s } }
        return BrainStatus(scopes: out, askBudget: (o["ask_budget_s"] as? Double).flatMap { $0 > 0 ? $0 : nil })
    }
}

final class Oracle: @unchecked Sendable {
    static let seat = "oracle"
    static let perMinute = 6
    static let maxQuestion = 2048
    static let maxReply = 4096
    static let wakePoll: TimeInterval = 2, wakeLimit: TimeInterval = 45
    static let retryWindow: TimeInterval = 30 * 60
    static let retryTick: TimeInterval = 15

    static let busyLine = "Busy right now, I'll answer here within ~10 min."
    static func giveUpLine(owner: String, room: String) -> String { "Couldn't answer; ask \(owner) in \(room)." }

    /// A question waiting for the brain. Persisted in `oracle-pending.json`; deduped by question id.
    struct Pending: Codable, Equatable {
        var id: String, mailbox: String, agent: String, text: String
        var attempts: Int, nextAt: Date, since: Date
    }

    private struct Question { var id: String; var agent: String; var mac: String; var text: String; var link: PeerLink? }

    private let engine: PeerEngine, bus: ChatBus, brain: BrainTransport
    private let askOn: @Sendable () -> Bool
    private let projectsFor: @Sendable (String) -> [String]
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let lock = NSLock()
    private var fifo: [Question] = []
    private var draining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var asked: [String: [Date]] = [:]
    private var wakes = 0
    private var pending: [Pending] = []
    private var retrying = false
    private var timerOn = false
    private let autoRetry: Bool
    private let retryNap: @Sendable (TimeInterval) async -> Void
    private var pendingURL: URL { engine.root.appendingPathComponent("oracle-pending.json") }

    init(engine: PeerEngine, bus: ChatBus, brain: BrainTransport = BrainHTTP(),
         askOn: @escaping @Sendable () -> Bool = { PeerSettings.ask },
         projectsFor: @escaping @Sendable (String) -> [String] = { PeerSettings.askProjects[$0] ?? [] },
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         autoRetry: Bool = true,
         retryNap: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.engine = engine; self.bus = bus; self.brain = brain; self.askOn = askOn; self.projectsFor = projectsFor; self.now = now; self.sleep = sleep
        self.autoRetry = autoRetry; self.retryNap = retryNap
        if let d = try? Data(contentsOf: engine.root.appendingPathComponent("oracle-pending.json")),
           let p = try? Self.dec().decode([Pending].self, from: d) { pending = p }
        bus.registerSeat(Self.seat) { [weak self] m in self?.receive(m) }
        if !pending.isEmpty { ensureTimer() }                 // a restart mid-queue still answers
    }

    private static func dec() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
    private static func enc() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.sortedKeys]; return e }

    /// Questions still waiting for the brain (tests, status).
    var pendingQuestions: [Pending] { lock.lock(); defer { lock.unlock() }; return pending }

    private func savePendingLocked() {
        try? FileManager.default.createDirectory(at: engine.root, withIntermediateDirectories: true)
        if let d = try? Self.enc().encode(pending) { try? d.write(to: pendingURL, options: .atomic) }
    }

    /// Resolves once every queued question has been answered (tests; production never waits).
    func waitIdle() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fifo.isEmpty && !draining && wakes == 0 { lock.unlock(); c.resume() } else { idleWaiters.append(c); lock.unlock() }
        }
    }

    private func receive(_ m: ChatMessage) {
        guard m.channel == "@" + Self.seat, !(m.from.agent == Self.seat && m.from.mac == bus.mac) else { return }
        let link = m.from.mac == bus.mac ? nil : engine.peerLinks().first { PeerNaming.slug($0.label) == m.from.mac }
        if link == nil && m.from.mac != bus.mac { return }      // not us, not a pinned peer: nothing to answer
        lock.lock()
        if pending.contains(where: { $0.id == m.id }) { lock.unlock(); return }          // already queued: relay redelivery
        fifo.append(Question(id: m.id, agent: m.from.agent, mac: m.from.mac, text: m.text, link: link))
        let start = !draining; draining = true
        lock.unlock()
        if start { Task { [self] in await drain() } }
    }

    /// Next queued question, or nil (and wake idle waiters) when the queue is empty.
    private func next() -> Question? {
        lock.lock()
        guard !fifo.isEmpty else {
            draining = false
            let w = wakes == 0 ? idleWaiters : []
            if wakes == 0 { idleWaiters = [] }
            lock.unlock()
            for c in w { c.resume() }
            return nil
        }
        let q = fifo.removeFirst()
        lock.unlock()
        return q
    }

    private func drain() async {
        while let q = next() {
            if let l = q.link { let wait = rateWait(l.mailboxId); if wait > 0 { await sleep(wait) }; stamp(l.mailboxId) }
            await answer(q)
        }
    }

    /// Seconds until this peer may ask again: at most `perMinute` per rolling minute.
    private func rateWait(_ mailbox: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        let recent = (asked[mailbox] ?? []).filter { $0 > t.addingTimeInterval(-60) }
        guard recent.count >= Self.perMinute else { return 0 }
        return recent[recent.count - Self.perMinute].addingTimeInterval(60.001).timeIntervalSince(t)
    }

    private func stamp(_ mailbox: String) {
        lock.lock(); asked[mailbox, default: []].append(now()); asked[mailbox] = Array(asked[mailbox]!.suffix(60)); lock.unlock()
    }

    private enum Outcome { case reply(String), busy, down }

    /// One try at a question: fresh status call, then the ask with the brain's own budget. `status` is passed when the
    /// caller just fetched it.
    private func attempt(_ q: Question, link l: PeerLink, status: BrainStatus? = nil) async -> Outcome {
        let owner = engine.ownName, room = "#" + PeerNaming.slug(owner)
        let noProjects = "No projects are shared with you for asking — ask \(owner) in \(room)."
        if !askOn() { return .reply("asking is off") }
        if q.text.count > Self.maxQuestion { return .reply("Ask one question at a time (2 KB).") }
        let mine = projectsFor(l.mailboxId)
        if mine.isEmpty { return .reply(noProjects) }                   // checked on every question, never cached
        let fresh = status == nil ? await brain.status() : status
        guard let st = fresh else { return .down }
        let allowed = mine.filter { st.scopes[$0]?.hasPrefix("shared-") == true }
        if allowed.isEmpty { return .reply(noProjects) }
        switch await brain.ask(question: q.text, projects: allowed, timeout: st.askBudget ?? BrainHTTP.defaultAskBudget) {
        case .answer(let a): return .reply(Self.compose(a, owner: owner, room: room))
        case .busy: return .busy
        case .down: return .down
        case .failed:
            engine.recordProblem(.oracle, peer: l.label, text: "The brain couldn't answer \(l.label)'s question")
            return .reply(Self.giveUpLine(owner: owner, room: room))
        }
    }

    private func answer(_ q: Question) async {
        let owner = engine.ownName
        if let l = q.link {
            let st = await brain.status()
            if st == nil { startWake(q, link: l); return }           // cold brain: leave the queue so other questions are not held
            switch await attempt(q, link: l, status: st) {
            case .reply(let r): send(r, to: q)
            case .busy, .down: park(q, link: l)
            }
        } else {
            switch await brain.ask(question: q.text, projects: [], timeout: BrainHTTP.defaultAskBudget) {
            case .answer(let a): send(Self.compose(a, owner: owner, room: "#here"), to: q)
            case .busy: send("The brain is busy right now — ask again in a minute.", to: q)
            case .down: send("The brain isn't running.", to: q)
            case .failed: send("The brain couldn't answer that.", to: q)
            }
        }
    }

    /// Tell the asker once, then keep the question on disk and retry with backoff.
    private func park(_ q: Question, link l: PeerLink) {
        let t = now()
        lock.lock()
        let fresh = !pending.contains { $0.id == q.id }
        if fresh {
            pending.append(Pending(id: q.id, mailbox: l.mailboxId, agent: q.agent, text: q.text, attempts: 0,
                                   nextAt: t.addingTimeInterval(Self.backoff(0)), since: t))
            savePendingLocked()
        }
        lock.unlock()
        if fresh { sendLine(Self.busyLine, to: q) }
        ensureTimer()
    }

    static func backoff(_ attempts: Int) -> TimeInterval { min(30 * pow(2, Double(attempts)), 300) }

    private func ensureTimer() {
        guard autoRetry else { return }
        guard claimTimer() else { return }
        Task { [self] in
            repeat { await retryNap(Self.retryTick); await retryPending() } while !timerIdle()
        }
    }

    /// One pass over the queue: drop questions whose link is gone, answer the due ones, give up after 30 min.
    func retryPending() async {
        guard beginRetry() else { return }
        defer { endRetry() }
        for p in pruneAndDue() {
            guard let l = engine.peerLinks().first(where: { $0.mailboxId == p.mailbox }) else { remove(p.id); continue }
            let q = Question(id: p.id, agent: p.agent, mac: PeerNaming.slug(l.label), text: p.text, link: l)
            let owner = engine.ownName, room = "#" + PeerNaming.slug(owner)
            switch await attempt(q, link: l) {
            case .reply(let r): send(r, to: q); remove(p.id)
            case .busy, .down:
                if now().timeIntervalSince(p.since) >= Self.retryWindow {
                    engine.recordProblem(.oracle, peer: l.label, text: "The brain didn't answer \(l.label)'s question within 30 min")
                    send(Self.giveUpLine(owner: owner, room: room), to: q); remove(p.id)
                } else {
                    bump(p.id)
                }
            }
        }
    }

    private func claimTimer() -> Bool { lock.lock(); defer { lock.unlock() }; if timerOn { return false }; timerOn = true; return true }
    private func timerIdle() -> Bool { lock.lock(); defer { lock.unlock() }; if pending.isEmpty { timerOn = false }; return pending.isEmpty }
    private func beginRetry() -> Bool { lock.lock(); defer { lock.unlock() }; if retrying { return false }; retrying = true; return true }
    private func endRetry() { lock.lock(); retrying = false; lock.unlock() }

    /// Drops questions whose link is gone (removed/unpaired), returns the ones due now.
    private func pruneAndDue() -> [Pending] {
        let links = engine.peerLinks()
        lock.lock(); defer { lock.unlock() }
        let before = pending.count
        pending.removeAll { p in !links.contains { $0.mailboxId == p.mailbox } }
        if pending.count != before { savePendingLocked() }
        return pending.filter { $0.nextAt <= now() }
    }

    private func bump(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].attempts += 1; pending[i].nextAt = now().addingTimeInterval(Self.backoff(pending[i].attempts)); savePendingLocked()
    }

    private func remove(_ id: String) {
        lock.lock(); pending.removeAll { $0.id == id }; savePendingLocked(); lock.unlock()
    }

    /// The brain did not answer its status call: tell the asker, start it if it has no process, poll every 2 s for up to
    /// 45 s, then answer (or park the question and say so once). Runs as its own task.
    private func startWake(_ q: Question, link l: PeerLink) {
        lock.lock(); wakes += 1; lock.unlock()
        Task { [self] in
            sendLine("Waking the brain on \(engine.ownName)'s Mac…", to: q)
            await brain.wakeIfDown()
            var st: BrainStatus?
            var waited: TimeInterval = 0
            while st == nil, waited < Self.wakeLimit {
                await sleep(Self.wakePoll); waited += Self.wakePoll
                st = await brain.status()
            }
            if let st, case .reply(let r) = await attempt(q, link: l, status: st) { send(r, to: q) }
            else { park(q, link: l) }
            let w = endWake()
            for c in w { c.resume() }
        }
    }

    private func endWake() -> [CheckedContinuation<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        wakes -= 1
        guard wakes == 0 && fifo.isEmpty && !draining else { return [] }
        let w = idleWaiters; idleWaiters = []
        return w
    }

    private func sendLine(_ text: String, to q: Question) {
        guard let l = q.link else { return }
        _ = engine.postChat(channel: "@\(q.agent)@\(PeerNaming.slug(l.label))", agent: Self.seat, text: text, re: q.id, recordLocal: false)
    }

    /// `answer` + `Sources: …` (repo-relative), masked, capped. Empty sources → the no-record line.
    static func compose(_ a: BrainAnswer, owner: String, room: String) -> String {
        guard !a.sources.isEmpty else { return "No record in the brain for that — ask \(owner) in \(room)." }
        let paths = a.sources.map { s -> String in
            guard let r = s.range(of: #"/Users/[^/]+/Projects/"#, options: .regularExpression) else { return s }
            return s.replacingCharacters(in: r, with: "")
        }
        let text = PeerMask.mask(a.answer + "\nSources: " + paths.joined(separator: ", "))
        return text.count > maxReply ? String(text.prefix(maxReply - 6)) + "…(cut)" : text
    }

    private func send(_ text: String, to q: Question) {
        if let l = q.link {
            let peer = PeerNaming.slug(l.label)
            _ = engine.postChat(channel: "@\(q.agent)@\(peer)", agent: Self.seat, text: text, re: q.id, recordLocal: false)
            func cut(_ s: String) -> String { s.count > 400 ? String(s.prefix(400)) : s }
            bus.post(channel: "#" + peer, agent: q.agent, mac: l.label, text: "Q (\(q.agent)): " + cut(q.text), id: q.id + ":q", deliver: false)
            bus.post(channel: "#" + peer, agent: Self.seat, text: "A: " + cut(ChatNaming.clean(text)), re: q.id, deliver: false)
        } else {
            _ = engine.postChat(channel: "@" + q.agent, agent: Self.seat, text: text, re: q.id)
        }
    }
}
