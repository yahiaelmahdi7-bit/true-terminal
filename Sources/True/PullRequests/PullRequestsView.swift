import SwiftUI

/// The open PRs: title · author · +/− · gate word · Held pill. Shows what `PRListState` says; no rule lives here.
struct PullRequestsView: View {
    let state: PRListState
    var onOpen: (PRRow) -> Void = { _ in }
    var onSignIn: () -> Void = {}
    /// Stills only: start with the rows scrolled to the bottom.
    var startAtEnd = false

    /// One row (52) plus its divider (1). The rows' scroll area is never taller than this times the row count, so a short
    /// list hugs its content, and never taller than the room left, so a long list scrolls inside its window.
    static let rowPitch: CGFloat = 53

    /// Height the rows' scroll area actually got. Shorter than all the rows = the list is cut off = the footer gets its hairline.
    @State private var rowsHeight: CGFloat = .infinity
    static func isCutOff(rows: Int, height: CGFloat) -> Bool { height < CGFloat(rows) * rowPitch - 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PRScreenCopy.title).font(Theme.Fonts.h3.weight(.semibold)).foregroundStyle(Theme.Token.text0)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            if state.showsSignIn {
                PRSignInEmpty(onSignIn: onSignIn)
            } else {
                if let m = state.message {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m).foregroundStyle(Theme.Token.text1)
                        if let s = state.secondLine { Text(s).foregroundStyle(Theme.Token.text2) }
                    }
                    .font(Theme.Fonts.body).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                }
                if state.showsRows {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                ForEach(state.rows, id: \.number) { row in
                                    Button { onOpen(row) } label: { rowView(PRRowLine(row), heldColumn: state.anyHeld) }.buttonStyle(.plain)
                                    Divider().overlay(Theme.Token.line)
                                }
                            }
                        }
                        .frame(maxHeight: CGFloat(state.rows.count) * Self.rowPitch)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                        .onAppear { if startAtEnd, let last = state.rows.last { proxy.scrollTo(last.number, anchor: .bottom) } }
                    }
                }
                if let f = state.footer {
                    if Self.isCutOff(rows: state.rows.count, height: rowsHeight) { Divider().overlay(Theme.Token.line) }
                    Text(f).font(Theme.Fonts.small).foregroundStyle(Theme.Token.text2).padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Token.bg0)
    }

    private func rowView(_ r: PRRowLine, heldColumn: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(Theme.Fonts.bodyMedium).foregroundStyle(Theme.Token.text0).lineLimit(1).truncationMode(.tail)
                Text(r.author).font(Theme.Fonts.label).foregroundStyle(Theme.Token.text2).lineLimit(1)
            }
            Spacer(minLength: 8)
            PRCounts(added: r.added, removed: r.removed)
            PRGateWord(word: r.gate).frame(width: 56, alignment: .trailing)
            if heldColumn { ZStack(alignment: .trailing) { if r.held { PRHeldPill() } }.frame(width: 52, alignment: .trailing) }
        }
        .padding(.horizontal, 20).frame(height: 52).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
