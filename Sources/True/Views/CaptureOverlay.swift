import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

enum CaptureOutcome { case cancel, copy(AnnotationState), save(AnnotationState), send(AnnotationState) }

// MARK: - The per-screen overlay view

/// One screen's frozen still, dimmed, with the region picker (drag / snap) and — once a region is
/// chosen — the annotation editor sitting exactly over the chosen pixels.
final class CaptureView: NSView {
    enum Phase { case aiming, dragging, editing }

    let still: CGImage
    /// Window frames in this view's coordinates (top-left), front to back.
    var windows: [CGRect]
    var onOutcome: (CaptureOutcome) -> Void = { _ in }
    /// The mouse is over this screen while it aims: the controller hands it the keyboard.
    var onActivate: () -> Void = {}
    /// This screen just took the selection: the controller clears every other screen.
    var onEngage: () -> Void = {}
    /// False while another screen holds a selection that already has marks — this one then stays a plain dim.
    var mayAim: () -> Bool = { true }

    private(set) var phase: Phase = .aiming
    private(set) var selection: CGRect?
    private(set) var state: AnnotationState?
    var cursor: CGPoint?
    var hoverWindow: CGRect?
    /// Plain-English name of what the hover is on ("Button", "Area", "Window"…).
    var hoverName: String?
    /// This screen's top-left in the global (AX / CGWindowList) space.
    var displayOrigin: CGPoint = .zero
    /// Window numbers of True's own overlay panels (evaluated lazily; excluded from AX hit-testing).
    var overlayWindowNumbers: () -> Set<Int> = { [] }
    /// Image-fallback candidate boxes in view points, set once the detector finishes.
    var imageBoxes: [CGRect] = []
    var axTrusted = false
    private(set) var picker = SmartPicker()
    private var lastAX: [PickElement] = []
    private var pickSeq = 0
    private var scrollAccum: CGFloat = 0
    private let pickWorker = SmartPickWorker()
    private var anchor: CGPoint?
    private var downPoint: CGPoint?
    private var dragged = false
    private var spaceHeld = false
    private var lastPoint: CGPoint = .zero
    private var canvasHost: NSView?
    private var toolbarHost: NSView?
    private var handleLayer: HandleOverlay?
    private var activeHandle: RectHandle?
    private var handleOrigin: CGRect = .zero

