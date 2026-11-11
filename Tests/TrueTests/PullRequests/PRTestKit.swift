import Foundation
@testable import True

/// Fake runner with recorded outputs. No test here touches real gh, git, the network or ~/.true.
final class PRFakeRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [PRCommand] = []
    var handler: @Sendable (PRCommand) -> PRRun
    init(_ handler: @escaping @Sendable (PRCommand) -> PRRun = { _ in PRRun(code: 0) }) { self.handler = handler }
    var calls: [PRCommand] { lock.lock(); defer { lock.unlock() }; return _calls }
    var lines: [String] { calls.map { ($0.tool == .git ? "git " : $0.tool == .gh ? "gh " : "file ") + $0.args.joined(separator: " ") } }
    func count(_ prefix: String) -> Int { lines.filter { $0.hasPrefix(prefix) }.count }
    private func record(_ c: PRCommand) { lock.lock(); _calls.append(c); lock.unlock() }
    var runner: PRRunner {
        PRRunner { [self] c in
            record(c)
            return handler(c)
        }
    }
}

struct Sandbox {
    let root: URL
    var gateDir: String { root.appendingPathComponent("gate").path }
    var holdsPath: String { root.appendingPathComponent("holds.json").path }
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("true-pr-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("gate"), withIntermediateDirectories: true)
    }
    func ctx(_ fake: PRFakeRunner, holds: PRHoldStore? = nil) -> PRContext {
        var c = PRContext(repoDir: root.path, repo: "o/r", holds: holds ?? PRHoldStore(path: holdsPath))
        c.runner = fake.runner
        c.gates = GateReader(dir: gateDir)
        c.prDir = root.appendingPathComponent("pr").path
        c.gateWorktrees = root.appendingPathComponent("pr-gate").path
        c.gateLock = PRGateLock()
        return c
    }
    /// Writes `<sha>.json` and `<run>/result.json` (+ test.log) like gate.py.
    func writeGate(_ sha: String, passed: Bool = true, dirty: Bool = false, commit: String? = nil, run: String = "run1",
                   runFile: Bool = true, reason: String = "", failed: [String] = [], tests: Int? = 1691) {
        func json(_ c: String) -> String {
            #"{"passed":\#(passed),"failed":\#(failed.isEmpty ? "[]" : "[\"" + failed.joined(separator: "\",\"") + "\"]"),"flaky":[],"reason":"\#(reason)","duration":89.4,"commit":"\#(c)","run_id":"\#(run)","dirty":\#(dirty)}"#
        }
        try? json(commit ?? sha).write(toFile: "\(gateDir)/\(sha).json", atomically: true, encoding: .utf8)
        guard runFile else { return }
        try? FileManager.default.createDirectory(atPath: "\(gateDir)/\(run)", withIntermediateDirectories: true)
        try? json(commit ?? sha).write(toFile: "\(gateDir)/\(run)/result.json", atomically: true, encoding: .utf8)
        if let tests {
            try? "noise\n✔ Test run with \(tests) tests in 266 suites passed after 89.1 seconds.\n".write(toFile: "\(gateDir)/\(run)/test.log", atomically: true, encoding: .utf8)
        }
    }
}

let sha1 = String(repeating: "a", count: 40)
let sha2 = String(repeating: "b", count: 40)
let sha3 = String(repeating: "c", count: 40)

func viewJSON(head: String, state: String = "OPEN", draft: Bool = false, base: String = "main", ref: String = "builder/x", fork: Bool = false) -> String {
    #"{"number":7,"state":"\#(state)","isDraft":\#(draft),"headRefOid":"\#(head)","baseRefName":"\#(base)","headRefName":"\#(ref)","isCrossRepository":\#(fork)}"#
}

/// A GitHub that answers the merge flow. `heads` is consumed one per `pr view` read of the PR head.
final class FakeGitHub: @unchecked Sendable {
    let fake: PRFakeRunner
    private let lock = NSLock()
    private var heads: [String]
    var behind = "ahead", mergeOK = true, mergedState = "MERGED", otherPRs = "[]", base = "main", fork = false, ref = "builder/x"
    init(heads: [String]) {
        self.heads = heads
        fake = PRFakeRunner()
        fake.handler = { [unowned self] c in answer(c) }
    }
    private func nextHead() -> String { lock.lock(); defer { lock.unlock() }; return heads.count > 1 ? heads.removeFirst() : heads[0] }
    private func answer(_ c: PRCommand) -> PRRun {
        let a = c.args
        if a.starts(with: ["pr", "view"]), a.contains(PRView.fields) {
            return PRRun(code: 0, out: viewJSON(head: nextHead(), base: base, ref: ref, fork: fork))
        }
        if a.starts(with: ["pr", "view"]) { return PRRun(code: 0, out: #"{"state":"\#(mergedState)","mergeCommit":{"oid":"\#(sha3)"}}"#) }
        if a.first == "api", a.contains("--jq") { return PRRun(code: 0, out: behind + "\n") }
        if a.starts(with: ["pr", "merge"]) { return mergeOK ? PRRun(code: 0) : PRRun(code: 1, err: "Pull request is not mergeable\nmore") }
        if a.starts(with: ["pr", "list"]) { return PRRun(code: 0, out: otherPRs) }
        return PRRun(code: 0)
    }
}
