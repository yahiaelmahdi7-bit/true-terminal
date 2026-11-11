import SwiftUI
import AppKit

/// The panel's content: collapsed pill ⇄ 4-column grid ⇄ zoom, one glass surface that the controller resizes.
struct TrayPanelRoot: View {
    let controller: TrayPanelController
    private let watcher = ScreenshotWatcher.shared
    @Namespace private var ns
    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            switch controller.mode {
            case .collapsed:
                Pill(watcher: watcher, controller: controller)
            case .grid:
                GridPanel(controller: controller, watcher: watcher, ns: ns)
            case .zoom(let id):
                if let entry = watcher.entries.first(where: { $0.id == id }) {
                    ZoomPanel(controller: controller, watcher: watcher, entry: entry, ns: ns)
                } else {
                    Color.clear.onAppear { controller.set(.grid) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(TrayGlass(shape: Self.shape, solid: reduceTransparency))
        .overlay(alignment: .bottom) { Toast(controller: controller, watcher: watcher) }
        .preferredColorScheme(.dark)
        .onExitCommand { controller.escape() }
    }
}

/// Tray surface: dark glass, or a solid `bg2` card with a visible edge under Reduce Transparency.
private struct TrayGlass: ViewModifier {
    let shape: RoundedRectangle
    let solid: Bool
    func body(content: Content) -> some View {
        if solid {
            content
                .background(Theme.Token.bg2, in: shape)
                .overlay(shape.strokeBorder(Theme.Token.strongLine, lineWidth: 1))
        } else {
            content
                .glassSurface(shape, tint: .black.opacity(0.7), hairline: false)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
    }
}

// MARK: - Collapsed

private struct Pill: View {
    let watcher: ScreenshotWatcher
    let controller: TrayPanelController
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Not a Button: one gesture tells a click (< 4 pt of travel) from a drag-to-corner.
        Group {
            HStack(spacing: 10) {
                ZStack {
                    ForEach(Array(watcher.entries.prefix(3).enumerated().reversed()), id: \.element.id) { i, e in
                        ThumbImage(entry: e, fill: true)
                            .frame(width: 38, height: 26)
                            .clipShape(.rect(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.Veil.edgeStrong, lineWidth: 0.5))
                            .rotationEffect(.degrees(Double(i) * -5))
                            .offset(x: CGFloat(i) * 7, y: CGFloat(i) * -1.5)
                    }
                    if watcher.entries.isEmpty {
                        Image(systemName: "camera.viewfinder").font(.callout).foregroundStyle(Theme.dimText)
                    }
                }
                .frame(width: 58, height: 32, alignment: .leading)
                Text("\(watcher.entries.count)").font(.callout.monospacedDigit()).foregroundStyle(Theme.text)
                if watcher.fresh {
                    Circle().fill(.white).frame(width: 6, height: 6).transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hovering ? Theme.Token.hoverFill : .clear, in: .rect(cornerRadius: Theme.Radius.sm, style: .continuous))
            .contentShape(.rect)
        }
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in controller.dragChanged() }
            .onEnded { _ in if controller.dragEnded() { controller.set(.grid) } })
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.set(.grid) }
        .help("Screenshots — ⇧⌘S; drag to move to a corner")
        .motion(.micro, value: watcher.fresh)
        .motion(.micro, value: hovering)
    }
}

// MARK: - Grid

