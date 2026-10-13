import Foundation

/// Append-only JSONL writer: one `seekToEnd + write` per record (O(record) bytes), never a whole-file rewrite.
/// Past `maxBytes` the file moves to as `name.1.ext` (older ones shift up, `keep` files at most). Files 0600.
enum JSONLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var writes: [String: Int] = [:]

    static func append(_ line: Data, to url: URL, maxBytes: Int, keep: Int) {
        let fm = FileManager.default
        lock.lock(); defer { lock.unlock() }
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= maxBytes { rotate(url, keep: keep) }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line)
        } else {
            fm.createFile(atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
        writes[url.path, default: 0] += 1
    }

    private static func rotate(_ url: URL, keep: Int) {
        let fm = FileManager.default
        guard keep > 0 else { try? fm.removeItem(at: url); return }
        func old(_ n: Int) -> URL { url.deletingPathExtension().appendingPathExtension("\(n)").appendingPathExtension(url.pathExtension) }
        try? fm.removeItem(at: old(keep))
        for n in stride(from: keep - 1, through: 1, by: -1) { try? fm.moveItem(at: old(n), to: old(n + 1)) }
        try? fm.moveItem(at: url, to: old(1))
    }

    /// Test hook: how many appends this process made to the file.
    static func writeCount(for url: URL) -> Int { lock.withLock { writes[url.path] ?? 0 } }
}

/// The rule behind the lag fix: `git`, `claude` and file scans never run on the main thread.
enum OffMain {
    static func violatesNow() -> Bool { pthread_main_np() != 0 }
    /// Call first thing in every `systemRunner`. DEBUG only: a regression traps in the debugger and in tests.
    @inline(__always) static func assertOffMain() {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
    }
}
