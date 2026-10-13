import AppKit
import Observation
import SwiftUI

/// The one in-flight pane drag. Written only by the grip's gesture callbacks; while no drag is live
/// nothing here runs (the Esc key monitor exists only between drag start and end).
@MainActor @Observable
final class PaneDrag {
    static let shared = PaneDrag()
    private(set) var pane: UUID?
    private(set) var target: (pane: UUID, zone: SplitTree.DropZone)?
    private var cancelled = false
    @ObservationIgnored private var monitor: Any?

    func update(pane: UUID, tree: SplitTree, location: CGPoint, size: CGSize) {
        if self.pane == nil { begin(pane) }
        guard !cancelled else { return }
        let t = tree.dropTarget(at: location, in: size, excluding: pane)
        if t?.pane != target?.pane || t?.zone != target?.zone { target = t }
    }

    /// Ends the drag; the landing spot, or nil when cancelled / dropped outside any pane.
    func finish() -> (pane: UUID, target: UUID, zone: SplitTree.DropZone)? {
        defer { reset() }
        guard !cancelled, let p = pane, let t = target else { return nil }
        return (p, t.pane, t.zone)
    }

    func cancel() { cancelled = true; target = nil }

    private func begin(_ p: UUID) {
        pane = p; cancelled = false; target = nil
        // Esc cancels. Local monitor, installed only for the duration of a drag.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { PaneDrag.shared.cancel() }
            return nil
        }
    }

    private func reset() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; pane = nil; target = nil; cancelled = false
    }
}

/// The pick-up handle: a small pill at the top centre of a pane that appears on hover. Only its own
/// rect takes the mouse, so terminal clicks, selection and scrolling are untouched everywhere else.
struct PaneGrip: View {
    let pane: UUID
    let model: WorkspaceModel
    let tab: TabState
    let size: CGSize
    @State private var hovering = false

    static let width: CGFloat = 44, height: CGFloat = 14

    var body: some View {
        let dragging = PaneDrag.shared.pane == pane
        Capsule()
            .fill(dragging ? Theme.dimText : Theme.hairline)
            .overlay(Capsule().strokeBorder(Theme.dimText, lineWidth: 0.5))
            .frame(width: Self.width, height: 6)
            .frame(width: Self.width, height: Self.height)
            .contentShape(Rectangle())
            .opacity(hovering || dragging ? 1 : 0)
            .onHover { hovering = $0 }
            .pointerStyle(dragging ? .grabActive : .grabIdle)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("area"))
                .onChanged { v in
                    PaneDrag.shared.update(pane: pane, tree: tab.tree, location: v.location, size: size)
                }
                .onEnded { _ in
                    if let d = PaneDrag.shared.finish() { model.movePane(d.pane, onto: d.target, zone: d.zone) }
                })
            .accessibilityLabel("Move pane")
            .accessibilityHint("Drag onto another pane's edge to move this pane beside it, or onto its middle to swap places. Escape cancels.")
            .accessibilityAddTraits(.isButton)
    }
}

/// Shaded landing zone drawn over the pane the drag is hovering.
struct PaneDropPreview: View {
    let rect: CGRect
    var body: some View {
        Rectangle().fill(Theme.hairline)
            .overlay(Rectangle().strokeBorder(Theme.dimText, lineWidth: 1))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}
