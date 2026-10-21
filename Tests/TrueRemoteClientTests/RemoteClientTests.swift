import Testing
import Foundation
@testable import TrueRemoteClient

final class StubTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(Int, Data, [String: String])]
    private(set) var requests: [URLRequest] = []

    init(_ responses: (Int, String, [String: String])...) {
        queue = responses.map { ($0.0, Data($0.1.utf8), $0.2) }
    }

    private func next(_ req: URLRequest) -> (Int, Data, [String: String]) {
        lock.lock(); defer { lock.unlock() }
        requests.append(req)
        return queue.count > 1 ? queue.removeFirst() : queue[0]
    }

    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, data, headers) = next(req)
        return (data, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

// Lifted from scripts/remote-mock.py hub() (normal state), trimmed to two projects.
let sampleHub = """
{"summary":"1 working · 1 needs you · 1 done","projects":[
 {"title":"true","summary":"1 working · 1 needs you","rows":[
  {"kind":"seat","id":"lead-true","name":"lead-true","status":"Working","statusKey":"working","pane":"11111111-1111-1111-1111-111111111111","cwd":"~/Projects/true","elapsed":"12m"},
  {"kind":"seat","id":"helper-1-true","name":"helper-1-true","status":"Needs you","statusKey":"needsYou","pane":"22222222-2222-2222-2222-222222222222","cwd":"~/Projects/true/Sources","elapsed":"3m"},
  {"kind":"background","id":"builder run-26","name":"builder run-26","status":"Done","statusKey":"done","builderId":"run-26","acked":false,"cwd":"~/Projects/true.builders","elapsed":2460.7,"branch":null}]},
 {"title":"axon","summary":"1 failed","rows":[
  {"kind":"other","id":"zsh in Ghostty","name":"zsh in Ghostty","status":"Working","statusKey":"working","cwd":"~/Projects/axon","elapsed":"1h 2m"}]}]}
"""

private let base = URL(string: "https://mac.tail1234.ts.net:8444")!
private func session(_ t: StubTransport, token: String? = "tok", store: InMemoryTokenStore? = nil) -> (RemoteSession, InMemoryTokenStore) {
    let s = store ?? InMemoryTokenStore(token: token)
    return (RemoteSession(baseURL: base, store: s, transport: t), s)
}

@Suite struct RemoteSessionTests {
    @Test func bearerHeaderAndNoCookie() async throws {
        let t = StubTransport((200, sampleHub, [:]))
        let (s, _) = session(t)
        _ = try await s.hub()
        let req = try #require(t.requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(req.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(req.httpShouldHandleCookies == false)
        #expect(req.url?.absoluteString == "https://mac.tail1234.ts.net:8444/api/hub")
    }

    @Test func postsCarryExactOrigin() async throws {
        let t = StubTransport((200, #"{"ok":true}"#, [:]))
        let (s, _) = session(t)
        try await s.clip(text: "hi")
        #expect(t.requests[0].value(forHTTPHeaderField: "Origin") == "https://mac.tail1234.ts.net:8444")
    }

    @Test func unauthorizedClearsToken() async {
        let t = StubTransport((401, "Not paired", [:]))
        let (s, store) = session(t)
        await #expect(throws: RemoteError.unauthorized) { try await s.hub() }
        #expect(store.load() == nil)
    }

    @Test func routeNotFoundIsExpired() async {
        let t = StubTransport((404, "Route expired", [:]))
        let (s, store) = session(t)
        await #expect(throws: RemoteError.routeExpired) { try await s.setSlot(routeId: "r1", slot: "kind", value: "x") }
        await #expect(throws: RemoteError.routeExpired) { try await s.run(routeId: "r1") }
        #expect(store.load() == "tok")
    }

    @Test func rateLimitParsesRetryAfter() async {
        let t = StubTransport((429, "Slow down", ["Retry-After": "60"]))
        let (s, _) = session(t)
        await #expect(throws: RemoteError.rateLimited(retryAfter: 60)) { try await s.route(text: "hi") }
    }

    @Test func forbiddenAndOtherStatuses() async {
        let (s, _) = session(StubTransport((403, "Forbidden", [:])))
        await #expect(throws: RemoteError.refused) { try await s.recent() }
        let (s2, _) = session(StubTransport((500, "", [:])))
        await #expect(throws: RemoteError.http(500)) { try await s2.recent() }
    }

    @Test func runConfirmIsNotAnError() async throws {
        let t = StubTransport((409, #"{"needsConfirm":true,"reason":"dangerous_text"}"#, [:]))
        let (s, _) = session(t)
        let r = try await s.run(routeId: "r1", background: false, confirmed: false)
        #expect(r.needsConfirm == true && r.reason == "dangerous_text")
        let body = try #require(t.requests[0].httpBody)
        let o = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(o["routeId"] as? String == "r1" && o["confirm"] as? Bool == false)
    }

    @Test func pairStoresToken() async throws {
        let t = StubTransport((200, #"{"token":"abc123"}"#, [:]))
        let (s, store) = session(t, token: nil)
        try await s.pair(code: " 123456 ")
        #expect(store.load() == "abc123")
        #expect(t.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(String(decoding: t.requests[0].httpBody ?? Data(), as: UTF8.self).contains("123456"))
    }

    @Test func pairWrongCodeKeepsStoreEmpty() async {
        let t = StubTransport((401, #"{"error":"That code didn't work."}"#, [:]))
        let (s, store) = session(t, token: nil)
        await #expect(throws: RemoteError.pairingFailed("That code didn't work.")) { try await s.pair(code: "000000") }
        #expect(store.load() == nil)
    }

    @Test func unpairedRequestThrowsWithoutNetwork() async {
        let t = StubTransport((200, "{}", [:]))
        let (s, _) = session(t, token: nil)
        await #expect(throws: RemoteError.unauthorized) { try await s.hub() }
        #expect(t.requests.isEmpty)
    }
}

@Suite struct RemoteModelTests {
    @Test func hubSnapshotDecodesMockPayload() throws {
        let h = try JSONDecoder().decode(HubSnapshot.self, from: Data(sampleHub.utf8))
        #expect(h.projects.count == 2 && h.projects[0].rows.count == 3)
        #expect(h.projects[0].rows[1].statusKey == "needsYou")
        #expect(h.projects[0].rows[2].builderId == "run-26" && h.projects[0].rows[2].branch == nil)
        #expect(h.needsYouIDs == ["helper-1-true"])
    }

    /// The Mac sends builders `elapsed` in seconds and seats a label; a number must never fail the whole snapshot
    /// (that read as "Mac asleep or offline" on the phone, Run 30).
    @Test func hubRowDecodesQuestionFieldsWhenPresent() throws {
        let json = #"{"kind":"seat","id":"seat-a","name":"a","status":"Needs you","statusKey":"needsYou","pane":"P","question":"Run it?","tool":"Bash","detail":"ls"}"#
        let row = try JSONDecoder().decode(HubRow.self, from: Data(json.utf8))
        #expect(row.question == "Run it?" && row.tool == "Bash" && row.detail == "ls")
        let bare = #"{"kind":"seat","id":"seat-b","name":"b"}"#
        let old = try JSONDecoder().decode(HubRow.self, from: Data(bare.utf8))
        #expect(old.question == nil && old.tool == nil && old.detail == nil && old.needKind == nil)
        let q = try JSONDecoder().decode(HubRow.self, from: Data(#"{"kind":"pane","id":"p","name":"n","needKind":"question"}"#.utf8))
        #expect(q.needKind == "question" && NeedsYouNotifier.isQuestion(q) && NeedsYouNotifier.title(for: q) == "n has a question")
        #expect(!NeedsYouNotifier.isQuestion(old) && NeedsYouNotifier.title(for: old) == "b needs you")
    }

    @Test func hubElapsedDecodesSecondsOrText() throws {
        let h = try JSONDecoder().decode(HubSnapshot.self, from: Data(sampleHub.utf8))
        let rows = h.projects.flatMap(\.rows)
        #expect(rows.first { $0.kind == "background" }?.elapsed == "41m")
        #expect(rows.first { $0.id == "lead-true" }?.elapsed == "12m")
        #expect(HubRow.elapsedLabel(41) == "41s")
        #expect(HubRow.elapsedLabel(3720) == "1h 2m")
        let bare = #"{"projects":[{"title":"t","rows":[{"kind":"seat","id":"a","name":"a","status":"","statusKey":"idle"}]}]}"#
        #expect(try JSONDecoder().decode(HubSnapshot.self, from: Data(bare.utf8)).projects[0].rows[0].elapsed == nil)
    }

    @Test func routeResponseDecodesWhereKey() throws {
        let json = #"{"routeId":"r0","route":{"text":"t","kind":"agentTask","kindLabel":"Claude task","project":"true","target":"newPane","where":"New pane","model":"opus","effort":"high","uncertain":["project"],"twoChoice":false,"dangerous":false,"typedOnly":false,"runnable":true},"alternatives":["shellCommand"],"candidates":{"kind":[{"value":"agentTask","label":"Claude task"}]}}"#
        let r = try JSONDecoder().decode(RouteResponse.self, from: Data(json.utf8))
        #expect(r.route.whereLabel == "New pane" && r.uncertain == ["project"] && r.runnable && !r.dangerous)
        #expect(r.candidates["kind"]?.first?.label == "Claude task")
    }
}

@Suite struct HubPollerTests {
    private func snap(_ ids: [String]) -> HubSnapshot {
        let rows = ids.map { HubRow(kind: "seat", id: $0, name: $0, status: "Needs you", statusKey: "needsYou") }
        let d = try! JSONEncoder().encode(rows)
        let json = "{\"projects\":[{\"title\":\"p\",\"rows\":" + String(decoding: d, as: UTF8.self) + "}]}"
        return try! JSONDecoder().decode(HubSnapshot.self, from: Data(json.utf8))
    }

    @Test func needsYouRoseTrueOnNewAsk() {
        #expect(HubPoller.needsYouRose(from: snap(["a"]), to: snap(["a", "b"])))
        #expect(HubPoller.needsYouRose(from: snap(["a"]), to: snap(["b"])))
    }

    @Test func needsYouRoseFalseWhenSameFewerOrFirst() {
        #expect(!HubPoller.needsYouRose(from: snap(["a"]), to: snap(["a"])))
        #expect(!HubPoller.needsYouRose(from: snap(["a", "b"]), to: snap(["a"])))
        #expect(!HubPoller.needsYouRose(from: nil, to: snap(["a"])))
    }

    @Test func backoffDoublesToCap() {
        var d: Duration? = nil
        var seen: [Duration] = []
        for _ in 0..<6 { d = HubPoller.nextBackoff(after: d); seen.append(d!) }
        #expect(seen == [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    }
}

@Suite struct PaneInputTests {
    @Test func encodesRequestAndDecodesOutcome() async throws {
        let t = StubTransport((200, #"{"outcome":"landed"}"#, [:]))
        let (s, _) = session(t)
        let o = try await s.paneInput(id: "ABC", intent: .prompt, text: "hi \"there\"\nline2")
        #expect(o == .landed)
        let req = try #require(t.requests.first)
        #expect(req.httpMethod == "POST" && req.url?.path == "/api/pane/ABC/input")
        #expect(req.value(forHTTPHeaderField: "Origin") == "https://mac.tail1234.ts.net:8444")
        let body = try JSONSerialization.jsonObject(with: try #require(req.httpBody)) as? [String: String]
        #expect(body == ["intent": "prompt", "text": "hi \"there\"\nline2"])
    }

    @Test func unknownOutcomeIsTolerated() async throws {
        let (s, _) = session(StubTransport((200, #"{"outcome":"teleported"}"#, [:])))
        #expect(try await s.paneInput(id: "A", intent: .approve) == .unknown("teleported"))
        let (s2, _) = session(StubTransport((200, "{}", [:])))
        #expect(try await s2.paneInput(id: "A", intent: .deny) == .unknown(""))
        for (w, o) in [("stuckInComposer", InputOutcome.stuckInComposer), ("promptGone", .promptGone), ("unverified", .unverified)] {
            #expect(InputOutcome(wire: w) == o)
        }
    }

    @Test func notFoundMapsToPaneGone() async throws {
        let (s, _) = session(StubTransport((404, #"{"error":"No such pane"}"#, [:])))
        await #expect(throws: RemoteError.paneGone) { try await s.paneInput(id: "A", intent: .prompt, text: "x") }
    }

    @Test func paneDecodesWithAndWithoutClaude() throws {
        let base = #"{"id":"1","title":"t","cwd":"/","agent":null,"needsYou":false,"busy":false,"live":true"#
        let old = try JSONDecoder().decode(RemotePane.self, from: Data((base + "}").utf8))
        #expect(old.claude == false)
        let new = try JSONDecoder().decode(RemotePane.self, from: Data((base + #","claude":true}"#).utf8))
        #expect(new.claude)
    }

    @Test func paneDecodesIdentityWithAndWithoutKeys() throws {
        let base = #"{"id":"1","title":"t","cwd":"/","agent":null,"needsYou":false,"busy":false,"live":true"#
        let old = try JSONDecoder().decode(RemotePane.self, from: Data((base + "}").utf8))
        #expect(old.repo == nil && old.branch == nil && old.sessionID == nil && old.topic == nil && !old.worktree)
        let new = try JSONDecoder().decode(RemotePane.self, from: Data((base + #","repo":"true","branch":"dev","worktree":true,"sessionID":"S","topic":"Fix it"}"#).utf8))
        #expect(new.repo == "true" && new.branch == "dev" && new.worktree && new.sessionID == "S" && new.topic == "Fix it")
    }
}

@Suite struct ComposerReactionTests {
    @Test func outcomesMapToPhoneBehaviour() {
        #expect(InputOutcome.landed.reaction(for: .prompt) == .nothing)
        #expect(InputOutcome.unverified.reaction(for: .prompt) == .toast("Sent"))
        #expect(InputOutcome.unverified.reaction(for: .submitOnly) == .nothing)
        #expect(InputOutcome.stuckInComposer.reaction(for: .prompt) == .restore(toast: "Didn't go through — try again or use Keys"))
        #expect(InputOutcome.noPane.reaction(for: .prompt) == .popPane(toast: "Pane is gone"))
        #expect(InputOutcome.promptGone.reaction(for: .approve) == .toast("No prompt on screen"))
        #expect(InputOutcome.unknown("x").reaction(for: .prompt) == .toast("Sent"))
    }
}

@Suite struct ScreenshotPlanTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func plansNewerUnseenOldestFirst() {
        let assets = [("c", t0.addingTimeInterval(30)), ("a", t0.addingTimeInterval(10)), ("old", t0.addingTimeInterval(-5)), ("b", t0.addingTimeInterval(20))]
        #expect(ScreenshotPlan.plan(assets: assets, lastSynced: t0, seen: ["b"]) == ["a", "c"])
    }

    @Test func nothingBeforeArmedOrAtBoundary() {
        #expect(ScreenshotPlan.plan(assets: [("a", t0)], lastSynced: nil, seen: []).isEmpty)
        #expect(ScreenshotPlan.plan(assets: [("a", t0)], lastSynced: t0, seen: []).isEmpty)
    }

    @Test func filenameIsStable() {
        let utc = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 1_791_642_325) // 2026-10-10 14:25:25 UTC
        #expect(ScreenshotPlan.filename(created: d, ext: "png", timeZone: utc) == "Screenshot-20261010-142525.png")
    }

    @Test func sniffsFormats() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])
        let heic = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        #expect(ScreenshotPlan.format(of: png) == .png)
        #expect(ScreenshotPlan.format(of: jpg) == .jpeg)
        #expect(!ScreenshotPlan.needsJPEGConversion(png) && !ScreenshotPlan.needsJPEGConversion(jpg))
        #expect(ScreenshotPlan.needsJPEGConversion(heic) && ScreenshotPlan.needsJPEGConversion(Data()))
    }
}

@Suite struct AttachmentTests {
    @Test func attachEncodedOnlyWhenPresent() async throws {
        let t = StubTransport((200, #"{"outcome":"landed"}"#, [:]), (200, #"{"outcome":"landed"}"#, [:]))
        let (s, _) = session(t)
        _ = try await s.paneInput(id: "A", intent: .prompt, text: "x", attachments: [.shot(id: "s1"), .file(name: "a b.pdf")])
        let b1 = try JSONSerialization.jsonObject(with: try #require(t.requests[0].httpBody)) as? [String: Any]
        let attach = try #require(b1?["attach"] as? [[String: String]])
        #expect(attach == [["id": "s1"], ["name": "a b.pdf"]])
        _ = try await s.paneInput(id: "A", intent: .prompt, text: "x")
        let b2 = try JSONSerialization.jsonObject(with: try #require(t.requests[1].httpBody)) as? [String: String]
        #expect(b2 == ["intent": "prompt", "text": "x"])
    }

    @Test func refFromDrop() {
        #expect(PaneAttachmentRef(drop: DropResponse(ok: true, where: "shots", id: "i", name: nil)) == .shot(id: "i"))
        #expect(PaneAttachmentRef(drop: DropResponse(ok: true, where: "downloads", id: nil, name: "n")) == .file(name: "n"))
        #expect(PaneAttachmentRef(drop: DropResponse(ok: true, where: "x", id: "i", name: "n")) == nil)
        #expect(PaneAttachmentRef(drop: DropResponse(ok: true, where: "shots", id: nil, name: nil)) == nil)
    }

    @Test func canSendRules() {
        #expect(!AttachmentPlan.canSend(text: "  ", attachments: []))
        #expect(AttachmentPlan.canSend(text: "hi", attachments: []))
        #expect(AttachmentPlan.canSend(text: "", attachments: [.ready, .failed]))
        #expect(!AttachmentPlan.canSend(text: "hi", attachments: [.ready, .uploading]))
        #expect(!AttachmentPlan.canSend(text: "", attachments: [.failed]))
    }

    @Test func filenamesAndCaps() {
        let utc = TimeZone(identifier: "UTC")!
        let d = Date(timeIntervalSince1970: 1_791_642_330)
        let stamp = AttachmentPlan.filename(for: .camera(index: 1), now: d, timeZone: utc)
        #expect(stamp.hasPrefix("Camera-") && stamp.hasSuffix("-1.jpg"))
        #expect(AttachmentPlan.filename(for: .photo(ext: "HEIC", index: 2), now: d, timeZone: utc).hasSuffix("-2.jpg"))
        #expect(AttachmentPlan.filename(for: .photo(ext: "png", index: 1), now: d, timeZone: utc).hasSuffix("-1.png"))
        #expect(AttachmentPlan.filename(for: .photo(ext: "mov", index: 1), now: d, timeZone: utc).hasSuffix("-1.mov"))
        #expect(AttachmentPlan.filename(for: .file(name: "Report.pdf"), now: d) == "Report.pdf")
        #expect(AttachmentPlan.room(current: 3) == 5 && AttachmentPlan.room(current: 9) == 0)
        #expect(AttachmentPlan.withinCap(bytes: 200_000_000) && !AttachmentPlan.withinCap(bytes: 200_000_001))
    }
}

@Suite struct NeedsYouNotifierTests {
    func row(_ id: String, _ key: String, pane: String? = "P", question: String? = nil, tool: String? = nil, detail: String? = nil) -> HubRow {
        HubRow(kind: "seat", id: id, name: id, status: key == "idle" ? "Idle" : "x", statusKey: key, pane: pane,
               question: question, tool: tool, detail: detail)
    }
    func snap(_ rows: [HubRow]) -> HubSnapshot {
        let json = try! JSONEncoder().encode(rows)
        let data = Data(#"{"projects":[{"title":"p","rows":"#.utf8) + json + Data("}]}".utf8)
        return try! JSONDecoder().decode(HubSnapshot.self, from: data)
    }

    @Test func planFiresNewAndClearsResolved() {
        let s = snap([row("a", "needsYou"), row("b", "needsYou"), row("c", "working")])
        let p = NeedsYouNotifier.plan(old: ["b", "gone"], new: s)
        #expect(p.fire.map(\.id) == ["a"])
        #expect(p.clear == ["gone"])
        #expect(NeedsYouNotifier.plan(old: s.needsYouIDs, new: s).fire.isEmpty)
    }

    @Test func doneFiresOnceOnWorkingToIdle() {
        let before = snap([row("a", "working"), row("b", "working"), row("c", "working"), row("d", "working", pane: nil)])
        let after = snap([row("a", "idle"), row("b", "needsYou"), row("c", "failed"), row("d", "idle", pane: nil)])
        let oldWorking = NeedsYouNotifier.workingIDs(before)
        #expect(NeedsYouNotifier.donePlan(oldWorking: oldWorking, new: after).map(\.id) == ["a"])
        #expect(NeedsYouNotifier.donePlan(oldWorking: NeedsYouNotifier.workingIDs(after), new: after).isEmpty)
    }

    @Test func bodyUsesQuestionThenToolDetail() {
        #expect(NeedsYouNotifier.body(for: row("a", "needsYou", question: "Run it?", tool: "Bash", detail: "ls")) == "Run it?\nBash: ls")
        #expect(NeedsYouNotifier.body(for: row("a", "needsYou", question: "Run it?")) == "Run it?")
        #expect(NeedsYouNotifier.body(for: row("a", "needsYou")) == "Tap to open")
    }

    @Test func answersMapToIntentsAndTrimReplies() {
        #expect(LockScreenAnswer.approve.intent == .approve && LockScreenAnswer.deny.intent == .deny)
        #expect(LockScreenAnswer.reply(trimming: "  hi \n") == .reply("hi"))
        #expect(LockScreenAnswer.reply(trimming: "  \n") == nil)
        #expect(LockScreenAnswer.followUp(for: .promptGone) == "That prompt is gone")
        #expect(LockScreenAnswer.followUp(for: .landed) == nil)
    }
}

@Suite struct PanePickerTests {
    private func row(_ id: String, pane: String?, key: String = "working") -> HubRow {
        HubRow(kind: "seat", id: id, name: id, status: key, statusKey: key, pane: pane)
    }

    @Test func lastOpenedPaneComesFirst() {
        let rows = [row("a", pane: "pa", key: "needsYou"), row("b", pane: "pb"), row("c", pane: "pc")]
        #expect(PanePicker.order(rows: rows, lastPaneId: "pc").map(\.id) == ["c", "a", "b"])
    }

    @Test func needsYouBeforeWorking() {
        let rows = [row("a", pane: "pa"), row("b", pane: "pb", key: "needsYou"), row("c", pane: "pc")]
        #expect(PanePicker.order(rows: rows, lastPaneId: nil).map(\.id) == ["b", "a", "c"])
    }

    @Test func rowsWithoutPaneAreDropped() {
        let rows = [row("a", pane: nil), row("b", pane: "pb")]
        #expect(PanePicker.order(rows: rows, lastPaneId: nil).map(\.id) == ["b"])
    }
}

@Suite struct NeedsAttentionTests {
    private func row(_ key: String, acked: Bool? = nil) -> HubRow {
        HubRow(kind: "background", id: key, name: "b", status: key, statusKey: key, acked: acked)
    }
    @Test func askingPaneAndUnackedFailureNeedYou() {
        #expect(row("needsYou").needsAttention)
        #expect(row("failed").needsAttention)
        #expect(row("failed", acked: false).needsAttention)
    }
    @Test func ackedFailureAndWorkingDoNot() {
        #expect(!row("failed", acked: true).needsAttention)
        #expect(!row("working").needsAttention)
        #expect(!row("done", acked: false).needsAttention)
    }
}
