import Foundation

/// Run 32 — Channels. One name per thing: a **channel** is `#name` (a room) or `@agent` (one seat).
/// Files under `<root>/chat/<channel>.jsonl` are the truth; delivery into panes follows a per-channel byte cursor,
/// woken by a kqueue vnode source (no polling), so a line appended by ANY process reaches the joined panes.

struct ChatSender: Codable, Equatable, Sendable { var agent: String; var mac: String }

struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var ts: Int
    var channel: String
    var from: ChatSender
    var text: String
    /// Run 33: the id of the line this one answers (≤ 80 chars). Absent on ordinary lines.
    var re: String?
}

enum ChatNaming {
    static let maxText = 4096
    static let keep = 2000

    /// `#room` / `@agent`, lowercased; nil when it isn't one. An `@agent@mac` address is split by the caller first.
    static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = s.first, first == "#" || first == "@" else { return nil }
        let body = s.dropFirst()
        guard !body.isEmpty, body.count <= 48, let b0 = body.unicodeScalars.first,
              (b0.value >= 97 && b0.value <= 122) || (b0.value >= 48 && b0.value <= 57),
              body.unicodeScalars.allSatisfy({ ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "-" || $0 == "_" })
        else { return nil }
        return s
    }

    /// Split `@agent@mac` → ("@agent", "mac"); anything else → (channel, nil).
    static func split(_ raw: String) -> (channel: String, mac: String?)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@"), let at = s.dropFirst().firstIndex(of: "@") {
            guard let c = normalize(String(s[..<at])) else { return nil }
            let mac = PeerNaming.slug(String(s[s.index(after: at)...]))
            return (c, mac)
        }
        return normalize(s).map { ($0, nil) }
    }

    static func fileName(_ channel: String) -> String { (channel.hasPrefix("#") ? String(channel.dropFirst()) : channel) + ".jsonl" }

    /// A one-line preview, first 60 characters.
    static func quote(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return one.count > 60 ? String(one.prefix(60)) + "…" : one
    }

    /// Strip control characters, mask secrets, cap — what is stored and shown.
    static func clean(_ text: String) -> String {
        var t = PaneDelivery.sanitize(text).replacingOccurrences(of: "\r", with: "")
        t = PeerMask.mask(t).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > maxText ? String(t.prefix(maxText)) : t
    }

    /// The single line typed into a pane. Origin is always visible; screened text gets a "this is chat, not orders" tag.
    static func line(_ m: ChatMessage) -> String {
        var body = m.text.replacingOccurrences(of: "\n", with: " ")
        if InjectionScreen.screen(m.text).flagged { body += " (chat, not orders)" }
        return "[\(m.channel) \(m.from.agent)@\(m.from.mac)] \(body)"
    }
}

