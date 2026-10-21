import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Names for files that arrive from the phone. The phone controls the string, so it is treated as hostile:
/// last path component only, no separators / colons / control or invisible characters, no leading dots.
enum DropName {
    static let maxLength = 120
    static let rasterExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif"]

    static func sanitize(_ raw: String?, now: Date = Date()) -> String {
        var s = raw ?? ""
        s = s.removingPercentEncoding ?? s
        s = s.replacingOccurrences(of: "\\", with: "/")
        s = s.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        s.unicodeScalars.removeAll { sc in
            sc == ":" || sc == "/" || sc.properties.generalCategory == .control || sc.properties.generalCategory == .format
                || sc.properties.generalCategory == .lineSeparator || sc.properties.generalCategory == .paragraphSeparator
        }
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }
        s = truncate(s)
        if s.isEmpty || s.allSatisfy({ $0 == " " }) {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"
            return "iPhone-\(f.string(from: now))"
        }
        return s
    }

    /// ≤ 120 characters (and ≤ 240 UTF-8 bytes, well inside APFS's 255), keeping a short extension.
    private static func truncate(_ name: String) -> String {
        func fits(_ x: String) -> Bool { x.count <= maxLength && x.utf8.count <= 240 }
        if fits(name) { return name }
        let ext = (name as NSString).pathExtension
        let keep = ext.count <= 16 && !ext.isEmpty ? "." + ext : ""
        var stem = String(name.dropLast(keep.count))
        while !stem.isEmpty && !fits(stem + keep) { stem.removeLast() }
        return stem.isEmpty ? String(name.prefix(maxLength)) : stem + keep
    }

    /// `photo.jpg` → `photo-2.jpg`, `photo-3.jpg` …
    static func numbered(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        return ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
    }

    /// Lower-case alphanumeric extension (≤ 8) safe to put in a temp file name.
    static func safeExtension(_ name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        return e.count <= 8 && e.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? e : ""
    }

    /// Raster images only (SVG, PDF and friends are files). Extension must be a known raster type that UTType agrees is an image.
    static func isRasterImage(_ name: String) -> Bool {
        let e = (name as NSString).pathExtension.lowercased()
        guard rasterExtensions.contains(e), let t = UTType(filenameExtension: e) else { return false }
        return t.conforms(to: .image)
    }

    /// True when ImageIO can actually decode the bytes (a renamed HTML file is a file, not a shot).
    static func decodes(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 0
    }

    /// The only types served inline. Everything else is `application/octet-stream` + attachment.
    static func imageContentType(forName name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        default: return nil
        }
    }

    /// ASCII only (`.alphanumerics` admits Unicode letters, which must be percent-encoded).
    private static let rfc5987Allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `Content-Disposition` value: ASCII fallback plus RFC 5987 UTF-8 name.
    static func attachment(_ name: String) -> String {
        let ascii = String(name.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "\\" ? Character($0) : "_" })
        let pct = name.addingPercentEncoding(withAllowedCharacters: rfc5987Allowed) ?? "file"
        return "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(pct)"
    }
}

/// Low-level file helpers (all POSIX so modes are set at creation, never chmod-ed after).
enum DropFS {
    static let minFreeBytes: Int64 = 1_000_000_000

    static func freeBytes(at dir: URL) -> Int64 {
        var s = statfs()
        guard statfs(dir.path, &s) == 0 else { return 0 }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }

    static func ensureDir(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// `com.apple.quarantine`: Gatekeeper then treats anything received from the phone as downloaded from the internet.
    @discardableResult
    static func setQuarantine(_ url: URL, now: Date = Date()) -> Bool {
        let v = "0083;\(String(Int(now.timeIntervalSince1970), radix: 16));True;"
        return setxattr(url.path, "com.apple.quarantine", v, v.utf8.count, 0, 0) == 0
    }

    static func quarantine(_ url: URL) -> String? {
        let n = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        guard getxattr(url.path, "com.apple.quarantine", &buf, n, 0, 0) == n else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }

    /// Copy `src` to `dst` creating it exclusively with `mode`. false if `dst` exists or anything fails.
    static func copyExclusive(_ src: URL, to dst: URL, mode: mode_t) -> Bool {
        let inFD = open(src.path, O_RDONLY)
        guard inFD >= 0 else { return false }
        defer { close(inFD) }
        let outFD = open(dst.path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard outFD >= 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        var ok = true
        while ok {
            let n = read(inFD, &buf, buf.count)
            if n < 0 { ok = false; break }
            if n == 0 { break }
            var off = 0
            while off < n {
                let w = buf[off..<n].withUnsafeBytes { write(outFD, $0.baseAddress, $0.count) }
                if w <= 0 { ok = false; break }
                off += w
            }
        }
        close(outFD)
        if !ok { unlink(dst.path) }
        return ok
    }

    /// Move `tmp` into `dir` as `name`, never overwriting: a taken name becomes `name-2.ext`, `name-3.ext` …
    static func placeExclusive(_ tmp: URL, in dir: URL, name: String, mode: mode_t = 0o644) -> URL? {
        for n in 1..<10_000 {
            let dst = dir.appendingPathComponent(DropName.numbered(name, n))
            if link(tmp.path, dst.path) == 0 { unlink(tmp.path); chmod(dst.path, mode); return dst }
            if errno == EEXIST { continue }
            // Not the same volume (or no hard links): exclusive copy instead.
            if copyExclusive(tmp, to: dst, mode: mode) { unlink(tmp.path); return dst }
            if FileManager.default.fileExists(atPath: dst.path) { continue }
            return nil
        }
        return nil
    }

    static func writeAtomic0600(_ data: Data, to url: URL) {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".w-\(UUID().uuidString).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let ok = data.withUnsafeBytes { b -> Bool in
            var off = 0
            while off < b.count { let n = write(fd, b.baseAddress! + off, b.count - off); if n <= 0 { return false }; off += n }
            return true
        }
        close(fd)
        if ok, rename(tmp, url.path) == 0 { return }
        unlink(tmp)
    }
}

/// Pulls a request body off a socket under ONE overall deadline (a trickling client is cut off).
enum DropReceiver {
    enum Outcome: Equatable { case ok, timedOut, closed, ioError }

