import AppKit
import QuartzCore

/// One heartbeat for every terminal pane's redraws.
///
/// **The lag.** With agent seats live on the desk, a `sample` of the app showed roughly half of all
/// main-thread work inside `TerminalView.draw(_:)` → `buildAttributedString` → `getAttributes` —
/// CoreGraphics text drawing, rebuilt per row per repaint — while WindowServer sat at ~45% CPU.
/// The cause is not that drawing a terminal is expensive; it is HOW OFTEN and HOW UNSYNCHRONIZED
/// it happens. A `claude` TUI paints a thinking spinner ~10×/s, and every chunk of PTY
/// output calls `setNeedsDisplay(region)` immediately. Five live seats meant ~50 invalidations a
/// second landing on five different layers at five different moments, so WindowServer composited
/// the whole canvas ~50×/s to show five spinning characters.
///
/// **The fix.** Invalidations are collected and released together on one shared ~30 Hz tick. Two
/// wins, and the second is the larger one: no single pane can repaint faster than the display can
/// show it, and — because every pane flushes inside the SAME turn of the run loop — AppKit
/// coalesces them into ONE compositing transaction per frame instead of N.
///
/// The dirty rectangles are unioned rather than dropped, so a coalesced frame repaints exactly the
/// region the individual invalidations would have, and nothing renders stale.
///
/// **Why a display link and not a timer.** The batching above is the good idea; the 30 Hz `Timer`
/// that used to drive it was not, and "≤33 ms is below the threshold where a terminal feels
/// instant" was simply wrong. Keystroke-to-glyph is THE feel metric for a terminal — Warp and
/// Ghostty sit around 5–10 ms — and a free-running timer added up to 33 ms before a keystroke
/// could paint at all. Worse, its phase had nothing to do with the display's: a flush released
/// just after a frame boundary missed that frame and waited for the next compositing pass, and
/// its run-loop jitter meant frames arrived unevenly, which reads as stutter even when the
/// average rate is fine.
///
/// A `CADisplayLink` fixes both without giving anything up. Flushes land in phase with the
/// compositor, so every pending paint makes the very next frame — ~8 ms on this 120 Hz display
/// instead of up to 33 — and because all panes still flush inside one run-loop turn, AppKit
/// coalesces them into a single transaction exactly as before. The draw COUNT barely moves: the
/// tick only releases paints that were already requested, so a spinner invalidating 10×/s still
/// costs 10 draws/s. Only a burst faster than the display rate merges, which is precisely the
/// case worth merging.
///
/// **Isolation.** Deliberately NOT `@MainActor`. Its one caller is `NSView.setNeedsDisplay(_:)` —
/// a nonisolated AppKit override that cannot hop actors without either `assumeIsolated` (which
/// crashes this app's runtime on macOS 26, hence the package's `-disable-dynamic-actor-isolation`
/// and the standing rule against it) or a per-invalidation `Task`, which would allocate on the
/// hottest path in the app. Instead this follows the same `nonisolated(unsafe)` + main-thread
/// contract Axon used for a cached key: every entry point asserts
/// the main thread, and AppKit already guarantees it for view invalidation.
final class TerminalRedrawCoalescer: @unchecked Sendable {
    static let shared = TerminalRedrawCoalescer()

    /// The fallback cadence, used only if no screen can vend a display link. Deliberately faster
    /// than the 30 Hz this class used to run at: if we ever land here, latency still matters.
    private static let fallbackInterval: TimeInterval = 1.0 / 60.0

    /// Registered panes with pending paint. Weak: a torn-down pane must not be kept alive by the
    /// timer, and must not be flushed after SwiftUI dismantles it.
    private final class Pending {
        weak var view: TrueTerminalView?
        var rect: NSRect
        init(_ view: TrueTerminalView, _ rect: NSRect) {
            self.view = view
            self.rect = rect
        }
    }

    private var pending: [ObjectIdentifier: Pending] = [:]
    /// Display-synced driver. Preferred; `timer` is the fallback when no screen vends one.
    private var link: CADisplayLink?
    private var timer: Timer?

    private init() {}

    /// The display link's callback needs an `@objc` selector target, and this class is
    /// `@unchecked Sendable` rather than an `NSObject`. A tiny proxy keeps it that way.
    private final class LinkTarget: NSObject {
        @objc func step(_ link: CADisplayLink) { TerminalRedrawCoalescer.shared.tick() }
    }
    private let linkTarget = LinkTarget()

    /// Note that `view` wants `rect` repainted. Returns immediately; the paint lands on the next
    /// tick. Unioning is what makes this lossless — two invalidations for different rows become
    /// one repaint covering both.
    ///
    /// Main thread only, which AppKit already requires of the caller.
    func invalidate(_ view: TrueTerminalView, rect: NSRect) {
        assert(Thread.isMainThread, "TerminalRedrawCoalescer is main-thread only")
        let key = ObjectIdentifier(view)
        if let existing = pending[key] {
            existing.rect = existing.rect.union(rect)
        } else {
            pending[key] = Pending(view, rect)
        }
        startIfNeeded()
    }

