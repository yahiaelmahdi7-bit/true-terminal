import SwiftUI
import AppKit
import Carbon.HIToolbox
import Observation

/// What the markup editor needs from whichever surface hosts it (the floating panel or the overlay).
@MainActor protocol MarkupHosting: AnyObject {
    var markingUp: Bool { get set }
    var markupDirty: Bool { get set }
    func makeKey()
    func showToast(_ text: String)
    func markupSaved(id: String)
}

/// The full-screen Shots overlay: a borderless panel over the screen under the mouse, summoned by the
/// panel's expand button, the Shell menu, or the global hotkey. It is a second VIEW over the same stores
/// (`ScreenshotWatcher`, `DownloadsWatcher`) — no second watcher, no second copy of the data.
@MainActor @Observable
final class ShotsOverlayController: MarkupHosting {
    static let shared = ShotsOverlayController()

    /// Drives the open/close animation separately from window visibility.
    private(set) var presented = false
    private(set) var isOpen = false
    private(set) var insets = EdgeInsets()
    var viewerID: String?
    var markingUp = false
    var markupDirty = false
    var hoveredID: String?
    var columns: Int
    var dropTargeted = false
    var toast: String?
    private(set) var sending = false

    let watcher = ScreenshotWatcher.shared
    let downloads = DownloadsWatcher.shared
    private var panel: ShotsOverlayPanel?
    private var keyMonitor: Any?
    private var resignObserver: Any?
    private var toastTask: Task<Void, Never>?

    private init() {
        UserDefaults.standard.register(defaults: [ShotsOverlayLogic.columnsKey: ShotsOverlayLogic.defaultColumns])
        columns = ShotsOverlayLogic.clampColumns(UserDefaults.standard.integer(forKey: ShotsOverlayLogic.columnsKey))
    }

    // MARK: Summon / dismiss

    func toggle() { isOpen ? dismiss() : show() }

    func show() {
        guard !isOpen else { return }
        let screens = NSScreen.screens
        let idx = ShotsOverlayLogic.screenIndex(mouse: NSEvent.mouseLocation, frames: screens.map(\.frame))
        guard let screen = idx.map({ screens[$0] }) ?? NSScreen.main ?? screens.first else { return }
        let i = ShotsOverlayLogic.contentInsets(frame: screen.frame, visible: screen.visibleFrame,
                                                safeTop: screen.safeAreaInsets.top, margin: 28)
        insets = EdgeInsets(top: i.top, leading: i.leading, bottom: i.bottom, trailing: i.trailing)
        watcher.recheckFolder(); watcher.markSeen(); downloads.start()
        TrayPanelController.shared.set(.collapsed)

        let p = ShotsOverlayPanel(screen: screen)
        p.contentView = NSHostingView(rootView: ShotsOverlayRoot(controller: self))
        panel = p
        viewerID = nil; viewerProgress = 0; closing = false; markingUp = false; markupDirty = false; sending = false; toast = nil
        isOpen = true
        p.makeKeyAndOrderFront(nil)
        installMonitors(for: p)
        // Next turn of the run loop, so the views mount un-presented and the stagger actually animates.
        DispatchQueue.main.async { [weak self] in self?.presented = true }
    }