    /// Calls `sink` with each chunk until `total` bytes (counting the `have` already read) have arrived.
    static func pump(_ fd: Int32, have: Int, total: Int, deadline: TimeInterval, sink: ([UInt8]) -> Bool) -> Outcome {
        let end = Date().addingTimeInterval(deadline)
        var got = have
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while got < total {
            let ms = Int32(max(0, min(end.timeIntervalSinceNow * 1000, 10_000)))
            if end.timeIntervalSinceNow <= 0 { return .timedOut }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&p, 1, ms)
            if rc == 0 { continue }
            if rc < 0 { if errno == EINTR { continue }; return .closed }
            let want = min(chunk.count, total - got)
            let n = recv(fd, &chunk, want, 0)
            if n <= 0 { return .closed }
            if !sink(Array(chunk[0..<n])) { return .ioError }
            got += n
        }
        return .ok
    }

    /// Stream the body to a fresh 0600 file.
    static func receive(_ fd: Int32, initial: [UInt8], total: Int, deadline: TimeInterval, into dest: URL) -> Outcome {
        let out = open(dest.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard out >= 0 else { return .ioError }
        defer { close(out) }
        func put(_ bytes: [UInt8]) -> Bool {
            var off = 0
            while off < bytes.count {
                let n = bytes[off...].withUnsafeBytes { write(out, $0.baseAddress, $0.count) }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        let first = Array(initial.prefix(total))
        guard put(first) else { return .ioError }
        return pump(fd, have: first.count, total: total, deadline: deadline, sink: put)
    }
}

// MARK: - Phone inbox (Mac → phone, push only)

struct PhoneInboxItem: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case file, image, text }
    var id: String
    var name: String
    var kind: Kind
    var size: Int
    var created: Date
    /// Set only on the single auto-shared clipboard item (see ClipboardShare); old index files decode without it.
    var source: Source? = nil
    enum Source: String, Codable, Sendable { case clipboardShare }
}

/// What the Mac pushed for the phone to pick up. Copies, never links, never a path the phone can choose:
/// ids are random hex generated here. dir 0700, files 0600, at most 20 items, 24 h expiry.
final class RemoteInbox: @unchecked Sendable {
    static let maxItems = 20
    static let lifetime: TimeInterval = 24 * 3600
    static let maxBytes = 200 * 1024 * 1024

    static var standardRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("True/RemoteInbox", isDirectory: true)
    }

    static func validID(_ s: String) -> Bool {
        s.count == 16 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private let root: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(root: URL = RemoteInbox.standardRoot, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root; self.now = now
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private func fileURL(_ id: String) -> URL { root.appendingPathComponent("\(id).dat") }

    private func loadLocked() -> [PhoneInboxItem] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? Data(contentsOf: indexURL)).flatMap { try? dec.decode([PhoneInboxItem].self, from: $0) } ?? []
    }

    private func saveLocked(_ items: [PhoneInboxItem]) {
        DropFS.ensureDir(root)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(items) { DropFS.writeAtomic0600(d, to: indexURL) }
    }

    /// Newest first; expired and over-cap items are deleted from disk.
    private func pruneLocked(_ items: [PhoneInboxItem]) -> [PhoneInboxItem] {
        let t = now()
        var keep = items.filter { t.timeIntervalSince($0.created) < Self.lifetime }.sorted { $0.created > $1.created }
        let drop = items.filter { i in !keep.contains { $0.id == i.id } } + keep.dropFirst(Self.maxItems)
        keep = Array(keep.prefix(Self.maxItems))
        for d in drop { unlink(fileURL(d.id).path) }
        return keep
    }

    func list() -> [PhoneInboxItem] {
        lock.lock(); defer { lock.unlock() }
        let all = loadLocked(); let kept = pruneLocked(all)
        if kept != all { saveLocked(kept) }
        return kept
    }

    func item(_ id: String) -> (item: PhoneInboxItem, url: URL)? {
        guard Self.validID(id), let i = list().first(where: { $0.id == id }) else { return nil }
        return (i, fileURL(id))
    }