    /// Drop a torn-down pane's pending paint without drawing it.
    func forget(_ view: TrueTerminalView) {
        assert(Thread.isMainThread, "TerminalRedrawCoalescer is main-thread only")
        pending.removeValue(forKey: ObjectIdentifier(view))
    }

    /// The driver runs ONLY while something is waiting to paint. An idle desk costs nothing — a
    /// permanently-armed display link would be its own small version of the bug this file fixes,
    /// and an always-on link also blocks the display from dropping to a low refresh rate.
    private func startIfNeeded() {
        guard link == nil, timer == nil else { return }
        // The screen the panes are actually on, so the cadence matches the display they're
        // composited to (an external 60 Hz monitor and this 120 Hz laptop panel differ).
        let screen = pending.values.compactMap { $0.view?.window?.screen }.first ?? .main
        if let screen {
            let l = screen.displayLink(target: linkTarget, selector: #selector(LinkTarget.step(_:)))
            // Full display rate is what we want, but stated as a RANGE so the system may throttle
            // under thermal pressure or on battery instead of us pinning it.
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            // `.common` so redraws keep flowing while a menu is open or the canvas is being
            // dragged — on `.default` the panes would freeze for the duration of the gesture.
            l.add(to: .main, forMode: .common)
            link = l
            return
        }
        let t = Timer(timeInterval: Self.fallbackInterval, repeats: true) { _ in
            TerminalRedrawCoalescer.shared.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Tear the driver down once there's nothing left to paint.
    private func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    /// Frames deliberately skipped while a pane is flooding. See `tick`.
    private var floodSkip = 0

    private func tick() {
        assert(Thread.isMainThread, "TerminalRedrawCoalescer is main-thread only")
        guard !pending.isEmpty else {
            floodSkip = 0
            stop()
            return
        }
        // Under a flood, GIVE THE MAIN THREAD BACK. SwiftTerm reads the PTY with no backpressure
        // and queues chunks in an unbounded array drained on the main queue under a fixed time
        // slice — so main-thread time spent drawing is time that queue does not get, and the queue
        // diverges. Measured: at full display rate a flooding pane pushed the process to 46 GB in
        // 30 s, against 20 GB when drawing at 30 Hz. Text arriving faster than 2 MB/s is a blur
        // nobody can read, so dropping to ~12 Hz costs a viewer nothing and buys back 90% of the
        // frames. Latency is unaffected in every normal case, which is what the display link is
        // for. This is mitigation, not a bound — the real bound has to be on that queue.
        if TrueTerminalView.isFlooding {
            floodSkip += 1
            if floodSkip % 10 != 0 { return }
        } else {
            floodSkip = 0
        }
        // Pick this frame's paints, and take them out of `pending` BEFORE flushing: a flush can
        // invalidate again (a caret repaint), and that belongs to the NEXT frame, not this one —
        // otherwise a self-feeding pane could spin inside a single tick. Panes not due yet keep
        // their unioned rect and wait; nothing is dropped.
        let now = CACurrentMediaTime()
        let focusedPainting = pending.values.contains { $0.view?.isFocusedPane == true }
        var due: [(TrueTerminalView, NSRect)] = []
        for (key, entry) in pending {
            guard let view = entry.view, view.window != nil, view.isOnScreen else {
                pending.removeValue(forKey: key)
                continue
            }
            if FramePacing.shouldFlush(isFocused: view.isFocusedPane, now: now,
                                       lastFlush: view.lastCoalescedFlush,
                                       focusedPaintingThisFrame: focusedPainting) {
                due.append((view, entry.rect))
                pending.removeValue(forKey: key)
            }
        }
        for (view, rect) in due { view.flushCoalescedDisplay(rect) }
    }
}

/// Who paints on a given display-link frame. Pure, so the policy is tested without a display.
///
/// The pane being typed into is the only one whose latency anyone feels, so it paints on every
/// frame. Every other visible pane — a claude seat spinning beside you — is capped at 30 Hz, which
/// is smooth for a spinner or scrolling log and a quarter of the draws at 120 Hz. And when the
/// focused pane IS painting, a recently-painted background pane waits (up to `maxDeferral`), so a
/// keystroke's frame carries the keystroke and not four other panes' text layout. The deferral is
/// bounded so a focused pane that streams nonstop can slow its neighbours but never freeze them.
enum FramePacing {
    static let backgroundInterval: CFTimeInterval = 1.0 / 30.0
    static let maxDeferral: CFTimeInterval = 0.1

    static func shouldFlush(isFocused: Bool, now: CFTimeInterval, lastFlush: CFTimeInterval,
                            focusedPaintingThisFrame: Bool) -> Bool {
        if isFocused { return true }
        let waited = now - lastFlush
        if waited < backgroundInterval { return false }
        if focusedPaintingThisFrame, waited < maxDeferral { return false }
        return true
    }
}
