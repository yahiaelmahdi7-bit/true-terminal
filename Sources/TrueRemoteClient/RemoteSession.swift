import Foundation
#if os(iOS)
import UIKit
#endif

public enum RemoteError: Error, Equatable, Sendable {
    /// 401 (or WS close 4401): the token is gone or revoked. The token store has been cleared; show the pairing screen.
    case unauthorized
    /// 404 on /api/route* or /api/run: route ids are short-lived. Route again.
    case routeExpired
    /// 429. `retryAfter` is the Retry-After header in seconds when the Mac sent one.
    case rateLimited(retryAfter: TimeInterval?)
    /// 403: identity/Host/Origin mismatch, a send-only token, or the Mac refusing a run.
    case refused
    case http(Int)
    /// POST /pair answered 401/403 with {"error"}: wrong, burned or expired code.
    case pairingFailed(String)
    /// 404 on /api/pane/<id>/input: the pane was closed.
    case paneGone
    case badResponse
    case transport(String)
}

public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func load() -> String? { lock.lock(); defer { lock.unlock() }; return token }
    public func save(_ t: String) { lock.lock(); token = t; lock.unlock() }
    public func clear() { lock.lock(); token = nil; lock.unlock() }
}

public protocol RemoteTransport: Sendable {
    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: RemoteTransport {
    public func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RemoteError.badResponse }
        return (data, http)
    }
}

