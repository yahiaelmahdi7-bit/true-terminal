import AppKit
import SwiftUI

/// Window chrome, such as it is: no traffic lights, and a black title-bar zone that holds the tab
/// numbers and still drags and double-click zooms.
@MainActor
enum WindowChrome {
    /// System Settings → Desktop & Dock → "Double-click a window's title bar to". "Fill" (the
    /// macOS 15+ default, also what an unset key means) and "Maximize" both fill the usable screen;
    /// `performZoom` does that and a second double-click puts the window back, as Warp does.
    static func titleBarDoubleClick(_ window: NSWindow) {
        switch TitleBarAction.parse(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
        case .minimize: window.performMiniaturize(nil)
        case .none: break
        case .zoom: window.performZoom(nil)
        }
    }

    /// No traffic lights: True is black with no chrome. ⌘W / ⌘M / ⌘Q and the Window menu still
    /// close, minimise and quit. Called on every key-window change (AppKit re-adds them after
    /// full screen).
    static func hideButtons(_ window: NSWindow) {
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = true
        }
    }

    /// Black, buttonless title-bar zone with no separator line. Runs as soon as the window exists
    /// (a window launched behind others never becomes key, so the key-change hook alone misses it).
    static func configure(_ window: NSWindow) {
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.nsBackground
        hideButtons(window)
        installTabs(window)
    }

    private static let tabsID = NSUserInterfaceItemIdentifier("true.tabs")

    /// The tab row goes INTO the 32pt title-bar zone rather than under it. SwiftUI content laid out
    /// there never paints on macOS 26, but the title bar's own subviews do (it's where the traffic
    /// lights draw), so the row is an AppKit-hosted view parented to the title bar itself.
    static func installTabs(_ window: NSWindow) {
        guard let bar = window.standardWindowButton(.closeButton)?.superview,
              !bar.subviews.contains(where: { $0.identifier == tabsID }) else { return }
        let host = NSHostingView(rootView: TabBar(model: .shared).preferredColorScheme(.dark))
        host.identifier = tabsID
        host.sizingOptions = []   // the title bar sizes the row, never the reverse
        host.frame = bar.bounds
        host.autoresizingMask = [.width, .height]
        bar.addSubview(host)
    }
}

/// Zero-size probe that hands its window to ``WindowChrome/configure(_:)`` once it is in one.
/// Lives in the root's background, away from the tab row.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WindowChrome.configure(window) }
        }
    }
}

extension View {
    /// Make this bar's empty space act like a title bar (drag, double-click zoom) on a black
    /// backing. Controls in the bar keep their own clicks: a background only gets what they miss.
    func windowChromeArea() -> some View {
        background {
            Theme.background
                .contentShape(Rectangle())
                .trueWindowDrag()
                .onTapGesture(count: 2) { if let w = NSApp.keyWindow { WindowChrome.titleBarDoubleClick(w) } }
        }
    }
}
