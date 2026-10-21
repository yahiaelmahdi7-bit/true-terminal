import Testing
import Foundation
@testable import True

struct PeerLogicTests {
    static let id = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
    static func body(_ patch: [String: Any] = [:], drop: [String] = []) -> Data {
        var o: [String: Any] = ["jobId": id, "title": "Fix the thing", "brief": "Please fix X.\n\tIndented.", "repo": "git@github.com:Acme/App.git",
                                "base": "main", "mode": "pane", "fromAgent": "lead"]
        for (k, v) in patch { o[k] = v }
        for k in drop { o[k] = nil }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    @Test func validJobParses() throws {
        let j = try PeerValidate.parseJob(Self.body()).get()
        #expect(j.jobId == Self.id.lowercased() && j.mode == .pane && j.base == "main")
        let d = try PeerValidate.parseJob(Self.body(drop: ["base"])).get()
        #expect(d.base == "main")
    }

    @Test func validationRejects() {
        func bad(_ p: [String: Any] = [:], drop: [String] = []) -> Bool {
            if case .failure = PeerValidate.parseJob(Self.body(p, drop: drop)) { return true }; return false
        }
        #expect(bad(["jobId": "nope"]))
        #expect(bad(["title": ""]))
        #expect(bad(["title": String(repeating: "a", count: 121)]))
        #expect(bad(["title": "two\nlines"]))
        #expect(bad(["brief": "has \u{1B}[31m escape"]))
        #expect(bad(["brief": "nul \u{0} byte"]))
        #expect(bad(["brief": String(repeating: "a", count: PeerValidate.maxBrief + 1)]))
        #expect(bad(["repo": "not a url"]))
        #expect(bad(["repo": "file:///etc/passwd"]))
        #expect(bad(["base": "--upload-pack=x"]))
        #expect(bad(["base": "a..b"]))
        #expect(bad(["mode": "shell"]))
        #expect(bad(drop: ["brief"]))
        #expect(!bad(["title": String(repeating: "a", count: 120)]))
        #expect(!bad(["brief": "tab\tand\nnewline"]))
    }

    @Test func repoIsOptional() throws {
        for j in [Self.body(drop: ["repo"]), Self.body(["repo": ""]), Self.body(["repo": "   "]), Self.body(["repo": NSNull()])] {
            let r = try PeerValidate.parseJob(j).get()
            #expect(!r.hasRepo && r.repo.isEmpty && PeerRun.choose(for: r) == .scratch)
        }
        let with = try PeerValidate.parseJob(Self.body()).get()
        #expect(with.hasRepo && PeerRun.choose(for: with) == .repo)
        if case .success = PeerValidate.parseJob(Self.body(["repo": "not a url"])) { Issue.record("bad repo accepted") }
        if case .success = PeerValidate.parseJob(Self.body(["repo": 5])) { Issue.record("non-string repo accepted") }
    }

    @Test func scratchFolderIsInsideJobDir() {
        let d = URL(fileURLWithPath: "/tmp/jobs/abc")
        #expect(PeerNaming.scratch(jobDir: d).path == "/tmp/jobs/abc/work")
    }

    @Test func arrivalText() {
        #expect(PeerText.arrival(peer: "Bea", title: "Fix it", mode: .auto) == "Bea sent a job: Fix it")
        #expect(PeerText.arrival(peer: "Bea", title: "Fix it", mode: .ask) == "Bea sent a job: Fix it — waiting for you")
        #expect(PeerText.arrival(peer: "Bea", title: "a\nb", mode: .auto) == "Bea sent a job: a b")
    }

    @Test func repoNormalizationFixtures() {
        let want = "github.com/acme/App"
        for u in ["https://github.com/acme/App", "https://GitHub.com/acme/App.git", "git@github.com:acme/App.git",
                  "ssh://git@github.com/acme/App.git", "https://user@github.com/acme/App/", "ssh://git@github.com:22/acme/App"] {
            #expect(PeerRepo.normalize(u) == want, "\(u)")
        }
        #expect(PeerRepo.normalize("https://github.com/acme") == nil)
        #expect(PeerRepo.normalize("github.com/acme/App") == nil)
        #expect(PeerRepo.normalize("") == nil)
        #expect(PeerRepo.same("git@github.com:Acme/App.git", "https://github.com/Acme/App"))
        #expect(!PeerRepo.same("git@github.com:Acme/App.git", "https://github.com/Acme/Other"))
        #expect(PeerRepo.name("git@github.com:Acme/App.git") == "App")
    }

    @Test func repoResolutionPicksTheMatchingClone() {
        let origins = ["/r/a": "https://github.com/x/a.git", "/r/b": "git@github.com:acme/app.git"]
        #expect(PeerRepo.resolve(repo: "https://github.com/acme/app", candidates: ["/r/a", "/r/b"], originOf: { origins[$0] }) == "/r/b")
        #expect(PeerRepo.resolve(repo: "https://github.com/none/none", candidates: ["/r/a", "/r/b"], originOf: { origins[$0] }) == nil)
    }

    @Test func namingIsStable() {
        #expect(PeerNaming.shortId(Self.id) == "0f1e2d3c")
        #expect(PeerNaming.slug("Sam's Mac!") == "sam-s-mac")
        #expect(PeerNaming.slug("!!!") == "peer")
        #expect(PeerNaming.branch(label: "Sam", jobId: Self.id) == "peer/sam/0f1e2d3c")
        #expect(PeerNaming.agentName(label: "Sam", jobId: Self.id) == "peer-sam-0f1e2d3c")
        #expect(PeerNaming.worktree(clone: "/Users/f/Projects/app", jobId: Self.id) == "/Users/f/Projects/app.peers/0f1e2d3c")
        #expect(PeerNaming.fetchCommand(branch: "peer/sam/0f1e2d3c") == "git fetch origin peer/sam/0f1e2d3c && git checkout peer/sam/0f1e2d3c")
    }

    @Test func envelopeQuotesTheBriefAndRoleCardIsShort() throws {
        let j = try PeerValidate.parseJob(Self.body()).get()
        let e = PeerText.envelope(label: "Sam", job: j, branch: "peer/sam/0f1e2d3c", worktree: "/w", resultPath: "/r/result.md")
        let begin = try #require(e.range(of: PeerText.beginMark)), end = try #require(e.range(of: PeerText.endMark))
        #expect(begin.upperBound < end.lowerBound)
        #expect(e[begin.upperBound..<end.lowerBound].contains("Please fix X."))
        #expect(e.contains("Sam's True") && e.contains("push branch peer/sam/0f1e2d3c"))
        let c = PeerText.roleCard(label: "Sam", branch: "b", worktree: "/w", resultPath: "/r")
        #expect(c.contains("SendMessage") && c.contains("Sam's True"))
        #expect(PeerText.doneLine(label: "Sam", title: "Fix", status: .done, branch: "b", resultPath: "/r")
                == "[peer Sam] \"Fix\" done — branch b — result: /r")
    }

