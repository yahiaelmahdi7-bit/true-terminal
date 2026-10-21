import Foundation

/// One DevTools-protocol message, parsed. Pure: no socket here.
enum CDPMessage: Equatable {
    case response(id: Int, result: [String: AnyHashable]?, error: String?)
    case event(method: String, params: [String: AnyHashable], sessionId: String?)

    static func encode(id: Int, method: String, params: [String: Any] = [:], sessionId: String? = nil) -> String {
        var o: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { o["params"] = params }
        if let sessionId { o["sessionId"] = sessionId }
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    static func decode(_ text: String) -> CDPMessage? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        if let id = o["id"] as? Int {
            let err = (o["error"] as? [String: Any]).flatMap { $0["message"] as? String }
            return .response(id: id, result: (o["result"] as? [String: Any]).map(Self.hashable), error: err)
        }
        if let m = o["method"] as? String {
            return .event(method: m, params: (o["params"] as? [String: Any]).map(Self.hashable) ?? [:], sessionId: o["sessionId"] as? String)
        }
        return nil
    }

    /// Params are compared in tests; keep only hashable leaves (nested containers become their description).
    private static func hashable(_ d: [String: Any]) -> [String: AnyHashable] {
        d.mapValues { ($0 as? AnyHashable) ?? String(describing: $0) as AnyHashable }
    }
}

/// What a phone can ask of the browser (JSON text messages on the stream).
enum BrowserCommand: Equatable {
    case viewport(w: Int, h: Int, scale: Double)
    case tap(x: Double, y: Double)                  // normalized 0…1
    case scroll(x: Double, y: Double, dx: Double, dy: Double)   // normalized point, CSS-px wheel delta
    case text(String)
    case key(String)                                // Enter, Backspace, Tab, Escape, ArrowUp …
    case navigate(String)
    case back, forward, reload
    case newTab(String?), closeTab(String), selectTab(String)

    static func parse(_ text: String) -> BrowserCommand? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let t = o["t"] as? String else { return nil }
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        switch t {
        case "viewport":
            guard let w = num("w"), let h = num("h"), w >= 100, h >= 100, w <= 4000, h <= 4000 else { return nil }
            return .viewport(w: Int(w), h: Int(h), scale: min(3, max(1, num("scale") ?? 2)))
        case "tap": guard let x = num("x"), let y = num("y") else { return nil }; return .tap(x: x, y: y)
        case "scroll": guard let x = num("x"), let y = num("y") else { return nil }; return .scroll(x: x, y: y, dx: num("dx") ?? 0, dy: num("dy") ?? 0)
        case "text": return (o["text"] as? String).map { .text(String($0.prefix(4096))) }
        case "key": return (o["key"] as? String).map { .key($0) }
        case "nav": return (o["url"] as? String).map { .navigate($0) }
        case "back": return .back
        case "forward": return .forward
        case "reload": return .reload
        case "tab.new": return .newTab(o["url"] as? String)
        case "tab.close": return (o["id"] as? String).map { .closeTab($0) }
        case "tab.select": return (o["id"] as? String).map { .selectTab($0) }
        default: return nil
        }
    }
}

/// Turns what a person types in the URL bar into something navigable. Search words go to a search page.
enum BrowserURL {
    static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 2048 else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower == "about:blank" { return s }
        if lower.hasPrefix("javascript:") || lower.hasPrefix("file:") || lower.hasPrefix("data:") || lower.hasPrefix("chrome:") { return nil }
        let host = s.split(separator: "/").first.map(String.init) ?? s
        let local = host.hasPrefix("localhost") || host.hasPrefix("127.") || host.hasPrefix("[::1]")
        if !s.contains(" "), local { return "http://" + s }
        if !s.contains(" "), host.contains(".") { return "https://" + s }
        return "https://www.google.com/search?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)
    }
}

/// Latest-frame-wins mailbox between Chrome's screencast and one slow phone socket: a frame that is overtaken before the
/// writer takes it is dropped, so a backed-up socket costs frames, never memory or latency.
final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: Data?
    private(set) var dropped = 0
    private(set) var delivered = 0
    let wake = DispatchSemaphore(value: 0)

    func put(_ f: Data) {
        lock.lock()
        if frame != nil { dropped += 1 } else { wake.signal() }
        frame = f
        lock.unlock()
    }
    func take() -> Data? {
        lock.lock(); defer { lock.unlock() }
        let f = frame; frame = nil
        if f != nil { delivered += 1 }
        return f
    }
}

/// Key names the phone sends → DevTools key fields.
enum BrowserKeys {
    struct Spec: Equatable { var key: String; var code: String; var vk: Int; var text: String? }
    static func spec(_ name: String) -> Spec? {
        switch name {
        case "Enter": return Spec(key: "Enter", code: "Enter", vk: 13, text: "\r")
        case "Backspace": return Spec(key: "Backspace", code: "Backspace", vk: 8, text: nil)
        case "Tab": return Spec(key: "Tab", code: "Tab", vk: 9, text: nil)
        case "Escape": return Spec(key: "Escape", code: "Escape", vk: 27, text: nil)
        case "ArrowUp": return Spec(key: "ArrowUp", code: "ArrowUp", vk: 38, text: nil)
        case "ArrowDown": return Spec(key: "ArrowDown", code: "ArrowDown", vk: 40, text: nil)
        case "ArrowLeft": return Spec(key: "ArrowLeft", code: "ArrowLeft", vk: 37, text: nil)
        case "ArrowRight": return Spec(key: "ArrowRight", code: "ArrowRight", vk: 39, text: nil)
        default: return nil
        }
    }
}
