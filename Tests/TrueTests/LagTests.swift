import Testing
import Foundation
import AppKit
@testable import True

private func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("lag-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func inode(_ u: URL) -> UInt64 { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.systemFileNumber] as? UInt64) ?? 0 }
private func size(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0 }
private func gitItem(_ id: String) -> InboxItem {
    InboxItem(id: id, agent: Duty.watcherName, source: "git", kind: "unpushed", subject: "repo@main", repo: "/tmp/r", fingerprint: "git|unpushed|\(id)",
              title: "t", evidence: "e", report: nil, level: nil, state: .open, seen: 1, at: 1000, cost: 0, note: nil, builderID: nil,
              lookedFixed: false, snoozeUntil: nil, canInvestigate: false)
}

@MainActor @Suite struct MainThreadTests {
    /// A slow `git` (300 ms per call) must not hold the main actor: the check yields while it waits.
    @Test func slowGitDoesNotBlockMain() async throws {
        let root = tmp()
        let file = InboxFile(dir: InboxFile.home(agent: Duty.watcherName, root: root)); file.ensureDir()
        for i in 0..<3 { file.append(InboxEvent(.created, id: "g\(i)", at: 1000, item: gitItem("g\(i)"))) }
        var deps = WatcherStore.Deps()
        deps.root = root
        let calls = Box(0), onMain = Box(0)
        deps.git = { _ in calls.mutate { $0 += 1 }; if Thread.isMainThread { onMain.mutate { $0 += 1 } }
                          Thread.sleep(forTimeInterval: 0.3); return nil }
        deps.enabled = { true }
        let store = WatcherStore(deps: deps)

        let t0 = Date()
        store.checkStuck(builders: [])
        #expect(Date().timeIntervalSince(t0) < 0.010, "checkStuck must return immediately")

        // The rule itself, not a stopwatch: wall-clock pings flaked in full runs, where other @MainActor
        // suites hold the main thread for 250-390 ms regardless of this check (6 of 12 runs, 2026-10-11).
        await store.checkTask?.value
        #expect(calls.value > 0, "the check never ran git, so the test proves nothing")
        #expect(onMain.value == 0, "git ran on the main thread \(onMain.value) time(s)")
    }

    /// A tick that arrives while a check is still running is skipped, not queued.
    @Test func overlappingChecksAreSkipped() async throws {
        let root = tmp()
        let file = InboxFile(dir: InboxFile.home(agent: Duty.watcherName, root: root)); file.ensureDir()
        file.append(InboxEvent(.created, id: "g0", at: 1000, item: gitItem("g0")))
        let calls = Box(0)
        var deps = WatcherStore.Deps()
        deps.root = root; deps.enabled = { true }
        deps.git = { _ in calls.mutate { $0 += 1 }; Thread.sleep(forTimeInterval: 0.2); return nil }
        let store = WatcherStore(deps: deps)
        store.checkStuck(builders: [])
        try await Task.sleep(nanoseconds: 50_000_000)
        store.checkStuck(builders: [])
        store.checkStuck(builders: [])
        await store.checkTask?.value
        // one item -> branchesArgv lookup only (nil stops it): exactly one git call for the one check
        #expect(calls.value == 1)
    }

    @Test func inboxChangeAppendsOnly() throws {
        let root = tmp()
        var deps = WatcherStore.Deps()
        deps.root = root; deps.enabled = { true }
        let file = InboxFile(dir: InboxFile.home(agent: Duty.watcherName, root: root)); file.ensureDir()
        for i in 0..<50 { file.append(InboxEvent(.created, id: "g\(i)", at: 1000, item: gitItem("g\(i)"))) }
        let store = WatcherStore(deps: deps)
        let before = try Data(contentsOf: file.url), ino = inode(file.url)
        store.reject("g7", reason: "Already handled")
        let after = try Data(contentsOf: file.url)
        #expect(inode(file.url) == ino, "file was replaced (whole-file rewrite)")
        #expect(after.prefix(before.count) == before, "existing bytes changed")
        #expect(after.count - before.count < 600, "one change wrote \(after.count - before.count) bytes")
        #expect(store.items.first { $0.id == "g7" }?.state == .resolved)
    }
}

@Suite struct JSONLogTests {
    @Test func appendIsOrderRecordBytes() throws {
        let dir = tmp(), u = dir.appendingPathComponent("a.jsonl")
        var last = 0, total = 0
        for i in 0..<1000 {
            let line = Data("{\"n\":\(i),\"pad\":\"xxxxxxxxxxxxxxxxxxxx\"}\n".utf8)
            JSONLog.append(line, to: u, maxBytes: 10 << 20, keep: 2)
            let s = size(u)
            #expect(s - last == line.count)       // delta is exactly this record
            last = s; total += line.count
        }
        #expect(total == last)
        #expect(JSONLog.writeCount(for: u) == 1000)
        #expect(((try FileManager.default.attributesOfItem(atPath: u.path))[.posixPermissions] as? Int) == 0o600)
    }

    @Test func rotatesAtCapKeepingTwo() throws {
        let dir = tmp(), u = dir.appendingPathComponent("r.jsonl")
        let line = Data(String(repeating: "x", count: 99).utf8 + [10])      // 100 bytes
        for _ in 0..<1000 { JSONLog.append(line, to: u, maxBytes: 10_000, keep: 2) }
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("r.1.jsonl").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("r.2.jsonl").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("r.3.jsonl").path))
        #expect(size(u) <= 10_000 + 100)
        #expect(size(dir.appendingPathComponent("r.1.jsonl")) <= 10_100)
    }

    @Test func overseerLogAppendsAndUsesOneMegCap() {
        #expect(OverseerLog.maxBytes == 1 << 20)
    }
}

