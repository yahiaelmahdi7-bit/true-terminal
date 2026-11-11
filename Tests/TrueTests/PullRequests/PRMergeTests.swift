import Testing
import Foundation
@testable import True

private func facts(head: String = sha1, state: String = "OPEN", draft: Bool = false, base: String = "main", behind: Bool = false) -> PRFacts {
    PRFacts(number: 7, headSha: head, state: state, isDraft: draft, baseRef: base, behindMain: behind)
}
private func good(_ sha: String = sha1) -> GateResult { GateResult(passed: true, commit: sha, duration: 89, run_id: "run1") }
private let hold = HoldEntry(repo: "o/r", number: 7, since: "2026-11-09T14:02:00Z", why: "waiting on Alex")
private func refusal(_ v: PRMergeVerdict) -> String { if case .refuse(let r) = v { return r }; return "" }

@Suite struct PullRequestsMergeTests {
    @Test func heldPRIsRefusedWithHeldText() {
        let v = prMergeCheck(facts: facts(base: "dev"), gatedSha: sha1, gate: good(), runFileOK: true, held: hold)
        #expect(refusal(v) == "Held by the user. Release it to merge.")
    }
    @Test func noGateFileIsRefused() {
        #expect(refusal(prMergeCheck(facts: facts(), gatedSha: sha1, gate: nil, runFileOK: false, held: nil)) == "No gate result for this commit. Run the gate first.")
    }
    @Test func runFileMissingIsRefused() {
        #expect(refusal(prMergeCheck(facts: facts(), gatedSha: sha1, gate: good(), runFileOK: false, held: nil)) == "No gate result for this commit. Run the gate first.")
    }
    @Test func failedGateIsRefusedWithItsReason() {
        var g = good(); g.passed = false; g.reason = "build failed"
        #expect(refusal(prMergeCheck(facts: facts(), gatedSha: sha1, gate: g, runFileOK: true, held: nil)) == "The gate failed: build failed.")
        g.reason = ""; g.failed = ["PRTests/a"]
        #expect(refusal(prMergeCheck(facts: facts(), gatedSha: sha1, gate: g, runFileOK: true, held: nil)) == "The gate failed: PRTests/a.")
        g.reason = "build failed."
        #expect(refusal(prMergeCheck(facts: facts(), gatedSha: sha1, gate: g, runFileOK: true, held: nil)) == "The gate failed: build failed.")
    }
    @Test func dirtyGateDoesNotCount() {
        var g = good(); g.dirty = true
        #expect(refusal(prMergeCheck(facts: facts(), gatedSha: sha1, gate: g, runFileOK: true, held: nil)) == "The gate ran on uncommitted work, so it does not count.")
    }
    @Test func nonMainBaseIsRefused() {
        #expect(refusal(prMergeCheck(facts: facts(base: "dev"), gatedSha: sha1, gate: good(), runFileOK: true, held: nil)) == "This PR is not against main.")
    }
    @Test func gateFileForAnotherCommitIsRefused() {
        #expect(refusal(prMergeCheck(facts: facts(), gatedSha: sha1, gate: good(sha2), runFileOK: true, held: nil)) == "Gate result belongs to another commit.")
    }
    @Test func draftAndClosedAreRefused() {
        #expect(refusal(prMergeCheck(facts: facts(draft: true), gatedSha: sha1, gate: good(), runFileOK: true, held: nil)) == "This PR is a draft.")
        #expect(refusal(prMergeCheck(facts: facts(state: "MERGED"), gatedSha: sha1, gate: good(), runFileOK: true, held: nil)) == "This PR is closed.")
    }
    @Test func headDifferentFromGatedShaIsRefused() {
        #expect(refusal(prMergeCheck(facts: facts(), gatedSha: sha2, gate: good(), runFileOK: true, held: nil)) == "The PR changed after the gate. Run the gate again.")
    }
    @Test func branchBehindMainIsRefused() {
        #expect(refusal(prMergeCheck(facts: facts(behind: true), gatedSha: sha1, gate: good(), runFileOK: true, held: nil)) == "Update the branch first.")
    }
    @Test func greenCleanCurrentUnheldPasses() {
        #expect(prMergeCheck(facts: facts(), gatedSha: sha1, gate: good(), runFileOK: true, held: nil) == .merge(sha: sha1))
    }
}

