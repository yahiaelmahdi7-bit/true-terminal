import Foundation

/// `true://pair?host=<dns>:<port>&code=<6 digits>` — what the Mac's QR carries and the phone's scanner reads.
/// The address and code are exactly what the Remote Access sheet already shows, so scanning is as safe as reading.
public struct PairLink: Equatable, Sendable {
    public let address: String
    public let code: String?

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "true", url.host?.lowercased() == "pair",
              url.path.isEmpty || url.path == "/",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty else { return nil }
        // A bare host[:port] only: no scheme, path, query, credentials or whitespace.
        guard !host.contains(where: { "/?#@ \t\n\\".contains($0) }), !host.contains("://") else { return nil }
        var code: String?
        if let raw = items.first(where: { $0.name == "code" })?.value {
            guard raw.count == 6, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            code = raw
        }
        self.address = host
        self.code = code
    }

    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }
}
