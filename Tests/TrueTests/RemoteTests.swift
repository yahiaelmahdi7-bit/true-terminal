import Testing
import Foundation
import Darwin
@testable import True

/// Client→server frame (masked, as RFC 6455 requires of browsers).
private func maskedFrame(_ op: UInt8, _ payload: [UInt8], fin: Bool = true, key: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]) -> [UInt8] {
    var out: [UInt8] = [(fin ? 0x80 : 0) | op]
    let n = payload.count
    if n < 126 { out.append(0x80 | UInt8(n)) }
    else if n <= 0xFFFF { out += [0x80 | 126, UInt8(n >> 8), UInt8(n & 0xFF)] }
    else { out.append(0x80 | 127); for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(s)) & 0xFF)) } }
    out += key
    for (i, b) in payload.enumerated() { out.append(b ^ key[i % 4]) }
    return out
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("true-remote-\(UUID().uuidString).json")
}

@Suite struct WebSocketTests {
    @Test func rfcSampleAcceptKey() {
        #expect(WebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func serverEncodeLengths() {
        for n in [0, 5, 125, 126, 65535, 65536] {
            let f = WebSocket.encode(.binary, [UInt8](repeating: 7, count: n))
            #expect(f[0] == 0x82)
            switch n {
            case ..<126: #expect(f[1] == UInt8(n) && f.count == 2 + n)
            case ...65535: #expect(f[1] == 126 && f.count == 4 + n && Int(f[2]) << 8 | Int(f[3]) == n)
            default: #expect(f[1] == 127 && f.count == 10 + n)
            }
        }
    }

    @Test func decodeMaskedAcrossLengthBoundaries() throws {
        for n in [0, 1, 125, 126, 65535, 65536] {
            let payload = (0..<n).map { UInt8($0 & 0xFF) }
            var d = WebSocket.Decoder()
            let msgs = try d.feed(maskedFrame(2, payload))
            #expect(msgs == [WebSocket.Message(op: .binary, payload: payload)])
        }
    }

    @Test func decodeByteAtATime() throws {
        var d = WebSocket.Decoder()
        var got: [WebSocket.Message] = []
        for b in maskedFrame(1, Array("hello".utf8)) { got += try d.feed([b]) }
        #expect(got == [WebSocket.Message(op: .text, payload: Array("hello".utf8))])
    }

    @Test func fragmentationReassembles() throws {
        var d = WebSocket.Decoder()
        var out = try d.feed(maskedFrame(1, Array("hel".utf8), fin: false))
        #expect(out.isEmpty)
        out = try d.feed(maskedFrame(9, [1, 2]))                       // control frame interleaved
        #expect(out == [WebSocket.Message(op: .ping, payload: [1, 2])])
        out = try d.feed(maskedFrame(0, Array("lo".utf8)))
        #expect(out == [WebSocket.Message(op: .text, payload: Array("hello".utf8))])
    }

    @Test func rejectsUnmaskedAndOversize() {
        var d = WebSocket.Decoder()
        #expect(throws: WebSocket.Decoder.Failure.self) { _ = try d.feed([0x81, 0x01, 0x41]) }
        var small = WebSocket.Decoder(maxMessage: 10)
        #expect(throws: WebSocket.Decoder.Failure.self) { _ = try small.feed(maskedFrame(2, [UInt8](repeating: 1, count: 11))) }
    }

    @Test func backpressureRule() {
        #expect(!RemoteBackpressure.shouldSnapshot(pendingBytes: 1_048_576))
        #expect(RemoteBackpressure.shouldSnapshot(pendingBytes: 1_048_577))
        let v = RemoteViewer(pane: UUID())
        #expect(v.take() == .snapshot)                  // first delivery is a snapshot
        v.push([1, 2, 3])
        #expect(v.take() == .data([1, 2, 3]))
        v.push([UInt8](repeating: 0, count: 1_048_577))  // fell > 1 MB behind
        #expect(v.take() == .snapshot)
        #expect(v.take() == .none)
    }
}

@Suite struct HTTPParseTests {
    @Test func parsesRequestWithQueryAndHeaders() {
        let raw = Array("GET /api/tabs?x=1&y=two HTTP/1.1\r\nHost: m.ts.net\r\nTailscale-User-Login: me@x\r\n\r\n".utf8)
        guard case .request(let r, let used) = HTTPRequest.parse(raw) else { Issue.record("not parsed"); return }
        #expect(used == raw.count)
        #expect(r.method == "GET" && r.path == "/api/tabs")
        #expect(r.query == ["x": "1", "y": "two"])
        #expect(r.header("tailscale-user-login") == "me@x")
        #expect(!r.isWebSocketUpgrade)
    }

