import Foundation
import ImageIO

/// One tray shot as recorded in `index.json` — the field names are a contract (a Claude Code mod reads them).
struct TrayEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case original, markup }
    var id: String
    var file: String            // "shots/<id>.<ext>", relative to the store root
    var created: Date
    var kind: Kind
    var parent: String?
    var source: String?
    var width: Int
    var height: Int

    private enum CodingKeys: String, CodingKey { case id, file, created, kind, parent, source, width, height }

    init(id: String, file: String, created: Date, kind: Kind, parent: String?, source: String?, width: Int, height: Int) {
        self.id = id; self.file = file; self.created = created; self.kind = kind
        self.parent = parent; self.source = source; self.width = width; self.height = height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        file = try c.decode(String.self, forKey: .file)
        let s = try c.decode(String.self, forKey: .created)
        guard let d = TrayStore.parseISO(s) else {
            throw DecodingError.dataCorruptedError(forKey: .created, in: c, debugDescription: "bad date")
        }
        created = d
        kind = try c.decode(Kind.self, forKey: .kind)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(file, forKey: .file)
        try c.encode(TrayStore.isoString(created), forKey: .created)
        try c.encode(kind, forKey: .kind)
        try c.encode(parent, forKey: .parent)   // explicit null, per the contract
        try c.encode(source, forKey: .source)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
    }
}

struct TrayIndex: Codable, Equatable, Sendable {
    var version = 1
    var updated: String = ""
    var shots: [TrayEntry] = []
}

/// True's own copies of screenshots: `~/Library/Application Support/True/ScreenshotTray/`. Copies, never
/// moves; the originals are not touched. Synchronous and lock-guarded — callers run it off the main thread
/// (`Task.detached`). It never throws: a failed step returns nil / false and leaves the tray as it was.
final class TrayStore: @unchecked Sendable {
    static let limit = 24
    static let outboxTrimAt = 1000
    static let outboxKeep = 200

    /// A removed shot, kept so the undo toast can put it back.
    struct Removed: Sendable { let entry: TrayEntry; let trashed: URL? }

    let root: URL
    private let trash: @Sendable (URL) -> URL?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var fm: FileManager { .default }

    static let defaultRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/True/ScreenshotTray", isDirectory: true)

    /// Default trash moves the file to the user's Trash (never a hard delete).
    static let systemTrash: @Sendable (URL) -> URL? = { url in
        var out: NSURL?
        do { try FileManager.default.trashItem(at: url, resultingItemURL: &out) } catch { return nil }
        return out as URL?
    }

    init(root: URL = TrayStore.defaultRoot,
         trash: @escaping @Sendable (URL) -> URL? = TrayStore.systemTrash,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root; self.trash = trash; self.now = now
    }

    var shotsDir: URL { root.appendingPathComponent("shots", isDirectory: true) }
    var indexURL: URL { root.appendingPathComponent("index.json") }
    var outboxURL: URL { root.appendingPathComponent("outbox.jsonl") }
    func url(for entry: TrayEntry) -> URL { root.appendingPathComponent(entry.file) }

    // MARK: - Pure helpers

