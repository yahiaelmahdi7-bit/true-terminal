import Foundation
import CoreGraphics

/// What the user has × 'd out of the Hub (row ids → when), kept in UserDefaults. Only a click writes.
enum HubDismissals {
    static let key = "hub.dismissed"
    /// An id forgotten after this long (the row it hid is long gone by then).
    static let keepFor: Double = 30 * 86_400

    static func load(_ defaults: UserDefaults = .standard, now: Double = Date().timeIntervalSince1970) -> Set<String> {
        let raw = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return Set(raw.filter { now - $0.value < keepFor }.keys)
    }

    static func add(_ ids: [String], _ defaults: UserDefaults = .standard, now: Double = Date().timeIntervalSince1970) {
        var raw = (defaults.dictionary(forKey: key) as? [String: Double] ?? [:]).filter { now - $0.value < keepFor }
        for id in ids { raw[id] = now }
        defaults.set(raw, forKey: key)
    }
}

/// How big the Hub card opens and how it falls back on a narrow window. Pure.
enum HubLayout {
    static let minSize = CGSize(width: 1000, height: 680)
    static let screenShare: CGFloat = 0.75
    /// Below this width the two columns fold into one.
    static let twoColumnMin: CGFloat = 900
    /// Share of the card's width the left (inbox) column takes.
    static let leftShare: CGFloat = 0.6

    static func defaultSize(screen: CGSize) -> CGSize {
        CGSize(width: max(screen.width * screenShare, minSize.width), height: max(screen.height * screenShare, minSize.height))
    }

    /// The saved size (or the default) kept inside the window, with `margin` left around it. A window smaller than
    /// the minimum wins over the minimum: the card never spills out of it.
    static func size(saved: CGSize?, screen: CGSize, window: CGSize, margin: CGFloat) -> CGSize {
        let want = saved ?? defaultSize(screen: screen)
        let maxW = max(window.width - 2 * margin, 320), maxH = max(window.height - 2 * margin, 320)
        return CGSize(width: min(max(want.width, minSize.width), maxW), height: min(max(want.height, minSize.height), maxH))
    }

    static func isTwoColumn(width: CGFloat) -> Bool { width >= twoColumnMin }
}
