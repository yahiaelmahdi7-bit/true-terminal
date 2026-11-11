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

    static let inlineSuggestionsKey = "terminal.inlineSuggestions"
    /// Fish-style ghost text in zsh panes (vendored zsh-autosuggestions). Read by the shim at pane start, so it applies to new panes.
    static var inlineSuggestions: Bool { UserDefaults.standard.object(forKey: inlineSuggestionsKey) as? Bool ?? true }

    static let claudeAutostartKey = "terminal.claudeAutostart"
    /// Whether new tabs and a fresh launch boot Claude with skip-permissions. The public build's Info.plist sets
    /// `TrueClaudeAutostartDefault=false`: strangers must not get skip-permissions unasked. Missing key = on.
    static func claudeAutostartDefault(info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        info?["TrueClaudeAutostartDefault"] as? Bool ?? true
    }
    static var claudeAutostart: Bool {
        UserDefaults.standard.object(forKey: claudeAutostartKey) as? Bool ?? claudeAutostartDefault()
    }

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

/// Run 42 push-to-talk dictation settings. Default OFF; nothing here runs at launch.
enum DictationSettings {
    static let enabledKey = "dictation.enabled"
    static let keyKey = "dictation.key"
    static let modelKey = "dictation.modelPath"
    static let languageKey = "dictation.language"
    static let vocabularyKey = "dictation.vocabulary"

    static let defaultVocabulary = "Claude, Codex, Swift, SwiftUI, Xcode, GitHub, npm"
    static var defaultModelPath: String { NSHomeDirectory() + "/.cache/whisper/ggml-large-v3-turbo-q5_0.bin" }
    static let binaryKey = "dictation.binaryPath"
    /// The resolved engine; the Homebrew path when none is installed (callers check it is executable).
    static var binaryPath: String {
        DictationEngine.resolve(userPath: UserDefaults.standard.string(forKey: binaryKey) ?? "") ?? DictationEngine.candidates[0]
    }

    enum Key: String, CaseIterable, Identifiable {
        case rightOption, rightCommand, f5
        var id: String { rawValue }
        var label: String {
            switch self { case .rightOption: "Right Option"; case .rightCommand: "Right Command"; case .f5: "F5" }
        }
        var keyCode: UInt16 {
            switch self { case .rightOption: 61; case .rightCommand: 54; case .f5: 96 }
        }
        /// Modifier keys arrive as flagsChanged; F5 as keyDown/keyUp.
        var isModifier: Bool { self != .f5 }
        var flag: NSEvent.ModifierFlags? {
            switch self { case .rightOption: .option; case .rightCommand: .command; case .f5: nil }
        }
    }

    static func enabled(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: enabledKey) as? Bool ?? false }
    static func key(_ d: UserDefaults = .standard) -> Key { Key(rawValue: d.string(forKey: keyKey) ?? "") ?? .rightOption }
    static func language(_ d: UserDefaults = .standard) -> String { d.string(forKey: languageKey) ?? "auto" }
    static func modelPath(_ d: UserDefaults = .standard) -> String {
        let p = d.string(forKey: modelKey) ?? ""
        if let r = DictationModels.resolve(userPath: p) { return r }
        return p.isEmpty ? defaultModelPath : (p as NSString).expandingTildeInPath
    }
    static func vocabulary(_ d: UserDefaults = .standard) -> String { d.string(forKey: vocabularyKey) ?? defaultVocabulary }

    /// Exists and is non-empty.
    static func modelValid(_ path: String) -> Bool {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return ((a?[.size] as? NSNumber)?.intValue ?? 0) > 0
    }
}
