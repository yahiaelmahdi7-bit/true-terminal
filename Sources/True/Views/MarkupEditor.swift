import SwiftUI
import AppKit

/// Draws marks; the same code paints the live Canvas (scale = view/pixel) and the export (scale 1 over pixels).
enum MarkupDrawing {
    static func color(_ c: MarkupColor) -> Color {
        switch c {
        case .red: Color(red: 1.0, green: 0.27, blue: 0.23)
        case .amber: Theme.verdictWarn
        case .blue: Color(red: 0.04, green: 0.52, blue: 1.0)
        }
    }

    static let highlightFactor: CGFloat = 5

    static func draw(_ strokes: [Stroke], in ctx: inout GraphicsContext, scale s: CGFloat) {
        for st in strokes {
            let col = color(st.color)
            let style = StrokeStyle(lineWidth: st.width * s, lineCap: .round, lineJoin: .round)
            func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }
            switch st.mark {
            case .pen(let pts):
                ctx.stroke(polyline(pts.map(pt)), with: .color(col), style: style)
            case .highlight(let pts):
                let wide = StrokeStyle(lineWidth: st.width * highlightFactor * s, lineCap: .round, lineJoin: .round)
                ctx.stroke(polyline(pts.map(pt)), with: .color(col.opacity(0.35)), style: wide)
            case .rect(let r):
                ctx.stroke(Path(roundedRect: CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s),
                                cornerRadius: 2 * s), with: .color(col), style: style)
            case .arrow(let a, let b):
                var path = Path()
                let from = pt(a), to = pt(b)
                path.move(to: from); path.addLine(to: to)
                let angle = atan2(to.y - from.y, to.x - from.x)
                let head = max(st.width * 4, 14) * s
                for d in [CGFloat.pi * 0.85, -CGFloat.pi * 0.85] {
                    path.move(to: to)
                    path.addLine(to: CGPoint(x: to.x + cos(angle + d) * head, y: to.y + sin(angle + d) * head))
                }
                ctx.stroke(path, with: .color(col), style: style)
            case .text(let str, let at):
                ctx.draw(Text(str).font(.system(size: st.width * s, weight: .semibold)).foregroundColor(col),
                         at: pt(at), anchor: .topLeading)
            }
        }
    }

    private static func polyline(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count == 1 { p.addLine(to: first) } else { for q in pts.dropFirst() { p.addLine(to: q) } }
        return p
    }

    /// Render image + marks at the image's PIXEL size (scale 1) to PNG.
    @MainActor
    static func renderPNG(image: CGImage, strokes: [Stroke]) -> Data? {
        let size = CGSize(width: image.width, height: image.height)
        let view = ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
            Canvas { ctx, _ in var c = ctx; draw(strokes, in: &c, scale: 1) }
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let out = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}

