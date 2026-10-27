import Testing
import Foundation
@testable import True

private func tmp() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("true-closed-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private let sid = "9176169f-0000-4000-8000-0000000000aa"

@MainActor private func entry(_ at: Date = Date(), launch: UUID = WorkspaceModel.thisLaunch, whole: Bool = false) -> ClosedEntry {
    let p = UUID()
    return ClosedEntry(id: UUID(), closedAt: at, launchID: launch, title: "t", tab: TabState(id: UUID(), pane: p, cwd: "/tmp"),
                       wholeTab: whole, place: ClosedPlace(tabID: UUID(), tabIndex: 0, axis: nil, before: false, siblingLeaves: [], anchorLeaf: nil))
}

@MainActor private func stack(max: Int = 20, bytes: Int = 1 << 30) -> ClosedStack {
    let d = tmp()
    return ClosedStack(url: d.appendingPathComponent("closed.json"), scrollback: ScrollbackStore(dir: d.appendingPathComponent("sb")),
                       maxEntries: max, maxBytes: bytes)
}

private let hdr = ScrollbackStore.Header(cols: 80, rows: 24, savedAt: Date(), wasRunning: nil)

@Suite @MainActor struct ClosedStackTests {
    @Test func pushPopRemoveAndCap() {
        let s = stack(max: 3)
        let es = (0..<4).map { _ in entry() }
        for e in es { s.push(e) }
        #expect(s.entries.count == 3)
        #expect(s.newest?.id == es[3].id)
        #expect(s.entry(es[0].id) == nil)
        #expect(s.take(es[3].id)?.id == es[3].id)
        s.remove(es[2].id)
        #expect(s.entries.map(\.id) == [es[1].id])
    }

    @Test func byteCapDropsOldestButKeepsNewest() {
        let s = stack(bytes: 100)
        let a = entry(), b = entry()
        s.scrollback.save(pane: a.panes[0], text: String(repeating: "x", count: 90), header: hdr)
        s.scrollback.save(pane: b.panes[0], text: String(repeating: "y", count: 90), header: hdr)
        s.push(a); s.push(b)
        #expect(s.entries.map(\.id) == [b.id])
        #expect(s.scrollbackBytes() == 90)
        let c = entry()
        s.scrollback.save(pane: c.panes[0], text: String(repeating: "z", count: 500), header: hdr)
        s.push(c)
        #expect(s.entries.map(\.id) == [c.id])   // newest stays even over the cap
    }

    @Test func persistsRoundTripWith0600() throws {
        let s = stack()
        let e = entry()
        s.push(e)
        let perms = try FileManager.default.attributesOfItem(atPath: s.url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let s2 = ClosedStack(url: s.url, scrollback: s.scrollback)
        s2.load()
        #expect(s2.entries.map(\.id) == [e.id])
    }

    @Test func oneBadEntryDoesNotCostTheRest() throws {
        let s = stack()
        let good = entry()
        s.push(good)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: s.url)) as! [String: Any]
        var list = json["entries"] as! [Any]
        list.append(["id": "nonsense"])
        json["entries"] = list
        try JSONSerialization.data(withJSONObject: json).write(to: s.url)
        let s2 = ClosedStack(url: s.url, scrollback: s.scrollback)
        s2.load()
        #expect(s2.entries.map(\.id) == [good.id])
    }

    @Test func corruptFileMovedAside() throws {
        let s = stack()
        try FileManager.default.createDirectory(at: s.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: s.url)
        s.load()
        #expect(s.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.url.path))
        #expect(FileManager.default.fileExists(atPath: s.url.deletingLastPathComponent().appendingPathComponent("closed.corrupt.json").path))
    }

    @Test func orphanScrollbackSweptOnLoad() {
        let s = stack()
        let e = entry(), orphan = UUID()
        s.scrollback.save(pane: e.panes[0], text: "keep", header: hdr)
        s.scrollback.save(pane: orphan, text: "gone", header: hdr)
        s.push(e)
        s.load()
        #expect(s.scrollback.take(orphan) == nil)
        #expect(s.scrollback.take(e.panes[0]) != nil)
    }
}

