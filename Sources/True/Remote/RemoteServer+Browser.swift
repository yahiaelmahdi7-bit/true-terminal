import Foundation
import os

/// The phone browser's doors: WS /api/browser/stream (frames Mac→phone, input phone→Mac) and the tab list/actions.
extension RemoteServer {
    /// GET /api/browser/tabs → {enabled,running,tabs,canBack,canForward} · POST {action:new|close|select,url?,id?}
    func handleBrowserTabs(_ fd: Int32, _ req: HTTPRequest) {
        guard req.path == "/api/browser/tabs" else { plain(fd, 404, "Not Found", "Not found"); return }
        guard browser.enabled else { json(fd, 403, "Forbidden", ["error": "Phone browser is off on the Mac", "enabled": false]); return }
        if req.method == "GET" {
            let body = (browser as? BrowserHub)?.tabsJSONConnecting() ?? browser.tabsJSON()
            _ = send(fd, HTTPResponse.make(status: 200, reason: "OK", body: [UInt8](body), contentType: "application/json")); return
        }
        guard req.method == "POST" else { plain(fd, 405, "Method Not Allowed", "No"); return }
        let len = req.declaredLength
        guard len > 0, len <= 8192 else { json(fd, 400, "Bad Request", ["error": "Send JSON"]); return }
        var body = Array(req.body.prefix(len))
        if DropReceiver.pump(fd, have: body.count, total: len, deadline: HTTPRequest.bodyDeadline, sink: { body += $0; return true }) != .ok {
            json(fd, 408, "Request Timeout", ["error": "Too slow"]); return
        }
        guard let o = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any], let action = o["action"] as? String else {
            json(fd, 400, "Bad Request", ["error": "Need {action}"]); return
        }
        var msg: [String: Any] = ["t": "tab." + action]
        if let u = o["url"] { msg["url"] = u }
        if let i = o["id"] { msg["id"] = i }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let cmd = BrowserCommand.parse(String(decoding: data, as: UTF8.self)) else { json(fd, 400, "Bad Request", ["error": "Bad action"]); return }
        if let hub = browser as? BrowserHub { hub.handleSync(cmd) } else { browser.handle(cmd) }
        json(fd, 200, "OK", ["ok": true])
    }

    func streamBrowser(_ fd: Int32, key: String) {
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(WebSocket.acceptKey(for: key))\r\n\r\n"
        guard send(fd, Array(head.utf8)) else { return }
        var dec = WebSocket.Decoder()
        var pending: [WebSocket.Message] = []
        guard let authed = authenticateSocket(fd, &dec, &pending) else {
            _ = send(fd, WebSocket.encode(.close, [0x11, 0x31])); return   // 4401
        }
        lock.lock(); socketDevices[fd] = authed.id; lock.unlock()
        defer { lock.lock(); socketDevices[fd] = nil; lock.unlock() }
        guard devices.all.contains(where: { $0.id == authed.id }) else { return }
        guard let viewer = browser.addViewer() else {
            _ = send(fd, WebSocket.encode(.text, Array(#"{"t":"off"}"#.utf8)))
            _ = send(fd, WebSocket.encode(.close, [0x03, 0xE8])); return
        }
        let sendLock = NSLock()
        let alive = OSAllocatedUnfairLock(initialState: true)
        @Sendable func out(_ op: WebSocket.Opcode, _ payload: [UInt8]) -> Bool {
            sendLock.lock(); defer { sendLock.unlock() }
            return send(fd, WebSocket.encode(op, payload))
        }
        let writer = Thread { [self] in
            while alive.withLock({ $0 }) && isRunning && browser.enabled {
                for t in viewer.takeTexts() { if !out(.text, Array(t.utf8)) { shutdown(fd, SHUT_RDWR); return } }
                if let f = viewer.frames.take() {
                    if !out(.binary, [UInt8](f)) { shutdown(fd, SHUT_RDWR); return }
                    continue
                }
                if viewer.wake.wait(timeout: .now() + 20) == .timedOut { _ = out(.ping, []) }
            }
        }
        writer.start()
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 8192)
        readLoop: while isRunning && browser.enabled {
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
                case .text:
                    if let c = BrowserCommand.parse(String(decoding: m.payload, as: UTF8.self)) { browser.handle(c) }
                default: break
                }
            }
        }
        alive.withLock { $0 = false }
        viewer.wake.signal()
        browser.removeViewer(viewer)
    }
}
