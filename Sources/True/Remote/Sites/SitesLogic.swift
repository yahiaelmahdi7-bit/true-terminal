import Foundation

/// Pure rules for "Sites": which listening ports are a dev web server a pane started, which Tailscale port to
/// expose it on, and when a framework is refusing the `*.ts.net` Host header. No process, socket or UI here.
enum SitesLogic {
    /// Databases, caches and debuggers listen on TCP but are not something a browser should open.
    static let nonWebPorts: Set<Int> = [5432, 6379, 27017, 3306, 9229]
    /// Ports True's own phone surfaces and the existing serve entries use. Never offered, never allocated.
    static let reservedPorts: Set<Int> = [443, 8444, 8800, 8801]
    static let allocationRange = 8450...8499

    static func isWebCandidate(port: Int) -> Bool {
        port >= 1024 && port <= 65535 && !nonWebPorts.contains(port) && !reservedPorts.contains(port)
    }

    struct Listener: Equatable { var pid: Int32; var command: String; var port: Int }

    /// `lsof -nP -iTCP -sTCP:LISTEN -F pcn` → one Listener per (pid, port). Fields: `p<pid>`, `c<command>`, `n<addr:port>`.
    /// Only loopback / wildcard binds count (a server bound to another interface is not what a phone proxy can reach).
    static func parseLsof(_ out: String) -> [Listener] {
        var pid: Int32 = 0, cmd = ""
        var seen = Set<String>(), result: [Listener] = []
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let v = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(v) ?? 0; cmd = ""
            case "c": cmd = v
            case "n":
                guard pid > 0, let colon = v.lastIndex(of: ":"), let port = Int(v[v.index(after: colon)...]) else { continue }
                let host = String(v[..<colon])
                guard ["*", "127.0.0.1", "[::1]", "[::]", "localhost"].contains(host) else { continue }
                if seen.insert("\(pid):\(port)").inserted { result.append(Listener(pid: pid, command: cmd, port: port)) }
            default: break
            }
        }
        return result
    }

    /// `ps -axo pid=,ppid=` → [pid: ppid].
    static func parsePs(_ out: String) -> [Int32: Int32] {
        var m: [Int32: Int32] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count >= 2, let p = Int32(f[0]), let pp = Int32(f[1]) { m[p] = pp }
        }
        return m
    }

    /// Every pid whose ancestor chain reaches `root` (root excluded). Cycle-safe.
    static func descendants(of root: Int32, parents: [Int32: Int32]) -> Set<Int32> {
        var out = Set<Int32>()
        for pid in parents.keys {
            var cur = pid, hops = 0
            while let pp = parents[cur], hops < 64 {
                if pp == root { out.insert(pid); break }
                if pp <= 1 || pp == cur { break }
                cur = pp; hops += 1
            }
        }
        return out
    }

    /// Which pane (by shell pid) owns each listener. Listeners with no pane ancestor are dropped.
    static func attribute(listeners: [Listener], shells: [UUID: Int32], parents: [Int32: Int32]) -> [(listener: Listener, pane: UUID)] {
        var out: [(Listener, UUID)] = []
        let trees = shells.mapValues { descendants(of: $0, parents: parents).union([$0]) }
        for l in listeners {
            guard isWebCandidate(port: l.port) else { continue }
            if let hit = trees.first(where: { $0.value.contains(l.pid) }) { out.append((l, hit.key)) }
        }
        return out
    }

    /// Same port if free; else the next free port in 8450-8499. `taken` = every port already in `tailscale serve`
    /// (True's and foreign alike). nil = nothing free.
    static func allocate(preferred: Int, taken: Set<Int>) -> Int? {
        let blocked = taken.union(reservedPorts)
        if !blocked.contains(preferred) && preferred >= 1024 { return preferred }
        return allocationRange.first { !blocked.contains($0) }
    }

    /// Ports of the `Web` entries in `tailscale serve status --json` (keys look like `host.ts.net:8444`).
    static func servePorts(fromStatus data: Data) -> Set<Int> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var ports = Set<Int>()
        for key in (root["Web"] as? [String: Any] ?? [:]).keys { if let p = key.split(separator: ":").last.flatMap({ Int($0) }) { ports.insert(p) } }
        for key in (root["TCP"] as? [String: Any] ?? [:]).keys { if let p = Int(key) { ports.insert(p) } }
        return ports
    }

    /// `<title>…</title>`, whitespace-collapsed, ≤ 80 chars.
    static func title(fromHTML html: String) -> String? {
        guard let a = html.range(of: "<title", options: .caseInsensitive),
              let open = html.range(of: ">", range: a.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex) else { return nil }
        let t = html[open.upperBound..<close.lowerBound].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.isEmpty ? nil : String(t.prefix(80))
    }

    struct HostFix: Equatable { var framework: String; var snippet: String }

    /// A dev server that answers the tailnet Host header with its own "blocked host" page.
    static func blockedHostFix(status: Int, body: String) -> HostFix? {
        let b = body.lowercased()
        if b.contains("blocked request") || b.contains("allowedhosts") || b.contains("is not allowed") && b.contains("host") {
            return HostFix(framework: "Vite", snippet: "server: { allowedHosts: ['.ts.net'] }")
        }
        if b.contains("allowedorigins") || b.contains("alloweddevorigins") || b.contains("cross origin request detected") {
            return HostFix(framework: "Next.js", snippet: "allowedDevOrigins: ['*.ts.net']")
        }
        if status == 403 && (b.contains("invalid host header") || b.contains("host not allowed")) {
            return HostFix(framework: "webpack-dev-server", snippet: "devServer: { allowedHosts: ['.ts.net'] }")
        }
        return nil
    }
}

/// What the app support file remembers: only the mappings True itself created, so cleanup can never remove a foreign entry.
struct SiteOwnership: Codable, Equatable {
    var mappings: [Int: Int] = [:]   // local dev port → tailscale https port True opened for it

    /// Mappings to tear down now: owned, and either the server is gone or its pane closed.
    func stale(livePorts: Set<Int>) -> [Int] { mappings.filter { !livePorts.contains($0.key) }.map(\.key).sorted() }
    /// A `tailscale serve --https=<p> off` is allowed only for ports True owns.
    func mayRemove(servePort: Int) -> Bool { mappings.values.contains(servePort) }
}
