import Foundation

/// Silence guard + transcript cleanup. Deterministic code (no Jev: nothing here is a classify/route step).
enum DictationCleaner {
    static let minSeconds = 0.5
    /// RMS energy floor of the 16 kHz clip: room tone sits well under this, speech well over. Raise it if phantom phrases appear.
    static let rmsFloor: Float = 0.004

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// True when the clip should not even go to Whisper.
    static func isSilent(samples: [Float], seconds: Double) -> Bool {
        seconds < minSeconds || rms(samples) < rmsFloor
    }

    private static let knownTags = ["[BLANK_AUDIO]", "[Music]", "[MUSIC]", "(silence)", "[silence]", "[SILENCE]", "(Silence)"]
    private static let lone: Set<String> = ["thank you", "thanks for watching", "thank you for watching", "thanks"]

    /// Strip non-speech tags and tag-only lines; join the rest on single spaces. Empty string = heard nothing.
    static func clean(_ raw: String, seconds: Double) -> String {
        var lines: [String] = []
        for var line in raw.split(whereSeparator: \.isNewline).map(String.init) {
            for t in knownTags { line = line.replacingOccurrences(of: t, with: "") }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) { continue }
            lines.append(t)
        }
        let text = lines.joined(separator: " ").split(separator: " ").joined(separator: " ")
        let key = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if seconds < 2, lone.contains(key) { return "" }
        return text
    }
}
