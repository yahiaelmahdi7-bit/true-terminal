import Foundation

/// a cross-Mac `ask` — a short, read-only Claude run on a partner's Mac that answers one question.
/// It rides the delegate path (relay, outbox, sealing, grants, PeerNotifier) as two new sealed kinds: `ask` and `ask-answer`.

enum AskPoolState: Sendable { case ok, lendOff, atLimit }

enum AskRunResult: Sendable { case answer(String), failed }

/// Runs one jailed ask. The live runner starts `claude`; tests use a fake.
protocol AskRunning: AnyObject, Sendable {
    func run(prompt: String, cwd: String, root: URL, askId: String) -> AskRunResult
}

struct SentAsk: Codable, Equatable, Sendable {
    var askId: String
    var peerLabel: String
    var mailbox: String
    var repo: String          // what the person typed (or the folder's name), for the refusal text only
    var created: Date
    var fromAgent: String
    var q: String             // kept on the sender's own Mac so `--re` can thread; never sent to audit
}

struct AskAnswer: Codable, Equatable, Sendable {
    var askId: String
    var peerLabel: String
    var status: String        // answered | refused | expired | failed
    var text: String          // the answer or the plain refusal line
    var q: String
    var at: Date
}

private struct AskRateEntry: Codable { var asker: String; var at: Double }

/// The grant half of an ask, a pure function so it is easy to test.
enum AskGrant {
    static let levels: Set<String> = ["read", "work", "admin"]

    /// `peerKey` is the asker's device key. `repoURL` nil = no `--repo`. `clonePath` is the receiver's clone, if any.
    static func allowed(_ s: GrantSnapshot, peerKey: String, repoURL: String?, clonePath: String?, now: Date) -> Bool {
        guard let person = GrantRules.person(for: peerKey, in: s) else { return false }
        let t = now.timeIntervalSince1970
        let held = s.grants.filter { $0.person == person && levels.contains($0.level) && $0.revoked_at == nil && ($0.expires.map { $0 > t } ?? true) }
        let me = s.devices.first { $0.device == s.device }?.person
        for g in held {
            guard let w = s.workspaces.first(where: { $0.id == g.workspace }) else { continue }
            if let url = repoURL {
                if w.kind == "repo", GrantRules.repoMatches(w.key, url) { return true }
                if w.kind == "folder", let clone = clonePath {
                    let root = PeerDirs.realDirectory(w.key) ?? URL(fileURLWithPath: (w.key as NSString).expandingTildeInPath).standardizedFileURL.path
                    let real = PeerDirs.realDirectory(clone) ?? clone
                    if real == root || real.hasPrefix(root + "/") { return true }
                }
            } else if let me, w.owner == me {
                return true
            }
        }
        return false
    }
}

/// A 60 s cache of Steward's `GET /allowance`: `{devices: [{device, lend, headroom|null, ...}]}`.
final class AskBoard: @unchecked Sendable {
    struct Row { var lend: String; var headroom: Double? }
    static let ttl: TimeInterval = 60
    private let lock = NSLock()
    private var cached: [String: Row]?
    private var at: Date?

    func rows(now: Date, fetch: (@Sendable () throws -> Data)?) -> [String: Row]? {
        lock.lock(); defer { lock.unlock() }
        if let at, now.timeIntervalSince(at) < Self.ttl, now >= at { return cached }
        var out: [String: Row]?
        if let fetch, let data = try? fetch(),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let devs = obj["devices"] as? [[String: Any]] {
            var m: [String: Row] = [:]
            for d in devs { if let id = d["device"] as? String { m[id] = Row(lend: (d["lend"] as? String) ?? "on", headroom: (d["headroom"] as? NSNumber)?.doubleValue) } }
            out = m
        }
        cached = out; at = now
        return out
    }
}

final class AskService: @unchecked Sendable {
    unowned let engine: PeerEngine
    let queue = DispatchQueue(label: "true.peers.ask")
    private let lock = NSLock()
    private var sent: [SentAsk]
    private var rate: [AskRateEntry]

    static let life: TimeInterval = 24 * 3600
    static let perHour = 10, perDay = 40

