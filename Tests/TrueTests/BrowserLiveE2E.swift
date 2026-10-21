import Testing
import Foundation
@testable import True
import TrueRemoteClient

/// Real Chrome (separate profile) + a real RemoteServer socket. Runs only with TRUE_LIVE_E2E=1.
@Suite("Browser live", .enabled(if: ProcessInfo.processInfo.environment["TRUE_LIVE_E2E"] == "1"))
struct BrowserLiveE2E {
    static let dns = "mac.test.ts.net"
    struct Stub: RemoteBackend {
        func tabsJSON() -> Data { Data(#"{"tabs":[]}"#.utf8) }
        func snapshot(pane: UUID) -> (cols: Int, rows: Int, bytes: [UInt8])? { nil }
        func input(pane: UUID, bytes: [UInt8]) -> Bool { true }
    }

    final class WS {
        let fd: Int32; var buf: [UInt8] = []
        init(port: UInt16) {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var a = RemoteServer.loopbackAddress(port: port)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let h = "GET /api/browser/stream HTTP/1.1\r\nHost: \(BrowserLiveE2E.dns):8444\r\nTailscale-User-Login: me@x\r\nOrigin: https://\(BrowserLiveE2E.dns):8444\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
            let raw = Array(h.utf8); _ = Darwin.send(fd, raw, raw.count, 0)
            // Like a browser: first frame only after the 101 head.
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !String(decoding: buf, as: UTF8.self).contains("\r\n\r\n") {
                let n = recv(fd, &chunk, chunk.count, 0); if n <= 0 { break }; buf += chunk[0..<n]
            }
        }
        deinit { close(fd) }
        func sendText(_ s: String) {
            let p = Array(s.utf8); let mask: [UInt8] = [1, 2, 3, 4]
            var f: [UInt8] = [0x81]
            if p.count < 126 { f.append(0x80 | UInt8(p.count)) } else { f.append(0x80 | 126); f += [UInt8(p.count >> 8), UInt8(p.count & 255)] }
            f += mask; f += p.enumerated().map { $0.element ^ mask[$0.offset % 4] }
            _ = Darwin.send(fd, f, f.count, 0)
        }
        /// Next server frame (op, payload); nil on timeout. Skips the HTTP 101 head first.
        func next() -> (op: UInt8, payload: [UInt8])? {
            if let r = String(decoding: buf, as: UTF8.self).range(of: "\r\n\r\n"), buf.starts(with: Array("HTTP/".utf8)) {
                buf.removeFirst(String(decoding: buf, as: UTF8.self)[..<r.upperBound].utf8.count)
            }
            while true {
                if !buf.starts(with: Array("HTTP/".utf8)), buf.count >= 2 {
                    var len = Int(buf[1] & 0x7f), off = 2
                    if len == 126, buf.count >= 4 { len = Int(buf[2]) << 8 | Int(buf[3]); off = 4 }
                    else if len == 127, buf.count >= 10 { len = buf[2..<10].reduce(0) { $0 << 8 | Int($1) }; off = 10 }
                    else if len >= 126 { len = -1 }
                    if len >= 0, buf.count >= off + len {
                        let r = (buf[0] & 0x0f, Array(buf[off..<(off + len)])); buf.removeFirst(off + len); return r
                    }
                }
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = recv(fd, &chunk, chunk.count, 0)
                if n <= 0 { return nil }
                buf += chunk[0..<n]
                if buf.starts(with: Array("HTTP/".utf8)), let r = String(decoding: buf, as: UTF8.self).range(of: "\r\n\r\n") {
                    buf.removeFirst(String(decoding: buf, as: UTF8.self)[..<r.upperBound].utf8.count)
                }
            }
        }
    }

    @Test func streamTapTypeChangesThePage() throws {
        var log: [String] = []
        func say(_ s: String) { print("E2E \(s)"); log.append(s) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("browser-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        <html><head><title>E2E page</title><meta name=viewport content="width=device-width"></head>
        <body style="margin:0"><button id=b style="position:fixed;left:20px;top:100px;width:200px;height:100px" onclick="document.title='clicked'">Tap me</button>
        <input id=i style="position:fixed;left:20px;top:300px;width:340px;height:60px;font-size:24px">
        <div id=c style="position:fixed;left:0;top:500px;width:100%;height:200px"></div>
        <script>let n=0;setInterval(()=>{document.getElementById('c').style.background='hsl('+(n+=15)+',80%,50%)'},120)</script></body></html>
        """.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let py = Process(); py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        py.arguments = ["-m", "http.server", "8765", "--bind", "127.0.0.1"]; py.currentDirectoryURL = dir
        py.standardOutput = FileHandle.nullDevice; py.standardError = FileHandle.nullDevice
        try py.run(); defer { py.terminate() }
        for _ in 0..<50 where SiteHTTP.fetch(URL(string: "http://127.0.0.1:8765/")!, method: "HEAD", timeout: 0.3, maxBytes: 1) == nil { Thread.sleep(forTimeInterval: 0.2) }

        let devices = DeviceStore(url: dir.appendingPathComponent("d.json"))
        let token = devices.pair(label: "E2E phone")
        let hub = BrowserHub.shared
        let s = RemoteServer(backend: Stub(), codes: PairingCodes(), devices: devices, allowedLogin: { "me@x" },
                             dnsName: { Self.dns }, browser: hub)
        #expect(s.start(port: 18831)); defer { s.stop() }

        let ws = WS(port: 18831)
        ws.sendText(#"{"auth":"\#(token)"}"#)
        ws.sendText(#"{"t":"viewport","w":390,"h":844,"scale":2}"#)
        ws.sendText(#"{"t":"nav","url":"http://127.0.0.1:8765"}"#)
        say("sent auth + viewport 390x844@2 + nav http://127.0.0.1:8765")
        var frames = 0, texts = 0, bytes = 0, lastHeader = ""
        func pump(seconds: Double, until: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !until() {
                guard let m = ws.next() else { continue }
                if m.op == 2, let f = BrowserWire.decodeFrame(Data(m.payload)) { frames += 1; bytes += f.jpeg.count; lastHeader = "\(f.header)" }
                else if m.op != 1 { print("E2E op", m.op, m.payload) }
                else if m.op == 1 { texts += 1; if texts <= 3 { say("text: \(String(decoding: m.payload.prefix(160), as: UTF8.self))") } }
            }
        }
        var title = ""
        for _ in 0..<40 { pump(seconds: 0.5); title = hub.evaluate("document.title") ?? ""; if title == "E2E page" { break } }
        say("page loaded in True Chrome: document.title = \(title)")
        #expect(title == "E2E page")
        pump(seconds: 3)
        say("frames so far: \(frames) (\(bytes / max(1, frames)) bytes avg) last header \(lastHeader)")
        #expect(frames >= 10)

        ws.sendText(#"{"t":"tap","x":\#(120.0 / 390),"y":\#(150.0 / 844)}"#)
        var after = ""
        for _ in 0..<20 { pump(seconds: 0.3); after = hub.evaluate("document.title") ?? ""; if after == "clicked" { break } }
        say("after tap on button: document.title = \(after)")
        #expect(after == "clicked")

        ws.sendText(#"{"t":"tap","x":\#(190.0 / 390),"y":\#(330.0 / 844)}"#)
        pump(seconds: 0.6)
        ws.sendText(#"{"t":"text","text":"hello phone"}"#)
        var typed = ""
        for _ in 0..<20 { pump(seconds: 0.3); typed = hub.evaluate("document.getElementById('i').value") ?? ""; if typed == "hello phone" { break } }
        say("after tap on input + text: input.value = \(typed)")
        #expect(typed == "hello phone")
        let mobile = hub.evaluate("innerWidth + 'x' + innerHeight + ' touch=' + ('ontouchstart' in window)") ?? ""
        say("emulated viewport: \(mobile)")
        say("total frames \(frames), texts \(texts)")
        close(ws.fd)
        Thread.sleep(forTimeInterval: 0.5)
    }
}
