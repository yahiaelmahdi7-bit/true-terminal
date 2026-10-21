import Foundation

/// One localhost server a True pane started (GET /api/sites).
public struct RemoteSite: Codable, Sendable, Equatable, Identifiable, Hashable {
    public struct HostFix: Codable, Sendable, Equatable, Hashable { public var framework: String; public var snippet: String }
    public var port: Int
    public var title: String?
    public var pane: String?
    public var project: String?
    public var command: String?
    public var exposed: Bool
    public var url: String?
    public var hostFix: HostFix?
    public var id: Int { port }
    public init(port: Int, title: String? = nil, pane: String? = nil, project: String? = nil, command: String? = nil,
                exposed: Bool = false, url: String? = nil, hostFix: HostFix? = nil) {
        self.port = port; self.title = title; self.pane = pane; self.project = project; self.command = command
        self.exposed = exposed; self.url = url; self.hostFix = hostFix
    }
}

public struct SitesResponse: Codable, Sendable { public var sites: [RemoteSite] }

public struct BrowserTab: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String; public var title: String; public var url: String; public var active: Bool
    public init(id: String, title: String, url: String, active: Bool) { self.id = id; self.title = title; self.url = url; self.active = active }
}

public struct BrowserTabs: Codable, Sendable, Equatable {
    public var tabs: [BrowserTab]; public var canBack: Bool; public var canForward: Bool
    public init(tabs: [BrowserTab], canBack: Bool = false, canForward: Bool = false) { self.tabs = tabs; self.canBack = canBack; self.canForward = canForward }
}

public enum BrowserEvent: Sendable {
    /// A decoded screencast frame: JPEG bytes, the emulated page size in CSS px, and Mac send time (ms since epoch) for latency.
    case frame(jpeg: Data, width: Int, height: Int, sentAtMs: Double)
    case tabs(BrowserTabs)
    /// {"t":"error"|"off"}: True Chrome could not start, or "Phone browser" is off on the Mac.
    case failed(String)
    case closed(RemoteError?)
}

extension RemoteSession {
    public func sites(refresh: Bool = false) async throws -> [RemoteSite] {
        try await getJSON("/api/sites" + (refresh ? "?refresh=1" : ""), as: SitesResponse.self).sites
    }
    /// POST /api/sites/<port>/expose|unexpose → the updated row (or throws `.http` with the Mac's reason).
    public func setSiteExposed(port: Int, _ on: Bool) async throws -> RemoteSite {
        try await postJSON("/api/sites/\(port)/" + (on ? "expose" : "unexpose"))
    }
    public func browserTabs() async throws -> BrowserTabs { try await getJSON("/api/browser/tabs") }
    public func browserTabAction(_ action: String, url: String? = nil, id: String? = nil) async throws {
        var b: [String: String] = ["action": action]
        if let url { b["url"] = url }
        if let id { b["id"] = id }
        _ = try await postRaw("/api/browser/tabs", body: JSONEncoder().encode(b))
    }
}

/// WS /api/browser/stream. Frames are binary (`BrowserWire`), everything else JSON text. First message is {"auth":token}.
public actor BrowserSocket {
    public nonisolated let events: AsyncStream<BrowserEvent>
    private let continuation: AsyncStream<BrowserEvent>.Continuation
    private let task: URLSessionWebSocketTask
    private let token: String
    private var reader: Task<Void, Never>?

    public init(baseURL: URL, token: String, session: URLSession = RemoteSession.defaultTransport()) throws {
        guard var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw RemoteError.badResponse }
        let origin = { var o = c; o.path = ""; return o.string ?? baseURL.absoluteString }()
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = "/api/browser/stream"
        guard let url = c.url else { throw RemoteError.badResponse }
        var req = URLRequest(url: url)
        req.setValue(origin, forHTTPHeaderField: "Origin")
        task = session.webSocketTask(with: req)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.token = token
        (events, continuation) = AsyncStream.makeStream(of: BrowserEvent.self)
    }

    public func connect() async {
        task.resume()
        do { try await task.send(.string(String(decoding: try JSONEncoder().encode(["auth": token]), as: UTF8.self))) }
        catch { finish(error); return }
        reader = Task { [weak self] in await self?.readLoop() }
    }

    /// Fire-and-forget JSON command ({"t":"tap",...}); see `BrowserCommand` on the Mac.
    public func send(_ message: [String: Any]) async {
        guard let d = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? await task.send(.string(String(decoding: d, as: UTF8.self)))
    }

    public func close() {
        reader?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        continuation.yield(.closed(nil)); continuation.finish()
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                switch try await task.receive() {
                case .data(let d):
                    if let f = BrowserWire.decodeFrame(d) {
                        continuation.yield(.frame(jpeg: f.jpeg, width: f.header["w"] as? Int ?? 0, height: f.header["h"] as? Int ?? 0,
                                                  sentAtMs: (f.header["ts"] as? NSNumber)?.doubleValue ?? 0))
                    }
                case .string(let s): handleText(s)
                @unknown default: break
                }
            } catch { finish(error); return }
        }
    }

    private func handleText(_ s: String) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], let t = o["t"] as? String else { return }
        switch t {
        case "tabs":
            if let tabs = try? JSONDecoder().decode(BrowserTabs.self, from: Data(s.utf8)) { continuation.yield(.tabs(tabs)) }
        case "error": continuation.yield(.failed(o["message"] as? String ?? "True Chrome could not start on the Mac."))
        case "off": continuation.yield(.failed("Phone browser is off. Turn it on in True's Settings on the Mac."))
        default: break
        }
    }

    private func finish(_ error: Error) {
        let code = task.closeCode.rawValue
        let reason: RemoteError? = code == 4401 ? .unauthorized : code == 1000 ? nil : .transport(error.localizedDescription)
        continuation.yield(.closed(reason)); continuation.finish()
    }
}
