import Foundation

/// Pure screen for text that came from logs, files or other agents before it reaches Jev or Claude
/// (SPEC Run 15 §3 step 2): strip invisible/bidi characters, cap, flag instruction-like text, then redact secrets.
enum InjectionScreen {
    struct Result: Equatable, Sendable {
        var text: String
        var flagged: Bool
        var reasons: [String]
    }

    static let evidenceCap = 2048

    private static let patterns: [(name: String, regex: String)] = [
        ("ignore-instructions", #"\bignore\s+(all\s+|any\s+|the\s+)?(earlier|previous|prior|above|your)\s+(\w+\s+)?(instructions|rules|prompts?)\b"#),
        ("disregard", #"\bdisregard\s+(the\s+|all\s+|your\s+)?(task|above|previous|earlier|prior|instructions|rules|policy)\b"#),
        ("you-are-now", #"\byou\s+are\s+now\b"#),
        ("role-tag", #"\[\s*(system|assistant|developer)\s*\]|<\s*/?\s*(system|assistant|human|developer)\s*>|(^|\n)\s*(system|assistant)\s*:"#),
        ("pipe-to-shell", #"\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(ba|z)?sh\b"#),
        ("base64-run", #"[A-Za-z0-9+/]{200,}={0,2}"#),
        ("note-to-agent", #"\b(note|message|instruction)s?\s+to\s+(the\s+)?(automated\s+)?(ai|agent|assistant)\b|\bAI\s+assistants?\s+reading\b"#),
    ]

    /// Invisible/format characters removed, then NFKC (folds fullwidth and other confusables).
    static func strip(_ s: String) -> String {
        DenyList.stripInvisible(s).precomposedStringWithCompatibilityMapping
    }

    static func flags(_ s: String) -> [String] {
        patterns.compactMap { p in
            s.range(of: p.regex, options: [.regularExpression, .caseInsensitive]) != nil ? p.name : nil
        }
    }

    /// Strip -> flag -> cap -> redact. Flags are computed on the stripped text before the cap so a tail can't hide.
    static func screen(_ raw: String, cap: Int = evidenceCap) -> Result {
        let clean = strip(raw)
        let reasons = flags(clean)
        let capped = clean.count > cap ? String(clean.prefix(cap)) + "…" : clean
        return Result(text: Redact.secrets(capped), flagged: !reasons.isEmpty, reasons: reasons)
    }
}
