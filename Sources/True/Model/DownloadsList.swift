import Foundation
import Observation
import Dispatch

struct DownloadItem: Equatable, Identifiable, Sendable {
    let name: String
    let url: URL
    let isDirectory: Bool
    let size: Int
    let modified: Date
    var id: String { url.path }
}

/// The recent-downloads list behind the panel's Downloads strip. Points at files in place — never copies.
/// The filter mirrors the Claude Code mod's `/dl`: top level only, no dotfiles, no partial downloads.
enum DownloadsList {
    static let partialSuffixes = [".crdownload", ".download", ".part", ".partial", ".tmp"]

    static func recent(_ entries: [DownloadItem], limit: Int = 8) -> [DownloadItem] {
        let kept = entries.filter { item in
            let lower = item.name.lowercased()
            return !item.name.hasPrefix(".") && !partialSuffixes.contains { lower.hasSuffix($0) }
        }
        let sorted = kept.sorted { a, b in
            a.modified != b.modified ? a.modified > b.modified : a.name < b.name
        }
        return Array(sorted.prefix(limit))
    }

    /// nil when the directory cannot be listed (privacy denied, or gone).
    static func list(directory: URL, limit: Int = 8) -> [DownloadItem]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []) else { return nil }
        let items = urls.map { url -> DownloadItem in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return DownloadItem(name: url.lastPathComponent, url: url, isDirectory: v?.isDirectory ?? false,
                                size: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast)
        }
        return recent(items, limit: limit)
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}

/// Live state for the strip. Refreshes only while `start()`ed (panel expanded): one kqueue vnode source
/// on the directory, no timer; `stop()` cancels it.
@MainActor @Observable
final class DownloadsWatcher {
    static let shared = DownloadsWatcher()

    private(set) var items: [DownloadItem] = []
    private(set) var unreadable = false
    let directory: URL
    private var source: DispatchSourceFileSystemObject?

    init(directory: URL = DownloadsList.defaultDirectory) { self.directory = directory }

    func start() {
        refresh()
        guard source == nil else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    func refresh() {
        let dir = directory
        Task {
            let result = await Task.detached { DownloadsList.list(directory: dir) }.value
            items = result ?? []
            unreadable = result == nil
        }
    }
}