    nonisolated static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    nonisolated static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// `yyyyMMdd-HHmmss-<4 hex>`: sortable, unique. Local time, POSIX digits.
    nonisolated static func makeID(date: Date, suffix: UInt16) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + "-" + String(format: "%04x", suffix)
    }

    // MARK: - Reading

    /// The index, newest first. Missing or corrupt → rebuilt from `shots/` by file date (no file is lost).
    func load() -> TrayIndex {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    private func loadLocked() -> TrayIndex {
        if let data = try? Data(contentsOf: indexURL), let idx = try? JSONDecoder().decode(TrayIndex.self, from: data) {
            return idx
        }
        let rebuilt = rebuild()
        if !rebuilt.shots.isEmpty || fm.fileExists(atPath: indexURL.path) { writeIndex(rebuilt) }
        return rebuilt
    }

    private func rebuild() -> TrayIndex {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: shotsDir, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        var entries: [TrayEntry] = []
        for u in urls where ScreenshotWatcher.isImageFile(u.lastPathComponent) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let date = v?.contentModificationDate ?? v?.creationDate ?? .distantPast
            let (w, h) = Self.pixelSize(u)
            let id = u.deletingPathExtension().lastPathComponent
            entries.append(TrayEntry(id: id, file: "shots/" + u.lastPathComponent, created: date, kind: .original,
                                     parent: nil, source: nil, width: w, height: h))
        }
        entries.sort { $0.created > $1.created }
        return TrayIndex(version: 1, updated: Self.isoString(now()), shots: entries)
    }

    nonisolated static func pixelSize(_ url: URL) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }

    // MARK: - Writing

    /// Atomic: temp file in the same directory, then rename over the index.
    private func writeIndex(_ index: TrayIndex) {
        var idx = index
        idx.updated = Self.isoString(now())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(idx) else { return }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent(".index.json.tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
            if fm.fileExists(atPath: indexURL.path) {
                _ = try fm.replaceItemAt(indexURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: indexURL)
            }
        } catch {
            try? fm.removeItem(at: tmp)
        }
    }

    /// Insert keeping newest-first (a tie goes in front), then prune beyond the limit to the Trash.
    private func insert(_ e: TrayEntry, into index: inout TrayIndex) {
        let at = index.shots.firstIndex { $0.created <= e.created } ?? index.shots.count
        index.shots.insert(e, at: at)
        while index.shots.count > Self.limit {
            let old = index.shots.removeLast()
            _ = trash(url(for: old))
        }
    }

    private func freshID(date: Date, index: TrayIndex) -> String {
        for _ in 0..<64 {
            let id = Self.makeID(date: date, suffix: UInt16.random(in: 0...UInt16.max))
            if !index.shots.contains(where: { $0.id == id }) { return id }
        }
        return Self.makeID(date: date, suffix: UInt16.random(in: 0...UInt16.max)) + "x"
    }

    private func isDuplicate(_ source: URL, in index: TrayIndex) -> Bool {
        let path = source.path
        guard let v = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
        for e in index.shots where e.source == path {
            guard let cv = try? url(for: e).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            if cv.fileSize == v.fileSize,
               let a = cv.contentModificationDate, let b = v.contentModificationDate,
               abs(a.timeIntervalSince(b)) < 1 { return true }
        }
        return false
    }

    /// Copy one original into the tray. nil = already there (deduped), unreadable, or the copy failed.
    @discardableResult
    func ingest(_ source: URL, created: Date? = nil) -> TrayEntry? {
        ingest([source], created: created.map { [$0] }).first
    }

    /// Ingest several originals with one index write. Returns the entries actually added.
    @discardableResult
    func ingest(_ sources: [URL], created: [Date]? = nil) -> [TrayEntry] {
        lock.lock(); defer { lock.unlock() }
        try? fm.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        var index = loadLocked()
        var added: [TrayEntry] = []
        for (i, given) in sources.enumerated() {
            let src = URL(fileURLWithPath: given.path)   // a fresh URL: resource values are cached per URL object
            guard !isDuplicate(src, in: index),
                  let v = try? src.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) else { continue }
            let mtime = v.contentModificationDate ?? now()
            let date = created?[i] ?? v.creationDate ?? mtime
            let id = freshID(date: date, index: index)
            let ext = src.pathExtension.lowercased()
            let rel = "shots/\(id).\(ext.isEmpty ? "png" : ext)"
            let dest = root.appendingPathComponent(rel)
            do {
                try fm.copyItem(at: src, to: dest)
                // The copy carries the original's mtime: that is what dedupe compares on the next sighting.
                try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dest.path)
            } catch { try? fm.removeItem(at: dest); continue }
            let (w, h) = Self.pixelSize(dest)
            let e = TrayEntry(id: id, file: rel, created: date, kind: .original, parent: nil,
                              source: src.path, width: w, height: h)
            insert(e, into: &index)
            added.append(e)
        }
        if !added.isEmpty { writeIndex(index) }
        return added.filter { a in index.shots.contains { $0.id == a.id } }   // pruned ones never surface
    }

    /// A saved markup: PNG bytes become a new `kind: markup` entry whose parent is the shot it was drawn on.
    func addMarkup(png: Data, parent: String, width: Int, height: Int) -> TrayEntry? {
        lock.lock(); defer { lock.unlock() }
        try? fm.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        var index = loadLocked()
        let date = now()
        let id = freshID(date: date, index: index)
        let rel = "shots/\(id).png"
        let dest = root.appendingPathComponent(rel)
        do { try png.write(to: dest, options: .atomic) } catch { return nil }
        let e = TrayEntry(id: id, file: rel, created: date, kind: .markup, parent: parent, source: nil,
                          width: width, height: height)
        insert(e, into: &index)
        writeIndex(index)
        return e
    }

    /// A fresh capture (Run 27): PNG bytes become a new `kind: original` entry with no source and no parent.
    func addCapture(png: Data, width: Int, height: Int) -> TrayEntry? {
        lock.lock(); defer { lock.unlock() }
        try? fm.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        var index = loadLocked()
        let date = now()
        let id = freshID(date: date, index: index)
        let rel = "shots/\(id).png"
        do { try png.write(to: root.appendingPathComponent(rel), options: .atomic) } catch { return nil }
        let e = TrayEntry(id: id, file: rel, created: date, kind: .original, parent: nil, source: nil,
                          width: width, height: height)
        insert(e, into: &index)
        writeIndex(index)
        return e
    }

    /// Remove from the tray: the copy goes to the Trash (never hard-deleted).
    func remove(id: String) -> Removed? {
        lock.lock(); defer { lock.unlock() }
        var index = loadLocked()
        guard let i = index.shots.firstIndex(where: { $0.id == id }) else { return nil }
        let e = index.shots.remove(at: i)
        let trashed = trash(url(for: e))
        writeIndex(index)
        return Removed(entry: e, trashed: trashed)
    }

    /// Undo of `remove`: bring the copy back from the Trash and re-insert the entry.
    @discardableResult
    func restore(_ removed: Removed) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = removed.trashed else { return false }
        let dest = url(for: removed.entry)
        do {
            try fm.createDirectory(at: shotsDir, withIntermediateDirectories: true)
            try fm.moveItem(at: t, to: dest)
        } catch { return false }
        var index = loadLocked()
        if !index.shots.contains(where: { $0.id == removed.entry.id }) { insert(removed.entry, into: &index) }
        writeIndex(index)
        return true
    }

    // MARK: - First run backfill

    /// True on the very first run: no index and nothing in `shots/`.
    func isFirstRun() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let hasShots = ((try? fm.contentsOfDirectory(atPath: shotsDir.path)) ?? []).contains { !$0.hasPrefix(".") }
        return !fm.fileExists(atPath: indexURL.path) && !hasShots
    }

    /// The newest `limit` screenshot-named images across `folders`, newest first.
    nonisolated static func newestScreenshots(in folders: [URL], limit: Int = TrayStore.limit) -> [ScreenshotWatcher.Shot] {
        var seen = Set<String>()
        let all = folders.flatMap { ScreenshotWatcher.scan($0, limit: limit) ?? [] }
            .filter { seen.insert($0.url.standardizedFileURL.path).inserted }
        return Array(all.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Copy the newest 24 screenshots from `folders` (current folder + ~/Desktop on first run).
    @discardableResult
    func backfill(folders: [URL]) -> [TrayEntry] {
        let shots = Self.newestScreenshots(in: folders)
        return ingest(shots.map(\.url), created: shots.map(\.date))
    }

    /// Launch catch-up: anything in `folder` newer than the newest index entry (one listing).
    @discardableResult
    func ingestNewer(in folder: URL) -> [TrayEntry] {
        let newest = load().shots.first?.created ?? .distantPast
        let fresh = (ScreenshotWatcher.scan(folder, limit: Self.limit) ?? []).filter { $0.date > newest }
        return ingest(fresh.map(\.url), created: fresh.map(\.date))
    }

    // MARK: - Outbox

    /// One line per "Send", append-only. Trimmed to the last 200 lines only once it passes 1000.
    func appendOutbox(id: String, path: String) {
        lock.lock(); defer { lock.unlock() }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let obj: [String: String] = ["ts": Self.isoString(now()), "id": id, "path": path, "action": "send"]
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if !fm.fileExists(atPath: outboxURL.path) { fm.createFile(atPath: outboxURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: outboxURL) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
        trimOutboxIfNeeded()
    }

    private func trimOutboxIfNeeded() {
        guard let text = try? String(contentsOf: outboxURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > Self.outboxTrimAt else { return }
        let kept = lines.suffix(Self.outboxKeep).joined(separator: "\n") + "\n"
        let tmp = root.appendingPathComponent(".outbox.jsonl.tmp-\(UUID().uuidString)")
        do {
            try kept.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try fm.replaceItemAt(outboxURL, withItemAt: tmp)
        } catch { try? fm.removeItem(at: tmp) }
    }
}
