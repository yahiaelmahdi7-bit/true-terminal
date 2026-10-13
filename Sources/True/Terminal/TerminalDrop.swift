import AppKit
import Observation
import UniformTypeIdentifiers

/// Which pane a drag is currently hovering, so `TabContent` can draw one white hairline on it.
/// Written only by the drag callbacks — no timer, no animation.
@MainActor @Observable
final class DropTarget {
    static let shared = DropTarget()
    var pane: UUID?
}

/// The logic behind dropping files and images onto a pane: what gets pasted, and the small bit of
/// disk I/O that makes a dropped image readable by the process in the pane. Kept off the view so
/// the pure parts are testable.
///
/// Why copies exist: True and every process in its panes (e.g. `claude`) have no TCC access to
/// ~/Desktop, ~/Documents or ~/Downloads. A Finder drag grants True itself a one-file exception,
/// but the child cannot read that path, so an image from a protected folder is copied under
/// `~/.true/drops/` and the copy's path is what gets pasted.
enum TerminalDrop {
    /// Characters Terminal.app backslash-escapes in a dropped path. Everything else — notably
    /// U+202F, the narrow no-break space macOS puts in "Screenshot … at 11.43.14 AM" — is left alone.
    nonisolated private static let escaped: Set<Character> =
        Set(" \t\\'\"()[]{}<>|&;$`!*?#~=")

    nonisolated static func shellEscaped(_ path: String) -> String {
        var out = ""
        for ch in path {
            if escaped.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Escaped paths, one space apart, plus one trailing space so the user can keep typing.
    nonisolated static func pasteText(forPaths paths: [String]) -> String {
        paths.map(shellEscaped).joined(separator: " ") + " "
    }

    /// What actually goes to the PTY. Control characters other than tab and newlines are dropped
    /// everywhere: ESC because "\e[201~" would end bracketed paste early and run the rest as typed
    /// input, the rest (^C, ^D, C1 CSI…) because they would act as keystrokes. With bracketed paste
    /// off a newline would execute in a bare shell, so it becomes a space.
    nonisolated static func sanitizedPaste(_ text: String, bracketed: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            let v = u.value
            let control = v < 0x20 || (0x7F...0x9F).contains(v)
            if !control || u == "\t" || u == "\n" || u == "\r" { scalars.append(u) }
        }
        var s = String(scalars)
        if !bracketed {
            s = s.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        return s
    }

    /// `name`, or `name 2.ext`, `name 3.ext`… before the extension until `exists` says it is free.
    nonisolated static func uniqueURL(for name: String, in dir: URL, exists: (String) -> Bool) -> URL {
        let ns = name as NSString
        let ext = ns.pathExtension, base = ns.deletingPathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while exists(candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    nonisolated private static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f.string(from: date)
    }

    /// "drop-2026-09-30-114314.png" — local time, POSIX digits.
    nonisolated static func dropImageName(date: Date) -> String {
        "drop-\(stamp(date, "yyyy-MM-dd-HHmmss")).png"
    }

    /// The per-drop folder a file promise is received into.
    nonisolated static func dropFolderName(date: Date) -> String { stamp(date, "yyyyMMdd-HHmmss") }

    nonisolated static func expired(_ files: [(URL, Date)], now: Date, maxAge: TimeInterval) -> [URL] {
        files.filter { now.timeIntervalSince($0.1) > maxAge }.map(\.0)
    }

    // MARK: - I/O

    nonisolated static let maxAge: TimeInterval = 7 * 24 * 3600

    nonisolated static var dropsDir: URL { AgentPaths.standard.root.appendingPathComponent("drops") }

    /// Created on first write only, and every write prunes what is older than a week — event-driven,
    /// so there is no cleanup timer.
    nonisolated static func ensureDropsDir(_ dir: URL = dropsDir, now: Date = Date()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        let dated = entries.compactMap { url -> (URL, Date)? in
            guard let d = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { return nil }
            return (url, d)
        }
        for url in expired(dated, now: now, maxAge: maxAge) { try? fm.removeItem(at: url) }
    }

    /// True when this process cannot list `path`'s parent, i.e. the child in the pane cannot read it either.
    nonisolated static func isProtected(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) == nil
    }

    /// Above this a protected file keeps its own path rather than being duplicated on disk.
    nonisolated static let maxCopyBytes = 100 * 1024 * 1024

    /// A plain file small enough to copy — folders and packages are never copied.
    nonisolated static func isCopyable(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              v.isRegularFile == true else { return false }
        return (v.fileSize ?? 0) <= maxCopyBytes
    }

    /// The path to paste for a dropped file: a file from a folder the child cannot read (a
    /// screenshot on the Desktop, a PDF in Downloads) is copied into the drops folder; anything
    /// else (a dev dragging a file from a repo) keeps its own path.
    nonisolated static func pastePath(for url: URL) -> String {
        guard isProtected(url), isCopyable(url), let copy = copyIntoDrops(url) else { return url.path }
        return copy.path
    }

    nonisolated static func copyIntoDrops(_ url: URL) -> URL? {
        let fm = FileManager.default
        do {
            try ensureDropsDir()
            let dest = uniqueURL(for: url.lastPathComponent, in: dropsDir) { fm.fileExists(atPath: $0) }
            try fm.copyItem(at: url, to: dest)
            // A copy keeps the source's modification date; an old screenshot would be pruned at once.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        } catch { return nil }
    }

    nonisolated static func writePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let fm = FileManager.default
        do {
            try ensureDropsDir()
            let dest = uniqueURL(for: dropImageName(date: Date()), in: dropsDir) { fm.fileExists(atPath: $0) }
            try png.write(to: dest)
            return dest
        } catch { return nil }
    }

    /// A fresh subfolder for one drop's promised files.
    nonisolated static func makePromiseFolder() -> URL? {
        let fm = FileManager.default
        do {
            try ensureDropsDir()
            let dir = uniqueURL(for: dropFolderName(date: Date()), in: dropsDir) { fm.fileExists(atPath: $0) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch { return nil }
    }
}
