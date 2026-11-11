import Foundation
import CryptoKit

/// the receiving Mac's copy of Steward's grant snapshot, and the rules that turn it into "this peer job may run".
/// Pure rule code, no model. Network lives behind `GrantTransport`; time and files are injected so tests need no sleeps.

/// Steward's `GET /grants/snapshot`, as the Mac keeps it in `~/.true/peers/grants.json`.
struct GrantSnapshot: Codable, Equatable, Sendable {
    struct Person: Codable, Equatable, Sendable { var id: String; var role: String; var active: Int? }
    struct Device: Codable, Equatable, Sendable { var device: String; var person: String; var peer_key: String?; var public_key: String? }
    struct Workspace: Codable, Equatable, Sendable { var id: String; var kind: String; var key: String; var owner: String? }
    struct Grant: Codable, Equatable, Sendable {
        var id: String; var person: String; var workspace: String; var level: String
        var expires: Double?; var revoked_at: Double?
    }
    var fetched_at: Double?
    var device: String
    var persons: [Person]
    var devices: [Device]
    var workspaces: [Workspace]
    var grants: [Grant]
}

enum GrantTarget: Equatable, Sendable {
    case repo(String)            // the job's repo url
    case dir(String)             // a real (symlink-resolved) directory
    case scratch                 // no repo, no dir: touches no workspace
}

enum GrantVerdict: Equatable, Sendable {
    case allow(person: String)
    case deny(String)
}

enum GrantRules {
    static let notInGroup = "Peer not in the group"
    static let noGrant = "Not allowed: no grant"
    static let staleAfter: TimeInterval = 15 * 60

    static func stale(since: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "Grants stale, Steward unreachable since \(f.string(from: since))"
    }

    /// The person who owns the device whose registered peer key is `peerKey` (base64). Deactivated persons map to nobody.
    static func person(for peerKey: String, in s: GrantSnapshot) -> String? {
        guard let d = s.devices.first(where: { $0.peer_key == peerKey }) else { return nil }
        guard let p = s.persons.first(where: { $0.id == d.person }), p.active != 0 else { return nil }
        return p.id
    }

    /// T3 Group: may this peer's person READ the repo's workspace (read, work or admin, live)? Fail closed:
    /// no snapshot, a snapshot older than `staleAfter` (the offline allowance does not waive it) or no device→person entry = no.
    static func readsRepo(_ s: GrantSnapshot?, fetched: Date?, peerKey: String, url: String, now: Date) -> Bool {
        guard let s, let fetched, now.timeIntervalSince(fetched) <= staleAfter, let person = person(for: peerKey, in: s) else { return false }
        let t = now.timeIntervalSince1970
        return s.grants.contains { g in
            g.person == person && ["read", "work", "admin"].contains(g.level) && g.revoked_at == nil && (g.expires.map { $0 > t } ?? true)
                && s.workspaces.contains { $0.id == g.workspace && $0.kind == "repo" && repoMatches($0.key, url) }
        }
    }

    /// Does `person` hold `work` (or `admin`) on a workspace matching `target`? Expired or revoked grants do not count,
    /// even if the cached snapshot still lists them. `real` real-paths a folder workspace key like `PeerDirs.resolve` does.
    static func check(_ s: GrantSnapshot, peerKey: String, target: GrantTarget, now: Date,
                      real: (String) -> String? = PeerDirs.realDirectory) -> GrantVerdict {
        guard let person = person(for: peerKey, in: s) else { return .deny(notInGroup) }
        if target == .scratch { return .allow(person: person) }
        let t = now.timeIntervalSince1970
        let held = s.grants.filter { $0.person == person && ["work", "admin"].contains($0.level) && $0.revoked_at == nil && ($0.expires.map { $0 > t } ?? true) }
        for g in held {
            guard let w = s.workspaces.first(where: { $0.id == g.workspace }) else { continue }
            switch (w.kind, target) {
            case ("repo", .repo(let url)) where repoMatches(w.key, url): return .allow(person: person)
            case ("folder", .dir(let dir)):
                let root = real(w.key) ?? URL(fileURLWithPath: (w.key as NSString).expandingTildeInPath).standardizedFileURL.path
                if dir == root || dir.hasPrefix(root + "/") { return .allow(person: person) }
            default: continue
            }
        }
        return .deny(noGrant)
    }