@Suite struct PullRequestsMergeFlowTests {
    @Test func greenCleanCurrentUnheldMergesSquashWithPinnedHead() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = FakeGitHub(heads: [sha1])
        let result = await prMerge(number: 7, gatedSha: sha1, in: box.ctx(gh.fake))
        #expect(result == .merged(PRMerged(number: 7, sha: sha1, branch: "builder/x", branchDeleted: true)))
        #expect(gh.fake.lines.contains("gh pr merge 7 --squash --match-head-commit \(sha1)"))
        #expect(gh.fake.lines.contains("gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/builder/x"))
        let merge = gh.fake.lines.filter { $0.hasPrefix("gh pr merge") }.joined()
        for banned in ["--admin", "--auto", "--delete-branch", "--body"] { #expect(!merge.contains(banned)) }
    }
    @Test func headMovedBeforeMergeIsRefusedAndNeverMerges() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = FakeGitHub(heads: [sha1, sha2])
        let result = await prMerge(number: 7, gatedSha: sha1, in: box.ctx(gh.fake))
        #expect(result == .refused("The PR changed while merging. Nothing was merged."))
        #expect(gh.fake.count("gh pr merge") == 0)
    }
    @Test func holdAddedBeforeMergeStopsIt() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = FakeGitHub(heads: [sha1])
        var ctx = box.ctx(gh.fake)
        let reads = PRCounter()
        ctx.held = { _ in reads.next() >= 2 ? hold : nil }
        let result = await prMerge(number: 7, gatedSha: sha1, in: ctx)
        #expect(result == .refused("Held by the user. Release it to merge."))
        #expect(gh.fake.count("gh pr merge") == 0)
    }
    @Test func mergeAlwaysPassesMatchHeadCommit() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = FakeGitHub(heads: [sha1]); gh.mergeOK = false
        let result = await prMerge(number: 7, gatedSha: sha1, in: box.ctx(gh.fake))
        #expect(result == .refused("GitHub refused the merge: Pull request is not mergeable."))
        let merges = gh.fake.lines.filter { $0.hasPrefix("gh pr merge") }
        #expect(merges.count == 1 && merges[0].hasSuffix("--match-head-commit \(sha1)"))
        #expect(gh.fake.count("gh api -X DELETE") == 0)
    }
    @Test func refusedMergeWithMovedHeadSaysChanged() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = FakeGitHub(heads: [sha1, sha1, sha2]); gh.mergeOK = false
        #expect(await prMerge(number: 7, gatedSha: sha1, in: box.ctx(gh.fake)) == .refused("The PR changed while merging. Nothing was merged."))
    }
    @Test func mergeNotConfirmedIsReported() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = FakeGitHub(heads: [sha1]); gh.mergedState = "OPEN"
        #expect(await prMerge(number: 7, gatedSha: sha1, in: box.ctx(gh.fake)) == .refused("Merge not confirmed. Check GitHub."))
        #expect(gh.fake.count("gh api -X DELETE") == 0)
    }
    @Test func behindMainFromGitHubIsRefusedBeforeAnyMerge() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = FakeGitHub(heads: [sha1]); gh.behind = "diverged"
        #expect(await prMerge(number: 7, gatedSha: sha1, in: box.ctx(gh.fake)) == .refused("Update the branch first."))
        #expect(gh.fake.count("gh pr merge") == 0)
    }
    @Test func runFileMissingOnDiskIsRefused() async {
        let box = Sandbox(); box.writeGate(sha1, runFile: false)
        let gh = FakeGitHub(heads: [sha1])
        #expect(await prMerge(number: 7, gatedSha: sha1, in: box.ctx(gh.fake)) == .refused("No gate result for this commit. Run the gate first."))
    }
    @Test func branchDeleteSkipsMainOtherPRBaseAndFork() async {
        for variant in 0..<3 {
            let box = Sandbox(); box.writeGate(sha1)
            let gh = FakeGitHub(heads: [sha1])
            if variant == 0 { gh.ref = "main" }
            if variant == 1 { gh.otherPRs = #"[{"number":9}]"# }
            if variant == 2 { gh.fork = true }
            let result = await prMerge(number: 7, gatedSha: sha1, in: box.ctx(gh.fake))
            guard case .merged(let m) = result else { Issue.record("not merged"); continue }
            #expect(!m.branchDeleted)
            #expect(gh.fake.count("gh api -X DELETE") == 0)
        }
    }
}

final class PRCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    func peek() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}
