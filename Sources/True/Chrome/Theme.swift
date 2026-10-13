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
