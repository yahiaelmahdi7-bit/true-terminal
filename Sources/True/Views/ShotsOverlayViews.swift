import SwiftUI
import AppKit
import ImageIO

/// Behind-window blur of whatever is on the desktop under the overlay.
private struct BackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.material = .fullScreenUI
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

private extension View {
    /// Dark-tinted glass with a hairline edge: legible over a bright wallpaper as well as a dark one.
    func chromeGlass<S: InsettableShape>(_ shape: S, tint: Double = 0.4) -> some View {
        glassSurface(shape, tint: Color.black.opacity(tint), hairline: false)
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

struct ShotsOverlayRoot: View {
    let controller: ShotsOverlayController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var ns
    @State private var pinchBase: Int?
    static let space = "shotsOverlay"

    private var c: ShotsOverlayController { controller }
    private var open: Bool { c.presented }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 16) {
                header
                shots
                DownloadsGlassStrip(controller: c)
            }
            .opacity(c.markingUp ? 0 : 1)
            .allowsHitTesting(!c.markingUp)
            .animation(.easeOut(duration: 0.18), value: c.markingUp)
            .padding(.top, c.insets.top).padding(.leading, c.insets.leading)
            .padding(.bottom, c.insets.bottom).padding(.trailing, c.insets.trailing)

            if c.viewerID != nil {
                ShotViewer(controller: c, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
            }
            if c.dropTargeted { dropHighlight }
            toast
        }
        .coordinateSpace(name: ShotsOverlayRoot.space)
        .ignoresSafeArea()
        .opacity(open ? 1 : 0)
        .animation(open ? .easeOut(duration: 0.22) : .easeIn(duration: 0.18), value: open)
        .preferredColorScheme(.dark)
        .dropDestination(for: URL.self) { urls, _ in c.drop(urls) } isTargeted: { c.dropTargeted = $0 }
    }

    // MARK: Pieces

    private var backdrop: some View {
        Group {
            if reduceTransparency { Color(white: 0.06) } else {
                ZStack { BackdropBlur(); Color.black.opacity(0.36) }
            }
        }
        .contentShape(.rect)
        .onTapGesture { c.dismiss() }
    }

    private var header: some View {
        GlassContainer(spacing: 12) {
            HStack(spacing: 10) {
                Text("Shots").font(.title3.weight(.semibold))
                Text("\(c.entries.count)").font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.72))
                Spacer()
                ActionButton(symbol: "folder", help: "Show \(c.watcher.folder.lastPathComponent) in Finder", bounceOnHover: true) {
                    NSWorkspace.shared.open(c.watcher.folder)
                }
                ActionButton(symbol: "xmark", help: "Close (Esc)") { c.dismiss() }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .chromeGlass(.capsule)
        }
    }

    @ViewBuilder private var shots: some View {
        if c.entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "camera.viewfinder").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(c.watcher.unreadable ? "True can't read \(c.watcher.folder.lastPathComponent)" : "No screenshots yet")
                    .font(.title3)
                Text(c.watcher.unreadable ? "Allow access in Privacy Settings." : "New ones in \(c.watcher.folder.lastPathComponent) appear here — or drop images in.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            grid
        }
    }

    private var grid: some View {
        let groups = ShotsOverlayLogic.group(c.entries, now: Date(), calendar: .current)
        let order = Dictionary(uniqueKeysWithValues: c.entries.enumerated().map { ($1.id, $0) })
        let cols = Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: c.columns)
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.title) { g in
                    Section {
                        LazyVGrid(columns: cols, spacing: 18) {
                            ForEach(g.entries) { e in
                                ShotTile(controller: c, entry: e, index: order[e.id] ?? 0, reduceMotion: reduceMotion)
                            }
                        }
                    } header: {
                        Text(g.title).font(.callout.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .chromeGlass(.capsule)
                    }
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
        .simultaneousGesture(MagnifyGesture().onChanged { v in
            let base = pinchBase ?? c.columns
            pinchBase = base
            let n = ShotsOverlayLogic.columns(base: base, pinchScale: v.magnification)
            if n != c.columns { c.setColumns(n, persist: false) }
        }.onEnded { _ in
            pinchBase = nil
            UserDefaults.standard.set(c.columns, forKey: ShotsOverlayLogic.columnsKey)
        })
        // Arrowing through the viewer keeps its tile on screen, so the close always has somewhere to land.
        .onChange(of: c.viewerID) { _, id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id) }
        }
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
            .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 28, style: .continuous))
            .overlay {
                Label("Drop images to add", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.medium)).padding(.horizontal, 22).padding(.vertical, 12)
                    .glassSurface(Capsule())
            }
            .padding(14).allowsHitTesting(false).transition(.opacity)
    }

    @ViewBuilder private var toast: some View {
        if let text = c.toast {
            HStack(spacing: 12) {
                Text(text).font(.callout)
                if text == "Removed from tray" {
                    Button("Undo") { c.undoRemove() }.glassButtonStyle().controlSize(.small)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .chromeGlass(.capsule)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, c.insets.bottom + 120)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: 0.2), value: c.toast)
        }
    }
}

