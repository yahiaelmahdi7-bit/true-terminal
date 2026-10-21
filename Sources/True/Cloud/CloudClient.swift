import Foundation

/// One job as `GET /jobs` and `GET /jobs/:id` return it (true-factory, docs/spec-factory.md). Times are unix seconds.
struct CloudJob: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var repo: String
    var branch: String
    /// `working | needsYou | done | failed`: the Hub's vocabulary.
    var status: String
    var foremanStatus: String?
    var needsYouReason: String?
    var reason: String?
    var createdAt: Double
    var updatedAt: Double
    var viewedAt: Double?
    var unviewed: Bool?
    var archived: Bool?
    /// What the job was started with (nil = the server's default, or an older server).
    var model: String?
    var effort: String?

    enum CodingKeys: String, CodingKey {
        case id, title, repo, branch, status, reason, unviewed, archived, model, effort
        case foremanStatus = "foreman_status", needsYouReason = "needs_you_reason"
        case createdAt = "created_at", updatedAt = "updated_at", viewedAt = "viewed_at"
    }

    /// "Sonnet 5.5 · High", or nil when neither was recorded.
    var modelChip: String? { CloudModel.chip(model: model, effort: effort) }

    var isWorking: Bool { status == "working" }
    var needsYou: Bool { status == "needsYou" }
    var isDone: Bool { status == "done" }
    var isFailed: Bool { status == "failed" }
}

/// `GET /jobs/:id`: the job plus what it was asked, the base it branched from and Foreman's last verdict.
struct CloudJobDetail: Codable, Equatable, Sendable {
    var job: CloudJob
    var prompt: String
    var base: String?
    var baseSha: String?

    init(job: CloudJob, prompt: String, base: String?, baseSha: String?) {
        (self.job, self.prompt, self.base, self.baseSha) = (job, prompt, base, baseSha)
    }
    private enum K: String, CodingKey { case job, base, baseSha = "base_sha" }
    init(from decoder: Decoder) throws {
        job = try CloudJob(from: decoder)
        let c = try decoder.container(keyedBy: K.self)
        prompt = try c.decodeIfPresent(String.self, forKey: .job) ?? ""
        base = try c.decodeIfPresent(String.self, forKey: .base)
        baseSha = try c.decodeIfPresent(String.self, forKey: .baseSha)
    }
    func encode(to encoder: Encoder) throws { try job.encode(to: encoder) }
}

/// One line of `events.jsonl`, loosely typed: the factory's shape is Foreman's, so unknown keys are kept in `raw`.
struct CloudEvent: Equatable, Identifiable, Sendable {
    var id: Int          // SSE cursor (1-based line number across attempts)
    var type: String
    var text: String
    var at: Double?

    /// Parse the JSON in an SSE `data:` line. Never throws: a line we can't read still shows as raw text.
    static func parse(id: Int, line: String) -> CloudEvent {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return CloudEvent(id: id, type: "event", text: String(line.prefix(300)), at: nil)
        }
        let type = (o["type"] as? String) ?? (o["event_type"] as? String) ?? "event"
        var text = ""
        for key in ["message", "text", "summary", "content", "detail", "reason", "output", "tool", "name"] {
            if let s = o[key] as? String, !s.isEmpty { text = s; break }
        }
        if text.isEmpty, let p = o["payload"] as? [String: Any] {
            for key in ["message", "text", "summary", "content", "output", "tool", "name"] {
                if let s = p[key] as? String, !s.isEmpty { text = s; break }
            }
        }
        let at = (o["ts"] as? Double) ?? (o["timestamp"] as? Double) ?? (o["created_at"] as? Double)
        return CloudEvent(id: id, type: type, text: String(text.prefix(400)), at: at)
    }
}

enum CloudError: Error, Equatable, LocalizedError {
    case noToken, http(Int, String), network, bad
    var errorDescription: String? {
        switch self {
        case .noToken: return "No cloud token in the Keychain (io.github.true-terminal.True-factory / streambox)"
        case .http(let s, let m): return m.isEmpty ? "Cloud said \(s)" : m
        case .network: return "Can't reach the cloud factory"
        case .bad: return "Unreadable reply from the cloud factory"
        }
    }
}

protocol CloudTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
    /// Like `send`, but for a live-tailing stream (SSE): returns what arrived within `window` seconds, or when it ends.
    func snapshot(_ request: URLRequest, window: TimeInterval) async throws -> (status: Int, body: Data)
}

extension CloudTransport {
    func snapshot(_ request: URLRequest, window: TimeInterval) async throws -> (status: Int, body: Data) { try await send(request) }
}

private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ b: UInt8) { lock.withLock { data.append(b) } }
    var value: Data { lock.withLock { data } }
}

