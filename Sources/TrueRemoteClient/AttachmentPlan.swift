import Foundation

/// How a pane prompt refers to something already on the Mac: a tray shot by id, or a Downloads file by name.
/// Wire shape inside `attach`: `{"id":…}` / `{"name":…}`.
public enum PaneAttachmentRef: Equatable, Sendable, Codable {
    case shot(id: String)
    case file(name: String)

    private enum Key: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .id) { self = .shot(id: id); return }
        if let name = try c.decodeIfPresent(String.self, forKey: .name) { self = .file(name: name); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Need id or name"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .shot(let id): try c.encode(id, forKey: .id)
        case .file(let name): try c.encode(name, forKey: .name)
        }
    }

    /// What `/api/drop` answered: `where == "shots"` → tray id, `"downloads"` → file name.
    public init?(drop: DropResponse) {
        switch drop.where {
        case "shots": guard let id = drop.id else { return nil }; self = .shot(id: id)
        case "downloads": guard let name = drop.name else { return nil }; self = .file(name: name)
        default: return nil
        }
    }
}

/// Pure decisions behind attaching things to a pane prompt (no Photos/UIKit, so `swift test` covers them).
public enum AttachmentPlan {
    public static let maxCount = 8
    public static let maxBytes = 200_000_000

    public enum Pick: Equatable, Sendable {
        /// `ext` is the source's own extension ("heic", "png", "mov"…); HEIC-like formats are sent as JPEG.
        case photo(ext: String, index: Int)
        case camera(index: Int)
        case file(name: String)
    }

    public enum Status: Equatable, Sendable { case uploading, ready, failed }

    /// "Photo-20261010-142530-1.jpg", "Camera-…-1.jpg"; files keep their own name.
    public static func filename(for pick: Pick, now: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: now)
        switch pick {
        case .photo(let ext, let index):
            let e = ext.lowercased()
            let out = ["png", "jpg", "jpeg"].contains(e) ? (e == "jpeg" ? "jpg" : e) : (["heic", "heif", ""].contains(e) ? "jpg" : e)
            return "Photo-\(stamp)-\(index).\(out)"
        case .camera(let index): return "Camera-\(stamp)-\(index).jpg"
        case .file(let name): return name
        }
    }

    /// Send needs words or at least one ready attachment, and never while something is still uploading.
    public static func canSend(text: String, attachments: [Status]) -> Bool {
        if attachments.contains(.uploading) { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.contains(.ready)
    }

    /// How many more can be added, and whether one payload is within the size cap.
    public static func room(current: Int) -> Int { max(0, maxCount - current) }
    public static func withinCap(bytes: Int) -> Bool { bytes <= maxBytes }
}