private struct GridPanel: View {
    let controller: TrayPanelController
    let watcher: ScreenshotWatcher
    let ns: Namespace.ID
    private let downloads = DownloadsWatcher.shared
    private let columns = Array(repeating: GridItem(.fixed(96), spacing: 8, alignment: .top), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Screenshots").font(.callout.weight(.semibold))
                Text("\(watcher.entries.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "folder", help: "Show \(watcher.folder.lastPathComponent) in Finder") {
                    NSWorkspace.shared.open(watcher.folder)
                }
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open full screen — ⌃⌥⌘S") {
                    ShotsOverlayController.shared.show()
                }
                IconButton(symbol: "chevron.up", help: "Collapse (Esc)") { controller.set(.collapsed) }
            }
            Group {
            if watcher.unreadable && watcher.entries.isEmpty {
                Text("True can't read \(watcher.folder.lastPathComponent).")
                    .font(.callout).foregroundStyle(Theme.text).padding(.top, 6)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                        NSWorkspace.shared.open(url)
                    }
                }.controlSize(.small)
                Spacer(minLength: 0)
            } else if watcher.entries.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No screenshots yet").font(.callout).foregroundStyle(Theme.text)
                    Text("New ones in \(watcher.folder.lastPathComponent) appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(watcher.entries) { e in GridTile(controller: controller, watcher: watcher, entry: e, ns: ns) }
                    }
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.never)
            }
            }
            .frame(height: TrayPanelController.shotsAreaHeight, alignment: .top)
            DownloadsStrip(controller: controller, downloads: downloads)
        }
        .padding(12)
        .onChange(of: downloads.items.count) { controller.place(animated: true) }
    }
}

// MARK: - Downloads strip

private struct DownloadsStrip: View {
    let controller: TrayPanelController
    let downloads: DownloadsWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Theme.hairline).padding(.bottom, 4)
            HStack(spacing: 8) {
                Text("Downloads").font(.callout.weight(.semibold))
                Text("\(downloads.items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "folder", help: "Show Downloads in Finder") {
                    NSWorkspace.shared.open(downloads.directory)
                }
            }
            if downloads.unreadable {
                Text("True can't read Downloads.").font(.callout).foregroundStyle(Theme.text)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                        NSWorkspace.shared.open(url)
                    }
                }.controlSize(.small)
            } else if downloads.items.isEmpty {
                Text("No recent downloads").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(downloads.items) { item in DownloadRow(controller: controller, item: item) }
            }
        }
    }
}

private struct DownloadRow: View {
    let controller: TrayPanelController
    let item: DownloadItem
    @State private var hovering = false

    private var detail: String {
        let age = ScreenshotWatcher.relativeLabel(for: item.modified, now: Date(), calendar: .current)
        return item.isDirectory ? age : "\(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)) · \(age)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 18, height: 18)
            Text(item.name).font(.callout).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            IconButton(symbol: "paperplane", help: "Send to session") {
                ScreenshotWatcher.shared.sendPath(item.url)
                controller.showToast("Sent to session")
            }
            IconButton(symbol: "iphone.and.arrow.forward", help: "Send to Phone") { PhoneOutbox.sendFile(item.url) }
            IconButton(symbol: "link", help: "Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
                controller.showToast("Path copied")
            }
        }
        .padding(.leading, 4)
        .frame(height: TrayPanelController.downloadRowHeight - 4)
        .background(hovering ? Theme.hubHoverFill : .clear, in: .rect(cornerRadius: Theme.Radius.sm, style: .continuous))
        .contentShape(.rect(cornerRadius: Theme.Radius.sm, style: .continuous))
        .onHover { hovering = $0 }
        .motion(.micro, value: hovering)
        .onDrag { fileProvider(item.url) }
    }
}