struct URLSessionCloudTransport: CloudTransport {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, resp) = try await URLSession.shared.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func snapshot(_ request: URLRequest, window: TimeInterval) async throws -> (status: Int, body: Data) {
        let (bytes, resp) = try await URLSession.shared.bytes(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let box = ByteBox()
        let reader = Task { do { for try await b in bytes { box.add(b) } } catch {} }
        let timer = Task { try? await Task.sleep(for: .seconds(window)); reader.cancel() }
        await reader.value
        timer.cancel()
        return (status, box.value)
    }
}

/// Where the factory token lives. Read through `/usr/bin/security` (no access dialog); the value is only trimmed
/// and returned, never logged.
enum CloudToken {
    static let service = "io.github.true-terminal.True-factory"
    static let account = "streambox"
    static func fromKeychain() -> String? {
        guard let data = Subprocess.run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"]) else { return nil }
        let t = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// HTTP client for the true-factory API. The token is fetched per call from `tokenProvider` (Keychain at runtime).
struct CloudClient: Sendable {
    static let defaultBase = URL(string: "http://100.120.234.70:8788")!
    var base: URL = defaultBase
    var transport: CloudTransport = URLSessionCloudTransport()
    var tokenProvider: @Sendable () -> String? = { CloudToken.fromKeychain() }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil) throws -> URLRequest {
        guard let token = tokenProvider(), !token.isEmpty else { throw CloudError.noToken }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    private func call(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil,
                      window: TimeInterval? = nil) async throws -> Data {
        let req = try request(method, path, query: query, json: json)
        let (status, body): (Int, Data)
        do {
            if let window { (status, body) = try await transport.snapshot(req, window: window) }
            else { (status, body) = try await transport.send(req) }
        } catch { throw CloudError.network }
        guard (200..<300).contains(status) else {
            let msg = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String ?? ""
            throw CloudError.http(status, msg)
        }
        return body
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CloudError.bad }
    }

    func health() async throws -> CloudHealth { try decode(CloudHealth.self, try await call("GET", "health")) }
    func jobs() async throws -> [CloudJob] { try decode([CloudJob].self, try await call("GET", "jobs")) }
    func detail(_ id: String) async throws -> CloudJobDetail { try decode(CloudJobDetail.self, try await call("GET", "jobs/\(id)")) }

    /// `base` is a commit sha the sync step just put on the VPS; nil = the VPS clone's HEAD.
    func create(repo: String, job: String, title: String? = nil, base: String? = nil,
                model: String? = nil, effort: String? = nil) async throws -> CloudJob {
        var body: [String: Any] = ["repo": repo, "job": job]
        if let title, !title.isEmpty { body["title"] = title }
        if let base { body["base"] = base }
        if let model, !model.isEmpty { body["model"] = model }
        if let effort, !effort.isEmpty { body["effort"] = effort }
        return try decode(CloudJob.self, try await call("POST", "jobs", json: body))
    }

    func answer(_ id: String, text: String) async throws -> CloudJob {
        try decode(CloudJob.self, try await call("POST", "jobs/\(id)/answer", json: ["text": text]))
    }
    func stop(_ id: String) async throws -> CloudJob { try decode(CloudJob.self, try await call("POST", "jobs/\(id)/stop")) }
    func markViewed(_ id: String) async throws { _ = try await call("POST", "jobs/\(id)/viewed") }
    func diff(_ id: String) async throws -> String { String(decoding: try await call("GET", "jobs/\(id)/diff"), as: UTF8.self) }

    /// The events so far (SSE replayed from `since`; the stream ends itself once the job is terminal). The wire is
    /// `id: N\nevent: factory\ndata: {json}\n\n` blocks; the `end` event is dropped.
    func events(_ id: String, since: Int = 0) async throws -> [CloudEvent] {
        let data = try await call("GET", "jobs/\(id)/events", query: since > 0 ? [URLQueryItem(name: "since", value: String(since))] : [], window: 2.5)
        return Self.parseSSE(String(decoding: data, as: UTF8.self))
    }

    static func parseSSE(_ text: String) -> [CloudEvent] {
        var out: [CloudEvent] = []
        for block in text.components(separatedBy: "\n\n") {
            var cursor: Int?, event = "message", data: [String] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("id:") { cursor = Int(line.dropFirst(3).trimmingCharacters(in: .whitespaces)) }
                else if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                else if line.hasPrefix("data:") { data.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
            }
            guard event == "factory", let cursor, !data.isEmpty else { continue }
            out.append(CloudEvent.parse(id: cursor, line: data.joined(separator: "\n")))
        }
        return out
    }
}