// MARK: - Tile

private struct ShotTile: View {
    let controller: ShotsOverlayController
    let entry: TrayEntry
    let index: Int
    let reduceMotion: Bool
    @State private var hover: CGPoint?

    private var c: ShotsOverlayController { controller }
    private let maxTilt = 6.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let lifted = hover != nil
            let px: Double = Double(hover?.x ?? w / 2), py: Double = Double(hover?.y ?? h / 2)
            let tiltX: Double = -((py / Double(max(h, 1))) - 0.5) * 2 * maxTilt
            let tiltY: Double = ((px / Double(max(w, 1))) - 0.5) * 2 * maxTilt
            Group {
                if c.viewerID == entry.id {
                    Color.clear
                } else {
                    ThumbImage(entry: entry, fill: true)
                }
            }
            .frame(width: w, height: h)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(lifted ? 0.4 : 0.14), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if entry.kind == .markup {
                    Image(systemName: "pencil.tip").font(.system(size: 10, weight: .bold)).padding(5)
                        .glassSurface(Circle()).padding(8)
                }
            }
            .scaleEffect(lifted ? 1.04 : 1)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : tiltX), axis: (1, 0, 0), perspective: 0.6)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : tiltY), axis: (0, 1, 0), perspective: 0.6)
            .shadow(color: .black.opacity(lifted ? 0.45 : 0.18), radius: lifted ? 18 : 6, y: lifted ? 10 : 3)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: lifted)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.8), value: hover?.x)
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p; c.hoveredID = entry.id
                case .ended: hover = nil; if c.hoveredID == entry.id { c.hoveredID = nil }
                }
            }
            .onTapGesture { c.openViewer(entry.id) }
            .onDrag { fileProvider(c.watcher.fileURL(for: entry)) }
        }
        .aspectRatio(1.6, contentMode: .fit)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ShotsOverlayRoot.space)) } action: { c.tileFrames[entry.id] = $0 }
        .scaleEffect(c.presented || reduceMotion ? 1 : 0.9)
        .opacity(c.presented ? 1 : 0)
        .animation(c.presented
                   ? (reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.32, bounce: 0.18).delay(Double(min(index, 10)) * 0.02))
                   : .easeIn(duration: 0.18), value: c.presented)
        .zIndex(hover != nil ? 1 : 0)
    }
}

// MARK: - Viewer

private struct ShotViewer: View {
    let controller: ShotsOverlayController
    let reduceMotion: Bool
    let reduceTransparency: Bool
    @State private var full: CGImage?
    private var c: ShotsOverlayController { controller }

