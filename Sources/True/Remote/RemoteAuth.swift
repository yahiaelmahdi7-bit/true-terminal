import Foundation
import CryptoKit
import Security

/// Remote Access auth: independent checks (loopback bind, tailnet identity header, exact Host/Origin, paired-device
/// bearer token). The token lives in the phone's localStorage and travels in `Authorization` / the first WebSocket
/// message — never a cookie (cookies ignore ports, so they would also go to other services on the same hostname).
/// All pure or injectable so the decision table is unit-tested without a socket.
enum RemoteAuth {
    static let loginHeader = "Tailscale-User-Login"
    static let httpsPort = 8444

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 32 random bytes, hex. The raw token only ever exists in the phone's localStorage.
    static func newToken() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        let rc = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        precondition(rc == errSecSuccess, "no secure randomness")
        return b.map { String(format: "%02x", $0) }.joined()
    }

    enum Decision: Equatable {
        case allow
        case forbidden(String)      // 403 — wrong network identity, host or origin
        case needsPairing           // 401 — no/bad/revoked bearer token
    }

    /// Decision table, in order: identity header (403 beats everything), exact Host, exact Origin (state-changing
    /// requests and the WS upgrade), then the bearer token where the route needs one.
    static func decide(loginHeader: String?, allowedLogin: String?, host: String?, origin: String?, dnsName: String?,
                       requiresOrigin: Bool, requiresToken: Bool, tokenValid: Bool) -> Decision {
        guard let allowed = allowedLogin?.lowercased(), !allowed.isEmpty else { return .forbidden("no allowed login configured") }
        guard let login = loginHeader?.lowercased(), !login.isEmpty else { return .forbidden("missing tailscale login") }
        guard login == allowed else { return .forbidden("login not allowed") }
        guard hostMatches(host: host, dnsName: dnsName) else { return .forbidden("host mismatch") }
        if requiresOrigin, !originMatches(origin: origin, dnsName: dnsName) { return .forbidden("origin mismatch") }
        if requiresToken, !tokenValid { return .needsPairing }
        return .allow
    }

    private static func clean(_ dns: String?) -> String? {
        guard var d = dns?.lowercased(), !d.isEmpty else { return nil }
        if d.hasSuffix(".") { d.removeLast() }
        return d.isEmpty ? nil : d
    }

    /// `Host` must be `<dnsName>:8444` or `<dnsName>` — anything else (a rebound attacker domain) is refused.
    static func hostMatches(host: String?, dnsName: String?) -> Bool {
        guard let d = clean(dnsName), let h = host?.lowercased() else { return false }
        return h == d || h == "\(d):\(httpsPort)"
    }

    /// `Origin` must be exactly `https://<dnsName>:8444` (scheme + host + port).
    static func originMatches(origin: String?, dnsName: String?) -> Bool {
        guard let d = clean(dnsName), let o = origin else { return false }
        return o == "https://\(d):\(httpsPort)"
    }

    static func bearerToken(_ authorization: String?) -> String? {
        guard let a = authorization, a.hasPrefix("Bearer ") else { return nil }
        let t = String(a.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}

/// The 6-digit pairing code: fresh each time it is shown, valid 5 minutes, single use, ≤5 guesses a minute,
/// and burned outright after 5 wrong guesses (a new code must be shown on the Mac).
final class PairingCodes: @unchecked Sendable {
    enum Outcome: Equatable { case ok, wrong, burned, expired, rateLimited }
    static let maxWrong = 5
    static let lifetime: TimeInterval = 300
    static let maxAttemptsPerMinute = 5

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var code: String?
    private var issuedAt = Date.distantPast
    private var attempts: [Date] = []
    private var wrong = 0
    private var burnedFlag = false

    init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    /// A new code replaces any old one.
    @discardableResult
    func issue() -> String {
        lock.lock(); defer { lock.unlock() }
        var v: UInt32 = 0
        let rc = withUnsafeMutableBytes(of: &v) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        precondition(rc == errSecSuccess, "SecRandomCopyBytes failed")
        let c = String(format: "%06d", Int(v % 1_000_000))
        code = c; issuedAt = now(); wrong = 0; burnedFlag = false
        return c
    }

    func expiry() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return code == nil ? nil : issuedAt.addingTimeInterval(Self.lifetime)
    }

    func revokeCode() { lock.lock(); code = nil; burnedFlag = false; lock.unlock() }

    /// True after 5 wrong guesses killed the current code (shown in the Mac sheet).
    var isBurned: Bool { lock.lock(); defer { lock.unlock() }; return burnedFlag }

    func attempt(_ guess: String) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        attempts = attempts.filter { t.timeIntervalSince($0) < 60 }
        guard attempts.count < Self.maxAttemptsPerMinute else { return .rateLimited }
        attempts.append(t)
        guard let c = code else { return .expired }
        guard t.timeIntervalSince(issuedAt) <= Self.lifetime else { code = nil; return .expired }
        guard guess == c else {
            wrong += 1
            if wrong >= Self.maxWrong { code = nil; burnedFlag = true; return .burned }
            return .wrong
        }
        code = nil
        return .ok
    }
}

struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var label: String
    var tokenHash: String
    var created: Date
    var lastSeen: Date
    var scope: Scope = .full

    /// `dropOnly` (the iOS Shortcut token) may only POST /api/drop and /api/clip.
    enum Scope: String, Codable, Sendable { case full, dropOnly }

    init(id: UUID, label: String, tokenHash: String, created: Date, lastSeen: Date, scope: Scope = .full) {
        self.id = id; self.label = label; self.tokenHash = tokenHash
        self.created = created; self.lastSeen = lastSeen; self.scope = scope
    }

    /// A missing `scope` key (devices paired before scopes existed) decodes as `full`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        tokenHash = try c.decode(String.self, forKey: .tokenHash)
        created = try c.decode(Date.self, forKey: .created)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .full
    }
}

/// Paired phones, hashed at rest in Application Support (mode 0600). Raw tokens are never stored.
final class DeviceStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var devices: [PairedDevice]

    static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("True/remote-devices.json")
    }

    init(url: URL = DeviceStore.standardURL) {
        self.url = url
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        devices = (try? Data(contentsOf: url)).flatMap { try? dec.decode([PairedDevice].self, from: $0) } ?? []
    }

    var all: [PairedDevice] { lock.lock(); defer { lock.unlock() }; return devices }

    /// Register a new device; returns the raw token to hand to the phone exactly once.
    func pair(label: String, scope: PairedDevice.Scope = .full, at date: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        let token = RemoteAuth.newToken()
        devices.append(PairedDevice(id: UUID(), label: label, tokenHash: RemoteAuth.sha256Hex(token),
                                    created: date, lastSeen: date, scope: scope))
        save()
        return token
    }

    /// Match a presented token by hash; touches last-seen (at most once a minute, to spare the disk).
    func validate(_ token: String?, at date: Date = Date()) -> PairedDevice? {
        guard let token, !token.isEmpty else { return nil }
        let h = RemoteAuth.sha256Hex(token)
        lock.lock(); defer { lock.unlock() }
        guard let i = devices.firstIndex(where: { $0.tokenHash == h }) else { return nil }
        if date.timeIntervalSince(devices[i].lastSeen) > 60 { devices[i].lastSeen = date; save() }
        return devices[i]
    }

    func revoke(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        devices.removeAll { $0.id == id }
        save()
    }

    /// Written to a fresh 0600 temp file (created with the mode, never chmod-ed after) and renamed into place;
    /// the parent directory is 0700.
    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(devices) else { return }
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmp = dir.appendingPathComponent(".remote-devices-\(UUID().uuidString).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        close(fd)
        if ok, rename(tmp, url.path) == 0 { return }
        unlink(tmp)
    }
}
