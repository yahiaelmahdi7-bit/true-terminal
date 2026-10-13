import Foundation

/// A parsed HTTP/1.1 request head (we never accept request bodies beyond a small JSON POST).
struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]      // lower-cased names
    var body: [UInt8] = []
    /// Routes that read their own (large) body after auth: the head is parsed alone; `body` holds whatever already arrived.
    var streamsBody = false
    var declaredLength = 0

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var isWebSocketUpgrade: Bool {
        (header("upgrade") ?? "").lowercased() == "websocket"
            && (header("connection") ?? "").lowercased().contains("upgrade")
    }

    enum ParseResult: Equatable { case needMore, bad, request(HTTPRequest, consumed: Int) }

    static let maxHead = 16 * 1024
    static let bodyDeadline: TimeInterval = 10
    static let maxBody = 4 * 1024
    /// POST routes whose body is read after authentication, under their own caps (drop 200 MB streamed, clip 1 MB).
    static let bodyRoutes: Set<String> = ["/api/drop", "/api/clip"]
    /// The pane composer posts whole prompts (≤ 64 KB), so it streams too.
    static func isBodyRoute(_ path: String) -> Bool {
        bodyRoutes.contains(path) || (path.hasPrefix("/api/pane/") && path.hasSuffix("/input"))
    }
    static let singletonHeaders: Set<String> = ["tailscale-user-login", "host", "origin", "authorization"]

    /// Parse as much of `bytes` as forms one request. `.needMore` until the head (and any body) is complete.
    static func parse(_ bytes: [UInt8]) -> ParseResult {
        let sep: [UInt8] = [13, 10, 13, 10]
        guard let end = find(sep, in: bytes) else { return bytes.count > maxHead ? .bad : .needMore }
        guard end <= maxHead, let head = String(bytes: bytes[0..<end], encoding: .utf8) else { return .bad }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .bad }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { return .bad }
            let name = l[..<c].lowercased()
            // A second copy of a security-relevant header is how proxies and servers disagree about who is asking.
            if singletonHeaders.contains(name), headers[name] != nil { return .bad }
            headers[name] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(first[1])
        let comps = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if comps.count == 2 {
            for kv in comps[1].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1)
                query[String(p[0]).removingPercentEncoding ?? String(p[0])] =
                    p.count == 2 ? (String(p[1]).removingPercentEncoding ?? String(p[1])) : ""
            }
        }
        if first[0] == "POST", isBodyRoute(String(comps[0])) {
            let len = headers["transfer-encoding"] == nil ? (headers["content-length"].flatMap { Int($0) } ?? -1) : -1
            let have = Array(bytes[(end + 4)...].prefix(max(len, 0)))
            var r = HTTPRequest(method: String(first[0]), path: String(comps[0]), query: query, headers: headers, body: have)
            r.streamsBody = true; r.declaredLength = len
            return .request(r, consumed: end + 4 + have.count)
        }
        let bodyLen = Int(headers["content-length"] ?? "0") ?? -1
        guard bodyLen >= 0, bodyLen <= maxBody else { return .bad }
        let total = end + 4 + bodyLen
        guard bytes.count >= total else { return .needMore }
        let req = HTTPRequest(method: String(first[0]), path: String(comps[0]), query: query, headers: headers,
                              body: Array(bytes[(end + 4)..<total]))
        return .request(req, consumed: total)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<i + needle.count]) == needle { return i }
        return nil
    }
}

enum HTTPResponse {
    /// Every response carries the same hardening headers; `Cache-Control: no-store` is on all of them (a superset of /api/*).
    static let csp = "default-src 'self'; img-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; object-src 'none'; style-src 'self' 'unsafe-inline'"

    static func make(status: Int, reason: String, headers: [String: String] = [:], body: [UInt8] = [],
                     contentType: String = "text/plain; charset=utf-8") -> [UInt8] {
        head(status: status, reason: reason, headers: headers, length: body.count, contentType: contentType) + body
    }

    /// Status line + headers only (file responses stream the body after it).
    static func head(status: Int, reason: String, headers: [String: String] = [:], length: Int,
                     contentType: String) -> [UInt8] {
        var h = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\n"
        h += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        h += "X-Frame-Options: DENY\r\nContent-Security-Policy: \(csp)\r\nConnection: close\r\n"
        for (k, v) in headers { h += "\(k): \(v)\r\n" }
        return Array((h + "\r\n").utf8)
    }
}
