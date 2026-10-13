import Testing
import Foundation
@testable import True

/// Scripted transport: records requests, answers with a fixed status/body, or throws, or stalls.
final class FakeJev: JevTransport, @unchecked Sendable {
    enum Mode { case reply(Int, Data), fail, stall }
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var mode: Mode
    init(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        lock.withLock { requests.append(request) }
        switch mode {
        case .reply(let s, let d): return (s, d)
        case .fail: throw URLError(.notConnectedToInternet)
        case .stall: try await Task.sleep(for: .seconds(30)); return (200, Data())
        }
    }
}

final class KeyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    func hit() { lock.withLock { calls += 1 } }
}

let jevFixture = Data("""
{"model":"jev-latest","answers":{
 "n":{"type":"noul","noul":0.83},
 "c":{"type":"choice","choice":"opus","confidence":0.91,"probabilities":{"haiku":0.02,"opus":0.91}},
 "s":{"type":"score","score":2.4,"confidence":0.7,"probabilities":{"2":0.6,"3":0.3}}}}
""".utf8)

private let ask: [String: JevQuestion] = ["n": .noul("Is it?")]

@Suite struct JevClientTests {
    private func client(_ t: FakeJev, env: [String: String] = [:], key: String? = "kc-key",
                        counter: KeyCounter = KeyCounter()) -> JevClient {
        JevClient(transport: t, keyProvider: { counter.hit(); return key }, env: env)
    }

    @Test func requestBodyShape() async throws {
        let t = FakeJev(.reply(200, jevFixture))
        let qs: [String: JevQuestion] = [
            "n": .noul("Is it?"),
            "c": .choice("Which?", [(id: "a", what: "alpha"), (id: "b", what: "beta")]),
            "s": .score("How much?", focus: "filler", levels: ["none", "some", "lots"]),
        ]
        _ = await client(t).ask(state: ["file": "x"], questions: qs, timeout: 2)
        let req = try #require(t.requests.first)
        #expect(req.url?.absoluteString == JevClient.endpoint.absoluteString)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer kc-key")
        let bodyData = try #require(req.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(obj["model"] as? String == "jev-latest")
        #expect((obj["state"] as? [String: String]) == ["file": "x"])
        let q = try #require(obj["questions"] as? [String: [String: Any]])
        #expect(q["n"]?["type"] as? String == "noul" && q["n"]?["instructions"] as? String == "Is it?")
        #expect(q["c"]?["type"] as? String == "choice")
        #expect((q["c"]?["criteria"] as? [String: String]) == ["a": "alpha", "b": "beta"])
        #expect(q["s"]?["type"] as? String == "score")
        #expect((q["s"]?["criteria"] as? [String]) == ["none", "some", "lots"])
        let ins = try #require(q["s"]?["instructions"] as? [String: String])
        #expect(ins == ["question": "How much?", "focus": "filler"])
    }

    @Test func decodesEveryAnswerType() async throws {
        let r = try #require(await client(FakeJev(.reply(200, jevFixture))).ask(state: "s", questions: ask, timeout: 2))
        #expect(r.answers["n"]?.noul == 0.83)
        #expect(r.answers["c"]?.choice == "opus" && r.answers["c"]?.confidence == 0.91)
        #expect(r.answers["c"]?.probabilities?["haiku"] == 0.02)
        #expect(r.answers["s"]?.score == 2.4 && r.answers["s"]?.confidence == 0.7)
    }

    @Test func nilOnFailures() async {
        #expect(await client(FakeJev(.reply(500, jevFixture))).ask(state: "s", questions: ask, timeout: 2) == nil)
        #expect(await client(FakeJev(.reply(200, Data("garbage".utf8)))).ask(state: "s", questions: ask, timeout: 2) == nil)
        #expect(await client(FakeJev(.reply(200, Data("{}".utf8)))).ask(state: "s", questions: ask, timeout: 2) == nil)
        #expect(await client(FakeJev(.fail)).ask(state: "s", questions: ask, timeout: 2) == nil)
    }

    @Test func nilOnTimeout() async {
        let start = Date()
        let r = await client(FakeJev(.stall)).ask(state: "s", questions: ask, timeout: 0.2)
        #expect(r == nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func nilWithoutKeyAndNoRequestSent() async {
        let t = FakeJev(.reply(200, jevFixture))
        #expect(await client(t, key: nil).ask(state: "s", questions: ask, timeout: 2) == nil)
        #expect(t.requests.isEmpty)
    }

    @Test func providerCalledOnceAndMissingCached() async {
        let c = KeyCounter(); let t = FakeJev(.reply(200, jevFixture))
        let have = client(t, counter: c)
        for _ in 0..<3 { _ = await have.ask(state: "s", questions: ask, timeout: 2) }
        #expect(c.calls == 1)
        let c2 = KeyCounter()
        let missing = client(t, key: nil, counter: c2)
        for _ in 0..<3 { _ = await missing.ask(state: "s", questions: ask, timeout: 2) }
        #expect(c2.calls == 1)
    }
}
