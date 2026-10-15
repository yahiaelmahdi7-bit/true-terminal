import AppKit
import SwiftUI

private func swiftColor(_ s: Stroke) -> Color {
    let c = MarkupRender.rgb(s)
    return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
}

private func swatchColor(_ c: MarkupColor) -> Color { swiftColor(Stroke(mark: .pen([]), color: c, width: 1)) }

// MARK: - Canvas

/// The image with its layers, fitted into whatever box it is given. Input is forwarded in image pixels.
struct AnnotationCanvas: View {
    @Bindable var state: AnnotationState
    var corner: CGFloat = 3
    @FocusState private var textFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let iw = max(state.imageSize.width, 1), ih = max(state.imageSize.height, 1)
            let k = max(min(geo.size.width / iw, geo.size.height / ih), 0.001)
            let fit = CGSize(width: iw * k, height: ih * k)
            ZStack(alignment: .topLeading) {
                if let img = MarkupRender.render(base: state.image, doc: state.liveDoc, scale: min(1, k * 2), applyCrop: false) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high)
                }
                Canvas { ctx, size in
                    drawChrome(&ctx, size: size, k: k)
                }
                .allowsHitTesting(false)
                if let t = state.textEdit {
                    TextField("Text", text: Binding(get: { state.textEdit?.value ?? "" }, set: { state.textEdit?.value = $0 }))
                        .textFieldStyle(.plain)
                        .font(.system(size: state.fontSize * k, weight: .semibold))
                        .foregroundStyle(swiftColor(Stroke(mark: .pen([]), color: state.color, width: 1, custom: state.custom)))
                        .focused($textFocused)
                        .onSubmit { state.commitText() }
                        .frame(width: max(140, fit.width - t.at.x * k - 6), alignment: .leading)
                        .offset(x: t.at.x * k, y: t.at.y * k)
                        .onAppear { textFocused = true }
                }
            }
            .frame(width: fit.width, height: fit.height)
            .clipShape(.rect(cornerRadius: corner))
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !dragging { dragging = true; state.begin(point(v.startLocation, k)) }
                    state.move(point(v.location, k))
                }
                .onEnded { v in
                    if !dragging { state.begin(point(v.startLocation, k)) }
                    state.end(point(v.location, k)); dragging = false
                })
            .onChange(of: k, initial: true) { _, new in state.viewScale = new }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @State private var dragging = false

    private func point(_ p: CGPoint, _ k: CGFloat) -> CGPoint {
        CGPoint(x: max(0, min(p.x / k, state.imageSize.width)), y: max(0, min(p.y / k, state.imageSize.height)))
    }

    private func drawChrome(_ ctx: inout GraphicsContext, size: CGSize, k: CGFloat) {
        if let c = state.cropShown {
            let r = CGRect(x: c.minX * k, y: c.minY * k, width: c.width * k, height: c.height * k)
            var dim = Path(CGRect(origin: .zero, size: size)); dim.addRect(r)
            ctx.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            ctx.stroke(Path(r), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: state.tool == .crop ? [] : [4, 3]))
            if state.tool == .crop {
                for h in RectHandle.allCases {
                    let p = h.point(in: r)
                    let box = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                    ctx.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(.white))
                    ctx.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(.black.opacity(0.5)), lineWidth: 0.75)
                }
            }
        }
        if let i = state.selected, state.doc.strokes.indices.contains(i) {
            let s = state.doc.strokes[i]
            let b = s.bounds
            let r = CGRect(x: b.minX * k, y: b.minY * k, width: b.width * k, height: b.height * k)
            ctx.stroke(Path(r), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if state.resizable(s) {
                for p in state.handlePoints(of: s) {
                    let h = CGRect(x: p.x * k - 4, y: p.y * k - 4, width: 8, height: 8)
                    ctx.fill(Path(roundedRect: h, cornerRadius: 2), with: .color(.white))
                    ctx.stroke(Path(roundedRect: h, cornerRadius: 2), with: .color(.black.opacity(0.5)), lineWidth: 0.75)
                }
            }
        }
    }
}

// MARK: - Toolbar

struct FinishAction: Identifiable {
    let id: String
    let title: String
    var symbol: String? = nil
    var primary = false
    var shortcut: KeyEquivalent? = nil
    var enabled = true
    let action: () -> Void
}

