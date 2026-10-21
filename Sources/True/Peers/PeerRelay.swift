import Foundation

/// Where the relay lives (Run 29). The public build ships `defaultURL`; `peer.relayURL` overrides it.
enum PeerRelay {
    static let defaultURL = "wss://true-relay.yahia-xbox.workers.dev"
    static let defaultsKey = "peer.relayURL"

    static var url: String {
        get {
            let o = UserDefaults.standard.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return o.isEmpty ? defaultURL : o
        }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == defaultURL { UserDefaults.standard.removeObject(forKey: defaultsKey) }
            else { UserDefaults.standard.set(t, forKey: defaultsKey) }
        }
    }

    /// `<relay>/v1/connect?m=<mailboxId>`; nil for anything that isn't a ws(s) URL or is still the placeholder.
    static func connectURL(_ relay: String, mailboxId: String) -> URL? {
        guard !relay.contains("RELAY_URL_PLACEHOLDER"), var c = URLComponents(string: relay.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "wss" || c.scheme == "ws", let host = c.host, !host.isEmpty else { return nil }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path + "/v1/connect"
        c.queryItems = [URLQueryItem(name: "m", value: mailboxId)]
        return c.url
    }

    /// The host (and port) the relay hello signs, so a hello can't be replayed to another relay.
    static func helloHost(_ url: URL) -> String {
        (url.host ?? "") + (url.port.map { ":\($0)" } ?? "")
    }

    /// 1 s doubling to 5 min, with ±20% jitter (never above the cap).
    static func reconnectDelay(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> TimeInterval {
        min(300, pow(2, Double(max(0, min(attempt, 9)))) * jitter)
    }
}

/// The real relay connection: a URLSessionWebSocketTask, up only while the engine wants it. No polling — reconnects
/// back off, and the only recurring work is one ping every 5 minutes while connected.
final class PeerRelayLive: PeerTransport, @unchecked Sendable {
    private let identity: PeerIdentity
    private let relayURL: @Sendable () -> String
    private let q = DispatchQueue(label: "true.peers.relay")
    private let session = URLSession(configuration: .default)

    private var wanted = false
    private var ready = false
    private var task: URLSessionWebSocketTask?
    private var gen = 0
    private var attempt = 0
    private var waiters: [String: (sem: DispatchSemaphore, box: ResultBox)] = [:]
    private let lock = NSLock()

    private final class ResultBox: @unchecked Sendable { var r: PeerSendResult = .retry }

    var onMessage: (@Sendable (String, String, Data) -> Void)?
    var onStatus: (@Sendable (Bool) -> Void)?

    init(identity: PeerIdentity, relayURL: @escaping @Sendable () -> String = { PeerRelay.url }) {
        self.identity = identity; self.relayURL = relayURL
    }

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    func setWanted(_ on: Bool) {
        q.async { [self] in
            guard on != wanted else { return }
            wanted = on
            if on { attempt = 0; connect() } else { teardown() }
        }
    }

    /// The relay URL setting changed: drop the connection and dial the new one.
    func reload() {
        q.async { [self] in
            guard wanted else { return }
            teardown(); attempt = 0; connect()
        }
    }

    // MARK: send

    func send(to: String, id: String, blob: Data) -> PeerSendResult {
        guard isConnected, blob.count <= PeerSeal.maxBlob else { return blob.count > PeerSeal.maxBlob ? .refused : .retry }
        let msg: [String: Any] = ["t": "send", "to": to, "id": id, "blob": PeerB64.std(blob)]
        guard let data = try? JSONSerialization.data(withJSONObject: msg), let text = String(data: data, encoding: .utf8) else { return .retry }
        let w = (sem: DispatchSemaphore(value: 0), box: ResultBox())
        lock.lock(); waiters[id] = w; let t = task; lock.unlock()
        guard let t else { lock.lock(); waiters[id] = nil; lock.unlock(); return .retry }
        t.send(.string(text)) { [weak self] err in
            if err != nil { self?.resolve(id, .retry) }
        }
        if w.sem.wait(timeout: .now() + 20) == .timedOut { resolve(id, .retry) }
        lock.lock(); waiters[id] = nil; lock.unlock()
        return w.box.r
    }

    private func resolve(_ id: String, _ r: PeerSendResult) {
        lock.lock(); let w = waiters[id]; lock.unlock()
        guard let w else { return }
        w.box.r = r
        w.sem.signal()
    }

    private func failAllWaiters() {
        lock.lock(); let ids = Array(waiters.keys); lock.unlock()
        for id in ids { resolve(id, .retry) }
    }

    // MARK: connection (all on `q`)

    private func connect() {
        guard wanted, task == nil else { return }
        guard let url = PeerRelay.connectURL(relayURL(), mailboxId: identity.mailboxId) else {
            scheduleReconnect(); return      // placeholder / bad URL: stay offline, retry slowly (the setting may change)
        }
        gen += 1
        let g = gen
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 512 * 1024
        task = t
        t.resume()
        receive(t, g, host: PeerRelay.helloHost(url))
        q.asyncAfter(deadline: .now() + 15) { [self] in       // no "ready" in 15 s: the hello went nowhere
            if g == gen, !isConnected { fail(g) }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ g: Int, host: String) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {
                guard g == self.gen else { return }
                switch result {
                case .failure: self.fail(g)
                case .success(let m):
                    if case .string(let s) = m { self.handle(s, t, g, host: host) }
                    self.receive(t, g, host: host)
                }
            }
        }
    }

    private func handle(_ text: String, _ t: URLSessionWebSocketTask, _ g: Int, host: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let kind = o["t"] as? String else { return }
        switch kind {
        case "challenge":
            guard let nonce = o["nonce"] as? String else { return }
            let sig = identity.helloSignature(nonce: nonce, host: host)
            let hello: [String: Any] = ["t": "hello", "pub": PeerB64.std(identity.keys.sign), "sig": PeerB64.std(sig)]
            if let d = try? JSONSerialization.data(withJSONObject: hello), let s = String(data: d, encoding: .utf8) {
                t.send(.string(s)) { _ in }
            }
        case "ready":
            lock.lock(); ready = true; lock.unlock()
            attempt = 0
            onStatus?(true)
            schedulePing(g)
        case "ack":
            if let id = o["id"] as? String { resolve(id, .delivered) }
        case "nack":
            if let id = o["id"] as? String { resolve(id, (o["reason"] as? String) == "size" ? .refused : .retry) }
        case "msg":
            guard let from = o["from"] as? String, let id = o["id"] as? String, let b = o["blob"] as? String,
                  let blob = PeerB64.fromStd(b) ?? PeerB64.fromURL(b) else { return }
            onMessage?(from, id, blob)
            if let d = try? JSONSerialization.data(withJSONObject: ["t": "got", "id": id]), let s = String(data: d, encoding: .utf8) {
                t.send(.string(s)) { _ in }
            }
        default: break
        }
    }

    private func schedulePing(_ g: Int) {
        q.asyncAfter(deadline: .now() + 300) { [self] in
            guard g == gen, let t = task, isConnected else { return }
            t.sendPing { [weak self] err in
                guard let self else { return }
                if err != nil { self.q.async { self.fail(g) } } else { self.q.async { self.schedulePing(g) } }
            }
        }
    }

    private func fail(_ g: Int) {
        guard g == gen else { return }
        teardown()
        scheduleReconnect()
    }

    private func teardown() {
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        lock.lock(); let was = ready; ready = false; lock.unlock()
        failAllWaiters()
        if was { onStatus?(false) }
    }

    private func scheduleReconnect() {
        guard wanted else { return }
        let d = PeerRelay.reconnectDelay(attempt: attempt)
        attempt += 1
        let g = gen
        q.asyncAfter(deadline: .now() + d) { [self] in
            if wanted, task == nil, g == gen { connect() }
        }
    }
}