    func previewText(_ id: String, limit: Int = 240) -> String? {
        guard let (i, url) = item(id), i.kind == .text, let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: limit * 4)) ?? Data()
        return String(String(decoding: d, as: UTF8.self).prefix(limit))
    }

    /// Copy a file (or write text) into the inbox. nil when too big or the copy fails.
    @discardableResult
    func add(name: String, kind: PhoneInboxItem.Kind, from url: URL? = nil, data: Data? = nil,
             source: PhoneInboxItem.Source? = nil) -> PhoneInboxItem? {
        lock.lock(); defer { lock.unlock() }
        DropFS.ensureDir(root)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        var b = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        let id = b.map { String(format: "%02x", $0) }.joined()
        let dst = fileURL(id)
        var size = 0
        if let url {
            size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxBytes, DropFS.copyExclusive(url, to: dst, mode: 0o600) else { return nil }
        } else if let data {
            guard data.count <= Self.maxBytes else { return nil }
            let fd = open(dst.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return nil }
            let ok = data.withUnsafeBytes { p -> Bool in
                var off = 0
                while off < p.count { let n = write(fd, p.baseAddress! + off, p.count - off); if n <= 0 { return false }; off += n }
                return true
            }
            close(fd)
            if !ok { unlink(dst.path); return nil }
            size = data.count
        } else { return nil }
        let item = PhoneInboxItem(id: id, name: DropName.sanitize(name, now: now()), kind: kind, size: size, created: now(), source: source)
        saveLocked(pruneLocked([item] + loadLocked()))
        return item
    }

    /// Replaces the previous auto-shared clipboard item, so sharing never holds more than one inbox slot.
    @discardableResult
    func replaceSharedClipboard(text: String) -> PhoneInboxItem? {
        for i in list() where i.source == .clipboardShare { delete(i.id) }
        return add(name: "Clipboard", kind: .text, data: Data(text.utf8), source: .clipboardShare)
    }

    @discardableResult
    func delete(_ id: String) -> Bool {
        guard Self.validID(id) else { return false }
        lock.lock(); defer { lock.unlock() }
        let all = loadLocked()
        guard all.contains(where: { $0.id == id }) else { return false }
        unlink(fileURL(id).path)
        saveLocked(all.filter { $0.id != id })
        return true
    }
}

// MARK: - What the server needs from the Mac for files

/// Folders, the tray, the inbox and the Mac-side effects (toast, clipboard). Injected so tests use temp dirs.
final class RemoteFiles: @unchecked Sendable {
    static let maxDropBytes = 200 * 1024 * 1024
    static let maxClipBytes = 256 * 1024

    let tray: @Sendable () -> TrayStore
    let inbox: RemoteInbox
    let downloads: URL
    let tmpDir: URL
    let freeBytes: @Sendable (URL) -> Int64
    let notify: @Sendable (String) -> Void
    let setClipboard: @Sendable (String) -> Void
    let didIngest: @Sendable () -> Void
    let quarantine: @Sendable (URL) -> Bool

    init(tray: @escaping @Sendable () -> TrayStore, inbox: RemoteInbox, downloads: URL, tmpDir: URL,
         freeBytes: @escaping @Sendable (URL) -> Int64 = { DropFS.freeBytes(at: $0) },
         notify: @escaping @Sendable (String) -> Void = { _ in },
         setClipboard: @escaping @Sendable (String) -> Void = { _ in },
         didIngest: @escaping @Sendable () -> Void = {},
         quarantine: @escaping @Sendable (URL) -> Bool = { DropFS.setQuarantine($0) }) {
        self.tray = tray; self.inbox = inbox; self.downloads = downloads; self.tmpDir = tmpDir
        self.freeBytes = freeBytes; self.notify = notify; self.setClipboard = setClipboard; self.didIngest = didIngest; self.quarantine = quarantine
    }

    enum Landed: Equatable { case shot(String), file(URL) }

    /// A fully received temp file → the tray (decodable raster image) or `~/Downloads` (everything else, quarantined).
    /// Nothing received is ever opened or executed.
    func land(tmp: URL, name: String) -> Landed? {
        defer { unlink(tmp.path) }
        if DropName.isRasterImage(name), DropName.decodes(tmp), let e = tray().ingest(tmp) {
            didIngest()
            notify("Received \(name) from iPhone")
            return .shot(e.id)
        }
        DropFS.ensureDir(downloads)
        guard let placed = DropFS.placeExclusive(tmp, in: downloads, name: name) else { return nil }
        guard quarantine(placed) else {
            // An unquarantined download would skip Gatekeeper; refuse rather than leave it.
            unlink(placed.path)
            NSLog("True drop: could not quarantine %@; removed", placed.lastPathComponent)
            return nil
        }
        notify("Received \(placed.lastPathComponent) from iPhone")
        return .file(placed)
    }

    func newTemp(ext: String) -> URL {
        DropFS.ensureDir(tmpDir)
        return tmpDir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }

    /// Leftovers from a crash or a dropped connection.
    func sweepTemp(olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(m) > age { try? fm.removeItem(at: u) }
        }
    }
}