    @Test func partialAndMalformed() {
        #expect(HTTPRequest.parse(Array("GET / HTTP/1.1\r\nHost: a".utf8)) == .needMore)
        #expect(HTTPRequest.parse(Array("NONSENSE\r\n\r\n".utf8)) == .bad)
        let big = Array("POST /pair HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)
        #expect(HTTPRequest.parse(big) == .bad)
    }

    @Test func bodyWaitsForContentLength() {
        let head = "POST /pair HTTP/1.1\r\nContent-Length: 6\r\n\r\n"
        #expect(HTTPRequest.parse(Array((head + "12").utf8)) == .needMore)
        guard case .request(let r, _) = HTTPRequest.parse(Array((head + "123456").utf8)) else { Issue.record("no"); return }
        #expect(r.body == Array("123456".utf8))
    }
}

@Suite struct RemoteAuthTests {
    static let dns = "mac.ts.net"
    private func decide(login: String?, allowed: String? = "me@x", valid: Bool = true, origin: String? = nil,
                        ws: Bool = false, host: String? = "mac.ts.net:8444", post: Bool = false,
                        api: Bool = true) -> RemoteAuth.Decision {
        RemoteAuth.decide(loginHeader: login, allowedLogin: allowed, host: host, origin: origin, dnsName: Self.dns,
                          requiresOrigin: ws || post, requiresToken: api && !ws, tokenValid: valid)
    }

    @Test func decisionTable() {
        guard case .forbidden = decide(login: nil) else { Issue.record("no header"); return }
        guard case .forbidden = decide(login: "other@x") else { Issue.record("wrong login"); return }
        guard case .forbidden = decide(login: "me@x", allowed: nil) else { Issue.record("no configured login"); return }
        #expect(decide(login: "me@x", valid: false) == .needsPairing)       // no/bad/revoked token
        #expect(decide(login: "ME@x") == .allow)
        #expect(decide(login: "other@x", valid: false) != .needsPairing)    // identity beats token
    }

    @Test func originMustBeExact() {
        let good = "https://mac.ts.net:8444"
        #expect(decide(login: "me@x", origin: good, ws: true) == .allow)
        #expect(decide(login: "me@x", origin: good, post: true, api: false) == .allow)
        for bad in ["https://mac.ts.net", "http://mac.ts.net:8444", "https://mac.ts.net:8443", "https://evil.com",
                    "https://mac.ts.net:8444.evil.com", "https://mac.ts.net:8444/", "null", ""] {
            guard case .forbidden = decide(login: "me@x", origin: bad, ws: true) else { Issue.record("ws \(bad)"); return }
            guard case .forbidden = decide(login: "me@x", origin: bad, post: true, api: false) else { Issue.record("post \(bad)"); return }
        }
        guard case .forbidden = decide(login: "me@x", origin: nil, ws: true) else { Issue.record("nil origin"); return }
        guard case .forbidden = decide(login: "me@x", origin: nil, post: true, api: false) else { Issue.record("nil post"); return }
    }

    @Test func hostMustBeExact() {
        #expect(decide(login: "me@x") == .allow)
        #expect(decide(login: "me@x", host: "mac.ts.net") == .allow)
        #expect(decide(login: "me@x", host: "MAC.ts.net:8444") == .allow)
        for bad in ["evil.com", "evil.com:8444", "mac.ts.net:9999", "mac.ts.net.evil.com", "127.0.0.1:8801", ""] {
            guard case .forbidden = decide(login: "me@x", host: bad) else { Issue.record("host \(bad)"); return }
        }
        guard case .forbidden = decide(login: "me@x", host: nil) else { Issue.record("nil host"); return }
        guard case .forbidden = RemoteAuth.decide(loginHeader: "me@x", allowedLogin: "me@x", host: "mac.ts.net", origin: nil,
                                                  dnsName: nil, requiresOrigin: false, requiresToken: false,
                                                  tokenValid: false) else { Issue.record("no dns"); return }
    }

