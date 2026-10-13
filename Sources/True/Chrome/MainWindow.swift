import AppKit
import SwiftUI

/// Which NSWindow is True's main window, by identity rather than title (a retitled main window must
/// still snapshot; another window titled "True" must not). The scene is a single-instance `Window`,
/// so there is exactly one main window and "it closed" means "True is quitting".
@MainActor
enum MainWindow {
    /// Weak: the registry never keeps a closed window alive.
    private(set) static weak var current: NSWindow?

    static func register(_ window: NSWindow) { current = window }

    /// One window across every monitor: the union of the screens' usable areas. macOS only draws a
    /// window on more than one display when System Settings ▸ Desktop & Dock ▸ "Displays have separate
    /// Spaces" is OFF; with it on, the parts beyond the window's own display stay hidden.
    static func fillAllDisplays() {
        guard let current else { return }
        current.setFrame(spanningFrame(NSScreen.screens.map(\.visibleFrame)) ?? current.frame, display: true, animate: true)
    }

    /// Smallest rectangle covering all `frames`; nil for none.
    nonisolated static func spanningFrame(_ frames: [CGRect]) -> CGRect? {
        frames.dropFirst().reduce(frames.first) { $0?.union($1) }
    }

    /// Pure decision for the willClose observer: snapshot only when the closing window IS the main one.
    /// Sheets, popovers, Settings and any other window (whatever its title) answer false.
    /// Identities (not windows) so the notification closure can carry the value across isolation.
    nonisolated static func shouldSnapshot(closing: ObjectIdentifier?, main: ObjectIdentifier?) -> Bool {
        guard let closing, let main else { return false }
        return closing == main
    }

    /// Only the main window goes buttonless; Settings and Remote Access keep their close button.
    nonisolated static func shouldHideButtons(window: ObjectIdentifier, main: ObjectIdentifier?) -> Bool {
        window == main
    }
}

/// Zero-size probe for the main scene's root view: reports its window to ``MainWindow`` once it is in one.
struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindow.register(window) }
        }
    }
}
