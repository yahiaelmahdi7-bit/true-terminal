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
}