/// The one engine + relay connection for this app. Built on first use (so keys are generated on first Peers use).
enum PeerService {
    static let relay = PeerRelayLive(identity: identity)
    static let identity = PeerIdentity.loadOrCreate(root: PeerEngine.standardRoot)
    private(set) nonisolated(unsafe) static var oracle: Oracle?
    static let engine: PeerEngine = {
        let e = PeerEngine(identity: identity, launcher: PeerLauncherLive(), transport: relay)
        e.onJobArrived = { PeerNotifier.shared.jobArrived($0) }
        let bus = makeChatBus(name: Host.current().localizedName ?? "True")
        e.chat = bus
        oracle = Oracle(engine: e, bus: bus)      // Run 33: `@oracle` answers peers' questions from the second brain
        return e
    }()

    private static func onMain<T: Sendable>(_ f: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { f() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { f() } }
    }

    /// The live channel store (`~/.true/chat`): seats are the app's agents, a line is typed into the seat's pane, and a
    /// seat sitting at a permission dialog holds its lines until the next pane event releases them.
    private static func makeChatBus(name: String) -> ChatBus {
        let bus = ChatBus(root: AgentPaths.standard.root, mac: String(name.prefix(PeerValidate.maxLabel)),
                          seats: { onMain { Array(AgentRegistry.shared.panes.keys) } },
                          deliver: { seat, line in onMain { AgentRegistry.shared.talk(seat, line) } },
                          atPermissionPrompt: { seat in
                              onMain {
                                  guard let pane = AgentRegistry.shared.panes[seat] else { return false }
                                  return TerminalRegistry.shared.view(for: pane).map { PermissionDialog.isVisible(in: $0.screenText()) } ?? false
                              }
                          })
        bus.knownSeat = { seat in onMain { AgentRegistry.shared.agent(named: seat) != nil } }
        bus.onMessage = { _ in NotificationCenter.default.post(name: .peersChanged, object: nil) }
        return bus
    }

    /// At launch: wake the engine (and the relay connection) only if this Mac already has peers or a pending invite.
    static func startIfPaired() {
        let fm = FileManager.default
        let r = PeerEngine.standardRoot
        guard fm.fileExists(atPath: r.appendingPathComponent("peers.json").path) || fm.fileExists(atPath: r.appendingPathComponent("invites.json").path) else { return }
        Task.detached(priority: .utility) { _ = engine }
    }
}