    // Seams: live closures over G6's lend file and Steward's allowance board (set in init); tests replace them.
    var runner: AskRunning = LiveAskRunner()
    var isReserved: @Sendable () -> Bool = { false }
    var poolState: @Sendable () -> AskPoolState = { .ok }
    var headroomOf: @Sendable (String) -> Int? = { _ in nil }
    private let board = AskBoard()
    var notify: @Sendable (String, String) -> Void = { who, id in PeerNotifier.shared.askAnswered(from: who, askId: id) }

    private var dir: URL { engine.root.appendingPathComponent("ask", isDirectory: true) }
    private var runsDir: URL { dir.appendingPathComponent("runs", isDirectory: true) }
    private var answersDir: URL { engine.root.appendingPathComponent("answers", isDirectory: true) }

    init(engine: PeerEngine) {
        self.engine = engine
        let d = engine.root.appendingPathComponent("ask", isDirectory: true)
        sent = (try? Data(contentsOf: d.appendingPathComponent("sent.json"))).flatMap { try? Self.dec.decode([SentAsk].self, from: $0) } ?? []
        rate = (try? Data(contentsOf: d.appendingPathComponent("rate.json"))).flatMap { try? JSONDecoder().decode([AskRateEntry].self, from: $0) } ?? []
        isReserved = { [unowned engine] in
            guard let s = engine.grants.snapshot, let d = s.devices.first(where: { $0.device == s.device }) else { return false }
            return s.persons.first { $0.id == d.person }?.role == "owner"
        }
        poolState = { [unowned self] in self.livePoolState() }
        headroomOf = { [unowned self] in self.liveHeadroom(mailbox: $0) }
        for a in sent { scheduleExpiry(a) }
        sweep()
    }

    // MARK: G6 wiring — the lend switch and the allowance board

    /// Steward's board rows by device, cached 60 s (a failed read too, so a dead Steward costs one short wait a minute). Nil = unreachable.
    private func boardRows() -> [String: AskBoard.Row]? {
        board.rows(now: engine.now(), fetch: engine.allowanceFetch)
    }

