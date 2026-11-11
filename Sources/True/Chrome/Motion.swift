import SwiftUI

/// Named springs (tokens.md "Motion springs"). Values are SwiftUI-preset-equivalent (response, damping
/// fraction), not measured from reference apps. Every spring has a Reduce Motion fallback: a 120 ms
/// opacity crossfade, with no scale or slide.
enum Motion: CaseIterable {
    /// Hover, press, focus ring.
    case micro
    /// Row select, inspector content, count change.
    case list
    /// Call panel, toast, banner enter/exit.
    case panel

    var response: Double {
        switch self {
        case .micro: return 0.22
        case .list: return 0.38
        case .panel: return 0.5
        }
    }

    var damping: Double {
        switch self {
        case .micro: return 1.0
        case .list: return 0.92
        case .panel: return 0.86
        }
    }

    static let reducedDuration = 0.12

    var spring: Animation { .spring(response: response, dampingFraction: damping) }
    static var crossfade: Animation { .easeInOut(duration: reducedDuration) }

    /// The animation to use right now: the spring, or the crossfade when Reduce Motion is on.
    func animation(reduceMotion: Bool) -> Animation { reduceMotion ? Motion.crossfade : spring }
}

private struct MotionAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let motion: Motion
    let value: V
    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation` with a named spring that falls back to a crossfade under Reduce Motion.
    /// Callers should drive an opacity change (not a scale/slide) so the fallback reads as a crossfade.
    func motion<V: Equatable>(_ motion: Motion, value: V) -> some View {
        modifier(MotionAnimation(motion: motion, value: value))
    }
}
