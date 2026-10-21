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
    let ownName: String
    private let steering: @Sendable () -> Bool
    private let share: @Sendable () -> PeerShare
    private let allowedDirs: @Sendable () -> [String]
    private let chatOn: @Sendable () -> Bool
    // Run 34 — Shared projects
    private let sharedRepos: @Sendable () -> [String: [SharedRepo]]
    private let setSharedRepos: @Sendable ([String: [SharedRepo]]) -> Void
    /// Where accepted repos are cloned: `<projectsRoot>/<slug>.peers/<peer-slug>`.
    private let projectsRoot: String
    private var offers: [PeerOffer]

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
    // Run 30 — Drive
    private var batchers: [String: PeerBatcher] = [:]
    private var activitySeq: [String: Int] = [:]
    private var flushScheduled: Set<String> = []
    private var heldSays: [String: [String]] = [:]
    private var prompting: Set<UUID> = []
    private var activityCache: [String: [PeerActivityItem]] = [:]
    static let activityKeep = 200
    // Run 32 — Channels
    /// The local channel store + delivery. Set by the app (PeerService) and by tests; nil = chat not running.
    var chat: ChatBus?
    private var chatPending: [String: [[String: Any]]] = [:]
    private var chatFlushArmed: Set<String> = []
    private var chatSlots: [String: [Date]] = [:]
    private var chatNacked: [String: Date] = [:]
    static let chatBatchDelay: TimeInterval = 0.3
    static let chatPerMinute = 20
    static let chatBatchItems = 8
    /// Set when someone finished pairing with us ("Paired with <label>"); the Peers sheet shows it.
    private(set) var lastPaired: String?
    private(set) var dropCount = 0
    /// Called once for each new inbound job, after it is stored (the app posts the macOS notification from here).
    var onJobArrived: (@Sendable (InboundJob) -> Void)?

    static let inviteLife: TimeInterval = 24 * 3600
    static let seenLife: TimeInterval = 8 * 24 * 3600

    init(root: URL = PeerEngine.standardRoot, identity: PeerIdentity, launcher: PeerLauncher, transport: PeerTransport,
         inboundMode: @escaping @Sendable () -> PeerInboundMode = { PeerInboundMode.current },
         ownName: String = Host.current().localizedName ?? "True",
         steering: @escaping @Sendable () -> Bool = { PeerSettings.steering },
         share: @escaping @Sendable () -> PeerShare = { PeerSettings.share },
         allowedDirs: @escaping @Sendable () -> [String] = { PeerSettings.allowedDirs },
         chatOn: @escaping @Sendable () -> Bool = { PeerSettings.chat },
         sharedRepos: @escaping @Sendable () -> [String: [SharedRepo]] = { PeerSettings.sharedRepos },
         setSharedRepos: @escaping @Sendable ([String: [SharedRepo]]) -> Void = { PeerSettings.sharedRepos = $0 },
         projectsRoot: String = NSHomeDirectory() + "/Projects",
         now: @escaping @Sendable () -> Date = { Date() },
         scheduler: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil) {
        self.root = root; self.identity = identity; self.launcher = launcher; self.transport = transport
        self.inboundMode = inboundMode; self.steering = steering; self.share = share; self.allowedDirs = allowedDirs; self.chatOn = chatOn; self.sharedRepos = sharedRepos; self.setSharedRepos = setSharedRepos; self.projectsRoot = projectsRoot; self.now = now; self.ownName = String(ownName.prefix(PeerValidate.maxLabel))
        let q = DispatchQueue(label: "true.peers.timer")
        self.scheduler = scheduler ?? { d, f in q.asyncAfter(deadline: .now() + d, execute: f) }
        links = PeerEngine.load(root.appendingPathComponent("peers.json")) ?? []
        inbound = PeerEngine.load(root.appendingPathComponent("inbound.json")) ?? []
        sent = PeerEngine.load(root.appendingPathComponent("sent.json")) ?? []
        invites = PeerEngine.load(root.appendingPathComponent("invites.json")) ?? []
        seen = PeerEngine.load(root.appendingPathComponent("seen.json")) ?? [:]
        outbox = PeerEngine.loadOutbox(root)
        offers = PeerEngine.load(root.appendingPathComponent("offers.json")) ?? []
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
    private func saveOffers() { Self.write((try? Self.enc().encode(offers)) ?? Data(), to: root.appendingPathComponent("offers.json")) }
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
    private func sealAndQueue(_ payload: [String: Any], to link: PeerLink, jobId: String? = nil, owner: String?, at: Date? = nil) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let id = UUID().uuidString.lowercased()
        guard let blob = PeerSeal.seal(payload: body, id: id, now: now(), from: identity, to: link.keys) else { return false }
        enqueue(OutboxItem(id: id, jobId: jobId, to: link.mailboxId, blob: blob, attempt: 0, nextAt: at ?? now(), owner: owner))
        return true
    }

    // MARK: Run 34 — shared projects

    private static let sharedSeat = "shared"

    func pendingOffers() -> [PeerOffer] { lock.lock(); defer { lock.unlock() }; return offers.sorted { $0.created > $1.created } }
    /// Accepted shares, newest peer first by label: (peer label, mailbox, repo).
    func shares() -> [(peer: String, mailbox: String, repo: SharedRepo)] {
        let ls = peerLinks()
        return sharedRepos().flatMap { mb, rs in rs.map { (peer: ls.first { $0.mailboxId == mb }?.label ?? "Unknown peer", mailbox: mb, repo: $0) } }
            .sorted { ($0.peer, $0.repo.slug) < ($1.peer, $1.repo.slug) }
    }

    private func joinRoom(_ slug: String) {
        guard let bus = chat else { return }
        bus.registerSeat(Self.sharedSeat) { _ in }      // the room is a record; no pane is typed into
        _ = bus.join(Self.sharedSeat, "#" + slug)
    }

    private func setOffer(_ id: String, _ f: (inout PeerOffer) -> Void) -> PeerOffer? {
        lock.lock(); defer { lock.unlock() }
        guard let i = offers.firstIndex(where: { $0.id == id }) else { return nil }
        f(&offers[i]); saveOffers()
        return offers[i]
    }

    /// Offer a repo (by URL) to a paired peer. They must accept before anything is cloned.
    func offer(peer: String, url rawURL: String, name rawName: String = "", note rawNote: String = "") -> Result<String, PeerError> {
        lock.lock(); let link = links.first { $0.label.lowercased() == peer.lowercased() }; lock.unlock()
        guard let link else { return .failure(.invalid("No peer named \(peer)")) }
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PeerRepo.normalize(url) != nil else { return .failure(.invalid("That isn't a git repo URL")) }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (PeerRepo.name(url) ?? "") : rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PeerShareRules.slug(name: name) != nil else { return .failure(.invalid("Give the project a short plain name")) }
        let note = String(rawNote.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PeerShareRules.maxNote))
        guard !PeerValidate.hasBadControl(note) else { return .failure(.invalid("The note has odd characters")) }
        let id = UUID().uuidString.lowercased()
        let o = PeerOffer(id: id, url: url, name: name, note: note, peerLabel: link.label, peerMailbox: link.mailboxId, incoming: false,
                          status: .pending, reason: "", created: now())
        lock.lock(); offers.append(o); saveOffers(); lock.unlock()
        guard sealAndQueue(["t": "offer", "id": id, "url": url, "name": name, "note": note], to: link, owner: link.mailboxId) else {
            lock.lock(); offers.removeAll { $0.id == id }; saveOffers(); lock.unlock()
            return .failure(.invalid("That offer is too large to send"))
        }
        changed()
        return .success(id)
    }

    private func handleOffer(_ obj: [String: Any], from mailbox: String) {
        guard let l = link(mailbox), let id = obj["id"] as? String, !id.isEmpty, id.count <= 80 else { drop("offer payload"); return }
        if let why = obj["nack"] as? String {            // the peer said no (or the clone failed)
            lock.lock(); let mine = offers.first { $0.id == id && !$0.incoming && $0.peerMailbox == mailbox }; lock.unlock()
            guard mine != nil else { drop("offer reply for an unknown offer"); return }
            _ = setOffer(id) { $0.status = .declined; $0.reason = String(why.prefix(200)) }
            changed(); return
        }
        if obj["ack"] as? Bool == true {                 // they accepted and cloned: record the share on this side too
            lock.lock(); let mine = offers.first { $0.id == id && !$0.incoming && $0.peerMailbox == mailbox && $0.status == .pending }; lock.unlock()
            guard let mine, let slug = (obj["slug"] as? String).flatMap({ PeerShareRules.slug(name: $0) }) else { drop("offer reply for an unknown offer"); return }
            let path = launcher.resolveClone(repo: mine.url) ?? ""
            addShare(SharedRepo(url: mine.url, path: path, slug: slug), peer: mailbox)
            _ = setOffer(id) { $0.status = .accepted }
            changed(); return
        }
        guard let url = obj["url"] as? String, PeerRepo.normalize(url) != nil, url.count <= 300,
              let name = obj["name"] as? String, PeerShareRules.slug(name: name) != nil else { drop("offer payload"); return }
        let note = (obj["note"] as? String) ?? ""
        guard note.count <= PeerShareRules.maxNote, !PeerValidate.hasBadControl(note) else { drop("offer payload"); return }
        lock.lock()
        if offers.contains(where: { $0.id == id }) { lock.unlock(); drop("offer id seen"); return }
        offers.append(PeerOffer(id: id, url: url, name: name.trimmingCharacters(in: .whitespacesAndNewlines), note: note, peerLabel: l.label,
                                peerMailbox: mailbox, incoming: true, status: .pending, reason: "", created: now()))
        saveOffers(); lock.unlock()
        changed()
    }

    private func addShare(_ r: SharedRepo, peer mailbox: String) {
        lock.lock()
        var all = sharedRepos()
        var mine = all[mailbox] ?? []
        mine.removeAll { $0.slug == r.slug }
        mine.append(r); all[mailbox] = mine
        setSharedRepos(all)
        lock.unlock()
        joinRoom(r.slug)
    }

    /// The owner clicked Accept: clone with their own credentials, then record + ack. A failure is shown on the card; nothing is recorded.
    func acceptOffer(_ id: String) {
        lock.lock(); let o = offers.first { $0.id == id && $0.incoming && ($0.status == .pending || $0.status == .failed) }; lock.unlock()
        guard let o else { return }
        _ = setOffer(id) { $0.status = .cloning; $0.reason = "" }
        changed()
        work.async { [self] in
            let slug = PeerShareRules.slug(name: o.name) ?? "project"
            let path = projectsRoot + "/\(slug).peers/\(PeerNaming.slug(o.peerLabel))"
            if let err = launcher.cloneRepo(url: o.url, into: path) {
                _ = setOffer(id) { $0.status = .failed; $0.reason = err }
                changed(); return
            }
            addShare(SharedRepo(url: o.url, path: path, slug: slug), peer: o.peerMailbox)
            _ = setOffer(id) { $0.status = .accepted }
            if let l = link(o.peerMailbox) { sealAndQueue(["t": "offer", "id": id, "ack": true, "slug": slug], to: l, owner: l.mailboxId) }
            changed()
        }
    }

    func declineOffer(_ id: String, reason: String = "Declined") {
        lock.lock(); let o = offers.first { $0.id == id && $0.incoming && ($0.status == .pending || $0.status == .failed) }; lock.unlock()
        guard let o else { return }
        _ = setOffer(id) { $0.status = .declined; $0.reason = reason }
        if let l = link(o.peerMailbox) { sealAndQueue(["t": "offer", "id": id, "nack": String(reason.prefix(200))], to: l, owner: l.mailboxId) }
        changed()
    }

    /// Drop a finished card from the list (accepted/declined/failed only).
    func dismissOffer(_ id: String) {
        lock.lock(); offers.removeAll { $0.id == id && $0.status != .pending && $0.status != .cloning }; saveOffers(); lock.unlock()
        changed()
    }

    /// Remove the allow-list entry and the room membership, never the clone on disk.
    func removeShare(mailbox: String, slug: String) {
        lock.lock()
        var all = sharedRepos()
        all[mailbox]?.removeAll { $0.slug == slug }
        if all[mailbox]?.isEmpty == true { all[mailbox] = nil }
        setSharedRepos(all)
        let stillUsed = all.values.contains { $0.contains { $0.slug == slug } }
        lock.unlock()
        if !stillUsed { chat?.leave(Self.sharedSeat, "#" + slug) }
        changed()
    }

    // MARK: sender

    /// Hand a job to a paired peer. `repo` is a local path or a git remote URL; empty = a job with no project. Returns the jobId.
    func delegate(peer: String, repo rawRepo: String = "", title: String, brief: String, base: String = "main", mode: PeerMode = .pane,
                  fromAgent: String = "agent", dir rawDir: String = "") -> Result<String, PeerError> {
        lock.lock(); let link = links.first { $0.label.lowercased() == peer.lowercased() }; lock.unlock()
        guard let link else { return .failure(.invalid("No peer named \(peer)")) }
        let repo = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = rawDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dir.isEmpty && !repo.isEmpty { return .failure(.invalid("Use either a repo or a directory, not both")) }
        if !dir.isEmpty && !PeerDirs.validRaw(dir) { return .failure(.invalid("A directory must be an absolute path (or start with ~/)")) }
        var remote = repo
        if repo.hasPrefix("/") || repo.hasPrefix("~") || repo.hasPrefix(".") {
            let path = (repo as NSString).expandingTildeInPath
            guard let r = launcher.remoteURL(ofRepoAt: path) else { return .failure(.invalid("That folder has no git origin")) }
            remote = r
        }
        let id = UUID().uuidString.lowercased()
        var req: [String: Any] = ["t": "job", "jobId": id, "title": title, "brief": brief, "base": base,
                                  "mode": mode.rawValue, "fromAgent": fromAgent]
        if !remote.isEmpty { req["repo"] = remote }   // older receivers drop a job whose repo is "", so omit it entirely
        let target: PeerTarget = dir.isEmpty ? .repo(repo: remote, base: base) : .dir(path: dir)
        if !dir.isEmpty { req["target"] = target.wire }
        guard let check = try? JSONSerialization.data(withJSONObject: req) else { return .failure(.invalid("bad job")) }
        if case .failure(let e) = PeerValidate.parseJob(check) { return .failure(e) }
        let t = now()
        let job = SentJob(jobId: id, peerLabel: link.label, peerMailbox: link.mailboxId, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          repo: remote, base: base, mode: mode, fromAgent: fromAgent,
                          status: .queued, note: "Sending", branch: nil, sha: nil, result: nil, created: t, updated: t, target: target)
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
            let branch = j.repo.isEmpty ? nil : (j.branch ?? PeerNaming.branch(label: j.peerLabel, jobId: j.jobId))
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
            case "say": handleSay(obj, from: o.envelope.from)
            case "stop": handleStop(obj, from: o.envelope.from)
            case "chat": if obj["nack"] is String { handleChatNack(obj, from: o.envelope.from) } else { handleChat(obj, from: o.envelope.from) }
            case "offer": handleOffer(obj, from: o.envelope.from)
            case "activity": if let a = PeerActivity.parse(obj) { receiveActivity(a, from: o.envelope.from) } else { drop("activity payload") }
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
        // Run 34: a job on a shared repo (repo or dir form) is always approved one by one, whatever the global mode says.
        let mode = onSharedRepo(job) ? PeerInboundMode.ask : inboundMode()
        let screened = InjectionScreen.screen(job.title + "\n" + job.brief)
        let j = InboundJob(req: job, peerLabel: link.label, peerMailbox: link.mailboxId, status: mode == .ask ? .queued : .accepted,
                           note: mode == .ask ? "Waiting for you" : "Starting", inboundMode: mode, flags: screened.reasons,
                           received: now(), finished: nil, branch: PeerNaming.branch(label: link.label, jobId: job.jobId), steering: steering())
        inbound.append(j); saveInbound()
        lock.unlock()
        let dir = jobDir(job.jobId)
        Self.write(Data(job.brief.utf8), to: dir.appendingPathComponent("brief.md"))
        Self.write((try? Self.enc().encode(j)) ?? Data(), to: dir.appendingPathComponent("job.json"))
        changed()
        onJobArrived?(j)
        if mode == .ask {
            report(j, .needsYou, "Waiting for them to accept")
        } else {
            work.async { [self] in run(job.jobId, flags: mode.claudeFlags) }
        }
    }

    private func onSharedRepo(_ job: PeerJobRequest) -> Bool {
        let all = sharedRepos().values.flatMap { $0 }
        switch PeerRun.choose(for: job) {
        case .repo: return PeerShareRules.repoIsShared(job.repo, shares: all)
        case .dir: return PeerShareRules.dirIsShared(job.dir ?? "", shares: all)
        case .scratch: return false
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
        let dir = jobDir(jobId)
        let resultP = resultPath(jobId)
        let clone: String?, wt: String, envelope: String, role: String
        switch PeerRun.choose(for: j.req) {
        case .repo:
            let shared = (sharedRepos()[j.peerMailbox] ?? []).first { PeerRepo.same($0.url, j.req.repo) && FileManager.default.fileExists(atPath: $0.path) }?.path
            guard let c = shared ?? launcher.resolveClone(repo: j.req.repo) else {
                end(jobId, .failed, "No local clone of \(j.req.repo)", reportAs: .failed); return
            }
            clone = c
            wt = PeerNaming.worktree(clone: c, jobId: jobId)
            if let err = launcher.prepareWorktree(clone: c, base: j.req.base, branch: j.branch, worktree: wt) {
                end(jobId, .failed, err, reportAs: .failed); return
            }
            envelope = PeerText.envelope(label: label, job: j.req, branch: j.branch, worktree: wt, resultPath: resultP)
            role = PeerText.roleCard(label: label, branch: j.branch, worktree: wt, resultPath: resultP)
        case .dir:
            switch PeerDirs.resolve(path: j.req.dir ?? "", allowed: allowedDirs() + (sharedRepos()[j.peerMailbox] ?? []).map(\.path).filter { !$0.isEmpty }) {
            case .failure(let e):
                if case .invalid(let m) = e { end(jobId, .failed, m, reportAs: .failed) } else { end(jobId, .failed, "Directory not allowed", reportAs: .failed) }
                return
            case .success(let real):
                clone = nil
                wt = real
                envelope = PeerText.envelopeDir(label: label, job: j.req, dir: real, resultPath: resultP)
                role = PeerText.roleCardDir(label: label, dir: real, resultPath: resultP)
            }
        case .scratch:
            let scratch = PeerNaming.scratch(jobDir: dir)
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                end(jobId, .failed, "Couldn't make a work folder for the job", reportAs: .failed); return
            }
            clone = nil
            wt = scratch.path
            envelope = PeerText.envelopeNoRepo(label: label, job: j.req, workDir: wt, resultPath: resultP)
            role = PeerText.roleCardNoRepo(label: label, workDir: wt, resultPath: resultP)
        }
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
    func paneEvent(pane: UUID, kind: PeerEventMap.Kind, message: String = "", tool: String? = nil, detail: String? = nil) {
        lock.lock(); let j = inbound.first { $0.pane == pane && !$0.status.isFinal }; lock.unlock()
        guard let j else { return }
        trackPermissionPrompt(j, kind: kind, tool: tool)
        queueActivity(j, Self.items(kind: kind, message: message, tool: tool, detail: detail, at: now()))
        let exists = FileManager.default.fileExists(atPath: resultPath(j.id))
        guard let s = PeerEventMap.status(kind, resultExists: exists), s != j.status else { return }
        if s == .done || s == .failed { end(j.id, s, s == .done ? "Finished" : "Hit an error", reportAs: s); return }
        if let u = update(j.id, { $0.status = s; $0.note = s == .working ? "Working" : s == .needsYou ? "Needs you" : "Waiting" }) {
            report(u, s, u.note)
        }
        changed()
    }

    /// The condensed activity a hook event stands for: a tool name (+ first input line), the last assistant text, or a question.
    static func items(kind: PeerEventMap.Kind, message: String, tool: String?, detail: String?, at: Date) -> [PeerActivityItem] {
        let t = Int(at.timeIntervalSince1970)
        switch kind {
        case .progress:
            let name = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "prompt" else { return [] }
            let d = detail.map { PeerMask.firstLine($0) } ?? ""
            return [PeerActivityItem(t: t, kind: .tool, text: PeerMask.firstLine(d.isEmpty ? name : "\(name) · \(d)"))]
        case .stop:
            let text = PeerMask.text(message)
            return text.isEmpty ? [] : [PeerActivityItem(t: t, kind: .assistant, text: text)]
        case .need:
            let d = detail.map { PeerMask.firstLine($0) } ?? ""
            let text = PeerMask.text(d.isEmpty ? message : "\(message) — \(tool ?? ""): \(d)")
            return text.isEmpty ? [] : [PeerActivityItem(t: t, kind: .question, text: text)]
        case .error, .other: return []
        }
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
        if status == .done, u.req.hasRepo, let wt = u.worktree, let sha = launcher.headSHA(worktree: wt) {
            final = update(jobId) { $0.sha = sha } ?? u
        }
        log(final)
        report(final, reportAs, note)
        lock.lock(); heldSays[jobId] = nil; if let p = final.pane { prompting.remove(p) }; lock.unlock()
        changed()
    }


    private func report(_ j: InboundJob, _ s: PeerStatus, _ note: String) {
        var o: [String: Any] = ["t": "event", "jobId": j.req.jobId, "status": s.rawValue, "note": String(note.prefix(PeerValidate.maxNote))]
        if (s == .done || s == .failed) && j.req.hasRepo { o["branch"] = j.branch }
        if s == .done {
            if let sha = j.sha { o["sha"] = sha }
            if let d = try? Data(contentsOf: URL(fileURLWithPath: resultPath(j.id))) {
                o["result"] = String(String(decoding: d.prefix(PeerValidate.maxResult * 2), as: UTF8.self).prefix(PeerValidate.maxResult))
            }
        }
        queueActivity(j, [PeerActivityItem(t: Int(now().timeIntervalSince1970), kind: .status, text: PeerMask.text("\(s.rawValue): \(note)"))], final: s == .done || s == .failed)
        lock.lock(); let link = links.first { $0.mailboxId == j.peerMailbox }; lock.unlock()
        guard let link else { return }       // revoked: nobody to tell
        sealAndQueue(o, to: link, owner: link.mailboxId)
    }

    // MARK: receiver — say / stop / activity out (Run 30)

    private static let steerable: Set<PeerStatus> = [.accepted, .working, .needsYou, .idle]

    private func link(_ mailbox: String) -> PeerLink? { lock.lock(); defer { lock.unlock() }; return links.first { $0.mailboxId == mailbox } }

    private func inboundJob(_ jobId: String, from mailbox: String) -> InboundJob? {
        lock.lock(); defer { lock.unlock() }
        return inbound.first { $0.req.jobId == jobId && $0.peerMailbox == mailbox }
    }

    /// Tell the sender no, in the activity stream (a `nack` item), without waiting for the batcher.
    private func nack(_ j: InboundJob, _ why: String) {
        guard let l = link(j.peerMailbox) else { return }
        lock.lock()
        let seq = max((activitySeq[j.id] ?? 0) + 1, Int(now().timeIntervalSince1970)); activitySeq[j.id] = seq
        lock.unlock()
        let item = PeerActivityItem(t: Int(now().timeIntervalSince1970), kind: .nack, text: why)
        sealAndQueue(["t": "activity", "jobId": j.id, "seq": seq, "items": [item.wire]], to: l, owner: l.mailboxId)
    }

    private func trackPermissionPrompt(_ j: InboundJob, kind: PeerEventMap.Kind, tool: String?) {
        guard let pane = j.pane else { return }
        var release: [String] = []
        lock.lock()
        if kind == .need { if tool != nil { prompting.insert(pane) } }
        else { prompting.remove(pane); release = heldSays.removeValue(forKey: j.id) ?? [] }
        lock.unlock()
        for line in release { _ = launcher.deliverToPane(pane, line: line) }
    }

    private func handleSay(_ obj: [String: Any], from mailbox: String) {
        guard let say = PeerSay.parse(obj) else { drop("say payload"); return }
        guard let j = inboundJob(say.jobId, from: mailbox) else { drop("say for a job not from this peer"); return }
        guard Self.steerable.contains(j.status) else { nack(j, "job not running"); return }
        guard steering() else { nack(j, "steering off"); return }
        let flags = InjectionScreen.screen(say.text).reasons
        if !flags.isEmpty, let u = update(j.id, { $0.flags = Array(Set($0.flags + flags)).sorted() }) { log(u) }
        let line = "[from \(j.peerLabel)] " + say.text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
        if let pane = j.pane {
            lock.lock(); let held = prompting.contains(pane); lock.unlock()
            if held || launcher.atPermissionPrompt(pane: pane) {
                lock.lock(); heldSays[j.id, default: []].append(line); lock.unlock()      // delivered after the owner answers locally
            } else if !launcher.deliverToPane(pane, line: line) {
                nack(j, "job not running")
            }
        } else if let b = j.builder {
            let inbox = jobDir(j.id).appendingPathComponent("inbox.md")
            let old = (try? Data(contentsOf: inbox)) ?? Data()
            Self.write(old + Data((line + "\n\n").utf8), to: inbox)
            launcher.deliverLine(agent: b, line: "[from \(j.peerLabel)] a follow-up is waiting in \(inbox.path)")
        } else {
            nack(j, "job not running")
        }
        changed()
    }

    // MARK: Run 32 — Channels

    /// Post a line from a local agent/human. Stored + delivered locally through the bus; forwarded to the paired peer(s)
    /// the channel belongs to (`#<peer>` → that peer, `@agent@<peer>` → that peer, a named room → every peer, `#here` / `@agent` → nobody).
    func postChat(channel raw: String, agent: String, text: String, re: String? = nil, recordLocal: Bool = true) -> Result<ChatMessage, PeerError> {
        guard let bus = chat else { return .failure(.invalid("Chat isn't running")) }
        guard let addr = ChatNaming.split(raw) else { return .failure(.invalid("A channel looks like #name or @agent")) }
        let own = PeerNaming.slug(ownName)
        lock.lock(); let ls = links; lock.unlock()
        var targets: [PeerLink] = [], local = addr.channel, wire = addr.channel, localText = text, deliverLocal = true
        if addr.channel.hasPrefix("@") {
            if let mac = addr.mac, mac != own {
                guard let l = ls.first(where: { PeerNaming.slug($0.label) == mac }) else { return .failure(.invalid("No peer named \(mac)")) }
                targets = [l]; local = "#" + PeerNaming.slug(l.label); localText = "\(addr.channel) " + text; deliverLocal = false
            }
        } else if let l = ls.first(where: { "#" + PeerNaming.slug($0.label) == addr.channel }) {
            targets = [l]; wire = "#" + own
        } else if addr.channel != "#here" {
            targets = ls
        }
        let posted: ChatMessage?
        if recordLocal { posted = bus.post(channel: local, agent: agent, text: localText, re: re, deliver: deliverLocal) }
        else {   // the caller records its own version in the shared room
            let t = ChatNaming.clean(text)
            posted = t.isEmpty ? nil : ChatMessage(id: UUID().uuidString.lowercased(), ts: Int(now().timeIntervalSince1970), channel: local,
                                                   from: ChatSender(agent: agent, mac: bus.mac), text: t, re: re.map { String($0.prefix(80)) })
        }
        guard let m = posted else { return .failure(.invalid("Say something (a line of text)")) }
        let body = ChatNaming.clean(text)
        for l in targets {
            var item: [String: Any] = ["id": m.id + (targets.count > 1 ? ":" + String(l.mailboxId.prefix(6)) : ""), "ts": m.ts, "channel": wire,
                                       "from": ["agent": m.from.agent, "mac": own], "text": body]
            if let r = m.re { item["re"] = r }
            lock.lock(); chatPending[l.mailboxId, default: []].append(item); let arm = chatFlushArmed.insert(l.mailboxId).inserted; lock.unlock()
            if arm { let mb = l.mailboxId; scheduler(Self.chatBatchDelay) { [weak self] in self?.flushChat(mb) } }
        }
        changed()
        return .success(m)
    }

    /// Send what has coalesced for a peer (all peers when nil). The scheduler calls this 300 ms after the first line; tests call it directly.
    func flushChat(_ mailbox: String? = nil) {
        lock.lock()
        let boxes = mailbox.map { [$0] } ?? Array(chatPending.keys)
        var work: [(PeerLink, [[String: Any]])] = []
        for mb in boxes {
            chatFlushArmed.remove(mb)
            let items = chatPending.removeValue(forKey: mb) ?? []
            if !items.isEmpty, let l = links.first(where: { $0.mailboxId == mb }) { work.append((l, items)) }
        }
        lock.unlock()
        for (l, items) in work {
            var i = 0
            while i < items.count {
                let chunk = Array(items[i..<min(i + Self.chatBatchItems, items.count)]); i += Self.chatBatchItems
                sealAndQueue(["t": "chat", "items": chunk], to: l, owner: l.mailboxId, at: chatSlot(l.mailboxId))
            }
        }
    }

    /// When the next envelope to this peer may go: at most `chatPerMinute` per rolling minute, overflow keeps its order (never dropped).
    private func chatSlot(_ mailbox: String) -> Date {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        var slots = (chatSlots[mailbox] ?? []).filter { $0 > t.addingTimeInterval(-120) }
        var at = t
        let recent = slots.filter { $0 > t.addingTimeInterval(-60) }
        if recent.count >= Self.chatPerMinute { at = recent[recent.count - Self.chatPerMinute].addingTimeInterval(60.001) }
        if let last = slots.last, last > t, at <= last { at = last.addingTimeInterval(0.001) }
        slots.append(at); chatSlots[mailbox] = slots
        return at
    }

    private func handleChat(_ obj: [String: Any], from mailbox: String) {
        guard let l = link(mailbox) else { drop("chat from an unknown peer"); return }
        let raw = (obj["items"] as? [[String: Any]]) ?? [obj]
        guard !raw.isEmpty, raw.count <= 50 else { drop("chat payload"); return }
        guard chatOn() else {
            lock.lock()
            let due = chatNacked[mailbox].map { now().timeIntervalSince($0) >= 3600 } ?? true
            if due { chatNacked[mailbox] = now() }
            lock.unlock()
            if due { sealAndQueue(["t": "chat", "nack": "chat off"], to: l, owner: l.mailboxId) }
            return
        }
        guard let bus = chat else { return }
        let peerRoom = "#" + PeerNaming.slug(l.label), allLinks = peerLinks()
        for o in raw {
            guard let id = o["id"] as? String, !id.isEmpty, id.count <= 80, let text = o["text"] as? String, !text.isEmpty,
                  let wireChannel = o["channel"] as? String, let from = o["from"] as? [String: Any], let agent = from["agent"] as? String, !agent.isEmpty,
                  let channel = ChatNaming.normalize(wireChannel) else { drop("chat payload"); continue }
            let ts = (o["ts"] as? Int) ?? Int(now().timeIntervalSince1970)
            var local: String?
            if channel == peerRoom || channel == "#" + PeerNaming.slug((from["mac"] as? String) ?? "") { local = peerRoom }   // their own-name room IS our room with them
            else if channel.hasPrefix("@") { if bus.isSeat(String(channel.dropFirst())) { local = channel } }
            else if channel != "#here", !bus.members(channel).isEmpty,
                    !allLinks.contains(where: { "#" + PeerNaming.slug($0.label) == channel }) { local = channel }
            guard let dest = local else { drop("chat channel not authorised"); continue }
            let key = "chat:" + id
            lock.lock()
            let dup = seen[key] != nil
            if !dup { seen[key] = Int(now().timeIntervalSince1970) + Int(Self.seenLife); saveSeen() }
            lock.unlock()
            if dup { continue }
            bus.post(channel: dest, agent: String(agent.prefix(48)), mac: l.label, text: text, id: id, ts: ts, re: (o["re"] as? String).flatMap { $0.count <= 80 ? $0 : nil })
        }
        changed()
    }

    /// The other side has chat off: say so in the shared channel (a note for people, never typed into a pane).
    private func handleChatNack(_ obj: [String: Any], from mailbox: String) {
        guard let l = link(mailbox), let bus = chat else { return }
        bus.post(channel: "#" + PeerNaming.slug(l.label), agent: "true", text: "\(l.label) has chat turned off — they won't see these lines.", deliver: false)
        changed()
    }

    private func handleStop(_ obj: [String: Any], from mailbox: String) {
        guard let id = PeerStopRequest.parse(obj) else { drop("stop payload"); return }
        guard let j = inboundJob(id, from: mailbox) else { drop("stop for a job not from this peer"); return }
        guard !j.status.isFinal else { nack(j, "job not running"); return }
        guard steering() else { nack(j, "steering off"); return }
        launcher.stop(panes: j.pane.map { [$0] } ?? [], builders: j.builder.map { [$0] } ?? [])
        end(id, j.status == .queued ? .declined : .failed, "Stopped by sender", reportAs: .failed)
    }

    /// Add items to the job's outgoing batch; send when the batcher says so, else arm one timer.
    private func queueActivity(_ j: InboundJob, _ items: [PeerActivityItem], final: Bool = false) {
        if share() == .activity, !items.isEmpty {
            lock.lock()
            var b = batchers[j.id] ?? PeerBatcher()
            for it in items { b.add(it, at: now()) }
            batchers[j.id] = b
            lock.unlock()
        }
        flushActivity(j.id, force: final)
    }

    /// Send what is due for a job (tests call this after moving the clock).
    func flushActivity(_ jobId: String, force: Bool = false) {
        lock.lock()
        guard var b = batchers[jobId] else { lock.unlock(); return }
        let batch = b.take(at: now(), force: force)
        let nextAt = force ? nil : b.nextDue(at: now())
        if force || !b.hasPending { batchers[jobId] = force ? nil : b } else { batchers[jobId] = b }
        var seq = 0
        if batch != nil { seq = max((activitySeq[jobId] ?? 0) + 1, Int(now().timeIntervalSince1970)); activitySeq[jobId] = seq }
        let l = inbound.first { $0.req.jobId == jobId }.flatMap { j in links.first { $0.mailboxId == j.peerMailbox } }
        var arm: Date?
        if let nextAt, b.hasPending, !flushScheduled.contains(jobId) { flushScheduled.insert(jobId); arm = nextAt }
        lock.unlock()
        if let batch, let l {
            sealAndQueue(["t": "activity", "jobId": jobId, "seq": seq, "items": batch.map(\.wire)], to: l, owner: l.mailboxId)
        }
        if let arm {
            scheduler(max(0.05, arm.timeIntervalSince(now()))) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.flushScheduled.remove(jobId); self.lock.unlock()
                self.flushActivity(jobId)
            }
        }
    }

    // MARK: sender — steering and the activity stream (Run 30)

    /// Send a follow-up to the peer running one of our jobs.
    func say(jobId: String, text: String, fromAgent: String = "agent") -> Result<Void, PeerError> {
        lock.lock(); let job = sent.first { $0.jobId == jobId }; lock.unlock()
        guard let job else { return .failure(.invalid("No job \(jobId)")) }
        guard !job.status.isFinal else { return .failure(.invalid("That job has already ended")) }
        guard PeerSay.parse(["jobId": jobId, "text": text]) != nil else { return .failure(.invalid("Say something short (under 8 KB, no control characters)")) }
        guard let l = link(job.peerMailbox) else { return .failure(.invalid("That peer was removed")) }
        guard sealAndQueue(["t": "say", "jobId": jobId, "text": text, "fromAgent": fromAgent], to: l, jobId: jobId, owner: l.mailboxId) else {
            return .failure(.invalid("Couldn't send that"))
        }
        record(jobId, [PeerActivityItem(t: Int(now().timeIntervalSince1970), kind: .status, text: "You: " + String(text.prefix(PeerActivityItem.maxText)))])
        return .success(())
    }

    /// Ask the peer to end one of our jobs.
    func stopJob(jobId: String) -> Result<Void, PeerError> {
        lock.lock(); let job = sent.first { $0.jobId == jobId }; lock.unlock()
        guard let job else { return .failure(.invalid("No job \(jobId)")) }
        guard !job.status.isFinal else { return .failure(.invalid("That job has already ended")) }
        guard let l = link(job.peerMailbox) else { return .failure(.invalid("That peer was removed")) }
        sealAndQueue(["t": "stop", "jobId": jobId], to: l, jobId: jobId, owner: l.mailboxId)
        return .success(())
    }

    func eventsURL(_ jobId: String) -> URL { jobDir(jobId).appendingPathComponent("events.jsonl") }

    /// The newest `n` activity items for a sent job (memory first, then the events file).
    func activity(jobId: String, last n: Int = 200) -> [PeerActivityItem] {
        lock.lock(); let cached = activityCache[jobId]; lock.unlock()
        var items = cached ?? []
        if items.isEmpty, let d = try? Data(contentsOf: eventsURL(jobId)) {
            items = String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap { try? JSONDecoder().decode(PeerActivityItem.self, from: Data($0.utf8)) }
        }
        return Array(items.suffix(n))
    }

    private func record(_ jobId: String, _ items: [PeerActivityItem]) {
        guard !items.isEmpty else { return }
        var lines = Data()
        for it in items { if let d = try? JSONEncoder().encode(it) { lines.append(d); lines.append(10) } }
        let url = eventsURL(jobId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if fd >= 0 { _ = lines.withUnsafeBytes { Foundation.write(fd, $0.baseAddress!, $0.count) }; close(fd) }
        lock.lock()
        var c = activityCache[jobId] ?? []
        c.append(contentsOf: items)
        activityCache[jobId] = Array(c.suffix(Self.activityKeep))
        lock.unlock()
        changed()
    }

    private func receiveActivity(_ a: PeerActivity, from mailbox: String) {
        lock.lock()
        guard let i = sent.firstIndex(where: { $0.jobId == a.jobId }), sent[i].peerMailbox == mailbox else {
            lock.unlock(); drop("activity for a job not sent to this peer"); return
        }
        if let last = sent[i].seq, a.seq <= last { lock.unlock(); return }        // a repeat of a batch we already have
        sent[i].seq = a.seq; sent[i].lastActivity = now(); saveSent()
        let j = sent[i]
        lock.unlock()
        record(a.jobId, a.items)
        for q in a.items where q.kind == .question {
            launcher.deliverLine(agent: j.fromAgent, line: PeerText.questionLine(label: j.peerLabel, jobId: j.jobId, question: q.text))
        }
    }

    // MARK: kill switch

    /// End every running peer job cleanly (panes closed, builders stopped) and decline the waiting ones.
    func stopAll() {
        lock.lock()
        let live = inbound.filter { !$0.status.isFinal }
        heldSays.removeAll()        // queued follow-ups die with the jobs
        lock.unlock()
        launcher.stop(panes: live.compactMap(\.pane), builders: live.compactMap(\.builder))
        for j in live { end(j.id, j.status == .queued ? .declined : .failed, "Stopped on this Mac", reportAs: .failed) }
    }
}
