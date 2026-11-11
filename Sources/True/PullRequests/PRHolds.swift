import Foundation

struct HoldEntry: Codable, Equatable, Sendable {
    var repo: String
    var number: Int
    var since: String
    var why: String
}

/// `~/.true/pr-holds.json`: the user's brake. The app is the single writer. Holds follow the PR number,
/// not the head. `release` is called only by the app's own UI; no socket verb reaches it.
final class PRHoldStore: @unchecked Sendable {
    private struct File: Codable { var version: Int; var holds: [HoldEntry] }
    private let path: String
    private let lock = NSLock()

    init(path: String = NSHomeDirectory() + "/.true/pr-holds.json") { self.path = path }

    func all() -> [HoldEntry] { lock.lock(); defer { lock.unlock() }; return read() }

    func entry(repo: String, number: Int) -> HoldEntry? {
        all().first { $0.repo == repo && $0.number == number }
    }

    @discardableResult
    func hold(repo: String, number: Int, why: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var holds = read().filter { !($0.repo == repo && $0.number == number) }
        holds.append(HoldEntry(repo: repo, number: number, since: ISO8601DateFormatter().string(from: now),
                               why: why.trimmingCharacters(in: .whitespacesAndNewlines)))
        return write(holds)
    }

    /// App UI only.
    @discardableResult
    func release(repo: String, number: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return write(read().filter { !($0.repo == repo && $0.number == number) })
    }

    private func read() -> [HoldEntry] {
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.holds
    }

    private func write(_ holds: [HoldEntry]) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? enc.encode(File(version: 1, holds: holds)) else { return false }
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".pr-holds-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch { try? fm.removeItem(at: tmp); return false }
    }
}
