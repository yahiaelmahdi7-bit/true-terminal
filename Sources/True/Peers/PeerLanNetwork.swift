import Foundation
import Network

/// Run 39 — the live `PeerLanTransport`: a Bonjour `NWListener` + `NWBrowser` for `_true-peer._tcp`, and `NWConnection`s
/// carrying length-prefixed frames. Nothing here is constructed until the Peers window opens. Every handler runs on the
/// main queue, so `MainActor.assumeIsolated` is exact, not a hope.
@MainActor
final class PeerLanNetwork: PeerLanTransport {
    var onBrowse: ((PeerLanBrowseEvent) -> Void)?
    var onIncoming: ((PeerLanConnection) -> Void)?
    private(set) var isOpen = false

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var name = "", txt: [String: String] = [:]
    private var generation = 0
    private var listenerBackoff: TimeInterval = 2, browserBackoff: TimeInterval = 2

    func sync(open: Bool, name: String, txt: [String: String]) {
        if open {
            guard !isOpen else { return }
            isOpen = true; generation += 1
            self.name = name; self.txt = txt
            listenerBackoff = 2; browserBackoff = 2
            startListener(); startBrowser()
        } else if isOpen {
            isOpen = false; generation += 1
            listener?.cancel(); listener = nil
            browser?.cancel(); browser = nil
            endpoints.removeAll()
        }
    }

    /// Live tests on one Mac set `.loopback`: macOS does not deliver a process's connection to itself over its LAN address.
    var dialInterface: NWInterface.InterfaceType?

    func connect(to id: String) -> PeerLanConnection? {
        guard let ep = endpoints[id] else { return nil }
        let p = NWParameters.tcp
        if let t = dialInterface { p.requiredInterfaceType = t }
        return PeerLanNWConnection(NWConnection(to: ep, using: p), remote: "")
    }

    // MARK: listener

    private func startListener() {
        listener?.cancel(); listener = nil
        guard isOpen, let l = try? NWListener(using: .tcp) else { retryListener(); return }
        l.service = NWListener.Service(name: name, type: PeerLanTXT.serviceType, txtRecord: NWTXTRecord(txt))
        let gen = generation
        l.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                switch st {
                case .ready: self.listenerBackoff = 2
                case .failed: self.retryListener()
                default: break
                }
            } }
        }
        l.newConnectionHandler = { [weak self] c in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.generation == gen else { c.cancel(); return }
                self.onIncoming?(PeerLanNWConnection(c, remote: Self.host(of: c.endpoint)))
            } }
        }
        listener = l
        l.start(queue: .main)
    }

    private func retryListener() {
        let gen = generation, d = listenerBackoff
        listenerBackoff = min(60, listenerBackoff * 2)
        listener?.cancel(); listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { MainActor.assumeIsolated {
            if self.isOpen, self.generation == gen { self.startListener() }
        } }
    }

    // MARK: browser

    private func startBrowser() {
        browser?.cancel(); browser = nil
        guard isOpen else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: PeerLanTXT.serviceType, domain: nil), using: .tcp)
        let gen = generation
        b.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                switch st {
                case .ready: self.browserBackoff = 2; self.onBrowse?(.state(.ready))
                case .waiting(let err):
                    if case .dns(let code) = err, code == -65570 { self.onBrowse?(.state(.denied)) } else { self.onBrowse?(.state(.waiting)) }
                case .failed: self.onBrowse?(.state(.waiting)); self.retryBrowser()
                default: break
                }
            } }
        }
        b.browseResultsChangedHandler = { [weak self] _, changes in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                for ch in changes {
                    switch ch {
                    case .added(let r): self.add(r)
                    case .removed(let r): self.drop(r)
                    case .changed(let old, let new, _): self.drop(old); self.add(new)
                    default: break
                    }
                }
            } }
        }
        browser = b
        b.start(queue: .main)
    }

    private func retryBrowser() {
        let gen = generation, d = browserBackoff
        browserBackoff = min(60, browserBackoff * 2)
        browser?.cancel(); browser = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { MainActor.assumeIsolated {
            if self.isOpen, self.generation == gen { self.startBrowser() }
        } }
    }

    private func add(_ r: NWBrowser.Result) {
        guard case .service(let svc, _, _, _) = r.endpoint, case .bonjour(let rec) = r.metadata else { return }
        let id = "\(r.endpoint)"
        endpoints[id] = r.endpoint
        onBrowse?(.found(id: id, name: svc, txt: rec.dictionary))
    }

    private func drop(_ r: NWBrowser.Result) {
        let id = "\(r.endpoint)"
        endpoints[id] = nil
        onBrowse?(.removed(id: id))
    }

    nonisolated static func host(of ep: NWEndpoint) -> String {
        if case .hostPort(let h, _) = ep { return "\(h)".split(separator: "%").first.map(String.init) ?? "\(h)" }
        return "\(ep)"
    }
}

/// An `NWConnection` speaking `PeerLanFrame`s. A bad length closes the connection before any body is read.
@MainActor
final class PeerLanNWConnection: PeerLanConnection {
    let remote: String
    var onReady: (() -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let conn: NWConnection
    private var closed = false

    init(_ c: NWConnection, remote: String) { conn = c; self.remote = remote }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                switch st {
                case .ready: self.onReady?(); self.readHeader()
                case .failed, .cancelled: self.finish()
                default: break
                }
            } }
        }
        conn.start(queue: .main)
    }

    func send(_ payload: Data) {
        guard !closed, let framed = PeerLanFrame.wrap(payload) else { return }
        conn.send(content: framed, completion: .contentProcessed { _ in })
    }

    /// Graceful: frames already sent (a last "done" or "bye") reach the other side first. `cancel()` alone drops them.
    func close() { finish(flush: true) }

    private func finish(flush: Bool = false) {
        guard !closed else { return }
        closed = true
        conn.stateUpdateHandler = nil
        if flush {
            let c = conn
            c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { c.cancel() }
        } else {
            conn.cancel()
        }
        onFrame = nil; onReady = nil
        let cb = onClose; onClose = nil
        cb?()
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, err in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard err == nil, let data, let n = PeerLanFrame.length(header: data) else { self.finish(); return }
                self.readBody(n)
            } }
        }
    }

    private func readBody(_ n: Int) {
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, _, err in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard err == nil, let data, data.count == n else { self.finish(); return }
                self.onFrame?(data)
                if !self.closed { self.readHeader() }
            } }
        }
    }
}