    /// Steward stores repo keys as `host/owner/name` (no scheme); older rows may still be full URLs. Compare in normalised form.
    static func repoMatches(_ key: String, _ url: String) -> Bool {
        guard let job = PeerRepo.normalize(url) else { return false }
        let stored = PeerRepo.normalize(key) ?? PeerRepo.normalize("https://" + key)
        return stored == job
    }

    /// What an owner device signs for an offline allowance: compact JSON `["offline-allow", device, until]`.
    static func allowMessage(device: String, until: Int) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["offline-allow", device, until] as [Any], options: [.withoutEscapingSlashes])) ?? Data()
    }

    /// Valid only if signed by this Mac's device key as Steward recorded it, and that device's person is an owner.
    static func allowIsValid(_ a: OfflineAllow, snapshot s: GrantSnapshot) -> Bool {
        guard a.device == s.device,
              let d = s.devices.first(where: { $0.device == a.device }), let pk = d.public_key,
              s.persons.first(where: { $0.id == d.person })?.role == "owner",
              let raw = Data(base64Encoded: pk), let sig = Data(base64Encoded: a.signature) else { return false }
        let msg = allowMessage(device: a.device, until: a.until)
        if raw.count == 65 {   // One True device key: P-256 x963, DER signature
            guard let key = try? P256.Signing.PublicKey(x963Representation: raw), let der = try? P256.Signing.ECDSASignature(derRepresentation: sig) else { return false }
            return key.isValidSignature(der, for: msg)
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: msg)
    }
}

/// A signed local override: until `until` (epoch seconds) the stale rule is waived.
struct OfflineAllow: Codable, Equatable, Sendable { var device: String; var until: Int; var signature: String }

/// Persisted switch state (`group-enforce.json`): grants mode, the offline allowance, and audit notes waiting for Steward.
struct GrantLocalState: Codable, Equatable, Sendable {
    struct Note: Codable, Equatable, Sendable { var action: String; var note: String }
    var on = false
    var allow: OfflineAllow?
    var pending: [Note] = []
    /// T3 Group: send `agents` on the Card (nil = on, the default). Off = always empty.
    var shareAgents: Bool? = nil
}

final class GrantCache: @unchecked Sendable {
    private struct Stored: Codable { var snapshot: GrantSnapshot; var fetched: Double }

    private let dir: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var snap: GrantSnapshot?
    private var fetched: Date?
    private var failingSince: Date?
    private var local = GrantLocalState()
    /// Called (off the lock) when the snapshot changes.
    var onChange: (@Sendable () -> Void)?