    /// Receiver: may this Mac take an ask now? Lend off (the local file or Steward's row) refuses; unknown or no headroom
    /// (or Steward unreachable) is "at its pool limit". A missing lend file reads as on, as `read_lend` does.
    private func livePoolState() -> AskPoolState {
        let lendFile = engine.home + "/.true/group/lend"
        if let t = try? String(contentsOfFile: lendFile, encoding: .utf8), t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off" {
            return .lendOff
        }
        guard let device = engine.grants.snapshot?.device, let row = boardRows()?[device] else { return .atLimit }
        if row.lend == "off" { return .lendOff }
        guard let h = row.headroom, h > 0 else { return .atLimit }
        return .ok
    }

    /// Sender: that Mac's headroom from the board (nil = unknown, or it is not lending). Link -> device is the signing-key match
    /// `resolve` and `AskGrant` use against the grant snapshot.
    private func liveHeadroom(mailbox: String) -> Int? {
        guard let link = engine.peerLinks().first(where: { $0.mailboxId == mailbox }),
              let snap = engine.grants.snapshot,
              let device = snap.devices.first(where: { $0.peer_key == PeerB64.std(link.keys.sign) })?.device,
              let row = boardRows()?[device], row.lend != "off", let h = row.headroom else { return nil }
        return Int(h.rounded())
    }

    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    private func mkdirs() {
        for u in [dir, runsDir, answersDir] {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    private func saveSent() { mkdirs(); PeerEngine.write((try? Self.enc.encode(sent)) ?? Data(), to: dir.appendingPathComponent("sent.json")) }
    private func saveRate() { mkdirs(); PeerEngine.write((try? JSONEncoder().encode(rate)) ?? Data(), to: dir.appendingPathComponent("rate.json")) }

    static func validId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.allSatisfy { $0.isHexDigit || $0 == "-" } && !s.contains("..")
    }

    // MARK: audit (ids, sizes and times; never text)

    private func audit(_ action: String, _ id: String, size: Int? = nil, extra: String = "") {
        let note = "id=\(id.prefix(8)) t=\(Int(engine.now().timeIntervalSince1970))" + (size.map { " size=\($0)" } ?? "") + (extra.isEmpty ? "" : " \(extra)")
        engine.grants.note(action: action, note: note)
    }

    // MARK: sender

    /// Resolve a typed name to one Mac: a link label first, then a person (their Macs), the online one with the most headroom.
    func resolve(_ name: String) -> PeerLink? {
        let links = engine.peerLinks().filter { $0.confirmed }
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let l = links.first(where: { $0.label.lowercased() == n }) { return l }
        guard let s = engine.grants.snapshot, let p = s.persons.first(where: { $0.id.lowercased() == n }) else { return nil }
        let keys = Set(s.devices.filter { $0.person == p.id }.compactMap { $0.peer_key })
        let macs = links.filter { keys.contains(PeerB64.std($0.keys.sign)) }
        if macs.count <= 1 { return macs.first }
        let t = engine.now()
        func online(_ l: PeerLink) -> Bool {
            if let c = engine.peerCaps(l.mailboxId), !c.isStale(at: t) { return true }
            return engine.heardAt(l.mailboxId).map { t.timeIntervalSince($0) < 600 } ?? false
        }
        let pool = macs.filter(online).isEmpty ? macs : macs.filter(online)
        return pool.max { (headroomOf($0.mailboxId) ?? -1) < (headroomOf($1.mailboxId) ?? -1) }
    }

    func send(to name: String, question rawQ: String, repo rawRepo: String = "", re: String? = nil, fromAgent: String = "agent") -> Result<String, PeerError> {
        let q = rawQ.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return .failure(.invalid("Give a question to ask")) }
        if q.count > 2000 { return .failure(.invalid("That question is too long (2000 characters at most)")) }
        guard let link = resolve(name) else { return .failure(.invalid("No peer or person named \(name)")) }
        var remote = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        var shown = remote
        if remote.hasPrefix("/") || remote.hasPrefix("~") || remote.hasPrefix(".") {
            let path = (remote as NSString).expandingTildeInPath
            guard let r = engine.launcher.remoteURL(ofRepoAt: path) else { return .failure(.invalid("That folder has no git origin")) }
            remote = r; shown = (path as NSString).lastPathComponent
        } else if let n = PeerRepo.normalize(remote) {
            shown = (n as NSString).lastPathComponent
        }
        let id = UUID().uuidString.lowercased()
        var payload: [String: Any] = ["t": "ask", "askId": id, "q": q, "at": engine.now().timeIntervalSince1970]
        if !remote.isEmpty { payload["repo"] = remote }
        if let re, !re.isEmpty {
            payload["re"] = re
            if let prior = answer(re) { payload["ctx"] = String("Q: \(prior.q)\nA: \(prior.text)".prefix(1500)) }
        }
        let rec = SentAsk(askId: id, peerLabel: link.label, mailbox: link.mailboxId, repo: shown, created: engine.now(), fromAgent: fromAgent, q: q)
        lock.lock(); sent.append(rec); saveSent(); lock.unlock()
        guard engine.sealAndQueue(payload, to: link, jobId: id, owner: link.mailboxId) else {
            lock.lock(); sent.removeAll { $0.askId == id }; saveSent(); lock.unlock()
            return .failure(.invalid("That question is too large to send"))
        }
        audit("ask.sent", id, size: q.utf8.count)
        scheduleExpiry(rec)
        return .success(id)
    }

    private func scheduleExpiry(_ a: SentAsk) {
        let wait = max(1, a.created.addingTimeInterval(Self.life).timeIntervalSince(engine.now()) + 1)
        engine.scheduler(wait) { [weak self] in self?.sweep() }
    }

    /// Anything unanswered after 24 h expires; its queued ask leaves the outbox.
    func sweep() {
        lock.lock(); let all = sent; lock.unlock()
        for a in all where engine.now().timeIntervalSince(a.created) >= Self.life && answer(a.askId) == nil {
            if store(AskAnswer(askId: a.askId, peerLabel: a.peerLabel, status: "expired", text: "expired: \(a.peerLabel) did not come online", q: a.q, at: engine.now())) {
                engine.dropOutbox(jobId: a.askId)
                audit("ask.expired", a.askId)
                engine.changed()
            }
        }
    }

    func isPending(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return sent.contains { $0.askId == id } }

    func answer(_ id: String) -> AskAnswer? {
        guard Self.validId(id) else { return nil }
        return (try? Data(contentsOf: answersDir.appendingPathComponent("\(id).json"))).flatMap { try? Self.dec.decode(AskAnswer.self, from: $0) }
    }

    /// At most one answer per ask id: the first writer wins.
    @discardableResult private func store(_ a: AskAnswer) -> Bool {
        mkdirs()
        let u = answersDir.appendingPathComponent("\(a.askId).json")
        let fd = open(u.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let d = (try? Self.enc.encode(a)) ?? Data()
        _ = d.withUnsafeBytes { Foundation.write(fd, $0.baseAddress!, $0.count) }
        close(fd)
        return true
    }

    func refusalText(code: String, ask a: SentAsk, retryAt: Double?) -> String {
        let who = a.peerLabel
        switch code {
        case "grant":
            let target = a.repo.isEmpty ? "any of their workspaces" : a.repo
            return "refused: \(who) has not granted you read on \(target)"
        case "clone": return "refused: \(a.repo) is not cloned on \(who)"
        case "lendOff": return "refused: \(who)'s Mac is not lending right now"
        case "atLimit": return "refused: \(who)'s Mac is at its pool limit"
        case "reserved": return "refused: the user's Mac is reserved"
        case "rate":
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let when = retryAt.map { f.string(from: Date(timeIntervalSince1970: $0)) } ?? "later"
            return "refused: ask limit reached (10 an hour from you, 40 a day in total), try after \(when)"
        default: return "failed: \(who) could not answer"
        }
    }

    func handleAnswer(_ obj: [String: Any], from mailbox: String) {
        guard let id = obj["askId"] as? String, Self.validId(id) else { engine.drop("ask-answer payload"); return }
        lock.lock(); let rec = sent.first { $0.askId == id && $0.mailbox == mailbox }; lock.unlock()
        guard let rec else { engine.drop("ask-answer unknown"); return }
        let ok = obj["ok"] as? Bool ?? false
        let text: String, status: String
        if ok, let t = obj["text"] as? String { text = String(t.prefix(8000)); status = "answered" }
        else if let code = obj["code"] as? String, code != "failed" { text = refusalText(code: code, ask: rec, retryAt: obj["retryAt"] as? Double); status = "refused" }
        else { text = refusalText(code: "failed", ask: rec, retryAt: nil); status = "failed" }
        guard store(AskAnswer(askId: id, peerLabel: rec.peerLabel, status: status, text: text, q: rec.q, at: engine.now())) else {
            engine.drop("ask-answer duplicate"); return
        }
        audit(status == "answered" ? "ask.answered" : "ask.refused", id, size: text.utf8.count)
        engine.launcher.deliverLine(agent: rec.fromAgent, line: "Answer from \(rec.peerLabel) is ready: run `true-peer result \(id)`")
        notify(rec.peerLabel, id)
        engine.changed()
    }

    // MARK: receiver

    func handleAsk(_ obj: [String: Any], from link: PeerLink) {
        queue.async { [self] in receive(obj, from: link) }
    }

    private func reply(_ id: String, to link: PeerLink, ok: Bool, text: String? = nil, code: String? = nil, retryAt: Double? = nil) {
        var p: [String: Any] = ["t": "ask-answer", "askId": id, "ok": ok]
        if let text { p["text"] = text }
        if let code { p["code"] = code }
        if let retryAt { p["retryAt"] = retryAt }
        _ = engine.sealAndQueue(p, to: link, owner: link.mailboxId)
    }

    private func refuse(_ id: String, _ link: PeerLink, _ code: String, retryAt: Double? = nil) {
        audit("ask.refused", id, extra: "code=\(code)")
        reply(id, to: link, ok: false, code: code, retryAt: retryAt)
    }

    /// True the first time an ask id is seen on this Mac (O_EXCL); a replay or repeat never runs.
    private func claim(_ id: String) -> Bool {
        mkdirs()
        let fd = open(runsDir.appendingPathComponent("\(id).json").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let line = Data("{\"at\":\(Int(engine.now().timeIntervalSince1970))}".utf8)
        _ = line.withUnsafeBytes { Foundation.write(fd, $0.baseAddress!, $0.count) }
        close(fd)
        return true
    }

    private func receive(_ obj: [String: Any], from link: PeerLink) {
        guard let id = obj["askId"] as? String, Self.validId(id), let q = obj["q"] as? String,
              !q.isEmpty, q.count <= 2000, let at = obj["at"] as? Double else { engine.drop("ask payload"); return }
        if engine.now().timeIntervalSince1970 - at > Self.life { engine.drop("ask older than 24h"); return }
        guard claim(id) else { engine.drop("ask duplicate"); return }
        audit("ask.received", id, size: q.utf8.count)
        if isReserved() { return refuse(id, link, "reserved") }
        let repo = (obj["repo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let clone: String? = repo.flatMap { r in
            (engine.sharedRepos()[link.mailboxId] ?? []).first { PeerRepo.same($0.url, r) && FileManager.default.fileExists(atPath: $0.path) }?.path
                ?? engine.launcher.resolveClone(repo: r)
        }
        // Grant: from the cached snapshot, fresh, whatever the grants-mode switch says. Any failure reads as "no grant".
        let g = engine.grants
        let fresh = g.lastFetch.map { engine.now().timeIntervalSince($0) < GrantRules.staleAfter } ?? false
        let offline = g.offlineUntil.map { $0 > engine.now() } ?? false
        guard let snap = g.snapshot, fresh || offline,
              AskGrant.allowed(snap, peerKey: PeerB64.std(link.keys.sign), repoURL: repo, clonePath: clone, now: engine.now()) else {
            return refuse(id, link, "grant")
        }
        if repo != nil && clone == nil { return refuse(id, link, "clone") }
        switch poolState() {
        case .lendOff: return refuse(id, link, "lendOff")
        case .atLimit: return refuse(id, link, "atLimit")
        case .ok: break
        }
        if let retry = rateCheck(asker: link.mailboxId) { return refuse(id, link, "rate", retryAt: retry) }
        recordRate(asker: link.mailboxId)

        var cwd = clone ?? ""
        var temp: String?
        if cwd.isEmpty {
            let t = NSTemporaryDirectory() + "true-ask-\(id)"
            try? FileManager.default.createDirectory(atPath: t, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            cwd = t; temp = t
        }
        var prompt = "You are answering one question for a teammate about the files in the current folder. Use only Read, Grep and Glob. "
            + "Do not change anything. Answer in under 400 words.\n\n"
        if let ctx = obj["ctx"] as? String, !ctx.isEmpty { prompt += "Earlier in this thread:\n\(ctx.prefix(1500))\n\n" }
        prompt += "Question:\n\(q)"
        let result = runner.run(prompt: prompt, cwd: cwd, root: engine.root, askId: id)
        if let temp { try? FileManager.default.removeItem(atPath: temp) }
        switch result {
        case .answer(let text):
            audit("ask.answered", id, size: text.utf8.count)
            reply(id, to: link, ok: true, text: text)
        case .failed:
            audit("ask.failed", id)
            reply(id, to: link, ok: false, code: "failed")
        }
    }

    // MARK: rate limit — 10 an hour per asker, 40 a day in total; only asks that run are counted

    private func rateCheck(asker: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let t = engine.now().timeIntervalSince1970
        rate.removeAll { t - $0.at >= 86400 }
        let hour = rate.filter { $0.asker == asker && t - $0.at < 3600 }.map(\.at).sorted()
        var retry: Double?
        if hour.count >= Self.perHour { retry = hour[hour.count - Self.perHour] + 3600 }
        if rate.count >= Self.perDay {
            let day = rate.map(\.at).sorted()
            retry = max(retry ?? 0, day[day.count - Self.perDay] + 86400)
        }
        return retry
    }

    private func recordRate(asker: String) {
        lock.lock(); rate.append(AskRateEntry(asker: asker, at: engine.now().timeIntervalSince1970)); saveRate(); lock.unlock()
    }
}

/// Starts the real `claude` in the jail. Nothing but the prompt comes from the asker.
final class LiveAskRunner: AskRunning, @unchecked Sendable {
    static func claudePath() -> String? {
        ProgramFinder.shared.resolve("claude")
    }

    func run(prompt: String, cwd: String, root: URL, askId: String) -> AskRunResult {
        guard let exe = Self.claudePath(), let settings = AskJail.prepare(root: root, askId: askId, cwd: cwd) else { return .failed }
        defer { try? FileManager.default.removeItem(atPath: settings) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProgramFinder.shared.path
        p.environment = env
        p.arguments = AskJail.arguments(prompt: prompt, settingsFile: settings)
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { ProgramFinder.shared.failedToRun("claude"); return .failed }
        DispatchQueue.global().asyncAfter(deadline: .now() + AskJail.wallClock) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0, !text.isEmpty else { return .failed }
        return .answer(String(text.prefix(6000)))
    }
}
