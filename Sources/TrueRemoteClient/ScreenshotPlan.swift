import Foundation

/// Pure decisions behind the phone's automatic screenshot upload (no Photos dependency, so `swift test` covers them).
public enum ScreenshotPlan {
    public enum Format: Equatable, Sendable { case png, jpeg, other }

    /// Which assets to upload, oldest first: newer than `lastSynced`, not already sent this session.
    /// No `lastSynced` means the toggle was never armed, so nothing goes.
    public static func plan(assets: [(id: String, created: Date)], lastSynced: Date?, seen: Set<String>) -> [String] {
        guard let lastSynced else { return [] }
        return assets
            .filter { $0.created > lastSynced && !seen.contains($0.id) }
            .sorted { $0.created < $1.created }
            .map(\.id)
    }

    /// "Screenshot-20261010-142530.png", in the phone's current calendar and time zone.
    public static func filename(created: Date, ext: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Screenshot-\(f.string(from: created)).\(ext)"
    }

    /// Sniff the first bytes; anything that is neither PNG nor JPEG (HEIC, …) must be converted before upload.
    public static func format(of data: Data) -> Format {
        let b = [UInt8](data.prefix(8))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47, b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return .png }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        return .other
    }

    public static func needsJPEGConversion(_ data: Data) -> Bool { format(of: data) == .other }
}