    init(dir: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dir = dir; self.now = now
        if let d = try? Data(contentsOf: dir.appendingPathComponent("grants.json")), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            snap = s.snapshot; fetched = Date(timeIntervalSince1970: s.fetched)
        }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("group-enforce.json")), let l = try? JSONDecoder().decode(GrantLocalState.self, from: d) {
            local = l
            if let a = l.allow, let s = snap, !GrantRules.allowIsValid(a, snapshot: s) { local.allow = nil }   // never trust an unverifiable file
        }
    }

    /// Sign-out: forget the snapshot and every local grant file for this person (grants.json, enforce state).
    func clear() {
        lock.lock(); snap = nil; fetched = nil; failingSince = nil; local = GrantLocalState(); lock.unlock()
        for n in ["grants.json", "group-enforce.json"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
        onChange?()
    }

    var isEnforcing: Bool { lock.lock(); defer { lock.unlock() }; return local.on }
    var snapshot: GrantSnapshot? { lock.lock(); defer { lock.unlock() }; return snap }
    var lastFetch: Date? { lock.lock(); defer { lock.unlock() }; return fetched }

    // MARK: snapshot

    /// A successful fetch. Returns false (and keeps the old snapshot) when the body is not a snapshot.
    @discardableResult
    func apply(_ data: Data) -> Bool {
        guard let s = try? JSONDecoder().decode(GrantSnapshot.self, from: data) else { return false }
        lock.lock(); let t = now(); snap = s; fetched = t; failingSince = nil
        if let a = local.allow, !GrantRules.allowIsValid(a, snapshot: s) { local.allow = nil; saveLocal() }
        if let d = try? JSONEncoder().encode(Stored(snapshot: s, fetched: t.timeIntervalSince1970)) { write(d, "grants.json") }
        lock.unlock()
        onChange?()
        return true
    }

    func noteFailure() { lock.lock(); if failingSince == nil { failingSince = fetched ?? now() }; lock.unlock() }

    // MARK: the gate

    /// nil = allowed (or grants mode is off). Otherwise the plain reason to refuse a NEW peer job. Running jobs are never asked.
    func refusal(peerKey: String, target: GrantTarget) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard local.on else { return nil }
        let t = now()
        let allowed = local.allow.map { Date(timeIntervalSince1970: Double($0.until)) > t } ?? false
        if !allowed, fetched.map({ t.timeIntervalSince($0) > GrantRules.staleAfter }) ?? true {
            return GrantRules.stale(since: failingSince ?? fetched ?? t)
        }
        guard let s = snap else { return GrantRules.notInGroup }
        if case .deny(let why) = GrantRules.check(s, peerKey: peerKey, target: target, now: t) { return why }
        return nil
    }

    /// G9: a POSITIVE check for auto-accept. True only with grants mode on, a fresh snapshot, and the sender holding work/admin on a real
    /// workspace (a scratch job touches none, so it never qualifies). `refusal` stays the gate for everything else.
    func holdsWork(peerKey: String, target: GrantTarget) -> Bool {
        if target == .scratch { return false }
        lock.lock(); let on = local.on, has = snap != nil; lock.unlock()
        return on && has && refusal(peerKey: peerKey, target: target) == nil
    }

    /// This Mac's Steward device id from the last snapshot.
    var deviceId: String? { lock.lock(); defer { lock.unlock() }; return snap?.device }

    // MARK: switches

    /// T3 Group: whether this Mac's Card may carry `agents`.
    var sharesAgents: Bool { lock.lock(); defer { lock.unlock() }; return local.shareAgents ?? true }
    func setShareAgents(_ on: Bool) { lock.lock(); local.shareAgents = on; saveLocal(); lock.unlock() }

    /// T3 Group: may `folders` / `agents` for this repo go to that peer? Grants mode off = yes (the share itself was the consent).
    func mayShare(peerKey: String, repoURL: String) -> Bool {
        lock.lock(); let on = local.on, s = snap, f = fetched; lock.unlock()
        guard on else { return true }
        return GrantRules.readsRepo(s, fetched: f, peerKey: peerKey, url: repoURL, now: now())
    }

    func setEnforce(_ on: Bool) {
        lock.lock()
        if local.on != on { local.on = on; local.pending.append(.init(action: on ? "enforce.on" : "enforce.off", note: "")) }
        saveLocal(); lock.unlock()
    }

    var offlineUntil: Date? {
        lock.lock(); defer { lock.unlock() }
        return local.allow.map { Date(timeIntervalSince1970: Double($0.until)) }.flatMap { $0 > now() ? $0 : nil }
    }

    /// Sign and store an offline allowance. `signingKey` is the device's base64 Ed25519 seed (steward.json). Refused unless this
    /// Mac's device is an owner's and the seed matches the public key Steward recorded for it.
    func allowOffline(for seconds: TimeInterval, signingKey: String) -> Result<Date, PeerError> {   // legacy Ed25519 seed (tests only; the CLI no longer sends one)
        guard let seed = Data(base64Encoded: signingKey), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            return .failure(.invalid("no device key to sign with"))
        }
        return allowOffline(for: seconds) { try key.signature(for: $0) }
    }

    /// Same, signed by this Mac's device key (P-256 DER).

    private func allowOffline(for seconds: TimeInterval, sign: (Data) throws -> Data) -> Result<Date, PeerError> {
        lock.lock(); defer { lock.unlock() }
        guard seconds >= 60, seconds <= 24 * 3600 else { return .failure(.invalid("--offline-allow must be between 1 minute and 24 hours")) }
        guard let s = snap else { return .failure(.invalid("no grant snapshot yet; reach Steward once first")) }
        let until = Int(now().timeIntervalSince1970 + seconds)
        guard let sig = try? sign(GrantRules.allowMessage(device: s.device, until: until)) else { return .failure(.invalid("could not sign")) }
        let a = OfflineAllow(device: s.device, until: until, signature: sig.base64EncodedString())
        guard GrantRules.allowIsValid(a, snapshot: s) else { return .failure(.invalid("only an owner's device can allow offline")) }
        local.allow = a
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        local.pending.append(.init(action: "enforce.offline-allow", note: "until " + f.string(from: Date(timeIntervalSince1970: Double(until)))))
        saveLocal()
        return .success(Date(timeIntervalSince1970: Double(until)))
    }

    func pendingNotes() -> [GrantLocalState.Note] { lock.lock(); defer { lock.unlock() }; return local.pending }
    /// G7: an audit line (ids, sizes, times only) that rides out with the next Steward sync.
    func note(action: String, note: String) {
        lock.lock(); local.pending.append(.init(action: action, note: note)); if local.pending.count > 500 { local.pending.removeFirst(local.pending.count - 500) }
        saveLocal(); lock.unlock()
    }
    func ackNotes(_ n: Int) { lock.lock(); local.pending.removeFirst(min(n, local.pending.count)); saveLocal(); lock.unlock() }

    private func saveLocal() { if let d = try? JSONEncoder().encode(local) { write(d, "group-enforce.json") } }

    private func write(_ d: Data, _ name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let u = dir.appendingPathComponent(name)
        try? d.write(to: u, options: .atomic); chmod(u.path, 0o600)
    }
}

