import AppKit
import CoreImage
import SwiftUI

/// True's whole palette. Black, no chrome: every surface is the terminal's own black, and the only
/// lines are hairlines between panes. Views and the terminal bridge read these, never literals.
///
/// COLOUR DOCTRINE (Run 8, 2026-09-30): True is black and white. Colour exists in exactly ONE place —
/// agent avatars (`AgentAvatar`, `AgentHue`) — and it means IDENTITY ("who"), never state. Model tier
/// stays brightness (`AgentModel.tint`); status stays monochrome (`AgentStatus.tint`, words, the presence
/// dot). Anything else that wants a colour is wrong. That governs True's own chrome: terminal OUTPUT keeps
/// the colours programs paint unless Settings turns colour off (amended 2026-10-06).
enum Theme {
    static let background = Color.black
    static let hairline = Color.white.opacity(0.10)
    static let text = Color.white.opacity(0.88)
    static let dimText = Color.white.opacity(0.38)
    /// Hub-local secondary text: ~0.82 white keeps ≥7:1 even where the pop-up's tinted glass lets terminal
    /// output bleed through (`dimText` is too faint for that and the terminal chrome still uses it, so it is left alone).
    static let hubSecondary = Color.white.opacity(0.82)
    static let hubCardFill = Color.white.opacity(0.05)
    static let hubCardStroke = Color.white.opacity(0.08)
    static let hubHoverFill = Color.white.opacity(0.05)
    /// The one warm colour (Run 12): an Overseer "Unverified" verdict. Everything else stays monochrome.
    static let verdictWarn = Color(red: 1.0, green: 0.62, blue: 0.24)
    /// Hub triage only: a failed run. The second state colour next to `verdictWarn`; never used for identity.
    static let hubFailed = Color(red: 1.0, green: 0.35, blue: 0.33)

    static let nsBackground = NSColor.black
    static let nsText = NSColor(white: 0.88, alpha: 1)

    /// The soft aura around terminal text. A fresh instance per call: NSShadow is mutable and
    /// each view keeps the one it's handed.
    static var textGlow: NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor(white: 1, alpha: 0.45)
        s.shadowBlurRadius = 4
        s.shadowOffset = .zero
        return s
    }

    /// Drains all colour from what a terminal draws when colour is off (see `TrueTerminalView.applyColorMode`).
    static var monochrome: [CIFilter] {
        guard let f = CIFilter(name: "CIColorControls") else { return [] }
        f.setValue(0, forKey: kCIInputSaturationKey)
        return [f]
    }

    /// Breathing room between a pane's edge and its first/last character.
    static let paneInsets = EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 10)
}

// MARK: - Design tokens (P1, additive)
// Source of truth: docs/designs/true-design-pass/group-canvas/tokens.md. Nothing above reads these yet;
// views adopt them in P2/P3. Light = S0 light-glass + one orange accent; dark = True black/white
// (colour is identity only, states are words and brightness). Resolved per colorScheme, never two code paths.

extension Theme {
    /// Type scale in points (tokens.md --t-*). One family; weight carries hierarchy.
    enum TypeScale {
        static let label: CGFloat = 11
        static let small: CGFloat = 12.5
        static let body: CGFloat = 14
        static let h3: CGFloat = 16
        static let h2: CGFloat = 19
        static let h1: CGFloat = 25
        static let all: [CGFloat] = [label, small, body, h3, h2, h1]
    }

