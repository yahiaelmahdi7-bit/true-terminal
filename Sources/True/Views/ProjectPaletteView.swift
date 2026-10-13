import SwiftUI

/// Isolates the palette's observation so opening it never re-evaluates the whole window body.
struct ProjectPaletteHost: View {
    private let palette = ProjectPalette.shared
    var body: some View {
        if palette.isOpen { ProjectPaletteView(palette: palette) }
    }
}

/// Spotlight-style card floating near the top of the window: search field, project list, key hints.
struct ProjectPaletteView: View {
    @Bindable var palette: ProjectPalette
    @FocusState private var searchFocused: Bool

    private let rowHeight: CGFloat = 36
    private let maxRows = 9

    var body: some View {
        ZStack(alignment: .top) {
            // Click outside closes. Near-clear (not clear) so it still takes the hit.
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { palette.close() }
            card
                .frame(width: 560)
                .padding(.top, 90)
        }
        .transition(.opacity)
    }

    private var card: some View {
        let rows = palette.visible
        return VStack(spacing: 0) {
            searchField
            Divider().opacity(0.5)
            list(rows)
            Divider().opacity(0.5)
            footer
        }
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        .background {
            // Key equivalents that work while the text field has focus: ⌘↩ and Esc.
            Button("") { palette.openHighlighted(withClaude: false) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") { palette.close() }.keyboardShortcut(.cancelAction)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
            TextField("Open project…", text: $palette.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { palette.openHighlighted(withClaude: true) }
                .onKeyPress(.upArrow) { palette.move(by: -1); return .handled }
                .onKeyPress(.downArrow) { palette.move(by: 1); return .handled }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    @ViewBuilder
    private func list(_ rows: [Project]) -> some View {
        if rows.isEmpty {
            Text(palette.loading ? "Looking…" : "No matching projects")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).frame(height: 64)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, p in
                            ProjectRowView(project: p, detail: palette.details[p.path], highlighted: i == palette.highlight)
                                .frame(height: rowHeight)
                                .id(p.id)
                                .onTapGesture { palette.open(p, withClaude: true) }
                        }
                    }
                    .padding(6)
                }
                .frame(height: CGFloat(min(rows.count, maxRows)) * rowHeight + 12)
                .onChange(of: palette.highlight) { _, h in
                    if rows.indices.contains(h) { proxy.scrollTo(rows[h].id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("↩ Open with Claude   ⌘↩ Open a shell   esc Close")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Add Folder…") { palette.addFolder() }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

private struct ProjectRowView: View {
    let project: Project
    let detail: ProjectPalette.Detail?
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 20)
            Text(project.name).font(.body.weight(.medium)).lineLimit(1)
            Text(project.parent).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 8)
            if detail?.handoff == true {
                Text("handoff").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.white.opacity(0.16), in: .capsule)
                    .help("Unfinished work: a .claude/HANDOFF file is waiting here")
            }
            if let b = detail?.branch {
                Text(b).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .background(highlighted ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}
