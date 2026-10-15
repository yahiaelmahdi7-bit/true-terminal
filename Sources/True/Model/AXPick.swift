import AppKit
import ApplicationServices

/// The Accessibility source for smart selection. The capture overlay is True's own window, so nothing here
/// hit-tests system-wide: we find the topmost window under the point ourselves (CGWindowList), then ask THAT
/// app's AX tree what is at the point. Every call is slow-path; use `SmartPickWorker`, never the main thread.
enum AXPick {
    /// Trusted for Accessibility? Never shows the system prompt.
    static func trusted() -> Bool { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary) }

    private static let manualLock = NSLock()
    nonisolated(unsafe) private static var manualDone = Set<pid_t>()

    struct Result: Sendable { var chain: [PickElement]; var window: CGRect? }

    /// `point` is in the global top-left space (same as CGWindowList / AX). `excluding` = the overlay's own window numbers.
    static func query(at point: CGPoint, excluding: Set<Int>) -> Result {
        guard let (pid, frame) = topWindow(at: point, excluding: excluding) else { return Result(chain: [], window: nil) }
        guard trusted() else { return Result(chain: [], window: frame) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        enableManualAccessibility(app, pid: pid)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, let el = hit else {
            return Result(chain: [], window: frame)
        }
        AXUIElementSetMessagingTimeout(el, 0.1)
        var raw: [PickElement] = []
        var cur: AXUIElement? = el
        var depth = 0
        while let e = cur, depth < 40 {
            let role = string(e, kAXRoleAttribute), sub = string(e, kAXSubroleAttribute)
            if let f = elementFrame(e) { raw.append(PickElement(frame: f, kind: PickKind.from(role: role, subrole: sub))) }
            if role == "AXWindow" { break }
            cur = element(e, kAXParentAttribute)
            depth += 1
        }
        return Result(chain: SmartPickLogic.clean(raw, window: frame), window: frame)
    }

    /// Topmost normal window under `p`, front to back, skipping the overlay's own windows only.
    static func topWindow(at p: CGPoint, excluding: Set<Int>) -> (pid_t, CGRect)? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let num = w[kCGWindowNumber as String] as? Int, !excluding.contains(num),
                  let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width >= 40, r.height >= 40, r.contains(p) { return (pid, r) }
        }
        return nil
    }

    /// Electron / Chromium apps only build their tree when asked. `AXManualAccessibility` is the narrow switch;
    /// `AXEnhancedUserInterface` is deliberately never touched (side effects in other apps).
    private static func enableManualAccessibility(_ app: AXUIElement, pid: pid_t) {
        manualLock.lock(); defer { manualLock.unlock() }
        guard !manualDone.contains(pid) else { return }
        manualDone.insert(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
    private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private static func elementFrame(_ e: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}

/// Runs AX queries off the main thread, latest-wins: while one query is in flight only the newest request is
/// kept, and the caller drops any answer whose sequence number is no longer current.
final class SmartPickWorker: @unchecked Sendable {
    private struct Request { var seq: Int; var point: CGPoint; var excluding: Set<Int>; var deliver: @Sendable (Int, AXPick.Result) -> Void }
    private let queue = DispatchQueue(label: "true.smartpick", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: Request?
    private var running = false

    func request(seq: Int, point: CGPoint, excluding: Set<Int>, deliver: @escaping @Sendable (Int, AXPick.Result) -> Void) {
        lock.lock()
        pending = Request(seq: seq, point: point, excluding: excluding, deliver: deliver)
        let start = !running; running = true
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let r = pending else { running = false; lock.unlock(); return }
            pending = nil; lock.unlock()
            let result = AXPick.query(at: r.point, excluding: r.excluding)
            r.deliver(r.seq, result)
        }
    }
}