    /// 4-pt spacing (tokens.md --s1...--s7).
    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 24
        static let s6: CGFloat = 32
        static let s7: CGFloat = 48
        static let all: [CGFloat] = [s1, s2, s3, s4, s5, s6, s7]
    }

    /// Three radii (tokens.md --r-sm, --r, --r-lg).
    enum Radius {
        static let sm: CGFloat = 9
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
    }

    /// Minimum click targets (the user 2026-11-02: "like aim training"). HIG macOS: rows ≥ 28pt; we go roomier.
    enum Hit {
        static let row: CGFloat = 44
        static let control: CGFloat = 32
    }

    /// Opacity ladder applied to the ink colour (`Palette.ink`), replacing scattered `white.opacity(x)`.
    enum Alpha {
        static let hover = 0.05
        static let press = 0.08
        static let hairline = 0.10
        static let strongLine = 0.20
        static let disabled = 0.38
        static let skeletonLow = 0.06
        static let skeletonHigh = 0.12
        /// Static skeleton fill when Reduce Motion turns the shimmer off.
        static let skeletonStatic = 0.09
        /// Dim behind a floating card (command bar, palette).
        static let scrim = 0.28
        /// Drop shadow under a floating card.
        static let shadow = 0.45
        /// Pill fill for a warning word (tinted by `Token.warn`).
        static let tint = 0.16
    }

    /// One system font per scale step; weight carries hierarchy. Views use these, never `.font(.system(size:))`.
    enum Fonts {
        static let label = Font.system(size: TypeScale.label)
        static let small = Font.system(size: TypeScale.small)
        static let body = Font.system(size: TypeScale.body)
        static let bodyMedium = Font.system(size: TypeScale.body, weight: .medium)
        static let h3 = Font.system(size: TypeScale.h3)
        static let h2 = Font.system(size: TypeScale.h2)
        static let labelStrong = Font.system(size: TypeScale.label, weight: .semibold)
        static let smallStrong = Font.system(size: TypeScale.small, weight: .medium)
    }

    /// A resolved set of colours for one appearance. Hex values are sRGB 0xRRGGBB.
    struct Palette: Sendable {
        let bg0, bg1, bg2, bg3: UInt32
        let text0, text1, text2, text3: UInt32
        let ink: UInt32
        let accent, accentInk, onAccent: UInt32
        let ok, warn, danger: UInt32

        static let light = Palette(
            bg0: 0xFAF8F4, bg1: 0xFFFDF9, bg2: 0xFFFFFF, bg3: 0xF2EEE6,
            text0: 0x1D1A16, text1: 0x4A4538, text2: 0x5E5748, text3: 0x6F6859,
            ink: 0x1D1A16,
            accent: 0xE8590C, accentInk: 0xB8460A, onAccent: 0xFFFDF9,
            ok: 0x2F6B47, warn: 0x8A5F0D, danger: 0xB03226)

        static let dark = Palette(
            bg0: 0x000000, bg1: 0x070707, bg2: 0x0D0D0D, bg3: 0x181818,
            text0: 0xF5F5F5, text1: 0xE0E0E0, text2: 0xA8A8A8, text3: 0x8C8C8C,
            ink: 0xFFFFFF,
            accent: 0xFFFFFF, accentInk: 0xFFFFFF, onAccent: 0x000000,
            ok: 0xE0E0E0, warn: 0xF5F5F5, danger: 0xF5F5F5)

        static func `for`(_ scheme: ColorScheme) -> Palette { scheme == .dark ? dark : light }

        var backgrounds: [UInt32] { [bg0, bg1, bg2, bg3] }
        /// Every token that is drawn as text, with its name (for the contrast test).
        var textTokens: [(name: String, hex: UInt32)] {
            [("text0", text0), ("text1", text1), ("text2", text2), ("text3", text3),
             ("accentInk", accentInk), ("ok", ok), ("warn", warn), ("danger", danger)]
        }
    }

    /// Appearance-resolved colours: one `Color` that follows the system (or the view's) appearance.
    enum Token {
        private static func dynamic(_ name: String, _ pick: @escaping @Sendable (Palette) -> UInt32) -> Color {
            Color(nsColor: NSColor(name: NSColor.Name("true.\(name)")) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: pick(isDark ? .dark : .light))
            })
        }
        static let bg0 = dynamic("bg0") { $0.bg0 }
        static let bg1 = dynamic("bg1") { $0.bg1 }
        static let bg2 = dynamic("bg2") { $0.bg2 }
        static let bg3 = dynamic("bg3") { $0.bg3 }
        static let text0 = dynamic("text0") { $0.text0 }
        static let text1 = dynamic("text1") { $0.text1 }
        static let text2 = dynamic("text2") { $0.text2 }
        static let text3 = dynamic("text3") { $0.text3 }
        static let ink = dynamic("ink") { $0.ink }
        static let accent = dynamic("accent") { $0.accent }
        static let accentInk = dynamic("accentInk") { $0.accentInk }
        static let onAccent = dynamic("onAccent") { $0.onAccent }
        static let ok = dynamic("ok") { $0.ok }
        static let warn = dynamic("warn") { $0.warn }
        static let danger = dynamic("danger") { $0.danger }

        static let hoverFill = ink.opacity(Alpha.hover)
        static let pressFill = ink.opacity(Alpha.press)
        static let line = ink.opacity(Alpha.hairline)
        static let strongLine = ink.opacity(Alpha.strongLine)
    }
}