// MARK: - Keeping the cache fresh

protocol GrantTransport: Sendable {
    /// Blocking. The snapshot body, or throws when Steward is unreachable or refuses.
    func fetchSnapshot() throws -> Data
    func postAuditNote(action: String, note: String) throws
    /// Blocking: Steward's `GET /allowance` board (G6). Throws when Steward is unreachable. Transports that cannot say throw.
    func fetchAllowance() throws -> Data
    /// Blocking: Steward's `GET /items/{id}/placement` (G9). Transports that cannot say throw.
    func fetchPlacement(_ item: String) throws -> Data
    /// Blocking: reads Steward's `/events` until the stream ends or fails, calling `onEvent` with each event.
    /// `since` is Steward's cursor: nil = from the start (first connect), "latest" = replay nothing (reconnects).
    func streamEvents(since: String?, onEvent: @escaping @Sendable (SSEEvent) -> Void) throws
}

extension GrantTransport {
    func fetchAllowance() throws -> Data { throw PeerError.invalid("allowance board not available") }
}

/// One server-sent event: its `event:` kind and the raw `data:` line (Steward sends one JSON row per event).
struct SSEEvent: Equatable, Sendable { var kind: String; var data: String }

/// Parses `text/event-stream` lines into event kinds (the `event:` field, emitted at the blank line).
struct SSEKinds {
    private var kind: String?
    private var data = ""
    /// The `data:` of the event `feed` just returned.
    private(set) var lastData = ""
    mutating func feed(_ line: String) -> String? {
        if line.hasPrefix("event:") { kind = line.dropFirst(6).trimmingCharacters(in: .whitespaces); return nil }
        if line.hasPrefix("data:") { data = line.dropFirst(5).trimmingCharacters(in: .whitespaces); return nil }
        if line.isEmpty, let k = kind { kind = nil; lastData = data; data = ""; return k }
        return nil
    }
}