    init(frame: NSRect, still: CGImage, windows: [CGRect]) {
        self.still = still; self.windows = windows
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: phase == .editing ? .arrow : .crosshair) }

    private var imageSize: CGSize { CGSize(width: still.width, height: still.height) }
    private var bounds0: CGRect { CGRect(origin: .zero, size: bounds.size) }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let whole = bounds0
        NSImage(cgImage: still, size: whole.size).draw(in: whole, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let hole = selection ?? hoverWindow
        g.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        let dim = CGMutablePath(); dim.addRect(whole)
        if let h = hole { dim.addRect(h) }
        g.addPath(dim); g.fillPath(using: .evenOdd)

        if selection == nil, let w = hoverWindow, phase == .aiming {
            let path = CGPath(roundedRect: w.insetBy(dx: 1, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil)
            g.setFillColor(NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 0.16).cgColor); g.addPath(path); g.fillPath()
            g.setStrokeColor(NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1).cgColor); g.setLineWidth(2); g.addPath(path); g.strokePath()
            let pill = label(CaptureLogic.sizeLabel(CaptureLogic.pixelRect(w, viewSize: whole.size, imageSize: imageSize)), above: w)
            if let n = hoverName { chip(n, after: pill) }
        }
        if let s = selection {
            g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(1); g.stroke(s.insetBy(dx: -0.5, dy: -0.5))
            if phase == .dragging || phase == .aiming {
                label(CaptureLogic.sizeLabel(CaptureLogic.pixelRect(s, viewSize: whole.size, imageSize: imageSize)), above: s)
            }
        }
    }

    /// Small plain-name chip (Button, Area, Window…) beside the size label.
    private func chip(_ text: String, after pill: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.black]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let r = CGRect(x: pill.maxX + 6, y: pill.minY + (pill.height - sz.height - 4) / 2, width: sz.width + 14, height: sz.height + 4)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        s.draw(at: NSPoint(x: r.minX + 7, y: r.minY + 2))
    }

    @discardableResult
    private func label(_ text: String, above r: CGRect) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let pill = CGRect(x: r.minX, y: r.minY - sz.height - 12 < 4 ? r.minY + 6 : r.minY - sz.height - 12, width: sz.width + 14, height: sz.height + 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        s.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + 3))
        return pill
    }

    // MARK: mouse

    override func mouseMoved(with e: NSEvent) {
        guard phase != .editing else { return }
        guard mayAim() else { clearHover(); return }
        let p = convert(e.locationInWindow, from: nil)
        cursor = p
        updatePick(at: p)
        onActivate()
        needsDisplay = true
    }

    /// The mouse left for another screen: drop the hover box so nothing stale stays behind.
    override func mouseExited(with e: NSEvent) { clearHover() }

    func clearHover() {
        guard phase == .aiming else { return }
        cursor = nil; lastAX = []; pickSeq += 1   // also voids any Accessibility answer still in flight
        picker = SmartPicker(); syncHover(); needsDisplay = true
    }

    /// Another screen took the selection: back to a plain dim, editor and handles gone.
    func resetToAiming() {
        canvasHost?.removeFromSuperview(); toolbarHost?.removeFromSuperview(); handleLayer?.removeFromSuperview()
        canvasHost = nil; toolbarHost = nil; handleLayer = nil
        phase = .aiming; selection = nil; state = nil; anchor = nil; activeHandle = nil
        clearHover()
        window?.invalidateCursorRects(for: self)
    }

    /// Instant answer from what is already known (window frames + image boxes + the last AX chain if it still covers
    /// the cursor), then a latest-wins Accessibility query off the main thread that refines it.
    private func updatePick(at p: CGPoint) {
        let ax = lastAX.filter { $0.frame.contains(p) }   // ancestors that still cover the cursor
        setPick(SmartPickLogic.chain(ax: ax, window: CaptureLogic.windowRect(at: p, in: windows), boxes: imageBoxes, at: p))
        guard axTrusted else { return }
        pickSeq += 1
        let seq = pickSeq, origin = displayOrigin
        pickWorker.request(seq: seq, point: SmartPickLogic.toGlobal(p, displayOrigin: origin), excluding: overlayWindowNumbers()) { [weak self] n, result in
            Task { @MainActor in self?.applyAX(seq: n, result: result, point: p, origin: origin) }
        }
    }

    private func applyAX(seq: Int, result: AXPick.Result, point p: CGPoint, origin: CGPoint) {
        guard seq == pickSeq, phase == .aiming, cursor == p else { return }
        let win = result.window.map { SmartPickLogic.toOverlay($0, displayOrigin: origin) }
        let chain = result.chain.map { PickElement(frame: SmartPickLogic.toOverlay($0.frame, displayOrigin: origin), kind: $0.kind) }
        lastAX = win.map { SmartPickLogic.clean(chain, window: $0) } ?? []
        setPick(SmartPickLogic.chain(ax: lastAX, window: win ?? CaptureLogic.windowRect(at: p, in: windows), boxes: imageBoxes, at: p))
        needsDisplay = true
    }

    private func setPick(_ chain: [PickElement]) {
        picker.replace(chain); syncHover()
    }
    private func syncHover() {
        hoverWindow = picker.current?.frame; hoverName = picker.current?.kind.rawValue
    }

    override func scrollWheel(with e: NSEvent) {
        guard phase == .aiming, picker.elements.count > 1 else { return }
        scrollAccum += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        let step: CGFloat = 8
        while abs(scrollAccum) >= step {
            if scrollAccum > 0 { picker.grow(); scrollAccum -= step } else { picker.shrink(); scrollAccum += step }
        }
        syncHover(); needsDisplay = true
    }

    /// Stills/tests: aiming with a ready-made chain picked at `level`.
    func previewPick(chain: [PickElement], level: Int, cursor: CGPoint?) {
        phase = .aiming; selection = nil; self.cursor = cursor
        picker = SmartPicker(chain, level: level); syncHover(); needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        guard phase != .editing, mayAim() else { return }
        onEngage()
        let p = convert(e.locationInWindow, from: nil)
        downPoint = p; anchor = p; dragged = false; lastPoint = p
        selection = nil
        phase = .dragging
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard phase == .dragging, let a = anchor else { return }
        let p = convert(e.locationInWindow, from: nil)
        cursor = p
        if let d = downPoint, hypot(p.x - d.x, p.y - d.y) > 4 { dragged = true }
        guard dragged else { return }
        if spaceHeld, let s = selection {
            let dx = p.x - lastPoint.x, dy = p.y - lastPoint.y
            let moved = CaptureLogic.moved(s, by: CGSize(width: dx, height: dy), within: bounds0)
            anchor = CGPoint(x: a.x + moved.minX - s.minX, y: a.y + moved.minY - s.minY)
            selection = moved
        } else {
            selection = CaptureLogic.dragRect(from: a, to: p, square: e.modifierFlags.contains(.shift), bounds: bounds0)
        }
        lastPoint = p
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard phase == .dragging else { return }
        let p = convert(e.locationInWindow, from: nil)
        if dragged, let s = selection, s.width >= 6, s.height >= 6 {
            beginEditing()
        } else if !dragged, let w = picker.current?.frame ?? CaptureLogic.windowRect(at: p, in: windows) {
            selection = w; beginEditing()
        } else {
            phase = .aiming; selection = nil; updatePick(at: p)
        }
        needsDisplay = true
    }

    // MARK: keys (aiming / dragging; the editor takes over after that)

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: onOutcome(.cancel)                                   // esc
        case 48: picker.jumpToWindow(); syncHover(); needsDisplay = true      // tab: straight to window level
        case 49: spaceHeld = true                                      // space: move instead of resize
        case 3 where !e.modifierFlags.contains(.command):             // F: whole screen
            guard mayAim() else { return }
            onEngage(); selection = bounds0; beginEditing()
        case 123, 124, 125, 126:
            guard let s = selection else { return }
            let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            let d = e.keyCode == 123 ? CGSize(width: -step, height: 0) : e.keyCode == 124 ? CGSize(width: step, height: 0)
                : e.keyCode == 126 ? CGSize(width: 0, height: -step) : CGSize(width: 0, height: step)
            selection = CaptureLogic.moved(s, by: d, within: bounds0)
            if let a = anchor { anchor = CGPoint(x: a.x + d.width, y: a.y + d.height) }
            needsDisplay = true
        case 36, 76 where selection != nil && phase != .editing: beginEditing()
        default: break
        }
    }

    override func keyUp(with e: NSEvent) { if e.keyCode == 49 { spaceHeld = false } }

    // MARK: editor

    /// Nudge the chosen region while nothing has been drawn yet (arrow keys in the editor).
    func nudgeSelection(_ d: CGSize) -> Bool {
        guard let s = selection, state?.hasMarks == false else { return false }
        selection = CaptureLogic.moved(s, by: d, within: bounds0)
        beginEditing(); return true
    }

    /// Stills/tests: put the overlay in a given mid-drag state without events.
    func previewDrag(selection: CGRect?, cursor: CGPoint?) {
        phase = .dragging; self.selection = selection; self.cursor = cursor; needsDisplay = true
    }

    /// Handles are live only while nothing has been drawn: marks lock the chosen region.
    fileprivate var handlesActive: Bool { phase == .editing && state?.hasMarks == false }
    fileprivate func handleAt(_ p: CGPoint) -> RectHandle? {
        guard handlesActive, let s = selection else { return nil }
        return RectHandle.hit(p, in: s)
    }
    fileprivate func beginResize(_ h: RectHandle) {
        guard let s = selection else { return }
        canvasHost?.removeFromSuperview(); toolbarHost?.removeFromSuperview()
        canvasHost = nil; toolbarHost = nil
        activeHandle = h; handleOrigin = s; phase = .dragging; dragged = true
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true; handleLayer?.needsDisplay = true
    }
    fileprivate func continueResize(to p: CGPoint, square: Bool) {
        guard let h = activeHandle else { return }
        cursor = p
        selection = h.resized(handleOrigin, to: p, square: square, bounds: bounds0)
        needsDisplay = true; handleLayer?.needsDisplay = true
    }
    fileprivate func endResize() {
        activeHandle = nil
        beginEditing()
    }
    func refreshHandles() { handleLayer?.needsDisplay = true }

    /// Stills/tests: selection with its resize handles, mid-drag of the bottom-right one.
    func previewResize(selection: CGRect, cursor: CGPoint) {
        phase = .dragging; self.selection = selection; self.cursor = cursor; activeHandle = .bottomRight
        let layer = handleLayer ?? HandleOverlay(owner: self)
        layer.frame = bounds0
        if layer.superview == nil { addSubview(layer) }
        handleLayer = layer; layer.needsDisplay = true; needsDisplay = true
    }

    func beginEditing() {
        guard let sel = selection else { return }
        canvasHost?.removeFromSuperview(); toolbarHost?.removeFromSuperview()
        handleLayer?.removeFromSuperview()
        phase = .editing
        let px = CaptureLogic.pixelRect(sel, viewSize: bounds.size, imageSize: imageSize)
        guard let crop = still.cropping(to: px) else { onOutcome(.cancel); return }
        let st = AnnotationState(image: crop)
        state = st

        let canvas = NSHostingView(rootView: CaptureCanvasHost(state: st, onReturn: { [weak self] in self?.onOutcome(.save(st)) },
                                                               onEscape: { [weak self] in self?.onOutcome(.cancel) },
                                                               onArrow: { [weak self] dx, dy in self?.nudgeSelection(CGSize(width: dx, height: dy)) ?? false },
                                                               onMarksChanged: { [weak self] in self?.refreshHandles() }))
        canvas.frame = sel
        addSubview(canvas); canvasHost = canvas

        let bar = NSHostingView(rootView: CaptureToolbarHost(state: st, onOutcome: { [weak self] in self?.onOutcome($0) }))
        let size = bar.fittingSize
        bar.frame = CGRect(origin: CaptureLogic.toolbarOrigin(selection: sel, toolbar: size, in: bounds0), size: size)
        addSubview(bar); toolbarHost = bar
        let layer = HandleOverlay(owner: self); layer.frame = bounds0
        addSubview(layer, positioned: .above, relativeTo: canvas); handleLayer = layer
        window?.makeFirstResponder(canvas)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}

