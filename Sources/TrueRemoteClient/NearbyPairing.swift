import Foundation

/// Shared contract for the Bluetooth "nearby" trigger. The Mac advertises (peripheral), the phone scans (central).
/// Bluetooth carries discovery and the Mac's address only. It never carries the pairing code: pairing is still the
/// HTTPS call with the 6-digit code, so the QR / typed code remains the proof of presence.
public enum NearbyPairing {
    /// One fixed service UUID, generated once with `uuidgen` for True. Never change it: shipped phones scan for it.
    public static let serviceUUID = "6D458A38-6CF3-489E-BFE9-B2BA040DE91D"
    /// read: the Mac's Tailscale `host:port`, UTF-8. The only readable characteristic.
    public static let addressUUID = "DC7923C8-D94F-48CA-B17D-3743B8501CC4"
    /// write without response: `"<phone name>|<stable phone id>"`, once per discovery. This triggers the Mac card.
    public static let helloUUID = "6C94143E-094D-457D-96F6-4E93625A89A5"
    /// notify: `1` when a phone paired while the card was up, so the phone's card can collapse on its own.
    public static let pairedUUID = "CABEF3B2-3805-44A9-A476-F3DD497A4238"

    /// RSSI (dBm) at or above which a Mac counts as "nearby": roughly the same room. Weaker signals are ignored.
    public static let rssiThreshold = -70

    public static func isNearby(rssi: Int) -> Bool { rssi >= rssiThreshold }

    /// A hello that is longer than this is refused; a GATT write is small and the name is shown in a card.
    static let maxHelloBytes = 200

    public struct Hello: Equatable, Sendable {
        public let name: String
        public let id: String
        public init(name: String, id: String) { self.name = name; self.id = id }
    }

    /// `"<name>|<id>"`. The id never contains `|`; a `|` inside the name is turned into a space so the split is unambiguous.
    public static func encodeHello(_ hello: Hello) -> Data {
        let name = hello.name.replacingOccurrences(of: "|", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = hello.id.replacingOccurrences(of: "|", with: "-")
        return Data("\(name)|\(id)".utf8)
    }

    /// Nil unless the bytes are UTF-8 `name|id` with both parts non-empty (control characters rejected).
    public static func decodeHello(_ data: Data) -> Hello? {
        guard data.count <= maxHelloBytes, let s = String(data: data, encoding: .utf8),
              let bar = s.lastIndex(of: "|") else { return nil }
        let name = s[..<bar].trimmingCharacters(in: .whitespacesAndNewlines)
        let id = s[s.index(after: bar)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !id.isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return Hello(name: name, id: id)
    }

    public static func encodeAddress(_ address: String) -> Data { Data(address.utf8) }

    /// A bare `host[:port]` only (same rules as `PairLink`), or nil.
    public static func decodeAddress(_ data: Data) -> String? {
        guard data.count <= 255, let s = String(data: data, encoding: .utf8), !s.isEmpty,
              !s.contains(where: { "/?#@ \t\n\\".contains($0) }), !s.contains("://") else { return nil }
        return s
    }

    /// What the phone learned about a Mac in range.
    public struct NearbyMac: Equatable, Sendable {
        public let name: String
        public let address: String
        public init(name: String, address: String) { self.name = name; self.address = address }
    }

    /// The advertised local name is `True · <Mac name>`; this recovers the Mac name.
    public static func macName(fromLocalName local: String) -> String {
        let prefix = "True · "
        return local.hasPrefix(prefix) ? String(local.dropFirst(prefix.count)) : local
    }
}