extension NSColor {
    /// sRGB colour from 0xRRGGBB.
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// WCAG 2.x contrast maths, used by the contrast test and any runtime fallback (glass -> solid when < 4.5).
enum Contrast {
    static func luminance(_ hex: UInt32) -> Double {
        func lin(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((hex >> 16) & 0xFF) + 0.7152 * lin((hex >> 8) & 0xFF) + 0.0722 * lin(hex & 0xFF)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

// MARK: - Floating-card surface (P2)

private struct FloatingSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Glass lets whatever is behind bleed through, so contrast over it cannot be guaranteed:
        // Reduce Transparency or Increase Contrast switch to a solid fill with a visible edge.
        if reduceTransparency || contrast == .increased {
            content
                .background(Theme.Token.bg2, in: shape)
                .overlay(shape.strokeBorder(Theme.Token.strongLine, lineWidth: 1))
                .shadow(color: .black.opacity(Theme.Alpha.shadow), radius: Theme.Space.s5 + Theme.Space.s2, y: Theme.Space.s3)
        } else {
            content
                .glassSurface(shape)
                .shadow(color: .black.opacity(Theme.Alpha.shadow), radius: Theme.Space.s5 + Theme.Space.s2, y: Theme.Space.s3)
        }
    }
}

extension View {
    /// The shared look of the command bar and project palette: glass, or solid when transparency is off.
    func floatingCardSurface(radius: CGFloat = Theme.Radius.lg) -> some View {
        modifier(FloatingSurface(radius: radius))
    }
}

// MARK: - P3 tokens (additive): veil ladder, icon fonts, tokenised hues, hit targets

extension Theme {
    /// White ink on surfaces that are ALWAYS dark (glass pop-ups, hub, capture/shots overlays). Replaces every
    /// scattered `white.opacity(x)`; near values were snapped to the nearest rung (listed in p3-result.md).
    enum Veil {
        static let wash = Color.white.opacity(0.04)
        static let fill = Color.white.opacity(0.06)
        static let fillHover = Color.white.opacity(0.10)
        static let fillOn = Color.white.opacity(0.14)
        static let edgeSoft = Color.white.opacity(0.08)
        static let edge = Color.white.opacity(0.14)
        static let edgeStrong = Color.white.opacity(0.22)
        static let edgeOn = Color.white.opacity(0.40)
        static let sheen = Color.white.opacity(0.30)
        static let edgeBright = Color.white.opacity(0.55)
        static let textDim = Color.white.opacity(0.55)
        static let textSoft = Color.white.opacity(0.72)
        static let textStrong = Color.white.opacity(0.92)
        static let ink = Color.white
    }

    /// Hub board ink: white ladder on dark appearance, black ladder on light (moved here from HubInk).
    enum HubLadder {
        static let darkPrimary = Color.white.opacity(0.92), lightPrimary = Color.black.opacity(0.88)
        static let darkSecondary = Color.white.opacity(0.62), lightSecondary = Color.black.opacity(0.58)
        static let darkFaint = Color.white.opacity(0.40), lightFaint = Color.black.opacity(0.40)
        static let darkTile = Color.white.opacity(0.055), lightTile = Color.black.opacity(0.045)
        static let darkTileStroke = Color.white.opacity(0.09), lightTileStroke = Color.black.opacity(0.09)
        static let darkChip = Color.white.opacity(0.09), lightChip = Color.black.opacity(0.07)
    }

