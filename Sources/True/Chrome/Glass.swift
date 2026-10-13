import SwiftUI

/// The only place that names macOS 26 Liquid Glass. On 26 these are exactly `glassEffect` /
/// `GlassEffectContainer` / `.glass`; on macOS 15 they fall back to a blurred material with the
/// same tint and a hairline edge, so call sites stay free of availability checks.
extension View {
    /// Liquid Glass in `shape` (optionally tinted). `hairline` adds the edge only the fallback needs,
    /// for call sites that don't already draw their own.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ shape: S, tint: Color? = nil, hairline: Bool = true) -> some View {
        if #available(macOS 26, *) {
            if let tint {
                glassEffect(.regular.tint(tint), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint) }
                    if hairline { shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                }
            }
            .clipShape(shape)
        }
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
