import AppKit
import ImageIO
import Observation

/// Watches the screenshot folder so the tab bar can show "a new screenshot landed" and the tray can
/// list the latest few. Event-driven only: one kqueue vnode source on the folder, no timers, and the
/// pasteboard is read once per tray open, never polled.
@MainActor @Observable
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    struct Shot: Identifiable, Equatable, Sendable {
        let url: URL
        let date: Date
        var id: String { url.path }
    }

    /// One directory entry, reduced to what selection needs — so `select` is testable without disk.
    struct Entry: Sendable {
        var name: String
        var url: URL
        var date: Date
        var isRegularFile: Bool
        var isScreenCaptureFlag: Bool
    }

    nonisolated static let limit = 9
    static let lastSeenKey = "screenshotTray.lastSeen"

    /// The panel's data: True's own copies (TrayStore), newest first, at most 24.
    private(set) var entries: [TrayEntry] = []
    private(set) var fresh = false
    private(set) var folder: URL
    private(set) var unreadable = false
    private(set) var thumbnails: [String: NSImage] = [:]
    /// Set while a shot is being removed so the panel can offer undo.
    private(set) var lastRemoved: TrayStore.Removed?

    let store: TrayStore

    private var lastSeen: Date?
    private var source: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    private var debounce: Task<Void, Never>?
    private var loading: Set<String> = []

    private init(store: TrayStore = TrayStore()) {
        self.store = store
        folder = Self.currentFolder()
        let d = UserDefaults.standard
        if let seen = d.object(forKey: Self.lastSeenKey) as? Date {
            lastSeen = seen
        } else {
            // First ever run: whatever is already on disk is old news, never "fresh".
            let now = Date()
            lastSeen = now
            d.set(now, forKey: Self.lastSeenKey)
        }
    }

    // MARK: - Pure logic

    nonisolated static func isScreenshotName(_ name: String) -> Bool {
        name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ")
    }

    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif"]

    nonisolated static func isImageFile(_ name: String) -> Bool {
        imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Screenshots only, newest first, at most `limit`. macOS writes `.Screenshot…` temp files and
    /// renames them, so hidden names are skipped; the xattr flag covers non-English macOS.
    nonisolated static func select(_ entries: [Entry], limit: Int) -> [Shot] {
        entries
            .filter { e in
                !e.name.hasPrefix(".") && e.isRegularFile && isImageFile(e.name)
                    && (isScreenshotName(e.name) || e.isScreenCaptureFlag)
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { Shot(url: $0.url, date: $0.date) }
    }

    /// With no `lastSeen` we cannot tell, so nothing counts as fresh.
    nonisolated static func isFresh(newest: Date?, lastSeen: Date?) -> Bool {
        guard let newest, let lastSeen else { return false }
        return newest > lastSeen
    }

    /// The `location` default: nil/empty → ~/Desktop; `~` expanded; a trailing slash tolerated.
    nonisolated static func folder(fromDefaultsValue value: String?, home: URL) -> URL {
        guard var s = value?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        if s == "~" { s = home.path } else if s.hasPrefix("~/") { s = home.path + "/" + s.dropFirst(2) }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return URL(fileURLWithPath: s, isDirectory: true)
    }

    /// "now", "2m", "1h", "Yesterday", else a short date ("Sep 3").
    nonisolated static func relativeLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(secs / 3600))h" }
        if calendar.date(byAdding: .day, value: -1, to: now).map({ calendar.isDate(date, inSameDayAs: $0) }) == true { return "Yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    // MARK: - Disk (off the main actor)

    nonisolated static func currentFolder() -> URL {
        let value = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        return folder(fromDefaultsValue: value, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The folder to watch after re-reading the `location` default; nil when it has not changed.
    nonisolated static func folderChange(from current: URL, defaultsValue: String?, home: URL) -> URL? {
        let next = folder(fromDefaultsValue: defaultsValue, home: home)
        return next == current ? nil : next
    }

    nonisolated static func hasScreenCaptureFlag(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }

    /// nil when the folder cannot be listed (privacy denied, or gone).
    nonisolated static func scan(_ folder: URL, limit: Int = ScreenshotWatcher.limit) -> [Shot]? {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        let entries = urls.compactMap { url -> Entry? in
            let name = url.lastPathComponent
            guard isImageFile(name), let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(name: name, url: url,
                         date: v.creationDate ?? v.contentModificationDate ?? .distantPast,
                         isRegularFile: v.isRegularFile ?? false,
                         isScreenCaptureFlag: isScreenshotName(name) ? false : hasScreenCaptureFlag(url))
        }
        return select(entries, limit: limit)
    }

    nonisolated static func makeThumbnail(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: - Watching

    /// Launch side effects: one kqueue watch on the screenshot folder (0% CPU when idle), one catch-up
    /// ingest of anything newer than the newest copy (first run: backfill the newest 24 from the folder and
    /// ~/Desktop), and a re-read of the folder setting whenever True becomes active.
    func start() {
        folder = Self.currentFolder()
        startWatch()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckFolder() }
        }
        let dir = folder, store = store
        Task {
            let result = await Task.detached { () -> [TrayEntry] in
                if store.isFirstRun() {
                    let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
                    store.backfill(folders: [dir, desktop])
                } else {
                    store.ingestNewer(in: dir)
                }
                return store.load().shots
            }.value
            apply(result)
        }
    }

    /// Follow the screenshot-location setting: called on activation and when the panel expands.
    func recheckFolder() {
        let value = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let next = Self.folderChange(from: folder, defaultsValue: value,
                                        home: FileManager.default.homeDirectoryForCurrentUser) {
            folder = next
            startWatch()
            folderChanged()
        } else if watchedFolder != folder || source == nil {
            startWatch()
        }
    }

    private func startWatch() {
        source?.cancel()
        source = nil
        watchedFolder = nil
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { unreadable = true; return }
        unreadable = false
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        watchedFolder = folder
    }

    private func folderChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.ingestFolder()
        }
    }

    /// Every new shot goes into the store (a copy), then the panel re-reads the index.
    private func ingestFolder() async {
        let dir = folder, store = store
        let result = await Task.detached { () -> [TrayEntry] in
            store.ingestNewer(in: dir)
            return store.load().shots
        }.value
        guard dir == folder else { return }
        apply(result)
    }

    func refresh() async { await reload() }

    private func reload() async {
        let store = store
        apply(await Task.detached { store.load().shots }.value)
    }

    private func apply(_ result: [TrayEntry]) {
        entries = result
        let live = Set(result.map(\.id))
        thumbnails = thumbnails.filter { live.contains($0.key) }
        fresh = Self.isFresh(newest: result.first?.created, lastSeen: lastSeen)
    }

    func markSeen() {
        let seen = max(entries.first?.created ?? .distantPast, Date())
        lastSeen = seen
        UserDefaults.standard.set(seen, forKey: Self.lastSeenKey)
        fresh = false
    }

    // MARK: - Thumbnails

    func thumbnail(for entry: TrayEntry) -> NSImage? { thumbnails[entry.id] }

    func loadThumbnail(for entry: TrayEntry) async {
        let key = entry.id
        guard thumbnails[key] == nil, loading.insert(key).inserted else { return }
        let url = store.url(for: entry)
        let image = await Task.detached { () -> NSImage? in
            guard let cg = Self.makeThumbnail(url) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        loading.remove(key)
        if let image { thumbnails[key] = image }
    }

    // MARK: - Editing the tray

    func fileURL(for entry: TrayEntry) -> URL { store.url(for: entry) }

    /// Remove (to the Trash, with undo via `restoreLastRemoved`).
    func remove(_ entry: TrayEntry) {
        let store = store
        Task {
            let removed = await Task.detached { store.remove(id: entry.id) }.value
            lastRemoved = removed
            await reload()
        }
    }

    /// Drag-in: copy dropped image files into the tray through `TrayStore.ingest` (the 24-cap applies).
    /// Returns how many were actually added (duplicates of an already-ingested file add nothing).
    func ingestDropped(_ urls: [URL]) async -> Int {
        let store = store
        let added = await Task.detached { store.ingest(urls).count }.value
        await reload()
        return added
    }

    func restoreLastRemoved() {
        guard let removed = lastRemoved else { return }
        lastRemoved = nil
        let store = store
        Task {
            _ = await Task.detached { store.restore(removed) }.value
            await reload()
        }
    }

    /// A saved markup becomes a new tray entry (kind markup, parent = the shot it was drawn on).
    func addMarkup(png: Data, parent: TrayEntry) async -> TrayEntry? {
        let store = store
        let e = await Task.detached { store.addMarkup(png: png, parent: parent.id, width: parent.width, height: parent.height) }.value
        await reload()
        return e
    }

    // MARK: - Using a shot

    /// Send to session: paste the copy's path into True's focused pane and log it in the outbox.
    func send(_ entry: TrayEntry) {
        let url = store.url(for: entry)
        let store = store
        Task.detached { store.appendOutbox(id: entry.id, path: url.path) }
        paste(path: TerminalDrop.pastePath(for: url))
    }

    /// ⌥⌘V: the newest shot in the store, exactly like Send. No-op if there is none.
    func pasteLatest() {
        if entries.isEmpty { entries = store.load().shots }   // not loaded yet: one small file read
        guard let entry = entries.first else { return }
        send(entry)
    }

    /// Send to session for a file that is not a tray shot (a download): paste only, no outbox entry.
    func sendPath(_ url: URL) { paste(path: TerminalDrop.pastePath(for: url)) }

    private func paste(path: String) {
        markSeen()
        let pane = WorkspaceModel.shared.selectedTab.focusedPane
        guard let view = TerminalRegistry.shared.view(for: pane) else { return }
        view.pasteText(TerminalDrop.pasteText(forPaths: [path]))
        view.window?.makeFirstResponder(view)
        WorkspaceModel.shared.focus(pane: pane)
    }
}
