import Foundation
import Darwin

/// Starts (or finds) "True Chrome": a Chrome with its OWN profile and a loopback-only debugging port. The user's real
/// Chrome profile is never touched, and the debugging port is never exposed — only True's authenticated API is.
enum ChromeLauncher {
    static var profileDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("True/BrowserProfile", isDirectory: true)
    }

    static var executable: String? {
        let paths = ["/Applications/Chromium.app/Contents/MacOS/Chromium",
                     NSHomeDirectory() + "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
                     "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
                     "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A free TCP port on 127.0.0.1 (bind to 0, read it back, release).
    static func freeLoopbackPort() -> Int? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        return got == 0 ? Int(UInt16(bigEndian: a.sin_port)) : nil
    }

    /// The browser-level DevTools WebSocket of a live True Chrome, if one already runs on this profile.
    static func runningEndpoint() -> (port: Int, ws: String)? {
        let file = profileDir.appendingPathComponent("DevToolsActivePort")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let port = text.split(separator: "\n").first.flatMap({ Int($0) }) else { return nil }
        return version(port: port).map { (port, $0) }
    }

    static func version(port: Int) -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version"),
              let r = SiteHTTP.fetch(url, timeout: 1.5, maxBytes: 64 * 1024), r.status == 200,
              let o = (try? JSONSerialization.jsonObject(with: Data(r.body.utf8))) as? [String: Any] else { return nil }
        return o["webSocketDebuggerUrl"] as? String
    }

    private static let lock = NSLock()

    /// Browser WebSocket URL, launching True Chrome first when needed. Blocks up to ~15 s; call off the main thread.
    static func ensureRunning(url: String? = nil) -> (port: Int, ws: String)? {
        lock.lock(); defer { lock.unlock() }
        if let e = runningEndpoint() { return e }
        guard let exe = executable, let port = freeLoopbackPort() else { return nil }
        try? FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: profileDir.appendingPathComponent("DevToolsActivePort"))
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe)
        var args = ["--user-data-dir=\(profileDir.path)", "--remote-debugging-port=\(port)", "--remote-debugging-address=127.0.0.1",
                    "--no-first-run", "--no-default-browser-check"]
        if let url { args.append(url) }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        for _ in 0..<60 {
            if let ws = version(port: port) { return (port, ws) }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    /// Settings button: bring up True Chrome so the user can sign in to sites once in this profile.
    static func openForSignIn() {
        DispatchQueue.global().async { _ = ensureRunning(url: "about:blank") }
    }
}
