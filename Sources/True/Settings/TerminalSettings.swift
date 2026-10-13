import AppKit
import SwiftTerm

/// UserDefaults keys + value clamping for the few settings True has. `@AppStorage` in views and
/// plain reads in the terminal bridge share these so a key is spelled exactly once.
enum TerminalSettings {
    static let fontFamilyKey = "terminal.fontFamily"
    static let fontSizeKey = "terminal.fontSize"
    static let cursorKey = "terminal.cursor"
    static let scrollbackKey = "terminal.scrollback"
    static let colorKey = "terminal.color"

    static let overseerKey = "overseer.enabled"
    static let watcherKey = "watcher.enabled"
    /// The Overseer (Jev reads each finished turn). On by default; off = no Jev calls at all.
    static var overseer: Bool { UserDefaults.standard.object(forKey: overseerKey) as? Bool ?? true }

    static let jevRoutingKey = "commandbar.jevRouting"
    /// The Command bar's Jev read. On by default; off = prefix rules + pane-aware defaults, no network.
    static var jevRouting: Bool { UserDefaults.standard.object(forKey: jevRoutingKey) as? Bool ?? true }

    static let systemMono = "System Mono"
    /// Programs' own colours on by default: Claude Code's orange spinner is how you see it working.
    /// Off = the Run 8 black-and-white look (grey ANSI ladder + desaturation filter).
    static let defaultColor = true
    static var color: Bool { UserDefaults.standard.object(forKey: colorKey) as? Bool ?? defaultColor }
    static let defaultFontSize = 13.0
    static let defaultScrollback = 10_000

    static func clampSize(_ v: Double) -> Double { min(32, max(9, v.isFinite ? v : defaultFontSize)) }
    static func clampScrollback(_ v: Int) -> Int { min(100_000, max(500, v)) }

    /// Fixed-pitch families installed on this Mac, for the picker.
    static var fixedPitchFamilies: [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let fams = names.compactMap { NSFont(name: $0, size: 12)?.familyName }
        return Array(Set(fams)).sorted()
    }

    static func font(family: String, size: Double) -> NSFont {
        let s = CGFloat(clampSize(size))
        if family == systemMono { return NSFont.monospacedSystemFont(ofSize: s, weight: .regular) }
        return NSFont(name: family, size: s)
            ?? NSFontManager.shared.font(withFamily: family, traits: .fixedPitchFontMask, weight: 5, size: s)
            ?? NSFont.monospacedSystemFont(ofSize: s, weight: .regular)
    }

    /// Cursor choices. Default is a STEADY block: a blinking cursor is a permanent wake-up timer.
    enum Cursor: String, CaseIterable, Identifiable {
        case steadyBlock, blinkBlock, steadyBar, blinkBar, steadyUnderline, blinkUnderline
        var id: String { rawValue }
        var label: String {
            switch self {
            case .steadyBlock: "Block"
            case .blinkBlock: "Block (blinking)"
            case .steadyBar: "Bar"
            case .blinkBar: "Bar (blinking)"
            case .steadyUnderline: "Underline"
            case .blinkUnderline: "Underline (blinking)"
            }
        }
        var style: CursorStyle {
            switch self {
            case .steadyBlock: .steadyBlock
            case .blinkBlock: .blinkBlock
            case .steadyBar: .steadyBar
            case .blinkBar: .blinkBar
            case .steadyUnderline: .steadyUnderline
            case .blinkUnderline: .blinkUnderline
            }
        }
    }
}
