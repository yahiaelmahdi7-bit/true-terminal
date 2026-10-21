import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import os

/// Tiny HTTP/1.1 + WebSocket server on 127.0.0.1 ONLY. `tailscale serve` terminates TLS on the tailnet
/// and proxies here, adding `Tailscale-User-Login`. Pure BSD sockets, one thread per connection
/// (a phone or two), no dependencies — same style as ``LineSocketServer``.
final class RemoteServer: @unchecked Sendable {
    static let port: UInt16 = 8801
    static let maxConnections = 16
    private static let log = Logger(subsystem: "True", category: "remote")

    /// The only address we ever bind. Tested: never 0.0.0.0.
    static func loopbackAddress(port: UInt16 = RemoteServer.port) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        return a
    }

    let codes: PairingCodes
    let devices: DeviceStore
    let backend: RemoteBackend
    private let allowedLogin: @Sendable () -> String?
    private let dnsName: @Sendable () -> String?
    private let wsAuthTimeout: TimeInterval
    let files: RemoteFiles
    private let dropDeadline: TimeInterval
    let commands: RemoteCommands
    let bar: RemoteBar
    let sites: RemoteSites
    let browser: RemoteBrowser
    let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var open: Set<Int32> = []
    /// Drop uploads in flight; the free-space check is per upload, so cap how many can pass it at once.
    static let maxConcurrentDrops = 2
    private var activeDrops = 0
    /// Authenticated WebSocket fds → the device that authed them, so a revoke can cut live sessions.
    var socketDevices: [Int32: UUID] = [:]

    init(backend: RemoteBackend, codes: PairingCodes, devices: DeviceStore,
         allowedLogin: @escaping @Sendable () -> String?, dnsName: @escaping @Sendable () -> String?,
         files: RemoteFiles = RemoteFilesLive.make(), dropDeadline: TimeInterval = 120, wsAuthTimeout: TimeInterval = 5,
         commands: RemoteCommands = RemoteCommandsLive(), sites: RemoteSites = NoSites(), browser: RemoteBrowser = NoBrowser()) {
        self.browser = browser; self.sites = sites; self.commands = commands; self.bar = RemoteBar(commands: commands)
        self.wsAuthTimeout = wsAuthTimeout
        self.files = files; self.dropDeadline = dropDeadline
        self.backend = backend; self.codes = codes; self.devices = devices
        self.allowedLogin = allowedLogin; self.dnsName = dnsName
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    @discardableResult
    func start(port: UInt16 = RemoteServer.port) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return true }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)   // pane shells are forked from this process; they must never inherit the listener
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.loopbackAddress(port: port)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } == 0
        }
        guard ok, listen(fd, 16) == 0 else { close(fd); Self.log.error("bind failed on 127.0.0.1:\(port, privacy: .public)"); return false }
        listenFD = fd; running = true
        Self.log.notice("remote listening on 127.0.0.1:\(port, privacy: .public)")
        Thread.detachNewThread { [self] in acceptLoop(fd) }
        return true
    }

    func stop() {
        lock.lock()
        running = false
        let fds = open
        lock.unlock()
        for fd in fds { shutdown(fd, SHUT_RDWR) }
        Self.log.notice("remote stopped")
    }

    /// Close every live WebSocket that was authenticated by `device` (called on revoke).
    func disconnect(device: UUID) {
        // Shut down while holding the lock: an fd still in the map hasn't been closed, so it can't have been reused.
        lock.lock(); defer { lock.unlock() }
        for (fd, d) in socketDevices where d == device { shutdown(fd, SHUT_RDWR) }
    }

    // MARK: accept

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 500) > 0 else { continue }
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            lock.lock()
            let full = open.count >= Self.maxConnections
            if !full { open.insert(c) }
            lock.unlock()
            if full { close(c); continue }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { [self] in
                handle(c)
                lock.lock(); open.remove(c); lock.unlock()
                close(c)
            }
        }
        close(fd)
        lock.lock(); listenFD = -1; lock.unlock()
    }

    // MARK: socket io

    func send(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    enum ReadOutcome: Equatable { case request(HTTPRequest), bad, timedOut }
    static let requestDeadline: TimeInterval = 10

    /// Read until a full HTTP request parses. The deadline is for the WHOLE request, not per read, so a client
    /// dribbling one byte at a time (slowloris) is cut off; the head is capped at 16 KB by the parser.
    static func readRequest(_ fd: Int32, deadline: TimeInterval = requestDeadline) -> ReadOutcome {
        let end = Date().addingTimeInterval(deadline)
        var buf: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            switch HTTPRequest.parse(buf) {
            case .bad: return .bad
            case .request(let r, _): return .request(r)
            case .needMore: break
            }
            let ms = Int32(max(0, min(end.timeIntervalSinceNow * 1000, 10_000)))
            if ms == 0 { return .timedOut }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&p, 1, ms)
            if rc == 0 { return .timedOut }
            if rc < 0 { if errno == EINTR { continue }; return .timedOut }
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return .timedOut }
            buf += chunk[0..<n]
        }
    }

    // MARK: request handling

    private func handle(_ fd: Int32) {
        let req: HTTPRequest
        switch Self.readRequest(fd) {
        case .timedOut: return
        case .bad: _ = send(fd, HTTPResponse.make(status: 400, reason: "Bad Request", body: Array("Bad request".utf8))); return
        case .request(let r): req = r
        }
        let isAPI = req.path.hasPrefix("/api/")
        let ws = req.isWebSocketUpgrade
        // The only request allowed to skip the bearer header is the pane WebSocket (it authenticates by first message).
        let paneSocket = ws && (req.path.hasPrefix("/api/pane/") || req.path == "/api/browser/stream")
        if ws && !paneSocket {
            _ = send(fd, HTTPResponse.make(status: 400, reason: "Bad Request", body: Array("Bad request".utf8))); return
        }
        let stateChanging = req.method != "GET" && req.method != "HEAD"
        // WebSocket auth is the first message (browsers can't set headers on a WS), so the upgrade itself needs no token.
        let needsToken = isAPI && !paneSocket
        let bearer = RemoteAuth.bearerToken(req.header("authorization"))
        let device = needsToken ? devices.validate(bearer) : nil
        // Browsers always send Origin on POST, and a bearer token is not ambient (no CSRF), so ONLY the Shortcuts routes
        // may omit it. A present Origin must still be exact; a bad/missing bearer still gets 401.
        let originOptional = req.method == "POST" && Self.noOriginRoutes.contains(req.path) && req.header("origin") == nil
        // A send-only (Shortcut) token is valid for nothing but POST /api/drop and /api/clip.
        if let device, device.scope == .dropOnly, !(req.method == "POST" && Self.noOriginRoutes.contains(req.path)) {
            Self.log.notice("deny 403 \(req.method, privacy: .public) \(req.path, privacy: .public): send-only token")
            _ = send(fd, HTTPResponse.make(status: 403, reason: "Forbidden", body: Array("Forbidden".utf8))); return
        }
        let decision = RemoteAuth.decide(loginHeader: req.header(RemoteAuth.loginHeader), allowedLogin: allowedLogin(),
                                         host: req.header("host"), origin: req.header("origin"), dnsName: dnsName(),
                                         requiresOrigin: (stateChanging || ws) && !originOptional, requiresToken: needsToken,
                                         tokenValid: device != nil)
        switch decision {
        case .forbidden(let why):
            Self.log.notice("deny 403 \(req.method, privacy: .public) \(req.path, privacy: .public): \(why, privacy: .public)")
            _ = send(fd, HTTPResponse.make(status: 403, reason: "Forbidden", body: Array("Forbidden".utf8)))
        case .needsPairing:
            Self.log.notice("deny 401 \(req.path, privacy: .public): not paired")
            _ = send(fd, HTTPResponse.make(status: 401, reason: "Unauthorized", body: Array("Not paired".utf8)))
        case .allow:
            let duty = req.header("x-true-duty").map { " duty=\($0)" } ?? ""
            Self.log.notice("allow \(req.method, privacy: .public) \(req.path, privacy: .public) device=\(device?.label ?? "-", privacy: .public)\(duty, privacy: .public)")
            route(fd, req, device: device?.id)
        }
    }

    static let noOriginRoutes: Set<String> = ["/api/drop", "/api/clip"]
    /// Every API route this server answers (the test asserts none of them reads the Mac clipboard or a Mac path).
    static let routeTable: [String] = [
        "POST /pair", "GET /api/tabs", "WS /api/pane/<uuid>", "POST /api/pane/<uuid>/input", "POST /api/drop", "POST /api/clip",
        "GET /api/shots", "GET /api/shots/<id>", "GET /api/shots/<id>/thumb", "GET /api/inbox", "GET /api/inbox/<id>", "DELETE /api/inbox/<id>",
        "GET /api/hub", "GET /api/hub/builder/<id>", "POST /api/hub/builder/<id>/ack",
        "POST /api/route", "POST /api/route/<routeId>/slot", "POST /api/run", "GET /api/recent",
        "GET /api/sites", "POST /api/sites/<port>/expose", "POST /api/sites/<port>/unexpose",
        "WS /api/browser/stream", "GET /api/browser/tabs", "POST /api/browser/tabs",
    ]

    func json(_ fd: Int32, _ status: Int, _ reason: String, _ obj: [String: Any], extra: [String: String] = [:]) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        _ = send(fd, HTTPResponse.make(status: status, reason: reason, headers: extra, body: [UInt8](body),
                                       contentType: "application/json"))
    }

    /// POST /pair {"code":"123456"} → {"token":"…"}; the phone keeps the token in localStorage.
    private func handlePair(_ fd: Int32, _ req: HTTPRequest) {
        let code = (try? JSONSerialization.jsonObject(with: Data(req.body)) as? [String: Any])?["code"] as? String
        switch codes.attempt(code ?? "") {
        case .ok:
            let label = Self.deviceLabel(req.header("user-agent") ?? "")
            let token = devices.pair(label: label)
            Self.log.notice("paired device \(label, privacy: .public)")
            json(fd, 200, "OK", ["token": token])
        case .rateLimited:
            Self.log.notice("pair rate-limited")
            json(fd, 429, "Too Many Requests", ["error": "Too many tries. Wait a minute."], extra: ["Retry-After": "60"])
        case .burned:
            Self.log.notice("pair code burned")
            json(fd, 401, "Unauthorized", ["error": "Code burned. Show a new one on the Mac."])
        case .wrong, .expired:
            Self.log.notice("pair wrong/expired code")
            json(fd, 401, "Unauthorized", ["error": "That code didn't work. Show a fresh one on the Mac."])
        }
    }

    /// Identity, Host and (where needed) Origin/token already passed.
    private func route(_ fd: Int32, _ req: HTTPRequest, device: UUID? = nil) {
        if req.method == "POST" && req.path == "/pair" { handlePair(fd, req); return }
        if req.path.hasPrefix("/api/browser") {
            if req.path == "/api/browser/stream", req.isWebSocketUpgrade {
                guard let key = req.header("sec-websocket-key") else { plain(fd, 400, "Bad Request", "Bad request"); return }
                streamBrowser(fd, key: key); return
            }
            guard device != nil else { plain(fd, 401, "Unauthorized", "Not paired"); return }
            handleBrowserTabs(fd, req); return
        }
        if req.path.hasPrefix("/api/sites") {
            guard device != nil else { plain(fd, 401, "Unauthorized", "Not paired"); return }
            handleSites(fd, req); return
        }
        if req.path.hasPrefix("/api/hub") || req.path.hasPrefix("/api/route") || req.path == "/api/run" || req.path == "/api/recent" {
            guard let device else { plain(fd, 401, "Unauthorized", "Not paired"); return }
            handleBar(fd, req, device: device); return
        }
        if req.path == "/api/tabs", req.method == "GET" {
            _ = send(fd, HTTPResponse.make(status: 200, reason: "OK", body: [UInt8](backend.tabsJSON()),
                                           contentType: "application/json")); return
        }
        if req.method == "POST", req.path.hasPrefix("/api/pane/"), req.path.hasSuffix("/input") { handlePaneInput(fd, req); return }
        if req.method == "POST", req.path == "/api/drop" { handleDrop(fd, req); return }
        if req.method == "POST", req.path == "/api/clip" { handleClip(fd, req); return }
        if req.method == "GET", req.path == "/api/shots" { handleShotsList(fd); return }
        if req.method == "GET", req.path.hasPrefix("/api/shots/") {
            let rest = String(req.path.dropFirst("/api/shots/".count))
            if rest.hasSuffix("/thumb") { handleShotThumb(fd, String(rest.dropLast("/thumb".count))) } else { handleShot(fd, rest) }
            return
        }
        if req.path == "/api/inbox", req.method == "GET" { handleInboxList(fd); return }
        if req.path.hasPrefix("/api/inbox/") {
            let id = String(req.path.dropFirst("/api/inbox/".count))
            if req.method == "GET" { handleInboxItem(fd, id); return }
            if req.method == "DELETE" { handleInboxDelete(fd, id); return }
        }
        if req.path.hasPrefix("/api/pane/"), req.isWebSocketUpgrade {
            guard let id = UUID(uuidString: String(req.path.dropFirst("/api/pane/".count))),
                  let key = req.header("sec-websocket-key") else {
                _ = send(fd, HTTPResponse.make(status: 400, reason: "Bad Request")); return
            }
            streamPane(fd, pane: id, key: key); return
        }
        // The web app itself is not secret; all data sits behind /api/* and the token.
        if req.method == "GET", !req.path.hasPrefix("/api/"), let asset = RemoteWebAssets.asset(req.path) {
            _ = send(fd, HTTPResponse.make(status: 200, reason: "OK", body: asset.body, contentType: asset.type)); return
        }
        _ = send(fd, HTTPResponse.make(status: 404, reason: "Not Found", body: Array("Not found".utf8)))
    }

    /// GET /api/sites[?refresh=1] · POST /api/sites/<port>/expose|unexpose
    private func handleSites(_ fd: Int32, _ req: HTTPRequest) {
        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        if req.method == "GET", path == "/api/sites" {
            let body = sites.listJSON(refresh: req.path.contains("refresh=1"))
            _ = send(fd, HTTPResponse.make(status: 200, reason: "OK", body: [UInt8](body), contentType: "application/json")); return
        }
        let parts = path.split(separator: "/").map(String.init)   // api sites <port> expose
        guard req.method == "POST", parts.count == 4, let port = Int(parts[2]), SitesLogic.isWebCandidate(port: port),
              parts[3] == "expose" || parts[3] == "unexpose" else { plain(fd, 404, "Not Found", "Not found"); return }
        let r = parts[3] == "expose" ? sites.expose(port: port) : sites.unexpose(port: port)
        json(fd, r.status, r.status == 200 ? "OK" : "Error", r.json)
    }

    // MARK: phone ↔ Mac files

    func plain(_ fd: Int32, _ status: Int, _ reason: String, _ msg: String) {
        _ = send(fd, HTTPResponse.make(status: status, reason: reason, body: Array(msg.utf8)))
    }

    /// POST /api/drop — raw body, name in `X-Filename`. Streamed to a temp file under one 120 s deadline.
    private func handleDrop(_ fd: Int32, _ req: HTTPRequest) {
        let len = req.declaredLength
        guard len > 0 else { plain(fd, len == 0 ? 400 : 411, len == 0 ? "Bad Request" : "Length Required", "Send a Content-Length"); return }
        guard len <= RemoteFiles.maxDropBytes else { plain(fd, 413, "Payload Too Large", "Over 200 MB"); return }
        lock.lock()
        let slot = activeDrops < Self.maxConcurrentDrops
        if slot { activeDrops += 1 }
        lock.unlock()
        guard slot else {
            _ = send(fd, HTTPResponse.make(status: 503, reason: "Service Unavailable", headers: ["Retry-After": "2"],
                                           body: Array("Busy, retry".utf8))); return
        }
        defer { lock.lock(); activeDrops -= 1; lock.unlock() }
        guard files.freeBytes(files.tmpDir) >= DropFS.minFreeBytes else {
            plain(fd, 507, "Insufficient Storage", "The Mac is almost out of disk space"); return
        }
        let name = DropName.sanitize(req.header("x-filename"))
        if (req.header("expect") ?? "").lowercased() == "100-continue" { _ = send(fd, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
        let tmp = files.newTemp(ext: DropName.safeExtension(name))
        switch DropReceiver.receive(fd, initial: req.body, total: len, deadline: dropDeadline, into: tmp) {
        case .ok: break
        case .timedOut: unlink(tmp.path); plain(fd, 408, "Request Timeout", "Too slow"); return
        case .closed: unlink(tmp.path); return
        case .ioError: unlink(tmp.path); plain(fd, 500, "Internal Server Error", "Could not write the file"); return
        }
        switch files.land(tmp: tmp, name: name) {
        case .shot(let id): json(fd, 200, "OK", ["ok": true, "where": "shots", "id": id])
        case .file(let url): json(fd, 200, "OK", ["ok": true, "where": "downloads", "name": url.lastPathComponent])
        case nil: plain(fd, 500, "Internal Server Error", "Could not save the file")
        }
    }

    /// POST /api/clip {"text"} (≤ 256 KB) → the Mac pasteboard.
    private func handleClip(_ fd: Int32, _ req: HTTPRequest) {
        let len = req.declaredLength
        guard len > 0 else { plain(fd, 400, "Bad Request", "Send JSON"); return }
        guard len <= 1024 * 1024 else { plain(fd, 413, "Payload Too Large", "Over 256 KB"); return }
        var body = Array(req.body.prefix(len))
        if DropReceiver.pump(fd, have: body.count, total: len, deadline: HTTPRequest.bodyDeadline, sink: { body += $0; return true }) != .ok {
            plain(fd, 408, "Request Timeout", "Too slow"); return
        }
        guard let text = (try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])?["text"] as? String,
              !text.isEmpty else { plain(fd, 400, "Bad Request", "Need {\"text\"}"); return }
        guard text.utf8.count <= RemoteFiles.maxClipBytes else { plain(fd, 413, "Payload Too Large", "Over 256 KB"); return }
        files.setClipboard(text)
        files.notify("Clipboard from iPhone")
        json(fd, 200, "OK", ["ok": true])
    }

    /// GET /api/shots — the tray, newest first. Nothing else about the Mac.
    private func handleShotsList(_ fd: Int32) {
        let rows: [[String: Any]] = files.tray().load().shots.map {
            ["id": $0.id, "created": ISO8601DateFormatter().string(from: $0.created), "kind": $0.kind.rawValue, "w": $0.width, "h": $0.height]
        }
        json(fd, 200, "OK", ["shots": rows])
    }

    /// `^\d{8}-\d{6}-[0-9a-f]{4}$` AND present in index.json. The id picks an index entry; it is never a path.
    static func validShotID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count == 20, u[8] == 45, u[15] == 45 else { return false }
        func digit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
        func hex(_ b: UInt8) -> Bool { digit(b) || (b >= 97 && b <= 102) }
        return u[0..<8].allSatisfy(digit) && u[9..<15].allSatisfy(digit) && u[16..<20].allSatisfy(hex)
    }

    private func handleShot(_ fd: Int32, _ id: String) {
        let store = files.tray()
        guard Self.validShotID(id), let e = store.load().shots.first(where: { $0.id == id }),
              e.file.hasPrefix("shots/"), !e.file.contains("..") else { plain(fd, 404, "Not Found", "Not found"); return }
        sendFile(fd, store.url(for: e), name: e.file.split(separator: "/").last.map(String.init) ?? id)
    }

    /// GET /api/shots/<id>/thumb — a 480 px JPEG (~30 KB) so the phone grid is not 21 full-size PNGs. Cached on disk.
    private func handleShotThumb(_ fd: Int32, _ id: String) {
        let store = files.tray()
        guard Self.validShotID(id), let e = store.load().shots.first(where: { $0.id == id }),
              e.file.hasPrefix("shots/"), !e.file.contains("..") else { plain(fd, 404, "Not Found", "Not found"); return }
        let dir = files.tmpDir.appendingPathComponent("thumbs", isDirectory: true)
        let cached = dir.appendingPathComponent(id + ".jpg")
        if !FileManager.default.fileExists(atPath: cached.path) {
            guard let src = CGImageSourceCreateWithURL(store.url(for: e) as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                  (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
                  let dest = CGImageDestinationCreateWithURL(cached as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { plain(fd, 404, "Not Found", "Not found"); return }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { plain(fd, 404, "Not Found", "Not found"); return }
        }
        sendFile(fd, cached, name: id + ".jpg")
    }

    private func handleInboxList(_ fd: Int32) {
        let rows: [[String: Any]] = files.inbox.list().map { i in
            var r: [String: Any] = ["id": i.id, "name": i.name, "kind": i.kind.rawValue, "size": i.size,
                                    "created": i.created.timeIntervalSince1970]
            if let src = i.source { r["source"] = src.rawValue }
            if i.kind == .text { r["preview"] = files.inbox.previewText(i.id) ?? "" }
            return r
        }
        json(fd, 200, "OK", ["items": rows])
    }

    private func handleInboxItem(_ fd: Int32, _ id: String) {
        guard let (item, url) = files.inbox.item(id) else { plain(fd, 404, "Not Found", "Not found"); return }
        sendFile(fd, url, name: item.name)
    }

    private func handleInboxDelete(_ fd: Int32, _ id: String) {
        files.inbox.delete(id) ? json(fd, 200, "OK", ["ok": true]) : plain(fd, 404, "Not Found", "Not found")
    }

    /// Stream a file the phone is allowed to see. Raster images get their image type; EVERYTHING else (SVG, HTML, PDF …)
    /// is an octet-stream attachment, and every file response adds `Content-Security-Policy: sandbox`, so nothing served
    /// from here can run script in this origin.
    func sendFile(_ fd: Int32, _ url: URL, name: String) {
        let ifd = Darwin.open(url.path, O_RDONLY)
        guard ifd >= 0 else { plain(fd, 404, "Not Found", "Not found"); return }
        defer { close(ifd) }
        var st = stat()
        guard fstat(ifd, &st) == 0 else { plain(fd, 404, "Not Found", "Not found"); return }
        var extra = ["Content-Security-Policy": "sandbox"]
        let image = DropName.imageContentType(forName: name)
        if image == nil { extra["Content-Disposition"] = DropName.attachment(name) }
        guard send(fd, HTTPResponse.head(status: 200, reason: "OK", headers: extra, length: Int(st.st_size),
                                         contentType: image ?? "application/octet-stream")) else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var left = Int(st.st_size)
        while left > 0 {
            let n = read(ifd, &buf, min(buf.count, left))
            if n <= 0 { return }
            if !send(fd, Array(buf[0..<n])) { return }
            left -= n
        }
    }

    /// First WebSocket message must be text `{"auth":"<token>"}` within 5 s, else close 4401 and no PTY bytes flow.
    func authenticateSocket(_ fd: Int32, _ dec: inout WebSocket.Decoder, _ pending: inout [WebSocket.Message]) -> PairedDevice? {
        let end = Date().addingTimeInterval(wsAuthTimeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while pending.isEmpty {
            let ms = Int32(max(0, end.timeIntervalSinceNow * 1000))
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard ms > 0, poll(&p, 1, ms) > 0 else { return nil }
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0, let msgs = try? dec.feed(Array(chunk[0..<n])) else { return nil }
            pending += msgs
        }
        let first = pending.removeFirst()
        guard first.op == .text,
              let tok = (try? JSONSerialization.jsonObject(with: Data(first.payload)) as? [String: Any])?["auth"] as? String,
              let dev = devices.validate(tok), dev.scope == .full else { return nil }
        return dev
    }

    // MARK: pane stream

    private func streamPane(_ fd: Int32, pane: UUID, key: String) {
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(WebSocket.acceptKey(for: key))\r\n\r\n"
        guard send(fd, Array(head.utf8)) else { return }
        var dec = WebSocket.Decoder()
        var pending: [WebSocket.Message] = []
        guard let authed = authenticateSocket(fd, &dec, &pending) else {
            Self.log.notice("ws auth failed")
            _ = send(fd, WebSocket.encode(.close, [0x11, 0x31]))   // 4401
            return
        }
        lock.lock(); socketDevices[fd] = authed.id; lock.unlock()
        defer { lock.lock(); socketDevices[fd] = nil; lock.unlock() }
        // Revoked between validate and registration → no disconnect would ever reach this fd.
        guard devices.all.contains(where: { $0.id == authed.id }) else { return }
        guard backend.snapshot(pane: pane) != nil else {
            _ = send(fd, WebSocket.encode(.text, Array(#"{"t":"gone"}"#.utf8)))
            _ = send(fd, WebSocket.encode(.close, [0x03, 0xE8])); return
        }
        Self.log.notice("ws open pane=\(pane.uuidString.prefix(8), privacy: .public)")
        let viewer = RemoteHub.shared.subscribe(pane)
        let sendLock = NSLock()
        let alive = OSAllocatedUnfairLock(initialState: true)
        @Sendable func out(_ op: WebSocket.Opcode, _ payload: [UInt8]) -> Bool {
            sendLock.lock(); defer { sendLock.unlock() }
            return send(fd, WebSocket.encode(op, payload))
        }
        let writer = Thread { [self] in
            while alive.withLock({ $0 }) && !viewer.closed && isRunning {
                switch viewer.take() {
                case .none:
                    if viewer.wake.wait(timeout: .now() + 20) == .timedOut { _ = out(.ping, []) }
                case .data(let d):
                    if !out(.binary, d) { shutdown(fd, SHUT_RDWR); return }
                case .snapshot:
                    guard let s = backend.snapshot(pane: pane) else {
                        _ = out(.text, Array(#"{"t":"gone"}"#.utf8)); shutdown(fd, SHUT_RDWR); return
                    }
                    let hello = #"{"t":"snap","cols":\#(s.cols),"rows":\#(s.rows)}"#
                    if !out(.text, Array(hello.utf8)) || !out(.binary, s.bytes) { shutdown(fd, SHUT_RDWR); return }
                }
            }
        }
        writer.start()
        // Reader: client input → PTY. No resize message exists; the Mac stays authoritative.
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 8192)
        readLoop: while isRunning {
            var msgs = pending; pending = []
            if msgs.isEmpty {
                let n = recv(fd, &chunk, chunk.count, 0)
                if n <= 0 { break }
                guard let got = try? dec.feed(Array(chunk[0..<n])) else { break }
                msgs = got
            }
            for m in msgs {
                switch m.op {
                case .close: _ = out(.close, []); break readLoop
                case .ping: _ = out(.pong, m.payload)
                case .binary, .text:
                    if !backend.input(pane: pane, bytes: m.payload) { break readLoop }
                default: break
                }
            }
        }
        alive.withLock { $0 = false }
        RemoteHub.shared.unsubscribe(viewer)
        Self.log.notice("ws close pane=\(pane.uuidString.prefix(8), privacy: .public)")
    }

    // MARK: small helpers

    static func parseForm(_ body: [UInt8]) -> [String: String] {
        var out: [String: String] = [:]
        for kv in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let p = kv.split(separator: "=", maxSplits: 1)
            guard p.count == 2 else { continue }
            out[String(p[0])] = String(p[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
        }
        return out
    }

    static func deviceLabel(_ ua: String) -> String {
        let kind = ua.contains("iPhone") ? "iPhone" : ua.contains("iPad") ? "iPad" : ua.contains("Android") ? "Android"
            : ua.contains("Macintosh") ? "Mac browser" : "Browser"
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        return "\(kind) · paired \(f.string(from: Date()))"
    }
}
