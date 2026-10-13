import Foundation
import SwiftTerm

/// A pane's current screen (plus recent history) as a byte stream a fresh xterm of the SAME size can
/// replay: reset, history lines, then each visible row placed with an absolute cursor move, then the
/// cursor position. Absolute placement matters: a TUI like Claude redraws with relative moves from
/// where its cursor is, so the snapshot must leave the client's cursor exactly where the Mac's is.
enum RemoteSnapshot {
    static let historyLines = 1_000

    static func render(_ t: Terminal) -> [UInt8] {
        var out = "\u{1b}c"
        let alt = t.isCurrentBufferAlternate
        if alt { out += "\u{1b}[?1049h" }
        let rows = t.rows
        var first = t.buffer.totalLinesTrimmed
        var count = 0
        while t.getScrollInvariantLine(row: first + count) != nil { count += 1 }
        let screenTop = first + max(0, count - rows)
        if !alt {
            first = max(first, screenTop - historyLines)
            var style = ScrollbackSerializer.Style.plain
            var r = first
            while r < screenTop, let l = t.getScrollInvariantLine(row: r) {
                let continues = t.getScrollInvariantLine(row: r + 1)?.isWrapped == true && r + 1 < screenTop
                out += ScrollbackSerializer.cells(of: l, terminal: t, trimTrailing: !continues, style: &style)
                if !continues { out += "\u{1b}[0m\r\n"; style = .plain }
                r += 1
            }
            // Push history out of the viewport so the screen rows below land on a clean grid.
            out += String(repeating: "\r\n", count: rows) + "\u{1b}[2J"
        }
        var style = ScrollbackSerializer.Style.plain
        for i in 0..<rows {
            guard let l = t.getScrollInvariantLine(row: screenTop + i) else { break }
            out += "\u{1b}[\(i + 1);1H"
            out += ScrollbackSerializer.cells(of: l, terminal: t, trimTrailing: true, style: &style)
            if style != .plain { out += "\u{1b}[0m"; style = .plain }
        }
        let cur = t.getCursorLocation()
        out += "\u{1b}[\(cur.y + 1);\(cur.x + 1)H"
        return Array(out.utf8)
    }
}