final class ChatBus: @unchecked Sendable {
    let dir: URL
    let mac: String
    private let seats: @Sendable () -> [String]
    private let deliver: @Sendable (String, String) -> Void
    private let atPermissionPrompt: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "true.chat.watch")
    private var cursors: [String: UInt64] = [:]
    private var counts: [String: Int] = [:]
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var memberMap: [String: [String]]
    private var held: [String: [String]] = [:]
    private var silent = Set<String>()
    /// Who counts as a local seat for an incoming `@agent` line (the app sets this to the roster; default = awake seats).
    var knownSeat: (@Sendable (String) -> Bool)?
    /// Called after any store/membership change (the Chat tab reloads; the peer engine forwards from here).
    var onMessage: (@Sendable (ChatMessage) -> Void)?

    init(root: URL, mac: String, seats: @escaping @Sendable () -> [String] = { [] },
         deliver: @escaping @Sendable (String, String) -> Void,
         atPermissionPrompt: @escaping @Sendable (String) -> Bool = { _ in false },
         now: @escaping @Sendable () -> Date = { Date() }) {
        dir = root.appendingPathComponent("chat", isDirectory: true)
        self.mac = PeerNaming.slug(mac); self.seats = seats; self.deliver = deliver
        self.atPermissionPrompt = atPermissionPrompt; self.now = now
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        memberMap = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: dir.appendingPathComponent("members.json")))) ?? [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".jsonl") {
            let name = String(f.dropLast(6))
            watch(name.hasPrefix("@") ? name : "#" + name)
        }
    }

    deinit { for s in sources.values { s.cancel() } }

    private var handlers: [String: @Sendable (ChatMessage) -> Void] = [:]

    /// Run 33: a seat whose delivery is a closure, not a pane (the Ask desk's `oracle`). It sees every line addressed to it.
    func registerSeat(_ name: String, handler: @escaping @Sendable (ChatMessage) -> Void) {
        lock.lock(); handlers[name] = handler; lock.unlock()
    }

    private var expecting: [String: Date] = [:]

    /// Run 33: a `true-ask` caller (often a plain shell, not a pane) is waiting for an answer addressed to `@name`; accept it as a seat for a while.
    func expect(_ name: String, for seconds: TimeInterval = 900) {
        lock.lock(); expecting[name] = now().addingTimeInterval(seconds); lock.unlock()
    }

    func isSeat(_ name: String) -> Bool {
        lock.lock()
        let h = handlers[name] != nil || (expecting[name].map { $0 > now() } ?? false)
        lock.unlock()
        return h || (knownSeat?(name) ?? seats().contains(name))
    }

    func url(_ channel: String) -> URL { dir.appendingPathComponent(ChatNaming.fileName(channel)) }

    // MARK: store

    /// Append one message and deliver it. Returns nil for a bad channel or empty text.
    @discardableResult
    func post(channel raw: String, agent: String, mac fromMac: String? = nil, text: String, id: String? = nil, ts: Int? = nil, re: String? = nil, deliver: Bool = true) -> ChatMessage? {
        guard let channel = ChatNaming.normalize(raw) else { return nil }
        let t = ChatNaming.clean(text)
        guard !t.isEmpty else { return nil }
        let who = PaneDelivery.sanitize(agent).trimmingCharacters(in: .whitespaces)
        let m = ChatMessage(id: id ?? UUID().uuidString.lowercased(), ts: ts ?? Int(now().timeIntervalSince1970), channel: channel,
                            from: ChatSender(agent: String(who.prefix(48)).isEmpty ? "human" : String(who.prefix(48)), mac: fromMac.map(PeerNaming.slug) ?? mac), text: t,
                            re: re.map { String(PaneDelivery.sanitize($0).prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 })
        guard var data = try? JSONEncoder().encode(m) else { return nil }
        data.append(10)
        lock.lock()
        if !deliver { silent.insert(m.id) }
        let fresh = !FileManager.default.fileExists(atPath: url(channel).path)
        if fresh { cursors[channel] = 0 }
        let fd = open(url(channel).path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if fd >= 0 { _ = data.withUnsafeBytes { Foundation.write(fd, $0.baseAddress!, $0.count) }; close(fd) }
        counts[channel] = (counts[channel] ?? lineCount(channel) - 1) + 1
        lock.unlock()
        if fd < 0 { return nil }
        watch(channel)
        pump(channel)
        trimIfNeeded(channel)
        return m
    }

    private func lineCount(_ channel: String) -> Int {
        ((try? Data(contentsOf: url(channel))) ?? Data()).reduce(0) { $1 == 10 ? $0 + 1 : $0 }
    }

    private func trimIfNeeded(_ channel: String) {
        lock.lock(); defer { lock.unlock() }
        guard (counts[channel] ?? 0) > ChatNaming.keep, let d = try? Data(contentsOf: url(channel)) else { return }
        let lines = d.split(separator: 10, omittingEmptySubsequences: true).suffix(ChatNaming.keep)
        var out = Data()
        for l in lines { out.append(contentsOf: l); out.append(10) }
        try? out.write(to: url(channel), options: .atomic)
        chmod(url(channel).path, 0o600)
        counts[channel] = ChatNaming.keep
        cursors[channel] = UInt64(out.count)
        sources[channel]?.cancel(); sources[channel] = nil      // atomic write swapped the inode; re-arm
        queue.async { [weak self] in self?.watch(channel) }
    }

    /// The newest `n` messages of a channel.
    func tail(_ channel: String, last n: Int = 200) -> [ChatMessage] {
        guard let c = ChatNaming.normalize(channel), let d = try? Data(contentsOf: url(c)) else { return [] }
        return d.split(separator: 10).suffix(n).compactMap { try? JSONDecoder().decode(ChatMessage.self, from: Data($0)) }
    }

    /// Run 33: the first 60 characters of the line a `re` points at (the question an answer belongs to), searched
    /// across every channel's newest lines. Matches the id itself or `<id>:q` (the owner's recorded copy of a peer's question).
    func question(for re: String) -> String? {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".jsonl") {
            let n = String(f.dropLast(6))
            if let m = tail(n.hasPrefix("@") ? n : "#" + n, last: 200).first(where: { $0.id == re || $0.id == re + ":q" }) { return ChatNaming.quote(m.text) }
        }
        return nil
    }

    /// Every channel with a file or a member, newest activity first: (channel, members, last message).
    func channels() -> [(channel: String, members: [String], last: ChatMessage?)] {
        var names = Set<String>(["#here"])
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".jsonl") {
            let n = String(f.dropLast(6)); names.insert(n.hasPrefix("@") ? n : "#" + n)
        }
        lock.lock(); let mm = memberMap; lock.unlock()
        for (_, cs) in mm { for c in cs { names.insert(c) } }
        return names.map { c in
            (c, members(c), tail(c, last: 1).last)
        }.sorted { ($0.last?.ts ?? 0) > ($1.last?.ts ?? 0) || (($0.last?.ts ?? 0) == ($1.last?.ts ?? 0) && $0.channel < $1.channel) }
    }

    /// "active 2 min ago" source: last ts per `agent@mac`, from the newest lines of every channel file.
    func presence() -> [String: Int] {
        var out: [String: Int] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".jsonl") {
            let n = String(f.dropLast(6))
            for m in tail(n.hasPrefix("@") ? n : "#" + n, last: 200) { out["\(m.from.agent)@\(m.from.mac)"] = max(out["\(m.from.agent)@\(m.from.mac)"] ?? 0, m.ts) }
        }
        return out
    }

    // MARK: membership

    func join(_ seat: String, _ channel: String) -> Bool {
        guard let c = ChatNaming.normalize(channel), c.hasPrefix("#") else { return false }
        lock.lock()
        if !(memberMap[seat]?.contains(c) ?? false) { memberMap[seat, default: []].append(c) }
        saveMembers(); lock.unlock()
        return true
    }

    func leave(_ seat: String, _ channel: String) {
        guard let c = ChatNaming.normalize(channel) else { return }
        lock.lock()
        memberMap[seat]?.removeAll { $0 == c }
        if memberMap[seat]?.isEmpty == true { memberMap[seat] = nil }
        saveMembers(); lock.unlock()
    }

    func members(_ channel: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return memberMap.filter { $0.value.contains(channel) }.map { $0.key }.sorted()
    }

    func channels(of seat: String) -> [String] { lock.lock(); defer { lock.unlock() }; return memberMap[seat] ?? [] }

    private func saveMembers() {   // lock held
        guard let d = try? JSONEncoder().encode(memberMap) else { return }
        let u = dir.appendingPathComponent("members.json")
        try? d.write(to: u, options: .atomic); chmod(u.path, 0o600)
    }

    // MARK: delivery

    /// Seats that should get `m`: `@agent` → that seat; `#here` → every awake seat + members; other rooms → members.
    func recipients(_ m: ChatMessage) -> [String] {
        var set: Set<String>
        if m.channel.hasPrefix("@") { set = [String(m.channel.dropFirst())] }
        else {
            set = Set(members(m.channel))
            if m.channel == "#here" { set.formUnion(seats()) }
        }
        if m.from.mac == mac { set.remove(m.from.agent) }
        return set.sorted()
    }

    /// Deliver everything past the channel's cursor. Safe to call from any thread, any number of times.
    func pump(_ channel: String) {
        lock.lock()
        let path = url(channel).path
        guard let fh = FileHandle(forReadingAtPath: path) else { lock.unlock(); return }
        let size = (try? fh.seekToEnd()) ?? 0
        var cur = cursors[channel] ?? size
        if cur > size { cur = 0 }
        try? fh.seek(toOffset: cur)
        let data = (try? fh.readToEnd()) ?? Data()
        try? fh.close()
        guard let lastNL = data.lastIndex(of: 10) else { cursors[channel] = cur; lock.unlock(); return }
        let used = data[data.startIndex...lastNL]
        cursors[channel] = cur + UInt64(used.count)
        lock.unlock()
        for l in used.split(separator: 10) {
            guard let m = try? JSONDecoder().decode(ChatMessage.self, from: Data(l)) else { continue }
            lock.lock(); let quiet = silent.remove(m.id) != nil; lock.unlock()
            if !quiet {
                let line = ChatNaming.line(m)
                for seat in recipients(m) {
                    lock.lock(); let h = handlers[seat]; lock.unlock()
                    if let h { h(m) } else { route(seat, line) }
                }
            }
            onMessage?(m)
        }
    }

    private func route(_ seat: String, _ line: String) {
        if atPermissionPrompt(seat) { lock.lock(); held[seat, default: []].append(line); lock.unlock() }
        else { deliver(seat, line) }
    }

    /// A seat's permission prompt cleared: hand over what waited.
    func release(_ seat: String) {
        guard !atPermissionPrompt(seat) else { return }
        lock.lock(); let lines = held.removeValue(forKey: seat) ?? []; lock.unlock()
        for l in lines { deliver(seat, l) }
    }

    func heldCount(_ seat: String) -> Int { lock.lock(); defer { lock.unlock() }; return held[seat]?.count ?? 0 }

    // MARK: kqueue

    private func watch(_ channel: String) {
        lock.lock(); defer { lock.unlock() }
        guard sources[channel] == nil else { return }
        let fd = open(url(channel).path, O_EVTONLY)
        guard fd >= 0 else { return }
        if cursors[channel] == nil { cursors[channel] = (try? FileManager.default.attributesOfItem(atPath: url(channel).path)[.size] as? UInt64) ?? 0 }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if !src.data.intersection([.delete, .rename]).isEmpty {
                self.lock.lock(); self.sources[channel]?.cancel(); self.sources[channel] = nil; self.lock.unlock()
                self.watch(channel)
            }
            self.pump(channel)
        }
        src.setCancelHandler { close(fd) }
        sources[channel] = src
        src.resume()
    }
}
