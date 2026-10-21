import Foundation

/// Blocking helpers for the Sites feature: a tiny HTTP fetch that stops reading after `maxBytes`, and a process runner.
enum SiteHTTP {
    private final class Reader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let maxBytes: Int
        var status = 0
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        init(maxBytes: Int) { self.maxBytes = maxBytes }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive r: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (r as? HTTPURLResponse)?.statusCode ?? 0
            completionHandler(.allow)
        }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive d: Data) {
            data.append(d)
            if data.count >= maxBytes { dataTask.cancel() }
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { done.signal() }
    }

    /// nil = no HTTP answer at all (refused / timed out / not HTTP). Any status code counts as an answer.
    static func fetch(_ url: URL, method: String = "GET", timeout: TimeInterval, maxBytes: Int = 4096) -> (status: Int, body: String)? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        let reader = Reader(maxBytes: maxBytes)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout; cfg.timeoutIntervalForResource = timeout
        cfg.connectionProxyDictionary = [:]   // never route localhost / tailnet probes through a system proxy
        let session = URLSession(configuration: cfg, delegate: reader, delegateQueue: nil)
        session.dataTask(with: req).resume()
        _ = reader.done.wait(timeout: .now() + timeout + 0.5)
        session.invalidateAndCancel()
        guard reader.status > 0 else { return nil }
        return (reader.status, String(decoding: reader.data, as: UTF8.self))
    }

    /// Run a tool to completion; nil on launch failure, non-zero exit or timeout. stderr is dropped.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 10) -> Data? {
        Subprocess.run(exe, args, timeout: timeout)
    }

    /// GET / straight from the loopback socket with an arbitrary Host header — exactly what a dev server sees when
    /// `tailscale serve` proxies a phone request. (A Mac cannot open its own *.ts.net URL, so this is how the
    /// "blocked host" check is done.) nil = no HTTP answer.
    static func rawGet(port: Int, host: String, timeout: TimeInterval = 2, maxBytes: Int = 8192) -> (status: Int, body: String)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var a = RemoteServer.loopbackAddress(port: UInt16(truncatingIfNeeded: port))
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } == 0 }
        guard ok else { return nil }
        let req = "GET / HTTP/1.1\r\nHost: \(host)\r\nAccept: text/html\r\nConnection: close\r\n\r\n"
        guard Darwin.send(fd, Array(req.utf8), req.utf8.count, 0) > 0 else { return nil }
        var buf: [UInt8] = [], chunk = [UInt8](repeating: 0, count: 4096)
        while buf.count < maxBytes {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buf += chunk[0..<n]
        }
        let text = String(decoding: buf, as: UTF8.self)
        guard text.hasPrefix("HTTP/"), let code = text.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap({ Int($0) }) else { return nil }
        return (code, text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? "")
    }
}
