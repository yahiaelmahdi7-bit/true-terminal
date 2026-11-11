import Foundation

/// The chat mask: the same patterns, in the same order, as Steward's `true_steward.chat.mask`. `steward/tests/fixtures/mask-lines.json`
/// runs through both. `PeerMask` (the Mac app) takes its patterns from `rules`, so there is one list on this side.
/// Widening a rule is allowed; weakening one is not. Bare `0x` + hex is deliberately NOT masked.
public enum ChatMask {
    public static let marker = "‹masked›"

    /// One piece the mask replaced: Steward's name for it, and where. `start` and `length` count Unicode scalars of the MASKED text.
    /// Never carries the cut text.
    public struct Cut: Equatable, Sendable, Codable {
        public let kind: String
        public let start: Int
        public let length: Int
        public init(kind: String, start: Int, length: Int) { self.kind = kind; self.start = start; self.length = length }
    }

    private static let key = #"(?i)["']?[\w-]{0,40}(?:%@)["']?[ \t]*[=:][ \t]*"#
    private static let tok = "[A-Za-z0-9_-]"

    public static let rules: [(kind: String, pattern: String)] = [
        ("secret_key", #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{8,}"#),
        ("github_token", #"gh[pousr]_[A-Za-z0-9]{8,}"#),
        ("bearer_token", #"(?i)bearer\s+[A-Za-z0-9._~+/=\-]{6,}"#),
        ("hex_secret", #"\b[0-9a-fA-F]{32,}\b"#),
        ("private_key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#),
        ("pgp_key", #"-----BEGIN PGP PRIVATE KEY BLOCK-----[\s\S]*?(-----END PGP PRIVATE KEY BLOCK-----|$)"#),
        ("password_line", key.replacingOccurrences(of: "%@", with: "password|passwd|passphrase") + #"(?:"[^"\n]*"|'[^'\n]*'|[^\n]+)"#),
        ("credential", key.replacingOccurrences(of: "%@", with: #"token|secret|api[_-]?key|apikey|access[_-]?key"#) + #"(?:"[^"\n]*"|'[^'\n]*'|\S+)"#),
        ("resend_key", #"\bre_[A-Za-z0-9_]{16,}"#),
        ("aws_key", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("jwt", #"\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}\b"#),
        ("slack_token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        ("github_token", #"github_pat_\w{20,}"#),
        ("stripe_key", #"(?:sk|rk)_(?:live|test)_\w{10,}"#),
        ("google_key", #"AIza[0-9A-Za-z_\-]{30,}"#),
        ("gitlab_token", #"glpat-[A-Za-z0-9_\-]{20,}"#),
        ("url_password", #"://[^/\s:@]+:[^/\s@]+@"#),
        ("welcome_code", #"\b[a-z0-9_]{1,40}-[ABCDEFGHJKMNPQRSTVWXYZ23456789]{10}\b"#),
        // any case, but only when the ten characters hold a digit: `risk-management` stays readable
        ("welcome_code", #"\b[A-Za-z0-9_]{1,40}-(?=[A-Za-z]{0,9}[2-9])[ABCDEFGHJKMNPQRSTVWXYZabcdefghjkmnpqrstvwxyz2-9]{10}\b"#),
        ("session_token", "(?<![A-Za-z0-9_-])(?=\(tok){43}(?![A-Za-z0-9_-]))(?=\(tok){0,42}[A-Z])(?=\(tok){0,42}[a-z])\(tok){43}"),
    ]

    private static let compiled: [(kind: String, re: NSRegularExpression)] = rules.map { r in
        (r.kind, try! NSRegularExpression(pattern: r.pattern))
    }

    /// The masked text and what was cut. Same substitutions as Steward, in the same order, on running text where an earlier cut is a hole.
    public static func mask(_ text: String) -> (text: String, cuts: [Cut]) {
        var kinds: [String] = []
        var out = text
        for (kind, re) in compiled {
            let ns = out as NSString
            let ms = re.matches(in: out, range: NSRange(location: 0, length: ns.length)).filter { $0.range.length > 0 }
            if ms.isEmpty { continue }
            var pieces = "", pos = 0
            for m in ms {
                pieces += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
                kinds.append(kind)
                pieces += "\u{0}\(kinds.count - 1)\u{0}"
                pos = m.range.location + m.range.length
            }
            pieces += ns.substring(from: pos)
            out = pieces
        }
        guard !kinds.isEmpty else { return (text, []) }
        var result = "", cuts: [Cut] = [], length = 0
        var digits = "", inHole = false
        for u in out.unicodeScalars {
            if u == "\u{0}" {
                if inHole {
                    cuts.append(Cut(kind: kinds[Int(digits) ?? 0], start: length, length: marker.unicodeScalars.count))
                    result += marker; length += marker.unicodeScalars.count
                    digits = ""
                }
                inHole.toggle()
            } else if inHole { digits.unicodeScalars.append(u) }
            else { result.unicodeScalars.append(u); length += 1 }
        }
        return (result, cuts)
    }

    /// What a sender is told about a cut: a plain name and the place, never the cut text.
    public static func phrase(_ kind: String) -> String {
        switch kind {
        case "secret_key": "an API key (sk-…)"
        case "github_token": "a GitHub token"
        case "bearer_token": "a bearer token"
        case "hex_secret": "a long hex string"
        case "private_key": "a private key"
        case "pgp_key": "a PGP private key"
        case "password_line": "a password or passphrase"
        case "credential": "a value after token=, secret=, an API key or similar"
        case "resend_key": "a Resend key (re_…)"
        case "aws_key": "an AWS access key"
        case "jwt": "a JWT"
        case "slack_token": "a Slack token"
        case "stripe_key": "a Stripe key"
        case "google_key": "a Google API key"
        case "gitlab_token": "a GitLab token"
        case "url_password": "a password inside a link"
        case "welcome_code": "a welcome code"
        case "session_token": "a session token"
        default: "a secret"
        }
    }

    public static func notice(_ cuts: [Cut]) -> String? {
        cuts.isEmpty ? nil : "Part of this message was hidden: " + cuts.map { "\(phrase($0.kind)) at character \($0.start + 1) (\($0.length) long)" }.joined(separator: "; ") + "."
    }
}