/// The 8 resize handles over the chosen region. Transparent to the mouse except right on a handle, and only
/// while nothing has been drawn.
final class HandleOverlay: NSView {
    private weak var owner: CaptureView?
    init(owner: CaptureView) { self.owner = owner; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        owner?.handleAt(convert(point, from: superview)) != nil ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirty: NSRect) {
        guard let o = owner, let s = o.selection, o.handlesActive || o.phase == .dragging else { return }
        for h in RectHandle.allCases {
            let p = h.point(in: s)
            let r = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            NSColor.white.setFill(); path.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke(); path.lineWidth = 0.75; path.stroke()
        }
    }

    private var grabbed: RectHandle?
    override func mouseDown(with e: NSEvent) {
        guard let o = owner, let h = o.handleAt(convert(e.locationInWindow, from: nil)) else { return }
        grabbed = h; o.beginResize(h)
    }
    override func mouseDragged(with e: NSEvent) {
        guard grabbed != nil else { return }
        owner?.continueResize(to: convert(e.locationInWindow, from: nil), square: e.modifierFlags.contains(.shift))
    }
    override func mouseUp(with e: NSEvent) {
        guard grabbed != nil else { return }
        grabbed = nil; owner?.endResize()
    }
    override func resetCursorRects() {
        guard let o = owner, o.handlesActive, let s = o.selection else { return }
        for h in RectHandle.allCases { addCursorRect(CGRect(x: h.point(in: s).x - 8, y: h.point(in: s).y - 8, width: 16, height: 16), cursor: .crosshair) }
    }
}

