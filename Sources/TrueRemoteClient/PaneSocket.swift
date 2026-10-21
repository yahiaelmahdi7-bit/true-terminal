import Foundation

public enum PaneEvent: Sendable, Equatable {
    /// Binary frame: raw PTY bytes (the first one after `.snapshot` is the screen contents).
    case output(Data)
    /// {"t":"snap","cols":N,"rows":M}: the Mac's size. There is no resize message; the Mac stays authoritative.
    case snapshot(cols: Int, rows: Int)
    /// {"t":"gone"}: the pane was closed on the Mac.
    case gone
    /// Always the last event. `.unauthorized` for close code 4401; otherwise the reason (nil = clean close).
    /// Like app.js, a caller seeing a non-4401 close should probe `RemoteSession.tabs()` to learn about a 401.
    case closed(RemoteError?)
}

/// WS /api/pane/{uuid}. The upgrade needs no token; the FIRST message must be text {"auth":"<token>"} within 5 s.
/// Client input is sent as binary frames (app.js: ws.send(enc.encode(s))).
public actor PaneSocket {
    public nonisolated let events: AsyncStream<PaneEvent>
    private let continuation: AsyncStream<PaneEvent>.Continuation
    private let task: URLSessionWebSocketTask
    private let token: String
    private var reader: Task<Void, Never>?

    public init(baseURL: URL, paneId: String, token: String, session: URLSession = RemoteSession.defaultTransport()) throws {
        guard var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw RemoteError.badResponse }
        let origin = { var o = c; o.path = ""; return o.string ?? baseURL.absoluteString }()
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = "/api/pane/" + paneId
        guard let url = c.url else { throw RemoteError.badResponse }
        var req = URLRequest(url: url)
        req.setValue(origin, forHTTPHeaderField: "Origin")   // the server demands an exact Origin on the upgrade
        task = session.webSocketTask(with: req)
        self.token = token
        (events, continuation) = AsyncStream.makeStream(of: PaneEvent.self)
    }

    public func connect() async {
        task.resume()
        do { try await task.send(.string(String(decoding: try JSONEncoder().encode(["auth": token]), as: UTF8.self))) }
        catch { finish(error); return }
        reader = Task { [weak self] in await self?.readLoop() }
    }

    public func send(_ text: String) async throws { try await task.send(.data(Data(text.utf8))) }
    public func send(bytes: Data) async throws { try await task.send(.data(bytes)) }

    public func close() {
        reader?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        continuation.yield(.closed(nil)); continuation.finish()
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                switch try await task.receive() {
                case .data(let d): continuation.yield(.output(d))
                case .string(let s): handleControl(s)
                @unknown default: break
                }
            } catch { finish(error); return }
        }
    }

    private func handleControl(_ s: String) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], let t = o["t"] as? String else { return }
        if t == "snap", let cols = o["cols"] as? Int, let rows = o["rows"] as? Int { continuation.yield(.snapshot(cols: cols, rows: rows)) }
        else if t == "gone" { continuation.yield(.gone) }
    }

    private func finish(_ error: Error) {
        let code = task.closeCode.rawValue
        let reason: RemoteError? = code == 4401 ? .unauthorized : code == 1000 ? nil : .transport(error.localizedDescription)
        continuation.yield(.closed(reason)); continuation.finish()
    }
}
