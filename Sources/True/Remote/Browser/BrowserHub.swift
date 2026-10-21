import Foundation
import TrueRemoteClient

/// What RemoteServer needs from the phone browser (a protocol so server tests run without Chrome).
protocol RemoteBrowser: Sendable {
    var enabled: Bool { get }
    func addViewer() -> BrowserViewer?
    func removeViewer(_ v: BrowserViewer)
    func handle(_ c: BrowserCommand)
    func tabsJSON() -> Data
}

struct NoBrowser: RemoteBrowser {
    var enabled: Bool { false }
    func addViewer() -> BrowserViewer? { nil }
    func removeViewer(_ v: BrowserViewer) {}
    func handle(_ c: BrowserCommand) {}
    func tabsJSON() -> Data { Data(#"{"enabled":false,"running":false,"tabs":[]}"#.utf8) }
}

/// One phone watching the browser: a latest-frame-wins frame slot plus a tiny queue of JSON text messages.
final class BrowserViewer: @unchecked Sendable {
    let frames = LatestFrame()
    private let lock = NSLock()
    private var texts: [String] = []
    var wake: DispatchSemaphore { frames.wake }
    var closed = false
    func push(text: String) { lock.lock(); texts.append(text); if texts.count > 50 { texts.removeFirst() }; lock.unlock(); frames.wake.signal() }
    func takeTexts() -> [String] { lock.lock(); defer { lock.unlock() }; let t = texts; texts = []; return t }
}

/// Owns True Chrome's DevTools connection and fans the active tab's screencast out to phone viewers.
/// Screencast runs only while at least one viewer is attached.
final class BrowserHub: RemoteBrowser, @unchecked Sendable {
    static let shared = BrowserHub()
    static let defaultsKey = "remote.phoneBrowser"

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }

    private let lock = NSLock()
    private let cmdQueue = DispatchQueue(label: "true.browser.cmd")
    private var conn: CDPConnection?
    private var viewers: [ObjectIdentifier: BrowserViewer] = [:]
    private var viewport = (w: 390, h: 844, scale: 2.0)
    private var activeTarget: String?
    private var sessionID: String?
    private var screencasting = false
    private var seq = 0
    private(set) var framesSent = 0

    // MARK: viewers

    func addViewer() -> BrowserViewer? {
        guard enabled else { return nil }
        let v = BrowserViewer()
        lock.lock(); viewers[ObjectIdentifier(v)] = v; lock.unlock()
        cmdQueue.async { [self] in
            guard ensureConnected() else { v.push(text: #"{"t":"error","message":"Could not start True Chrome"}"#); return }
            startScreencastIfNeeded()
            broadcastTabs()
        }
        return v
    }

    func removeViewer(_ v: BrowserViewer) {
        v.closed = true
        lock.lock(); viewers[ObjectIdentifier(v)] = nil; let none = viewers.isEmpty; lock.unlock()
        if none { cmdQueue.async { [self] in stopScreencast() } }
    }

    private func allViewers() -> [BrowserViewer] { lock.lock(); defer { lock.unlock() }; return Array(viewers.values) }

    // MARK: connection

    /// Call on cmdQueue only.
    func ensureConnected() -> Bool {
        if let c = conn, !c.closed, sessionID != nil { return true }
        conn?.close(); conn = nil; sessionID = nil; screencasting = false
        guard let ep = ChromeLauncher.ensureRunning(), let c = CDPConnection(url: ep.ws) else { return false }
        c.onEvent = { [weak self] m, p, s in self?.event(m, p, s) }
        c.onClose = { [weak self] in self?.cmdQueue.async { self?.conn = nil; self?.sessionID = nil; self?.screencasting = false } }
        c.start(); conn = c
        _ = c.call("Target.setDiscoverTargets", ["discover": true])
        var pages = pageTargets()
        if pages.isEmpty {
            if case .success(let r) = c.call("Target.createTarget", ["url": "about:blank"]), let id = r["targetId"] as? String { _ = id }
            pages = pageTargets()
        }
        guard let first = pages.first else { return false }
        return attach(first.id)
    }

    struct Tab { var id: String; var title: String; var url: String }

    func pageTargets() -> [Tab] {
        guard let c = conn, case .success(let r) = c.call("Target.getTargets"),
              let infos = r["targetInfos"] as? [[String: Any]] else { return [] }
        return infos.filter { ($0["type"] as? String) == "page" }.compactMap {
            guard let id = $0["targetId"] as? String else { return nil }
            return Tab(id: id, title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "")
        }
    }

    /// Switch the streamed session to `target`. cmdQueue only.
    @discardableResult
    func attach(_ target: String) -> Bool {
        guard let c = conn else { return false }
        stopScreencast()
        if let old = sessionID { c.send("Target.detachFromTarget", ["sessionId": old]); sessionID = nil }
        guard case .success(let r) = c.call("Target.attachToTarget", ["targetId": target, "flatten": true]),
              let sid = r["sessionId"] as? String else { return false }
        sessionID = sid; activeTarget = target
        c.send("Target.activateTarget", ["targetId": target])
        _ = c.call("Page.enable", session: sid)
        applyViewport()
        startScreencastIfNeeded()
        return true
    }

    private func applyViewport() {
        guard let c = conn, let sid = sessionID else { return }
        _ = c.call("Emulation.setDeviceMetricsOverride", ["width": viewport.w, "height": viewport.h, "deviceScaleFactor": viewport.scale,
                                                           "mobile": true], session: sid)
        _ = c.call("Emulation.setTouchEmulationEnabled", ["enabled": true, "maxTouchPoints": 5], session: sid)
    }

    private func startScreencastIfNeeded() {
        guard let c = conn, let sid = sessionID, !screencasting, !allViewers().isEmpty else { return }
        screencasting = true
        c.send("Page.startScreencast", ["format": "jpeg", "quality": 60, "maxWidth": Int(Double(viewport.w) * viewport.scale),
                                         "maxHeight": Int(Double(viewport.h) * viewport.scale), "everyNthFrame": 1], session: sid)
    }

    private func stopScreencast() {
        guard screencasting else { return }
        screencasting = false
        if let c = conn, let sid = sessionID { c.send("Page.stopScreencast", session: sid) }
    }

    // MARK: events

    private func event(_ method: String, _ p: [String: Any], _ session: String?) {
        switch method {
        case "Page.screencastFrame":
            guard let c = conn, let sid = session, let ack = p["sessionId"] as? Int else { return }
            c.send("Page.screencastFrameAck", ["sessionId": ack], session: sid)
            guard let b64 = p["data"] as? String, let jpeg = Data(base64Encoded: b64) else { return }
            lock.lock(); seq += 1; let n = seq; framesSent += 1; let vp = viewport; lock.unlock()
            let frame = BrowserWire.encodeFrame(header: ["t": "frame", "w": vp.w, "h": vp.h, "seq": n,
                                                         "ts": Int(Date().timeIntervalSince1970 * 1000)], jpeg: jpeg)
            for v in allViewers() { v.frames.put(frame) }
        case "Target.targetCreated", "Target.targetDestroyed", "Target.targetInfoChanged", "Page.frameNavigated":
            cmdQueue.async { [self] in broadcastTabs() }
        default: break
        }
    }

    // MARK: tabs

    func tabsPayload() -> [String: Any] {
        let tabs = pageTargets()
        var canBack = false, canForward = false
        if let c = conn, let sid = sessionID, case .success(let r) = c.call("Page.getNavigationHistory", session: sid),
           let i = r["currentIndex"] as? Int, let e = r["entries"] as? [[String: Any]] { canBack = i > 0; canForward = i < e.count - 1 }
        return ["t": "tabs", "canBack": canBack, "canForward": canForward,
                "tabs": tabs.map { ["id": $0.id, "title": $0.title, "url": $0.url, "active": $0.id == activeTarget] as [String: Any] }]
    }

    private func broadcastTabs() {
        guard !allViewers().isEmpty else { return }
        let d = (try? JSONSerialization.data(withJSONObject: tabsPayload())) ?? Data()
        let s = String(decoding: d, as: UTF8.self)
        for v in allViewers() { v.push(text: s) }
    }

    func tabsJSON() -> Data {
        var payload = tabsPayload()
        payload["t"] = nil
        payload["enabled"] = enabled; payload["running"] = conn != nil && !(conn?.closed ?? true)
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    /// Phone-side tab list works without a viewer (REST); connects lazily.
    func tabsJSONConnecting() -> Data {
        cmdQueue.sync { _ = enabled ? ensureConnected() : false; return tabsJSON() }
    }

    // MARK: commands

    func handle(_ cmd: BrowserCommand) {
        guard enabled else { return }
        cmdQueue.async { [self] in run(cmd) }
    }

    /// Synchronous variant for tests and REST callers.
    func handleSync(_ cmd: BrowserCommand) { cmdQueue.sync { run(cmd) } }

    /// Run a script in the active tab (used by the live e2e to prove the page changed).
    func evaluate(_ js: String) -> String? {
        cmdQueue.sync {
            guard let c = conn, let sid = sessionID,
                  case .success(let r) = c.call("Runtime.evaluate", ["expression": js, "returnByValue": true], session: sid),
                  let res = r["result"] as? [String: Any] else { return nil }
            return (res["value"]).map { "\($0)" }
        }
    }

    private func run(_ cmd: BrowserCommand) {
        guard ensureConnected(), let c = conn, let sid = sessionID else { return }
        func point(_ nx: Double, _ ny: Double) -> CGPoint {
            BrowserInputMapper.pagePoint(nx: nx, ny: ny, viewport: CGSize(width: viewport.w, height: viewport.h))
        }
        switch cmd {
        case .viewport(let w, let h, let scale):
            guard (w, h, scale) != (viewport.w, viewport.h, viewport.scale) else { return }
            lock.lock(); viewport = (w, h, scale); lock.unlock()
            stopScreencast(); applyViewport(); startScreencastIfNeeded()
        case .tap(let x, let y):
            let p = point(x, y)
            let tp: [[String: Any]] = [["x": p.x, "y": p.y]]
            _ = c.call("Input.dispatchTouchEvent", ["type": "touchStart", "touchPoints": tp], session: sid)
            _ = c.call("Input.dispatchTouchEvent", ["type": "touchEnd", "touchPoints": [] as [[String: Any]]], session: sid)
        case .scroll(let x, let y, let dx, let dy):
            let p = point(x, y)
            c.send("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": p.x, "y": p.y, "deltaX": dx, "deltaY": dy], session: sid)
        case .text(let t): c.send("Input.insertText", ["text": t], session: sid)
        case .key(let name):
            guard let k = BrowserKeys.spec(name) else { return }
            var down: [String: Any] = ["type": k.text == nil ? "rawKeyDown" : "keyDown", "key": k.key, "code": k.code,
                                       "windowsVirtualKeyCode": k.vk]
            if let t = k.text { down["text"] = t }
            c.send("Input.dispatchKeyEvent", down, session: sid)
            c.send("Input.dispatchKeyEvent", ["type": "keyUp", "key": k.key, "code": k.code, "windowsVirtualKeyCode": k.vk], session: sid)
        case .navigate(let raw):
            guard let url = BrowserURL.normalize(raw) else { return }
            c.send("Page.navigate", ["url": url], session: sid)
        case .back, .forward:
            guard case .success(let r) = c.call("Page.getNavigationHistory", session: sid),
                  let i = r["currentIndex"] as? Int, let e = r["entries"] as? [[String: Any]] else { return }
            let j = cmd == .back ? i - 1 : i + 1
            guard e.indices.contains(j), let id = e[j]["id"] as? Int else { return }
            c.send("Page.navigateToHistoryEntry", ["entryId": id], session: sid)
        case .reload: c.send("Page.reload", session: sid)
        case .newTab(let raw):
            let url = raw.flatMap(BrowserURL.normalize) ?? "about:blank"
            if case .success(let r) = c.call("Target.createTarget", ["url": url]), let id = r["targetId"] as? String { attach(id) }
        case .closeTab(let id):
            _ = c.call("Target.closeTarget", ["targetId": id])
            if id == activeTarget { if let next = pageTargets().first { attach(next.id) } else { sessionID = nil; _ = ensureConnected() } }
        case .selectTab(let id): attach(id)
        }
        broadcastTabs()
    }
}
