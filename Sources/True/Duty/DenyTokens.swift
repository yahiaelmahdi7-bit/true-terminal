import Foundation

/// Word-by-word reading of a command text (single pass, no regex gaps): git behind its global options, and the target of a pipe
/// behind any wrapper chain. Complements the regex rules in `DenyList`; every input is already under the 8 KB cap.
extension DenyList {
    private static let wrappers: Set<String> = ["sudo", "doas", "env", "nohup", "xargs", "command", "exec", "nice", "ionice", "time",
                                                "stdbuf", "timeout", "caffeinate", "arch"]
    /// Wrapper flags that take a separate value word.
    private static let valuedFlags: Set<String> = ["-u", "-g", "-C", "-U", "-h", "-p", "-r", "-t", "-n", "-c", "-I", "-L", "-P", "-s", "-k"]
    private static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "perl", "ruby", "node",
                                                    "osascript", "php"]
    /// git global options whose value is the next word (when not written `--opt=value`).
    private static let gitValued: Set<String> = ["-c", "-C", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"]
    private static let gitDangerousKeys = ["alias.", "core.sshcommand", "core.hookspath", "credential.helper", "core.pager", "core.editor",
                                           "core.fsmonitor"]

    private static func isOp(_ t: String) -> Bool { t.first.map { ";&|\n".contains($0) } ?? false }

    /// Words, with `; & | && || |& newline` as their own operator tokens.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var word: [UInt8] = []
        var op: [UInt8] = []
        func flushWord() {
            var lo = 0, hi = word.count
            func paren(_ c: UInt8) -> Bool { c == 40 || c == 41 || c == 123 || c == 125 }
            while lo < hi, paren(word[lo]) { lo += 1 }
            while hi > lo, paren(word[hi - 1]) { hi -= 1 }
            if lo < hi { out.append(String(decoding: word[lo..<hi], as: UTF8.self)) }
            word.removeAll(keepingCapacity: true)
        }
        func flushOp() { if !op.isEmpty { out.append(String(decoding: op, as: UTF8.self)); op.removeAll(keepingCapacity: true) } }
        for c in s.utf8 {
            switch c {
            case 59, 38, 124: flushWord(); op.append(c)  // ; & |
            case 10: flushWord(); flushOp(); out.append("\n")
            case 32, 9, 13: flushWord(); flushOp()
            default: flushOp(); word.append(c)
            }
        }
        flushWord(); flushOp()
        return out
    }

    private static func base(_ w: String) -> String { String(w.split(separator: "/").last ?? Substring(w)) }

    static func tokenHits(_ view: String) -> [String] {
        var out: Set<String> = []
        let toks = tokens(view)
        let hasDownload = matches(view, #"\b(curl|wget)\b"#)
        // One flag byte per token so the 200-word scans below compare integers, not strings.
        let kinds: [UInt8] = toks.map { w in
            if w == "--hard" { return 1 }
            if w == "--force" || (w.hasPrefix("-") && !w.hasPrefix("--") && w.utf8.contains(UInt8(ascii: "f"))) { return 2 }
            if w == "-D" { return 4 }
            if w == "." { return 8 }
            if w == "--" { return 16 }
            return 0
        }
        // Prefix counts per kind bit and the next operator position make every "any word in this range?" question O(1).
        var prefix = [[Int32]](repeating: [Int32](repeating: 0, count: toks.count + 1), count: 5)
        var nextOp = [Int](repeating: toks.count, count: toks.count + 1)
        for k in 0..<toks.count { for b in 0..<5 { prefix[b][k + 1] = prefix[b][k] + (kinds[k] >> UInt8(b) & 1 == 1 ? 1 : 0) } }
        for k in stride(from: toks.count - 1, through: 0, by: -1) { nextOp[k] = isOp(toks[k]) ? k : nextOp[k + 1] }
        let scan = Scan(kinds: kinds, prefix: prefix, nextOp: nextOp)
        var i = 0
        while i < toks.count {
            let t = toks[i]
            if t.utf8.count < 200, t.utf8.count >= 3, t.lowercased().hasSuffix("git"), base(t).lowercased() == "git" { gitAt(toks, scan, i, &out) }
            if hasDownload, t == "|" || t == "|&" { if pipeTarget(toks, i + 1) { out.insert("pipe to shell") } }
            i += 1
        }
        return Array(out)
    }

    struct Scan { let kinds: [UInt8]; let prefix: [[Int32]]; let nextOp: [Int] }

    /// `git [global options] <subcommand> <rest…>` -> the existing git rules run on the normalised form.
    private static func gitAt(_ toks: [String], _ scan: Scan, _ at: Int, _ out: inout Set<String>) {
        var j = at + 1
        while j < toks.count, !isOp(toks[j]) {
            let w = toks[j]
            guard w.hasPrefix("-") else { break }
            let lw = w.lowercased()
            if gitDangerousKeys.contains(where: { lw.contains($0) }) { out.insert("obfuscated shell") }
            if gitValued.contains(w) {
                j += 1
                if j < toks.count, !isOp(toks[j]), gitDangerousKeys.contains(where: { toks[j].lowercased().contains($0) }) {
                    out.insert("obfuscated shell")
                }
            }
            j += 1
        }
        guard j < toks.count, !isOp(toks[j]) else { return }
        let sub = toks[j].lowercased()
        guard ["push", "reset", "clean", "branch", "checkout", "restore"].contains(sub) else { return }
        let end = min(scan.nextOp[j + 1 <= toks.count ? j + 1 : toks.count], j + 201)
        func count(_ b: Int, _ lo: Int, _ hi: Int) -> Int32 { lo < hi ? scan.prefix[b][hi] - scan.prefix[b][lo] : 0 }
        func has(_ m: UInt8) -> Bool { (0..<5).contains { m >> UInt8($0) & 1 == 1 && count($0, j + 1, end) > 0 } }
        let first: UInt8 = j + 1 < end ? scan.kinds[j + 1] : 0
        switch sub {
        case "push": out.insert("git push")
        case "reset": if has(1) { out.insert("git destructive") }
        case "clean": if has(2) { out.insert("git destructive") }
        case "branch": if has(4) { out.insert("git destructive") }
        case "checkout":
            if first & 8 != 0 || (j + 1..<max(end - 1, j + 1)).contains(where: { scan.kinds[$0] & 16 != 0 && scan.kinds[$0 + 1] & 8 != 0 }) { out.insert("git destructive") }
        case "restore": if first & 8 != 0 { out.insert("git destructive") }
        default: break
        }
    }

    /// After a pipe: skip wrapper words and their flags/args; is the first real word a shell/interpreter?
    private static func pipeTarget(_ toks: [String], _ from: Int) -> Bool {
        var j = from
        var inWrapper = false
        while j < toks.count, !isOp(toks[j]) {
            let w = toks[j]
            let b = base(w).lowercased()
            if wrappers.contains(b) { inWrapper = true; j += 1; continue }
            if inWrapper {
                if w.hasPrefix("-") {
                    j += 1
                    if !w.contains("="), valuedFlags.contains(w), j < toks.count, !isOp(toks[j]) { j += 1 }
                    continue
                }
                if w.contains("=") || w.range(of: #"^[0-9.]+[smhd]?$"#, options: .regularExpression) != nil { j += 1; continue }
            }
            return interpreters.contains(b) || b.hasPrefix("python")
        }
        return false
    }
}