    /// Glyph (SF Symbol / icon) sizes. Text uses `Fonts`; icons use these.
    enum IconSize: CGFloat {
        case xs = 10, sm = 12, md = 14, lg = 17, xl = 20, hero = 34, display = 56
    }

    /// Hue exceptions the user chose to tokenise (2026-11-02). Same colours as before; the light-mode value of
    /// green/red is darkened where the system colour fails 4.5:1 on the light surface (DesignTokensTests).
    enum Hue {
        /// SitePill "exposed" dot. Dark = system green, light darkened.
        static let siteLiveDark: UInt32 = 0x32D74B, siteLiveLight: UInt32 = 0x1F7A3A
        /// Peer failures (nack text, failed reason). Dark = system red, light darkened.
        static let peerFailDark: UInt32 = 0xFF453A, peerFailLight: UInt32 = 0xB03226
        /// A notice that something was changed on the way out (a hidden secret). Dark = system orange, light darkened.
        static let noticeDark: UInt32 = 0xFF9F0A, noticeLight: UInt32 = 0x8A4500
        static let notice = dynamic("notice", dark: noticeDark, light: noticeLight)
        static let siteLive = dynamic("siteLive", dark: siteLiveDark, light: siteLiveLight)
        static let peerFail = dynamic("peerFail", dark: peerFailDark, light: peerFailLight)

        private static func dynamic(_ name: String, dark: UInt32, light: UInt32) -> Color {
            Color(nsColor: NSColor(name: NSColor.Name("true.hue.\(name)")) { appearance in
                NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            })
        }
    }

    /// Markup (annotation) pen colours. Painted onto screenshots of arbitrary content, not onto UI surfaces,
    /// so they stay the bright originals (no 4.5:1 text rule applies; they are strokes).
    enum MarkupInk {
        static let red = RGBA(r: 1.0, g: 0.27, b: 0.23)
        static let amber = RGBA(r: 1.0, g: 0.62, b: 0.24)
        static let blue = RGBA(r: 0.04, g: 0.52, b: 1.0)
        static let green = RGBA(r: 0.19, g: 0.82, b: 0.40)
        static let white = RGBA(r: 1, g: 1, b: 1)
        static let ink = RGBA(r: 0.07, g: 0.07, b: 0.08)
        static let highlighterYellow = RGBA(r: 1.0, g: 0.86, b: 0.10)
    }
}

extension Theme.Fonts {
    /// Icon glyph at a token size.
    static func icon(_ size: Theme.IconSize, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size.rawValue, weight: weight)
    }
    /// Big monospaced pairing/room code.
    static let code = Font.system(size: 30, weight: .semibold, design: .monospaced)
    static let codeLarge = Font.system(size: 34, weight: .semibold, design: .monospaced)
    /// Data-driven size (avatar glyph scales with the avatar; annotation text scales with the canvas).
    static func scaled(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static let labelMono = Font.system(size: Theme.TypeScale.label, design: .monospaced)
}

// MARK: - Diff colours (the user 2026-11-09: True black everywhere; colour ONLY on diff numbers and lines)

extension Theme {
    struct DiffPalette: Sendable {
        let add, remove: UInt32
        static let dark = DiffPalette(add: 0x00D492, remove: 0xFF6467)
        static let light = DiffPalette(add: 0x007A55, remove: 0xC10007)
    }

    enum Diff {
        private static func dynamic(_ name: String, _ pick: @escaping @Sendable (DiffPalette) -> UInt32) -> Color {
            Color(nsColor: NSColor(name: NSColor.Name("true.diff.\(name)")) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: pick(isDark ? .dark : .light))
            })
        }
        static let add = dynamic("add") { $0.add }
        static let remove = dynamic("remove") { $0.remove }
    }
}
