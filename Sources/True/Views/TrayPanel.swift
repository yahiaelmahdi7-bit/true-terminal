import SwiftUI
import AppKit
import Observation

enum TrayMode: Equatable { case collapsed, grid, zoom(String) }

/// The always-on floating screenshot panel: a non-activating NSPanel pinned to the top-right of the screen
/// under the mouse, above every app, on every Space. It never takes the app's focus; it becomes key only
/// when clicked while expanded (so Esc / ⌘Z / typing a label work) and gives it back on collapse.
@MainActor @Observable
final class TrayPanelController {
    static let shared = TrayPanelController()
    static let visibleKey = "screenshotTray.panelVisible"

    static let inset: CGFloat = 12
    static let collapsedSize = CGSize(width: 156, height: 48)
    static let gridSize = CGSize(width: 444, height: 372)
    /// Height of the screenshot area inside the grid panel (gridSize minus padding and header row).
    static let shotsAreaHeight: CGFloat = 312
    static let downloadRowHeight: CGFloat = 32
    static let zoomChrome: CGFloat = 46
    static let spring = Animation.spring(duration: 0.3, bounce: 0.1)

    private(set) var mode: TrayMode = .collapsed
    private(set) var visible: Bool
    /// True while the markup editor is open; click-away must not throw away unsaved marks.
    var markingUp = false
    var markupDirty = false
    var toast: String?
    /// Corner of the visible frame the chip rests in; remembered across launches (per corner, not coordinates).
    private(set) var corner: PanelCorner = PanelCorner.load()

    private let watcher = ScreenshotWatcher.shared
    private let downloads = DownloadsWatcher.shared
    private var panel: TrayPanel?
    private var monitors: [Any] = []
    private var toastTask: Task<Void, Never>?

    private init() {
        UserDefaults.standard.register(defaults: [Self.visibleKey: true])
        visible = UserDefaults.standard.bool(forKey: Self.visibleKey)
    }

    // MARK: - Lifecycle

    /// Launch side effect: build the panel and show it (unless hidden by the menu toggle last time).
    func start() {
        let p = TrayPanel()
        let host = NSHostingView(rootView: TrayPanelRoot(controller: self))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // A display went away or moved: fall back to the remembered corner on the main screen.
            MainActor.assumeIsolated { self?.place(animated: false, on: NSScreen.main ?? NSScreen.screens.first) }
        }
        installClickAway()
        if visible { show() }
    }

    func setVisible(_ on: Bool) {
        visible = on
        UserDefaults.standard.set(on, forKey: Self.visibleKey)
        if on { show() } else { panel?.orderOut(nil) }
    }

    private func show() {
        place(animated: false)
        panel?.orderFrontRegardless()
    }

    // MARK: - Mode

    func set(_ new: TrayMode) {
        guard new != mode else { return }
        if new != .collapsed { watcher.recheckFolder(); watcher.markSeen() }
        if new == .collapsed { downloads.stop() } else { downloads.start() }
        withAnimation(Self.spring) { mode = new }
        if new == .collapsed { markingUp = false; markupDirty = false }
        panel?.allowsKey = new != .collapsed
        place(animated: true)
        if new == .collapsed { panel?.resignKey() }
    }

    /// ⇧⌘S: expanded ⇄ collapsed (shows the panel first if it was hidden).
    func toggleExpanded() {
        if !visible { setVisible(true) }
        set(mode == .collapsed ? .grid : .collapsed)
    }

    /// Esc: leave markup (discarding), else step back out: zoom → grid → collapsed.
    func escape() {
        if markingUp { markingUp = false; markupDirty = false; return }
        switch mode {
        case .zoom: set(.grid)
        case .grid: set(.collapsed)
        case .collapsed: break
        }
    }

    func makeKey() { panel?.makeKey() }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Geometry

    /// Where the panel rests: the screen it is already on; the one under the mouse the first time it shows.
    private func targetScreen() -> NSScreen? {
        if let panel, panel.isVisible, let s = panel.screen { return s }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// Divider + header + rows (or one line for the empty/unreadable states) + spacing.
    private var stripHeight: CGFloat {
        let body = downloads.items.isEmpty || downloads.unreadable
            ? 22 : CGFloat(downloads.items.count) * Self.downloadRowHeight
        return 8 + 28 + 8 + body
    }

    func size(for mode: TrayMode, visibleFrame: CGRect) -> CGSize {
        switch mode {
        case .collapsed: return Self.collapsedSize
        case .grid: return CGSize(width: Self.gridSize.width, height: Self.gridSize.height + stripHeight)
        case .zoom(let id):
            let e = watcher.entries.first { $0.id == id }
            return TrayPanelFrame.zoomSize(visible: visibleFrame,
                                           imageSize: CGSize(width: e?.width ?? 0, height: e?.height ?? 0),
                                           chrome: Self.zoomChrome, inset: Self.inset)
        }
    }

    func place(animated: Bool, on screen: NSScreen? = nil, duration: TimeInterval = 0.3) {
        guard let panel, let screen = screen ?? targetScreen() else { return }
        let v = screen.visibleFrame
        let frame = TrayPanelFrame.frame(corner: corner, visible: v, size: size(for: mode, visibleFrame: v),
                                         inset: Self.inset)
        if animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Drag to corner (collapsed chip)

    private var dragStartMouse: CGPoint?
    private var dragStartOrigin = CGPoint.zero
    private var dragging = false

    /// Pointer moved while pressed on the chip. Past the click threshold the panel follows the pointer.
    func dragChanged() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStartMouse == nil { dragStartMouse = mouse; dragStartOrigin = panel.frame.origin }
        guard let start = dragStartMouse else { return }
        if !dragging && TrayPanelFrame.isDrag(from: start, to: mouse) { dragging = true }
        if dragging {
            panel.setFrameOrigin(CGPoint(x: dragStartOrigin.x + mouse.x - start.x,
                                         y: dragStartOrigin.y + mouse.y - start.y))
        }
    }

    /// Release: a drag snaps to the nearest corner of the screen it ended on; anything shorter is a click.
    /// Returns true if it was a click.
    func dragEnded() -> Bool {
        defer { dragStartMouse = nil; dragging = false }
        guard dragging, let panel else { return true }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? panel.screen ?? NSScreen.main
        guard let screen else { return false }
        corner = TrayPanelFrame.nearestCorner(to: CGPoint(x: panel.frame.midX, y: panel.frame.midY),
                                              in: screen.visibleFrame)
        corner.save()
        place(animated: true, on: screen, duration: 0.25)
        return false
    }

    // MARK: - Click away

    private func installClickAway() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.clickedAway() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated {
                if let self, e.window !== self.panel { self.clickedAway() }
            }
            return e
        }) { monitors.append(l) }
    }

    private func clickedAway() {
        guard mode != .collapsed, !(markingUp && markupDirty) else { return }
        set(.collapsed)
    }
}

/// Borderless, non-activating, floating, on every Space — and invisible to the window cycle.
final class TrayPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 156, height: 48),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { TrayPanelController.shared.escape() }
    }
}
