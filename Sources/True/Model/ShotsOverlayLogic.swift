import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The one place the summon shortcut is defined. Change `letter` / `modifiers` and the Carbon registration,
/// the menu item and its displayed shortcut all follow.
enum ShotsHotKey {
    static let letter: Character = "s"
    static let control = true, option = true, command = true, shift = false

    /// ANSI virtual key codes for the letters (Carbon `kVK_ANSI_*`; they are not alphabetical).
    private static let letterCodes: [Character: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46,
    ]

    static var carbonKeyCode: UInt32 { letterCodes[Character(letter.lowercased())] ?? 1 }
    static var carbonModifiers: UInt32 {
        (control ? UInt32(controlKey) : 0) | (option ? UInt32(optionKey) : 0)
            | (command ? UInt32(cmdKey) : 0) | (shift ? UInt32(shiftKey) : 0)
    }
    static var keyEquivalent: KeyEquivalent { KeyEquivalent(letter) }
    static var eventModifiers: SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if control { m.insert(.control) }
        if option { m.insert(.option) }
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        return m
    }
}

/// Pure decisions behind the full-screen Shots overlay — everything here is testable without a window.
enum ShotsOverlayLogic {
    // MARK: Day grouping

    struct DayGroup: Equatable {
        let title: String
        let entries: [TrayEntry]
    }

    /// "Today / Yesterday / Earlier", in `calendar`'s time zone, keeping the incoming (newest-first) order.
    /// Empty groups are dropped.
    static func group(_ entries: [TrayEntry], now: Date, calendar: Calendar) -> [DayGroup] {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        var today: [TrayEntry] = [], yest: [TrayEntry] = [], earlier: [TrayEntry] = []
        for e in entries {
            if calendar.isDate(e.created, inSameDayAs: now) { today.append(e) }
            else if let yesterday, calendar.isDate(e.created, inSameDayAs: yesterday) { yest.append(e) }
            else { earlier.append(e) }
        }
        return [DayGroup(title: "Today", entries: today), DayGroup(title: "Yesterday", entries: yest),
                DayGroup(title: "Earlier", entries: earlier)].filter { !$0.entries.isEmpty }
    }

    // MARK: Pinch → columns

    static let minColumns = 3, maxColumns = 9, defaultColumns = 5
    static let columnsKey = "shotsOverlay.columns"

    static func clampColumns(_ n: Int) -> Int { min(maxColumns, max(minColumns, n)) }

    /// Pinching out (scale > 1) makes thumbnails bigger, so fewer columns; pinching in, more.
    static func columns(base: Int, pinchScale: CGFloat) -> Int {
        guard pinchScale.isFinite, pinchScale > 0 else { return clampColumns(base) }
        return clampColumns(Int((CGFloat(base) / pinchScale).rounded()))
    }

    // MARK: Screen & insets

    /// The screen the mouse is on (AppKit global coordinates); `fallback` when it is on none (or none exist).
    static func screenIndex(mouse: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(mouse) }
    }

    /// Breathing room around the content: the menu bar / notch / Dock (frame minus visibleFrame, and the
    /// notch's safe-area top) plus `margin` on every side, so nothing touches an edge.
    static func contentInsets(frame: CGRect, visible: CGRect, safeTop: CGFloat, margin: CGFloat)
        -> (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        let top = max(frame.maxY - visible.maxY, safeTop)
        return (top + margin, max(0, visible.minX - frame.minX) + margin,
                max(0, visible.minY - frame.minY) + margin, max(0, frame.maxX - visible.maxX) + margin)
    }

    // MARK: Drag-in

    /// Image files only (by type, not by guessing from the name's look); folders and everything else are rejected.
    static func acceptsDrop(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return false }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: Viewer navigation

    /// Stop at the ends (no wrap): nil means "already at the edge".
    static func neighbor(of index: Int, count: Int, step: Int) -> Int? {
        let next = index + step
        return (0..<count).contains(next) ? next : nil
    }

    // MARK: Viewer layout & zoom

    /// Height reserved at the bottom of the viewer for the floating toolbar (capsule + gap), above the bottom inset.
    static let toolbarBand: CGFloat = 92
    /// Width reserved on each side for the ‹ › chevrons and the Close button.
    static let sideReserve: CGFloat = 76

    /// The box the viewer image may occupy: the container minus the content insets, the side reserve and the
    /// toolbar band. The toolbar lives in the band, so the image can never be under it.
    static func viewerArea(container: CGSize,
                           insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat),
                           sideReserve: CGFloat = sideReserve, toolbarBand: CGFloat = toolbarBand) -> CGRect {
        let x = insets.leading + sideReserve, y = insets.top
        let w = max(1, container.width - x - insets.trailing - sideReserve)
        let h = max(1, container.height - y - insets.bottom - toolbarBand)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Markup keeps the viewer's bottom band for its tool bar (same slot as the viewer toolbar) but only needs
    /// room for the Close button at the sides.
    static let markupSideReserve: CGFloat = 40

    static func markupArea(container: CGSize,
                           insets: (top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat)) -> CGRect {
        viewerArea(container: container, insets: insets, sideReserve: markupSideReserve, toolbarBand: toolbarBand)
    }

    /// Centre of the floating bottom bar (viewer toolbar and markup bar share the slot).
    static func bottomBarCenterY(containerHeight: CGFloat, bottomInset: CGFloat) -> CGFloat {
        containerHeight - bottomInset - 32
    }

    /// Aspect-fit `aspect` (width / height) inside `area`, centred; never upscaled past `maxScale`× `natural`
    /// (so a 16 pt icon is not blown up to a blurry slab). Falls back to 1.6 for a bad aspect.
    static func fittedRect(in area: CGRect, aspect: CGFloat, natural: CGSize? = nil, maxScale: CGFloat = 2) -> CGRect {
        let a = (aspect.isFinite && aspect > 0) ? aspect : 1.6
        var w = area.width, h = w / a
        if h > area.height { h = area.height; w = h * a }
        if let n = natural, n.width > 0, n.height > 0 {
            w = min(w, n.width * maxScale); h = min(h, n.height * maxScale)
            if w / h > a { w = h * a } else { h = w / a }
        }
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// Linear blend of two rects; t = 0 is `from`, t = 1 is `to`. Drives the zoom open/close.
    static func interpolate(from: CGRect, to: CGRect, t: CGFloat) -> CGRect {
        func l(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return CGRect(x: l(from.minX, to.minX), y: l(from.minY, to.minY),
                      width: l(from.width, to.width), height: l(from.height, to.height))
    }

    /// Where the viewer image zooms from/to: the tile's rect when at least part of it is on screen, otherwise nil
    /// (the caller shrinks + fades toward the centre instead).
    static func zoomSource(tile: CGRect?, overlay: CGSize) -> CGRect? {
        guard let tile, tile.width > 1, tile.height > 1 else { return nil }
        let visible = tile.intersection(CGRect(origin: .zero, size: overlay))
        guard !visible.isNull, visible.width * visible.height >= tile.width * tile.height * 0.5 else { return nil }
        return tile
    }

    /// Off-screen fallback: a small rect at the centre of `target`.
    static func centreShrink(of target: CGRect, scale: CGFloat = 0.6) -> CGRect {
        CGRect(x: target.midX - target.width * scale / 2, y: target.midY - target.height * scale / 2,
               width: target.width * scale, height: target.height * scale)
    }
}
