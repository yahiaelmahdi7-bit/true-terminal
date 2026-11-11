import Foundation
import CryptoKit

/// True ↔ True peers — the engine (Run 29). Receiver: take a validated job from a paired peer, run it as a real Claude
/// session in a worktree, report status + result back. Sender: hand jobs to peers, track them, deliver one line to the
/// lead. Everything crosses the relay as sealed envelopes (PeerSeal). All state in JSON files under `root`; the outbox
/// retries only while it has items (no idle timer).
final class PeerEngine: @unchecked Sendable {
    let root: URL
    let identity: PeerIdentity
    let launcher: PeerLauncher
    private let transport: PeerTransport
    private let inboundMode: @Sendable () -> PeerInboundMode
    let now: @Sendable () -> Date
    private var cloneLocks: [String: NSLock] = [:]
    let scheduler: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let missionOwnerLock = NSLock()
    private var missionOwner: MissionService?
    func missionService() -> MissionService {
        missionOwnerLock.lock(); defer { missionOwnerLock.unlock() }
        if let missionOwner { return missionOwner }
        final class Callback: @unchecked Sendable { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }
        let service = MissionService.live(engine: self, platform: launcher, now: now, scheduler: { [scheduler] delay, action in
            let callback = Callback(action)
            scheduler(delay) { callback.run() }
        })
        missionOwner = service
        return service
    }
    let ownName: String
    private let steering: @Sendable () -> Bool
    private let share: @Sendable () -> PeerShare
    private let allowedDirs: @Sendable () -> [String]
    private let chatOn: @Sendable () -> Bool
    // Run 35 — one desk per peer project
    private let deskOn: @Sendable () -> Bool
    private let laneCount: @Sendable () -> Int
    func lanes() -> Int { min(4, max(1, laneCount())) }
    /// Desk panes the owner/sender stopped on purpose: never fed another job even while their tab lingers.
    private var retired: Set<UUID> = []
    // Run 34 — Shared projects
    let sharedRepos: @Sendable () -> [String: [SharedRepo]]
    /// Steward's grant snapshot and the grants-mode switch. Off by default; a peer job is gated only when on.
    let grants: GrantCache
    private var grantSync: GrantSync?
    private let setSharedRepos: @Sendable ([String: [SharedRepo]]) -> Void
    /// Where accepted repos are cloned: `<projectsRoot>/<slug>.peers/<peer-slug>`.
    private let projectsRoot: String
    private var offers: [PeerOffer]

