import Testing
import Foundation
@testable import True

/// A GitHub that answers the Pull requests screen: preflight, list, one PR, its diff, git. No network, no real repo.
final class ScreenGH: @unchecked Sendable {
    private let lock = NSLock()
    private var _listFails = false, _rebaseFails = true
    var listFails: Bool { get { lock.lock(); defer { lock.unlock() }; return _listFails } set { lock.lock(); _listFails = newValue; lock.unlock() } }
    var rebaseFails: Bool { get { lock.lock(); defer { lock.unlock() }; return _rebaseFails } set { lock.lock(); _rebaseFails = newValue; lock.unlock() } }
    let fake = PRFakeRunner()
    /// What `gh api compare` says; "behind" keeps the Update branch tests as they were.
    var behind = "behind", mergeFails = false, ffFails = false, onMain = false, listJSONOverride: String?
    init() { fake.handler = { [weak self] c in self?.answer(c) ?? PRRun(code: 0) } }

    static let listJSON = #"[{"number":7,"title":"Add the thing","headRefName":"builder/x","headRefOid":"\#(sha1)","author":{"login":"owner"},"additions":3,"deletions":1,"isDraft":false,"url":"https://github.com/o/r/pull/7","commits":[]}]"#

    private func answer(_ c: PRCommand) -> PRRun {
        let a = c.args
        if c.tool == .gh {
            if a == ["--version"] { return PRRun(code: 0, out: "gh version 2.92.0 (2026-04-28)\n") }
            if a.starts(with: ["auth", "status"]) { return PRRun(code: 0) }
            if a.starts(with: ["pr", "list"]) { return listFails ? PRRun(code: 1, err: "dial tcp: no such host") : PRRun(code: 0, out: listJSONOverride ?? Self.listJSON) }
            if a.starts(with: ["pr", "view"]), a.contains("state,mergeCommit") { return PRRun(code: 0, out: #"{"state":"MERGED","mergeCommit":{"oid":"\#(sha3)"}}"#) }
            if a.starts(with: ["pr", "merge"]) { return mergeFails ? PRRun(code: 1, err: "Pull request is not mergeable\nmore") : PRRun(code: 0) }
            if a.starts(with: ["pr", "view"]) { return PRRun(code: 0, out: viewJSON(head: sha1)) }
            if a.starts(with: ["pr", "diff"]) { return PRRun(code: 0, out: "diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-a\n+b\n") }
            if a.first == "api" { return PRRun(code: 0, out: behind + "\n") }
            return PRRun(code: 0)
        }
        if a.starts(with: ["remote", "get-url"]) { return PRRun(code: 0, out: "git@github.com:o/r.git\n") }
        if a == ["rev-parse", "HEAD"] { return PRRun(code: 0, out: sha1 + "\n") }
        if a.first == "rev-parse", a.contains("--abbrev-ref") { return PRRun(code: 0, out: (onMain ? "main" : "feature") + "\n") }
        if a.starts(with: ["merge", "--ff-only"]) { return ffFails ? PRRun(code: 1, err: "fatal: Not possible") : PRRun(code: 0) }
        if (a.first == "rev-parse" && a.last?.hasPrefix("refs/remotes") == true) { return PRRun(code: 0, out: sha1 + "\n") }
        if a.first == "rebase", a.count == 2 { return rebaseFails ? PRRun(code: 1, err: "CONFLICT") : PRRun(code: 0) }
        if a.starts(with: ["diff", "--name-only"]) { return PRRun(code: 0, out: "a.txt\nb.txt\n") }
        return PRRun(code: 0)
    }
}

actor ScreenLatch {
    private(set) var reached = false
    private var opened = false
    private var cont: CheckedContinuation<Void, Never>?
    func wait() async { reached = true; if opened { return }; await withCheckedContinuation { cont = $0 } }
    func release() { opened = true; cont?.resume(); cont = nil }
}

@MainActor
struct PRScreenModelTests {
    private func model(_ gh: ScreenGH, _ sb: Sandbox, runner: PRRunner? = nil, holds: PRHoldStore? = nil, now: @escaping () -> Date = Date.init,
                       opened: @escaping @MainActor (URL) -> Void = { _ in }, toast: @escaping @MainActor (String) -> Void = { _ in }) -> PRScreenModel {
        PRScreenModel(folder: sb.root.path, runner: runner ?? gh.fake.runner, gates: GateReader(dir: sb.gateDir),
                      holds: holds ?? PRHoldStore(path: sb.holdsPath), prDir: sb.root.path + "/pr", gateWorktrees: sb.root.path + "/pr-gate",
                      sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                      now: now, open: opened, toast: toast, signInTab: {}, mainGate: { _ in })
    }
    private func listCalls(_ gh: ScreenGH) -> Int { gh.fake.count("gh pr list") }
    private func wait(_ cond: () -> Bool) async {
        for _ in 0..<300 where !cond() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func loadsTheListOnOpenAndKeepsItWhenARefreshFails() async {
        let gh = ScreenGH(), sb = Sandbox()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let m = model(gh, sb, now: { at })
        await m.load()
        #expect(m.list.phase == .loaded && m.list.rows.map(\.number) == [7] && m.list.cachedAt == at)
        gh.listFails = true
        await m.load()
        #expect(m.list.phase == .failed(PRCopy.network))
        #expect(m.list.rows.map(\.number) == [7])
        #expect(m.list.secondLine?.hasPrefix("Showing the last list from ") == true)
    }

    @Test func refreshesWhenTheWindowGainsFocusOnlyWhileVisible() async {
        let gh = ScreenGH(), sb = Sandbox()
        let m = model(gh, sb)
        await m.refreshOnFocus()
        #expect(listCalls(gh) == 0)           // hidden: nothing runs
        m.setVisible(true)
        await wait { listCalls(gh) == 1 }
        #expect(listCalls(gh) == 1)           // load on open
        await m.refreshOnFocus()
        #expect(listCalls(gh) == 2)           // focus gained
        m.setVisible(false)
        await m.refreshOnFocus()
        #expect(listCalls(gh) == 2)
    }

    @Test func theSixtySecondBeatRunsWhileVisibleAndStopsWhenHidden() async {
        let gh = ScreenGH(), sb = Sandbox()
        let slept = SleepLog()
        let timed = PRScreenModel(folder: sb.root.path, runner: gh.fake.runner, gates: GateReader(dir: sb.gateDir),
                                  holds: PRHoldStore(path: sb.holdsPath), sleep: { s in slept.add(s); try? await Task.sleep(for: .milliseconds(20)) },
                                  signInTab: {}, mainGate: { _ in })
        timed.setVisible(true)
        await wait { listCalls(gh) >= 3 }
        #expect(listCalls(gh) >= 3)
        #expect(slept.values.allSatisfy { $0 == 60 })
        timed.setVisible(false)
        try? await Task.sleep(for: .milliseconds(80))
        let after = listCalls(gh)
        try? await Task.sleep(for: .milliseconds(250))
        #expect(listCalls(gh) == after)       // hidden: no polling
        timed.setVisible(true)
        await wait { listCalls(gh) > after }
        #expect(listCalls(gh) > after)
        timed.setVisible(false)
    }

    @Test func updateBranchSetsUpdatingThenTheConflictLine() async {
        let gh = ScreenGH(), sb = Sandbox()
        let latch = ScreenLatch()
        let inner = gh.fake.runner
        let gated = PRRunner { c in
            if c.args.first == "rebase" { await latch.wait() }
            return await inner.run(c)
        }
        let m = model(gh, sb, runner: gated)
        await m.load()
        await m.openReview(m.list.rows[0])
        #expect(m.review?.showsUpdate == true && m.review?.updating == false)
        let t = Task { await m.update() }
        await wait { m.review?.updating == true }
        #expect(m.review?.updating == true)
        #expect(m.review?.updateEnabled == false)
        await latch.release()
        await t.value
        #expect(m.review?.updating == false)
        #expect(m.review?.updateNote == "Can't update: conflicts in 2 files.")
        #expect(m.review?.primary == TaskPRPrimary.none)
    }

    @Test func updateBranchSuccessClearsTheNoteAndReadsThePRAgain() async {
        let gh = ScreenGH(), sb = Sandbox()
        gh.rebaseFails = false
        let m = model(gh, sb)
        await m.load()
        await m.openReview(m.list.rows[0])
        let lists = listCalls(gh), views = gh.fake.count("gh pr view")
        await m.update()
        #expect(m.review?.updateNote == nil && m.review?.updating == false)
        #expect(listCalls(gh) == lists + 1)
        #expect(gh.fake.count("gh pr view") == views + 1)
        #expect(gh.fake.lines.contains { $0.hasPrefix("git push --force-with-lease=builder/x:") })
    }

    @Test func openOnGitHubUsesTheListUrl() async {
        let gh = ScreenGH(), sb = Sandbox()
        var opened: [URL] = []
        let m = model(gh, sb, opened: { opened.append($0) })
        await m.load()
        await m.openReview(m.list.rows[0])
        m.openOnGitHub()
        #expect(opened.map(\.absoluteString) == ["https://github.com/o/r/pull/7"])
        #expect(gh.fake.count("gh pr view 7 --web") == 0)
    }

    @Test func openOnGitHubFallsBackToGhWebWhenTheUrlIsMissing() async {
        let gh = ScreenGH(), sb = Sandbox()
        var opened: [URL] = []
        let m = model(gh, sb, opened: { opened.append($0) })
        var r = PRRow(number: 7, title: "t", author: "a", headRef: "builder/x", head: sha1, additions: 0, deletions: 0, isDraft: false,
                      url: "", gate: "Not run", held: false, holdWhy: "")
        r.url = ""
        await m.openReview(r)
        m.openOnGitHub()
        await wait { gh.fake.count("gh pr view 7 --web") == 1 }
        #expect(opened.isEmpty && gh.fake.count("gh pr view 7 --web") == 1)
    }
    // MARK: Gate word on the review matches the list

    @Test func anOlderGatedCommitShowsOldInTheRowAndOnTheReview() async {
        let gh = ScreenGH(), sb = Sandbox()
        sb.writeGate(sha2)   // an older commit of the PR was gated; the head (sha1) was not
        gh.listJSONOverride = ScreenGH.listJSON.replacingOccurrences(of: #""commits":[]"#, with: #""commits":[{"oid":"\#(sha2)"},{"oid":"\#(sha1)"}]"#)
        let m = model(gh, sb)
        await m.load()
        #expect(m.list.rows[0].gate == "Old")
        await m.openReview(m.list.rows[0])
        #expect(m.review?.pr?.gate == .old)
    }

    // MARK: Merge / Run gate / Hold on the review screen

    @Test func mergeRefusedShowsThePlainRefusalAndStaysOnTheReview() async {
        let gh = ScreenGH(), sb = Sandbox()
        sb.writeGate(sha1); gh.behind = "ahead"; gh.mergeFails = true
        var toasts: [String] = []
        let m = model(gh, sb, toast: { toasts.append($0) })
        await m.load(); await m.openReview(m.list.rows[0])
        #expect(m.review?.pr?.mergeEnabled == true)
        await m.merge()
        #expect(m.review?.pr?.note == "GitHub refused the merge: Pull request is not mergeable.")
        #expect(m.review != nil && toasts.isEmpty)
    }

    @Test func mergeMergedClosesTheReviewRefreshesAndToastsWithTheLocalMainNote() async {
        let gh = ScreenGH(), sb = Sandbox()
        sb.writeGate(sha1); gh.behind = "ahead"; gh.onMain = true; gh.ffFails = true
        var toasts: [String] = []
        let m = model(gh, sb, toast: { toasts.append($0) })
        await m.load(); await m.openReview(m.list.rows[0])
        let lists = gh.fake.count("gh pr list --state open --limit")
        await m.merge()
        #expect(m.review == nil)
        #expect(gh.fake.count("gh pr list --state open --limit") == lists + 1)   // the screen's list, not the branch-delete lookup
        #expect(toasts == ["Merged PR #7. Local main has diverged from GitHub; not updated."])
        #expect(gh.fake.lines.contains("gh pr merge 7 --squash --match-head-commit \(sha1)"))
    }

    @Test func runGateShowsTheClockThenClearsItAndReloads() async {
        let gh = ScreenGH(), sb = Sandbox()
        let latch = ScreenLatch()
        let inner = gh.fake.runner
        let gated = PRRunner { c in
            if case .file = c.tool { await latch.wait() }
            return await inner.run(c)
        }
        let m = model(gh, sb, runner: gated)
        await m.load(); await m.openReview(m.list.rows[0])
        #expect(m.review?.pr?.gateRunningFor == nil)
        let lists = listCalls(gh), views = gh.fake.count("gh pr view")
        let t = Task { await m.runGate() }
        await wait { m.review?.pr?.gateRunningFor != nil }
        #expect(m.review?.pr?.gateRunningFor != nil)
        await latch.release()
        await t.value
        #expect(m.review?.pr?.gateRunningFor == nil)
        #expect(listCalls(gh) == lists + 1)
        #expect(gh.fake.count("gh pr view") > views)
    }

    @Test func holdTogglesAndASaveFailureSaysSo() async throws {
        let gh = ScreenGH(), sb = Sandbox()
        let m = model(gh, sb)
        await m.load(); await m.openReview(m.list.rows[0])
        #expect(m.review?.pr?.held == false)
        await m.toggleHold()
        #expect(m.review?.pr?.held == true)
        await m.toggleHold()
        #expect(m.review?.pr?.held == false)
        // A Hold file that cannot be written: its parent is a plain file.
        let blocker = sb.root.appendingPathComponent("blocker").path
        try "x".write(toFile: blocker, atomically: true, encoding: .utf8)
        let bad = model(gh, sb, holds: PRHoldStore(path: blocker + "/holds.json"))
        await bad.load(); await bad.openReview(bad.list.rows[0])
        await bad.toggleHold()
        #expect(bad.review?.pr?.held == false)
        #expect(bad.review?.pr?.note == "Could not save the Hold.")
    }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock(); private var v: [Double] = []
    func add(_ s: Double) { lock.lock(); v.append(s); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return v }
}

extension PRFlowTests {
    /// The "not on origin" check asks git by exit code (2 = no such ref), so a non-English git says the same thing.
    @Test func lsRemoteExitCodeTwoIsTheGitHubLineWhateverTheLanguage() async {
        let sb = Sandbox()
        let fake = PRFakeRunner { c in c.args.first == "ls-remote" ? PRRun(code: 2, err: "fatal: kein solcher Remote-Ref") : PRRun(code: 0) }
        #expect(await PRUpdate.run(branch: "fork/x", worktree: nil, ctx: sb.ctx(fake)) == PRScreenCopy.noCleanCopy)
        #expect(fake.lines.first == "git ls-remote --exit-code origin refs/heads/fork/x")
        #expect(fake.count("git fetch") == 0)
    }

    @Test func lsRemoteOtherFailureIsTheNetworkLine() async {
        let sb = Sandbox()
        let fake = PRFakeRunner { c in c.args.first == "ls-remote" ? PRRun(code: 128, err: "fatal: unable to access") : PRRun(code: 0) }
        #expect(await PRUpdate.run(branch: "builder/x", worktree: nil, ctx: sb.ctx(fake)) == PRCopy.network)
    }

    @Test func failedWorktreeAddSaysCantUpdateNotPushFailed() async {
        let sb = Sandbox()
        let fake = PRFakeRunner { c in
            if (c.args.first == "rev-parse" && c.args.last?.hasPrefix("refs/remotes") == true) { return PRRun(code: 0, out: sha1 + "\n") }
            if c.args.starts(with: ["worktree", "add"]) { return PRRun(code: 128, err: "fatal: disk full\nmore") }
            return PRRun(code: 0)
        }
        #expect(await PRUpdate.run(branch: "builder/x", worktree: nil, ctx: sb.ctx(fake)) == "Can't update: fatal: disk full.")
    }
}

extension PRFlowTests {
    /// Both callers (task bar, Pull requests screen) toast whatever this returns, so the note lives here.
    @Test func mergeFlowToastIncludesTheLocalMainNoteWhenTheFastForwardIsRefused() async {
        let box = Sandbox(); box.writeGate(sha1)
        let gh = FakeGitHub(heads: [sha1]); gh.behind = "ahead"
        let inner = gh.fake.handler
        gh.fake.handler = { c in
            if c.args.first == "rev-parse" { return PRRun(code: 0, out: "main\n") }
            if c.args.starts(with: ["merge", "--ff-only"]) { return PRRun(code: 1, err: "fatal") }
            return inner(c)
        }
        let started = LockedCount()
        let out = await PRMergeFlow.run(number: 7, gatedSha: sha1, ctx: box.ctx(gh.fake), mainGate: { _ in started.bump() })
        #expect(out.toast == "Merged PR #7. Local main has diverged from GitHub; not updated.")
        #expect(out.refusal == nil && started.n == 1)
    }

    @Test func mergeFlowRefusalIsThePlainSentenceAndStartsNoMainGate() async {
        let box = Sandbox()   // no gate result
        let gh = FakeGitHub(heads: [sha1]); gh.behind = "ahead"
        let started = LockedCount()
        let out = await PRMergeFlow.run(number: 7, gatedSha: sha1, ctx: box.ctx(gh.fake), mainGate: { _ in started.bump() })
        #expect(out.toast == nil && out.refusal?.isEmpty == false && started.n == 0)
    }
}

final class LockedCount: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0
    func bump() { lock.lock(); v += 1; lock.unlock() }
    var n: Int { lock.lock(); defer { lock.unlock() }; return v }
}
