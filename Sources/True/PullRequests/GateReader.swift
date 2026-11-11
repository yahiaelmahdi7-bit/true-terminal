import Foundation

/// `~/.true/gate/<sha>.json`, as gate.py writes it.
struct GateResult: Codable, Equatable, Sendable {
    var passed: Bool
    var dirty: Bool
    var commit: String
    var failed: [String]
    var flaky: [String]
    var reason: String
    var duration: Double
    var run_id: String

    init(passed: Bool, dirty: Bool = false, commit: String, failed: [String] = [], flaky: [String] = [],
         reason: String = "", duration: Double = 0, run_id: String = "") {
        self.passed = passed; self.dirty = dirty; self.commit = commit; self.failed = failed
        self.flaky = flaky; self.reason = reason; self.duration = duration; self.run_id = run_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        passed = try c.decode(Bool.self, forKey: .passed)
        commit = try c.decode(String.self, forKey: .commit)
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
        failed = try c.decodeIfPresent([String].self, forKey: .failed) ?? []
        flaky = try c.decodeIfPresent([String].self, forKey: .flaky) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        run_id = try c.decodeIfPresent(String.self, forKey: .run_id) ?? ""
    }
}

/// The one word a gate file state gets in the list.
enum GateWord: String, Equatable, Sendable {
    case green = "Green", red = "Red", notRun = "Not run", old = "Old"
}

/// Read-only: this never writes under the gate directory.
struct GateReader: Sendable {
    var dir: String = NSHomeDirectory() + "/.true/gate"

    func result(_ sha: String) -> GateResult? {
        guard Self.isSha(sha), let data = FileManager.default.contents(atPath: "\(dir)/\(sha).json") else { return nil }
        return try? JSONDecoder().decode(GateResult.self, from: data)
    }

    /// `<run_id>/result.json` exists and agrees with the gate file (`commit`, `passed`).
    func runFileOK(_ gate: GateResult) -> Bool {
        guard !gate.run_id.isEmpty, !gate.run_id.contains("/"), gate.run_id != ".", gate.run_id != "..",
              let data = FileManager.default.contents(atPath: "\(dir)/\(gate.run_id)/result.json"),
              let run = try? JSONDecoder().decode(GateResult.self, from: data) else { return false }
        return run.commit == gate.commit && run.passed == gate.passed
    }

    /// Last "Test run with N tests" in `<run_id>/test.log` (result.json has no count).
    func testCount(_ gate: GateResult) -> Int? {
        guard !gate.run_id.isEmpty, !gate.run_id.contains("/"), gate.run_id != ".", gate.run_id != "..",
              let h = FileHandle(forReadingAtPath: "\(dir)/\(gate.run_id)/test.log") else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        guard let range = text.range(of: #"Test run with (\d+) tests?"#, options: [.regularExpression, .backwards]) else { return nil }
        return Int(text[range].split(separator: " ").dropFirst(3).first ?? "")
    }

    /// Gate state of a PR head. `commits` = the PR's own commit list (shas).
    func word(head: String, commits: [String]) -> GateWord {
        if let g = result(head) {
            if g.commit != head || g.dirty { return .notRun }
            return g.passed ? .green : .red
        }
        return commits.contains { $0 != head && result($0) != nil } ? .old : .notRun
    }

    static func isSha(_ s: String) -> Bool {
        (7...64).contains(s.count) && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
