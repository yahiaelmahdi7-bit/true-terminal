import SwiftUI

/// The ONE place colour lives in True (doctrine, Run 8): an agent's avatar. Colour means identity
/// ("who is this"), never state — state stays monochrome (presence dot, words). Ten hue-adjacent
/// gradients, light at top-leading to deep at bottom-trailing; never a cross-hue rainbow.
enum AgentHue: String, CaseIterable, Codable, Sendable {
    case sun, tangerine, coral, rose, magenta, lime, mint, aqua, azure, cobalt

    /// (light, deep) as 0xRRGGBB.
    private var stops: (UInt32, UInt32) {
        switch self {
        case .sun: return (0xFFD60A, 0xFF9F0A)
        case .tangerine: return (0xFFB340, 0xFF6A00)
        case .coral: return (0xFF8A65, 0xFF3B30)
        case .rose: return (0xFF7AA8, 0xFF2D55)
        case .magenta: return (0xFF6BE0, 0xD6249F)
        case .lime: return (0xC6F432, 0x34C759)
        case .mint: return (0x66F0C8, 0x00B386)
        case .aqua: return (0x6EE7FF, 0x00A3D9)
        case .azure: return (0x5AC8FA, 0x0A84FF)
        case .cobalt: return (0x4DA3FF, 0x0A5CFF)
        }
    }

    var light: Color { Self.color(stops.0) }
    var deep: Color { Self.color(stops.1) }
    var gradient: LinearGradient {
        LinearGradient(colors: [light, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Asleep: each stop pulled to 10% of its saturation (toward its own luma grey) — a faint hint of hue,
    /// no brown mud. Done in the colours themselves, not with `.saturation()`, so it renders the same in
    /// snapshots (ImageRenderer ignores that filter) and on screen.
    var asleepGradient: LinearGradient {
        func fade(_ hex: UInt32) -> Color {
            let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
            let y = 0.299 * r + 0.587 * g + 0.114 * b, k = 0.10
            return Color(red: y + (r - y) * k, green: y + (g - y) * k, blue: y + (b - y) * k)
        }
        return LinearGradient(colors: [fade(stops.0), fade(stops.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Black on the bright hues, white on the rest — whichever keeps the glyph readable.
    var glyphIsDark: Bool {
        switch self {
        case .sun, .lime, .mint, .aqua: return true
        default: return false
        }
    }
    var glyphColor: Color { glyphIsDark ? Color.black.opacity(0.82) : .white }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    /// FNV-1a 32-bit over the UTF-8 bytes, mod 10. Deliberately NOT `hashValue`: Swift randomises that
    /// per launch, and an agent's colour must never change between runs.
    static func derived(from name: String) -> AgentHue {
        var h: UInt32 = 2_166_136_261
        for b in name.utf8 { h ^= UInt32(b); h = h &* 16_777_619 }
        return allCases[Int(h % UInt32(allCases.count))]
    }
}

extension Agent {
    /// The stored hue when it is one of the ten, else derived from the name (stable across launches).
    var resolvedHue: AgentHue { hue.flatMap(AgentHue.init(rawValue:)) ?? AgentHue.derived(from: name) }
}

/// Vivid gradient disc + glyph, Messages-style presence dot. `hue == nil` = a stranger (not our crew):
/// a plain grey disc, no colour.
struct AgentAvatar: View {
    let hue: AgentHue?
    let symbol: String
    let status: AgentStatus
    var size: CGFloat = 40
    var parentHue: AgentHue?
    var showsPresence = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The breathing glow is a repeatForever animation. The Hub is removed from the view tree while
    // hidden (TrueApp's `if registry.panelOpen`), so it costs nothing then — it only runs while visible.
    @State private var breathe = false

    private var ringGap: CGFloat { 2 }
    private var ringed: Bool { parentHue != nil || (status == .needsYou && hue != nil) }
    private var lit: Bool { status != .asleep }
    private var glows: Bool { hue != nil && (status == .working || status == .needsYou) }

    var body: some View {
        // The outer footprint is always `size`: a ring shrinks the disc inside it (2pt ring + 2pt gap each side),
        // so ringed and unringed avatars line up in a column.
        ZStack {
            disc
            if let ring = ringColor {
                Circle().strokeBorder(ring, lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) { if showsPresence && hue != nil { presence } }
        .accessibilityHidden(true)
    }

    private var ringColor: Color? {
        if let parentHue { return parentHue.deep }
        return status == .needsYou && hue != nil ? .white : nil
    }

    @ViewBuilder private var disc: some View {
        let d = size - (ringed ? (ringGap + 2) * 2 : 0)
        ZStack {
            if let hue {
                Circle().fill(status == .asleep ? hue.asleepGradient : hue.gradient)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.30), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.55)))
                    .clipShape(Circle())
                Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                Image(systemName: symbol)
                    .font(.system(size: d * 0.46, weight: .semibold))
                    .foregroundStyle(hue.glyphColor)
                    .shadow(color: hue.glyphIsDark ? .clear : .black.opacity(0.25), radius: 1, y: 0.5)
            } else {
                Circle().fill(.white.opacity(0.08))
                Image(systemName: symbol).font(.system(size: d * 0.46, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: d, height: d)
        .opacity(status == .asleep && hue != nil ? 0.55 : 1)
        .shadow(color: glows ? (hue?.deep ?? .clear).opacity(glowOpacity) : .clear, radius: 8)
        .onAppear { if status == .working && !reduceMotion { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true } } }
        .onChange(of: status) { _, s in
            if s == .working && !reduceMotion {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathe = true }
            } else {
                withAnimation(nil) { breathe = false }
            }
        }
    }

    /// ~0.45 static; while working (and motion allowed) it breathes between 0.25 and 0.45.
    private var glowOpacity: Double { status == .working && !reduceMotion ? (breathe ? 0.45 : 0.22) : 0.45 }

    private var presence: some View {
        let dot = size * 0.28
        return Circle().fill(status.tint)
            .frame(width: dot, height: dot)
            .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2).frame(width: dot + 4, height: dot + 4))
            .offset(x: 1, y: 1)
    }
}