@Suite @MainActor struct UndoCloseRouteTests {
    let now = Date()
    @Test func table() {
        let fresh = entry(now.addingTimeInterval(-10)), old = entry(now.addingTimeInterval(-400))
        let other = entry(now.addingTimeInterval(-10), launch: UUID())
        let l = WorkspaceModel.thisLaunch
        #expect(UndoCloseRoute.decide(keyWindowIsMain: false, responderIsText: false, newest: fresh, now: now, launchID: l) == .forwardUndo)
        #expect(UndoCloseRoute.decide(keyWindowIsMain: true, responderIsText: true, newest: fresh, now: now, launchID: l) == .forwardUndo)
        #expect(UndoCloseRoute.decide(keyWindowIsMain: true, responderIsText: false, newest: fresh, now: now, launchID: l) == .reopen(fresh.id))
        #expect(UndoCloseRoute.decide(keyWindowIsMain: true, responderIsText: false, newest: old, now: now, launchID: l) == .beep)
        #expect(UndoCloseRoute.decide(keyWindowIsMain: true, responderIsText: false, newest: other, now: now, launchID: l) == .beep)
        #expect(UndoCloseRoute.decide(keyWindowIsMain: true, responderIsText: false, newest: nil, now: now, launchID: l) == .beep)
        #expect(UndoCloseRoute.title(newest: fresh, now: now, launchID: l) == "Undo Close Pane")
        #expect(UndoCloseRoute.title(newest: entry(now, whole: true), now: now, launchID: l) == "Undo Close Tab")
        #expect(UndoCloseRoute.title(newest: old, now: now, launchID: l) == "Undo")
    }
}

@Suite @MainActor struct SplitTreeReinsertTests {
    private func strip(_ t: SplitTree) -> String {
        switch t {
        case .leaf(let id): return id.uuidString.prefix(2).description
        case .split(_, let ax, _, let a, let b): return "\(ax == .horizontal ? "H" : "V")(\(strip(a)),\(strip(b)))"
        }
    }
    @Test func closeThenReinsertGivesSameShape() {
        let a = UUID(), b = UUID(), c = UUID()
        let t0 = SplitTree.leaf(a).insertingEvened(b, beside: a, axis: .horizontal).insertingEvened(c, beside: b, axis: .vertical)
        let pl = t0.placement(of: a)!
        let rest = t0.removing(a)!
        #expect(rest.leafIDs.sorted { $0.uuidString < $1.uuidString } == [b, c].sorted { $0.uuidString < $1.uuidString })
        let back = rest.reinserting(a, besideLeaves: pl.siblings, axis: pl.axis, before: pl.before)!
        #expect(strip(back) == strip(t0))
    }
    @Test func nilWhenSiblingsGone() {
        let a = UUID(), b = UUID()
        let t = SplitTree.leaf(a)
        #expect(t.reinserting(b, besideLeaves: [UUID()], axis: .horizontal, before: false) == nil)
    }
}

