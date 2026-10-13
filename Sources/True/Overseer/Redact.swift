import Foundation

/// Strips credentials from text before it leaves the process (the Overseer's Jev call and its log file).
/// Pure. Over-redacting is fine; leaking is not.
enum Redact {
    static let mark = "[redacted]"

    private static let patterns: [NSRegularExpression] = [
        #"-----BEGIN\b[\s\S]*?(?:-----END[^\n]*-----|$)"#,
        // Bare long hex (hashes/keys) and long mixed-case base64 tokens; bounded lookaheads keep paths and prose intact.
        #"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])"#,
        #"(?<![A-Za-z0-9+/_-])(?=[A-Za-z0-9+/_-]{0,64}\d)(?=[A-Za-z0-9+/_-]{0,64}[a-z])(?=[A-Za-z0-9+/_-]{0,64}[A-Z])[A-Za-z0-9+/_-]{40,}={0,2}"#,
        #"\bsk-(?:ant-)?[A-Za-z0-9_\-]{8,}"#,
        // Stripe secret / restricted keys and webhook signing secrets (underscores, not dashes).
        #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{8,}"#,
        #"\bwhsec_[A-Za-z0-9]{8,}"#,
        #"\bgh[opsur]_[A-Za-z0-9]{8,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{8,}"#,
        #"\bAKIA[0-9A-Z]{12,}"#,
        #"\bAIza[0-9A-Za-z_\-]{30,}"#,
        #"\bxox[bp]-[A-Za-z0-9\-]{8,}"#,
        // JWTs: Supabase service-role / anon keys and most session tokens.
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        #"\bBearer\s+[A-Za-z0-9._~+/=\-]{8,}"#,
        // NAME=value, NAME: value, "name": "value" where NAME contains KEY / TOKEN / SECRET / PASSWORD
        // (any case) — env files, JSON/YAML config, HTTP headers like `apikey: …`.
        #"(?i)\b[A-Za-z0-9_\-]*(?:key|token|secret|passw(?:or)?d)[A-Za-z0-9_\-]*["']?\s*[:=]\s*["']?[^\s"',;}]+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func secrets(_ text: String) -> String {
        var out = text
        for re in patterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: mark)
        }
        return out
    }
}