final class GrantSync: @unchecked Sendable {
    static let pollEvery: TimeInterval = 45   // G2: the fallback path lands inside a minute (G1 measured 61 s at 60)
    private let cache: GrantCache
    private let transport: GrantTransport
    private let scheduler: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let runner: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let lock = NSLock()
    private var running = false, queued = false
    private var sessions = 0
    private var observers: [@Sendable (SSEEvent) -> Void] = []
    private let q = DispatchQueue(label: "true.group.sync")

    /// `runner` runs a coalesced refresh; tests pass `{ $0() }`.
    init(cache: GrantCache, transport: GrantTransport,
         scheduler: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void,
         runner: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        self.cache = cache; self.transport = transport; self.scheduler = scheduler
        let q = self.q
        self.runner = runner ?? { f in q.async(execute: f) }
    }

    /// One fetch. Success replaces the snapshot and flushes queued audit notes; failure only marks Steward unreachable.
    func refresh() {
        guard let data = try? transport.fetchSnapshot(), cache.apply(data) else { cache.noteFailure(); return }
        let notes = cache.pendingNotes()
        var sent = 0
        for n in notes { if (try? transport.postAuditNote(action: n.action, note: n.note)) != nil { sent += 1 } else { break } }
        if sent > 0 { cache.ackNotes(sent) }
    }

    /// Other consumers (the `GroupClient`) share this stream instead of opening a second one. Called for every event,
    /// plus a synthetic `stream.reconnected` after a reconnect (events in the gap were skipped: reload).
    func observe(_ f: @escaping @Sendable (SSEEvent) -> Void) { lock.lock(); observers.append(f); lock.unlock() }

    func handle(_ e: SSEEvent) {
        lock.lock(); let all = observers; lock.unlock()
        for f in all { f(e) }
        handleEvent(e.kind)
    }

    /// A Steward event arrived. `grants.changed` triggers a refetch; a burst collapses into one.
    func handleEvent(_ kind: String) {
        guard kind == "grants.changed" else { return }
        lock.lock(); if queued { lock.unlock(); return }; queued = true; lock.unlock()
        runner { [self] in lock.lock(); queued = false; lock.unlock(); refresh() }
    }

    /// One pass over the event stream; true when it connected and ended without error.
    @discardableResult
    func eventSession() -> Bool {
        lock.lock(); let first = sessions == 0; sessions += 1; lock.unlock()
        if !first {   // reconnect: reload the snapshot, then listen from "now" instead of replaying history
            refresh()
            handle(SSEEvent(kind: "stream.reconnected", data: ""))
        }
        do { try transport.streamEvents(since: first ? nil : "latest") { [weak self] in self?.handle($0) }; return true } catch { return false }
    }

    func start() {
        lock.lock(); if running { lock.unlock(); return }; running = true; lock.unlock()
        runner { [self] in refresh() }
        poll()
        Thread.detachNewThread { [self] in
            var attempt = 0
            while isRunning {
                attempt = eventSession() ? 0 : attempt + 1
                Thread.sleep(forTimeInterval: attempt == 0 ? 1 : PeerBackoff.delay(attempt: attempt - 1))   // reconnect with backoff
            }
        }
    }

    func stop() { lock.lock(); running = false; lock.unlock() }
    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func poll() {
        scheduler(Self.pollEvery) { [weak self] in
            guard let self, isRunning else { return }
            runner { [self] in refresh() }
            poll()
        }
    }
}

extension GrantTransport {
    func fetchPlacement(_ item: String) throws -> Data { throw PeerError.invalid("placement not supported") }
}

