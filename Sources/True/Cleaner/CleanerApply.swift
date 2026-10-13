import Foundation

struct ApplyRequest: Sendable {
    let file: ContextFile
    let newContent: String
}

struct ApplyResult: Equatable, Sendable {
    let path: String
    /// nil = written.
    let error: String?
}

struct UndoReport: Equatable, Sendable {
    var restored: [String] = []
    /// Files edited since the apply (or missing): left alone.
    var skipped: [String] = []
    var note: String?
}

private struct ManifestEntry: Codable, Equatable {
    let path: String
    let shaBefore: String
    let shaAfter: String
}

/// Writes approved rewrites with a backup first, and undoes the newest apply. Nothing here runs unless
/// the user clicked Apply / Undo. No git.
struct CleanerApplier: Sendable {
    var backupRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/cleaner-backups")
    var now: @Sendable () -> Date = { Date() }
    static let staleMessage = "changed since read — rescan"
    private static let manifestName = "manifest.json"

    func apply(_ requests: [ApplyRequest]) -> [ApplyResult] {
        let fm = FileManager.default
        var results: [ApplyResult] = []
        var manifest: [ManifestEntry] = []
        var dir: URL?
        for r in requests {
            let path = r.file.path
            func fail(_ m: String) { results.append(ApplyResult(path: path, error: m)) }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.size] as? NSNumber)?.intValue == r.file.size,
                  (attrs[.modificationDate] as? Date) == r.file.mtime,
                  let current = fm.contents(atPath: path), sha256Hex(current) == r.file.sha else {
                fail(Self.staleMessage); continue
            }
            do {
                let d = try dir ?? makeBackupDir()
                dir = d
                let backup = d.appendingPathComponent("files" + path)
                try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try current.write(to: backup)
                let new = Data(r.newContent.utf8)
                try Self.writeKeepingPermissions(new, to: path, like: attrs)
                manifest.append(ManifestEntry(path: path, shaBefore: r.file.sha, shaAfter: sha256Hex(new)))
                results.append(ApplyResult(path: path, error: nil))
            } catch {
                fail("write failed: \(error.localizedDescription)")
            }
        }
        if let dir, !manifest.isEmpty {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(manifest) {
                try? data.write(to: dir.appendingPathComponent(Self.manifestName), options: .atomic)
            }
        }
        return results
    }

    /// Restores every file of the newest manifest whose current content is still what Apply wrote.
    /// A fully restored manifest is renamed aside, so the next Undo reaches the apply before it.
    func undoLast() -> UndoReport {
        let fm = FileManager.default
        var report = UndoReport()
        let names = ((try? fm.contentsOfDirectory(atPath: backupRoot.path)) ?? []).sorted(by: >)
        guard let dir = names.map({ backupRoot.appendingPathComponent($0) })
            .first(where: { fm.fileExists(atPath: $0.appendingPathComponent(Self.manifestName).path) }),
              let data = fm.contents(atPath: dir.appendingPathComponent(Self.manifestName).path),
              let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) else {
            report.note = "Nothing to undo"
            return report
        }
        for e in entries {
            guard let attrs = try? fm.attributesOfItem(atPath: e.path), let now = fm.contents(atPath: e.path),
                  sha256Hex(now) == e.shaAfter,
                  let original = fm.contents(atPath: dir.appendingPathComponent("files" + e.path).path),
                  sha256Hex(original) == e.shaBefore,
                  (try? Self.writeKeepingPermissions(original, to: e.path, like: attrs)) != nil else {
                report.skipped.append(e.path); continue
            }
            report.restored.append(e.path)
        }
        if report.skipped.isEmpty {
            try? fm.moveItem(at: dir.appendingPathComponent(Self.manifestName),
                             to: dir.appendingPathComponent("manifest.undone.json"))
        }
        return report
    }

    private func makeBackupDir() throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: now())
        var d = backupRoot.appendingPathComponent(stamp)
        var n = 2
        while FileManager.default.fileExists(atPath: d.path) {   // two applies in one second
            d = backupRoot.appendingPathComponent("\(stamp)-\(n)"); n += 1
        }
        try FileManager.default.createDirectory(at: d.appendingPathComponent("files"), withIntermediateDirectories: true)
        return d
    }

    /// Atomic replace (temp file + rename), then the old permissions put back.
    private static func writeKeepingPermissions(_ data: Data, to path: String, like attrs: [FileAttributeKey: Any]) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if let perms = attrs[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: path)
        }
    }
}