struct CaptureCanvasHost: View {
    let state: AnnotationState
    let onReturn: () -> Void, onEscape: () -> Void
    let onArrow: (CGFloat, CGFloat) -> Bool
    var onMarksChanged: () -> Void = {}
    var body: some View {
        AnnotationCanvas(state: state, corner: 0)
            .annotationKeys(state, onReturn: onReturn, onEscape: onEscape, onArrow: onArrow)
            .onChange(of: state.hasMarks) { _, _ in onMarksChanged() }
    }
}

struct CaptureToolbarHost: View {
    let state: AnnotationState
    let onOutcome: (CaptureOutcome) -> Void
    var body: some View {
        AnnotationToolbar(state: state, finish: [
            FinishAction(id: "cancel", title: "Cancel", action: { onOutcome(.cancel) }),
            FinishAction(id: "copy", title: "Copy", symbol: "doc.on.doc", shortcut: "c", action: { onOutcome(.copy(state)) }),
            FinishAction(id: "send", title: "Send", symbol: "paperplane", action: { onOutcome(.send(state)) }),
            FinishAction(id: "save", title: "Save", primary: true, shortcut: "s", action: { onOutcome(.save(state)) }),
        ], floating: true)
        .fixedSize()
    }
}

// MARK: - Permission prompt

