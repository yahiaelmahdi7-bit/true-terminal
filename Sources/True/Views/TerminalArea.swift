import SwiftUI

/// All tabs, all panes, in ONE flat coordinate space.
///
/// Why flat: SwiftUI keeps a view's identity (and so its running shell) only while its place in
/// the view tree is unchanged. A recursive split view would re-parent a pane whenever it is split
/// and restart its shell. Here every pane is a sibling in one `ForEach`, positioned by
/// `SplitTree.layout(in:)` — splitting only changes a frame. All tabs stay mounted; hidden ones are
/// invisible and untouchable, so switching tabs never kills anything.
struct TerminalArea: View {
    let model: WorkspaceModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(model.state.tabs) { tab in
                    TabContent(model: model, tab: tab, size: geo.size,
                               visible: tab.id == model.state.selectedTab)
                }
            }
            .coordinateSpace(.named("area"))
        }
    }
}

private struct TabContent: View {
    let model: WorkspaceModel
    let tab: TabState
    let size: CGSize
    let visible: Bool

    var body: some View {
        let layout = tab.tree.layout(in: size)
        ZStack(alignment: .topLeading) {
            // Stable order (not tree order): a move reshuffles the tree, and a reordered ForEach would
            // detach and re-attach terminal views. Panes never overlap, so z-order is irrelevant.
            ForEach(tab.tree.leafIDs.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                if let r = layout.panes[id] {
                    let focused = visible && tab.focusedPane == id
                    EmbeddedTerminal(paneID: id, startDir: tab.cwds[id] ?? NSHomeDirectory(), isFocused: focused,
                                     isVisible: visible)
                        .opacity(PaneDrag.shared.pane == id ? 0.35 : (focused || tab.tree.leafIDs.count == 1 ? 1 : 0.6))
                        .padding(Theme.paneInsets)
                        .frame(width: r.width, height: r.height)
                        .background(Theme.background)
                        .overlay {
                            if DropTarget.shared.pane == id {
                                Rectangle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1).allowsHitTesting(false)
                            }
                        }
                        .position(x: r.midX, y: r.midY)
                    if visible, let site = SiteModel.shared.sites(in: id).first {
                        SitePill(site: site)
                            .position(x: r.maxX - 60, y: r.maxY - 22)
                    }
                }
            }
            ForEach(layout.dividers, id: \.splitID) { d in
                DividerHandle(divider: d,
                              onFraction: { f in model.setFraction(f, split: d.splitID, tab: tab.id) },
                              onEqualize: { model.equalize(split: d.splitID, tab: tab.id) })
            }
            if visible, tab.tree.leafIDs.count > 1 {
                ForEach(tab.tree.leafIDs.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                    if let r = layout.panes[id], r.width > PaneGrip.width, r.height > PaneGrip.height * 3 {
                        PaneGrip(pane: id, model: model, tab: tab, size: size)
                            .position(x: r.midX, y: r.minY + PaneGrip.height / 2)
                    }
                }
                if let t = PaneDrag.shared.target, let r = layout.panes[t.pane] {
                    PaneDropPreview(rect: SplitTree.previewRect(of: t.zone, in: r))
                }
            }
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}

/// 1pt line with a 7pt grab area; dragging reports a new proportion of the split's region, and a
/// double-click snaps the row back to equal shares.
private struct DividerHandle: View {
    let divider: SplitTree.DividerFrame
    let onFraction: (Double) -> Void
    let onEqualize: () -> Void

    var body: some View {
        let f = divider.frame
        let horizontal = divider.axis == .horizontal
        let hit = CGRect(x: f.midX - (horizontal ? 3.5 : f.width / 2),
                         y: f.midY - (horizontal ? f.height / 2 : 3.5),
                         width: horizontal ? 7 : f.width,
                         height: horizontal ? f.height : 7)
        Rectangle().fill(Color.primary.opacity(0.001))
            .overlay(Rectangle().fill(Theme.hairline)
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1))
            .frame(width: hit.width, height: hit.height)
            .contentShape(Rectangle())
            .position(x: hit.midX, y: hit.midY)
            .trueCursor(horizontal ? .columnResize : .rowResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("area")).onChanged { v in
                let r = divider.region
                let frac = horizontal ? (v.location.x - r.minX) / r.width : (v.location.y - r.minY) / r.height
                onFraction(Double(frac))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onEqualize() })
    }
}
