import Foundation
import CryptoKit

/// True ↔ True peers — the engine (Run 29). Receiver: take a validated job from a paired peer, run it as a real Claude
/// session in a worktree, report status + result back. Sender: hand jobs to peers, track them, deliver one line to the
/// lead. Everything crosses the relay as sealed envelopes (PeerSeal). All state in JSON files under `root`; the outbox
/// retries only while it has items (no idle timer).
final class PeerEngine: @unchecked Sendable {
    let root: URL
    let identity: PeerIdentity
    private let launcher: PeerLauncher
    private let transport: PeerTransport
    private let inboundMode: @Sendable () -> PeerInboundMode
    private let now: @Sendable () -> Date
    private let scheduler: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let ownName: String

    private let lock = NSLock()
    private let work = DispatchQueue(label: "true.peers.work")
    private let net = DispatchQueue(label: "true.peers.net")
    private var links: [PeerLink]
    private var inbound: [InboundJob]
    private var sent: [SentJob]
    private var outbox: [OutboxItem]
    private var invites: [PendingInvite]
    private var seen: [String: Int]
    private var timerAt: Date?
    private var lastWanted: Bool?
    /// Set when someone finished pairing with us ("Paired with <label>"); the Peers sheet shows it.
    private(set) var lastPaired: String?
    private(set) var dropCount = 0

    static let inviteLife: TimeInterval = 24 * 3600
    static let seenLife: TimeInterval = 8 * 24 * 3600

    init(root: URL = PeerEngine.standardRoot, identity: PeerIdentity, launcher: PeerLauncher, transport: PeerTransport,
         inboundMode: @escaping @Sendable () -> PeerInboundMode = { PeerInboundMode.current },
         ownName: String = Host.current().localizedName ?? "True",
         now: @escaping @Sendable () -> Date = { Date() },
         scheduler: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil) {
        self.root = root; self.identity = identity; self.launcher = launcher; self.transport = transport
        self.inboundMode = inboundMode; self.now = now; self.ownName = String(ownName.prefix(PeerValidate.maxLabel))
        let q = DispatchQueue(label: "true.peers.timer")
        self.scheduler = scheduler ?? { d, f in q.asyncAfter(deadline: .now() + d, execute: f) }
        links = PeerEngine.load(root.appendingPathComponent("peers.json")) ?? []
        inbound = PeerEngine.load(root.appendingPathComponent("inbound.json")) ?? []
        sent = PeerEngine.load(root.appendingPathComponent("sent.json")) ?? []
        invites = PeerEngine.load(root.appendingPathComponent("invites.json")) ?? []
        seen = PeerEngine.load(root.appendingPathComponent("seen.json")) ?? [:]
        outbox = PeerEngine.loadOutbox(root)
        let t = now()
        invites.removeAll { $0.used || $0.expires <= t }
        seen = seen.filter { $0.value > Int(t.timeIntervalSince1970) }
        transport.onMessage = { [weak self] _, _, blob in self?.receive(blob) }
        transport.onStatus = { [weak self] up in
            guard let self else { return }
            if up { self.flush() }
            self.changed()
        }
        for i in invites { scheduleWantedCheck(at: i.expires) }
        updateWanted()
        if !outbox.isEmpty { net.async { [self] in pump() } }
    }

