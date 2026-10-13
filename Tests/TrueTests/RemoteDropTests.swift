import Testing
import Foundation
import Darwin
import AppKit
@testable import True

@Suite struct DropNameTests {
    private let t = Date(timeIntervalSince1970: 0)

    @Test func traversalAndAbsolutePathsKeepOnlyTheLastComponent() {
        #expect(DropName.sanitize("../../x", now: t) == "x")
        #expect(DropName.sanitize("/etc/passwd", now: t) == "passwd")
        #expect(DropName.sanitize("a\\b\\c.txt", now: t) == "c.txt")
        #expect(DropName.sanitize("dir/", now: t).hasPrefix("dir") || DropName.sanitize("dir/", now: t).hasPrefix("iPhone-"))
    }

    @Test func leadingDotsControlCharsAndColonsGoAway() {
        #expect(DropName.sanitize(".hidden", now: t) == "hidden")
        #expect(DropName.sanitize("...", now: t).hasPrefix("iPhone-"))
        let n = DropName.sanitize("a\u{0}b\u{7}c:d.png", now: t)
        #expect(!n.contains("\u{0}") && !n.contains(":") && n.hasSuffix(".png"))
    }

    @Test func unicodeSurvivesAndLongNamesAreCappedKeepingTheExtension() {
        #expect(DropName.sanitize("café 写真.jpg", now: t) == "café 写真.jpg")
        let long = String(repeating: "a", count: 300) + ".png"
        let n = DropName.sanitize(long, now: t)
        #expect(n.count <= 120 && n.hasSuffix(".png"))
    }

    @Test func emptyOrNilBecomesIPhoneDate() {
        #expect(DropName.sanitize("", now: t).hasPrefix("iPhone-"))
        #expect(DropName.sanitize(nil, now: t).hasPrefix("iPhone-"))
        #expect(DropName.sanitize("%00%2F", now: t).count > 0)
    }

    @Test func numberedNeverOverwrites() throws {
        #expect(DropName.numbered("a.txt", 2) == "a-2.txt")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("true-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        DropFS.ensureDir(dir)
        var names: [String] = []
        for i in 0..<3 {
            let tmp = dir.appendingPathComponent("tmp\(i)")
            try Data("\(i)".utf8).write(to: tmp)
            names.append(DropFS.placeExclusive(tmp, in: dir, name: "a.txt")!.lastPathComponent)
        }
        #expect(names == ["a.txt", "a-2.txt", "a-3.txt"])
        #expect(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8) == "0")
    }

    @Test func rasterImagesOnly() {
        for ok in ["a.png", "a.JPG", "a.jpeg", "a.heic", "a.heif", "a.gif", "a.webp", "a.tiff"] { #expect(DropName.isRasterImage(ok), "\(ok)") }
        for no in ["a.svg", "a.pdf", "a.html", "a.txt", "a"] { #expect(!DropName.isRasterImage(no), "\(no)") }
    }
}

@Suite struct RemoteInboxTests {
    private func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("true-inbox-\(UUID().uuidString)") }
    private func mode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions]) as? Int) ?? -1 }

    @Test func permissionsAreOwnerOnly() throws {
        let root = dir(); defer { try? FileManager.default.removeItem(at: root) }
        let box = RemoteInbox(root: root)
        let item = try #require(box.add(name: "Clipboard", kind: .text, data: Data("hi".utf8)))
        #expect(mode(root) == 0o700)
        #expect(mode(root.appendingPathComponent("\(item.id).dat")) == 0o600)
    }

    @Test func capsAtTwentyNewestFirst() throws {
        let root = dir(); defer { try? FileManager.default.removeItem(at: root) }
        let box = RemoteInbox(root: root)
        for i in 0..<25 { box.add(name: "n\(i)", kind: .text, data: Data("\(i)".utf8)) }
        let all = box.list()
        #expect(all.count == 20)
        #expect(all.first?.name == "n24")
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).filter { $0.hasSuffix(".dat") }.count == 20)
    }

    @Test func expiresAfter24Hours() {
        let root = dir(); defer { try? FileManager.default.removeItem(at: root) }
        final class Clock: @unchecked Sendable { var t = Date() }
        let c = Clock()
        let box = RemoteInbox(root: root, now: { c.t })
        let item = box.add(name: "x", kind: .text, data: Data("x".utf8))!
        #expect(box.list().count == 1)
        c.t = c.t.addingTimeInterval(24 * 3600 + 60)
        #expect(box.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(item.id).dat").path))
    }

    @Test func idsAreStrict() {
        #expect(RemoteInbox.validID("0123456789abcdef"))
        #expect(!RemoteInbox.validID("../etc/passwd"))
        #expect(!RemoteInbox.validID("0123456789ABCDEF"))
    }
}

