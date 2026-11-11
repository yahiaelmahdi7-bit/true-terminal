import SwiftUI

/// Isolates the palette's observation so opening it never re-evaluates the whole window body.
struct ProjectPaletteHost: View {
    private let palette = ProjectPalette.shared
    var body: some View {
        Group { if palette.isOpen { ProjectPaletteView(palette: palette) } }
            .motion(.panel, value: palette.isOpen)
    }
}

/// Spotlight-style card floating near the top of the window: search field, project list, key hints.
struct ProjectPaletteView: View {
    @Bindable var palette: ProjectPalette
    @FocusState private var searchFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // Click outside closes. Near-clear (not clear) so it still takes the hit.
            Color.black.opacity(Theme.Alpha.scrim)
                .contentShape(Rectangle())
                .onTapGesture { palette.close() }
            card
                .frame(width: 560)
                .padding(.top, 90)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -Theme.Space.s2)))
        }
        .transition(.opacity)
    }

    private var card: some View {
        ProjectPaletteCard(query: $palette.query, rows: palette.visible, details: palette.details,
                           highlight: palette.highlight, loading: palette.loading, focus: $searchFocused,
                           submit: { palette.openHighlighted(withClaude: true) },
                           up: { palette.move(by: -1) }, down: { palette.move(by: 1) },
                           pick: { palette.open($0, withClaude: true) }, addFolder: { palette.addFolder() })
        .background {
            // Key equivalents that work while the text field has focus: ⌘↩ and Esc.
            Button("") { palette.openHighlighted(withClaude: false) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") { palette.close() }.keyboardShortcut(.cancelAction)
        }
    }
}

/// The card itself, free of the store so snapshots can render it from fixtures.
struct ProjectPaletteCard: View {
    @Binding var query: String
    var rows: [Project]
    var details: [String: ProjectPalette.Detail] = [:]
    var highlight = 0
    var loading = false
    var focus: FocusState<Bool>.Binding
    var submit: () -> Void = {}
    var up: () -> Void = {}
    var down: () -> Void = {}
    var pick: (Project) -> Void = { _ in }
    var addFolder: () -> Void = {}

    private let rowHeight: CGFloat = Theme.Hit.row
    private let maxRows = 9

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(Theme.Token.line).frame(height: 1)
            list(rows)
            Rectangle().fill(Theme.Token.line).frame(height: 1)
            footer
        }
        .floatingCardSurface()
    }

    private var searchField: some View {
        HStack(spacing: Theme.Space.s3) {
            Image(systemName: "magnifyingglass").font(Theme.Fonts.h3).foregroundStyle(Theme.Token.text2)
            TextField("Open project…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.h3)
                .foregroundStyle(Theme.Token.text0)
                .focused(focus)
                .onSubmit(submit)
                .onKeyPress(.upArrow) { up(); return .handled }
                .onKeyPress(.downArrow) { down(); return .handled }
        }
        .padding(.horizontal, Theme.Space.s4).padding(.vertical, Theme.Space.s4)
        .onAppear { DispatchQueue.main.async { focus.wrappedValue = true } }
    }

    @ViewBuilder
    private func list(_ rows: [Project]) -> some View {
        if rows.isEmpty {
            Text(loading ? "Looking…" : "No matching projects")
                .font(Theme.Fonts.small).foregroundStyle(Theme.Token.text2)
                .frame(maxWidth: .infinity).frame(height: 64)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, p in
                            ProjectRowView(project: p, detail: details[p.path], highlighted: i == highlight)
                                .frame(height: rowHeight)
                                .id(p.id)
                                .onTapGesture { pick(p) }
                        }
                    }
                    .padding(Theme.Space.s1 + 2)
                }
                .frame(height: CGFloat(min(rows.count, maxRows)) * rowHeight + Theme.Space.s3)
                .onChange(of: highlight) { _, h in
                    if rows.indices.contains(h) { proxy.scrollTo(rows[h].id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("↩ Open with Claude   ⌘↩ Open a shell   esc Close")
                .font(Theme.Fonts.label).foregroundStyle(Theme.Token.text2)
            Spacer()
            Button("Add Folder…") { addFolder() }
                .buttonStyle(.borderless).font(Theme.Fonts.label)
                .foregroundStyle(Theme.Token.text1)
                .padding(.horizontal, Theme.Space.s3)
                .frame(minHeight: Theme.Hit.control)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, Theme.Space.s4).padding(.vertical, Theme.Space.s2 + 1)
    }
}

private struct ProjectRowView: View {
    let project: Project
    let detail: ProjectPalette.Detail?
    let highlighted: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: Theme.Space.s2) {
            Image(systemName: "folder").font(Theme.Fonts.body).foregroundStyle(Theme.Token.text2).frame(width: Theme.Space.s5 - Theme.Space.s1)
            Text(project.name).font(Theme.Fonts.bodyMedium).foregroundStyle(Theme.Token.text0).lineLimit(1)
            Text(project.parent).font(Theme.Fonts.small).foregroundStyle(Theme.Token.text3).lineLimit(1)
            Spacer(minLength: Theme.Space.s2)
            if detail?.handoff == true {
                Text("handoff").font(Theme.Fonts.labelStrong).foregroundStyle(Theme.Token.text1)
                    .padding(.horizontal, Theme.Space.s2).padding(.vertical, Theme.Space.s1 / 2)
                    .background(Theme.Token.strongLine, in: .capsule)
                    .help("Unfinished work: a .claude/HANDOFF file is waiting here")
            }
            if let b = detail?.branch {
                Text(b).font(Theme.Fonts.label).foregroundStyle(Theme.Token.text3).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
        }
        .padding(.horizontal, Theme.Space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(highlighted ? Theme.Token.pressFill : hovered ? Theme.Token.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