struct AnnotationToolbar: View {
    @Bindable var state: AnnotationState
    var finish: [FinishAction]
    /// Floating = a glass capsule over a screenshot; otherwise a flat bar in the panel.
    var floating = false
    @State private var stylePopover = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 6) {
            // One row when it fits; otherwise the finish actions drop to their own right-aligned row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) { toolsRow; divider; finishRow }
                VStack(spacing: 6) {
                    HStack(spacing: 2) { toolsRow }
                    HStack(spacing: 2) { finishRow }.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if let chips = chipRow { chips }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background { if floating { floatingBackdrop } }
    }

    @ViewBuilder private var toolsRow: some View {
        ForEach(AnnotationTool.allCases, id: \.self) { t in
            ToolButton(tool: t, selected: state.tool == t) { state.tool = t }
        }
        divider
        Button { stylePopover.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(swiftColor(Stroke(mark: .pen([]), color: state.color, width: 1, custom: state.custom)))
                    .frame(width: 14, height: 14).overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.hubSecondary).frame(width: 44, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain).help("Colour and size")
        .popover(isPresented: $stylePopover, arrowEdge: .bottom) { StylePanel(state: state).padding(14) }
        divider
        IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { state.undo() }
            .keyboardShortcut("z").disabled(!state.doc.canUndo).opacity(state.doc.canUndo ? 1 : 0.35)
        IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { state.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!state.doc.canRedo).opacity(state.doc.canRedo ? 1 : 0.35)
    }
    private var finishRow: some View { ForEach(finish) { f in FinishButton(f: f) } }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 18).padding(.horizontal, 5) }

    @ViewBuilder private var floatingBackdrop: some View {
        if reduceTransparency { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.12)) }
        else { Color.clear.glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: Color.black.opacity(0.55), hairline: false) }
    }

    /// The contextual second row: only for tools with a mode.
    private var chipRow: AnyView? {
        switch state.tool {
        case .censor:
            return AnyView(HStack(spacing: 4) {
                ForEach(CensorMode.allCases, id: \.self) { m in
                    Chip(title: m == .pixelate ? "Pixelate" : m == .blur ? "Blur" : "Solid", on: state.censorMode == m) { state.censorMode = m }
                }
            })
        case .rect, .ellipse:
            return AnyView(HStack(spacing: 4) {
                Chip(title: "Outline", on: !state.filled) { state.filled = false }
                Chip(title: "Filled", on: state.filled) { state.filled = true }
            })
        case .crop:
            return AnyView(HStack(spacing: 4) {
                Text(state.doc.crop == nil ? "Drag over the part to keep" : "Drag again to change").font(.caption).foregroundStyle(Theme.hubSecondary)
                if state.doc.crop != nil { Chip(title: "Reset crop", on: false) { state.doc.setCrop(nil) } }
            })
        default: return nil
        }
    }
}

private struct ToolButton: View {
    let tool: AnnotationTool
    let selected: Bool
    let action: () -> Void
    var body: some View {
        IconButton(symbol: tool.symbol, help: "\(tool.label) (\(String(tool.key).uppercased()))", selected: selected, action: action)
            .accessibilityLabel(tool.label)
    }
}

private struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Theme.text : Theme.hubSecondary)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(on ? Theme.hubCardStroke : Theme.hubCardFill, in: .capsule)
        }.buttonStyle(.plain)
    }
}

private struct FinishButton: View {
    let f: FinishAction
    var body: some View {
        let b = Button(action: f.action) {
            HStack(spacing: 4) {
                if let s = f.symbol { Image(systemName: s).font(.system(size: 11, weight: .semibold)) }
                Text(f.title).font(.system(size: 12, weight: f.primary ? .semibold : .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(f.primary ? Color.black : Theme.hubSecondary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(f.primary ? Color.white.opacity(f.enabled ? 1 : 0.3) : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain).disabled(!f.enabled)
        if let key = f.shortcut { b.keyboardShortcut(key, modifiers: key == .escape || key == .return ? [] : .command) } else { b }
    }
}

/// The "pick any colour" control: a multicolour ring the size of a swatch that opens the system colour panel,
/// and shows the picked colour once there is one.
struct CustomColorDot: View {
    let custom: RGBA?
    let pick: (RGBA) -> Void
    var body: some View {
        Button {
            ColorPanelBridge.shared.open(current: custom, pick: pick)
        } label: {
            ZStack {
                if let c = custom {
                    Circle().fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1))
                    Circle().strokeBorder(.white, lineWidth: 2).padding(-4)
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    Circle().fill(Color(white: 0.11)).padding(6)
                }
            }
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain).help("Custom colour")
    }
}

@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var pick: ((RGBA) -> Void)?
    func open(current: RGBA?, pick: @escaping (RGBA) -> Void) {
        self.pick = pick
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self); panel.setAction(#selector(changed(_:)))
        if let c = current { panel.color = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
        panel.orderFront(nil)
    }
    @objc private func changed(_ sender: NSColorPanel) {
        let n = sender.color.usingColorSpace(.sRGB) ?? .red
        pick?(RGBA(r: n.redComponent, g: n.greenComponent, b: n.blueComponent, a: 1))
    }
}

/// Colour swatches + custom picker + stroke width + text size. Shown in the toolbar popover.
struct StylePanel: View {
    @Bindable var state: AnnotationState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(MarkupColor.allCases, id: \.self) { c in
                    let on = state.custom == nil && state.color == c
                    Button { state.custom = nil; state.color = c } label: {
                        Circle().fill(swatchColor(c)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white.opacity(c == .ink ? 0.35 : 0.25), lineWidth: 1))
                            .overlay(Circle().strokeBorder(.white, lineWidth: on ? 2 : 0).padding(-4))
                    }.buttonStyle(.plain).help(c.rawValue.capitalized)
                }
                CustomColorDot(custom: state.custom) { state.custom = $0 }
            }
            slider("Stroke", value: $state.strokeWidth, range: 2...max(24, state.strokeWidth * 3), icon: "scribble")
            slider("Text size", value: $state.fontSize, range: 12...max(120, state.fontSize * 2), icon: "textformat.size")
        }
        .frame(width: 230)
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.caption).foregroundStyle(Theme.hubSecondary); Spacer(); Text("\(Int(value.wrappedValue)) px").font(.caption.monospacedDigit()).foregroundStyle(Theme.dimText) }
            Slider(value: value, in: range)
        }
    }
}

