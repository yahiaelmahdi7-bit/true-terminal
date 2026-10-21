import Foundation

/// Run 33 — Ask desk. One seat per Mac, `@oracle`, whose delivery is a closure: every line addressed to it is a question,
/// answered from the owner's second brain (never from a Claude pane) and sent back as a direct line with `re` = the question id.

struct BrainAnswer: Equatable, Sendable { var answer: String; var sources: [String] }

protocol BrainTransport: Sendable {
    /// nil = server down, non-2xx or bad JSON.
    func ask(question: String, projects: [String]) async -> BrainAnswer?
    /// project slug → scope (`shared-*`, `walled-*`), from `GET /api/status`; nil = unreachable.
    func scopes() async -> [String: String]?
}

/// The live brain: `http://127.0.0.1:8800`.
struct BrainHTTP: BrainTransport {
    var base = URL(string: "http://127.0.0.1:8800")!

    private func session(_ timeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout
        return URLSession(configuration: c)
    }

    func ask(question: String, projects: [String]) async -> BrainAnswer? {
        var req = URLRequest(url: base.appendingPathComponent("api/ask"), timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["question": question, "project_ids": projects])
        guard let (data, resp) = try? await session(60).data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let a = o["answer"] as? String else { return nil }
        return BrainAnswer(answer: a, sources: (o["sources"] as? [String]) ?? [])
    }

    func scopes() async -> [String: String]? {
        var req = URLRequest(url: base.appendingPathComponent("api/status"), timeoutInterval: 20)
        req.httpMethod = "GET"
        guard let (data, resp) = try? await session(20).data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ps = o["projects"] as? [[String: Any]] else { return nil }
        var out: [String: String] = [:]
        for p in ps { if let id = p["project_id"] as? String, let s = p["scope"] as? String { out[id.lowercased()] = s } }
        return out
    }
}

final class Oracle: @unchecked Sendable {
    static let seat = "oracle"
    static let perMinute = 6
    static let maxQuestion = 2048
    static let maxReply = 4096
    static let scopeLife: TimeInterval = 600

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
    private var scopeCache: (at: Date, map: [String: String])?

    init(engine: PeerEngine, bus: ChatBus, brain: BrainTransport = BrainHTTP(),
         askOn: @escaping @Sendable () -> Bool = { PeerSettings.ask },
         projectsFor: @escaping @Sendable (String) -> [String] = { PeerSettings.askProjects[$0] ?? [] },
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.engine = engine; self.bus = bus; self.brain = brain; self.askOn = askOn; self.projectsFor = projectsFor; self.now = now; self.sleep = sleep
        bus.registerSeat(Self.seat) { [weak self] m in self?.receive(m) }
    }

    /// Resolves once every queued question has been answered (tests; production never waits).
    func waitIdle() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fifo.isEmpty && !draining { lock.unlock(); c.resume() } else { idleWaiters.append(c); lock.unlock() }
        }
    }

    private func receive(_ m: ChatMessage) {
        guard m.channel == "@" + Self.seat, !(m.from.agent == Self.seat && m.from.mac == bus.mac) else { return }
        let link = m.from.mac == bus.mac ? nil : engine.peerLinks().first { PeerNaming.slug($0.label) == m.from.mac }
        if link == nil && m.from.mac != bus.mac { return }      // not us, not a pinned peer: nothing to answer
        lock.lock()
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
            let w = idleWaiters; idleWaiters = []
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

    private func cachedScopes() -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        guard let c = scopeCache, now().timeIntervalSince(c.at) < Self.scopeLife else { return nil }
        return c.map
    }

    private func storeScopes(_ m: [String: String]) { lock.lock(); scopeCache = (now(), m); lock.unlock() }

    private func liveScopes() async -> [String: String]? {
        if let c = cachedScopes() { return c }
        guard let m = await brain.scopes() else { return nil }
        storeScopes(m)
        return m
    }

    private func answer(_ q: Question) async {
        let owner = engine.ownName, room = "#" + PeerNaming.slug(owner)
        let reply: String
        if let l = q.link {
            let noProjects = "No projects are shared with you for asking — ask \(owner) in \(room)."
            let asleep = "The brain on \(owner)'s Mac is asleep — ask in \(room)."
            if !askOn() { reply = "asking is off" }
            else if q.text.count > Self.maxQuestion { reply = "Ask one question at a time (2 KB)." }
            else if projectsFor(l.mailboxId).isEmpty { reply = noProjects }      // checked on every question, never cached
            else if let scopes = await liveScopes() {
                let allowed = projectsFor(l.mailboxId).filter { scopes[$0]?.hasPrefix("shared-") == true }
                if allowed.isEmpty { reply = noProjects }
                else if let a = await brain.ask(question: q.text, projects: allowed) { reply = Self.compose(a, owner: owner, room: room) }
                else { reply = asleep }
            } else { reply = asleep }
        } else if let a = await brain.ask(question: q.text, projects: []) {
            reply = Self.compose(a, owner: owner, room: "#here")
        } else { reply = "The brain isn't running." }
        send(reply, to: q)
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
