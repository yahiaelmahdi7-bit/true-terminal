import Foundation

/// One typed question for Jev, a small typed-judgment model: it answers with a probability or a pick,
/// never prose. Build with `.noul`, `.choice` or `.score`.
struct JevQuestion: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case noul
        case choice([(id: String, what: String)])
        case score([String])

        static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) {
            case (.noul, .noul): return true
            case (.choice(let x), .choice(let y)): return x.map(\.id) == y.map(\.id) && x.map(\.what) == y.map(\.what)
            case (.score(let x), .score(let y)): return x == y
            default: return false
            }
        }
    }
    let kind: Kind
    let instructions: String
    /// Optional second line of the instructions object (`{"question","focus"}`).
    var focus: String?

    static func noul(_ instructions: String) -> JevQuestion { .init(kind: .noul, instructions: instructions) }
    static func choice(_ instructions: String, _ options: [(id: String, what: String)]) -> JevQuestion {
        .init(kind: .choice(options), instructions: instructions)
    }
    static func score(_ instructions: String, focus: String? = nil, levels: [String]) -> JevQuestion {
        .init(kind: .score(levels), instructions: instructions, focus: focus)
    }

    var json: [String: Any] {
        var q: [String: Any] = [:]
        if let focus { q["instructions"] = ["question": instructions, "focus": focus] }
        else { q["instructions"] = instructions }
        switch kind {
        case .noul: q["type"] = "noul"
        case .choice(let opts):
            q["type"] = "choice"
            var c: [String: Any] = [:]
            for o in opts { c[o.id] = o.what }
            q["criteria"] = c
        case .score(let levels):
            q["type"] = "score"
            q["criteria"] = levels
        }
        return q
    }
}

/// One typed answer. Only the fields for the question's own type are set.
struct JevAnswer: Sendable, Equatable {
    let type: String
    let choice: String?
    let confidence: Double?
    let probabilities: [String: Double]?
    let noul: Double?
    let score: Double?
}

struct JevReply: Sendable, Equatable {
    let answers: [String: JevAnswer]
}

/// The wire, injectable so tests never touch the network. Returns the HTTP status and body.
protocol JevTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

struct URLSessionJevTransport: JevTransport {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, resp) = try await Self.session.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Where the key comes from. The public build has no key source: judge calls are skipped and every
/// caller uses its plain rules.
enum JevKey {
    static func fromKeychain() -> String? { nil }
}

/// The wire to Jev. Every failure (no key, network, timeout, non-2xx, garbage) returns `nil`, and every
/// caller falls through to what it did before Jev existed. No retries: a late verdict is worthless.
final class JevClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://judge.invalid/v1")!
    static let model = "jev-latest"
    static let shared = JevClient()

    private let transport: JevTransport
    private let keyProvider: @Sendable () -> String?
    private let env: [String: String]
    private let lock = NSLock()
    private var resolved = false
    private var cachedKey: String?

    init(transport: JevTransport = URLSessionJevTransport(),
         keyProvider: @escaping @Sendable () -> String? = JevKey.fromKeychain,
         env: [String: String] = ProcessInfo.processInfo.environment) {
        self.transport = transport; self.keyProvider = keyProvider; self.env = env
    }

    /// Environment first, then the provider, ONCE per client; "missing" is cached too.
    private func key() -> String? {
        lock.withLock {
            if resolved { return cachedKey }
            resolved = true
            if let k = keyProvider(), !k.isEmpty { cachedKey = k }
            return cachedKey
        }
    }

    private func loadKey() async -> String? {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: self.key()) }
        }
    }

    static func body(state: Any, questions: [String: JevQuestion]) -> Data? {
        let obj: [String: Any] = ["model": model, "state": state,
                                  "questions": questions.mapValues(\.json)]
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    static func decode(_ data: Data) -> JevReply? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["answers"] as? [String: Any] else { return nil }
        var answers: [String: JevAnswer] = [:]
        for (id, v) in raw {
            guard let a = v as? [String: Any], let type = a["type"] as? String else { continue }
            answers[id] = JevAnswer(
                type: type,
                choice: a["choice"] as? String,
                confidence: (a["confidence"] as? NSNumber)?.doubleValue,
                probabilities: (a["probabilities"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue },
                noul: (a["noul"] as? NSNumber)?.doubleValue,
                score: (a["score"] as? NSNumber)?.doubleValue)
        }
        return JevReply(answers: answers)
    }

    /// Ask every question about `state` in one call. `state` must be JSON-serialisable.
    func ask(state: Any, questions: [String: JevQuestion], timeout: TimeInterval) async -> JevReply? {
        guard let key = await loadKey(), let body = Self.body(state: state, questions: questions) else { return nil }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let transport = self.transport
        let request = req
        // Race the call against the deadline so a transport that ignores timeoutInterval still returns.
        return await withTaskGroup(of: JevReply?.self) { group in
            group.addTask {
                guard let r = try? await transport.send(request), (200..<300).contains(r.status) else { return nil }
                return Self.decode(r.body)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