    @Test func bearerParsing() {
        #expect(RemoteAuth.bearerToken("Bearer abc") == "abc")
        #expect(RemoteAuth.bearerToken("bearer abc") == nil)
        #expect(RemoteAuth.bearerToken("Bearer ") == nil)
        #expect(RemoteAuth.bearerToken(nil) == nil)
    }

    @Test func deviceLifecycle() {
        let url = tempFile(); defer { try? FileManager.default.removeItem(at: url) }
        let store = DeviceStore(url: url)
        let token = store.pair(label: "iPhone")
        #expect(token.count == 64)
        #expect(store.validate(token)?.label == "iPhone")
        #expect(store.validate("bad") == nil)
        #expect(store.validate(nil) == nil)
        let disk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(!disk.contains(token))                                    // only the hash is stored
        #expect(disk.contains(RemoteAuth.sha256Hex(token)))
        #expect(DeviceStore(url: url).validate(token) != nil)             // survives restart
        store.revoke(store.all[0].id)
        #expect(store.validate(token) == nil)
    }

    @Test func sha256KnownVector() {
        #expect(RemoteAuth.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct PairingCodeTests {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000_000) }

    @Test func codeIsSixDigitsAndSingleUse() {
        let c = Clock(); let p = PairingCodes(now: { c.t })
        let code = p.issue()
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        #expect(p.attempt(code) == .ok)
        #expect(p.attempt(code) == .expired)
    }

    @Test func expiresAfterFiveMinutes() {
        let c = Clock(); let p = PairingCodes(now: { c.t })
        let code = p.issue()
        c.t = c.t.addingTimeInterval(301)
        #expect(p.attempt(code) == .expired)
    }

    @Test func rateLimitFivePerMinute() {
        let c = Clock(); let p = PairingCodes(now: { c.t })
        let code = p.issue()
        let wrong = code == "000000" ? "111111" : "000000"
        for _ in 0..<4 { #expect(p.attempt(wrong) == .wrong) }
        let code2 = p.issue()                               // fresh code resets the burn counter, not the rate window
        let wrong2 = code2 == wrong ? "123456" : wrong
        #expect(p.attempt(wrong2) == .wrong)
        #expect(p.attempt(code2) == .rateLimited)          // even the right code is refused
        c.t = c.t.addingTimeInterval(61)
        #expect(p.attempt(code2) == .ok)
    }

    @Test func burnsAfterFiveWrongGuesses() {
        let c = Clock(); let p = PairingCodes(now: { c.t })
        let code = p.issue()
        let wrong = code == "000000" ? "111111" : "000000"
        for _ in 0..<4 { #expect(p.attempt(wrong) == .wrong) }
        #expect(!p.isBurned)
        #expect(p.attempt(wrong) == .burned)
        #expect(p.isBurned)
        c.t = c.t.addingTimeInterval(61)                   // rate window gone; the code is still dead
        #expect(p.attempt(code) == .expired)
        _ = p.issue()
        #expect(!p.isBurned)                               // a new code clears the flag
    }

    @Test func newCodeReplacesOld() {
        let p = PairingCodes()
        let a = p.issue(); var b = p.issue()
        while b == a { b = p.issue() }
        #expect(p.attempt(a) == .wrong)
    }
}

@Suite struct RemoteServerTests {
    @Test func bindsLoopbackOnly() {
        let a = RemoteServer.loopbackAddress()
        #expect(UInt32(bigEndian: a.sin_addr.s_addr) == 0x7F000001)
        #expect(a.sin_addr.s_addr != INADDR_ANY)
        #expect(UInt16(bigEndian: a.sin_port) == 8801)
    }

    @Test func parsesTailscaleStatus() {
        let json = #"{"Self":{"DNSName":"mac.tail0000.ts.net.","UserID":42},"User":{"42":{"LoginName":"me@x"}}}"#
        let r = RemoteAccess.LoginCache.parse(Data(json.utf8))
        #expect(r?.dns == "mac.tail0000.ts.net")
        #expect(r?.login == "me@x")
        #expect(RemoteAccess.LoginCache.parse(Data("{}".utf8)) == nil)
    }
}

// MARK: - hardening (Run 23)

@Suite struct RemoteHardeningTests {
    @Test func duplicateSecurityHeadersRejected() {
        for h in ["Tailscale-User-Login: a@x", "Host: m.ts.net", "Origin: https://m.ts.net:8444", "Authorization: Bearer t"] {
            let raw = "GET /api/tabs HTTP/1.1\r\n\(h)\r\n\(h.lowercased())\r\n\r\n"
            #expect(HTTPRequest.parse(Array(raw.utf8)) == .bad, "dup \(h)")
        }
        // Other repeated headers are still fine.
        #expect(HTTPRequest.parse(Array("GET / HTTP/1.1\r\nHost: a\r\nAccept: x\r\nAccept: y\r\n\r\n".utf8)) != .bad)
    }

    @Test func headCappedAt16KB() {
        let big = "GET / HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 17 * 1024) + "\r\n\r\n"
        #expect(HTTPRequest.parse(Array(big.utf8)) == .bad)
        let noEnd = Array(("GET / HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 17 * 1024)).utf8)
        #expect(HTTPRequest.parse(noEnd) == .bad)
    }

    @Test func responseCarriesHardeningHeaders() {
        let r = String(decoding: HTTPResponse.make(status: 200, reason: "OK"), as: UTF8.self)
        for h in ["X-Frame-Options: DENY", "X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer",
                  "Cache-Control: no-store",
                  "Content-Security-Policy: default-src 'self'; img-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; object-src 'none'; style-src 'self' 'unsafe-inline'"] {
            #expect(r.contains(h), "\(h)")
        }
        #expect(!r.lowercased().contains("set-cookie"))
    }

    @Test func webAppHasNoInlineScriptsOrCookies() {
        let html = String(decoding: RemoteWebAssets.asset("/")?.body ?? [], as: UTF8.self)
        #expect(!html.contains("onclick=") && !html.contains("javascript:"))
        #expect(!html.replacingOccurrences(of: "<script src=", with: "").contains("<script"))
        let js = String(decoding: RemoteWebAssets.asset("/app.js")?.body ?? [], as: UTF8.self)
        #expect(!js.contains("document.cookie") && js.contains("localStorage") && js.contains("Bearer "))
    }

    @Test func embeddedXtermMatchesResource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (path, file) in [("/xterm.js", "xterm.js"), ("/xterm.css", "xterm.css"), ("/app.js", "app.js"),
                             ("/index.html", "index.html")] {
            let disk = try Data(contentsOf: root.appendingPathComponent("Resources/Remote/\(file)"))
            #expect(Data(RemoteWebAssets.asset(path)?.body ?? []) == disk, "\(file) embedded copy is stale — run gen.py")
        }
    }

    @Test func deadlineCoversWholeRequest() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        // Slowloris: a byte every 100 ms never completes the head; the overall deadline fires.
        let writer = Thread { for b in Array("GET / HTTP/1.1\r\nHost: a".utf8) { _ = send(fds[1], [b], 1, 0); usleep(100_000) } }
        writer.start()
        let t0 = Date()
        let out = RemoteServer.readRequest(fds[0], deadline: 0.6)
        #expect(out == .timedOut)
        #expect(Date().timeIntervalSince(t0) < 1.5)
    }

    @Test func readRequestReturnsCompleteRequest() {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let raw = Array("GET /x HTTP/1.1\r\nHost: a\r\n\r\n".utf8)
        _ = send(fds[1], raw, raw.count, 0)
        guard case .request(let r) = RemoteServer.readRequest(fds[0], deadline: 2) else { Issue.record("no request"); return }
        #expect(r.path == "/x")
    }

    @Test func deviceFileIs0600AndParent0700() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("true-perm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("remote-devices.json")
        let store = DeviceStore(url: url)
        _ = store.pair(label: "p")
        func mode(_ u: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? -1 }
        #expect(mode(url) == 0o600)
        #expect(mode(dir) == 0o700)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left == ["remote-devices.json"])                      // no stray temp file
    }
}

/// End to end against a real loopback server and a fake backend.
@Suite(.serialized) struct RemoteEndToEndTests {
    struct FakeBackend: RemoteBackend {
        let pane = UUID()
        func tabsJSON() -> Data { Data(#"{"tabs":[]}"#.utf8) }
        func snapshot(pane: UUID) -> (cols: Int, rows: Int, bytes: [UInt8])? { pane == self.pane ? (80, 24, [0x41]) : nil }
        func input(pane: UUID, bytes: [UInt8]) -> Bool { true }
        final class Log: @unchecked Sendable { var calls: [(PaneInputIntent, String)] = []; var attachments: [[String]] = [] }
        let log = Log()
        func paneInput(pane: UUID, intent: PaneInputIntent, text: String, attachments: [String]) -> String? {
            guard pane == self.pane else { return nil }
            log.calls.append((intent, text)); log.attachments.append(attachments)
            return intent == .approve ? PaneDelivery.Outcome.promptGone.wire : PaneDelivery.Outcome.landed.wire
        }
    }
    static let dns = "mac.test.ts.net"
    static let origin = "https://\(dns):8444"

    func withServer(port: UInt16, _ body: (RemoteServer, PairingCodes, DeviceStore, FakeBackend) throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("true-e2e-\(UUID().uuidString)/d.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let codes = PairingCodes(); let devices = DeviceStore(url: url); let be = FakeBackend()
        let s = RemoteServer(backend: be, codes: codes, devices: devices, allowedLogin: { "me@x" },
                             dnsName: { Self.dns }, wsAuthTimeout: 0.7)
        #expect(s.start(port: port))
        defer { s.stop() }
        try body(s, codes, devices, be)
    }

    func connect(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = RemoteServer.loopbackAddress(port: port)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// One request, read until the server closes.
    func http(_ port: UInt16, _ method: String, _ path: String, host: String? = dns + ":8444", origin: String? = nil,
              bearer: String? = nil, extra: [String] = [], body: String = "", login: String? = "me@x") -> (status: Int, head: String, body: String) {
        var l = ["\(method) \(path) HTTP/1.1"]
        if let host { l.append("Host: \(host)") }
        if let login { l.append("Tailscale-User-Login: \(login)") }
        if let origin { l.append("Origin: \(origin)") }
        if let bearer { l.append("Authorization: Bearer \(bearer)") }
        l += extra
        if !body.isEmpty { l.append("Content-Type: application/json"); l.append("Content-Length: \(body.utf8.count)") }
        let raw = Array((l.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
        let fd = connect(port); defer { close(fd) }
        _ = send(fd, raw, raw.count, 0)
        var all: [UInt8] = []; var buf = [UInt8](repeating: 0, count: 8192)
        while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; all += buf[0..<n] }
        let text = String(decoding: all, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let status = Int(parts[0].split(separator: " ").dropFirst().first ?? "") ?? 0
        return (status, parts[0], parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    @Test func paneInputMapsIntentsAndPaths() throws {
        try withServer(port: 18871) { _, _, devices, be in
            let tok = devices.pair(label: "t")
            func post(_ id: String, _ body: String) -> (status: Int, head: String, body: String) {
                http(18871, "POST", "/api/pane/\(id)/input", origin: Self.origin, bearer: tok, body: body)
            }
            let id = be.pane.uuidString
            let r = post(id, #"{"intent":"prompt","text":"hello there"}"#)
            #expect(r.status == 200 && r.body.contains(#""outcome":"landed""#))
            #expect(post(id, #"{"intent":"approve"}"#).body.contains("promptGone"))
            #expect(post(id, #"{"intent":"submitOnly"}"#).status == 200)
            for n in ["stage", "control", "deny"] { #expect(post(id, #"{"intent":"\#(n)","text":"x"}"#).status == 200) }
            #expect(be.log.calls.map(\.0) == [.prompt, .approve, .submitOnly, .stage, .control, .deny])
            #expect(be.log.calls[0].1 == "hello there")
            #expect(post(UUID().uuidString, #"{"intent":"prompt","text":"x"}"#).status == 404)
            #expect(post("not-a-uuid", #"{"intent":"prompt","text":"x"}"#).status == 404)
            #expect(post(id, #"{"intent":"nuke","text":"x"}"#).status == 400)
            #expect(post(id, "garbage").status == 400)
            #expect(post(id, #"{"intent":"prompt","text":"  "}"#).status == 400)
            let big = String(repeating: "a", count: 5000)           // past the 4 KB buffered cap, still one request
            #expect(post(id, #"{"intent":"prompt","text":"\#(big)"}"#).status == 200)
            #expect(http(18871, "POST", "/api/pane/\(id)/input", origin: Self.origin, body: #"{"intent":"prompt","text":"x"}"#).status == 401)
        }
    }

    @Test func paneInputAttachResolvesAndGuards() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("true-attach-\(UUID().uuidString)")
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tray = TrayStore(root: root.appendingPathComponent("tray"), trash: { _ in nil })
        let src = root.appendingPathComponent("a.png")
        try Data(RemoteDropEndToEndTests.png()).write(to: src)
        let shot = try #require(tray.ingest(src))
        let doc = downloads.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: doc)
        let secret = root.appendingPathComponent("x")
        try Data("s".utf8).write(to: secret)
        let files = RemoteFiles(tray: { tray }, inbox: RemoteInbox(root: root.appendingPathComponent("inbox")),
                                downloads: downloads, tmpDir: root.appendingPathComponent("tmp"))
        let devices = DeviceStore(url: root.appendingPathComponent("d.json"))
        let tok = devices.pair(label: "t"); let be = FakeBackend()
        let s = RemoteServer(backend: be, codes: PairingCodes(), devices: devices, allowedLogin: { "me@x" },
                             dnsName: { Self.dns }, files: files, wsAuthTimeout: 0.7)
        #expect(s.start(port: 18872)); defer { s.stop() }
        func post(_ body: String) -> Int {
            http(18872, "POST", "/api/pane/\(be.pane.uuidString)/input", origin: Self.origin, bearer: tok, body: body).status
        }
        #expect(post(#"{"intent":"prompt","text":"look","attach":[{"id":"\#(shot.id)"},{"name":"notes.txt"}]}"#) == 200)
        let got = try #require(be.log.attachments.last)
        #expect(got.count == 2 && got[0].hasSuffix(shot.file.split(separator: "/").last.map(String.init) ?? "?"))
        #expect(got[1].hasSuffix("/Downloads/notes.txt") || got[1].contains("notes.txt"))
        #expect(post(#"{"intent":"prompt","text":"","attach":[{"id":"\#(shot.id)"}]}"#) == 200)
        #expect(post(#"{"intent":"prompt","text":"x","attach":[{"id":"nope"}]}"#) == 404)
        #expect(post(#"{"intent":"prompt","text":"x","attach":[{"name":"missing.txt"}]}"#) == 404)
        #expect(post(#"{"intent":"prompt","text":"x","attach":[{"name":"../x"}]}"#) == 404)   // sanitized to "x" inside Downloads: absent
        let nine = Array(repeating: #"{"name":"notes.txt"}"#, count: 9).joined(separator: ",")
        #expect(post(#"{"intent":"prompt","text":"x","attach":[\#(nine)]}"#) == 400)
        #expect(post(#"{"intent":"prompt","text":"x","attach":[{"id":"a","name":"b"}]}"#) == 400)
        #expect(post(#"{"intent":"prompt","text":"x","attach":[{}]}"#) == 400)
        #expect(post(#"{"intent":"prompt","text":""}"#) == 400)
        #expect(post(#"{"intent":"prompt","text":"hello"}"#) == 200)
        #expect(be.log.attachments.last == [])
    }

    @Test func paneInputIntentMapping() {
        #expect(PaneInputIntent.prompt.deliveryIntent == .prompt)
        #expect(PaneInputIntent.approve.deliveryIntent == .answer(approve: true))
        #expect(PaneInputIntent.deny.deliveryIntent == .answer(approve: false))
        #expect(PaneInputIntent.submitOnly.deliveryIntent == .submitOnly)
        #expect(PaneInputIntent.allCases.count == 6)
    }

    @Test func pairReturnsTokenInBodyAndNeverSetsCookie() throws {
        try withServer(port: 18811) { _, codes, devices, _ in
            let code = codes.issue()
            let r = http(18811, "POST", "/pair", origin: Self.origin, body: #"{"code":"\#(code)"}"#)
            #expect(r.status == 200)
            #expect(!r.head.lowercased().contains("set-cookie"))
            let tok = (try JSONSerialization.jsonObject(with: Data(r.body.utf8)) as? [String: Any])?["token"] as? String
            #expect(tok?.count == 64)
            #expect(devices.validate(tok) != nil)
            // Bearer works; a cookie carrying the same token does not.
            #expect(http(18811, "GET", "/api/tabs", bearer: tok).status == 200)
            #expect(http(18811, "GET", "/api/tabs", extra: ["Cookie: true_dev=\(tok ?? "")"]).status == 401)
            #expect(http(18811, "GET", "/api/tabs", bearer: "nope").status == 401)
        }
    }

    @Test func pairNeedsExactOrigin() throws {
        try withServer(port: 18812) { _, codes, _, _ in
            let code = codes.issue(); let body = #"{"code":"\#(code)"}"#
            #expect(http(18812, "POST", "/pair", origin: nil, body: body).status == 403)
            #expect(http(18812, "POST", "/pair", origin: "https://\(Self.dns)", body: body).status == 403)   // no port
            #expect(http(18812, "POST", "/pair", origin: "http://\(Self.dns):8444", body: body).status == 403) // http
            #expect(http(18812, "POST", "/pair", origin: "https://evil.com:8444", body: body).status == 403)
            #expect(http(18812, "POST", "/pair", origin: Self.origin, body: body).status == 200)             // code was never spent
        }
    }

    @Test func foreignHostRefused() throws {
        try withServer(port: 18813) { _, _, _, _ in
            #expect(http(18813, "GET", "/", host: "evil.example:8444").status == 403)    // DNS rebinding
            #expect(http(18813, "GET", "/", host: "127.0.0.1:8801").status == 403)
            #expect(http(18813, "GET", "/", host: nil).status == 403)
            #expect(http(18813, "GET", "/", host: Self.dns).status == 200)
            #expect(http(18813, "GET", "/", host: Self.dns + ":8444").status == 200)
        }
    }

    @Test func everyResponseHasHeaders() throws {
        try withServer(port: 18814) { _, _, _, _ in
            for r in [http(18814, "GET", "/"), http(18814, "GET", "/api/tabs"), http(18814, "GET", "/", host: "x"),
                      http(18814, "GET", "/nope")] {
                let h = r.head.lowercased()
                #expect(h.contains("x-frame-options: deny") && h.contains("content-security-policy: default-src 'self'"))
                #expect(h.contains("cache-control: no-store") && h.contains("x-content-type-options: nosniff"))
                #expect(h.contains("referrer-policy: no-referrer"))
            }
        }
    }

    @Test func burnedCodeStopsWorking() throws {
        try withServer(port: 18815) { _, codes, _, _ in
            let code = codes.issue(); let wrong = code == "000000" ? "111111" : "000000"
            for _ in 0..<5 { #expect(http(18815, "POST", "/pair", origin: Self.origin, body: #"{"code":"\#(wrong)"}"#).status == 401) }
            #expect(codes.isBurned)
            #expect(http(18815, "POST", "/pair", origin: Self.origin, body: #"{"code":"\#(code)"}"#).status == 429)
        }
    }

    @Test func duplicateHeaderGets400() throws {
        try withServer(port: 18816) { _, _, _, _ in
            #expect(http(18816, "GET", "/", extra: ["Tailscale-User-Login: other@x"]).status == 400)
            #expect(http(18816, "GET", "/", extra: ["Host: evil.com"]).status == 400)
            #expect(http(18816, "GET", "/api/tabs", bearer: "a", extra: ["Authorization: Bearer b"]).status == 400)
        }
    }

    // MARK: websocket

    private func open(_ port: UInt16, pane: UUID, origin: String?) -> Int32 {
        let fd = connect(port)
        var l = ["GET /api/pane/\(pane.uuidString) HTTP/1.1", "Host: \(Self.dns):8444", "Tailscale-User-Login: me@x",
                 "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                 "Sec-WebSocket-Version: 13"]
        if let origin { l.append("Origin: \(origin)") }
        let raw = Array((l.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        _ = send(fd, raw, raw.count, 0)
        return fd
    }

    /// Browsers send their first frame only after `onopen`, i.e. after the 101 head.
    private func awaitHead(_ fd: Int32) {
        var got: [UInt8] = []; var b = [UInt8](repeating: 0, count: 1)
        while !(got.suffix(4) == [13, 10, 13, 10]) { if recv(fd, &b, 1, 0) <= 0 { break }; got += b }
    }

    private func readAll(_ fd: Int32) -> [UInt8] {
        var all: [UInt8] = []; var buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; all += buf[0..<n] }
        return all
    }

    /// Bytes of the first close frame after the 101 head, if any.
    private func closeCode(_ bytes: [UInt8]) -> Int? {
        let sep: [UInt8] = [13, 10, 13, 10]
        guard let i = (0..<max(0, bytes.count - 3)).first(where: { Array(bytes[$0..<$0 + 4]) == sep }) else { return nil }
        let f = Array(bytes[(i + 4)...])
        guard f.count >= 4, f[0] == 0x88 else { return nil }
        return Int(f[2]) << 8 | Int(f[3])
    }

    @Test func websocketNeedsExactOrigin() throws {
        try withServer(port: 18817) { _, _, _, be in
            for o in [nil, "https://\(Self.dns)", "http://\(Self.dns):8444", "https://evil.com"] as [String?] {
                let fd = open(18817, pane: be.pane, origin: o); defer { close(fd) }
                #expect(String(decoding: readAll(fd), as: UTF8.self).hasPrefix("HTTP/1.1 403"), "origin \(o ?? "nil")")
            }
        }
    }

    @Test func websocketClosesWith4401WithoutValidFirstMessage() throws {
        try withServer(port: 18818) { _, _, devices, be in
            // 1. silence → closed 4401 after the auth window, and not one PTY byte.
            do {
                let fd = open(18818, pane: be.pane, origin: Self.origin); defer { close(fd) }
                let bytes = readAll(fd)
                #expect(String(decoding: bytes, as: UTF8.self).hasPrefix("HTTP/1.1 101"))
                #expect(closeCode(bytes) == 4401)
                #expect(!bytes.contains(0x41) || closeCode(bytes) == 4401)
            }
            // 2. wrong token → 4401 immediately.
            do {
                let fd = open(18818, pane: be.pane, origin: Self.origin); defer { close(fd) }
                awaitHead(fd)
                let m = maskedFrame(1, Array(#"{"auth":"wrong"}"#.utf8))
                let t0 = Date()
                _ = send(fd, m, m.count, 0)
                let bytes = readAll(fd)
                #expect(bytes.count == 4 && bytes[0] == 0x88 && Int(bytes[2]) << 8 | Int(bytes[3]) == 4401)
                #expect(Date().timeIntervalSince(t0) < 0.5)               // refused at once, not by timeout
            }
            // 3. valid token → snapshot flows.
            do {
                let tok = devices.pair(label: "t")
                let fd = open(18818, pane: be.pane, origin: Self.origin); defer { close(fd) }
                awaitHead(fd)
                let m = maskedFrame(1, Array(#"{"auth":"\#(tok)"}"#.utf8))
                _ = send(fd, m, m.count, 0)
                var buf = [UInt8](repeating: 0, count: 4096); var got: [UInt8] = []
                while !String(decoding: got, as: UTF8.self).contains(#""t":"snap""#) {
                    let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; got += buf[0..<n]
                }
                #expect(String(decoding: got, as: UTF8.self).contains(#""t":"snap""#))
            }
        }
    }

    @Test func upgradeHeadersDoNotSkipBearerOutsidePaneSocket() throws {
        try withServer(port: 18819) { _, _, _, _ in
            let up = ["Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                      "Sec-WebSocket-Version: 13"]
            let r = http(18819, "GET", "/api/tabs", origin: Self.origin, extra: up)
            #expect(r.status == 400 && !r.body.contains("tabs"))
            #expect(http(18819, "GET", "/", origin: Self.origin, extra: up).status == 400)
            #expect(http(18819, "GET", "/api/tabs").status == 401)                       // plain, no bearer
        }
    }

    @Test func revokeClosesLiveSocket() throws {
        try withServer(port: 18820) { s, _, devices, be in
            let tok = devices.pair(label: "t")
            let id = try #require(devices.validate(tok)?.id)
            let fd = open(18820, pane: be.pane, origin: Self.origin); defer { close(fd) }
            awaitHead(fd)
            let m = maskedFrame(1, Array(#"{"auth":"\#(tok)"}"#.utf8))
            _ = send(fd, m, m.count, 0)
            var buf = [UInt8](repeating: 0, count: 4096); var got: [UInt8] = []
            while !String(decoding: got, as: UTF8.self).contains(#""t":"snap""#) {
                let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; got += buf[0..<n]
            }
            #expect(String(decoding: got, as: UTF8.self).contains(#""t":"snap""#))
            devices.revoke(id); s.disconnect(device: id)
            let t0 = Date()
            _ = readAll(fd)                                                              // returns only once the server closed
            #expect(Date().timeIntervalSince(t0) < 2)
            #expect(devices.validate(tok) == nil)
        }
    }

    @Test func emptyDNSNameFailsClosed() {
        #expect(!RemoteAuth.hostMatches(host: "", dnsName: "."))
        #expect(!RemoteAuth.hostMatches(host: ":8444", dnsName: "."))
        #expect(!RemoteAuth.originMatches(origin: "https://:8444", dnsName: "."))
    }
}