// MARK: - Keys

extension View {
    /// Single-key tool shortcuts, ⌫ delete, arrow nudge. Return / Esc go to the host.
    func annotationKeys(_ state: AnnotationState, onReturn: @escaping () -> Void = {}, onEscape: @escaping () -> Void = {},
                         onArrow: ((CGFloat, CGFloat) -> Bool)? = nil) -> some View {
        self.focusable().focusEffectDisabled()
            .onKeyPress(phases: .down) { p in
                guard state.textEdit == nil else {
                    if p.key == .escape { state.textEdit = nil; return .handled }
                    return .ignored
                }
                if p.key == .escape { onEscape(); return .handled }
                if p.key == .return { onReturn(); return .handled }
                if p.key == .delete || p.key == .deleteForward { state.deleteSelected(); return .handled }
                let step: CGFloat = p.modifiers.contains(.shift) ? 10 : 1
                if state.selected == nil, let onArrow, let d = [KeyEquivalent.leftArrow: (-step, 0), .rightArrow: (step, 0), .upArrow: (0, -step), .downArrow: (0, step)][p.key], onArrow(d.0, d.1) { return .handled }
                switch p.key {
                case .leftArrow: state.nudge(-step, 0); return .handled
                case .rightArrow: state.nudge(step, 0); return .handled
                case .upArrow: state.nudge(0, -step); return .handled
                case .downArrow: state.nudge(0, step); return .handled
                default: break
                }
                guard !p.modifiers.contains(.command), !p.modifiers.contains(.control),
                      let c = p.characters.lowercased().first, let t = AnnotationTool.allCases.first(where: { $0.key == c }) else { return .ignored }
                state.tool = t
                return .handled
            }
    }
}

// MARK: - Tray "Mark up" host

/// The editor inside the tray's zoom view / the Shots overlay viewer. Save writes a `markup` child entry.
struct MarkupEditor: View {
    enum Style {
        case compact
        case overlay(insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat))
    }

    var style: Style = .compact
    let controller: any MarkupHosting
    let watcher: ScreenshotWatcher
    let entry: TrayEntry
    let image: CGImage

    @State private var state: AnnotationState
    @State private var saving = false

    init(style: Style = .compact, controller: any MarkupHosting, watcher: ScreenshotWatcher, entry: TrayEntry, image: CGImage) {
        self.style = style; self.controller = controller; self.watcher = watcher; self.entry = entry; self.image = image
        _state = State(initialValue: AnnotationState(image: image))
    }

    private var finish: [FinishAction] {
        [FinishAction(id: "cancel", title: "Cancel", action: cancel),
         FinishAction(id: "save", title: saving ? "Saving…" : "Save", primary: true, shortcut: "s", enabled: state.hasMarks && !saving, action: save)]
    }

    var body: some View {
        Group {
            switch style {
            case .compact:
                VStack(spacing: 0) {
                    AnnotationToolbar(state: state, finish: finish).frame(maxWidth: .infinity)
                        .frame(minHeight: TrayPanelController.zoomChrome)
                    AnnotationCanvas(state: state).padding([.horizontal, .bottom], 8)
                }
            case .overlay(let insets):
                GeometryReader { geo in
                    let area = ShotsOverlayLogic.markupArea(container: geo.size, insets: insets)
                    ZStack {
                        AnnotationCanvas(state: state, corner: 10).frame(width: area.width, height: area.height)
                            .position(x: area.midX, y: area.midY)
                        AnnotationToolbar(state: state, finish: finish, floating: true)
                            .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
                            .position(x: geo.size.width / 2,
                                      y: ShotsOverlayLogic.bottomBarCenterY(containerHeight: geo.size.height, bottomInset: insets.bottom))
                    }
                }
            }
        }
        .annotationKeys(state, onEscape: cancel)
        .onChange(of: state.doc) { controller.markupDirty = state.hasMarks }
    }

    private func cancel() { state.textEdit = nil; controller.markingUp = false; controller.markupDirty = false }

    private func save() {
        guard !saving, let out = state.export(), state.hasMarks else { return }
        saving = true
        Task {
            if let e = await watcher.addMarkup(png: out.png, parent: entry, width: out.width, height: out.height) {
                controller.markupSaved(id: e.id)
                controller.showToast("Markup saved")
            } else { saving = false }
        }
    }
}
