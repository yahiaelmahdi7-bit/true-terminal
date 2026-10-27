import Foundation
import AppKit
import Darwin
import os

/// The seams undo-close reads from the live app. Tests replace them with fakes (a fake process tree, a fake clock).
@MainActor
struct ClosedHooks {
    var probe: (UUID) -> (alive: Bool, found: ClaudeSessions.Found?) = { SessionSnapshot.probe($0) }
    var hook: (UUID) -> AgentStatus? = { SessionSnapshot.hookStatus($0) }
    /// The pane's shell screen as text, if its view is alive.
    var screen: (UUID) -> (text: String, header: ScrollbackStore.Header)? = { SessionSnapshot.screen($0) }
    /// A peer desk pane resumes quietly: no continue prompt.
    var isDesk: (UUID) -> Bool = { PeerOrigin.shared.label(for: $0) != nil }
    var dirExists: (String) -> Bool = { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
    var pidAlive: (pid_t) -> Bool = { kill($0, 0) == 0 }
    var killPid: (pid_t) -> Void = { _ = Darwin.kill(-$0, SIGKILL); _ = Darwin.kill($0, SIGKILL) }
    var now: () -> Date = { Date() }
    var quit: () -> Void = { NSApp.terminate(nil) }
}

extension WorkspaceModel {
    static let thisLaunch = UUID()
    private static let closeLog = Logger(subsystem: "True", category: "restore")
    /// A pid older than this may belong to someone else by now: never wait on or kill it.
    static let pidTrustWindow: TimeInterval = 30

    enum ReopenOutcome: Equatable {
        case nothing
        /// Reopened; the focused pane.
        case reopened(UUID)
        /// The session was already live in this pane; it got focus and nothing was started.
        case focused(UUID)
        /// The old process is still exiting; the reopen finishes when it is gone.
        case waiting
    }

    // MARK: Capture

    private struct Captured { var resume: PaneResume?; var interrupted: Bool; var pids: [pid_t] }

    /// One pane's state at close, from the same calls the quit snapshot makes. nil for agent panes.
    private func captureOne(_ pane: UUID, in tab: TabState) -> Captured? {
        if agentName?(pane) != nil { return nil }
        refreshCwd(pane: pane)
        let (alive, found) = hooks.probe(pane)
        let previous = tab.resume?[pane]
        let rec = SessionRecorder.decide(previous: previous, agent: nil, alive: alive, found: found, mode: paneMode?(pane))
        if case .claude = previous, found == nil, alive { Self.closeLog.notice("undo-close: no claude found for \(pane.uuidString.prefix(8), privacy: .public)") }
        var interrupted = false
        if case .claude? = rec {
            interrupted = !hooks.isDesk(pane) && SessionRecorder.isInterrupted(found: found, hook: hooks.hook(pane))
        } else if let s = hooks.screen(pane) {
            closed.scrollback.save(pane: pane, text: s.text, header: s.header)
        }
        return Captured(resume: rec, interrupted: interrupted, pids: found.map { [$0.pid] } ?? [])
    }

    /// ⌘W: a one-pane slice, with the placement read from the tree before the pane is removed.
    func recordClose(pane: UUID, tabIndex i: Int) {
        let tab = state.tabs[i]
        guard let c = captureOne(pane, in: tab) else { return }
        let cwd = tab.cwds[pane] ?? NSHomeDirectory()
        var slice = TabState(id: UUID(), pane: pane, cwd: cwd)
        slice.resume = c.resume.map { [pane: $0] }
        slice.interrupted = c.interrupted ? [pane] : nil
        let pl = tab.tree.placement(of: pane)
        let place = ClosedPlace(tabID: tab.id, tabIndex: i, axis: pl?.axis, before: pl?.before ?? false,
                                siblingLeaves: pl?.siblings ?? [], anchorLeaf: pl?.siblings.first)
        closed.push(ClosedEntry(id: UUID(), closedAt: hooks.now(), launchID: launchID, title: TabState.basename(cwd),
                                tab: slice, wholeTab: false, place: place), pids: c.pids)
    }

    /// The tab ✕: the whole tab, agent panes dropped from the slice.
    func recordClose(tab: TabState, index i: Int) {
        var slice = tab
        slice.resume = nil; slice.interrupted = nil
        var resume: [UUID: PaneResume] = [:], marks = Set<UUID>(), pids: [pid_t] = []
        for p in tab.tree.leafIDs {
            guard let c = captureOne(p, in: tab) else {
                if let t = slice.tree.removing(p) { slice.tree = t; slice.cwds[p] = nil } else { return }
                continue
            }
            if let r = c.resume { resume[p] = r }
            if c.interrupted { marks.insert(p) }
            pids += c.pids
        }
        slice.resume = resume.isEmpty ? nil : resume
        slice.interrupted = marks.isEmpty ? nil : marks
        if !slice.tree.contains(slice.focusedPane), let f = slice.tree.leafIDs.first { slice.focusedPane = f }
        let place = ClosedPlace(tabID: tab.id, tabIndex: i, axis: nil, before: false, siblingLeaves: [], anchorLeaf: nil)
        closed.push(ClosedEntry(id: UUID(), closedAt: hooks.now(), launchID: launchID, title: slice.title,
                                tab: slice, wholeTab: true, place: place), pids: pids)
    }

    // MARK: Reopen

    /// The pane already running this session, if any (no double resume).
    private func livePane(sessionID: String) -> UUID? {
        for t in state.tabs {
            for (p, r) in t.resume ?? [:] { if case let .claude(id, _, _) = r, id == sessionID { return p } }
        }
        return nil
    }