struct CapturePermissionPrompt: View {
    let openSettings: () -> Void
    let dismiss: () -> Void
    var body: some View {
        CaptureNotice(symbol: "rectangle.dashed.badge.record", text: "True needs Screen Recording to capture.",
                      button: "Open Settings", action: openSettings, dismiss: dismiss)
    }
}

/// One-line notice used by the permission prompt and the "macOS still owns ⌘⇧4" notice.
struct CaptureNotice: View {
    let symbol: String, text: String, button: String
    let action: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Theme.hubSecondary)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text)
            Button(action: action) {
                Text(button).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 12).frame(height: 26).background(.white, in: .capsule)
            }.buttonStyle(.plain)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.hubSecondary).frame(width: 24, height: 24) }
                .buttonStyle(.plain).help("Close")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(white: 0.11), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .fixedSize()
    }
}

// MARK: - Controller

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CaptureController {
    static let shared = CaptureController()
    private var panels: [CapturePanel] = []
    private var prompt: NSPanel?
    private(set) var busy = false

    var active: Bool { !panels.isEmpty }

    func start() {
        guard !busy, !active else { return }
        guard CGPreflightScreenCaptureAccess() else { showPrompt(); return }
        busy = true
        Task {
            defer { busy = false }
            do { try await present() } catch { showPrompt() }
        }
    }

    private func present() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var made: [CapturePanel] = []
        var views: [(CaptureView, CGImage, CGFloat)] = []
        let trusted = AXPick.trusted()
        let windowList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(screen.frame.width * screen.backingScaleFactor); cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg)
            let origin = CGDisplayBounds(id).origin
            let frames: [CGRect] = windowList.compactMap { w in
                guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                      let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).offsetBy(dx: -origin.x, dy: -origin.y)
            }
            let view = CaptureView(frame: CGRect(origin: .zero, size: screen.frame.size), still: img, windows: frames)
            view.displayOrigin = origin
            view.axTrusted = trusted
            view.overlayWindowNumbers = { [weak self] in Set((self?.panels ?? []).map(\.windowNumber)) }
            views.append((view, img, screen.backingScaleFactor))
            view.onOutcome = { [weak self] in self?.handle($0) }
            let p = CapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = view
            p.setFrame(screen.frame, display: false)
            view.onActivate = { [weak self, weak p] in p.map { self?.activate($0) } }
            view.onEngage = { [weak self, weak view] in view.map { self?.engage($0) } }
            view.mayAim = { [weak self, weak view] in view.map { self?.mayAim($0) ?? true } ?? true }
            made.append(p)
        }
        guard !made.isEmpty else { throw CocoaError(.fileReadUnknown) }
        panels = made
        let underMouse = made.first { $0.frame.contains(NSEvent.mouseLocation) } ?? made[0]
        for p in made { p.orderFrontRegardless() }
        underMouse.makeKey()
        if let v = underMouse.contentView { underMouse.makeFirstResponder(v) }
        for (view, img, scale) in views {   // image-fallback boxes: once per screen, off the main thread
            Task.detached(priority: .userInitiated) { [weak view] in
                let size = await MainActor.run { view?.bounds.size ?? .zero }
                let boxes = LayoutRegions.detect(img, scale: scale).map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale) }
                let kept = SmartPickLogic.filterBoxes(boxes, screen: size, minSide: 20)
                await MainActor.run { view?.imageBoxes = kept }
            }
        }
        if !trusted { showAccessibilityNotice() }
    }

    // MARK: Accessibility notice (once per run)

    private var axNotice: NSPanel?
    private var axNoticeShown = false

    private func showAccessibilityNotice() {
        guard !axNoticeShown else { return }
        axNoticeShown = true
        let host = NSHostingView(rootView: CaptureNotice(symbol: "hand.raised", text: "Turn on Accessibility for exact picks", button: "Open Settings", action: { [weak self] in
            self?.close()
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
        }, dismiss: { [weak self] in self?.axNotice?.orderOut(nil); self?.axNotice = nil }))
        let size = host.fittingSize
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1); p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let s = NSScreen.main { p.setFrameOrigin(CGPoint(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height - 90)) }
        p.orderFrontRegardless()
        axNotice = p
    }

    // MARK: several screens — one selection at a time

    private var views: [CaptureView] { panels.compactMap { $0.contentView as? CaptureView } }

    /// The keyboard follows the mouse between screens until one of them holds a selection.
    private func activate(_ p: CapturePanel) {
        guard !p.isKeyWindow, !views.contains(where: { $0.phase != .aiming }) else { return }
        p.makeKey()
        if let v = p.contentView { p.makeFirstResponder(v) }
    }

    /// A screen took the selection: every other screen goes back to a plain dim.
    private func engage(_ view: CaptureView) {
        for v in views where v !== view { v.resetToAiming() }
        if let w = view.window, !w.isKeyWindow { w.makeKey(); w.makeFirstResponder(view) }
    }

    /// Marks on one screen lock the capture there; until then any screen can take over.
    private func mayAim(_ view: CaptureView) -> Bool {
        !views.contains { $0 !== view && $0.state?.hasMarks == true }
    }

    func close() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        axNotice?.orderOut(nil); axNotice = nil
    }

    private func handle(_ outcome: CaptureOutcome) {
        switch outcome {
        case .cancel: close()
        case .copy(let s):
            if let out = s.export() {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(out.png, forType: .png)
                save(out)
            }
            close()
        case .save(let s):
            if let out = s.export() { save(out); TrayPanelController.shared.showToast("Saved to Screenshots") }
            close()
        case .send(let s):
            if let out = s.export() { save(out, thenSend: true) }
            close()
        }
    }

    private func save(_ out: (png: Data, width: Int, height: Int), thenSend: Bool = false) {
        Task {
            guard let e = await ScreenshotWatcher.shared.addCapture(png: out.png, width: out.width, height: out.height) else { return }
            if thenSend { ScreenshotWatcher.shared.send(e) }
        }
    }

    // MARK: shortcut notice

    private var shortcutNotice: NSPanel?

    /// Shows "macOS still owns ⌘⇧4" while macOS's own area-screenshot shortcut is on; hides it once it's off.
    func refreshShortcutNotice() {
        guard SystemShortcut.areaScreenshotOwnedByMacOS() else { shortcutNotice?.orderOut(nil); shortcutNotice = nil; noticeDismissed = false; return }
        guard shortcutNotice == nil, !noticeDismissed else { return }
        let host = NSHostingView(rootView: CaptureNotice(symbol: "keyboard", text: "macOS still owns ⌘⇧4", button: "Open Keyboard Shortcuts", action: {
            if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(u) }
        }, dismiss: { [weak self] in self?.noticeDismissed = true; self?.shortcutNotice?.orderOut(nil); self?.shortcutNotice = nil }))
        let size = host.fittingSize
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .floating; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let s = NSScreen.main { p.setFrameOrigin(CGPoint(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height - 90)) }
        p.orderFrontRegardless()
        shortcutNotice = p
    }
    private var noticeDismissed = false

    // MARK: permission

    private func showPrompt() {
        close()
        prompt?.orderOut(nil)
        let host = NSHostingView(rootView: CapturePermissionPrompt(openSettings: { [weak self] in
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
            self?.prompt?.orderOut(nil)
        }, dismiss: { [weak self] in self?.prompt?.orderOut(nil) }))
        let size = host.fittingSize
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .floating; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let s = NSScreen.main { p.setFrameOrigin(CGPoint(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height - 90)) }
        p.orderFrontRegardless()
        prompt = p
        CGRequestScreenCaptureAccess()   // registers True in the Screen Recording list the first time
    }
}

// MARK: - Global hotkey

/// ⌘⇧4 (primary) and ⌃⌥⌘A (backup) — see `CaptureHotKey` — from any app. Shares the Carbon event target with
/// `ShotsHotKeyRegistrar`, so each handler checks the hot-key id and passes on anything that isn't its own.
@MainActor
final class CaptureHotKeyRegistrar {
    static let shared = CaptureHotKeyRegistrar()
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    func register() {
        guard refs.isEmpty else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard hk.signature == OSType(0x54524350), CaptureHotKey.all.contains(where: { $0.id == hk.id }) else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in CaptureController.shared.start() }
            return noErr
        }, 1, &spec, nil, &handler)
        for c in CaptureHotKey.all {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(c.carbonKeyCode, c.carbonModifiers, EventHotKeyID(signature: OSType(0x54524350), id: c.id),   // 'TRCP'
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
        CaptureController.shared.refreshShortcutNotice()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in CaptureController.shared.refreshShortcutNotice() }
        }
    }
}
