import Foundation
import SwiftTerm
import Darwin

/// Turns a terminal's NORMAL buffer (scrollback + screen) into text that, fed to a fresh terminal of
/// the same width, redraws it with its colours. SGR is emitted only when the attributes change.
enum ScrollbackSerializer {
    static let maxLines = 5_000
    static let maxBytes = 2_000_000

    struct Style: Equatable {
        var fg: Attribute.Color, bg: Attribute.Color
        var style: CharacterStyle
        var underline: UnderlineStyle
        static var plain: Style { Style(fg: .defaultColor, bg: .defaultColor, style: [], underline: .none) }
    }

    /// The caller must have switched to the normal buffer (`ESC[?1049l`) if the pane was in an alt screen.
    static func serialize(_ t: Terminal, maxLines: Int = maxLines, maxBytes: Int = maxBytes) -> String {
        var rows: [String] = []          // one entry per logical row (soft-wrapped lines joined)
        var current = ""
        var style = Style.plain
        var open = false
        var r = t.buffer.totalLinesTrimmed
        var line = t.getScrollInvariantLine(row: r)
        while let l = line {
            let next = t.getScrollInvariantLine(row: r + 1)
            let continues = next?.isWrapped == true
            current += cells(of: l, terminal: t, trimTrailing: !continues, style: &style)
            if continues {
                open = true
            } else {
                if style != .plain { current += "\u{1b}[0m"; style = .plain }
                rows.append(current)
                current = ""; open = false
            }
            r += 1
            line = next
        }
        if open { rows.append(current + "\u{1b}[0m") }
        while let last = rows.last, last.isEmpty || last == "\u{1b}[0m" { rows.removeLast() }
        rows = Array(rows.suffix(maxLines))
        var bytes = 0
        var keep = 0
        for row in rows.reversed() {
            bytes += row.utf8.count + 2
            if bytes > maxBytes { break }
            keep += 1
        }
        return rows.suffix(keep).joined(separator: "\r\n")
    }

    static func cells(of l: BufferLine, terminal t: Terminal, trimTrailing: Bool, style: inout Style) -> String {
        var end = l.count
        if trimTrailing {
            while end > 0 {
                let c = l[end - 1]
                let blank = (t.getCharacter(for: c) == " " || t.getCharacter(for: c) == "\0") && c.attribute.bg == .defaultColor
                    && !c.attribute.style.contains(.inverse)
                if !blank && c.width != 0 { break }
                end -= 1
            }
        }
        var out = ""
        var col = 0
        while col < end {
            let c = l[col]
            col += 1
            if c.width == 0 { continue }            // placeholder after a wide char
            let s = Style(fg: c.attribute.fg, bg: c.attribute.bg, style: c.attribute.style,
                          underline: c.attribute.underlineStyle)
            if s != style { out += sgr(s); style = s }
            let ch = t.getCharacter(for: c)
            out += ch == "\0" ? " " : String(ch)   // a never-written cell reads as NUL
        }
        return out
    }

    private static func sgr(_ s: Style) -> String {
        var p = ["0"]
        if s.style.contains(.bold) { p.append("1") }
        if s.style.contains(.dim) { p.append("2") }
        if s.style.contains(.italic) { p.append("3") }
        if s.style.contains(.underline) || s.underline != .none { p.append("4") }
        if s.style.contains(.blink) { p.append("5") }
        if s.style.contains(.inverse) { p.append("7") }
        if s.style.contains(.invisible) { p.append("8") }
        if s.style.contains(.crossedOut) { p.append("9") }
        p += color(s.fg, base: 30, bright: 90, ext: 38)
        p += color(s.bg, base: 40, bright: 100, ext: 48)
        return "\u{1b}[" + p.joined(separator: ";") + "m"
    }

    private static func color(_ c: Attribute.Color, base: Int, bright: Int, ext: Int) -> [String] {
        switch c {
        case .ansi256(let code):
            let n = Int(code)
            if n < 8 { return ["\(base + n)"] }
            if n < 16 { return ["\(bright + n - 8)"] }
            return ["\(ext)", "5", "\(n)"]
        case .trueColor(let r, let g, let b): return ["\(ext)", "2", "\(r)", "\(g)", "\(b)"]
        default: return []
        }
    }
}

/// `~/.true/scrollback/<pane>.ans` + `<pane>.json`, mode 0600 (terminal output can hold secrets).
struct ScrollbackStore: Sendable {
    struct Header: Codable, Equatable, Sendable {
        var cols: Int, rows: Int
        var savedAt: Date
        var wasRunning: String?
    }
    struct Snapshot: Sendable { var bytes: [UInt8]; var header: Header }

    let dir: URL
    static let standard = ScrollbackStore(dir: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/scrollback"))

    private func ans(_ p: UUID) -> URL { dir.appendingPathComponent("\(p.uuidString).ans") }
    private func hdr(_ p: UUID) -> URL { dir.appendingPathComponent("\(p.uuidString).json") }

    func save(pane: UUID, text: String, header: Header) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let h = try? enc.encode(header) else { return }
        for (url, data) in [(ans(pane), Data(text.utf8)), (hdr(pane), h)] {
            try? data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// One-shot: returns the snapshot and deletes both files (a bad header still deletes them).
    func take(_ pane: UUID) -> Snapshot? {
        defer { remove(pane) }
        guard let d = try? Data(contentsOf: ans(pane)), let h = try? Data(contentsOf: hdr(pane)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let header = try? dec.decode(Header.self, from: h), header.cols > 0, header.rows > 0 else { return nil }
        return Snapshot(bytes: [UInt8](d), header: header)
    }

    func remove(_ pane: UUID) {
        try? FileManager.default.removeItem(at: ans(pane))
        try? FileManager.default.removeItem(at: hdr(pane))
    }

    /// Delete files of panes that are no longer in the workspace.
    func prune(keeping panes: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in names {
            let stem = (n as NSString).deletingPathExtension
            if let id = UUID(uuidString: stem), !panes.contains(id) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(n))
            }
        }
    }

    /// The dim marker line fed after the restored text (then the shell prints its prompt below it).
    static func markerLine(_ h: Header, locale: Locale = Locale(identifier: "en_GB")) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = "EEE d MMM HH:mm"
        let running = h.wasRunning.map { " · was running: \($0)" } ?? ""
        return "\u{1b}[2m── restored · \(f.string(from: h.savedAt))\(running) ──\u{1b}[0m"
    }
}