@Suite struct OffMainTests {
    /// `dispatchPrecondition` would kill the test process, so the rule is a pure check the runners also assert.
    @Test @MainActor func mainThreadViolates() {
        #expect(OffMain.violatesNow())
    }
    @Test func backgroundIsFine() async {
        let v = await Task.detached { OffMain.violatesNow() }.value
        #expect(!v)
    }
}

/// The paint budget (2026-10-14): the focused pane paints every frame, other visible panes ≤30 Hz,
/// background tabs not at all.
@Suite struct FramePacingTests {
    @Test func focusedPaneAlwaysPaints() {
        #expect(FramePacing.shouldFlush(isFocused: true, now: 10, lastFlush: 10, focusedPaintingThisFrame: true))
    }
    @Test func backgroundPaneIsCappedAt30Hz() {
        #expect(!FramePacing.shouldFlush(isFocused: false, now: 10.02, lastFlush: 10, focusedPaintingThisFrame: false))
        #expect(FramePacing.shouldFlush(isFocused: false, now: 10.04, lastFlush: 10, focusedPaintingThisFrame: false))
    }
    @Test func backgroundYieldsToAKeystrokeFrameButOnlyBriefly() {
        #expect(!FramePacing.shouldFlush(isFocused: false, now: 10.05, lastFlush: 10, focusedPaintingThisFrame: true))
        #expect(FramePacing.shouldFlush(isFocused: false, now: 10.11, lastFlush: 10, focusedPaintingThisFrame: true))
    }
    @Test func idleBackgroundPanePaintsAtOnce() {
        #expect(FramePacing.shouldFlush(isFocused: false, now: 500, lastFlush: 0, focusedPaintingThisFrame: true))
    }
}

@MainActor @Suite struct HiddenPaneTests {
    /// A background tab's pane swallows invalidations (no AppKit paint) and owes one repaint.
    @Test func hiddenPaneDoesNotPaint() {
        let term = TrueTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        term.setOnScreen(false)
        #expect(term.isHidden)
        term.needsDisplay = false
        term.setNeedsDisplay(NSRect(x: 0, y: 0, width: 400, height: 20))
        #expect(term.owesRepaint)
        #expect(!term.needsDisplay, "a hidden pane reached AppKit's paint queue")
    }

    /// Revealing it pays the debt with one paint, in the same pass as the tab switch.
    @Test func revealPaysTheOwedRepaint() {
        let term = TrueTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        term.setOnScreen(false)
        term.setNeedsDisplay(NSRect(x: 0, y: 0, width: 400, height: 20))
        #expect(term.lastCoalescedFlush == 0)
        term.setOnScreen(true)
        #expect(!term.isHidden)
        #expect(!term.owesRepaint)
        // A windowless view never reports `needsDisplay`, so assert the flush itself ran.
        #expect(term.lastCoalescedFlush > 0)
    }

    /// Nothing changed while hidden → the reveal paints nothing.
    @Test func cleanRevealPaintsNothing() {
        let term = TrueTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        term.setOnScreen(false)
        term.needsDisplay = false
        term.setOnScreen(true)
        #expect(!term.needsDisplay)
    }
}
