import Foundation
@testable import True

/// Run 39 test rig: an in-memory local network. Frames and connects are queued and delivered by `net.run()`, so tests
/// are deterministic. Timers fire only when a test says so.
@MainActor
final class FakeLanNet {
    private var queue: [@MainActor () -> Void] = []
    var transports: [String: FakeLanTransport] = [:]
    func post(_ f: @escaping @MainActor () -> Void) { queue.append(f) }
    func run() { var n = 0; while !queue.isEmpty, n < 10_000 { queue.removeFirst()(); n += 1 } }
}

@MainActor
final class FakeLanConnection: PeerLanConnection {
    let remote: String
    var onReady: (() -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var peer: FakeLanConnection?
    let net: FakeLanNet
    private(set) var closed = false
    private(set) var started = false
    /// Every payload this end sent, decoded for assertions.
    private(set) var sent: [[String: Any]] = []
    var onStart: (() -> Void)?
    init(net: FakeLanNet, remote: String) { self.net = net; self.remote = remote }
    func start() { started = true; onStart?() }
    func send(_ payload: Data) {
        guard !closed else { return }
        if let o = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] { sent.append(o) }
        let p = peer
        net.post { p?.deliver(payload) }
    }
    func deliver(_ d: Data) { if !closed { onFrame?(d) } }
    func close() {
        guard !closed else { return }
        closed = true
        let cb = onClose; onClose = nil; cb?()
        let p = peer
        net.post { p?.remoteClosed() }
    }
    func remoteClosed() { close() }
    /// Types of the frames this end RECEIVED (the peer's sent list), for tests that hold the far end.
    func deliveredTypes() -> [String] { peer?.types() ?? [] }
    func types() -> [String] { sent.compactMap { $0["t"] as? String } }
    static func pair(net: FakeLanNet, remote: String) -> (FakeLanConnection, FakeLanConnection) {
        let a = FakeLanConnection(net: net, remote: remote), b = FakeLanConnection(net: net, remote: remote)
        a.peer = b; b.peer = a
        return (a, b)
    }
}

@MainActor
final class FakeLanTransport: PeerLanTransport {
    var onBrowse: ((PeerLanBrowseEvent) -> Void)?
    var onIncoming: ((PeerLanConnection) -> Void)?
    private(set) var isOpen = false
    private(set) var syncs: [Bool] = []
    var name = "", txt: [String: String] = [:]
    let net: FakeLanNet, address: String
    /// Connections this transport dialled out (client ends).
    private(set) var dialled: [FakeLanConnection] = []
    var remoteAddress = "10.0.0.2"
    init(net: FakeLanNet, address: String) { self.net = net; self.address = address; net.transports[address] = self }

    func sync(open: Bool, name: String, txt: [String: String]) {
        syncs.append(open)
        guard open != isOpen else { return }
        isOpen = open
        self.name = name; self.txt = txt
        for (addr, t) in net.transports where addr != address && t.isOpen {
            if open { t.onBrowse?(.found(id: address, name: name, txt: txt)); onBrowse?(.found(id: addr, name: t.name, txt: t.txt)) }
            else { t.onBrowse?(.removed(id: address)) }
        }
    }

    func connect(to id: String) -> PeerLanConnection? {
        guard let target = net.transports[id], target.isOpen else { return nil }
        let (client, server) = FakeLanConnection.pair(net: net, remote: remoteAddress)
        dialled.append(client)
        client.onStart = { [net] in
            net.post {
                target.onIncoming?(server)
                server.start()
                client.onReady?()
                server.onReady?()
            }
        }
        return client
    }

    /// Inject a raw incoming connection (for hostile-peer tests). Returns the remote end.
    func inject(remote: String = "10.0.0.9") -> FakeLanConnection {
        let (client, server) = FakeLanConnection.pair(net: net, remote: remote)
        onIncoming?(server)
        return client
    }
}

@MainActor
final class ManualTimers {
    struct T { var delay: TimeInterval; var fire: @MainActor () -> Void; var live: Bool }
    private(set) var all: [T] = []
    private final class Flag { var live = true }
    var factory: PeerLanTimerFactory {
        return { [unowned self] delay, fire in
            let idx = self.all.count
            self.all.append(T(delay: delay, fire: fire, live: true))
            return { [unowned self] in self.all[idx].live = false }
        }
    }
    /// Fire the newest live timer with this delay.
    @discardableResult func fire(_ delay: TimeInterval) -> Bool {
        guard let i = all.lastIndex(where: { $0.live && $0.delay == delay }) else { return false }
        all[i].live = false; all[i].fire(); return true
    }
    func live(_ delay: TimeInterval) -> Bool { all.contains { $0.live && $0.delay == delay } }
}