/// One paired phone's connection to one Mac. Bearer header only, never a cookie (app.js: cookies ignore ports).
public actor RemoteSession {
    public let baseURL: URL
    private let store: TokenStore
    private let transport: RemoteTransport
    private var dutyHeader: String?

    /// Diagnostic value sent as `X-True-Duty` on GET /api/hub only; nil sends nothing.
    public func setDutyHeader(_ value: String?) { dutyHeader = value }

    public init(baseURL: URL, store: TokenStore, transport: RemoteTransport = RemoteSession.defaultTransport()) {
        self.baseURL = baseURL; self.store = store; self.transport = transport
    }

    public static var clientUserAgent: String {
        #if os(iOS)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return "True/1 (\(device); iOS \(UIDevice.current.systemVersion))"
        #else
        return "True/1 (Macintosh)"
        #endif
    }

    public static func defaultTransport() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        // The Mac labels a paired device from this header ("iPhone · paired ..."); CFNetwork's default says neither.
        c.httpAdditionalHeaders = ["User-Agent": clientUserAgent]
        return URLSession(configuration: c)
    }

    public var isPaired: Bool { store.load() != nil }

    // MARK: Pairing

    /// POST /pair {"code"} -> {"token"}; saves the token. Wrong/burned/expired codes are 401 with {"error"}.
    public func pair(code: String) async throws {
        let body = try JSONEncoder().encode(["code": code.trimmingCharacters(in: .whitespaces)])
        let (data, resp) = try await perform("POST", "/pair", body: body, authenticated: false)
        let decoded = try? JSONDecoder().decode(PairResponse.self, from: data)
        switch resp.statusCode {
        case 200..<300:
            guard let token = decoded?.token, !token.isEmpty else { throw RemoteError.badResponse }
            store.save(token)
        case 401, 403: throw RemoteError.pairingFailed(decoded?.error ?? "Pairing failed.")
        default: throw try map(resp, path: "/pair")
        }
    }

    public func unpair() { store.clear() }

    // MARK: Endpoints

    public func hub() async throws -> HubSnapshot { try await get("/api/hub") }
    public func builderDetail(id: String) async throws -> BuilderDetail { try await get("/api/hub/builder/" + Self.seg(id)) }
    public func ackBuilder(id: String) async throws { _ = try await call("POST", "/api/hub/builder/" + Self.seg(id) + "/ack", json: [String: String]()) }
    public func inbox() async throws -> [InboxItem] { try await get("/api/inbox", as: InboxResponse.self).items }
    public func inboxData(id: String) async throws -> Data { try await call("GET", "/api/inbox/" + Self.seg(id)) }
    public func deleteInboxItem(id: String) async throws { _ = try await call("DELETE", "/api/inbox/" + Self.seg(id)) }
    public func clip(text: String) async throws { _ = try await call("POST", "/api/clip", json: ["text": text]) }
    /// POST /api/drop: raw body, name in X-Filename (server sanitises it). 200 MB max.
    public func drop(_ data: Data, filename: String) async throws -> DropResponse {
        let out = try await call("POST", "/api/drop", body: data, headers: ["X-Filename": filename, "Content-Type": "application/octet-stream"])
        return try decode(out)
    }
    public func recent() async throws -> [String] { try await get("/api/recent", as: RecentResponse.self).items }
    public func route(text: String) async throws -> RouteResponse { try await post("/api/route", ["text": text]) }

    public func setSlot(routeId: String, slot: String, value: String) async throws -> RouteResponse {
        var r: RouteResponse = try await post("/api/route/" + Self.seg(routeId) + "/slot", ["slot": slot, "value": value])
        if r.routeId == nil { r.routeId = routeId }
        return r
    }

    /// 409 comes back as a normal RunResponse with `needsConfirm == true`.
    public func run(routeId: String, background: Bool = false, confirmed: Bool = false) async throws -> RunResponse {
        struct Body: Encodable { var routeId: String; var background: Bool; var confirm: Bool }
        let data = try await call("POST", "/api/run", json: Body(routeId: routeId, background: background, confirm: confirmed), accept: [409])
        return try decode(data)
    }

    public func shots() async throws -> [Shot] { try await get("/api/shots", as: ShotsResponse.self).shots }
    public func shotData(id: String) async throws -> Data { try await call("GET", "/api/shots/" + Self.seg(id)) }
    /// POST /api/pane/<id>/input. Never throws on an unrecognised outcome string; 404 is `.paneGone`.
    public func paneInput(id: String, intent: PaneInputIntent, text: String = "",
                          attachments: [PaneAttachmentRef] = []) async throws -> InputOutcome {
        struct Body: Encodable { var intent: String; var text: String; var attach: [PaneAttachmentRef]?
            func encode(to e: Encoder) throws {
                var c = e.container(keyedBy: K.self)
                try c.encode(intent, forKey: .intent); try c.encode(text, forKey: .text)
                if let attach, !attach.isEmpty { try c.encode(attach, forKey: .attach) }
            }
            enum K: String, CodingKey { case intent, text, attach } }
        let data = try await call("POST", "/api/pane/" + Self.seg(id) + "/input",
                                  json: Body(intent: intent.rawValue, text: text, attach: attachments))
        let wire = (try? JSONDecoder().decode([String: String].self, from: data))?["outcome"]
        return InputOutcome(wire: wire ?? "")
    }
    public func tabs() async throws -> TabsResponse { try await get("/api/tabs") }

    // MARK: Plumbing

    /// Origin the server requires on state-changing requests and the WS upgrade: exactly scheme://host:port.
    var origin: String {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.path = ""; c.query = nil; c.fragment = nil
        return c.string ?? baseURL.absoluteString
    }

    public func currentToken() -> String? { store.load() }

    private static func seg(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s }

    func getJSON<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T { try decode(try await call("GET", path)) }
    func postJSON<T: Decodable>(_ path: String) async throws -> T { try decode(try await call("POST", path, json: [String: String]())) }
    func postRaw(_ path: String, body: Data) async throws -> Data { try await call("POST", path, body: body, headers: ["Content-Type": "application/json"]) }

    private func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T { try decode(try await call("GET", path)) }
    private func post<T: Decodable>(_ path: String, _ body: some Encodable) async throws -> T { try decode(try await call("POST", path, json: body)) }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw RemoteError.badResponse }
    }

    private func call(_ method: String, _ path: String, json: (some Encodable)? = Optional<String>.none, body: Data? = nil,
                      headers: [String: String] = [:], accept: Set<Int> = []) async throws -> Data {
        let payload = try json.map { try JSONEncoder().encode($0) } ?? body
        var h = headers
        if json != nil { h["Content-Type"] = "application/json" }
        return try await send(method, path, body: payload, headers: h, accept: accept)
    }

    private func send(_ method: String, _ path: String, body: Data?, headers: [String: String], accept: Set<Int>) async throws -> Data {
        let (data, resp) = try await perform(method, path, body: body, headers: headers, authenticated: true)
        if (200..<300).contains(resp.statusCode) || accept.contains(resp.statusCode) { return data }
        throw try map(resp, path: path)
    }

    /// The one place a URLRequest is built: Bearer, no-store, no cookies, and Origin on anything that isn't a GET.
    private func perform(_ method: String, _ path: String, body: Data?, headers: [String: String] = [:], authenticated: Bool) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw RemoteError.badResponse }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        req.httpBody = body
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if authenticated {
            guard let token = store.load() else { throw RemoteError.unauthorized }
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if method != "GET" { req.setValue(origin, forHTTPHeaderField: "Origin") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if method == "GET", path == "/api/hub", let d = dutyHeader { req.setValue(d, forHTTPHeaderField: "X-True-Duty") }
        do { return try await transport.send(req) }
        catch let e as RemoteError { throw e }
        catch { throw RemoteError.transport(error.localizedDescription) }
    }

    private func map(_ resp: HTTPURLResponse, path: String) throws -> RemoteError {
        switch resp.statusCode {
        case 401: store.clear(); return .unauthorized
        case 404 where path.hasPrefix("/api/pane/") && path.hasSuffix("/input"): return .paneGone
        case 404 where path.hasPrefix("/api/route") || path == "/api/run": return .routeExpired
        case 429: return .rateLimited(retryAfter: resp.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case 403: return .refused
        default: return .http(resp.statusCode)
        }
    }
}