    @Test func hookEventsMapToStatus() {
        #expect(PeerEventMap.status(.progress, resultExists: false) == .working)
        #expect(PeerEventMap.status(.need, resultExists: false) == .needsYou)
        #expect(PeerEventMap.status(.stop, resultExists: false) == .idle)
        #expect(PeerEventMap.status(.stop, resultExists: true) == .done)
        #expect(PeerEventMap.status(.error, resultExists: true) == .failed)
        #expect(PeerEventMap.status(.other, resultExists: true) == nil)
    }

    @Test func backoffDoublesToTheCap() {
        #expect((0...7).map { PeerBackoff.delay(attempt: $0) } == [30, 60, 120, 240, 480, 600, 600, 600])
        #expect(PeerBackoff.delay(attempt: 10_000) == 600 && PeerBackoff.delay(attempt: -3) == 30)
    }

    @Test func inboundModeFlags() {
        #expect(PeerInboundMode.bypass.claudeFlags == ["--dangerously-skip-permissions"])
        #expect(PeerInboundMode.auto.claudeFlags == ["--permission-mode", "auto"])
        #expect(PeerInboundMode.ask.claudeFlags == ["--permission-mode", "auto"])
        #expect(PeerInboundMode.fresh == .ask)
    }

    // MARK: Run 30 — Drive

    @Test func targetParsing() throws {
        let repo = try PeerValidate.parseJob(Self.body(["target": ["kind": "repo", "repo": "https://github.com/acme/other.git", "base": "dev"]])).get()
        #expect(repo.dir == nil && repo.repo == "https://github.com/acme/other.git" && repo.base == "dev")
        #expect(repo.target == .repo(repo: "https://github.com/acme/other.git", base: "dev"))
        let dir = try PeerValidate.parseJob(Self.body(["target": ["kind": "dir", "path": "~/Work/fin"]], drop: ["repo"])).get()
        #expect(dir.dir == "~/Work/fin" && dir.repo.isEmpty && dir.target == .dir(path: "~/Work/fin") && PeerRun.choose(for: dir) == .dir)
        // an old sender (no target) is unchanged
        #expect(try PeerValidate.parseJob(Self.body()).get().target == .repo(repo: "git@github.com:Acme/App.git", base: "main"))
        for bad: [String: Any] in [["kind": "dir"], ["kind": "dir", "path": "relative/x"], ["kind": "dir", "path": "/a\u{7}b"], ["kind": "zip"]] {
            if case .success = PeerValidate.parseJob(Self.body(["target": bad])) { Issue.record("accepted \(bad)") }
        }
    }

