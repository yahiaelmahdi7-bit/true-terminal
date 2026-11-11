import SwiftUI

/// The only place that names macOS 26 Liquid Glass. On 26 these are exactly `glassEffect` /
/// `GlassEffectContainer` / `.glass`; on macOS 15 they fall back to a blurred material with the
/// same tint and a hairline edge, so call sites stay free of availability checks.
extension View {
    /// Liquid Glass in `shape` (optionally tinted). `hairline` adds the edge only the fallback needs,
    /// for call sites that don't already draw their own.
    func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, hairline: Bool = true) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, hairline: hairline))
    }

    /// `.buttonStyle(.glass)` on 26, `.bordered` on 15.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// `GlassEffectContainer` on 26 (glass shapes inside merge/morph); plain content on 15.
struct GlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

/// Glass, or (Reduce Transparency) a solid bg2 fill with a 1pt strong edge, for every call site.
private struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let tint: Color?
    let hairline: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(Theme.Token.bg2))
                .overlay(shape.strokeBorder(Theme.Token.strongLine, lineWidth: 1))
                .clipShape(shape)
        } else if #available(macOS 26, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint) }
                        if hairline { shape.strokeBorder(Theme.Veil.edge, lineWidth: 0.5) }
                    }
                }
                .clipShape(shape)
        }
    }
}

/// A list row: at least `Theme.Hit.row` tall, whole-row hit shape, hover fill (selected keeps its own fill).
private struct HitRow: ViewModifier {
    let selected: Color?
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: Theme.Hit.row, alignment: .leading)
            .background(selected ?? (hovering ? Theme.Token.hoverFill : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .motion(.micro, value: hovering)
    }
}

extension View {
    /// Row sizing + hover for list rows. Pass the selected fill when the row is selected.
    func hitRow(selected: Color? = nil) -> some View { modifier(HitRow(selected: selected)) }
}