    /// Bring a close back (`id` nil = the newest). Never asks anything; a Claude pane resumes by the restart path.
    @discardableResult
    func reopenClosed(_ id: UUID? = nil) -> ReopenOutcome {
        guard !frozen, let e = id.flatMap({ closed.entry($0) }) ?? closed.newest else { return .nothing }
        if !e.wholeTab, let p = e.panes.first, case let .claude(sid, _, _)? = e.tab.resume?[p], let live = livePane(sessionID: sid) {
            closed.remove(e.id)
            focus(pane: live)
            return .focused(live)
        }
        let trusted = hooks.now().timeIntervalSince(e.closedAt) < Self.pidTrustWindow
        let lingering = trusted ? (closed.pids[e.id] ?? []).filter(hooks.pidAlive) : []
        closed.take(e.id)
        if lingering.isEmpty { return .reopened(place(e)) }
        let alive = hooks.pidAlive, kill = hooks.killPid
        Task { @MainActor [weak self] in
            for pid in lingering { await ClosedReopen.waitForExit(pid: pid, isAlive: alive, kill: kill) }
            self?.place(e)
        }
        return .waiting
    }

    /// Fresh ids, start commands, then the pane or tab goes back where it was. Returns the focused pane.
    @discardableResult
    private func place(_ e: ClosedEntry) -> UUID {
        let oldPanes = e.panes
        let tabExists = !e.wholeTab && index(of: e.place.tabID) != nil
        var alias: [UUID: UUID] = [:]
        for p in oldPanes { alias[p] = UUID() }
        let newTabID = tabExists ? e.place.tabID : UUID()
        alias[e.place.tabID] = newTabID

        var slice = e.tab
        slice.id = newTabID
        slice.tree = slice.tree.relabeling(alias)
        slice.focusedPane = alias[slice.focusedPane] ?? slice.tree.leafIDs[0]
        var cwds: [UUID: String] = [:], resume: [UUID: PaneResume] = [:], marks = Set<UUID>()
        var gone: [UUID: String] = [:]
        let keepMarks = ClosedReopen.keepsMark(e, now: hooks.now(), launchID: launchID)
        for old in oldPanes {
            guard let new = alias[old] else { continue }
            var cwd = e.tab.cwds[old] ?? NSHomeDirectory()
            var rec = e.tab.resume?[old]
            if case let .claude(sid, rcwd, _)? = rec {
                cwd = rcwd
                if livePane(sessionID: sid) != nil { rec = nil }           // already running elsewhere: a plain shell
            }
            if !hooks.dirExists(cwd) { gone[new] = cwd; cwd = NSHomeDirectory(); rec = nil }
            cwds[new] = cwd
            if let r = rec { resume[new] = r }
            if keepMarks, e.tab.interrupted?.contains(old) == true, rec != nil { marks.insert(new) }
        }
        slice.cwds = cwds
        slice.resume = resume.isEmpty ? nil : resume
        slice.interrupted = marks.isEmpty ? nil : marks

        let plan = ResumePlan.apply(WorkspaceState(tabs: [slice], selectedTab: newTabID),
                                    claudeDir: claudeDir, settings: settings, reason: .closed)
        let done = plan.state.tabs[0]
        let delays = ResumePlan.stagger(plan.startups, continued: plan.continued, state: plan.state)
        for (pane, cmd) in plan.startups {
            let d = delays[pane] ?? 0
            startup.set(PaneStartup.staggered(cmd, after: d), for: pane)
            if d > 0 { wakeDeadlines[pane] = hooks.now().addingTimeInterval(TimeInterval(d) + Self.wakeGrace) }
        }
        wakingContinued.formUnion(plan.continued.filter { wakeDeadlines[$0] != nil })
        for (pane, path) in gone {
            startup.set("printf '\\033[2mfolder gone: %s\\033[0m\\n' \(AgentLaunch.shellQuote(path)); exec \"${SHELL:-/bin/zsh}\" -l", for: pane)
        }
        // Shells: the saved screen moves to the live store under the new id and replays with the restored marker.
        for old in oldPanes {
            guard let new = alias[old] else { continue }
            if done.resume?[new] == nil, gone[new] == nil, let snap = closed.scrollback.take(old) {
                liveScrollback.save(pane: new, text: String(decoding: snap.bytes, as: UTF8.self), header: snap.header)
            } else {
                closed.scrollback.remove(old)
            }
        }
        closed.remap(alias)

        if e.wholeTab || !tabExists {
            var t = done
            if !e.wholeTab { t.customName = nil }
            state.tabs.insert(t, at: min(max(0, e.place.tabIndex), state.tabs.count))
            state.selectedTab = newTabID
            return t.focusedPane
        }
        let new = done.tree.leafIDs[0]
        let j = index(of: newTabID)!
        let tab = state.tabs[j]
        let axis = e.place.axis
        let anchor = e.place.anchorLeaf.flatMap { tab.tree.contains($0) ? $0 : nil }
        let tree = axis.flatMap { tab.tree.reinserting(new, besideLeaves: e.place.siblingLeaves, axis: $0, before: e.place.before) }
            ?? anchor.map { tab.tree.insertingEvened(new, beside: $0, axis: axis ?? .horizontal, before: e.place.before) }
            ?? tab.tree.insertingEvened(new, beside: tab.focusedPane, axis: axis ?? .horizontal)
        state.tabs[j].tree = tree
        state.tabs[j].cwds[new] = done.cwds[new]
        if let r = done.resume?[new] { var m = state.tabs[j].resume ?? [:]; m[new] = r; state.tabs[j].resume = m }
        state.tabs[j].focusedPane = new
        state.selectedTab = newTabID
        return new
    }
}
