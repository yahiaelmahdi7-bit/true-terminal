import AppKit
import SwiftUI

/// Cursor styles the app uses, so macOS 15+ maps to `.pointerStyle` and macOS 14 to an NSCursor.
enum TrueCursor: Equatable {
    case grabIdle, grabActive, columnResize, rowResize

    var nsCursor: NSCursor {
        switch self {
        case .grabIdle: return .openHand
        case .grabActive: return .closedHand
        case .columnResize: return .resizeLeftRight
        case .rowResize: return .resizeUpDown
        }
    }
}

/// What a title-bar double-click does for a given `AppleActionOnDoubleClick` value.
enum TitleBarAction: Equatable {
    case minimize, none, zoom
    static func parse(_ v: String?) -> TitleBarAction {
        switch v {
        case "Minimize": return .minimize
        case "None": return .none
        default: return .zoom
        }
    }
}

extension View {
    /// macOS 15+: SwiftUI `.pointerStyle`. macOS 14: a cursor rect on a click-through backing view.
    @ViewBuilder func trueCursor(_ c: TrueCursor) -> some View {
        if #available(macOS 15, *) {
            switch c {
            case .grabIdle: pointerStyle(.grabIdle)
            case .grabActive: pointerStyle(.grabActive)
            case .columnResize: pointerStyle(.columnResize)
            case .rowResize: pointerStyle(.rowResize)
            }
        } else {
            background(CursorRectView(cursor: c.nsCursor))
        }
    }

    /// macOS 15+: `WindowDragGesture` + activation events. macOS 14: an AppKit view that drags the window.
    @ViewBuilder func trueWindowDrag() -> some View {
        if #available(macOS 15, *) {
            gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        } else {
            overlay(WindowDragView())
        }
    }
}

private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor
    func makeNSView(context: Context) -> View { View(cursor: cursor) }
    func updateNSView(_ v: View, context: Context) {
        if v.cursor !== cursor { v.cursor = cursor; v.window?.invalidateCursorRects(for: v) }
    }
    final class View: NSView {
        var cursor: NSCursor
        init(cursor: NSCursor) { self.cursor = cursor; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steal clicks or drags
        override func layout() { super.layout(); window?.invalidateCursorRects(for: self) }
    }
}

private struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ v: View, context: Context) {}
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                MainActor.assumeIsolated { WindowChrome.titleBarDoubleClick(window) }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