    static var standardRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".true/peers", isDirectory: true) }

    /// Tests: wait for queued work (launches, then the outbox, then anything those queued).
    func drain() { for _ in 0..<3 { work.sync {}; net.sync {} } }

    var isConnected: Bool { transport.isConnected }
    /// Whether the relay connection is wanted right now (a paired peer, a live invite, or something still to send).
    var wantsRelay: Bool { lock.lock(); defer { lock.unlock() }; return computeWanted() }

    // MARK: files

    private static func enc() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    private static func dec() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
    private static func load<T: Decodable>(_ url: URL) -> T? { (try? Data(contentsOf: url)).flatMap { try? dec().decode(T.self, from: $0) } }
    private static func loadOutbox(_ root: URL) -> [OutboxItem] {
        let dir = root.appendingPathComponent("outbox")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { load(dir.appendingPathComponent($0)) as OutboxItem? }
            .sorted { $0.nextAt < $1.nextAt }
    }

    /// 0600 file in a 0700 directory, created with the mode (never chmod-ed after) and renamed into place.
    static func write(_ data: Data, to url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let ok = data.withUnsafeBytes { p -> Bool in
            var off = 0
            while off < p.count { let n = Foundation.write(fd, p.baseAddress! + off, p.count - off); if n <= 0 { return false }; off += n }
            return true
        }
        close(fd)
        if ok { rename(tmp, url.path) } else { unlink(tmp) }
    }

    private func saveLinks() { Self.write((try? Self.enc().encode(links)) ?? Data(), to: root.appendingPathComponent("peers.json")) }
    private func saveInbound() { Self.write((try? Self.enc().encode(inbound)) ?? Data(), to: root.appendingPathComponent("inbound.json")) }
    private func saveSent() { Self.write((try? Self.enc().encode(sent)) ?? Data(), to: root.appendingPathComponent("sent.json")) }
    private func saveInvites() { Self.write((try? Self.enc().encode(invites)) ?? Data(), to: root.appendingPathComponent("invites.json")) }
    private func saveSeen() { Self.write((try? Self.enc().encode(seen)) ?? Data(), to: root.appendingPathComponent("seen.json")) }
    private func outboxURL(_ id: String) -> URL { root.appendingPathComponent("outbox/\(id).json") }
    private func saveOutbox(_ i: OutboxItem) { Self.write((try? Self.enc().encode(i)) ?? Data(), to: outboxURL(i.id)) }
    func jobDir(_ jobId: String) -> URL { root.appendingPathComponent("jobs/\(jobId)", isDirectory: true) }
    func resultPath(_ jobId: String) -> String { jobDir(jobId).appendingPathComponent("result.md").path }
    private func changed() { NotificationCenter.default.post(name: .peersChanged, object: nil) }

    /// One line per finished inbound job. Brief TEXT is never here — only its hash.
    private func log(_ j: InboundJob) {
        let o: [String: Any] = ["time": Int(now().timeIntervalSince1970), "jobId": j.req.jobId, "peer": j.peerLabel, "repo": j.req.repo,
                                "mode": j.req.mode.rawValue, "inboundMode": j.inboundMode.rawValue,
                                "briefSha256": SHA256.hash(data: Data(j.req.brief.utf8)).map { String(format: "%02x", $0) }.joined(),
                                "flags": j.flags, "status": j.status.rawValue]
        guard var line = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        line.append(10)
        let url = root.appendingPathComponent("jobs.jsonl")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        _ = line.withUnsafeBytes { Foundation.write(fd, $0.baseAddress!, $0.count) }
        close(fd)
    }

    /// A message was refused. One line, a reason code only — never the message's content.
    private func drop(_ reason: String) {
        lock.lock(); dropCount += 1; lock.unlock()
        let url = root.appendingPathComponent("drops.log")
        if let sz = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, sz > 256 * 1024 { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        let line = Data("\(Int(now().timeIntervalSince1970)) dropped: \(reason)\n".utf8)
        _ = line.withUnsafeBytes { Foundation.write(fd, $0.baseAddress!, $0.count) }
        close(fd)
    }

    // MARK: views for the UI / CLI

    func peerLinks() -> [PeerLink] { lock.lock(); defer { lock.unlock() }; return links }
    func inboundJobs() -> [InboundJob] { lock.lock(); defer { lock.unlock() }; return inbound.sorted { $0.received > $1.received } }
    func sentJobs() -> [SentJob] { lock.lock(); defer { lock.unlock() }; return sent.sorted { $0.created > $1.created } }
    func outboxCount() -> Int { lock.lock(); defer { lock.unlock() }; return outbox.count }
    func liveInviteCount() -> Int { lock.lock(); defer { lock.unlock() }; return invites.filter { !$0.used && $0.expires > now() }.count }

    // MARK: relay wanted

    private func computeWanted() -> Bool {
        !links.isEmpty || !outbox.isEmpty || invites.contains { !$0.used && $0.expires > now() }
    }

    private func updateWanted() {
        lock.lock(); let w = computeWanted(); let same = lastWanted == w; lastWanted = w; lock.unlock()
        if !same { transport.setWanted(w) }
    }

    private func scheduleWantedCheck(at date: Date) {
        scheduler(max(1, date.timeIntervalSince(now()) + 1)) { [weak self] in
            self?.updateWanted(); self?.changed()
        }
    }

    // MARK: pairing

    /// Inviter: a one-use, 24-hour invite string to send to one person.
    func invite() -> String {
        let secret = PeerCrypto.randomBytes(16)
        let exp = now().addingTimeInterval(Self.inviteLife)
        lock.lock()
        invites.removeAll { $0.used || $0.expires <= now() }
        invites.append(PendingInvite(secretHash: PeerCrypto.sha256Hex(secret), expires: exp, used: false))
        saveInvites()
        lock.unlock()
        scheduleWantedCheck(at: exp)
        updateWanted()
        changed()
        let k = identity.keys
        return PeerInvite(mailboxId: identity.mailboxId, kaPub: k.ka, signPub: k.sign, secret: secret).string
    }

    /// Joiner: pin the inviter's keys FROM THE INVITE and send a sealed pair-request. `label` is what we call them.
    func pairWithInvite(_ raw: String, label: String) -> Result<PeerLink, PeerError> {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inv = PeerInvite.parse(raw) else { return .failure(.invalid("That doesn't look like an invite")) }
        guard !name.isEmpty, name.count <= PeerValidate.maxLabel, !PeerValidate.hasBadControl(name), !name.contains("\n") else {
            return .failure(.invalid("Give them a name"))
        }
        guard inv.mailboxId != identity.mailboxId else { return .failure(.invalid("That invite is from this Mac")) }
        let k = identity.keys
        let payload: [String: Any] = ["t": "pair-request", "secret": PeerB64.std(inv.secret), "label": ownName,
                                      "sp": PeerB64.std(k.sign), "ka": PeerB64.std(k.ka)]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .failure(.invalid("bad request")) }
        let id = UUID().uuidString.lowercased()
        guard let blob = PeerSeal.seal(payload: body, id: id, now: now(), from: identity, to: inv.keys, introduce: true) else {
            return .failure(.invalid("Couldn't seal the request"))
        }
        let link = PeerLink(label: name, mailboxId: inv.mailboxId, keys: inv.keys, confirmed: false, created: now())
        lock.lock()
        links.removeAll { $0.mailboxId == link.mailboxId || $0.label.lowercased() == name.lowercased() }
        links.append(link); saveLinks()
        lock.unlock()
        enqueue(OutboxItem(id: id, jobId: nil, to: inv.mailboxId, blob: blob, attempt: 0, nextAt: now(), owner: inv.mailboxId))
        changed()
        return .success(link)
    }

    /// Revoke: delete the pinned keys, drop that peer's queued work, and tell them (best effort).
    func revoke(mailboxId: String) {
        lock.lock()
        guard let link = links.first(where: { $0.mailboxId == mailboxId }) else { lock.unlock(); return }
        links.removeAll { $0.mailboxId == mailboxId }
        saveLinks()
        let dropped = outbox.filter { $0.owner == mailboxId }
        outbox.removeAll { $0.owner == mailboxId }
        for d in dropped { try? FileManager.default.removeItem(at: outboxURL(d.id)) }
        for i in inbound.indices where inbound[i].peerMailbox == mailboxId && inbound[i].status == .queued {
            inbound[i].status = .declined; inbound[i].note = "Peer removed"; inbound[i].finished = now(); log(inbound[i])
        }
        saveInbound()
        for i in sent.indices where sent[i].peerMailbox == mailboxId && !sent[i].status.isFinal {
            sent[i].status = .failed; sent[i].note = "Peer removed"; sent[i].updated = now()
        }
        saveSent()
        lock.unlock()
        if let body = try? JSONSerialization.data(withJSONObject: ["t": "unpair"]) {
            let id = UUID().uuidString.lowercased()
            if let blob = PeerSeal.seal(payload: body, id: id, now: now(), from: identity, to: link.keys) {
                enqueue(OutboxItem(id: id, jobId: nil, to: mailboxId, blob: blob, attempt: 0, nextAt: now(), owner: nil))
            }
        }
        updateWanted()
        changed()
    }

    func revoke(label: String) {
        lock.lock(); let m = links.first { $0.label.lowercased() == label.lowercased() }?.mailboxId; lock.unlock()
        if let m { revoke(mailboxId: m) }
    }

    // MARK: sealed sending

    /// Seal a payload to a pinned peer and put it in the outbox.
    @discardableResult
    private func sealAndQueue(_ payload: [String: Any], to link: PeerLink, jobId: String? = nil, owner: String?) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let id = UUID().uuidString.lowercased()
        guard let blob = PeerSeal.seal(payload: body, id: id, now: now(), from: identity, to: link.keys) else { return false }
        enqueue(OutboxItem(id: id, jobId: jobId, to: link.mailboxId, blob: blob, attempt: 0, nextAt: now(), owner: owner))
        return true
    }

    // MARK: sender

    /// Hand a job to a paired peer. `repo` is a local path or a git remote URL. Returns the jobId.
    func delegate(peer: String, repo: String, title: String, brief: String, base: String = "main", mode: PeerMode = .pane,
                  fromAgent: String = "agent") -> Result<String, PeerError> {
        lock.lock(); let link = links.first { $0.label.lowercased() == peer.lowercased() }; lock.unlock()
        guard let link else { return .failure(.invalid("No peer named \(peer)")) }
        var remote = repo
        if repo.hasPrefix("/") || repo.hasPrefix("~") || repo.hasPrefix(".") {
            let path = (repo as NSString).expandingTildeInPath
            guard let r = launcher.remoteURL(ofRepoAt: path) else { return .failure(.invalid("That folder has no git origin")) }
            remote = r
        }
        let id = UUID().uuidString.lowercased()
        let req: [String: Any] = ["t": "job", "jobId": id, "title": title, "brief": brief, "repo": remote, "base": base,
                                  "mode": mode.rawValue, "fromAgent": fromAgent]
        guard let check = try? JSONSerialization.data(withJSONObject: req) else { return .failure(.invalid("bad job")) }
        if case .failure(let e) = PeerValidate.parseJob(check) { return .failure(e) }
        let t = now()
        let job = SentJob(jobId: id, peerLabel: link.label, peerMailbox: link.mailboxId, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          repo: remote, base: base, mode: mode, fromAgent: fromAgent,
                          status: .queued, note: "Sending", branch: nil, sha: nil, result: nil, created: t, updated: t)
        lock.lock(); sent.append(job); saveSent(); lock.unlock()
        guard sealAndQueue(req, to: link, jobId: id, owner: link.mailboxId) else {
            lock.lock()
            sent.removeAll { $0.jobId == id }; saveSent()
            lock.unlock()
            return .failure(.invalid("That job is too large to send"))
        }
        changed()
        return .success(id)
    }

    func status(jobId: String?) -> [SentJob] { sentJobs().filter { jobId == nil || $0.jobId == jobId } }
    func result(jobId: String) -> SentJob? { sentJobs().first { $0.jobId == jobId } }

    private func receiveEvent(_ ev: PeerEvent, from mailbox: String) {
        lock.lock()
        guard let i = sent.firstIndex(where: { $0.jobId == ev.jobId }), sent[i].peerMailbox == mailbox else {
            lock.unlock(); drop("event for a job not sent to this peer"); return
        }
        if !sent[i].status.isFinal {
            sent[i].status = ev.status; sent[i].note = ev.note; sent[i].updated = now()
            if let b = ev.branch { sent[i].branch = b }
            if let s = ev.sha { sent[i].sha = s }
            if let r = ev.result { sent[i].result = r }
            saveSent()
        }
        let j = sent[i]
        lock.unlock()
        changed()
        if j.status == .done || j.status == .failed, ev.status == j.status {
            let branch = j.branch ?? PeerNaming.branch(label: j.peerLabel, jobId: j.jobId)
            launcher.deliverLine(agent: j.fromAgent, line: PeerText.doneLine(label: j.peerLabel, title: j.title, status: j.status, branch: branch,
                                                                              resultPath: "true-peer result \(j.jobId)"))
        }
    }

    // MARK: outbox

    private func enqueue(_ item: OutboxItem) {
        lock.lock(); outbox.append(item); saveOutbox(item); lock.unlock()
        updateWanted()
        net.async { [self] in pump() }
    }

    /// Try everything due now; schedule one timer for the earliest of the rest. No items → no timer.
    func pump() {
        while true {
            lock.lock()
            let due = outbox.filter { $0.nextAt <= now() }.sorted { $0.nextAt < $1.nextAt }.first
            lock.unlock()
            guard let item = due else { break }
            let r = transport.send(to: item.to, id: item.id, blob: item.blob)
            lock.lock()
            guard let idx = outbox.firstIndex(where: { $0.id == item.id }) else { lock.unlock(); continue }   // revoked meanwhile
            switch r {
            case .delivered:
                outbox.remove(at: idx); try? FileManager.default.removeItem(at: outboxURL(item.id))
                if let jid = item.jobId, let s = sent.firstIndex(where: { $0.jobId == jid }), sent[s].status == .queued {
                    sent[s].note = "Delivered"; sent[s].updated = now(); saveSent()
                }
            case .retry:
                outbox[idx].nextAt = now().addingTimeInterval(PeerBackoff.delay(attempt: item.attempt))
                outbox[idx].attempt += 1
                saveOutbox(outbox[idx])
            case .refused:
                outbox.remove(at: idx); try? FileManager.default.removeItem(at: outboxURL(item.id))
                if let jid = item.jobId, let s = sent.firstIndex(where: { $0.jobId == jid }), !sent[s].status.isFinal {
                    sent[s].status = .failed; sent[s].updated = now(); sent[s].note = "The relay refused this job"; saveSent()
                }
            }
            lock.unlock()
            changed()
            if r == .retry { break }       // not connected / full: the rest would fail the same way; wait for the timer or a reconnect
        }
        updateWanted()
        lock.lock()
        let next = outbox.map(\.nextAt).min()
        let pending = timerAt
        lock.unlock()
        guard let next else { lock.lock(); timerAt = nil; lock.unlock(); return }
        if let pending, pending <= next, pending > now() { return }
        lock.lock(); timerAt = next; lock.unlock()
        scheduler(max(1, next.timeIntervalSince(now()))) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.timerAt = nil; self.lock.unlock()
            self.net.async { self.pump() }
        }
    }

    /// The relay just connected: anything stuck goes out now.
    func flush() {
        lock.lock()
        for i in outbox.indices { outbox[i].nextAt = now() }
        lock.unlock()
        net.async { [self] in pump() }
    }

    // MARK: receiving

    private func pinned(_ mailbox: String) -> PeerKeys? {
        lock.lock(); defer { lock.unlock() }
        return links.first { $0.mailboxId == mailbox }?.keys
    }

    /// Everything that arrives from the relay lands here. Anything that fails a check is dropped with one log line.
    func receive(_ blob: Data) {
        switch PeerSeal.open(blob, me: identity, now: now(), pinned: { self.pinned($0) }) {
        case .failure(let d): drop("\(d)")
        case .success(let o):
            let t = Int(now().timeIntervalSince1970)
            lock.lock()
            let replay = seen[o.envelope.id] != nil
            if !replay {
                seen = seen.filter { $0.value > t }
                seen[o.envelope.id] = t + Int(Self.seenLife)
                saveSeen()
            }
            lock.unlock()
            if replay { drop("replay"); return }
            guard let obj = (try? JSONSerialization.jsonObject(with: o.payload)) as? [String: Any], let kind = obj["t"] as? String else {
                drop("payload"); return
            }
            if !o.pinned && kind != "pair-request" { drop("unknown sender"); return }
            switch kind {
            case "pair-request": if o.pinned { drop("pair-request from a paired peer") } else { handlePairRequest(obj, sender: o.sender) }
            case "pair-accept": handlePairAccept(from: o.envelope.from)
            case "job": handleJob(o.payload, from: o.envelope.from)
            case "event": if let ev = PeerEvent.parse(obj) { receiveEvent(ev, from: o.envelope.from) } else { drop("event payload") }
            case "unpair": handleUnpair(from: o.envelope.from)
            default: drop("unknown kind")
            }
        }
    }

    private func handlePairRequest(_ obj: [String: Any], sender: PeerKeys) {
        guard let s = (obj["secret"] as? String).flatMap(PeerB64.fromStd), s.count == 16,
              let sp = (obj["sp"] as? String).flatMap(PeerB64.fromStd), let ka = (obj["ka"] as? String).flatMap(PeerB64.fromStd),
              sp == sender.sign, ka == sender.ka else { drop("pair-request payload"); return }
        let hash = Data(PeerCrypto.sha256Hex(s).utf8)
        let t = now()
        lock.lock()
        // Walk every invite (no early exit) so timing doesn't say which one matched.
        var hit: Int?
        for (i, inv) in invites.enumerated() where PeerCrypto.constantTimeEqual(Data(inv.secretHash.utf8), hash) && !inv.used && inv.expires > t {
            hit = i
        }
        guard let h = hit else { lock.unlock(); drop("pair-request secret"); return }
        invites.remove(at: h); saveInvites()
        var label = ((obj["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty || label.count > PeerValidate.maxLabel || PeerValidate.hasBadControl(label) || label.contains("\n") { label = "Peer" }
        let base = label
        var n = 2
        while links.contains(where: { $0.label.lowercased() == label.lowercased() }) { label = "\(base) \(n)"; n += 1 }
        let link = PeerLink(label: label, mailboxId: sender.mailboxId, keys: sender, confirmed: true, created: t)
        links.removeAll { $0.mailboxId == link.mailboxId }
        links.append(link); saveLinks()
        lastPaired = label
        lock.unlock()
        sealAndQueue(["t": "pair-accept", "name": ownName], to: link, owner: link.mailboxId)
        updateWanted()
        changed()
    }

    private func handlePairAccept(from mailbox: String) {
        lock.lock()
        guard let i = links.firstIndex(where: { $0.mailboxId == mailbox }) else { lock.unlock(); return }
        links[i].confirmed = true; saveLinks()
        lastPaired = links[i].label
        lock.unlock()
        changed()
    }

    private func handleUnpair(from mailbox: String) {
        lock.lock()
        links.removeAll { $0.mailboxId == mailbox }; saveLinks()
        let dropped = outbox.filter { $0.owner == mailbox }
        outbox.removeAll { $0.owner == mailbox }
        for d in dropped { try? FileManager.default.removeItem(at: outboxURL(d.id)) }
        for i in inbound.indices where inbound[i].peerMailbox == mailbox && inbound[i].status == .queued {
            inbound[i].status = .declined; inbound[i].note = "Peer removed"; inbound[i].finished = now(); log(inbound[i])
        }
        saveInbound()
        for i in sent.indices where sent[i].peerMailbox == mailbox && !sent[i].status.isFinal {
            sent[i].status = .failed; sent[i].note = "Peer removed"; sent[i].updated = now()
        }
        saveSent()
        lock.unlock()
        updateWanted()
        changed()
    }

    private func handleJob(_ payload: Data, from mailbox: String) {
        guard case .success(let job) = PeerValidate.parseJob(payload) else { drop("job payload"); return }
        lock.lock(); let link = links.first { $0.mailboxId == mailbox }; lock.unlock()
        guard let link else { drop("job from unknown peer"); return }
        receiveJob(job, from: link)
    }

    private func receiveJob(_ job: PeerJobRequest, from link: PeerLink) {
        lock.lock()
        if inbound.contains(where: { $0.req.jobId == job.jobId }) { lock.unlock(); drop("job id seen"); return }
        let mode = inboundMode()
        let screened = InjectionScreen.screen(job.title + "\n" + job.brief)
        let j = InboundJob(req: job, peerLabel: link.label, peerMailbox: link.mailboxId, status: mode == .ask ? .queued : .accepted,
                           note: mode == .ask ? "Waiting for you" : "Starting", inboundMode: mode, flags: screened.reasons,
                           received: now(), finished: nil, branch: PeerNaming.branch(label: link.label, jobId: job.jobId))
        inbound.append(j); saveInbound()
        lock.unlock()
        let dir = jobDir(job.jobId)
        Self.write(Data(job.brief.utf8), to: dir.appendingPathComponent("brief.md"))
        Self.write((try? Self.enc().encode(j)) ?? Data(), to: dir.appendingPathComponent("job.json"))
        changed()
        if mode == .ask {
            report(j, .needsYou, "Waiting for them to accept")
        } else {
            work.async { [self] in run(job.jobId, flags: mode.claudeFlags) }
        }
    }

    private func update(_ jobId: String, _ f: (inout InboundJob) -> Void) -> InboundJob? {
        lock.lock(); defer { lock.unlock() }
        guard let i = inbound.firstIndex(where: { $0.req.jobId == jobId }) else { return nil }
        f(&inbound[i]); saveInbound()
        return inbound[i]
    }

    func accept(_ jobId: String) {
        guard let j = inboundJobs().first(where: { $0.id == jobId }), j.status == .queued else { return }
        _ = update(jobId) { $0.status = .accepted; $0.note = "Starting" }
        changed()
        work.async { [self] in run(jobId, flags: PeerInboundMode.ask.claudeFlags) }
    }

    func decline(_ jobId: String) {
        guard let j = inboundJobs().first(where: { $0.id == jobId }), j.status == .queued else { return }
        end(jobId, .declined, "Declined", reportAs: .failed)
    }

    private func run(_ jobId: String, flags: [String]) {
        guard let j = inboundJobs().first(where: { $0.id == jobId }), !j.status.isFinal else { return }
        let label = j.peerLabel
        guard let clone = launcher.resolveClone(repo: j.req.repo) else {
            end(jobId, .failed, "No local clone of \(j.req.repo)", reportAs: .failed); return
        }
        let wt = PeerNaming.worktree(clone: clone, jobId: jobId)
        if let err = launcher.prepareWorktree(clone: clone, base: j.req.base, branch: j.branch, worktree: wt) {
            end(jobId, .failed, err, reportAs: .failed); return
        }
        let dir = jobDir(jobId)
        let resultP = resultPath(jobId)
        let envelope = PeerText.envelope(label: label, job: j.req, branch: j.branch, worktree: wt, resultPath: resultP)
        let role = PeerText.roleCard(label: label, branch: j.branch, worktree: wt, resultPath: resultP)
        Self.write(Data(envelope.utf8), to: dir.appendingPathComponent("envelope.md"))
        Self.write(Data(role.utf8), to: dir.appendingPathComponent("role.md"))
        let name = PeerNaming.agentName(label: label, jobId: jobId)
        var pane: UUID?, builder: String?
        switch PeerMode.effective(requested: j.req.mode, inboundFlags: flags, builderInstalled: launcher.canRunBackground) {
        case .pane:
            pane = launcher.launchPane(agentName: name, label: label, cwd: wt, flags: flags, rolePath: dir.appendingPathComponent("role.md").path,
                                       firstPrompt: PeerText.firstPrompt(envelopePath: dir.appendingPathComponent("envelope.md").path))
            if pane == nil { end(jobId, .failed, "Couldn't open a tab for the job", reportAs: .failed); return }
        case .background:
            if let err = launcher.launchBackground(agentName: name, parent: PeerNaming.parentName(label: label), cwd: wt,
                                                   prompt: PeerText.firstPrompt(envelopePath: dir.appendingPathComponent("envelope.md").path)) {
                end(jobId, .failed, err, reportAs: .failed); return
            }
            builder = name
        }
        if let u = update(jobId, { $0.clone = clone; $0.worktree = wt; $0.pane = pane; $0.builder = builder; $0.note = "Started" }) {
            report(u, .accepted, "Started")
        }
        changed()
    }

    // MARK: receiver — hook events

    /// A pane hook fired. Report only when the status actually changes; final states are sticky.
    func paneEvent(pane: UUID, kind: PeerEventMap.Kind) {
        lock.lock(); let j = inbound.first { $0.pane == pane && !$0.status.isFinal }; lock.unlock()
        guard let j else { return }
        let exists = FileManager.default.fileExists(atPath: resultPath(j.id))
        guard let s = PeerEventMap.status(kind, resultExists: exists), s != j.status else { return }
        if s == .done || s == .failed { end(j.id, s, s == .done ? "Finished" : "Hit an error", reportAs: s); return }
        if let u = update(j.id, { $0.status = s; $0.note = s == .working ? "Working" : s == .needsYou ? "Needs you" : "Waiting" }) {
            report(u, s, u.note)
        }
        changed()
    }

    func paneClosed(pane: UUID) {
        lock.lock(); let j = inbound.first { $0.pane == pane && !$0.status.isFinal }; lock.unlock()
        guard let j else { return }
        if FileManager.default.fileExists(atPath: resultPath(j.id)) { end(j.id, .done, "Finished", reportAs: .done) }
        else { end(j.id, .failed, "Closed before it finished", reportAs: .failed) }
    }

    /// Builder state changed (the Hub's builder list). `running == false` means it ended.
    func builderUpdate(name: String, running: Bool) {
        lock.lock(); let j = inbound.first { $0.builder == name && !$0.status.isFinal }; lock.unlock()
        guard let j else { return }
        if running {
            guard j.status != .working else { return }
            if let u = update(j.id, { $0.status = .working; $0.note = "Working" }) { report(u, .working, "Working") }
            changed()
        } else if FileManager.default.fileExists(atPath: resultPath(j.id)) {
            end(j.id, .done, "Finished", reportAs: .done)
        } else {
            end(j.id, .failed, "Ended without a result", reportAs: .failed)
        }
    }

    // MARK: receiver — finishing

    private func end(_ jobId: String, _ status: PeerStatus, _ note: String, reportAs: PeerStatus) {
        guard let u = update(jobId, { $0.status = status; $0.note = note; $0.finished = now() }) else { return }
        var final = u
        if status == .done, let wt = u.worktree, let sha = launcher.headSHA(worktree: wt) {
            final = update(jobId) { $0.sha = sha } ?? u
        }
        log(final)
        report(final, reportAs, note)
        changed()
    }


    private func report(_ j: InboundJob, _ s: PeerStatus, _ note: String) {
        var o: [String: Any] = ["t": "event", "jobId": j.req.jobId, "status": s.rawValue, "note": String(note.prefix(PeerValidate.maxNote))]
        if s == .done || s == .failed { o["branch"] = j.branch }
        if s == .done {
            if let sha = j.sha { o["sha"] = sha }
            if let d = try? Data(contentsOf: URL(fileURLWithPath: resultPath(j.id))) {
                o["result"] = String(String(decoding: d.prefix(PeerValidate.maxResult * 2), as: UTF8.self).prefix(PeerValidate.maxResult))
            }
        }
        lock.lock(); let link = links.first { $0.mailboxId == j.peerMailbox }; lock.unlock()
        guard let link else { return }       // revoked: nobody to tell
        sealAndQueue(o, to: link, owner: link.mailboxId)
    }

    // MARK: kill switch

    /// End every running peer job cleanly (panes closed, builders stopped) and decline the waiting ones.
    func stopAll() {
        lock.lock()
        let live = inbound.filter { !$0.status.isFinal }
        lock.unlock()
        launcher.stop(panes: live.compactMap(\.pane), builders: live.compactMap(\.builder))
        for j in live { end(j.id, j.status == .queued ? .declined : .failed, "Stopped on this Mac", reportAs: .failed) }
    }
}