    private func tempTree() throws -> (root: String, allowed: String, outside: String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("peerdirs-\(UUID().uuidString)").path
        for d in ["allowed/sub", "outside"] { try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true) }
        try fm.createSymbolicLink(atPath: root + "/allowed/escape", withDestinationPath: root + "/outside")
        return (root, root + "/allowed", root + "/outside")
    }

    @Test func dirAllowList() throws {
        let t = try tempTree()
        defer { try? FileManager.default.removeItem(atPath: t.root) }
        func ok(_ p: String, _ allowed: [String]) -> Bool { if case .success = PeerDirs.resolve(path: p, allowed: allowed, home: "/Users/nobody") { return true }; return false }
        #expect(ok(t.allowed, [t.allowed]) && ok(t.allowed + "/sub", [t.allowed]))
        #expect(!ok(t.outside, [t.allowed]))
        #expect(!ok(t.allowed + "/escape", [t.allowed]))            // symlink out
        #expect(!ok(t.allowed + "/sub/../../outside", [t.allowed]))  // ..
        #expect(!ok(t.allowed + "x", [t.allowed]))                   // prefix without a path boundary
        #expect(!ok(t.allowed + "/missing", [t.allowed]) && !ok(t.allowed, []))
        if case .failure(let e) = PeerDirs.resolve(path: t.outside, allowed: [], home: "/Users/nobody") { #expect(e == .invalid("Directory not allowed: \(t.outside)")) }
    }

    @Test func dirRefusesHomeAndAncestors() {
        let home = NSHomeDirectory()
        for p in ["/", home, "~", home + "/.true", "/Users", (home as NSString).deletingLastPathComponent] {
            if case .success = PeerDirs.resolve(path: p, allowed: [p, "/", home], home: home) { Issue.record("allowed \(p)") }
        }
        // a listed ancestor must not unlock its children either
        if case .success = PeerDirs.resolve(path: home + "/Documents", allowed: ["/", home], home: home) { Issue.record("home listed unlocked a child") }
    }

    @Test func sayStopActivityParse() {
        let id = Self.id
        #expect(PeerSay.parse(["jobId": id, "text": "keep going"])?.text == "keep going")
        #expect(PeerSay.parse(["jobId": id, "text": "  "]) == nil)
        #expect(PeerSay.parse(["jobId": id, "text": String(repeating: "a", count: 8 * 1024 + 1)]) == nil)
        #expect(PeerSay.parse(["jobId": "nope", "text": "x"]) == nil)
        #expect(PeerStopRequest.parse(["jobId": id]) == id.lowercased() && PeerStopRequest.parse([:]) == nil)
        let a = PeerActivity.parse(["jobId": id, "seq": 3, "items": [["t": 1, "kind": "tool", "text": "Bash"], ["t": 2, "kind": "bogus", "text": "x"]]])
        #expect(a?.seq == 3 && a?.items.count == 1)
        #expect(PeerActivity.parse(["jobId": id, "seq": -1, "items": []]) == nil)
    }

    @Test func secretMasking() {
        let hex = String(repeating: "ab12", count: 8)
        let m = PeerMask.firstLine("curl -H 'Authorization: Bearer abc.def-123456' sk-ant-abcdef123456 ghp_abcdefgh12345 \(hex) keep\nsecond line")
        #expect(!m.contains("abc.def") && !m.contains("sk-ant") && !m.contains("ghp_a") && !m.contains(hex))
        #expect(m.contains("keep") && !m.contains("second"))
        #expect(PeerMask.firstLine(String(repeating: "x", count: 5000)).count == 1024)
        #expect(PeerMask.mask("short hex deadbeef stays") == "short hex deadbeef stays")
    }

    @Test func batcherTwoSecondsEightKBTwentyPerMinute() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ n: Int = 10) -> PeerActivityItem { .init(t: 0, kind: .tool, text: String(repeating: "x", count: n)) }
        var b = PeerBatcher()
        b.add(item(), at: t0)
        #expect(b.take(at: t0.addingTimeInterval(1.9)) == nil)
        #expect(b.nextDue(at: t0) == t0.addingTimeInterval(2))
        #expect(b.take(at: t0.addingTimeInterval(2))?.count == 1 && !b.hasPending)
        // 8 KB flushes immediately
        for _ in 0..<9 { b.add(item(1000), at: t0.addingTimeInterval(3)) }
        #expect(b.take(at: t0.addingTimeInterval(3))?.count == 9)
        // 20 per rolling minute
        var c = PeerBatcher(), sent = 0
        for i in 0..<30 {
            let now = t0.addingTimeInterval(Double(i) * 2)
            c.add(item(), at: now)
            if c.take(at: now.addingTimeInterval(2)) != nil { sent += 1 }
        }
        #expect(sent == 20)
        // the budget returns after a minute, and force ignores it
        c.add(item(), at: t0.addingTimeInterval(61))
        // (the 10 throttled items are still pending, so the forced batch carries them plus the new one)
        #expect(c.take(at: t0.addingTimeInterval(61), force: true)?.count == 11)
    }
}