    private var entry: TrayEntry? { c.viewerID.flatMap { id in c.entries.first { $0.id == id } } }
    private var insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        (c.insets.top, c.insets.leading, c.insets.bottom, c.insets.trailing)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let p = c.viewerProgress
            ZStack {
                Color.black.opacity((c.markingUp ? 0.82 : 0.6) * p).contentShape(.rect).onTapGesture { if !c.markingUp { c.closeViewer() } }
                if let entry {
                    if c.markingUp, let full {
                        MarkupEditor(style: .overlay(insets: insets), controller: c, watcher: c.watcher, entry: entry, image: full)
                            .frame(width: size.width, height: size.height)
                        RoundButton(symbol: "xmark", help: "Cancel markup (Esc)", dark: !reduceTransparency) {
                            c.markingUp = false; c.markupDirty = false
                        }
                        .position(x: c.insets.leading + ShotsOverlayLogic.sideReserve / 2, y: c.insets.top + 22)
                    } else {
                        picture(entry, size: size, progress: p)
                        if !c.markingUp { chrome(entry, size: size).opacity(p) }
                    }
                }
            }
            .task(id: entry?.id) {
                guard let entry else { return }
                let u = c.watcher.fileURL(for: entry)
                full = await Task.detached { () -> CGImage? in
                    guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(src, 0, nil)
                }.value
            }
        }
        .transition(.opacity)
    }

    // MARK: Picture (explicit frame, tile → fitted)

    @ViewBuilder private func picture(_ entry: TrayEntry, size: CGSize, progress p: CGFloat) -> some View {
        let area = ShotsOverlayLogic.viewerArea(container: size, insets: insets)
        let aspect = entry.height > 0 ? CGFloat(entry.width) / CGFloat(entry.height) : 1.6
        let fitted = ShotsOverlayLogic.fittedRect(in: area, aspect: aspect,
                                                  natural: CGSize(width: CGFloat(entry.width) / 2, height: CGFloat(entry.height) / 2))
        let tile = ShotsOverlayLogic.zoomSource(tile: c.tileFrames[entry.id], overlay: size)
        // Crossfade (Reduce Motion) or the off-screen fallback: no travel, just a shrink-and-fade toward the centre.
        let from = reduceMotion ? fitted : (tile ?? ShotsOverlayLogic.centreShrink(of: fitted))
        let r = ShotsOverlayLogic.interpolate(from: from, to: fitted, t: p)
        let fades = reduceMotion || tile == nil
        let edge: Edge = c.slide >= 0 ? .trailing : .leading
        Group {
            if let full {
                Image(decorative: full, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                ThumbImage(entry: entry, fill: true)
            }
        }
        .frame(width: r.width, height: r.height)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.5 * p), radius: 30, y: 14)
        .opacity(fades ? p : 1)
        .onDrag { fileProvider(c.watcher.fileURL(for: entry)) }
        .position(x: r.midX, y: r.midY)
        .id(entry.id)
        .transition(c.slide == 0 || reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge == .trailing ? .leading : .trailing).combined(with: .opacity)))
    }

    // MARK: Chrome (never over the picture: the picture is fitted into the area that excludes all of it)

    private func chrome(_ entry: TrayEntry, size: CGSize) -> some View {
        let area = ShotsOverlayLogic.viewerArea(container: size, insets: insets)
        let sideX = c.insets.leading + ShotsOverlayLogic.sideReserve / 2
        let sideXR = size.width - c.insets.trailing - ShotsOverlayLogic.sideReserve / 2
        return ZStack {
            RoundButton(symbol: "xmark", help: "Close (Esc)", dark: !reduceTransparency) { c.closeViewer() }
                .position(x: sideX, y: c.insets.top + 22)
            RoundButton(symbol: "chevron.left", help: "Previous (←)", dark: !reduceTransparency) { c.step(-1) }
                .disabled(c.viewerIndex == 0).opacity(c.viewerIndex == 0 ? 0.35 : 1)
                .position(x: sideX, y: area.midY)
            RoundButton(symbol: "chevron.right", help: "Next (→)", dark: !reduceTransparency) { c.step(1) }
                .disabled(c.viewerIndex == c.entries.count - 1).opacity(c.viewerIndex == c.entries.count - 1 ? 0.35 : 1)
                .position(x: sideXR, y: area.midY)
            toolbar(entry)
                .position(x: size.width / 2, y: size.height - c.insets.bottom - 32)
        }
    }

    private func toolbar(_ entry: TrayEntry) -> some View {
        let url = c.watcher.fileURL(for: entry)
        return HStack(spacing: 2) {
            ToolbarButton(symbol: "paperplane", label: "Send", help: "Send to session") { c.send(entry) }
            ToolbarButton(symbol: "doc.on.doc", doneSymbol: "checkmark", label: "Copy", help: "Copy image") {
                guard let image = NSImage(contentsOf: url) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            ToolbarButton(symbol: "iphone.and.arrow.forward", label: "Phone", help: "Send to Phone") { PhoneOutbox.sendFile(url) }
            ToolbarButton(symbol: "pencil.tip.crop.circle", label: "Markup", help: "Mark up") { c.markingUp = true; c.makeKey() }
            ToolbarButton(symbol: "folder", label: "Finder", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            ToolbarButton(symbol: "trash", label: "Remove", help: "Remove from tray (the original file stays)") { c.delete(entry) }
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
}

/// 44 pt round glass button for the viewer's corners and sides.
private struct RoundButton: View {
    let symbol: String
    let help: String
    let dark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .background {
            if dark { Circle().fill(.clear).glassSurface(Circle(), tint: Color.black.opacity(0.5), hairline: false) }
            else { Circle().fill(Color(white: 0.12)) }
        }
        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Icon over a label, white on dark glass, 44 pt tall hit area.
private struct ToolbarButton: View {
    let symbol: String
    var doneSymbol: String?
    let label: String
    let help: String
    let action: () -> Void
    @State private var done = false
    @State private var bounce = 0
    @State private var hovering = false

    var body: some View {
        Button {
            action()
            bounce += 1
            if doneSymbol != nil {
                done = true
                Task { try? await Task.sleep(for: .milliseconds(1200)); done = false }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: done ? (doneSymbol ?? symbol) : symbol)
                    .font(.system(size: 17, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: bounce)
                    .frame(height: 20)
                Text(done ? "Copied" : label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(minWidth: 62, minHeight: 48)
            .background(.white.opacity(hovering ? 0.14 : 0), in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Downloads strip

private struct DownloadsGlassStrip: View {
    let controller: ShotsOverlayController
    private var d: DownloadsWatcher { controller.downloads }

    var body: some View {
        GlassContainer(spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Downloads").font(.callout.weight(.semibold))
                    Text("\(d.items.count)").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.72))
                }
                if d.unreadable {
                    Text("True can't read Downloads.").font(.callout).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                } else if d.items.isEmpty {
                    Text("No recent downloads").font(.callout).foregroundStyle(.white.opacity(0.72))
                    Spacer()
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) { ForEach(d.items) { DownloadChip(controller: controller, item: $0) } }
                    }
                    .scrollIndicators(.never)
                }
                ActionButton(symbol: "folder", help: "Show Downloads in Finder", bounceOnHover: true) {
                    NSWorkspace.shared.open(d.directory)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(height: 64)
            .chromeGlass(.rect(cornerRadius: 22, style: .continuous))
        }
        .opacity(controller.presented ? 1 : 0)
        .offset(y: controller.presented ? 0 : 14)
        .animation(.easeOut(duration: 0.28).delay(controller.presented ? 0.08 : 0), value: controller.presented)
    }
}

private struct DownloadChip: View {
    let controller: ShotsOverlayController
    let item: DownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 28, height: 28)
            Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading)
            ActionButton(symbol: "paperplane", help: "Send to session", flies: true) { controller.sendPath(item.url) }
            ActionButton(symbol: "iphone.and.arrow.forward", help: "Send to Phone") { PhoneOutbox.sendFile(item.url) }
            ActionButton(symbol: "link", doneSymbol: "checkmark", help: "Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .background(.white.opacity(hovering ? 0.10 : 0.05), in: .rect(cornerRadius: 14, style: .continuous))
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .onDrag { fileProvider(item.url) }
    }
}

// MARK: - Living icon button

/// A glass icon button with a symbol effect: bounce on hover (folder), a done-symbol morph for ~1.2 s
/// (copy → checkmark), or a bounce-then-fly-off (send).
struct ActionButton: View {
    let symbol: String
    var doneSymbol: String?
    let help: String
    var bounceOnHover = false
    var flies = false
    let action: () -> Void
    @State private var done = false
    @State private var bounce = 0
    @State private var gone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            action()
            if flies && !reduceMotion {
                bounce += 1
                withAnimation(.easeIn(duration: 0.22).delay(0.05)) { gone = true }
            } else if doneSymbol != nil {
                done = true
                Task { try? await Task.sleep(for: .milliseconds(1200)); done = false }
            }
        } label: {
            Image(systemName: done ? (doneSymbol ?? symbol) : symbol)
                .font(.system(size: 14, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 22, height: 22)
                .offset(x: gone ? 26 : 0, y: gone ? -26 : 0)
                .opacity(gone ? 0 : 1)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .onHover { if $0 && bounceOnHover && !reduceMotion { bounce += 1 } }
        .help(help)
        .accessibilityLabel(help)
    }
}