private struct GridTile: View {
    let controller: TrayPanelController
    let watcher: ScreenshotWatcher
    let entry: TrayEntry
    let ns: Namespace.ID
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Button { controller.set(.zoom(entry.id)) } label: {
                ThumbImage(entry: entry, fill: true)
                    .matchedGeometryEffect(id: entry.id, in: ns)
                    .frame(width: 96, height: 62)
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder((hovering ? Theme.Veil.edgeBright : Theme.Veil.edgeStrong), lineWidth: 0.5))
                    .overlay(alignment: .topTrailing) {
                        if entry.kind == .markup {
                            Image(systemName: "pencil.tip").font(Theme.Fonts.icon(.xs, .bold))
                                .padding(3).background(.black.opacity(0.6), in: .circle).padding(3)
                        }
                    }
                    .contentShape(.rect(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .motion(.micro, value: hovering)
            .onDrag { fileProvider(watcher.fileURL(for: entry)) }
            Text(ScreenshotWatcher.relativeLabel(for: entry.created, now: Date(), calendar: .current))
                .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

func fileProvider(_ url: URL) -> NSItemProvider { NSItemProvider(contentsOf: url) ?? NSItemProvider() }

// MARK: - Zoom

private struct ZoomPanel: View {
    let controller: TrayPanelController
    let watcher: ScreenshotWatcher
    let entry: TrayEntry
    let ns: Namespace.ID
    @State private var full: CGImage?

    private var url: URL { watcher.fileURL(for: entry) }

    var body: some View {
        VStack(spacing: 0) {
            if controller.markingUp, let full {
                MarkupEditor(controller: controller, watcher: watcher, entry: entry, image: full)
            } else {
                toolbar
                ZStack {
                    if let full {
                        Image(decorative: full, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ThumbImage(entry: entry, fill: false)
                    }
                }
                .matchedGeometryEffect(id: entry.id, in: ns)
                .padding([.horizontal, .bottom], 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDrag { fileProvider(url) }
            }
        }
        .task(id: entry.id) {
            let u = url
            full = await Task.detached { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }.value
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "chevron.left", help: "Back to all (Esc)") { controller.set(.grid) }
            Text(ScreenshotWatcher.relativeLabel(for: entry.created, now: Date(), calendar: .current))
                .font(.caption.monospaced()).foregroundStyle(.secondary).padding(.leading, 2)
            Spacer()
            IconButton(symbol: "pencil.tip.crop.circle", help: "Mark up") {
                controller.markingUp = true
                controller.makeKey()
            }
            IconButton(symbol: "doc.on.doc", help: "Copy image (⌘C)") {
                guard let image = NSImage(contentsOf: url) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                controller.showToast("Image copied")
            }
            .keyboardShortcut("c")
            IconButton(symbol: "paperplane", help: "Send to session") {
                watcher.send(entry)
                controller.showToast("Sent to session")
            }
            IconButton(symbol: "iphone.and.arrow.forward", help: "Send to Phone") { PhoneOutbox.sendFile(url) }
            IconButton(symbol: "link", help: "Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
                controller.showToast("Path copied")
            }
            IconButton(symbol: "folder", help: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            IconButton(symbol: "trash", help: "Remove from tray") {
                watcher.remove(entry)
                controller.set(.grid)
                controller.showToast("Removed")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: TrayPanelController.zoomChrome)
    }
}

// MARK: - Shared bits

struct ThumbImage: View {
    let entry: TrayEntry
    let fill: Bool
    private let watcher = ScreenshotWatcher.shared

    var body: some View {
        Group {
            if let image = watcher.thumbnail(for: entry) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Theme.Veil.fill
            }
        }
        .task(id: entry.id) { await watcher.loadThumbnail(for: entry) }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(Theme.Fonts.icon(.md, .regular))
                .foregroundStyle(selected || hovering ? Theme.text : Theme.hubSecondary)
                .frame(width: Theme.Hit.control, height: Theme.Hit.control)
                .background(selected ? Theme.hubCardStroke : (hovering ? Theme.hubHoverFill : .clear),
                            in: .rect(cornerRadius: Theme.Radius.sm, style: .continuous))
                .contentShape(.rect(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.micro, value: hovering)
        .help(help)
    }
}

private struct Toast: View {
    let controller: TrayPanelController
    let watcher: ScreenshotWatcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let text = controller.toast {
            HStack(spacing: 10) {
                Text(text).font(.caption).foregroundStyle(Theme.text)
                if text == "Removed" {
                    Button {
                        watcher.restoreLastRemoved()
                        controller.toast = nil
                    } label: {
                        Text("Undo").font(.caption.weight(.semibold))
                            .padding(.horizontal, Theme.Space.s2).frame(minHeight: Theme.Hit.control)
                    }
                    .buttonStyle(PillButtonStyle(shape: Capsule(), rest: .white, hover: .white))
                }
            }
            .padding(.horizontal, 12).frame(minHeight: Theme.Hit.control)
            .background(.black.opacity(0.85), in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
            .padding(.bottom, 10)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .motion(.panel, value: controller.toast)
        }
    }
}
