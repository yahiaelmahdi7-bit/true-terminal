import Testing
import Foundation
import SwiftTerm
@testable import True

private final class SilentTerminal: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// The detector on Axon's recorded sessions (copied under Fixtures/): a live dialog is visible; the
/// same pane after the dialog was answered is not.
@Suite struct NeedsYouTests {
    static let recorded: [(String, Bool)] = [
        ("A-dialog", true), ("B-after1s", false), ("B-after6s", false),
        ("C-dialog2", true), ("D-afterEsc1s", false), ("D-afterEsc5s", false),
    ]

    private static func recording(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/permission-dialog/\(name).raw"))
    }

    @Test(arguments: recorded)
    func recordedDialogOnScreen(name: String, visible: Bool) throws {
        let terminal = Terminal(delegate: SilentTerminal(), options: TerminalOptions(cols: 150, rows: 45))
        terminal.feed(byteArray: [UInt8](try Self.recording(name)))
        #expect(PermissionDialog.isVisible(in: PermissionDialog.screenText(terminal)) == visible, "\(name)")
    }

    @Test func proseIsNotADialog() {
        #expect(!PermissionDialog.isVisible(in: "Do you want to proceed?\n1. Yes\n2. No\nmore prose here\nand more\nand more\nand more"))
        #expect(PermissionDialog.isVisible(in: "Do you want to proceed?\n❯ 1. Yes\n  2. No (esc)\nEsc to cancel"))
    }

    @Test @MainActor func answerKeys() {
        #expect(PaneDelivery.answerKey(approve: true) == "1")
        #expect(PaneDelivery.answerKey(approve: false) == "\u{1B}")
        #expect(PaneDelivery.flatten("a\n  b\n\nc") == "a b c")
    }

    @Test @MainActor func rowsAreOldestFirstAndSkipResolved() {
        let p1 = UUID(), p2 = UUID(), p3 = UUID()
        let t = Date()
        let events: [UUID: PaneEvent] = [
            p1: PaneEvent(pane: p1, kind: .need, message: "b", at: t.addingTimeInterval(5)),
            p2: PaneEvent(pane: p2, kind: .need, message: "a", at: t),
            p3: PaneEvent(pane: p3, kind: .stop, message: "", at: t),
        ]
        let rows = NeedsYouQueue.rows(events: events, seat: { _ in nil })
        #expect(rows.map(\.paneID) == [p2, p1])
        #expect(NeedsYouQueue.rows(events: events, seat: { _ in nil }, resolved: [p2: t]).map(\.paneID) == [p1])
    }
}