    func dismiss() {
        guard isOpen else { return }
        isOpen = false
        presented = false
        removeMonitors()
        downloads.stop()
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            p?.orderOut(nil)
            if self?.panel === p { self?.panel = nil }
            p?.contentView = nil
        }
    }

    /// Esc: leave markup, else close the viewer, else dismiss.
    func escape() {
        if markingUp { markingUp = false; markupDirty = false }
        else if viewerID != nil { closeViewer() }
        else { dismiss() }
    }

    // MARK: Viewer

    var entries: [TrayEntry] { watcher.entries }
    var viewerIndex: Int? { viewerID.flatMap { id in entries.firstIndex { $0.id == id } } }
    /// -1 / +1 for the slide direction of the last arrow; 0 for a zoom-open or -close.
    var slide = 0
    /// 0 = the viewer image sits on its grid tile, 1 = fitted in the viewer. Animated; the close sets
    /// `viewerID = nil` only once it has landed back on the tile, so the tile never doubles up with the viewer copy.
    private(set) var viewerProgress: CGFloat = 0
    private var closing = false
    /// Each tile's frame in overlay coordinates, kept fresh by the tiles. Read on demand, never observed
    /// (scrolling would otherwise re-render the viewer every frame).
    @ObservationIgnored var tileFrames: [String: CGRect] = [:]

    private var zoomAnimation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.1)
    }

    func openViewer(_ id: String) {
        guard !closing else { return }
        slide = 0; viewerProgress = 0
        viewerID = id
        // Next turn, so the viewer mounts on the tile first and then springs out to its fitted rect.
        DispatchQueue.main.async { [weak self] in
            withAnimation(self?.zoomAnimation) { self?.viewerProgress = 1 }
        }
    }

    func closeViewer() {
        markingUp = false; markupDirty = false
        guard viewerID != nil, !closing else { return }
        closing = true; slide = 0
        withAnimation(zoomAnimation, completionCriteria: .logicallyComplete) {
            viewerProgress = 0
        } completion: { [weak self] in
            self?.viewerID = nil; self?.closing = false
        }
    }

    func step(_ delta: Int) {
        guard !closing, let i = viewerIndex, !markingUp, let j = ShotsOverlayLogic.neighbor(of: i, count: entries.count, step: delta) else { return }
        slide = delta
        withAnimation(.spring(duration: 0.35, bounce: 0.05)) { viewerID = entries[j].id }
    }

    /// Space from the grid: peek at the hovered shot (or the newest); Space again closes it.
    func peek() {
        if viewerID != nil { closeViewer() }
        else if let id = hoveredID ?? entries.first?.id { openViewer(id) }
    }

    // MARK: Actions

    func setColumns(_ n: Int, persist: Bool = true) {
        let c = ShotsOverlayLogic.clampColumns(n)
        withAnimation(.spring(duration: 0.3, bounce: 0)) { columns = c }
        if persist { UserDefaults.standard.set(c, forKey: ShotsOverlayLogic.columnsKey) }
    }

    /// Paste into True's focused pane (after the paper plane has had its moment), then land there.
    func send(_ entry: TrayEntry) { fly { [watcher] in watcher.send(entry) } }
    func sendPath(_ url: URL) { fly { [watcher] in watcher.sendPath(url) } }

    private func fly(_ paste: @escaping @MainActor () -> Void) {
        guard !sending else { return }
        sending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            paste()
            self?.dismiss()
            Self.bringTrueForward()
        }
    }

    private static func bringTrueForward() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible && !($0 is ShotsOverlayPanel) }?.makeKeyAndOrderFront(nil)
    }

    func delete(_ entry: TrayEntry) {
        let ids = entries.map(\.id), was = ids.firstIndex(of: entry.id)
        watcher.remove(entry)
        if viewerID == entry.id {
            let remaining = ids.filter { $0 != entry.id }
            let next = was.flatMap { remaining.indices.contains($0) ? remaining[$0] : remaining.last }
            if let next { withAnimation(.spring(duration: 0.35)) { viewerID = next } } else { closeViewer() }
        }
        showToast("Removed from tray")
    }

    func undoRemove() { watcher.restoreLastRemoved(); toast = nil }

    /// Drag-in: image files become tray copies through the same `TrayStore.ingest` a new screenshot uses.
    func drop(_ urls: [URL]) -> Bool {
        let own = watcher.store.root.path
        let fileURLs = urls.filter { $0.isFileURL && !$0.path.hasPrefix(own) }
        let images = fileURLs.filter(ShotsOverlayLogic.acceptsDrop)
        guard !images.isEmpty else { showToast("Only images can be added"); return false }
        Task { [watcher] in
            let n = await watcher.ingestDropped(images)
            showToast(n == 0 ? "Already in the tray" : n == 1 ? "Added 1 image" : "Added \(n) images")
        }
        if images.count < fileURLs.count { showToast("Added the images; skipped the rest") }
        return true
    }

    // MARK: MarkupHosting

    func makeKey() { panel?.makeKey() }
    func markupSaved(id: String) { markingUp = false; markupDirty = false; viewerID = id }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(text == "Removed from tray" ? 6 : 2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Keys & focus

    private func installMonitors(for p: NSPanel) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let consumed = MainActor.assumeIsolated { self?.handle(e) ?? false }
            return consumed ? nil : e
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.markupDirty != true { self?.dismiss() } }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil; resignObserver = nil
    }

    /// True when the key was ours (and must not reach the views).
    private func handle(_ e: NSEvent) -> Bool {
        guard isOpen, e.window === panel else { return false }
        let cmd = e.modifierFlags.contains(.command)
        switch Int(e.keyCode) {
        case kVK_Escape: escape(); return true
        case kVK_Space where !markingUp: peek(); return true
        case kVK_LeftArrow where viewerID != nil && !markingUp: step(-1); return true
        case kVK_RightArrow where viewerID != nil && !markingUp: step(1); return true
        case kVK_ANSI_Equal where cmd, kVK_ANSI_KeypadPlus where cmd: setColumns(columns - 1); return true   // ⌘+ = bigger
        case kVK_ANSI_Minus where cmd, kVK_ANSI_KeypadMinus where cmd: setColumns(columns + 1); return true
        default: return false
        }
    }
}

/// Borderless, above normal windows, every Space, invisible to the Dock and ⌘-Tab, and it CAN take key
/// (Esc / Space / arrows). Non-activating, so summoning it from another app does not drag True's windows up.
final class ShotsOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { ShotsOverlayController.shared.escape() }
    }
}

// MARK: - Global hotkey

/// ⌃⌥⌘S (see `ShotsHotKey`) from any app, via Carbon `RegisterEventHotKey` — no Accessibility permission.
@MainActor
final class ShotsHotKeyRegistrar {
    static let shared = ShotsHotKeyRegistrar()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in ShotsOverlayController.shared.toggle() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x54525348), id: 1)   // 'TRSH'
        RegisterEventHotKey(ShotsHotKey.carbonKeyCode, ShotsHotKey.carbonModifiers, id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}

extension TrayPanelController: MarkupHosting {
    func markupSaved(id: String) { markingUp = false; markupDirty = false; set(.zoom(id)) }
}