@Suite(.serialized) struct RemoteDropEndToEndTests {
    static let dns = "mac.test.ts.net"
    static let origin = "https://\(dns):8444"
    struct FakeBackend: RemoteBackend {
        func tabsJSON() -> Data { Data(#"{"tabs":[]}"#.utf8) }
        func snapshot(pane: UUID) -> (cols: Int, rows: Int, bytes: [UInt8])? { nil }
        func input(pane: UUID, bytes: [UInt8]) -> Bool { true }
    }
    final class Sink: @unchecked Sendable { var toasts: [String] = []; var clip: [String] = []; var ingests = 0; var free: Int64 = 50 << 30 }

    struct Env {
        let server: RemoteServer, token: String, shortcut: String, files: RemoteFiles, sink: Sink, root: URL
        var downloads: URL { files.downloads }
    }

    func withEnv(port: UInt16, deadline: TimeInterval = 5, quarantine: (@Sendable (URL) -> Bool)? = nil, commands: RemoteCommands? = nil, _ body: (Env) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("true-drop-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = Sink()
        let tray = TrayStore(root: root.appendingPathComponent("tray"), trash: { _ in nil })
        let files = RemoteFiles(tray: { tray }, inbox: RemoteInbox(root: root.appendingPathComponent("inbox")),
                                downloads: root.appendingPathComponent("Downloads"), tmpDir: root.appendingPathComponent("tmp"),
                                freeBytes: { _ in sink.free },
                                notify: { sink.toasts.append($0) }, setClipboard: { sink.clip.append($0) }, didIngest: { sink.ingests += 1 },
                                quarantine: quarantine ?? { DropFS.setQuarantine($0) })
        let devices = DeviceStore(url: root.appendingPathComponent("d.json"))
        let token = devices.pair(label: "Phone")
        let shortcut = devices.pair(label: "Shortcut", scope: .dropOnly)
        let s = RemoteServer(backend: FakeBackend(), codes: PairingCodes(), devices: devices, allowedLogin: { "me@x" },
                             dnsName: { Self.dns }, files: files, dropDeadline: deadline, wsAuthTimeout: 0.7,
                             commands: commands ?? RemoteCommandsLive())
        #expect(s.start(port: port))
        defer { s.stop() }
        try body(Env(server: s, token: token, shortcut: shortcut, files: files, sink: sink, root: root))
    }

    func connect(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = RemoteServer.loopbackAddress(port: port)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var tv = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    struct Resp { var status: Int; var head: String; var body: [UInt8]
        var text: String { String(decoding: body, as: UTF8.self) }
        /// Every value of a header (the file routes send the usual CSP AND `sandbox`; browsers enforce both).
        func all(_ n: String) -> [String] {
            head.components(separatedBy: "\r\n").dropFirst().filter { $0.lowercased().hasPrefix(n.lowercased() + ":") }
                .map { String($0.drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
        func header(_ n: String) -> String? {
            head.components(separatedBy: "\r\n").dropFirst().first { $0.lowercased().hasPrefix(n.lowercased() + ":") }
                .map { String($0.drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Raw request; `declared` overrides Content-Length, `sendBody` false = headers only, `truncate` sends fewer body bytes.
    func raw(_ port: UInt16, _ method: String, _ path: String, bearer: String?, origin: String? = nil, host: String? = dns + ":8444",
             extra: [String] = [], body: [UInt8] = [], declared: Int? = nil, sendBody: Bool = true) -> Resp {
        var l = ["\(method) \(path) HTTP/1.1"]
        if let host { l.append("Host: \(host)") }
        l.append("Tailscale-User-Login: me@x")
        if let origin { l.append("Origin: \(origin)") }
        if let bearer { l.append("Authorization: Bearer \(bearer)") }
        l += extra
        if !body.isEmpty || declared != nil { l.append("Content-Length: \(declared ?? body.count)") }
        let head = Array((l.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        let fd = connect(port); defer { close(fd) }
        _ = send(fd, head, head.count, 0)
        if sendBody, !body.isEmpty {
            var off = 0
            while off < body.count { let n = body[off...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }; if n <= 0 { break }; off += n }
        }
        var all: [UInt8] = []; var buf = [UInt8](repeating: 0, count: 65536)
        while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; all += buf[0..<n] }
        guard let r = all.firstRange(of: Array("\r\n\r\n".utf8)) else { return Resp(status: 0, head: "", body: all) }
        let h = String(decoding: all[0..<r.lowerBound], as: UTF8.self)
        let status = Int(h.split(separator: " ").dropFirst().first ?? "") ?? 0
        return Resp(status: status, head: h, body: Array(all[r.upperBound...]))
    }

    func drop(_ port: UInt16, _ env: Env, name: String, body: [UInt8], origin: String? = nil) -> Resp {
        raw(port, "POST", "/api/drop", bearer: env.token, origin: origin,
            extra: ["X-Filename: " + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)], body: body)
    }

    static func png() -> [UInt8] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return [UInt8](rep.representation(using: .png, properties: [:])!)
    }

    // MARK: routing & files

    @Test func imageGoesToTrayEverythingElseToDownloadsQuarantined() throws {
        try withEnv(port: 18841) { env in
            let img = drop(18841, env, name: "photo.png", body: Self.png())
            #expect(img.status == 200 && img.text.contains("\"shots\""))
            #expect(env.files.tray().load().shots.count == 1)
            #expect(env.sink.ingests == 1)
            #expect(env.sink.toasts.last == "Received photo.png from iPhone")

            let txt = drop(18841, env, name: "notes.txt", body: Array("hello".utf8))
            #expect(txt.status == 200 && txt.text.contains("downloads"))
            let placed = env.downloads.appendingPathComponent("notes.txt")
            #expect(FileManager.default.fileExists(atPath: placed.path))
            #expect(DropFS.quarantine(placed) != nil)

            // A fake .png that does not decode must not enter the tray.
            let bad = drop(18841, env, name: "fake.png", body: Array("not an image".utf8))
            #expect(bad.status == 200 && bad.text.contains("downloads"))
            #expect(env.files.tray().load().shots.count == 1)

            // svg is not raster → Downloads
            #expect(drop(18841, env, name: "x.svg", body: Array("<svg/>".utf8)).text.contains("downloads"))
            // same name twice never overwrites
            _ = drop(18841, env, name: "notes.txt", body: Array("two".utf8))
            #expect(FileManager.default.fileExists(atPath: env.downloads.appendingPathComponent("notes-2.txt").path))
            // traversal stays inside Downloads
            _ = drop(18841, env, name: "../../evil.txt", body: Array("x".utf8))
            #expect(FileManager.default.fileExists(atPath: env.downloads.appendingPathComponent("evil.txt").path))
            #expect(!FileManager.default.fileExists(atPath: env.root.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
            // temp dir is left empty
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: env.files.tmpDir.path)) ?? []).isEmpty)
        }
    }

    @Test func overTwoHundredMBIs413WithoutReadingIt() throws {
        try withEnv(port: 18842) { env in
            let r = raw(18842, "POST", "/api/drop", bearer: env.token, extra: ["X-Filename: big.bin"],
                        body: [], declared: RemoteFiles.maxDropBytes + 1)
            #expect(r.status == 413)
            #expect(raw(18842, "POST", "/api/drop", bearer: env.token, extra: ["X-Filename: a"], body: []).status == 411)
        }
    }

    @Test func lowDiskIs507() throws {
        try withEnv(port: 18843) { env in
            env.sink.free = 10 << 20
            #expect(drop(18843, env, name: "a.txt", body: Array("x".utf8)).status == 507)
            #expect(!FileManager.default.fileExists(atPath: env.downloads.appendingPathComponent("a.txt").path))
        }
    }

    @Test func slowBodyHitsTheDeadline() throws {
        try withEnv(port: 18844, deadline: 0.5) { env in
            let t0 = Date()
            let r = raw(18844, "POST", "/api/drop", bearer: env.token, extra: ["X-Filename: slow.bin"],
                        body: Array("0123456789".utf8), declared: 1000)
            #expect(r.status == 408)
            #expect(Date().timeIntervalSince(t0) < 3)
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: env.files.tmpDir.path)) ?? []).isEmpty)
        }
    }

    // MARK: auth rules

    @Test func noOriginWithBearerOnlyOnDropAndClip() throws {
        try withEnv(port: 18845) { env in
            #expect(drop(18845, env, name: "a.txt", body: Array("x".utf8)).status == 200)
            let clip = raw(18845, "POST", "/api/clip", bearer: env.token, body: Array(#"{"text":"hi"}"#.utf8))
            #expect(clip.status == 200 && env.sink.clip == ["hi"] && env.sink.toasts.contains("Clipboard from iPhone"))
            // Everywhere else a state-changing request without Origin is refused.
            #expect(raw(18845, "POST", "/pair", bearer: env.token, body: Array(#"{"code":"000000"}"#.utf8)).status == 403)
            #expect(raw(18845, "DELETE", "/api/inbox/0123456789abcdef", bearer: env.token).status == 403)
            // A present Origin must still be exact.
            #expect(drop(18845, env, name: "a.txt", body: Array("x".utf8), origin: "https://evil.example").status == 403)
            #expect(drop(18845, env, name: "b.txt", body: Array("x".utf8), origin: Self.origin).status == 200)
            // Exact Host still required.
            #expect(raw(18845, "POST", "/api/drop", bearer: env.token, host: "evil.example", extra: ["X-Filename: c"], body: Array("x".utf8)).status != 200)
            #expect(!FileManager.default.fileExists(atPath: env.downloads.appendingPathComponent("c").path))
        }
    }

    @Test func badOrMissingBearerIs401() throws {
        try withEnv(port: 18846) { env in
            let bad = raw(18846, "POST", "/api/drop", bearer: "nope", extra: ["X-Filename: a"], body: Array("x".utf8))
            #expect(bad.status == 401)
            #expect(raw(18846, "POST", "/api/drop", bearer: nil, extra: ["X-Filename: a"], body: Array("x".utf8)).status == 401)
            #expect(raw(18846, "POST", "/api/clip", bearer: "nope", body: Array(#"{"text":"x"}"#.utf8)).status == 401)
            #expect(raw(18846, "GET", "/api/shots", bearer: "nope", origin: Self.origin).status == 401)
            #expect(raw(18846, "GET", "/api/inbox", bearer: nil, origin: Self.origin).status == 401)
            #expect(env.sink.clip.isEmpty)
        }
    }

    @Test func clipCapAndNoClipboardReadRoute() throws {
        try withEnv(port: 18847) { env in
            let big = #"{"text":""# + String(repeating: "a", count: RemoteFiles.maxClipBytes + 1) + #""}"#
            #expect(raw(18847, "POST", "/api/clip", bearer: env.token, body: Array(big.utf8)).status == 413)
            #expect(env.sink.clip.isEmpty)
            #expect(raw(18847, "POST", "/api/clip", bearer: env.token, body: Array("{}".utf8)).status == 400)
            // No route reads the Mac clipboard or a Mac path.
            for p in ["/api/clip", "/api/clipboard", "/api/pasteboard", "/api/file", "/api/files", "/api/fs"] {
                #expect(raw(18847, "GET", p, bearer: env.token, origin: Self.origin).status == 404, "\(p)")
            }
            for r in RemoteServer.routeTable {
                let l = r.lowercased()
                #expect(!l.contains("clipboard") && !l.contains("pasteboard") && !l.contains("path") && !l.contains("file"))
                if l.contains("/api/clip") { #expect(l.hasPrefix("post")) }
            }
        }
    }

    // MARK: shots & inbox serving

    @Test func shotIdIsStrictAndMustBeInTheIndex() throws {
        try withEnv(port: 18848) { env in
            _ = drop(18848, env, name: "p.png", body: Self.png())
            let list = raw(18848, "GET", "/api/shots", bearer: env.token, origin: Self.origin)
            #expect(list.status == 200)
            let obj = try JSONSerialization.jsonObject(with: Data(list.body)) as? [String: Any]
            let id = try #require((obj?["shots"] as? [[String: Any]])?.first?["id"] as? String)
            #expect(id.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil)
            let ok = raw(18848, "GET", "/api/shots/\(id)", bearer: env.token, origin: Self.origin)
            #expect(ok.status == 200 && ok.header("Content-Type")?.hasPrefix("image/") == true)
            #expect(ok.all("Content-Security-Policy").contains("sandbox"))
            // well-formed but unknown, and path-shaped ids
            #expect(raw(18848, "GET", "/api/shots/20200101-000000-abcd", bearer: env.token, origin: Self.origin).status == 404)
            for bad in ["..%2F..%2Fetc%2Fpasswd", "../index.json", "index.json", "20200101-000000-ABCD", "x"] {
                #expect(raw(18848, "GET", "/api/shots/\(bad)", bearer: env.token, origin: Self.origin).status == 404, "\(bad)")
            }
        }
    }

    @Test func activeContentIsServedAsSandboxedAttachment() throws {
        try withEnv(port: 18849) { env in
            let box = env.files.inbox
            let svg = try #require(box.add(name: "x.svg", kind: .file, data: Data("<svg onload=alert(1)/>".utf8)))
            let html = try #require(box.add(name: "x.html", kind: .file, data: Data("<script>alert(1)</script>".utf8)))
            for item in [svg, html] {
                let r = raw(18849, "GET", "/api/inbox/\(item.id)", bearer: env.token, origin: Self.origin)
                #expect(r.status == 200)
                #expect(r.header("Content-Type") == "application/octet-stream")
                #expect(r.header("Content-Disposition")?.hasPrefix("attachment") == true)
                #expect(r.all("Content-Security-Policy").contains("sandbox"))
                #expect(r.header("X-Content-Type-Options")?.lowercased() == "nosniff")
            }
            // list + delete
            let list = raw(18849, "GET", "/api/inbox", bearer: env.token, origin: Self.origin)
            #expect(list.status == 200 && list.text.contains(svg.id))
            #expect(raw(18849, "DELETE", "/api/inbox/\(svg.id)", bearer: env.token, origin: Self.origin).status == 200)
            #expect(raw(18849, "GET", "/api/inbox/\(svg.id)", bearer: env.token, origin: Self.origin).status == 404)
            #expect(raw(18849, "GET", "/api/inbox/..%2F..%2Fetc%2Fpasswd", bearer: env.token, origin: Self.origin).status == 404)
        }
    }

    @Test func inboxImageKeepsItsImageType() throws {
        try withEnv(port: 18850) { env in
            let tmp = env.root.appendingPathComponent("p.png")
            try Data(Self.png()).write(to: tmp)
            let item = try #require(env.files.inbox.add(name: "p.png", kind: .image, from: tmp))
            let r = raw(18850, "GET", "/api/inbox/\(item.id)", bearer: env.token, origin: Self.origin)
            #expect(r.header("Content-Type") == "image/png")
            #expect(r.all("Content-Security-Policy").contains("sandbox"))
        }
    }

    // MARK: scope, concurrency, quarantine, header (security review)

    @Test func shortcutTokenCanOnlyDropAndClip() throws {
        try withEnv(port: 18851) { env in
            let item = try #require(env.files.inbox.add(name: "n.txt", kind: .text, data: Data("x".utf8)))
            for (m, p) in [("GET", "/api/tabs"), ("GET", "/api/shots"), ("GET", "/api/inbox"),
                           ("GET", "/api/inbox/\(item.id)"), ("DELETE", "/api/inbox/\(item.id)")] {
                #expect(raw(18851, m, p, bearer: env.shortcut, origin: Self.origin).status == 403, "\(m) \(p)")
            }
            #expect(env.files.inbox.list().count == 1)                                       // DELETE did nothing
            #expect(raw(18851, "POST", "/api/drop", bearer: env.shortcut, extra: ["X-Filename: a.txt"], body: Array("x".utf8)).status == 200)
            #expect(raw(18851, "POST", "/api/clip", bearer: env.shortcut, body: Array(#"{"text":"hi"}"#.utf8)).status == 200)
            // the full token is unaffected
            #expect(raw(18851, "GET", "/api/tabs", bearer: env.token, origin: Self.origin).status == 200)
            #expect(raw(18851, "GET", "/api/inbox", bearer: env.token, origin: Self.origin).status == 200)
        }
    }

    @Test func shortcutTokenIsRefusedOnTheWebSocket() throws {
        try withEnv(port: 18852) { env in
            let pane = UUID().uuidString.lowercased()
            func closeCode(for tok: String) -> (head: String, code: Int?) {
                let fd = connect(18852); defer { close(fd) }
                let req = "GET /api/pane/\(pane) HTTP/1.1\r\nHost: \(Self.dns):8444\r\nTailscale-User-Login: me@x\r\nOrigin: \(Self.origin)\r\n"
                    + "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
                _ = send(fd, Array(req.utf8), req.utf8.count, 0)
                var buf = [UInt8](repeating: 0, count: 4096); var got: [UInt8] = []
                while !got.contains(where: { _ in String(decoding: got, as: UTF8.self).contains("\r\n\r\n") }) {
                    let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; got += buf[0..<n]
                }
                // masked client text frame {"auth":tok}
                let payload = Array(#"{"auth":"\#(tok)"}"#.utf8), mask: [UInt8] = [1, 2, 3, 4]
                var f: [UInt8] = [0x81, 0x80 | UInt8(payload.count)] + mask
                for (i, b) in payload.enumerated() { f.append(b ^ mask[i % 4]) }
                _ = send(fd, f, f.count, 0)
                var all: [UInt8] = []
                while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; all += buf[0..<n] }
                let text = String(decoding: got, as: UTF8.self)
                guard all.count >= 4, all[0] == 0x88 else { return (text, nil) }
                return (text, Int(all[2]) << 8 | Int(all[3]))
            }
            #expect(closeCode(for: env.shortcut).code == 4401)
        }
    }

    @Test func oldDeviceJSONWithoutScopeDecodesAsFull() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("true-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("remote-devices.json")
        let h = RemoteAuth.sha256Hex("old-token")
        let json = #"[{"id":"\#(UUID().uuidString)","label":"iPhone","tokenHash":"\#(h)","created":1000,"lastSeen":2000}]"#
        try Data(json.utf8).write(to: url)
        let store = DeviceStore(url: url)
        #expect(store.all.count == 1 && store.all[0].scope == .full)
        #expect(store.validate("old-token")?.scope == .full)
        // round trip keeps a dropOnly scope
        let t = store.pair(label: "Shortcut", scope: .dropOnly)
        #expect(DeviceStore(url: url).validate(t)?.scope == .dropOnly)
    }

    @Test func thirdConcurrentDropIsBusy() throws {
        try withEnv(port: 18853, deadline: 30) { env in
            func hold() -> Int32 {                     // headers + a partial body: the upload stays in flight
                let fd = connect(18853)
                let h = "POST /api/drop HTTP/1.1\r\nHost: \(Self.dns):8444\r\nTailscale-User-Login: me@x\r\nAuthorization: Bearer \(env.token)\r\nX-Filename: big.bin\r\nContent-Length: 1000\r\n\r\nabc"
                _ = send(fd, Array(h.utf8), h.utf8.count, 0)
                return fd
            }
            let a = hold(), b = hold()
            defer { close(a); close(b) }
            Thread.sleep(forTimeInterval: 0.5)
            let third = raw(18853, "POST", "/api/drop", bearer: env.token, extra: ["X-Filename: c.txt"], body: Array("x".utf8))
            #expect(third.status == 503 && third.text == "Busy, retry" && third.header("Retry-After") != nil)
            // releasing a slot lets the next one through
            close(a)
            Thread.sleep(forTimeInterval: 0.5)
            #expect(raw(18853, "POST", "/api/drop", bearer: env.token, extra: ["X-Filename: c.txt"], body: Array("x".utf8)).status == 200)
        }
    }

    @Test func failedQuarantineRemovesTheFileAnd500s() throws {
        try withEnv(port: 18854, quarantine: { _ in false }) { env in
            let r = drop(18854, env, name: "evil.bin", body: Array("x".utf8))
            #expect(r.status == 500)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: env.downloads.path)) ?? []
            #expect(left.isEmpty)
        }
    }

    @Test func contentDispositionIsAsciiOnly() {
        let h = DropName.attachment("café 写真.svg")
        #expect(h.allSatisfy { $0.isASCII })
        #expect(h.contains("filename*=UTF-8''caf%C3%A9%20%E5%86%99%E7%9C%9F.svg"))
    }
}
