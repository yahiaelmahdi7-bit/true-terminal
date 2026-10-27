import Foundation

/// Run 39 — "On this network": what the Peers window shows and does about other Macs on the same Wi-Fi.
/// The window opens it (`open()`) and closes it (`close()`); nothing is advertised or browsed in between.
/// Timers are injected so tests run without waiting.
typealias PeerLanTimerFactory = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

@MainActor
final class PeerLanCoordinator: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id: String          // tag, hex
        var name: String
        var paired: Bool
    }
    enum LanState: Equatable { case ok, denied, cantSearch }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var lanState: LanState = .ok

    /// What a row's Invite button area shows. No entry = the Invite button.
    enum Send: Equatable {
        case connecting, cantReach
        case check(code: String)       // "482 913"
        case waitingAccept
        case pairing
        case paired, declined, busy, timedOut, failed
        case relayTimeout
        var busy: Bool { switch self { case .connecting, .check, .waitingAccept, .pairing: return true; default: return false } }
    }
    struct Prompt: Equatable { var name: String; var code: String }
    @Published private(set) var sendState: [String: Send] = [:]
    /// Receiver: someone on this network wants to pair; the person says Accept or Decline.
    @Published private(set) var prompt: Prompt?
    /// The window raises itself and posts a notification when a prompt arrives.
    var onPrompt: ((Prompt) -> Void)?

    private struct Entry { var name: String; var ad: PeerLanTXT.Ad; var ids: [String] }
    private var entries: [String: Entry] = [:]
    private var tagOfId: [String: String] = [:]

    let transport: PeerLanTransport
    let engine: PeerEngine
    let timer: PeerLanTimerFactory
    let now: () -> Date
    private var cancelWaiting: (@MainActor () -> Void)?
    private var opened = false
    private var peersObserver: NSObjectProtocol?

    static let waitingSeconds: TimeInterval = 10
    static let connectSeconds: TimeInterval = 10
    static let relayConfirmSeconds: TimeInterval = 30

    private final class Session {
        var machine: PeerLanHandshake
        let conn: PeerLanConnection
        let rowId: String?        // sender only
        var cancelTimer: (@MainActor () -> Void)?
        var ready = false
        init(machine: PeerLanHandshake, conn: PeerLanConnection, rowId: String?) { self.machine = machine; self.conn = conn; self.rowId = rowId }
    }
    private var session: Session?
    private var limiter = PeerLanRateLimiter()
    /// Sender, after `done{ok}`: the row waiting for the relay to confirm the link.
    private var relayWatch: (rowId: String, mailbox: String, cancel: @MainActor () -> Void)?

    init(transport: PeerLanTransport, engine: PeerEngine, timer: @escaping PeerLanTimerFactory = PeerLanCoordinator.realTimer,
         now: @escaping () -> Date = { Date() }) {
        self.transport = transport; self.engine = engine; self.timer = timer; self.now = now
        transport.onBrowse = { [weak self] ev in self?.handle(ev) }
        transport.onIncoming = { [weak self] c in self?.incoming(c) }
    }

    static let realTimer: PeerLanTimerFactory = { secs, fire in
        final class Flag: @unchecked Sendable { var live = true }
        let f = Flag()
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { MainActor.assumeIsolated { if f.live { fire() } } }
        return { f.live = false }
    }

    var isOpen: Bool { opened }

    // MARK: window lifecycle

    /// Idempotent. Starts advertising + browsing with a fresh salt.
    func open() {
        guard !opened else { return }
        opened = true
        let ad = PeerLanTXT.makeAd(mailboxId: engine.identity.mailboxId)
        transport.sync(open: true, name: PeerLanTXT.serviceName(engine.ownName), txt: PeerLanTXT.encode(ad))
        peersObserver = NotificationCenter.default.addObserver(forName: .peersChanged, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.rebuild() } }
        }
    }

    /// Idempotent. Stops everything and forgets what it saw.
    func close() {
        guard opened else { return }
        opened = false
        if let o = peersObserver { NotificationCenter.default.removeObserver(o); peersObserver = nil }
        transport.sync(open: false, name: "", txt: [:])
        cancelWaiting?(); cancelWaiting = nil
        if let s = session { feed(s, .windowClosed) }
        relayWatch?.cancel(); relayWatch = nil
        sendState.removeAll(); prompt = nil
        entries.removeAll(); tagOfId.removeAll()
        lanState = .ok
        rebuild()
    }

    // MARK: browsing

    func handle(_ ev: PeerLanBrowseEvent) {
        guard opened else { return }
        switch ev {
        case .found(let id, let name, let txt): add(id: id, name: name, txt: txt)
        case .removed(let id): remove(id: id)
        case .state(let st): browseState(st)
        }
    }

    private func add(id: String, name: String, txt: [String: String]) {
        remove(id: id)
        guard let ad = PeerLanTXT.decode(txt) else { return }
        guard !PeerLanTXT.matches(ad, mailboxId: engine.identity.mailboxId) else { return }   // our own row
        let tag = PeerLanTXT.hex(ad.tag)
        if var e = entries[tag] {
            e.ids.append(id); entries[tag] = e
        } else {
            guard entries.count < PeerLanTXT.maxRows else { return }
            entries[tag] = Entry(name: PeerLanLabel.display(name), ad: ad, ids: [id])
        }
        tagOfId[id] = tag
        rebuild()
    }

    private func remove(id: String) {
        guard let tag = tagOfId.removeValue(forKey: id), var e = entries[tag] else { return }
        e.ids.removeAll { $0 == id }
        if e.ids.isEmpty { entries[tag] = nil } else { entries[tag] = e }
        rebuild()
    }

    private func browseState(_ st: PeerLanBrowseState) {
        switch st {
        case .ready: cancelWaiting?(); cancelWaiting = nil; lanState = .ok
        case .denied: cancelWaiting?(); cancelWaiting = nil; lanState = .denied
        case .waiting:
            guard lanState == .ok, cancelWaiting == nil else { return }
            cancelWaiting = timer(Self.waitingSeconds) { [weak self] in
                guard let self else { return }
                self.cancelWaiting = nil
                if self.lanState == .ok { self.lanState = .cantSearch }
            }
        }
    }

    func rebuild() {
        let mids = engine.peerLinks().map(\.mailboxId)
        rows = entries.map { tag, e in
            Row(id: tag, name: e.name, paired: mids.contains { PeerLanTXT.matches(e.ad, mailboxId: $0) })
        }.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        if let w = relayWatch, engine.peerLinks().contains(where: { $0.mailboxId == w.mailbox && $0.confirmed }) {
            w.cancel(); relayWatch = nil; sendState[w.rowId] = .paired
        }
    }

    // MARK: sending (this Mac clicked Invite)

    /// Invite button on a row.
    func invite(rowId: String) {
        guard opened, session == nil, let row = rows.first(where: { $0.id == rowId }), !row.paired, sendState[rowId]?.busy != true,
              let cid = connectionId(for: rowId) else { return }
        guard let conn = transport.connect(to: cid) else { sendState[rowId] = .cantReach; return }
        let m = PeerLanHandshake(role: .sender, me: engine.identity, ownName: engine.ownName, now: now)
        let s = Session(machine: m, conn: conn, rowId: rowId)
        session = s
        sendState[rowId] = .connecting
        wire(s)
        s.cancelTimer = timer(Self.connectSeconds) { [weak self, weak s] in
            guard let self, let s, self.session === s, !s.ready else { return }
            self.endWithoutMachine(s, .cantReach)
        }
        conn.start()
    }

    /// Pair pressed on the code check.
    func confirmSend() { if let s = session, s.rowId != nil { feed(s, .userConfirm) } }
    /// Cancel pressed (sender) or Decline pressed (receiver).
    func cancelSession() { if let s = session { feed(s, .userCancel) } }
    /// Accept pressed on the prompt.
    func accept() { if let s = session, s.rowId == nil { feed(s, .userConfirm) } }

    // MARK: receiving

    private func incoming(_ conn: PeerLanConnection) {
        guard opened else { conn.close(); return }
        guard limiter.allow(conn.remote, now: now()) else { conn.close(); return }          // silent
        guard session == nil else {
            conn.send(PeerLanMsg(t: "bye", reason: "busy").data())
            conn.close(); return
        }
        let m = PeerLanHandshake(role: .receiver, me: engine.identity, ownName: engine.ownName, now: now)
        let s = Session(machine: m, conn: conn, rowId: nil)
        session = s
        wire(s)
        conn.start()
        feed(s, .begin)
    }

    // MARK: session plumbing

    private func wire(_ s: Session) {
        s.conn.onReady = { [weak self, weak s] in
            guard let self, let s, self.session === s, !s.ready else { return }
            s.ready = true
            s.cancelTimer?(); s.cancelTimer = nil
            if s.rowId != nil { self.feed(s, .begin) }
        }
        s.conn.onFrame = { [weak self, weak s] d in if let self, let s, self.session === s { self.feed(s, .frame(d)) } }
        s.conn.onClose = { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            if !s.ready, s.rowId != nil { self.endWithoutMachine(s, .cantReach) } else { self.feed(s, .connectionLost) }
        }
    }

    private func endWithoutMachine(_ s: Session, _ st: Send) {
        s.cancelTimer?(); s.cancelTimer = nil
        s.conn.onClose = nil; s.conn.close()
        if session === s { session = nil }
        if let r = s.rowId { sendState[r] = st }
    }

    private func feed(_ s: Session, _ e: PeerLanHandshake.Event) {
        let acts = s.machine.handle(e)
        for a in acts { run(a, s) }
        showProgress(s)
    }

    private func run(_ a: PeerLanHandshake.Action, _ s: Session) {
        switch a {
        case .send(let m): s.conn.send(m.data())
        case .close: s.conn.onClose = nil; s.conn.close()
        case .arm(let secs):
            s.cancelTimer?(); s.cancelTimer = nil
            if let secs { s.cancelTimer = timer(secs) { [weak self, weak s] in if let self, let s, self.session === s { self.feed(s, .timeout) } } }
        case .prompt(let code, let name):
            if s.rowId == nil {
                let p = Prompt(name: PeerLanLabel.display(name), code: PeerLanHandshake.spaced(code))
                prompt = p; onPrompt?(p)
            }
        case .makeInvite: feed(s, .inviteReady(engine.invite()))
        case .pair(let raw, let name):
            let label = PeerLanLabel.safe(name, existing: engine.peerLinks().map(\.label))
            switch engine.pairWithInvite(raw, label: label) {
            case .success: feed(s, .pairResult(ok: true, err: nil))
            case .failure(let e): feed(s, .pairResult(ok: false, err: Self.reason(e)))
            }
        case .cancelInvite(let sec): engine.cancelInvite(sec)
        case .finished(let o): finished(s, o)
        }
    }

    private static func reason(_ e: PeerError) -> String {
        if case .invalid(let m) = e { return String(m.prefix(80)) }
        return "couldn't pair"
    }

    private func showProgress(_ s: Session) {
        guard let r = s.rowId, session === s else { return }
        switch s.machine.phase {
        case .checkCode:
            sendState[r] = s.machine.waitingForAccept ? .waitingAccept : .check(code: PeerLanHandshake.spaced(s.machine.code ?? ""))
        case .awaitDone: sendState[r] = .pairing
        default: break
        }
    }

    private func finished(_ s: Session, _ o: PeerLanOutcome) {
        s.cancelTimer?(); s.cancelTimer = nil
        if session === s { session = nil }
        if s.rowId == nil {
            prompt = nil
            rebuild()
            return
        }
        guard let r = s.rowId else { return }
        switch o {
        case .paired:
            sendState[r] = .pairing
            if let mid = s.machine.theirMailbox {
                relayWatch?.cancel()
                let cancel = timer(Self.relayConfirmSeconds) { [weak self] in
                    guard let self, let w = self.relayWatch, w.rowId == r else { return }
                    self.relayWatch = nil; self.sendState[r] = .relayTimeout
                }
                relayWatch = (r, mid, cancel)
                rebuild()
            }
        case .declined: sendState[r] = .declined
        case .cancelled: sendState[r] = nil
        case .busy: sendState[r] = .busy
        case .timedOut: sendState[r] = .timedOut
        case .failed: sendState[r] = .failed
        }
    }

    /// First transport handle for a row (several interfaces can carry the same Mac).
    func connectionId(for rowId: String) -> String? { entries[rowId]?.ids.first }
}

/// Names that come from another Mac are never trusted raw.
enum PeerLanLabel {
    /// A name safe to show and to use as a peer label, else "Peer" (same rule as `PeerEngine.handlePairRequest`).
    static func display(_ raw: String) -> String {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n.count > PeerValidate.maxLabel || PeerValidate.hasBadControl(n) || n.contains("\n") { return "Peer" }
        return n
    }

    /// `display(raw)`, suffixed " 2", " 3"… until it matches no existing label (case-insensitive).
    static func safe(_ raw: String, existing: [String]) -> String {
        let base = display(raw)
        let taken = Set(existing.map { $0.lowercased() })
        var label = base, n = 2
        while taken.contains(label.lowercased()) { label = "\(base) \(n)"; n += 1 }
        return label
    }
}