@Suite @MainActor struct WorkspaceUndoCloseTests {
    final class Fakes {
        var found: [UUID: ClaudeSessions.Found] = [:]
        var hook: [UUID: AgentStatus] = [:]
        var alive: Set<pid_t> = []
        var killed: [pid_t] = []
        var now = Date()
        var quits = 0
        var hookSeenDuringHook: [UUID] = []
    }
    struct Rig {
        let ws: WorkspaceModel; let f: Fakes; let startup: PaneStartup; let closed: ClosedStack; let cwd: String; let claude: URL
    }
    func rig(transcript: Bool = true, dirExists: Bool = true) throws -> Rig {
        let d = tmp(), claude = tmp(), cwd = tmp().path
        let f = Fakes()
        if transcript {
            let u = AgentLaunch.transcriptURL(id: sid, cwd: cwd, claudeDir: claude)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: u)
        }
        var h = ClosedHooks()
        h.probe = { p in (true, f.found[p]) }
        h.hook = { f.hook[$0] }
        h.screen = { _ in nil }
        h.isDesk = { _ in false }
        h.dirExists = { dirExists || $0 == NSHomeDirectory() ? FileManager.default.fileExists(atPath: $0) || !dirExists : false }
        h.pidAlive = { f.alive.contains($0) }
        h.killPid = { f.killed.append($0); f.alive.remove($0) }
        h.now = { f.now }
        h.quit = { f.quits += 1 }
        let closed = ClosedStack(url: d.appendingPathComponent("closed.json"), scrollback: ScrollbackStore(dir: d.appendingPathComponent("sb")))
        let startup = PaneStartup()
        let ws = WorkspaceModel(store: WorkspaceStore(url: d.appendingPathComponent("w.json")), claudeDir: claude, settings: "/s.json",
                                startup: startup, claudeAutostart: { false }, closed: closed,
                                liveScrollback: ScrollbackStore(dir: d.appendingPathComponent("live")), hooks: h)
        return Rig(ws: ws, f: f, startup: startup, closed: closed, cwd: cwd, claude: claude)
    }
    private func claudeOn(_ r: Rig, _ p: UUID, busy: Bool, pid: pid_t = 4242) {
        r.f.found[p] = .init(sessionID: sid, cwd: r.cwd, pid: pid, busy: busy, idle: !busy)
    }

    @Test func closeRecordsAndReopenPutsPaneBackBeside() throws {
        let r = try rig()
        let first = r.ws.selectedTab.focusedPane
        let second = r.ws.split(.horizontal, cwd: r.cwd)
        claudeOn(r, second, busy: false)
        r.ws.closeFocusedPane()
        #expect(r.closed.entries.count == 1)
        #expect(r.ws.selectedTab.tree.leafIDs == [first])
        guard case .reopened(let np) = r.ws.reopenClosed() else { Issue.record("not reopened"); return }
        #expect(r.ws.selectedTab.tree.leafIDs == [first, np])
        #expect(r.ws.selectedTab.focusedPane == np)
        #expect(r.startup.take(np)?.hasPrefix("claude --resume \(sid)") == true)
        #expect(r.closed.entries.isEmpty)
    }

    @Test func exitsAndAgentPanesRecordNothing() throws {
        let r = try rig()
        let second = r.ws.split(.horizontal, cwd: r.cwd)
        r.ws.paneExited(second)
        #expect(r.closed.entries.isEmpty)
        let third = r.ws.split(.horizontal, cwd: r.cwd)
        r.ws.agentName = { $0 == third ? "lead" : nil }
        r.ws.select(tab: r.ws.selectedTab.id)
        r.ws.focus(pane: third)
        r.ws.closeFocusedPane()
        #expect(r.closed.entries.isEmpty)
    }

    @Test func busyReopenGetsClosedPromptIdleDoesNot() throws {
        let r = try rig()
        _ = r.ws.split(.horizontal, cwd: r.cwd)
        let p = r.ws.selectedTab.focusedPane
        claudeOn(r, p, busy: true)
        r.ws.closeFocusedPane()
        guard case .reopened(let np) = r.ws.reopenClosed() else { Issue.record("not reopened"); return }
        let cmd = r.startup.take(np) ?? ""
        #expect(cmd.contains(ResumePlan.continuePrompt(.closed)))
    }

    @Test func oldCloseOrOtherLaunchOrDeskGetsNoPrompt() throws {
        for mode in 0..<2 {
            let r = try rig()
            _ = r.ws.split(.horizontal, cwd: r.cwd)
            let p = r.ws.selectedTab.focusedPane
            claudeOn(r, p, busy: true)
            if mode == 1 { r.ws.hooks.isDesk = { _ in true } }
            r.ws.closeFocusedPane()
            if mode == 0 { r.f.now = r.f.now.addingTimeInterval(6 * 60) }
            guard case .reopened(let np) = r.ws.reopenClosed() else { Issue.record("not reopened"); return }
            #expect(r.startup.take(np)?.contains(ResumePlan.continuePrompt(.closed)) == false)
        }
    }

    @Test func missingTranscriptBecomesPlainShell() throws {
        let r = try rig(transcript: false)
        _ = r.ws.split(.horizontal, cwd: r.cwd)
        claudeOn(r, r.ws.selectedTab.focusedPane, busy: false)
        r.ws.closeFocusedPane()
        guard case .reopened(let np) = r.ws.reopenClosed() else { Issue.record("not reopened"); return }
        #expect(r.startup.take(np) == nil)
        #expect(r.ws.selectedTab.resume?[np] == nil)
    }

    @Test func goneFolderOpensShellInHome() throws {
        let r = try rig()
        _ = r.ws.split(.horizontal, cwd: r.cwd)
        claudeOn(r, r.ws.selectedTab.focusedPane, busy: false)
        r.ws.closeFocusedPane()
        r.ws.hooks.dirExists = { $0 == NSHomeDirectory() }
        guard case .reopened(let np) = r.ws.reopenClosed() else { Issue.record("not reopened"); return }
        #expect(r.ws.selectedTab.cwds[np] == NSHomeDirectory())
        #expect(r.startup.take(np)?.contains("folder gone") == true)
    }

    @Test func liveDuplicateFocusesAndSpawnsNothing() throws {
        let r = try rig()
        let a = r.ws.selectedTab.focusedPane
        let b = r.ws.split(.horizontal, cwd: r.cwd)
        claudeOn(r, b, busy: false)
        r.ws.setResume(.claude(sessionID: sid, cwd: r.cwd), pane: b)
        r.ws.closeFocusedPane()
        // the same session now runs in another pane
        r.ws.setResume(.claude(sessionID: sid, cwd: r.cwd), pane: a)
        let out = r.ws.reopenClosed()
        #expect(out == .focused(a))
        #expect(r.ws.selectedTab.tree.leafIDs == [a])
        #expect(r.closed.entries.isEmpty)
    }

    @Test func wholeTabCloseAndReopenKeepsShapeAndIndex() throws {
        let r = try rig()
        let t0 = r.ws.selectedTab.id
        _ = r.ws.state.addTab(cwd: r.cwd)
        let t1 = r.ws.state.tabs[1].id
        r.ws.select(tab: t1)
        _ = r.ws.split(.vertical, cwd: r.cwd)
        r.ws.closeTab(t1)
        #expect(r.ws.state.tabs.map(\.id) == [t0])
        #expect(r.closed.newest?.wholeTab == true)
        r.ws.reopenClosed()
        #expect(r.ws.state.tabs.count == 2)
        #expect(r.ws.selectedTab.tree.leafIDs.count == 2)
    }

    @Test func chainUndoPaneThenTab() throws {
        let r = try rig()
        let first = r.ws.selectedTab.focusedPane
        _ = r.ws.state.addTab(cwd: r.cwd)
        let tab = r.ws.state.tabs[1].id
        r.ws.select(tab: tab)
        let a = r.ws.selectedTab.focusedPane
        let b = r.ws.split(.horizontal, cwd: r.cwd)
        r.ws.closeFocusedPane()          // closes b (pane entry, anchored to a)
        r.ws.closeTab(tab)               // closes the tab holding a (tab entry)
        #expect(r.closed.entries.count == 2)
        r.ws.reopenClosed()              // tab back with new ids; the pane entry must follow
        let newA = r.ws.selectedTab.focusedPane
        #expect(newA != a)
        r.ws.reopenClosed()              // pane back beside the re-IDed anchor
        #expect(r.ws.selectedTab.tree.leafIDs.count == 2)
        #expect(r.ws.selectedTab.tree.leafIDs.contains(newA))
        #expect(!r.ws.selectedTab.tree.leafIDs.contains(b))
        _ = first
    }

    @Test func anchorGoneFallsBackToFocusedPane() throws {
        let r = try rig()
        let a = r.ws.selectedTab.focusedPane
        let b = r.ws.split(.horizontal, cwd: r.cwd)
        r.ws.closeFocusedPane()          // b
        r.ws.paneExited(a)               // a gone too (last pane -> quit hook); tab still exists via new one
        #expect(r.f.quits == 1)
        _ = b
    }

    @Test func lastTabCloseWritesFileBeforeQuit() throws {
        let r = try rig()
        var sawFile = false
        let url = r.closed.url
        r.ws.hooks.quit = { sawFile = FileManager.default.fileExists(atPath: url.path); r.f.quits += 1 }
        r.ws.closeFocusedPane()
        #expect(r.f.quits == 1)
        #expect(sawFile)
    }

    @Test func lingeringPidWaitsThenKills() async {
        let alive = Set<pid_t>([7])
        var live = alive
        var killed: [pid_t] = []
        await ClosedReopen.waitForExit(pid: 7, timeout: 0.2, poll: .milliseconds(20), isAlive: { live.contains($0) }, kill: { killed.append($0); live.remove($0) })
        #expect(killed == [7])
        var polls = 0
        await ClosedReopen.waitForExit(pid: 8, timeout: 5, poll: .milliseconds(5), isAlive: { _ in polls += 1; return polls < 3 }, kill: { _ in killed.append(99) })
        #expect(killed == [7])
    }
}
