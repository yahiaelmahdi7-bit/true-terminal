import Testing
import Foundation
import AppKit
@testable import True

/// A drag selection must survive a TUI repainting under it (tru's spinner, Claude Code's timer),
/// unless the program asked for the mouse, where SwiftTerm's own clear-on-output still applies.
@MainActor @Suite struct SelectionTests {
    private func bytes(_ s: String) -> ArraySlice<UInt8> { ArraySlice(Array(s.utf8)) }

    @Test func selectionSurvivesStreamingOutput() {
        let term = TrueTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        term.dataReceived(slice: bytes("hello\r\nworld\r\n"))
        term.selectAll()
        #expect(term.selectionActive)
        term.dataReceived(slice: bytes("\u{1b}[2;1H\u{1b}[2K✻ Pondering… 3s\r\nmore\r\n"))
        #expect(term.selectionActive)
        #expect(!term.allowMouseReporting)
    }

    @Test func mouseAppsKeepReportingAndClearOnOutput() {
        let term = TrueTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        term.dataReceived(slice: bytes("\u{1b}[?1000h\u{1b}[?1006h"))
        #expect(term.allowMouseReporting)   // synced right after the chunk that turned it on
        term.selectAll()
        term.dataReceived(slice: bytes("redraw\r\n"))
        #expect(!term.selectionActive)
        term.dataReceived(slice: bytes("\u{1b}[?1000l\u{1b}[?1006l"))
        #expect(!term.allowMouseReporting)
    }
}