    private let resumeLock = NSRecursiveLock()
    let lock = NSLock()
    let work = DispatchQueue(label: "true.peers.work")
    private let net = DispatchQueue(label: "true.peers.net")
    var links: [PeerLink]
    /// G7: the cross-Mac ask service (set at the end of init).
    var ask: AskService!
    private var inbound: [InboundJob]
    private var sent: [SentJob]
    private var outbox: [OutboxItem]
    private var invites: [PendingInvite]
    private var seen: [String: Int]
    /// Job ids whose prompt may already have been typed into a pane or a builder launched, but whose pane/builder isn't saved yet. Persisted so a restart never types a job twice.
    private var starting: Set<String> = []
    private var timerAt: Date?
    private var lastWanted: Bool?
    // Run 30 — Drive
    private var batchers: [String: PeerBatcher] = [:]
    private var activitySeq: [String: Int] = [:]
    private var flushScheduled: Set<String> = []
    // Run 36a — watch leases (jobId → expiry), engine-wide activity send times, sender-side watch renewals
    private var leases: [String: Date] = [:]
    private var activitySendTimes: [Date] = []
    private var watching: [String: Date] = [:]
    static let leaseSeconds: TimeInterval = 90, watchRenewSeconds: TimeInterval = 60, activityPerMinute = 20, backlogCap = 200
    private var heldSays: [String: [String]] = [:]
    private var lastErrors: [String: String] = [:]
    private var tailers: [String: PeerStreamTailer] = [:]
    // Run 36a — caps (what each peer's True can do) + own-path guard
    private var caps: [String: PeerCaps]
    /// T3 Group G1: one Card per peer. Gate state is per mailbox (snapshot of what that peer last got, when, a pending trailing flush).
    private var cardSnapshots: [String: Data] = [:]
    private var cardSentAts: [String: Date] = [:]
    private var cardTrailing: Set<String> = []
    private var cardSeq = 0
    /// At most one Card per peer per window; a change inside it is flushed once at the window's end.
    static let cardWindow: TimeInterval = 15
    /// What this Mac shares per repo hash: folders (newest-used first, focused pane's first) and live agent rows.
    /// Set by the app; defaults share nothing. Only entries for a repo the peer shares ever leave (see `card(for:)`).
    var cardFolders: @Sendable () -> [String: [String]] = { [:] }
    var cardAgents: @Sendable () -> [AgentShare] = { [] }
    /// This Mac's own plan use, sent in every Card. Set by the app (`UsageSharing`); nil = say nothing.
    var cardUsage: @Sendable () -> UsageShare? = { nil }
    private var cardHeartbeatArmed = false
    private let cardRefreshLock = NSLock()
    private var cardRefreshArmed = false
    private var cloneHashes: [String] = []
    private var capsFirstAsked: [String: Date] = [:]
    /// Our home directory, announced to peers in caps; tests set another one.
    var home = NSHomeDirectory() { didSet { cardChanged() } }
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
    /// 100x 2d: what we told a peer about each `@seat` line, by message id, so a retried id is answered again.
    private var chatAnswers: [String: [String: Any]] = [:]
    static let chatBatchDelay: TimeInterval = 0.3
    static let chatPerMinute = 20
    static let chatBatchItems = 8
    /// Set when someone finished pairing with us ("Paired with <label>"); the Peers sheet shows it.
    private(set) var lastPaired: String?
    private(set) var dropCount = 0
    // G4+ — doctor + mesh
    /// This Mac's True build; announced on the status card. Tests set one.
    var build: TrueBuild? = TrueBuild.current { didSet { cardChanged() } }
    private var lastFetch: Date?
    private var heard: [String: Date] = [:]
    private var heardSaved: [String: Date] = [:]
    private var history: [PeerLinkRecord] = []
    private var problemList: [PeerProblem] = []
    private var currentSender: String?
    /// H6: a problem worth a macOS notification (failed / declined job, dropped message, oracle failure, removed link).
    var onProblem: (@Sendable (PeerProblem) -> Void)?
    static let holdLife: TimeInterval = 72 * 3600
    private var refused: [String: String] = [:]
    private var refusalSentAt: [String: Date] = [:]
    private var meshRuns: [String: MeshRun] = [:]
    private var meshAskTimes: [String: [Date]] = [:]
    static let meshLeafWait: TimeInterval = 10, meshAsksPerMinute = 6
    /// Monotonic milliseconds for timing round trips; tests replace it.
    var monoMs: @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    /// Called once for each new inbound job, after it is stored (the app posts the macOS notification from here).
    var onJobArrived: (@Sendable (InboundJob) -> Void)?
    /// H5: a job is still waiting for Accept one hour after it arrived (the app posts a macOS notification).
    var onAcceptReminder: (@Sendable (InboundJob) -> Void)?
    static let acceptRemind: TimeInterval = 3600, acceptNudge: TimeInterval = 24 * 3600

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
         desk: @escaping @Sendable () -> Bool = { PeerSettings.desk },
         lanes: @escaping @Sendable () -> Int = { PeerSettings.lanes },
         projectsRoot: String = NSHomeDirectory() + "/Projects",
         now: @escaping @Sendable () -> Date = { Date() },
         scheduler: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil,
         grants: GrantCache? = nil) {
        self.grants = grants ?? GrantCache(dir: root, now: now)
        self.root = root; self.identity = identity; self.launcher = launcher; self.transport = transport
        self.inboundMode = inboundMode; self.steering = steering; self.share = share; self.allowedDirs = allowedDirs; self.chatOn = chatOn; self.sharedRepos = sharedRepos; self.setSharedRepos = setSharedRepos; self.deskOn = desk; self.laneCount = lanes; self.projectsRoot = projectsRoot; self.now = now; self.ownName = String(ownName.prefix(PeerValidate.maxLabel))
        let q = DispatchQueue(label: "true.peers.timer")
        self.scheduler = scheduler ?? { d, f in q.asyncAfter(deadline: .now() + d, execute: f) }
        links = PeerEngine.load(root.appendingPathComponent("peers.json")) ?? []
        inbound = PeerEngine.load(root.appendingPathComponent("inbound.json")) ?? []
        sent = PeerEngine.load(root.appendingPathComponent("sent.json")) ?? []
        invites = PeerEngine.load(root.appendingPathComponent("invites.json")) ?? []
        seen = PeerEngine.load(root.appendingPathComponent("seen.json")) ?? [:]
        starting = Set((PeerEngine.load(root.appendingPathComponent("starting.json")) as [String]?) ?? [])
        outbox = PeerEngine.loadOutbox(root)
        offers = PeerEngine.load(root.appendingPathComponent("offers.json")) ?? []
        caps = PeerEngine.load(root.appendingPathComponent("caps.json")) ?? [:]
        cardSeq = PeerEngine.load(root.appendingPathComponent("card-seq.json")) ?? 0
        history = PeerEngine.load(root.appendingPathComponent("links-history.json")) ?? []
        problemList = PeerEngine.load(root.appendingPathComponent("problems.json")) ?? []
        heard = PeerEngine.load(root.appendingPathComponent("heard.json")) ?? [:]
        heardSaved = heard
        let t = now()
        invites.removeAll { $0.used || $0.expires <= t }
        seen = seen.filter { $0.value > Int(t.timeIntervalSince1970) }
        transport.onMessage = { [weak self] _, _, blob in self?.receive(blob) }
        transport.onStatus = { [weak self] up in
            guard let self else { return }
            if up {
                self.work.async { [weak self] in
                    self?.refreshCloneCache(); self?.refreshCard(); self?.flush()
                }
            }
            self.armCardRefresh()
            self.changed()
        }
        for i in invites { scheduleWantedCheck(at: i.expires) }
        for j in inbound where j.status == .queued { if let s = j.acceptSince { scheduleAcceptReminders(j.id, since: s) } }
        if transport.isConnected { refreshCloneCache() }
        updateWanted()
        armCardRefresh()
        if !outbox.isEmpty { net.async { [self] in pump() } }
        work.async { [weak self] in self?.recoverInterrupted(); self?.sweepHeld() }
        ask = AskService(engine: self)
    }

    static var standardRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".true/peers", isDirectory: true) }

    /// Tests: wait for queued work (launches, then the outbox, then anything those queued).
    func drain() { for _ in 0..<3 { work.sync {}; net.sync {}; ask?.queue.sync {} } }

    var isConnected: Bool { transport.isConnected }
    /// Whether the relay connection is wanted right now (a paired peer, a live invite, or something still to send).
    var wantsRelay: Bool { lock.lock(); defer { lock.unlock() }; return computeWanted() }

    // MARK: files

    private static func enc() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    static func dec() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
    static func load<T: Decodable>(_ url: URL) -> T? { (try? Data(contentsOf: url)).flatMap { try? dec().decode(T.self, from: $0) } }
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
    private func saveHistory() { Self.write((try? Self.enc().encode(history)) ?? Data(), to: root.appendingPathComponent("links-history.json")) }
    private func saveProblems() { Self.write((try? Self.enc().encode(problemList)) ?? Data(), to: root.appendingPathComponent("problems.json")) }
    private func saveHeard() { Self.write((try? Self.enc().encode(heard)) ?? Data(), to: root.appendingPathComponent("heard.json")) }
    private func saveCaps() { Self.write((try? Self.enc().encode(caps)) ?? Data(), to: root.appendingPathComponent("caps.json")) }
    private func saveStarting() { Self.write((try? Self.enc().encode(starting.sorted())) ?? Data(), to: root.appendingPathComponent("starting.json")) }
    private func markStarting(_ jobId: String) { lock.lock(); starting.insert(jobId); saveStarting(); lock.unlock() }
    private func clearStarting(_ jobId: String) { lock.lock(); if starting.remove(jobId) != nil { saveStarting() }; lock.unlock() }
    private func saveSeen() { Self.write((try? Self.enc().encode(seen)) ?? Data(), to: root.appendingPathComponent("seen.json")) }
    private func outboxURL(_ id: String) -> URL { root.appendingPathComponent("outbox/\(id).json") }
    private func saveOutbox(_ i: OutboxItem) { Self.write((try? Self.enc().encode(i)) ?? Data(), to: outboxURL(i.id)) }
    func jobDir(_ jobId: String) -> URL { root.appendingPathComponent("jobs/\(jobId)", isDirectory: true) }
    func resultPath(_ jobId: String) -> String { jobDir(jobId).appendingPathComponent("result.md").path }
    func changed() {
        NotificationCenter.default.post(name: .peersChanged, object: nil)
    }

    private func cardChanged() {
        // update() can call this while holding the job lock.
        cardRefreshLock.lock()
        guard !cardRefreshArmed else { cardRefreshLock.unlock(); return }
        cardRefreshArmed = true
        cardRefreshLock.unlock()
        work.async { [weak self] in
            guard let self else { return }
            self.cardRefreshLock.lock(); self.cardRefreshArmed = false; self.cardRefreshLock.unlock()
            self.refreshCard()
        }
    }

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
    func drop(_ reason: String) {
        lock.lock(); dropCount += 1; let from = currentSender; lock.unlock()
        if let from, reason != "replay", let label = link(from)?.label {      // H6: a paired peer's message was thrown away
            let why = reason.hasPrefix("unknown kind") ? "\(label) sent something this True can't read. Update True." : "A message from \(label) was dropped (\(reason))."
            recordProblem(.dropped, peer: label, text: why)
        }
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

    /// H5: reminders for a job waiting on Accept: a notification at +1 h, a chat line at +24 h. Both no-op once the job is no longer waiting.
    private func scheduleAcceptReminders(_ jobId: String, since: Date) {
        func arm(_ at: TimeInterval, _ fire: @escaping @Sendable (PeerEngine, InboundJob) -> Void) {
            scheduler(max(1, since.addingTimeInterval(at).timeIntervalSince(now()))) { [weak self] in
                guard let self, let j = self.inboundJobs().first(where: { $0.id == jobId }), j.status == .queued else { return }
                fire(self, j)
            }
        }
        arm(Self.acceptRemind) { e, j in e.onAcceptReminder?(j) }
        arm(Self.acceptNudge) { e, j in
            let hours = Int(e.now().timeIntervalSince(since) / 3600)
            _ = e.chat?.post(channel: "#peers", agent: "true", text: PeerText.acceptNudge(peer: j.peerLabel, title: j.req.title, hours: hours), deliver: false)
            e.changed()
        }
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

    /// Inviter: drop an invite that was handed out but never used (the nearby handshake failed after minting it), and stop
    /// watching the relay for it if nothing else needs it.
    func cancelInvite(_ secret: Data) {
        let h = PeerCrypto.sha256Hex(secret)
        lock.lock()
        let before = invites.count
        invites.removeAll { $0.secretHash == h && !$0.used }
        let gone = invites.count != before
        if gone { saveInvites() }
        lock.unlock()
        guard gone else { return }
        updateWanted()
        changed()
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
        refused[link.mailboxId] = nil
        lock.unlock()
        enqueue(OutboxItem(id: id, jobId: nil, to: inv.mailboxId, blob: blob, attempt: 0, nextAt: now(), owner: inv.mailboxId))
        changed()
        return .success(link)
    }

    /// Revoke: delete the pinned keys, drop that peer's queued work (jobs with a saved brief are held, see `removeLink`), and tell them (best effort).
    func revoke(mailboxId: String) {
        guard let link = removeLink(mailboxId, who: "me") else { return }
        if let body = try? JSONSerialization.data(withJSONObject: ["t": "unpair"]) {
            let id = UUID().uuidString.lowercased()
            if let blob = PeerSeal.seal(payload: body, id: id, now: now(), from: identity, to: link.keys) {
                enqueue(OutboxItem(id: id, jobId: nil, to: mailboxId, blob: blob, attempt: 0, nextAt: now(), owner: nil))
            }
        }
        updateWanted()
        changed()
    }

    /// H3: the one place a link goes away. Writes the history row, fails what can't wait, HOLDS waiting jobs that have a saved
    /// brief (re-sealed on `resumeHeld`, never automatically), and tells the sender when the other person did it.
    @discardableResult
    private func removeLink(_ mailbox: String, who: String) -> PeerLink? {
        lock.lock()
        guard let link = links.first(where: { $0.mailboxId == mailbox }) else { lock.unlock(); return nil }
        let t = now()
        links.removeAll { $0.mailboxId == mailbox }; saveLinks()
        let build = caps[mailbox].flatMap { c in c.buildDate.map { d in c.buildCommit.map { "\(d) · \($0)" } ?? d } }
        if who == "them" { caps[mailbox] = nil; saveCaps(); capsFirstAsked[mailbox] = nil }
        let dropped = outbox.filter { $0.owner == mailbox }
        outbox.removeAll { $0.owner == mailbox }
        for d in dropped { try? FileManager.default.removeItem(at: outboxURL(d.id)) }
        for i in inbound.indices where inbound[i].peerMailbox == mailbox && inbound[i].status == .queued {
            inbound[i].status = .declined; inbound[i].note = "Peer removed"; inbound[i].finished = t; log(inbound[i])
        }
        saveInbound()
        let fp = link.keys.fingerprint
        var held = 0
        for i in sent.indices where sent[i].peerMailbox == mailbox && !sent[i].status.isFinal {
            let waiting = sent[i].status == .queued || PeerStatusText.isWaitingForAccept(sent[i])
            let hasBrief = FileManager.default.fileExists(atPath: jobDir(sent[i].jobId).appendingPathComponent("brief.md").path)
            if waiting && hasBrief {
                sent[i].status = .paused; sent[i].note = "Held — link \(who == "them" ? "removed by them" : "removed")"
                sent[i].heldSince = t; sent[i].heldFingerprint = fp; sent[i].updated = t; held += 1
            } else {
                sent[i].status = .failed; sent[i].note = "Peer removed"; sent[i].updated = t
            }
        }
        saveSent()
        history.append(PeerLinkRecord(who: who, at: t, label: link.label, mailboxId: mailbox, fingerprint: fp, lastBuild: build, heldJobs: held))
        if history.count > 200 { history.removeFirst(history.count - 200) }
        saveHistory()
        lock.unlock()
        if who == "them" {
            let tail = held > 0 ? " \(held) waiting job\(held == 1 ? "" : "s") held for 72 h." : ""
            recordProblem(.linkRemoved, peer: link.label, text: "Link with \(link.label) removed by them at \(PeerStatusText.time(t)).\(tail)")
        }
        updateWanted()
        changed()
        return link
    }

    func revoke(label: String) {
        lock.lock(); let m = links.first { $0.label.lowercased() == label.lowercased() }?.mailboxId; lock.unlock()
        if let m { revoke(mailboxId: m) }
    }

    // MARK: H3 held jobs · H6 problems and health

    /// H6: the one place the rest of the app reads "when did we last hear from this person" (the chat member list shows it as Online).
    func lastHeard(_ mailbox: String) -> Date? { heardAt(mailbox) }

    func linkHistory() -> [PeerLinkRecord] { lock.lock(); defer { lock.unlock() }; return history.sorted { $0.at > $1.at } }
    func problems() -> [PeerProblem] { lock.lock(); defer { lock.unlock() }; return problemList.sorted { $0.at > $1.at } }
    func clearProblems() { lock.lock(); problemList = []; saveProblems(); lock.unlock(); changed() }

    /// Add a line to the "Peer problems" feed and tell the app (notification). The same text for the same peer within a minute is one line.
    func recordProblem(_ kind: PeerProblem.Kind, peer: String, text: String, jobId: String? = nil) {
        let t = now()
        let p = PeerProblem(id: UUID().uuidString.lowercased(), at: t, kind: kind, peer: peer, text: text, jobId: jobId)
        lock.lock()
        if problemList.contains(where: { $0.peer == peer && $0.text == text && t.timeIntervalSince($0.at) < 60 }) { lock.unlock(); return }
        problemList.append(p)
        if problemList.count > 100 { problemList.removeFirst(problemList.count - 100) }
        saveProblems()
        lock.unlock()
        onProblem?(p)
        changed()
    }

    struct HeldGroup: Equatable { var label: String; var mailboxId: String; var count: Int; var since: Date; var canResume: Bool }

    /// Held jobs by person. `canResume` only when the person is paired again at the SAME mailbox with the SAME key fingerprint.
    func heldGroups() -> [HeldGroup] {
        sweepHeld()
        lock.lock(); defer { lock.unlock() }
        let held = sent.filter { $0.heldSince != nil && !$0.status.isFinal }
        return Dictionary(grouping: held, by: \.peerMailbox).map { mb, js in
            let l = links.first { $0.mailboxId == mb && $0.confirmed }
            let ok = l.map { l in js.contains { $0.heldFingerprint == l.keys.fingerprint } } ?? false
            return HeldGroup(label: js[0].peerLabel, mailboxId: mb, count: js.count, since: js.compactMap(\.heldSince).min() ?? js[0].updated, canResume: ok)
        }.sorted { $0.since > $1.since }
    }

    /// After 72 h a held job is failed (the sender is told).
    func sweepHeld() {
        let t = now()
        lock.lock()
        var expired: [SentJob] = []
        for i in sent.indices {
            if let h = sent[i].heldSince, !sent[i].status.isFinal, t.timeIntervalSince(h) >= Self.holdLife {
                sent[i].status = .failed; sent[i].note = "Link not restored within 72 h"; sent[i].updated = t; sent[i].heldSince = nil
                expired.append(sent[i])
            }
        }
        if !expired.isEmpty { saveSent() }
        lock.unlock()
        for j in expired { recordProblem(.jobFailed, peer: j.peerLabel, text: "“\(j.title)” for \(j.peerLabel) was held 72 h and dropped: the link never came back", jobId: j.jobId) }
        if !expired.isEmpty { changed() }
    }

    /// Re-seal the held jobs for `mailboxId` from their saved briefs. Only when that mailbox is paired again AND its keys' fingerprint
    /// is the one pinned when the jobs were held. Never by label, never automatic. Returns the new job ids.
    func resumeHeld(mailboxId: String) -> Result<[String], PeerError> {
        sweepHeld()
        lock.lock()
        let link = links.first { $0.mailboxId == mailboxId && $0.confirmed }
        let held = sent.filter { $0.peerMailbox == mailboxId && $0.heldSince != nil && !$0.status.isFinal }
        lock.unlock()
        guard !held.isEmpty else { return .failure(.invalid("Nothing is held for them")) }
        guard let link else { return .failure(.invalid("\(held[0].peerLabel) isn't paired again yet. Send them a new invite first.")) }
        let fp = link.keys.fingerprint
        let same = held.filter { $0.heldFingerprint == fp }
        guard !same.isEmpty else {
            return .failure(.invalid("\(link.label) now has different keys (\(fp)) than the person these jobs were for. They stay held. Check with them that it is the same person."))
        }
        var ids: [String] = []
        for old in same.sorted(by: { $0.created < $1.created }) {
            lock.lock()
            if let i = sent.firstIndex(where: { $0.jobId == old.jobId }) {
                sent[i].status = .canceled; sent[i].note = "Resumed as a new job"; sent[i].heldSince = nil; sent[i].updated = now(); saveSent()
            }
            lock.unlock()
            switch resend(jobId: old.jobId) {
            case .success(let id): ids.append(id)
            case .failure(.invalid(let why)):
                // The re-send failed: put the job back on hold exactly as it was, so the work is never silently lost.
                lock.lock()
                if let i = sent.firstIndex(where: { $0.jobId == old.jobId }) {
                    sent[i].status = old.status; sent[i].note = "Resume failed: \(why)"
                    sent[i].heldSince = old.heldSince; sent[i].updated = now(); saveSent()
                }
                lock.unlock()
            }
        }
        changed()
        return .success(ids)
    }

    /// The words on one peer row.
    func healthLine(for link: PeerLink, tz: TimeZone = .current) -> String {
        let t = now()
        lock.lock()
        let c = caps[link.mailboxId], h = heard[link.mailboxId]
        let flowing = sent.contains { $0.peerMailbox == link.mailboxId && [.accepted, .working].contains($0.status) }
            || inbound.contains { $0.peerMailbox == link.mailboxId && [.accepted, .working].contains($0.status) }
        lock.unlock()
        let st = PeerHealth.state(heard: h, sentCard: c != nil, cardVersion: c?.version, linkAge: t.timeIntervalSince(link.created), now: t)
        let build = c?.buildDate
        return PeerHealth.line(st, build: build, flowing: flowing, tz: tz)
    }

    /// Removed-by-them links that aren't paired again: the row text and the history record.
    func removedByThem() -> [PeerLinkRecord] {
        lock.lock(); defer { lock.unlock() }
        let live = Set(links.map(\.mailboxId))
        var seen = Set<String>()
        return history.sorted { $0.at > $1.at }.filter { $0.byThem && !live.contains($0.mailboxId) && seen.insert($0.mailboxId).inserted }
    }

    // MARK: sealed sending

    /// Seal a payload to a pinned peer and put it in the outbox.
    @discardableResult
    /// Whether `payload` seals under the blob cap to this peer (the status is sealed once for real afterwards).
    private func sealFits(_ payload: [String: Any], to link: PeerLink) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return PeerSeal.seal(payload: body, now: now(), from: identity, to: link.keys) != nil
    }

    func sealAndQueue(_ payload: [String: Any], to link: PeerLink, jobId: String? = nil, owner: String?, at: Date? = nil, lane: String? = nil, kind: String? = nil) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        if let kind = payload["t"] as? String, PeerKindTable.unreadable(kind: kind, card: peerCaps(link.mailboxId), now: now()) {
            recordProblem(.needsUpdate, peer: link.label, text: needsUpdateMessage(peer: link.label))   // H2: held at the sender, never sent into a drop
            return false
        }
        let id = UUID().uuidString.lowercased()
        guard let blob = PeerSeal.seal(payload: body, id: id, now: now(), from: identity, to: link.keys) else { return false }
        enqueue(OutboxItem(id: id, jobId: jobId, to: link.mailboxId, blob: blob, attempt: 0, nextAt: at ?? now(), owner: owner, kind: kind, lane: lane))
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
            refreshCloneCache()
            cardChanged()
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

    // MARK: caps (Run 36a)

    private func refreshCloneCache() {
        // Accepted clones live under .peers, outside the launcher's ordinary repo scan.
        let shared = sharedRepos().values.flatMap { $0 }.filter { !$0.path.isEmpty }.map { $0.url }
        let hashes = Array(Set((launcher.cloneRemotes() + shared).compactMap { PeerRepo.hash($0) })).sorted()
        lock.lock(); cloneHashes = hashes; lock.unlock()
    }

    /// What this True announces: job kinds, cached clone hashes, lanes, tools and home.
    func ownCaps() -> [String: Any] {
        let total = lanes()
        lock.lock()
        let hashes = cloneHashes
        let busy = Set(inbound.filter { !$0.status.isFinal && $0.desk != nil && $0.pane != nil }.map { "\($0.desk ?? "")|\($0.lane ?? 1)" }).count
        lock.unlock()
        var card: [String: Any] = ["t": "caps", "version": PeerCaps.currentVersion, "features": PeerCaps.ownFeatures, "home": home,
                "kinds": ["repo", "dir"], "repos": hashes, "lanes": ["total": total, "free": max(0, total - busy)],
                "tools": launcher.installedTools()]
        if let b = build { card["build"] = ["commit": b.commit, "date": b.date] }
        return card
    }

    /// T3 Group G1: this peer's Card = today's fields + only the `folders` / `agents` of repos it shares.
    /// Grants mode on: the peer's person must also read that repo's workspace; anything unknown fails closed (no entries).
    private func card(for link: PeerLink) -> [String: Any] {
        let key = PeerB64.std(link.keys.sign)
        var allowed = Set<String>()
        for r in sharedRepos()[link.mailboxId] ?? [] {
            if let h = PeerRepo.hash(r.url), grants.mayShare(peerKey: key, repoURL: r.url) { allowed.insert(h) }
        }
        var folders: [String: [String]] = [:]
        for (h, paths) in cardFolders() where allowed.contains(h) && CardLimits.isHash(h) {
            let w = paths.prefix(CardLimits.maxFolderPaths).map { CardLimits.wirePath($0, home: home) }.filter { !$0.isEmpty }
            if !w.isEmpty { folders[h] = w }
        }
        if folders.count > CardLimits.maxFolderRepos { for k in folders.keys.sorted().dropFirst(CardLimits.maxFolderRepos) { folders[k] = nil } }
        let agents = grants.sharesAgents ? cardAgents().filter { allowed.contains($0.repo) } : []
        return CardLimits.fit(ownCaps(), folders: folders, agents: agents, dirs: cardDirs(for: link), usage: cardUsage())
    }

    /// 100x 2c: the roots this peer's dir jobs may use, as the receiver's own resolve would see them. Empty = say nothing.
    private func cardDirs(for link: PeerLink) -> [String] {
        PeerDirs.topLevelRoots(allowedDirs() + (sharedRepos()[link.mailboxId] ?? []).map(\.path).filter { !$0.isEmpty }).prefix(CardLimits.maxDirs).map { $0 }
    }

    /// Tests: the Card as it would be built for `link` right now.
    func card(forTests link: PeerLink) -> [String: Any] { card(for: link) }

    func sendCapsToAll(heartbeatDue: Bool = false) {
        guard transport.isConnected else { return }
        lock.lock(); let ls = links.filter { $0.confirmed }; lock.unlock()
        for l in ls { sendCard(to: l, heartbeatDue: heartbeatDue) }
        armCardRefresh()
    }

    /// The per-peer gate: due when its filtered Card changed, the heartbeat is due or half the stale time has passed;
    /// never twice inside `cardWindow` (a change in the window arms one trailing flush on the scheduler, later changes fold into it).
    private func sendCard(to link: PeerLink, heartbeatDue: Bool = false, force: Bool = false) {
        let card = card(for: link)
        let mb = link.mailboxId
        let snapshot = try? JSONSerialization.data(withJSONObject: card, options: [.sortedKeys])
        lock.lock()
        let t = now(), last = cardSentAts[mb]
        let due = force || heartbeatDue || snapshot != cardSnapshots[mb] || last.map { t.timeIntervalSince($0) >= PeerCaps.staleAfter / 2 } ?? true
        guard due else { lock.unlock(); return }
        if !force, !heartbeatDue, let last, t.timeIntervalSince(last) < Self.cardWindow {
            let arm = cardTrailing.insert(mb).inserted
            lock.unlock()
            if arm {
                scheduler(max(1, Self.cardWindow - t.timeIntervalSince(last))) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.cardTrailing.remove(mb); let l = self.links.first { $0.mailboxId == mb && $0.confirmed }; self.lock.unlock()
                    guard let l else { return }
                    self.work.async { [weak self] in if self?.transport.isConnected == true { self?.sendCard(to: l) } }
                }
            }
            return
        }
        cardSnapshots[mb] = snapshot
        cardSentAts[mb] = t
        cardSeq += 1
        let seq = cardSeq
        Self.write((try? Self.enc().encode(seq)) ?? Data(), to: root.appendingPathComponent("card-seq.json"))
        lock.unlock()
        var out = card
        out["sentAt"] = t.timeIntervalSince1970
        out["seq"] = seq
        _ = sealAndQueue(out, to: link, owner: mb, kind: "caps")
    }

    /// The app calls this when its folders or shared agents change (or the share switch flips).
    func cardInputsChanged() { cardChanged() }

    /// Status changes are cheap; only the heartbeat rescans local clones.
    private func refreshCard() { sendCapsToAll() }

    private func armCardRefresh() {
        lock.lock()
        guard transport.isConnected, !cardHeartbeatArmed else { lock.unlock(); return }
        cardHeartbeatArmed = true
        lock.unlock()
        scheduler(PeerCaps.staleAfter / 2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.cardHeartbeatArmed = false; self.lock.unlock()
            self.work.async { [weak self] in
                guard let self, self.transport.isConnected else { return }
                self.refreshCloneCache(); self.sendCapsToAll(heartbeatDue: true); self.armCardRefresh()
            }
        }
    }
    private func sendCaps(to link: PeerLink) { sendCard(to: link, force: true) }

    private func handleCaps(_ obj: [String: Any], from mailbox: String) {
        guard var c = PeerCaps.parse(obj) else { drop("caps payload"); return }
        let arrival = now()
        lock.lock()
        // A Card the relay replays late (its `seq` is not above the newest seen) neither replaces the newer one nor refreshes presence.
        // Exception: a sender whose counter restarted shows a `sentAt` well past the stored one; a replay can never.
        if let old = caps[mailbox], let ns = c.seq, let os = old.seq, ns <= os,
           !(c.sentAt.map { n in old.sentAt.map { n > $0 + PeerCaps.staleAfter } ?? false } ?? false) { lock.unlock(); return }
        // A late-delivered Card shows its real age; a fast sender clock can never look fresher than the arrival.
        c.updated = c.sentAt.map { min(arrival, Date(timeIntervalSince1970: $0)) } ?? arrival
        caps[mailbox] = c; saveCaps(); lock.unlock()
        changed()
    }

    /// Treat the peer as never having announced (an older True) — for tests of the old-peer path.
    func heardAt(_ mailbox: String) -> Date? { lock.lock(); defer { lock.unlock() }; return heard[mailbox] }

    /// G7: an expired ask leaves the outbox.
    func dropOutbox(jobId: String) {
        lock.lock()
        let gone = outbox.filter { $0.jobId == jobId }
        outbox.removeAll { $0.jobId == jobId }
        lock.unlock()
        for d in gone { try? FileManager.default.removeItem(at: outboxURL(d.id)) }
        updateWanted()
    }

    func forgetCaps(_ mailbox: String) { lock.lock(); caps[mailbox] = nil; saveCaps(); lock.unlock() }

    /// Tests: pretend a peer announced this Card.
    func setPeerCaps(_ mailbox: String, _ c: PeerCaps) { lock.lock(); caps[mailbox] = c; saveCaps(); lock.unlock() }

    func peerCaps(_ mailbox: String) -> PeerCaps? { lock.lock(); defer { lock.unlock() }; return caps[mailbox] }

    /// Whether the peer's True supports `feature`: yes, no (it announced and lacks it), or wait (never announced; 60 s grace from the first ask).
    func capsState(mailbox: String, feature: String) -> PeerCapsState {
        lock.lock(); defer { lock.unlock() }
        if let c = caps[mailbox] { return c.features.contains(feature) ? .yes : .no }
        let t = now()
        let first = capsFirstAsked[mailbox] ?? t
        capsFirstAsked[mailbox] = first
        return t.timeIntervalSince(first) >= PeerCaps.unknownGrace ? .no : .wait
    }

    /// The words for a feature the peer can't do yet.
    func needsUpdateMessage(peer: String) -> String { "\(peer) needs to update True" }

    /// Own-path guard: a `--dir` under our own home that exists here, while the peer's home differs, is almost surely a slip.
    private func ownPathProblem(_ dir: String, peer link: PeerLink) -> String? {
        guard !dir.hasPrefix("~"), dir == home || dir.hasPrefix(home + "/"),
              FileManager.default.fileExists(atPath: dir),
              let theirs = peerCaps(link.mailboxId)?.home, !theirs.isEmpty, theirs != home else { return nil }
        return "That is a path on your Mac. Use --with to send it, or name a path on \(link.label)'s Mac."
    }

    /// Missions M1.2: what can never work is refused here with a plain reason + fix, before anything is sealed or queued.
    /// Peer offline, no Card yet or a stale Card → nil (the job queues, as before). Only a fresh Card can say "no clone".
    func preflight(link: PeerLink, remote: String, dir: String, brief: String) -> String? {
        if let msg = briefPathProblem(brief, peer: link) { return msg }
        guard let card = peerCaps(link.mailboxId), card.supportsM1, !card.isStale(at: now()) else { return nil }
        let kind = dir.isEmpty ? "repo" : "dir"
        if !card.kinds.isEmpty, !card.kinds.contains(kind) { return needsUpdateMessage(peer: link.label) }
        // 2c: only a fresh Card from a peer that announces `dirs-v1` may refuse; anything else sends and the receiver judges.
        if !dir.isEmpty, card.features.contains(PeerCaps.dirsFeature), let roots = card.dirs, !roots.isEmpty,
           let at = card.updated, now().timeIntervalSince(at) < PeerCaps.dirsFreshFor,
           PeerDirs.outsideRoots(dir, roots: roots, peerHome: card.home) { return "\(link.label) doesn't allow \(dir)" }
        guard dir.isEmpty, !remote.isEmpty, let h = PeerRepo.hash(remote), !card.repos.contains(h) else { return nil }
        lock.lock()
        let shared = offers.contains { !$0.incoming && $0.peerMailbox == link.mailboxId && PeerRepo.same($0.url, remote) && $0.status != .declined && $0.status != .failed }
        lock.unlock()
        return shared ? nil : "\(link.label) has no clone of this repo. Share it with them first: true-peer offer \(remote) \(link.label)"
    }

    /// A path in the brief that exists on this Mac but is under a home the peer doesn't share.
    private func briefPathProblem(_ brief: String, peer link: PeerLink) -> String? {
        guard let theirs = peerCaps(link.mailboxId)?.home, !theirs.isEmpty, theirs != home else { return nil }
        for tok in brief.split(whereSeparator: { $0.isWhitespace || "\"'`(),;".contains($0) }) {
            let t = String(tok)
            if t.hasPrefix(home + "/"), FileManager.default.fileExists(atPath: t) {
                return "The brief points at a path on your Mac (\(t)). Put the content in the brief, or send it with --with."
            }
        }
        return nil
    }

    // MARK: sender

    /// Hand a job to a paired peer. `repo` is a local path or a git remote URL; empty = a job with no project. Returns the jobId.
    func delegate(peer: String, repo rawRepo: String = "", title: String, brief: String, base: String = "main", mode: PeerMode = .pane,
                  fromAgent: String = "agent", dir rawDir: String = "", missionBranch: String? = nil, missionName: String? = nil, placement: String? = nil) -> Result<String, PeerError> {
        lock.lock(); let link = links.first { $0.label.lowercased() == peer.lowercased() }; lock.unlock()
        guard let link else { return .failure(.invalid("No peer named \(peer)")) }
        let repo = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = rawDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dir.isEmpty && !repo.isEmpty { return .failure(.invalid("Use either a repo or a directory, not both")) }
        if !dir.isEmpty && !PeerDirs.validRaw(dir) { return .failure(.invalid("A directory must be an absolute path (or start with ~/)")) }
        if !dir.isEmpty, let msg = ownPathProblem(dir, peer: link) { return .failure(.invalid(msg)) }
        if !dir.isEmpty, let msg = PeerDirs.sendProblem(dir, peerHome: peerCaps(link.mailboxId)?.home) { return .failure(.invalid(msg)) }
        var remote = repo
        if repo.hasPrefix("/") || repo.hasPrefix("~") || repo.hasPrefix(".") {
            let path = (repo as NSString).expandingTildeInPath
            guard let r = launcher.remoteURL(ofRepoAt: path) else { return .failure(.invalid("That folder has no git origin")) }
            remote = r
        }
        if let why = preflight(link: link, remote: remote, dir: dir, brief: brief) { return .failure(.invalid(why)) }
        let id = UUID().uuidString.lowercased()
        var req: [String: Any] = ["t": "job", "jobId": id, "title": title, "brief": brief, "base": base,
                                  "mode": mode.rawValue, "fromAgent": fromAgent]
        if let missionBranch { req["missionBranch"] = missionBranch }
        if let missionName { req["missionName"] = missionName }
        if let placement, PlacementID.parse(placement) != nil { req["placement"] = placement }
        if !remote.isEmpty { req["repo"] = remote }   // older receivers drop a job whose repo is "", so omit it entirely
        let target: PeerTarget = dir.isEmpty ? .repo(repo: remote, base: base) : .dir(path: dir)
        if !dir.isEmpty { req["target"] = target.wire }
        guard let check = try? JSONSerialization.data(withJSONObject: req) else { return .failure(.invalid("bad job")) }
        if case .failure(let e) = PeerValidate.parseJob(check) { return .failure(e) }
        let t = now()
        let job = SentJob(jobId: id, peerLabel: link.label, peerMailbox: link.mailboxId, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          repo: remote, base: base, mode: mode, fromAgent: fromAgent,
                          status: .queued, note: "Sending", branch: nil, sha: nil, result: nil, created: t, updated: t, target: target, missionName: missionName)
        lock.lock(); sent.append(job); saveSent(); lock.unlock()
        Self.write(Data(brief.utf8), to: jobDir(id).appendingPathComponent("brief.md"))      // H4: kept so `resend` can seal it again
        guard sealAndQueue(req, to: link, jobId: id, owner: link.mailboxId) else {
            lock.lock()
            sent.removeAll { $0.jobId == id }; saveSent()
            lock.unlock()
            try? FileManager.default.removeItem(at: jobDir(id).appendingPathComponent("brief.md"))
            return .failure(.invalid("That job is too large to send"))
        }
        changed()
        return .success(id)
    }

    /// H4: send a finished (failed / declined / canceled / done) job again from its saved brief, to the same person, as a
    /// NEW job. `dir` replaces the folder; without it the old target is reused. Returns the new jobId.
    func resend(jobId: String, dir newDir: String? = nil) -> Result<String, PeerError> {
        guard let old = sentJobs().first(where: { $0.jobId == jobId }) else { return .failure(.invalid("No job \(jobId)")) }
        guard old.status.isFinal else { return .failure(.invalid("That job is still going. Stop it first, or wait for it to finish.")) }
        guard let data = try? Data(contentsOf: jobDir(jobId).appendingPathComponent("brief.md")), let brief = String(data: data, encoding: .utf8), !brief.isEmpty else {
            return .failure(.invalid("True didn't keep that job's brief (it was sent before briefs were saved). Send it again with true-peer delegate."))
        }
        guard let link = peerLinks().first(where: { $0.mailboxId == old.peerMailbox }) else {
            return .failure(.invalid("\(old.peerLabel) isn't paired any more. Pair again first."))
        }
        var dir = (newDir ?? "").trimmingCharacters(in: .whitespacesAndNewlines), repo = old.repo
        if case .dir(let p)? = old.target { if dir.isEmpty { dir = p }; repo = "" }
        if !dir.isEmpty { repo = "" }
        return delegate(peer: link.label, repo: repo, title: old.title, brief: brief, base: old.base, mode: old.mode,
                        fromAgent: old.fromAgent, dir: dir, missionName: old.missionName)
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
            if ev.status == .paused { sent[i].pausedReason = ev.note; sent[i].resumeAt = ev.resumeAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
            else { sent[i].pausedReason = nil; sent[i].resumeAt = nil }
            saveSent()
        }
        let j = sent[i]
        lock.unlock()
        changed()
        if j.status == .failed, ev.status == .failed {
            let declined = ev.note.lowercased().contains("declin")
            recordProblem(declined ? .jobDeclined : .jobFailed, peer: j.peerLabel, text: "\(j.peerLabel) \(declined ? "declined" : "couldn't finish") “\(j.title)”: \(ev.note)", jobId: j.jobId)
        }
        if j.status == .done || j.status == .failed, ev.status == j.status {
            let branch = j.repo.isEmpty ? nil : (j.branch ?? PeerNaming.branch(label: j.peerLabel, jobId: j.jobId))
            launcher.deliverLine(agent: j.fromAgent, line: PeerText.doneLine(label: j.peerLabel, title: j.title, status: j.status, branch: branch,
                                                                              resultPath: "true-peer result \(j.jobId)"))
        }
    }

    // MARK: outbox

    private func enqueue(_ item: OutboxItem) {
        lock.lock()
        // A newer Card makes any older queued Card for the same peer pointless.
        var gone: [OutboxItem] = []
        if let k = item.kind { gone = outbox.filter { $0.kind == k && $0.to == item.to }; outbox.removeAll { $0.kind == k && $0.to == item.to } }
        outbox.append(item); saveOutbox(item); lock.unlock()
        for g in gone { try? FileManager.default.removeItem(at: outboxURL(g.id)) }
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
            var backedOff = false
            var pendingProblem: PeerProblem?
            lock.lock()
            guard let idx = outbox.firstIndex(where: { $0.id == item.id }) else { lock.unlock(); continue }   // revoked meanwhile
            switch r {
            case .delivered:
                outbox.remove(at: idx); try? FileManager.default.removeItem(at: outboxURL(item.id))
                if let jid = item.jobId, let s = sent.firstIndex(where: { $0.jobId == jid }), sent[s].status == .queued {
                    sent[s].note = "Delivered"; sent[s].updated = now(); saveSent()
                }
            case .retry(let why):
                outbox[idx].nextAt = now().addingTimeInterval(PeerBackoff.delay(attempt: item.attempt))
                if item.lane == "activity", why != .offline { backedOff = true }
                outbox[idx].attempt += 1
                saveOutbox(outbox[idx])
            case .refused:
                outbox.remove(at: idx); try? FileManager.default.removeItem(at: outboxURL(item.id))
                if let jid = item.jobId, let s = sent.firstIndex(where: { $0.jobId == jid }), !sent[s].status.isFinal {
                    sent[s].status = .failed; sent[s].updated = now(); sent[s].note = "The relay refused this job"; saveSent()
                    pendingProblem = PeerProblem(id: "", at: now(), kind: .jobFailed, peer: sent[s].peerLabel, text: "The relay refused “\(sent[s].title)” for \(sent[s].peerLabel)", jobId: jid)
                }
            }
            lock.unlock()
            if let p = pendingProblem { recordProblem(p.kind, peer: p.peer, text: p.text, jobId: p.jobId) }
            changed()
            if case .retry = r, !backedOff { break }       // not connected / full: the rest would fail the same way; wait for the timer or a reconnect
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
        lock.lock(); lastFetch = now(); lock.unlock()
        switch PeerSeal.open(blob, me: identity, now: now(), pinned: { self.pinned($0) }) {
        case .failure(let d): drop("\(d)")
        case .success(let o):
            let t = Int(now().timeIntervalSince1970)
            lock.lock()
            let replay = seen[o.envelope.id] != nil
            lock.unlock()
            if replay { drop("replay"); return }
            let obj = (try? JSONSerialization.jsonObject(with: o.payload)) as? [String: Any]
            let isJob = (obj?["t"] as? String) == "job"
            func markSeen() {
                lock.lock()
                seen = seen.filter { $0.value > t }
                seen[o.envelope.id] = t + Int(Self.seenLife)
                saveSeen()
                lock.unlock()
            }
            // A job is marked seen only once handleJob has saved it: a crash in between lets the relay's redelivery be accepted
            // (receiveJob dedupes by job id). Every other kind keeps the early mark so it can never be applied twice.
            if !isJob { markSeen() }
            defer { if isJob { markSeen() } }
            guard let obj, let kind = obj["t"] as? String else {
                drop("payload"); return
            }
            if !o.pinned && kind != "pair-request" { drop("unknown sender"); return }
            if o.pinned {
                lock.lock()
                let t0 = now(); heard[o.envelope.from] = t0
                if t0.timeIntervalSince(heardSaved[o.envelope.from] ?? .distantPast) >= 60 { heardSaved = heard; saveHeard() }   // at most once a minute per peer
                currentSender = o.envelope.from
                lock.unlock()
            }
            defer { lock.lock(); currentSender = nil; lock.unlock() }
            switch kind {
            case "pair-request": if o.pinned { drop("pair-request from a paired peer") } else { handlePairRequest(obj, sender: o.sender) }
            case "pair-accept": handlePairAccept(from: o.envelope.from)
            case "job": handleJob(o.payload, from: o.envelope.from)
            case "event": if let ev = PeerEvent.parse(obj) { receiveEvent(ev, from: o.envelope.from) } else { drop("event payload") }
            case "unpair": handleUnpair(from: o.envelope.from)
            case "say": handleSay(obj, from: o.envelope.from)
            case "stop": handleStop(obj, from: o.envelope.from)
            case "resume": handleResume(obj, from: o.envelope.from)
            case "chat":
                if obj["nack"] is String { handleChatNack(obj, from: o.envelope.from) }
                else if obj["reply"] is [[String: Any]] { handleChatReply(obj, from: o.envelope.from) }
                else { handleChat(obj, from: o.envelope.from) }
            case "offer": handleOffer(obj, from: o.envelope.from)
            case "caps": handleCaps(obj, from: o.envelope.from)
            case "ask": if let l = link(o.envelope.from) { ask.handleAsk(obj, from: l) } else { drop("ask from unknown peer") }
            case "ask-answer": ask.handleAnswer(obj, from: o.envelope.from)
            case "pair-refused": handlePairRefused(from: o.envelope.from)
            case "mesh": handleMesh(obj, from: o.envelope.from)
            case "watch": handleWatch(obj, from: o.envelope.from)
            case "activity": if let a = PeerActivity.parse(obj) { receiveActivity(a, from: o.envelope.from) } else { drop("activity payload") }
            default: drop("unknown kind: \(String(kind.prefix(24).filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }))")
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
        guard let h = hit else { lock.unlock(); drop("pair-request secret"); refusePair(sender); return }
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
        sendCaps(to: link)
        updateWanted()
        changed()
    }

    private func handlePairAccept(from mailbox: String) {
        lock.lock()
        guard let i = links.firstIndex(where: { $0.mailboxId == mailbox }) else { lock.unlock(); return }
        links[i].confirmed = true; saveLinks()
        lastPaired = links[i].label
        let l = links[i]
        lock.unlock()
        sendCaps(to: l)
        changed()
    }

    // MARK: G4+ — join answers, doctor, mesh

    /// The inviter turns a bad code away (used, expired or never minted). Sealed to the sender alone, at most once a minute each.
    private func refusePair(_ sender: PeerKeys) {
        let t = now()
        lock.lock()
        if let last = refusalSentAt[sender.mailboxId], t.timeIntervalSince(last) < 60 { lock.unlock(); return }
        refusalSentAt[sender.mailboxId] = t
        lock.unlock()
        guard let body = try? JSONSerialization.data(withJSONObject: ["t": "pair-refused"]) else { return }
        let id = UUID().uuidString.lowercased()
        guard let blob = PeerSeal.seal(payload: body, id: id, now: t, from: identity, to: sender) else { return }
        enqueue(OutboxItem(id: id, jobId: nil, to: sender.mailboxId, blob: blob, attempt: 0, nextAt: t, owner: nil))
    }

    /// The joiner hears that the code didn't work: forget the waiting link and remember why.
    private func handlePairRefused(from mailbox: String) {
        lock.lock()
        guard let i = links.firstIndex(where: { $0.mailboxId == mailbox }), !links[i].confirmed else { lock.unlock(); return }
        links.remove(at: i); saveLinks()
        refused[mailbox] = "That invite was already used or has expired. Ask them for a new one."
        let dropped = outbox.filter { $0.owner == mailbox }
        outbox.removeAll { $0.owner == mailbox }
        for d in dropped { try? FileManager.default.removeItem(at: outboxURL(d.id)) }
        lock.unlock()
        updateWanted()
        changed()
    }

    enum JoinState: Equatable { case waiting, paired(String), refused(String) }
    /// Where a join stands: waiting for the other side, paired, or turned away (with the plain reason).
    func joinState(mailbox: String) -> JoinState {
        lock.lock(); defer { lock.unlock() }
        if let l = links.first(where: { $0.mailboxId == mailbox }) { return l.confirmed ? .paired(l.label) : .waiting }
        if let why = refused[mailbox] { return .refused(why) }
        return .refused("That pairing is gone. Ask for a new invite.")
    }

    /// `true-peer doctor`.
    func doctorLines() -> [String] {
        let t = now()
        lock.lock()
        let peers = links.map { l -> PeerDoctorPeer in
            let c = caps[l.mailboxId]
            return PeerDoctorPeer(label: l.label, paired: l.confirmed, lastHeard: heard[l.mailboxId],
                                  outbox: outbox.filter { $0.owner == l.mailboxId || $0.to == l.mailboxId }.count,
                                  buildCommit: c?.buildCommit, buildDate: c?.buildDate, sentCard: c != nil,
                                  linkAge: t.timeIntervalSince(l.created))
        }
        let fetched = lastFetch
        lock.unlock()
        let log = (try? String(contentsOf: root.appendingPathComponent("drops.log"), encoding: .utf8)) ?? ""
        let drops = log.split(separator: "\n").compactMap { PeerDrop.parse(String($0)) }
        return PeerDoctor.lines(ownBuild: build, relayUp: transport.isConnected, lastFetch: fetched, peers: peers, drops: drops, now: t)
    }

    // mesh: `mesh?` asks, `reply` answers at once, `times` carries what the asked Mac measured to its own peers.

    private func meshPeerList() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return links.map { ["mailbox": $0.mailboxId, "label": $0.label, "paired": $0.confirmed] }
    }

    /// Start a mesh check: ask every paired Mac. Returns the run id; read it with `meshReport`.
    func meshStart() -> String {
        let id = "m" + UUID().uuidString.lowercased().prefix(8)
        let ls = peerLinks().filter { $0.confirmed }
        lock.lock(); meshRuns[id] = MeshRun(id: id, reportTo: nil, started: monoMs()); lock.unlock()
        for l in ls {
            lock.lock(); meshRuns[id]?.sentAt[l.mailboxId] = monoMs(); lock.unlock()
            _ = sealAndQueue(["t": "mesh", "q": "ask", "run": id, "grid": true], to: l, owner: l.mailboxId)
        }
        return id
    }

    private func meshAskAllowed(_ mailbox: String) -> Bool {
        let t = now()
        lock.lock(); defer { lock.unlock() }
        var times = (meshAskTimes[mailbox] ?? []).filter { t.timeIntervalSince($0) < 60 }
        guard times.count < Self.meshAsksPerMinute else { meshAskTimes[mailbox] = times; return false }
        times.append(t); meshAskTimes[mailbox] = times
        return true
    }

    private func handleMesh(_ obj: [String: Any], from mailbox: String) {
        guard let q = obj["q"] as? String, let run = obj["run"] as? String, run.count <= 40, let l = link(mailbox) else { drop("mesh payload"); return }
        switch q {
        case "ask":
            guard l.confirmed, meshAskAllowed(mailbox) else { drop("mesh ask"); return }
            var reply: [String: Any] = ["t": "mesh", "q": "reply", "run": run, "name": ownName, "peers": meshPeerList()]
            if let b = build { reply["build"] = b.words }
            _ = sealAndQueue(reply, to: l, owner: mailbox)
            if (obj["grid"] as? Bool) == true { meshLeaf(run: run, asker: l) }
        case "reply":
            lock.lock()
            defer { lock.unlock() }
            guard var r = meshRuns[run], let sent = r.sentAt[mailbox], r.replies[mailbox] == nil else { return }
            let peers = ((obj["peers"] as? [[String: Any]]) ?? []).prefix(16).compactMap { p -> (mailbox: String, label: String, paired: Bool)? in
                guard let m = p["mailbox"] as? String, let n = p["label"] as? String, m.count <= 64 else { return nil }
                return (m, String(n.prefix(PeerValidate.maxLabel)), (p["paired"] as? Bool) ?? false)
            }
            r.replies[mailbox] = MeshRun.Reply(ms: monoMs() - sent, name: String(((obj["name"] as? String) ?? l.label).prefix(PeerValidate.maxLabel)),
                                               build: String(((obj["build"] as? String) ?? "").prefix(40)), peers: Array(peers))
            meshRuns[run] = r
            if r.reportTo != nil { meshFinishLeafIfDone(run) }
        case "times":
            lock.lock(); defer { lock.unlock() }
            guard var r = meshRuns[run], r.reportTo == nil else { return }
            var cells: [String: Double?] = [:]
            for c in ((obj["cells"] as? [[String: Any]]) ?? []).prefix(16) {
                guard let m = c["mailbox"] as? String else { continue }
                cells[m] = c["ms"] as? Double
            }
            r.times[mailbox] = cells
            meshRuns[run] = r
        default: drop("mesh payload")
        }
    }

    /// We were asked as part of someone's grid: time our own round trip to each paired Mac (the asker included), then tell the asker.
    private func meshLeaf(run: String, asker: PeerLink) {
        let leaf = "\(run).\(identity.mailboxId.prefix(6))"
        let ls = peerLinks().filter { $0.confirmed }
        lock.lock()
        var r = MeshRun(id: leaf, reportTo: asker.mailboxId, started: monoMs())
        for l in ls { r.sentAt[l.mailboxId] = monoMs() }
        meshRuns[leaf] = r
        lock.unlock()
        for l in ls { _ = sealAndQueue(["t": "mesh", "q": "ask", "run": leaf, "grid": false], to: l, owner: l.mailboxId) }
        scheduler(Self.meshLeafWait) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.meshFinishLeafIfDone(leaf, force: true); self.lock.unlock()
        }
    }

    /// Caller holds `lock`.
    private func meshFinishLeafIfDone(_ leaf: String, force: Bool = false) {
        guard var r = meshRuns[leaf], let to = r.reportTo, !r.reported, force || r.replies.count == r.sentAt.count else { return }
        r.reported = true
        meshRuns[leaf] = nil
        let cells: [[String: Any]] = r.sentAt.keys.sorted().map { m in
            if let rep = r.replies[m] { return ["mailbox": m, "ms": rep.ms] }
            return ["mailbox": m]
        }
        guard let l = links.first(where: { $0.mailboxId == to }) else { return }
        let payload: [String: Any] = ["t": "mesh", "q": "times", "run": String(leaf.split(separator: ".").first ?? ""), "cells": cells]
        net.async { [weak self] in _ = self?.sealAndQueue(payload, to: l, owner: l.mailboxId) }
    }

    /// Everything a mesh run knows so far. `done` once every asked Mac has answered and sent its own timings.
    func meshReport(_ id: String) -> (lines: [String], done: Bool) {
        lock.lock()
        guard let r = meshRuns[id] else { lock.unlock(); return (["No such mesh check."], true) }
        let mine = identity.mailboxId
        let asked = r.sentAt.keys.sorted()
        let ownLabels = Dictionary(links.map { ($0.mailboxId, $0.label) }, uniquingKeysWith: { a, _ in a })
        var nodes = [MeshRun.Node(mailbox: mine, label: ownName)]
        var labels = ownLabels
        for m in asked { nodes.append(.init(mailbox: m, label: ownLabels[m] ?? "Peer")) }
        var paired: Set<String> = []
        func key(_ a: String, _ b: String) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }
        for m in asked { paired.insert(key(mine, m)) }
        var ms: [String: [String: Double?]] = [mine: [:]]
        for (m, rep) in r.replies { ms[mine]?[m] = rep.ms }
        for (m, rep) in r.replies {
            for p in rep.peers where p.mailbox != mine {
                if labels[p.mailbox] == nil { labels[p.mailbox] = p.label; nodes.append(.init(mailbox: p.mailbox, label: p.label)) }
                if p.paired { paired.insert(key(m, p.mailbox)) }
            }
        }
        for (m, cells) in r.times { ms[m] = cells }
        let waitingOn = asked.filter { r.replies[$0] == nil || r.times[$0] == nil }
        lock.unlock()
        var out = MeshGrid.render(nodes: nodes, ms: ms, paired: paired, ownMailbox: mine)
        out.append("")
        for m in asked {
            let name = ownLabels[m] ?? "Peer"
            if let rep = r.replies[m] {
                let states = rep.peers.map { "\($0.label) \($0.paired ? "paired" : "waiting for the other side")" }
                out.append("\(name): answered in \(MeshGrid.cell(rep.ms))\(rep.build.isEmpty ? "" : ", True \(rep.build)"). Sees: \(states.isEmpty ? "nobody" : states.joined(separator: ", ")).")
            } else {
                out.append("\(name): no answer. Their True may be older than \(ownName)'s, or their Mac is asleep or offline.")
            }
        }
        return (out, waitingOn.isEmpty)
    }

    private func handleUnpair(from mailbox: String) { removeLink(mailbox, who: "them") }

    private func handleJob(_ payload: Data, from mailbox: String) {
        guard case .success(let job) = PeerValidate.parseJob(payload) else { drop("job payload"); return }
        lock.lock(); let link = links.first { $0.mailboxId == mailbox }; lock.unlock()
        guard let link else { drop("job from unknown peer"); return }
        receiveJob(job, from: link)
    }

    /// Group tab (S1): the one listener on the shared stream; survives a restart of the sync.
    nonisolated(unsafe) var groupObserver: (@Sendable (SSEEvent) -> Void)?
    /// G7: Steward's allowance board (`GET /allowance`) over the same transport as the grant snapshot. Nil until grant sync starts.
    nonisolated(unsafe) var allowanceFetch: (@Sendable () throws -> Data)?
    /// G9: Steward's `GET /items/{id}/placement`. Nil until grant sync starts.
    nonisolated(unsafe) var placementFetch: (@Sendable (String) throws -> Data)?
    /// G9: where the owner's last prompt time is kept, and the runner's start/decline trail. Tests point both at a temp dir.
    nonisolated(unsafe) var groupDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".true/group")

    var placementEnv: PlacementEnv {
        let dir = groupDir
        return PlacementEnv(
            myDevice: { [grants] in grants.deviceId },
            fetchPlacement: { [placementFetch] id in
                guard let f = placementFetch else { throw PeerError.invalid("Steward not connected") }
                return try f(id)
            },
            fetchBoard: { [allowanceFetch] in
                guard let f = allowanceFetch else { throw PeerError.invalid("Steward not connected") }
                return try f()
            },
            lastPrompt: { (try? String(contentsOf: dir.appendingPathComponent("last-prompt"), encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } },
            now: now)
    }

    /// G9: may this NEW job skip the Accept button? Only a placed job that passes all five checks; everything else asks.
    private func placementAutoAccept(_ job: PeerJobRequest, link: PeerLink) -> Bool {
        guard let pid = job.placement else { return false }
        let target: GrantTarget
        switch PeerRun.choose(for: job) {
        case .repo: target = .repo(job.repo)
        case .dir: target = .dir(PeerDirs.realDirectory(job.dir ?? "") ?? job.dir ?? "")
        case .scratch: target = .scratch
        }
        let holds = grants.holdsWork(peerKey: PeerB64.std(link.keys.sign), target: target)
        return PlacementGate.decide(placementId: pid, title: job.title, brief: job.brief, senderHoldsWork: holds, env: placementEnv) == .auto
    }

    /// One blocking snapshot fetch on the shared sync; call off the main thread.
    func refreshGrantsNow() { grantSync?.refresh() }

    /// Keep the grant snapshot fresh (SSE + 60 s poll). Safe to call once at app start; grants mode itself stays off until switched on.
    func startGrantSync(_ transport: GrantTransport, onEvent: (@Sendable (SSEEvent) -> Void)? = nil) {
        grantSync?.stop()
        allowanceFetch = { try transport.fetchAllowance() }
        placementFetch = { try transport.fetchPlacement($0) }
        let s = GrantSync(cache: grants, transport: transport, scheduler: scheduler)
        if let onEvent { s.observe(onEvent) }
        s.observe { [weak self] e in self?.groupObserver?(e) }
        grantSync = s
        s.start()
    }

    /// Sign-out or revoke: stop listening to Steward and forget every grant file.
    func stopGrantSync(clearCache: Bool) {
        grantSync?.stop(); grantSync = nil; allowanceFetch = nil; placementFetch = nil
        if clearCache { grants.clear() }
    }

    /// why a NEW peer job may not run, or nil. Always nil with grants mode off, so today's behaviour is untouched.
    /// Only the peer-receive path calls this; the person's own jobs on their own Mac never do.
    private func grantRefusal(_ req: PeerJobRequest, link: PeerLink) -> String? {
        guard grants.isEnforcing else { return nil }
        let target: GrantTarget
        switch PeerRun.choose(for: req) {
        case .repo: target = .repo(req.repo)
        case .dir:
            let d = req.dir ?? ""
            if PeerDirs.isHomeOrEmpty(d), let planned = PeerDirs.autoFolder(title: req.title, create: false) { target = .dir(planned); break }
            target = .dir(PeerDirs.realDirectory(d) ?? URL(fileURLWithPath: (d as NSString).expandingTildeInPath).standardizedFileURL.path)
        case .scratch: target = .scratch
        }
        return grants.refusal(peerKey: PeerB64.std(link.keys.sign), target: target)
    }

    private func receiveJob(_ job: PeerJobRequest, from link: PeerLink) {
        lock.lock()
        if inbound.contains(where: { $0.req.jobId == job.jobId }) { lock.unlock(); drop("job id seen"); return }
        if let why = grantRefusal(job, link: link) {
            let j = InboundJob(req: job, peerLabel: link.label, peerMailbox: link.mailboxId, status: .declined, note: why, inboundMode: inboundMode(),
                               flags: [], received: now(), finished: now(), branch: job.missionBranch ?? PeerNaming.branch(label: link.label, jobId: job.jobId), steering: steering())
            inbound.append(j); saveInbound()
            lock.unlock()
            log(j); report(j, .failed, why); changed()
            return
        }
        // Run 34: a job on a shared repo (repo or dir form) is always approved one by one, whatever the global mode says.
        // G9: a placed job that Steward confirms for this Mac, from a sender with a work grant, with lend + pool on, the owner away and a clean brief, may skip Accept.
        let mode: PeerInboundMode = onSharedRepo(job) ? .ask : (placementAutoAccept(job, link: link) ? (inboundMode() == .ask ? .auto : inboundMode()) : inboundMode())
        let screened = InjectionScreen.screen(job.title + "\n" + job.brief)
        var j = InboundJob(req: job, peerLabel: link.label, peerMailbox: link.mailboxId, status: mode == .ask ? .queued : .accepted,
                           note: mode == .ask ? "Waiting for you" : "Starting", inboundMode: mode, flags: screened.reasons,
                           received: now(), finished: nil, branch: job.missionBranch ?? PeerNaming.branch(label: link.label, jobId: job.jobId), steering: steering())
        if mode == .ask { j.acceptSince = now() }
        inbound.append(j); saveInbound()
        lock.unlock()
        if let s = j.acceptSince { scheduleAcceptReminders(j.id, since: s) }
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
        let before = inbound[i]
        f(&inbound[i]); saveInbound()
        if before.status != inbound[i].status || before.desk != inbound[i].desk || before.lane != inbound[i].lane || before.pane != inbound[i].pane { cardChanged() }
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

    private func repoClone(_ j: InboundJob) -> String? {
        let shared = (sharedRepos()[j.peerMailbox] ?? []).first { PeerRepo.same($0.url, j.req.repo) && FileManager.default.fileExists(atPath: $0.path) }?.path
        return shared ?? launcher.resolveClone(repo: j.req.repo)
    }

    /// Missions M1.2: the accept check failed (no clone, fetch, folder not allowed): the job waits for the sender's fix as `needsYou`.
    private func acceptFailed(_ jobId: String, _ reason: String) {
        guard let u = update(jobId, { $0.status = .needsYou; $0.note = reason; $0.acceptFailed = true }) else { return }
        log(u); report(u, .needsYou, reason); changed()
        if let key = u.desk { work.async { [self] in startNextInLine(key) } }
    }

    private func run(_ jobId: String, flags: [String]) {
        guard let j = inboundJobs().first(where: { $0.id == jobId }), !j.status.isFinal else { return }
        // G1: a grant revoked (or Steward gone stale) while the job waited for approval stops it here. Jobs already running are never touched.
        lock.lock(); let senderLink = links.first { $0.mailboxId == j.peerMailbox }; lock.unlock()
        if let senderLink, let why = grantRefusal(j.req, link: senderLink) { end(jobId, .declined, why, reportAs: .failed); return }
        // G9: the runner's own check before a placed job starts: decline if the owner is at the Mac or its own reading is at the pooled hold.
        if let pid = j.req.placement, let id = PlacementID.parse(pid) {
            let c = PlacementGate.startCheck(item: id.item, env: placementEnv)
            PlacementGate.appendStartLine(c.line, to: groupDir.appendingPathComponent("starts.log"))
            if !c.start { end(jobId, .declined, c.why ?? "Declined", reportAs: .failed); return }
        }
        if PeerMode.effective(requested: j.req.mode, inboundFlags: flags, builderInstalled: launcher.canRunBackground) == .pane,
           deskOn(), let key = deskKey(for: j) {
            runDesk(j, key: key, flags: flags); return
        }
        let label = j.peerLabel
        let dir = jobDir(jobId)
        let resultP = resultPath(jobId)
        let clone: String?, wt: String, envelope: String, role: String
        switch PeerRun.choose(for: j.req) {
        case .repo:
            guard let c = repoClone(j) else { acceptFailed(jobId, "No local clone of \(j.req.repo)"); return }
            clone = c
            wt = PeerNaming.worktree(clone: c, jobId: jobId)
            if let err = launcher.prepareWorktree(clone: c, base: j.req.base, branch: j.branch, worktree: wt) {
                acceptFailed(jobId, err); return
            }
            envelope = PeerText.envelope(label: label, job: j.req, branch: j.branch, worktree: wt, resultPath: resultP)
            role = PeerText.roleCard(label: label, branch: j.branch, worktree: wt, resultPath: resultP)
        case .dir:
            let sender = senderLink.map { PeerB64.std($0.keys.sign) }
            let gate: ((String) -> String?)? = grants.isEnforcing ? { [grants] real in sender.flatMap { grants.refusal(peerKey: $0, target: .dir(real)) } ?? (sender == nil ? GrantRules.notInGroup : nil) } : nil
            switch PeerDirs.resolve(path: j.req.dir ?? "", allowed: allowedDirs() + (sharedRepos()[j.peerMailbox] ?? []).map(\.path).filter { !$0.isEmpty }, title: j.req.title, makeFolder: true, grant: gate) {
            case .failure(let e):
                if case .invalid(let m) = e { acceptFailed(jobId, m) } else { acceptFailed(jobId, "Directory not allowed") }
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
        markStarting(jobId)
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
        clearStarting(jobId)
        changed()
    }

    // MARK: receiver — desks (Run 35)

    /// `<mailbox>|repo:<normalised url>` / `dir:<resolved dir>` / `scratch`. nil = a dir job we can't resolve (the normal path reports why).
    private func deskKey(for j: InboundJob) -> String? {
        switch PeerRun.choose(for: j.req) {
        case .repo: return PeerNaming.deskKey(mailbox: j.peerMailbox, project: "repo:" + (PeerRepo.normalize(j.req.repo) ?? j.req.repo))
        case .dir:
            // A job aimed at home / nowhere gets its own folder at accept time; it never shares a desk with another job.
            if PeerDirs.isHomeOrEmpty(j.req.dir ?? "") { return PeerNaming.deskKey(mailbox: j.peerMailbox, project: "auto:" + j.id) }
            guard case .success(let real) = PeerDirs.resolve(path: j.req.dir ?? "", allowed: allowedDirs() + (sharedRepos()[j.peerMailbox] ?? []).map(\.path).filter { !$0.isEmpty }) else { return nil }
            return PeerNaming.deskKey(mailbox: j.peerMailbox, project: "dir:" + real)
        case .scratch: return PeerNaming.deskKey(mailbox: j.peerMailbox, project: "scratch")
        }
    }

    /// Put a job in line for its desk (status stays `accepted`; no pane yet). Reports only the first time.
    private func holdInLine(_ j: InboundJob, key: String, note: String) {
        if let u = update(j.id, { $0.desk = key; $0.note = note }), j.desk == nil { report(u, .accepted, note) }
        changed()
    }

    /// Missions M1.4: the lane a desk job runs on. Same branch as a live job → that job's lane; else the first free lane; else it waits on the least busy one.
    private func chooseLane(_ j: InboundJob, key: String) -> Int {
        if let l = j.lane { return l }
        let n = max(1, min(4, laneCount()))
        lock.lock()
        let live = inbound.filter { $0.desk == key && !$0.status.isFinal && $0.status != .paused && $0.id != j.id }
        lock.unlock()
        if j.req.hasRepo, let same = live.first(where: { $0.branch == j.branch && $0.req.hasRepo }) { return same.lane ?? 1 }
        func busy(_ lane: Int) -> Bool { live.contains { ($0.lane ?? 1) == lane && ($0.pane.map { launcher.paneAlive($0) } ?? ($0.received < j.received)) } }
        if let free = (1...n).first(where: { !busy($0) }) { return free }
        return (1...n).min { a, b in live.filter { ($0.lane ?? 1) == a }.count < live.filter { ($0.lane ?? 1) == b }.count } ?? 1
    }

    /// Test hooks: the per-clone git lock, and a way to age a record (pre-upgrade lane, shared branch).
    func cloneLockForTest(_ clone: String) -> NSLock { cloneLock(clone) }
    func laneForTest(_ j: InboundJob) -> Int { chooseLane(j, key: j.desk ?? "") }
    func mutateForTest(_ jobId: String, _ f: (inout InboundJob) -> Void) { _ = update(jobId, f) }

    private func cloneLock(_ clone: String) -> NSLock {
        lock.lock(); defer { lock.unlock() }
        if let l = cloneLocks[clone] { return l }
        let l = NSLock(); cloneLocks[clone] = l; return l
    }

    private func runDesk(_ j: InboundJob, key: String, flags: [String]) {
        let jobId = j.id, label = j.peerLabel, dir = jobDir(jobId), resultP = resultPath(jobId)
        let lane = chooseLane(j, key: key)
        if j.lane != lane { _ = update(jobId) { $0.lane = lane } }
        lock.lock()
        let others = inbound.filter { $0.desk == key && ($0.lane ?? 1) == lane && !$0.status.isFinal && $0.status != .paused && $0.id != jobId }
        let last = inbound.last { $0.desk == key && ($0.lane ?? 1) == lane && $0.pane != nil && $0.id != jobId }
        let hadDesk = inbound.contains { $0.desk == key && ($0.lane ?? 1) == lane && $0.worktree != nil && $0.id != jobId }
        lock.unlock()
        // Busy: a running job on a live pane, or an older job still waiting its turn.
        if let blocker = others.first(where: { o in o.pane.map { launcher.paneAlive($0) } ?? (o.received < j.received) }) {
            holdInLine(j, key: key, note: "In line behind \(blocker.req.title)" + (blocker.branch == j.branch && j.req.hasRepo ? " (same branch)" : "")); return
        }
        let clone: String?, wt: String, envelope: String
        switch PeerRun.choose(for: j.req) {
        case .repo:
            guard let c = repoClone(j) else { acceptFailed(jobId, "No local clone of \(j.req.repo)"); return }
            clone = c
            wt = PeerNaming.deskWorktree(clone: c, label: label, lane: lane)
            let gl = cloneLock(c); gl.lock()
            let prepErr = launcher.prepareWorktree(clone: c, base: j.req.base, branch: j.branch, worktree: wt)
            gl.unlock()
            if let err = prepErr { acceptFailed(jobId, err); return }
            envelope = PeerText.envelope(label: label, job: j.req, branch: j.branch, worktree: wt, resultPath: resultP, checkoutFirst: hadDesk)
        case .dir:
            clone = nil
            wt = String(key.split(separator: "|", maxSplits: 1).last.map { $0.dropFirst(4) } ?? "")
            envelope = PeerText.envelopeDir(label: label, job: j.req, dir: wt, resultPath: resultP)
        case .scratch:
            let scratch = PeerNaming.deskScratch(root: root, mailbox: j.peerMailbox)
            do { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { end(jobId, .failed, "Couldn't make a work folder for the job", reportAs: .failed); return }
            clone = nil
            wt = scratch.path
            envelope = PeerText.envelopeNoRepo(label: label, job: j.req, workDir: wt, resultPath: resultP)
        }
        let role = PeerText.roleCardDesk(label: label, workDir: wt)
        Self.write(Data(envelope.utf8), to: dir.appendingPathComponent("envelope.md"))
        Self.write(Data(role.utf8), to: dir.appendingPathComponent("role.md"))
        let prompt = PeerText.firstPrompt(envelopePath: dir.appendingPathComponent("envelope.md").path)
        var pane: UUID?
        // Reuse the desk pane only if it's alive, wasn't stopped, and was opened under the same permission mode.
        if let l = last, let lp = l.pane, l.inboundMode == j.inboundMode, launcher.paneAlive(lp) {
            lock.lock(); let gone = retired.contains(lp); lock.unlock()
            if !gone {
                if launcher.atPermissionPrompt(pane: lp) {
                    holdInLine(j, key: key, note: "In line — waiting for an answer on the desk")
                    scheduler(3) { [weak self] in self?.work.async { self?.run(jobId, flags: flags) } }
                    return
                }
                markStarting(jobId)
                if launcher.deliverToPane(lp, line: prompt) { pane = lp }
            }
        }
        if pane == nil {
            markStarting(jobId)
            pane = launcher.launchPane(agentName: PeerNaming.deskAgentName(label: label, project: PeerNaming.deskProject(key)), label: label, cwd: wt, flags: flags,
                                       rolePath: dir.appendingPathComponent("role.md").path, firstPrompt: prompt)
            if pane == nil { end(jobId, .failed, "Couldn't open a tab for the job", reportAs: .failed); return }
        }
        if let u = update(jobId, { $0.clone = clone; $0.worktree = wt; $0.pane = pane; $0.desk = key; $0.note = "Started" }) {
            report(u, .accepted, "Started")
        }
        clearStarting(jobId)
        changed()
    }

    /// The desk's oldest job in line starts now (its running job just ended).
    private func startNextInLine(_ key: String) {
        lock.lock()
        var heads: [InboundJob] = []
        for j in inbound where j.desk == key && !j.status.isFinal && j.status != .paused && j.pane == nil && !heads.contains(where: { ($0.lane ?? 1) == (j.lane ?? 1) }) { heads.append(j) }
        lock.unlock()
        for next in heads { run(next.id, flags: next.inboundMode.claudeFlags) }
    }

    /// Live desks for the Peers sheet: the running job (if any) and how many wait.
    struct DeskInfo: Equatable, Sendable { var key: String; var peer: String; var project: String; var running: String?; var inLine: Int; var lane: Int = 1 }
    func desks() -> [DeskInfo] {
        lock.lock(); defer { lock.unlock() }
        var out: [DeskInfo] = []
        for key in Array(Set(inbound.compactMap(\.desk))).sorted() {
            let all = inbound.filter { $0.desk == key && !$0.status.isFinal }
            for lane in Set(all.map { $0.lane ?? 1 }).sorted() {
                let live = all.filter { ($0.lane ?? 1) == lane }
                out.append(DeskInfo(key: key, peer: live[0].peerLabel, project: PeerNaming.deskProject(key), running: live.first { $0.pane != nil }?.req.title,
                                    inLine: live.filter { $0.pane == nil }.count, lane: lane))
            }
        }
        return out
    }
    /// Run 35: how many jobs wait behind this one's desk (0 when it has none).
    func inLineCount(desk key: String?) -> Int {
        guard let key else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return inbound.filter { $0.desk == key && !$0.status.isFinal && $0.pane == nil }.count
    }

    // MARK: receiver — hook events

    /// A pane hook fired. Report only when the status actually changes; final states are sticky.
    func paneEvent(pane: UUID, kind: PeerEventMap.Kind, message: String = "", tool: String? = nil, detail: String? = nil) {
        lock.lock(); let cj = inbound.first { $0.pane == pane && !$0.status.isFinal }; lock.unlock()
        if let cj { captureSession(cj) }
        lock.lock(); let j = inbound.first { $0.pane == pane && !$0.status.isFinal }; lock.unlock()
        guard let j else { return }
        if kind == .error {
            work.async { [weak self] in
                guard let self else { return }
                self.resumeLock.lock(); defer { self.resumeLock.unlock() }
                self.lock.lock(); let current = self.inbound.first { $0.id == j.id }; self.lock.unlock()
                guard let current, current.pane == pane, !current.status.isFinal, current.status != .paused else { return }
                let reason = PeerMask.firstLine(message.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")
                if PeerResume.isUsageLimit(message) {
                    let at = PeerResume.resumeTime(from: message, now: self.now())
                    self.pause(j.id, reason: "Usage limit", at: at ?? self.now().addingTimeInterval(PeerResume.unknownWait), known: at != nil)
                } else if PeerResume.isTransient(message) {
                    self.pauseForTransient(j, reason: reason.isEmpty ? "Claude stopped with an error" : reason, session: self.sessionFor(current))
                } else {
                    self.pause(j.id, reason: reason.isEmpty ? "Claude stopped with an error" : reason, at: self.now(), known: true)
                    self.performResume(j.id)
                }
            }
            return
        }
        guard j.status != .paused else { return }
        trackPermissionPrompt(j, kind: kind, tool: tool)
        queueActivity(j, Self.items(kind: kind, message: message, tool: tool, detail: detail, at: now(), level: share()))
        let exists = FileManager.default.fileExists(atPath: resultPath(j.id))
        guard let s = PeerEventMap.status(kind, resultExists: exists), s != j.status else { return }
        if s == .done || s == .failed { end(j.id, s, s == .done ? "Finished" : Self.withReason("Hit an error", takeError(j.id)), reportAs: s); return }
        if let u = update(j.id, { $0.status = s; $0.note = s == .working ? "Working" : s == .needsYou ? "Needs you" : "Waiting" }) {
            report(u, s, u.note)
        }
        changed()
    }

    /// The condensed activity a hook event stands for: a tool name (+ first input line), the last assistant text, or a question.
    static func items(kind: PeerEventMap.Kind, message: String, tool: String?, detail: String?, at: Date, level: PeerShare = .activity) -> [PeerActivityItem] {
        let t = Int(at.timeIntervalSince1970)
        switch kind {
        case .progress:
            let name = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "prompt" else { return [] }
            let d = safeDetail(tool: name, detail: detail, level: level)
            return [PeerActivityItem(t: t, kind: .tool, text: PeerMask.firstLine(d.isEmpty ? name : "\(name) · \(d)"))]
        case .stop:
            let text = PeerMask.text(message, limit: level == .everything ? PeerActivityItem.maxLong : PeerActivityItem.maxText)
            return text.isEmpty ? [] : [PeerActivityItem(t: t, kind: .assistant, text: text)]
        case .need:
            let d = detail.map { PeerMask.firstLine($0) } ?? ""
            let text = PeerMask.text(d.isEmpty ? message : "\(message) — \(tool ?? ""): \(d)")
            return text.isEmpty ? [] : [PeerActivityItem(t: t, kind: .question, text: text)]
        case .error, .other: return []
        }
    }

    /// What of a tool's input may leave the Mac: Activity = file paths, search patterns, a URL's host — never commands or
    /// prompts; Everything = the first line of whatever the tool was given. Status never gets here.
    static func safeDetail(tool: String, detail: String?, level: PeerShare) -> String {
        guard let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return "" }
        if level == .everything { return d }
        switch tool {
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "Grep", "Glob": return d
        case "WebFetch": return URL(string: d)?.host ?? ""
        default: return tool.hasPrefix("mcp__") ? d : ""
        }
    }

    func paneClosed(pane: UUID) {
        lock.lock(); let j = inbound.first { $0.pane == pane && !$0.status.isFinal }; lock.unlock()
        guard let j, j.status != .paused else { return }
        if FileManager.default.fileExists(atPath: resultPath(j.id)) { end(j.id, .done, "Finished", reportAs: .done) }
        else { end(j.id, .failed, "Closed before it finished", reportAs: .failed) }
    }

    /// Hub updates arrive on the main actor. Never block it behind a resume that is opening a pane.
    func builderUpdate(_ record: BuilderRecord) {
        work.async { [weak self] in
            self?.builderUpdate(name: record.name, state: record.state, dir: record.dir, waitReason: record.waitReason,
                                resumeAt: record.resumeAt.map { Date(timeIntervalSince1970: $0) }, run: record.runs)
        }
    }

    /// Compatibility for callers that only know whether the builder ended.
    func builderUpdate(name: String, running: Bool, dir: String? = nil) {
        builderUpdate(name: name, state: running ? .running : .done, dir: dir)
    }

    func builderUpdate(name: String, state: BuilderState, dir: String? = nil, waitReason: String? = nil, resumeAt: Date? = nil, run: Int? = nil) {
        resumeLock.lock(); defer { resumeLock.unlock() }
        lock.lock(); let j = inbound.first { $0.builder == name && !$0.status.isFinal }; lock.unlock()
        guard let j else { return }
        if let run {
            guard run >= (j.builderRun ?? run) else { return }
            if run != j.builderRun { _ = update(j.id) { $0.builderRun = run } }
        }
        if state == .waiting {
            let reason = PeerMask.firstLine(waitReason ?? "Usage limit").replacingOccurrences(of: "_", with: " ")
            pause(j.id, reason: reason.isEmpty ? "Usage limit" : reason, at: resumeAt, known: resumeAt != nil, builderOwned: true)
            return
        }
        if state.isLive {
            guard state == .running else { return }
            if let dir { startTailer(j, dir: dir) }
            guard j.status != .working else { return }
            if let u = update(j.id, { $0.status = .working; $0.note = "Working"; $0.builderOwnsPause = nil; $0.pausedReason = nil; $0.resumeAt = nil }) { report(u, .working, "Working") }
            changed()
        } else if j.status == .paused && j.builderOwnsPause != true {
            return // The same finished builder may be polled again before our resume timer fires.
        } else if FileManager.default.fileExists(atPath: resultPath(j.id)) {
            end(j.id, .done, "Finished", reportAs: .done)
        } else {
            let reason = dir.flatMap { Self.builderFailureReason(dir: $0) }
            if let dir { startTailer(j, dir: dir) }
            lock.lock(); let tailer = tailers[j.id]; lock.unlock()
            tailer?.sync()
            lock.lock(); let session = inbound.first { $0.id == j.id }?.sessionId; lock.unlock()
            if launcher.canResumeBackground, session != nil {
                if let r = reason, PeerResume.isUsageLimit(r) {
                    let at = PeerResume.resumeTime(from: r, now: now())
                    pause(j.id, reason: "Usage limit", at: at ?? now().addingTimeInterval(PeerResume.unknownWait), known: at != nil); return
                }
                if let r = reason, PeerResume.isTransient(r) {
                    pauseForTransient(j, reason: PeerMask.firstLine(r), session: session); return
                }
                if (j.resumes ?? 0) < PeerResume.maxResumes {
                    pause(j.id, reason: PeerMask.firstLine(reason ?? "Claude stopped with an error"), at: now(), known: true)
                    performResume(j.id); return
                }
            }
            end(j.id, .failed, Self.withReason("Ended without a result", reason), reportAs: .failed)
        }
    }

    // MARK: Missions M1 — pause and resume

    /// Builder waiting is observed only; all other pauses belong to the engine.
    private func pause(_ jobId: String, reason: String, at: Date?, known: Bool, builderOwned: Bool = false) {
        resumeLock.lock(); defer { resumeLock.unlock() }
        let note = known ? "Paused: \(reason)" : "Paused: \(reason), reset time unknown"
        lock.lock(); let cur = inbound.first { $0.id == jobId }; lock.unlock()
        guard let cur, !cur.status.isFinal else { return }
        if cur.status == .paused && cur.pausedReason == reason && cur.resumeAt == at && (cur.builderOwnsPause == true) == builderOwned { return }
        guard let u = update(jobId, { $0.status = .paused; $0.pausedReason = reason; $0.resumeAt = at; $0.note = note; $0.builderOwnsPause = builderOwned }) else { return }
        stopTailer(jobId)
        report(u, .paused, note)
        changed()
        if !builderOwned, let at { scheduleResume(jobId, at: at) }
    }

    /// 100x 2b: an API hiccup (`server_error`, overloaded, 5xx) waits 1 / 5 / 15 min, then resumes the same session.
    /// No session id, or past `maxResumes`, ends the job; its note carries the reason, so the cause reads `api`.
    private func pauseForTransient(_ j: InboundJob, reason: String, session: String?) {
        let used = j.resumes ?? 0
        guard session != nil, used < PeerResume.maxResumes else {
            let base = session == nil ? "Hit an error" : "Stopped after \(PeerResume.maxResumes) restarts"
            end(j.id, .failed, Self.withReason(base, reason), reportAs: .failed); return
        }
        pause(j.id, reason: reason, at: now().addingTimeInterval(PeerResume.backoff(resumes: used)), known: true)
    }

    private func stopTailer(_ jobId: String) {
        lock.lock(); let tl = tailers.removeValue(forKey: jobId); lock.unlock()
        tl?.sync(); tl?.stop()
    }

    private func scheduleResume(_ jobId: String, at: Date) {
        scheduler(max(1, at.timeIntervalSince(now()))) { [weak self] in
            guard let self else { return }
            self.work.async {
                self.resumeLock.lock(); defer { self.resumeLock.unlock() }
                self.lock.lock(); let cur = self.inbound.first { $0.id == jobId }; self.lock.unlock()
                if cur?.status == .paused, cur?.builderOwnsPause != true, cur?.resumeAt == at, at <= self.now().addingTimeInterval(1) { self.performResume(jobId) }
            }
        }
    }

    /// The Claude session a job continues: its own, else (desk) the lane's newest.
    private func sessionFor(_ j: InboundJob) -> String? {
        if let s = j.sessionId { return s }
        if let p = j.pane, let s = launcher.sessionId(forPane: p) { return s }
        guard let key = j.desk else { return nil }
        lock.lock(); defer { lock.unlock() }
        return inbound.last { $0.desk == key && $0.sessionId != nil }?.sessionId
    }

    private func captureSession(_ j: InboundJob) {
        guard j.sessionId == nil, let p = j.pane, let s = launcher.sessionId(forPane: p) else { return }
        _ = update(j.id) { $0.sessionId = s }
    }

    /// Relaunch a paused / interrupted job under its own Claude session. Past the cap, or with no session, it fails.
    func performResume(_ jobId: String) {
        resumeLock.lock(); defer { resumeLock.unlock() }
        lock.lock(); let cur = inbound.first { $0.id == jobId }; lock.unlock()
        guard let j = cur, j.status == .paused, j.builderOwnsPause != true else { return }
        guard let sid = sessionFor(j), let wt = j.worktree else {
            end(jobId, .failed, Self.withReason("Hit an error", j.pausedReason), reportAs: .failed); return
        }
        let n = (j.resumes ?? 0) + 1
        guard n <= PeerResume.maxResumes else { end(jobId, .failed, Self.withReason("Stopped after \(PeerResume.maxResumes) restarts", j.pausedReason), reportAs: .failed); return }
        stopTailer(jobId)
        // StopFailure leaves Claude alive. Close that tab while the job is still paused,
        // before a second process can resume the same session.
        if let old = j.pane, launcher.paneAlive(old) { launcher.stop(panes: [old], builders: []) }
        let dir = jobDir(jobId)
        var pane: UUID?, builder: String?
        if j.desk != nil {
            let prompt = "Continue job \(j.req.title) (\(jobId)) from where it stopped. The jobs before it are finished; don't touch them."
            pane = launcher.launchPane(agentName: PeerNaming.deskAgentName(label: j.peerLabel, project: PeerNaming.deskProject(j.desk ?? "")), label: j.peerLabel, cwd: wt, flags: j.inboundMode.claudeFlags,
                                       rolePath: dir.appendingPathComponent("role.md").path, firstPrompt: prompt, resumeSession: sid)
            if pane == nil { end(jobId, .failed, "Couldn't open a tab for the job", reportAs: .failed); return }
        } else if j.builder != nil {
            let name = launcher.keepsBuilderOnResume ? (j.builder ?? PeerNaming.agentName(label: j.peerLabel, jobId: jobId)) : PeerNaming.agentName(label: j.peerLabel, jobId: jobId) + "-r\(n)"
            // The live builder keeps its name. Reserve its next run before a stale Hub poll can arrive.
            if let run = j.builderRun { _ = update(jobId) { $0.builderRun = run + 1 } }
            if let err = launcher.launchBackground(agentName: name, parent: PeerNaming.parentName(label: j.peerLabel), cwd: wt, prompt: "Continue from where you stopped.", resumeSession: sid) {
                end(jobId, .failed, err, reportAs: .failed); return
            }
            builder = name
        } else {
            pane = launcher.launchPane(agentName: PeerNaming.agentName(label: j.peerLabel, jobId: jobId), label: j.peerLabel, cwd: wt, flags: j.inboundMode.claudeFlags,
                                       rolePath: dir.appendingPathComponent("role.md").path, firstPrompt: "Continue from where you stopped.", resumeSession: sid)
            if pane == nil { end(jobId, .failed, "Couldn't open a tab for the job", reportAs: .failed); return }
        }
        if let u = update(jobId, { $0.status = .working; $0.note = "Resumed"; $0.sessionId = sid; $0.resumes = n; $0.builderOwnsPause = nil; $0.pausedReason = nil; $0.resumeAt = nil; $0.pane = pane; $0.builder = builder ?? $0.builder }) {
            report(u, .working, "Resumed")
        }
        changed()
    }

    /// A fix round: re-open a finished peer job's own session with the sender's note in the prompt, so the worker fixes
    /// the merge and pushes again. Without a session/worktree there is nothing to resume, so it just reports as before.
    private func performFixResume(_ jobId: String, note: String) {
        resumeLock.lock(); defer { resumeLock.unlock() }
        lock.lock(); let cur = inbound.first { $0.id == jobId }; lock.unlock()
        guard let j = cur, j.status.isFinal else { return }
        guard let sid = sessionFor(j), let wt = j.worktree else { report(j, j.status, j.note); return }
        stopTailer(jobId)
        if let old = j.pane, launcher.paneAlive(old) { launcher.stop(panes: [old], builders: []) }
        let dir = jobDir(jobId)
        let prompt = MissionFixPrompt.resume(note: note, branch: j.branch)
        let n = (j.resumes ?? 0) + 1
        var pane: UUID?, builder: String?
        if j.desk != nil {
            pane = launcher.launchPane(agentName: PeerNaming.deskAgentName(label: j.peerLabel, project: PeerNaming.deskProject(j.desk ?? "")), label: j.peerLabel, cwd: wt, flags: j.inboundMode.claudeFlags,
                                       rolePath: dir.appendingPathComponent("role.md").path, firstPrompt: prompt, resumeSession: sid)
            if pane == nil { report(j, j.status, j.note); return }
        } else if j.builder != nil {
            let name = launcher.keepsBuilderOnResume ? (j.builder ?? PeerNaming.agentName(label: j.peerLabel, jobId: jobId)) : PeerNaming.agentName(label: j.peerLabel, jobId: jobId) + "-r\(n)"
            if let run = j.builderRun { _ = update(jobId) { $0.builderRun = run + 1 } }
            if let err = launcher.launchBackground(agentName: name, parent: PeerNaming.parentName(label: j.peerLabel), cwd: wt, prompt: prompt, resumeSession: sid) {
                report(j, j.status, j.note); return
            }
            builder = name
        } else {
            pane = launcher.launchPane(agentName: PeerNaming.agentName(label: j.peerLabel, jobId: jobId), label: j.peerLabel, cwd: wt, flags: j.inboundMode.claudeFlags,
                                       rolePath: dir.appendingPathComponent("role.md").path, firstPrompt: prompt, resumeSession: sid)
            if pane == nil { report(j, j.status, j.note); return }
        }
        if let u = update(jobId, { $0.status = .working; $0.note = "Resumed"; $0.sessionId = sid; $0.resumes = n; $0.finished = nil; $0.builderOwnsPause = nil; $0.pausedReason = nil; $0.resumeAt = nil; $0.pane = pane; $0.builder = builder ?? $0.builder }) {
            report(u, .working, "Resumed")
        }
        changed()
    }

    /// Launch: a job whose tab is gone (True quit or crashed) pauses, then resumes at once.
    func recoverInterrupted() {
        resumeLock.lock(); defer { resumeLock.unlock() }
        lock.lock()
        let paused = inbound.filter { $0.status == .paused && $0.builderOwnsPause != true }
        let hit = inbound.filter { !$0.status.isFinal && $0.status != .paused && $0.status != .queued && $0.pane.map { !launcher.paneAlive($0) } ?? false }
        // A job that never got a pane or builder. With no start marker nothing was typed, so it is safe to run again; with one it may
        // already have been typed, so it fails (the sender is told) rather than risk typing it twice.
        let paneless = inbound.filter { !$0.status.isFinal && $0.status != .paused && $0.status != .queued && $0.pane == nil && $0.builder == nil
            && $0.sessionId == nil && $0.status != .needsYou }
        // A job in line behind one that still has a pane or builder, or is paused, stays in line: that job hands over when it
        // ends. Running it now would put two jobs on one lane once the job ahead resumes below.
        let held = Set(paneless.filter { j in
            guard let key = j.desk else { return false }
            return inbound.contains { $0.id != j.id && $0.desk == key && ($0.lane ?? 1) == (j.lane ?? 1) && !$0.status.isFinal
                && ($0.pane != nil || $0.builder != nil || $0.status == .paused) }
        }.map(\.id))
        let marks = starting
        lock.unlock()
        for j in paneless {
            if marks.contains(j.id) {
                clearStarting(j.id)
                end(j.id, .failed, "Interrupted while starting. Send it again.", reportAs: .failed)
            } else if j.status == .accepted && !held.contains(j.id) {
                run(j.id, flags: j.inboundMode.claudeFlags)
            }
        }
        for j in paused {
            if let at = j.resumeAt, at > now() { scheduleResume(j.id, at: at) }
            else { performResume(j.id) }
        }
        for j in hit {
            if sessionFor(j) == nil { continue }
            pause(j.id, reason: "True restarted", at: now(), known: true)
            performResume(j.id)
        }
    }

    private func handleResume(_ obj: [String: Any], from mailbox: String) {
        guard let id = obj["jobId"] as? String else { drop("resume payload"); return }
        let note = (obj["note"] as? String).map { PeerMask.text($0, limit: PeerValidate.maxNote) }
        guard let j = inboundJob(id, from: mailbox) else {
            if let l = link(mailbox) {
                sealAndQueue(["t": "event", "jobId": id, "status": PeerStatus.failed.rawValue, "note": "\(ownName) has no record of this job"], to: l, owner: l.mailboxId)
            }
            return
        }
        work.async { [self] in
            switch j.status {
            case .paused: performResume(id)
            case .needsYou where j.acceptFailed == true:
                _ = update(id) { $0.status = .accepted; $0.acceptFailed = false; $0.note = "Starting" }
                run(id, flags: j.inboundMode.claudeFlags)
            case .idle:
                if let p = j.pane { _ = launcher.deliverToPane(p, line: "Finish the job and write result.md") }
                else if let b = j.builder { launcher.deliverLine(agent: b, line: "Finish the job and write result.md") }
                report(j, j.status, j.note)
            case .done, .failed:
                // Only a note-carrying resume (a fix round) re-opens a finished job; a plain one just reports as before.
                if let note { performFixResume(id, note: note) } else { report(j, j.status, j.note) }
            default: report(j, j.status, j.note)
            }
        }
    }

    /// Sender side: ask the peer to pick a stuck job back up. A `note` makes it a fix round: the sealed "resume" carries
    /// the note and a finished (.done) job is accepted so the receiver can re-run its session with the note in the prompt.
    func resumeJob(jobId: String, note: String? = nil) -> Result<Void, PeerError> {
        lock.lock(); let job = sent.first { $0.jobId == jobId }; lock.unlock()
        guard let job else { return .failure(.invalid("No job \(jobId)")) }
        let fixRound = note != nil
        guard !job.status.isFinal || job.status == .failed || (fixRound && job.status == .done) else {
            return .failure(.invalid("That job has already ended"))
        }
        guard let l = link(job.peerMailbox) else { return .failure(.invalid("That peer was removed")) }
        var payload: [String: Any] = ["t": "resume", "jobId": jobId]
        if let note { payload["note"] = PeerMask.text(note, limit: PeerValidate.maxNote) }
        sealAndQueue(payload, to: l, jobId: jobId, owner: l.mailboxId)
        if fixRound {
            // The peer is about to re-open a finished job, so the sender must accept its next events again.
            lock.lock()
            if let s = sent.firstIndex(where: { $0.jobId == jobId }), sent[s].status == .done {
                sent[s].status = .working; sent[s].note = "Resuming"; sent[s].updated = now(); saveSent()
            }
            lock.unlock()
        }
        return .success(())
    }

    // MARK: Run 36a — background-job steps

    /// Follow the builder's `stream.jsonl` and queue its steps as activity (same share-level rules as a pane).
    private func startTailer(_ j: InboundJob, dir: String) {
        lock.lock()
        guard tailers[j.id] == nil else { lock.unlock(); return }
        let jobId = j.id
        let t = PeerStreamTailer(path: dir + "/stream.jsonl") { [weak self] lines in
            guard let self else { return }
            self.lock.lock(); let job = self.inbound.first { $0.id == jobId && !$0.status.isFinal }; self.lock.unlock()
            guard let job else { return }
            if job.sessionId == nil, let sid = lines.lazy.compactMap({ PeerResume.initSession(line: $0) }).first { _ = self.update(jobId) { $0.sessionId = sid } }
            let level = self.share(), at = self.now()
            let items = lines.flatMap { PeerStream.items(line: $0, at: at, level: level) }
            if !items.isEmpty { self.queueActivity(job, items) }
        }
        tailers[j.id] = t
        lock.unlock()
    }

    // MARK: Run 36 — failure reasons

    private func noteError(_ jobId: String, _ message: String) {
        let m = PeerMask.text(message, limit: 400).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return }
        lock.lock(); lastErrors[jobId] = m; lock.unlock()
    }
    private func takeError(_ jobId: String) -> String? { lock.lock(); defer { lock.unlock() }; return lastErrors.removeValue(forKey: jobId) }

    /// "Hit an error: <reason>" — the reason masked and ≤ 400 chars, the whole note within `maxNote`.
    static func withReason(_ base: String, _ reason: String?) -> String {
        guard let r = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return base }
        return String("\(base): \(PeerMask.text(r, limit: 400))".prefix(PeerValidate.maxNote))
    }

    /// Why a builder failed: its last `is_error` result in stream.jsonl, else the last 3 lines of stderr.log.
    static func builderFailureReason(dir: String) -> String? {
        let d = URL(fileURLWithPath: dir)
        func tailText(_ name: String, _ bytes: UInt64) -> String? {
            guard let h = try? FileHandle(forReadingFrom: d.appendingPathComponent(name)) else { return nil }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > bytes ? size - bytes : 0)
            return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        }
        if let text = tailText("stream.jsonl", 65_536) {
            for raw in text.split(separator: "\n").reversed() {
                guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      o["type"] as? String == "result", o["is_error"] as? Bool == true else { continue }
                if let r = o["result"] as? String, !r.isEmpty { return r }
                if let sub = o["subtype"] as? String { return sub }
            }
        }
        if let err = tailText("stderr.log", 8_192) {
            let lines = err.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !lines.isEmpty { return lines.suffix(3).joined(separator: " ") }
        }
        return nil
    }

    // MARK: receiver — finishing

    private func end(_ jobId: String, _ status: PeerStatus, _ note: String, reportAs: PeerStatus, startNext: Bool = true) {
        guard let u = update(jobId, { $0.status = status; $0.note = note; $0.finished = now() }) else { return }
        clearStarting(jobId)
        var final = u
        lock.lock(); lastErrors[jobId] = nil; let tl = tailers.removeValue(forKey: jobId); lock.unlock()
        tl?.sync(); tl?.stop()
        if status == .done, u.req.hasRepo, let wt = u.worktree, let sha = launcher.headSHA(worktree: wt) {
            final = update(jobId) { $0.sha = sha } ?? u
        }
        log(final)
        report(final, reportAs, note)
        lock.lock(); heldSays[jobId] = nil; if let p = final.pane { prompting.remove(p) }; lock.unlock()
        changed()
        if startNext, let key = final.desk { work.async { [self] in startNextInLine(key) } }
    }


    private func report(_ j: InboundJob, _ s: PeerStatus, _ note: String) {
        let m1 = peerCaps(j.peerMailbox)?.supportsM1 == true
        var o: [String: Any] = ["t": "event", "jobId": j.req.jobId, "status": s.forPeer(m1: m1).rawValue, "note": String(note.prefix(PeerValidate.maxNote))]
        if s == .paused, m1, let at = j.resumeAt { o["resumeAt"] = Int(at.timeIntervalSince1970) }
        if (s == .done || s == .failed) && j.req.hasRepo { o["branch"] = j.branch }
        if s == .done {
            if let sha = j.sha { o["sha"] = sha }
            if let d = try? Data(contentsOf: URL(fileURLWithPath: resultPath(j.id))) {
                // Run 36: read a little over the cap so a cut mid-character still lands on a whole one, then clip by UTF-8 bytes.
                let text = String(decoding: d.prefix(PeerValidate.maxResult + 4), as: UTF8.self)
                let full = d.count > PeerValidate.maxResult || text.utf8.count > PeerValidate.maxResult
                var r = PeerValidate.clipBytes(text, PeerValidate.maxResult)
                o["result"] = full ? r + PeerValidate.cutNote : r
                // The sealed status must fit PeerSeal.maxBlob (JSON escaping can double the size): cut further until it does.
                if let link = link(j.peerMailbox) {
                    var tries = 0
                    while tries < 12, !sealFits(o, to: link) {
                        r = PeerValidate.clipBytes(r, r.utf8.count * 3 / 4)
                        o["result"] = r + PeerValidate.cutNote
                        tries += 1
                    }
                }
            }
        }
        queueActivity(j, [PeerActivityItem(t: Int(now().timeIntervalSince1970), kind: .status, text: PeerMask.text("\(s.rawValue): \(note)"))], final: s == .done || s == .failed || s == .canceled)
        lock.lock(); let link = links.first { $0.mailboxId == j.peerMailbox }; lock.unlock()
        guard let link else { return }       // revoked: nobody to tell
        sealAndQueue(o, to: link, owner: link.mailboxId)
    }

    // MARK: receiver — say / stop / activity out (Run 30)

    private static let steerable: Set<PeerStatus> = [.accepted, .working, .needsYou, .idle]

    func link(_ mailbox: String) -> PeerLink? { lock.lock(); defer { lock.unlock() }; return links.first { $0.mailboxId == mailbox } }

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
        // 100x 2d: a Mac whose build predates `chat-reply-v1` never answers; say so once, so silence isn't read as "delivered".
        if addr.channel.hasPrefix("@"), let l = targets.first, capsState(mailbox: l.mailboxId, feature: PeerCaps.chatReplyFeature) == .no {
            bus.post(channel: local, agent: "true", text: "Sent (no receipt from this Mac's version)", re: m.id, deliver: false)
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
        var replies: [[String: Any]] = []
        defer {
            // Only a sender that announced `chat-reply-v1` understands a reply; an old build would drop it as a bad payload.
            if !replies.isEmpty, peerCaps(mailbox)?.features.contains(PeerCaps.chatReplyFeature) == true {
                sealAndQueue(["t": "chat", "reply": replies], to: l, owner: l.mailboxId)
            }
        }
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
            let seat: String? = channel.hasPrefix("@") ? String(channel.dropFirst()) : nil
            guard let dest = local else {
                drop("chat channel not authorised")
                if let seat { replies.append(rememberChatAnswer(id, ["id": id, "ok": false, "seat": seat, "err": "No \(seat) on \(ownName)"])) }
                continue
            }
            let key = "chat:" + id
            lock.lock()
            let dup = seen[key] != nil
            if !dup { seen[key] = Int(now().timeIntervalSince1970) + Int(Self.seenLife); saveSeen() }
            let prior = chatAnswers[id]
            lock.unlock()
            if dup { if seat != nil { replies.append(prior ?? ["id": id, "ok": true, "seat": seat ?? ""]) }; continue }
            bus.post(channel: dest, agent: String(agent.prefix(48)), mac: l.label, text: text, id: id, ts: ts, re: (o["re"] as? String).flatMap { $0.count <= 80 ? $0 : nil })
            if let seat {
                // The seat can close between the check and the hand-over; say so instead of acknowledging a line nobody got.
                if bus.isSeat(seat) { replies.append(rememberChatAnswer(id, ["id": id, "ok": true, "seat": seat])) }
                else {
                    lock.lock(); seen[key] = nil; saveSeen(); lock.unlock()
                    replies.append(rememberChatAnswer(id, ["id": id, "ok": false, "seat": seat, "err": "No \(seat) on \(ownName)"]))
                }
            }
        }
        changed()
    }

    private func rememberChatAnswer(_ id: String, _ answer: [String: Any]) -> [String: Any] {
        lock.lock()
        if chatAnswers.count >= 200 { chatAnswers.removeAll() }
        chatAnswers[id] = answer
        lock.unlock()
        return answer
    }

    /// 100x 2d, sender side: the other Mac answered a line we sent. Shown as one plain line in the shared room (no new view).
    private func handleChatReply(_ obj: [String: Any], from mailbox: String) {
        guard let l = link(mailbox), let bus = chat, let items = obj["reply"] as? [[String: Any]], items.count <= 50 else { return }
        for o in items {
            guard let id = o["id"] as? String, !id.isEmpty, id.count <= 80, let ok = o["ok"] as? Bool else { drop("chat reply payload"); continue }
            let seat = PeerMask.firstLine((o["seat"] as? String) ?? "").prefix(48)
            let key = "chatreply:\(id):\(ok)"
            lock.lock()
            let dup = seen[key] != nil
            if !dup { seen[key] = Int(now().timeIntervalSince1970) + Int(Self.seenLife); saveSeen() }
            lock.unlock()
            if dup { continue }
            let text = ok ? "Delivered to \(seat) on \(l.label)" : "No \(seat) on \(l.label)"
            bus.post(channel: "#" + PeerNaming.slug(l.label), agent: "true", text: text, re: String(id.prefix(80)), deliver: false)
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
        if let p = j.pane { lock.lock(); retired.insert(p); lock.unlock() }
        launcher.stop(panes: j.pane.map { [$0] } ?? [], builders: j.builder.map { [$0] } ?? [])
        end(id, j.status == .queued ? .declined : .canceled, "Stopped by sender", reportAs: .canceled)
    }

    /// Add items to the job's outgoing batch; send when the batcher says so, else arm one timer.
    private func queueActivity(_ j: InboundJob, _ items: [PeerActivityItem], final: Bool = false) {
        let watchPeer = peerCaps(j.peerMailbox)?.features.contains("watch") == true
        var rest = items
        if watchPeer {
            // A question must reach the peer even with nobody watching.
            let urgent = items.filter { $0.kind == .question }
            rest = items.filter { $0.kind != .question }
            if !urgent.isEmpty, let l = link(j.peerMailbox) { sendActivity(urgent, jobId: j.id, to: l) }
        }
        if share() != .status, !rest.isEmpty {
            lock.lock()
            var b = batchers[j.id] ?? PeerBatcher()
            for it in rest { b.add(it, at: now()) }
            if watchPeer { b.trim(to: Self.backlogCap) }
            batchers[j.id] = b
            lock.unlock()
        }
        flushActivity(j.id, force: final)
    }

    private func sendActivity(_ batch: [PeerActivityItem], jobId: String, to l: PeerLink) {
        lock.lock()
        let seq = max((activitySeq[jobId] ?? 0) + 1, Int(now().timeIntervalSince1970)); activitySeq[jobId] = seq
        lock.unlock()
        sealAndQueue(["t": "activity", "jobId": jobId, "seq": seq, "items": batch.map(\.wire)], to: l, owner: l.mailboxId, lane: "activity")
    }

    private func handleWatch(_ obj: [String: Any], from mailbox: String) {
        guard let id = obj["jobId"] as? String, inboundJob(id, from: mailbox) != nil else { drop("watch for a job not from this peer"); return }
        lock.lock(); leases[id] = now().addingTimeInterval(Self.leaseSeconds); lock.unlock()
        flushActivity(id)
    }

    /// Send what is due for a job (tests call this after moving the clock).
    func flushActivity(_ jobId: String, force: Bool = false) {
        lock.lock()
        guard var b = batchers[jobId] else { lock.unlock(); return }
        let t = now()
        let peer = inbound.first { $0.req.jobId == jobId }?.peerMailbox
        let watchPeer = peer.flatMap { caps[$0] }?.features.contains("watch") == true
        let leased = !watchPeer || (leases[jobId].map { $0 > t } ?? false)
        activitySendTimes.removeAll { t.timeIntervalSince($0) >= 60 }
        let budgetOK = force || activitySendTimes.count < Self.activityPerMinute
        let batch = (leased && budgetOK) ? b.take(at: t, force: force) : nil
        var nextAt: Date? = force ? nil : b.nextDue(at: t)
        if leased, !budgetOK, b.hasPending, let o = activitySendTimes.first { nextAt = max(nextAt ?? t, o.addingTimeInterval(60)) }
        if !leased { nextAt = leases[jobId].flatMap { $0 > t ? $0 : nil } }   // an expired/absent lease needs a new watch, not a timer
        if force || !b.hasPending { batchers[jobId] = force ? nil : b } else { batchers[jobId] = b }
        if batch != nil { activitySendTimes.append(t) }
        let l = inbound.first { $0.req.jobId == jobId }.flatMap { j in links.first { $0.mailboxId == j.peerMailbox } }
        var arm: Date?
        if let nextAt, b.hasPending, leased, !flushScheduled.contains(jobId) { flushScheduled.insert(jobId); arm = nextAt }
        lock.unlock()
        if let batch, let l { sendActivity(batch, jobId: jobId, to: l) }
        if let arm {
            scheduler(max(0.05, arm.timeIntervalSince(now()))) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.flushScheduled.remove(jobId); self.lock.unlock()
                self.flushActivity(jobId)
            }
        }
    }

    // MARK: sender — watching a peer's job (Run 36a)

    /// Ask the peer's True to stream this job's activity for the next while (renewed every minute until `forSeconds` passes
    /// or the job ends). No-op for a peer whose True predates `watch` — that one streams as before.
    func watchJob(jobId: String, forSeconds: TimeInterval = 600) {
        lock.lock()
        let job = sent.first { $0.jobId == jobId }
        let already = watching[jobId] != nil
        watching[jobId] = now().addingTimeInterval(forSeconds)
        lock.unlock()
        guard let job, !job.status.isFinal, let l = link(job.peerMailbox), capsState(mailbox: l.mailboxId, feature: "watch") == .yes else { return }
        sealAndQueue(["t": "watch", "jobId": jobId, "since": job.seq ?? 0], to: l, owner: l.mailboxId, lane: "activity")
        if !already { scheduleWatchRenewal(jobId) }
    }

    func activitySendsInLastMinute() -> Int { lock.lock(); defer { lock.unlock() }; return activitySendTimes.filter { now().timeIntervalSince($0) < 60 }.count }

    func unwatchJob(jobId: String) { lock.lock(); watching[jobId] = nil; lock.unlock() }

    private func scheduleWatchRenewal(_ jobId: String) {
        scheduler(Self.watchRenewSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let until = self.watching[jobId]
            let live = until.map { $0 > self.now() } ?? false
            if !live { self.watching[jobId] = nil }
            self.lock.unlock()
            guard live else { return }
            self.lock.lock(); self.watching[jobId] = nil; self.lock.unlock()
            self.watchJob(jobId: jobId, forSeconds: until!.timeIntervalSince(self.now()))
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
        lock.lock(); retired.formUnion(live.compactMap(\.pane)); lock.unlock()
        launcher.stop(panes: live.compactMap(\.pane), builders: live.compactMap(\.builder))
        for j in live { end(j.id, j.status == .queued ? .declined : .failed, "Stopped on this Mac", reportAs: .failed, startNext: false) }
    }
}


/// Missions M1: usage-limit detection, reset-time parsing and the resume cap (plain rules, no model).
enum PeerResume {
    static let maxResumes = 3
    static let unknownWait: TimeInterval = 30 * 60

    /// 100x 2b: API trouble that usually clears by itself. Usage limits keep their own path (`isUsageLimit`).
    static func isTransient(_ text: String) -> Bool {
        if isUsageLimit(text) { return false }
        return text.range(of: #"(?i)server_error|overloaded|rate_limit|\b529\b|\b5\d\d\b"#, options: .regularExpression) != nil
    }

    /// Wait before resume number `resumes + 1`: 1, 5, then 15 minutes.
    static func backoff(resumes: Int) -> TimeInterval { [60, 300, 900][max(0, min(resumes, 2))] }

    static func isUsageLimit(_ text: String) -> Bool {
        text.range(of: #"(?i)(usage|rate|session) limit|limit reached|out of (usage|credits)"#, options: .regularExpression) != nil
    }

    /// "resets 3pm" / "resets at 10:30 pm": the next such wall-clock time on the receiver's clock; nil when unparseable.
    static func resumeTime(from text: String, now: Date, calendar: Calendar = .current) -> Date? {
        guard let re = try? NSRegularExpression(pattern: #"(?i)resets?\s+(?:at\s+)?(\d{1,2})(?::(\d\d))?\s?(am|pm)?"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hr = Range(m.range(at: 1), in: text).flatMap({ Int(text[$0]) }) else { return nil }
        let min = Range(m.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        var h = hr
        if let r = Range(m.range(at: 3), in: text) {
            let ap = text[r].lowercased()
            guard (1...12).contains(h) else { return nil }
            h = h % 12 + (ap == "pm" ? 12 : 0)
        }
        guard h < 24, min < 60 else { return nil }
        return calendar.nextDate(after: now, matching: DateComponents(hour: h, minute: min, second: 0), matchingPolicy: .nextTime)
    }

    /// `session_id` from the stream's first `{"type":"system","subtype":"init"}` line.
    static func initSession(line: String) -> String? {
        guard line.contains("\"init\""), let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              o["type"] as? String == "system", o["subtype"] as? String == "init" else { return nil }
        return o["session_id"] as? String
    }
}