/// The editor inside the zoom view: tools over the image, ⌘Z / ⇧⌘Z, Save writes a new markup entry.
struct MarkupEditor: View {
    enum Tool: CaseIterable { case pen, arrow, rect, highlight, text }
    /// `.compact` = the floating panel's zoom view (bar on top). `.overlay` = the full-screen overlay: the image is
    /// fitted above the viewer's bottom band and the tools float there in the viewer toolbar's style.
    enum Style {
        case compact
        case overlay(insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat))
    }

    var style: Style = .compact
    let controller: any MarkupHosting
    let watcher: ScreenshotWatcher
    let entry: TrayEntry
    let image: CGImage

    @State private var doc = MarkupDoc()
    @State private var tool: Tool = .pen
    @State private var color: MarkupColor = .red
    @State private var draft: [CGPoint] = []
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var textAt: CGPoint?
    @State private var textValue = ""
    @State private var saving = false
    @FocusState private var textFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    private var width: CGFloat { MarkupDoc.defaultWidth(forImage: imageSize) }

    var body: some View {
        Group {
            switch style {
            case .compact:
                VStack(spacing: 0) {
                    bar
                    GeometryReader { geo in canvas(in: geo.size) }
                        .padding([.horizontal, .bottom], 8)
                }
            case .overlay(let insets):
                GeometryReader { geo in
                    let area = ShotsOverlayLogic.markupArea(container: geo.size, insets: insets)
                    ZStack {
                        canvas(in: area.size)
                            .frame(width: area.width, height: area.height)
                            .position(x: area.midX, y: area.midY)
                        overlayBar
                            .position(x: geo.size.width / 2,
                                      y: ShotsOverlayLogic.bottomBarCenterY(containerHeight: geo.size.height, bottomInset: insets.bottom))
                    }
                }
            }
        }
        .onChange(of: doc) { controller.markupDirty = !doc.isEmpty }
        .onChange(of: tool) { commitText() }
    }

    private func canvas(in box: CGSize) -> some View {
        let fit = fitted(in: box)
        let scale = fit.width / max(imageSize.width, 1)
        return ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable()
            Canvas { ctx, _ in
                var c = ctx
                MarkupDrawing.draw(doc.strokes + liveStroke(), in: &c, scale: scale)
            }
            .gesture(drag(viewSize: fit))
            if let at = textAt {
                TextField("Text", text: $textValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: width * 5 * scale, weight: .semibold))
                    .foregroundStyle(MarkupDrawing.color(color))
                    .focused($textFocused)
                    .onSubmit(commitText)
                    .frame(width: max(120, fit.width - at.x * scale - 8), alignment: .leading)
                    .offset(x: at.x * scale, y: at.y * scale)
            }
        }
        .frame(width: fit.width, height: fit.height)
        .clipShape(.rect(cornerRadius: overlayStyle ? 10 : 3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var overlayStyle: Bool { if case .overlay = style { true } else { false } }

    // MARK: Toolbar

    private var bar: some View {
        HStack(spacing: 4) {
            ForEach(Tool.allCases, id: \.self) { t in
                IconButton(symbol: symbol(t), help: label(t), selected: tool == t) { tool = t }
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            ForEach(MarkupColor.allCases, id: \.self) { c in
                Button { color = c } label: {
                    Circle().fill(MarkupDrawing.color(c)).frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.white.opacity(color == c ? 0.9 : 0), lineWidth: 1.5).padding(-3))
                        .frame(width: 22, height: 28)
                }
                .buttonStyle(.plain).help(c.rawValue.capitalized)
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)") { doc.undo() }
                .keyboardShortcut("z").disabled(!doc.canUndo)
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)") { doc.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!doc.canRedo)
            Spacer()
            Button("Cancel") { controller.markingUp = false; controller.markupDirty = false }
                .buttonStyle(.plain).font(.callout).foregroundStyle(Theme.hubSecondary).padding(.horizontal, 8)
            Button(saving ? "Saving…" : "Save") { save() }
                .buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Theme.hubCardStroke, in: .capsule)
                .disabled(doc.isEmpty || saving)
        }
        .padding(.horizontal, 8)
        .frame(height: TrayPanelController.zoomChrome)
    }

    /// The viewer-toolbar twin: dark glass capsule, labelled 44 pt targets, Save as the one filled action.
    private var overlayBar: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases, id: \.self) { t in
                MarkupToolButton(symbol: symbol(t), label: shortLabel(t), help: label(t), selected: tool == t) { tool = t }
            }
            barDivider
            ForEach(MarkupColor.allCases, id: \.self) { c in
                Button { color = c } label: {
                    Circle().fill(MarkupDrawing.color(c)).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white.opacity(color == c ? 1 : 0.25), lineWidth: color == c ? 2.5 : 1).padding(-4))
                        .frame(width: 36, height: 44).contentShape(.rect)
                }
                .buttonStyle(.plain).help(c.rawValue.capitalized).accessibilityLabel(c.rawValue.capitalized)
            }
            barDivider
            undoRedoButton("arrow.uturn.backward", help: "Undo (⌘Z)", enabled: doc.canUndo) { doc.undo() }
                .keyboardShortcut("z")
            undoRedoButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: doc.canRedo) { doc.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            barDivider
            Button("Cancel") { controller.markingUp = false; controller.markupDirty = false }
                .buttonStyle(.plain).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 14).frame(height: 44).contentShape(.rect)
            let canSave = !(doc.isEmpty || saving)
            Button(saving ? "Saving…" : "Save") { save() }
                .buttonStyle(.plain).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(canSave ? Color.black : .white.opacity(0.55))
                .padding(.horizontal, 20).frame(height: 40)
                .background(canSave ? Color.white : Color.white.opacity(0.16), in: .capsule)
                .contentShape(.capsule)
                .disabled(!canSave)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(white: 0.12))
            } else {
                Capsule().fill(.clear).glassSurface(Capsule(), tint: Color.black.opacity(0.55), hairline: false)
            }
        }
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
    }

    private var barDivider: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 26).padding(.horizontal, 6)
    }

    private func undoRedoButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(!enabled).help(help).accessibilityLabel(help)
    }

    private func shortLabel(_ t: Tool) -> String { t == .rect ? "Box" : label(t) }

    private func symbol(_ t: Tool) -> String {
        switch t {
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .highlight: "highlighter"
        case .text: "textformat"
        }
    }

    private func label(_ t: Tool) -> String {
        switch t {
        case .pen: "Pen"
        case .arrow: "Arrow"
        case .rect: "Rectangle"
        case .highlight: "Highlight"
        case .text: "Text"
        }
    }

    // MARK: Drawing input

    private func fitted(in box: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let k = min(box.width / imageSize.width, box.height / imageSize.height)
        return CGSize(width: imageSize.width * k, height: imageSize.height * k)
    }

    private func drag(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let p = MarkupDoc.imagePoint(v.location, viewSize: viewSize, imageSize: imageSize)
                switch tool {
                case .pen, .highlight: draft.append(p)
                case .arrow, .rect:
                    if dragStart == nil { dragStart = MarkupDoc.imagePoint(v.startLocation, viewSize: viewSize, imageSize: imageSize) }
                    dragEnd = p
                case .text: break
                }
            }
            .onEnded { v in
                let p = MarkupDoc.imagePoint(v.location, viewSize: viewSize, imageSize: imageSize)
                if tool == .text {
                    commitText()
                    textAt = p; textValue = ""
                    controller.makeKey()
                    textFocused = true
                } else if let s = liveStroke().first { doc.add(s) }
                draft = []; dragStart = nil; dragEnd = nil
            }
    }

    private func liveStroke() -> [Stroke] {
        switch tool {
        case .pen where !draft.isEmpty: return [Stroke(mark: .pen(draft), color: color, width: width)]
        case .highlight where !draft.isEmpty: return [Stroke(mark: .highlight(draft), color: color, width: width)]
        case .arrow:
            guard let a = dragStart, let b = dragEnd else { return [] }
            return [Stroke(mark: .arrow(from: a, to: b), color: color, width: width)]
        case .rect:
            guard let a = dragStart, let b = dragEnd else { return [] }
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            return [Stroke(mark: .rect(r), color: color, width: width)]
        default: return []
        }
    }

    private func commitText() {
        defer { textAt = nil; textValue = "" }
        guard let at = textAt, !textValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        doc.add(Stroke(mark: .text(textValue, at: at), color: color, width: width * 5))
    }

    private func save() {
        commitText()
        guard !doc.isEmpty, !saving else { return }
        saving = true
        guard let png = MarkupDrawing.renderPNG(image: image, strokes: doc.strokes) else { saving = false; return }
        Task {
            if let e = await watcher.addMarkup(png: png, parent: entry) {
                controller.markupSaved(id: e.id)
                controller.showToast("Markup saved")
            } else { saving = false }
        }
    }
}

/// Labelled tool button for the overlay bar; the selected tool sits in a filled white-ish pill.
private struct MarkupToolButton: View {
    let symbol: String
    let label: String
    let help: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(minWidth: 62, minHeight: 48)
            .background(.white.opacity(selected ? 0.28 : (hovering ? 0.14 : 0)), in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help).accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
