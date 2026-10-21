import Foundation

/// One DevTools-protocol WebSocket to Chrome. Responses are matched by id on the receive path (never blocked),
/// events go to `onEvent`. `call` blocks the calling thread, so never call it from `onEvent`'s thread.
final class CDPConnection: NSObject, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private(set) var closed = false
    var onEvent: ((String, [String: Any], String?) -> Void)?
    var onClose: (() -> Void)?

    struct CDPError: Error, CustomStringConvertible { let description: String }

    init?(url: String) {
        guard let u = URL(string: url) else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        session = URLSession(configuration: cfg)
        task = session.webSocketTask(with: u)
        task.maximumMessageSize = 32 * 1024 * 1024
        super.init()
    }

    func start() { task.resume(); receive() }

    func close() {
        lock.lock(); closed = true; let all = pending; pending = [:]; lock.unlock()
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        for (_, c) in all { c(.failure(CDPError(description: "closed"))) }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                lock.lock(); let was = closed; closed = true; let all = pending; pending = [:]; lock.unlock()
                for (_, c) in all { c(.failure(CDPError(description: "closed"))) }
                if !was { onClose?() }
            case .success(let msg):
                var text: String?
                switch msg { case .string(let s): text = s; case .data(let d): text = String(decoding: d, as: UTF8.self); @unknown default: break }
                if let text, let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                    if let id = o["id"] as? Int {
                        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
                        if let e = o["error"] as? [String: Any] { c?(.failure(CDPError(description: e["message"] as? String ?? "error"))) }
                        else { c?(.success(o["result"] as? [String: Any] ?? [:])) }
                    } else if let method = o["method"] as? String {
                        onEvent?(method, o["params"] as? [String: Any] ?? [:], o["sessionId"] as? String)
                    }
                }
                receive()
            }
        }
    }

    func send(_ method: String, _ params: [String: Any] = [:], session sid: String? = nil,
              completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        lock.lock()
        if closed { lock.unlock(); completion?(.failure(CDPError(description: "closed"))); return }
        nextID += 1; let id = nextID
        if let completion { pending[id] = completion }
        lock.unlock()
        task.send(.string(CDPMessage.encode(id: id, method: method, params: params, sessionId: sid))) { [weak self] err in
            guard let err, let self else { return }
            lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
            c?(.failure(err))
        }
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], session sid: String? = nil, timeout: TimeInterval = 8) -> Result<[String: Any], Error> {
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        send(method, params, session: sid) { box.value = $0; sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return .failure(CDPError(description: "timeout \(method)")) }
        return box.value ?? .failure(CDPError(description: "no result"))
    }

    private final class Box: @unchecked Sendable { var value: Result<[String: Any], Error>? }
}
