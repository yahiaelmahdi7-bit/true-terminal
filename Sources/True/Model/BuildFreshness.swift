import AppKit
import Foundation
import Observation
import os

/// Identity of the executable file: which inode and when it last changed. `scripts/package.sh` replaces
/// the whole .app, so a rebuild changes at least one of the two (or removes the file).
struct BinaryStamp: Equatable, Sendable {
    var inode: UInt64
    var modified: Date

    static func read(_ url: URL) -> BinaryStamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let t = st.st_mtimespec
        return BinaryStamp(inode: UInt64(st.st_ino),
                           modified: Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9))
    }
}

/// Pure decisions for "restart to update".
enum BuildFreshness {
    /// Stale = the file on disk is no longer the one this process started from. `nil` = file is gone.
    static func isStale(launched: BinaryStamp, current: BinaryStamp?) -> Bool { current != launched }

    /// Detached `/bin/sh` that waits for `pid` to exit (gives up after ~60 s, so a cancelled quit leaks
    /// nothing), then reopens the bundle only if the pid is really gone. pid and path travel as
    /// positional args ($1, $2), never interpolated into the script. No `open -n`: two Trues at once
    /// would race on workspace.json.
    static func relauncherArguments(pid: Int32, bundlePath: String) -> [String] {
        ["-c", "i=0; while kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ \"$i\" -ge 300 ] && exit 0; sleep 0.2; done; /usr/bin/open \"$2\"", "sh", String(pid), bundlePath]
    }

    /// Wording of the pre-restart question; nil when no Claude session in True is mid-task.
    static func workingWarning(_ working: Int) -> String? {
        guard working > 0 else { return nil }
        let who = working == 1 ? "1 Claude session in True is" : "\(working) Claude sessions in True are"
        return "\(who) mid-task. They will pick up where they left off after the restart."
    }

    /// Everything below `root` in the process tree, BFS, cycle-safe, `maxDepth` levels deep.
    /// 6 levels: True, login, shell, a `claude` launcher script, claude, with headroom.
    static func descendants(of root: pid_t, children: (pid_t) -> [pid_t], maxDepth: Int = 6) -> Set<pid_t> {
        var seen: Set<pid_t> = [root], level = [root]
        for _ in 0..<maxDepth {
            level = level.flatMap(children).filter { seen.insert($0).inserted }
            if level.isEmpty { break }
        }
        seen.remove(root)
        return seen
    }

    /// posix_spawn with POSIX_SPAWN_SETSID: the child gets its own session and process group, so it is
    /// not reaped with True's group and keeps running after True exits. CLOEXEC_DEFAULT plus /dev/null on
    /// 0-2 means it inherits none of True's fds (PTY masters, listening sockets). False if the spawn failed.
    static func spawnDetached(_ executable: String, _ args: [String]) -> Bool {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return false }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 {
            guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) == 0 else { return false }
        }
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attr, argv, environ) == 0
    }
}

/// Watches the running executable; once it changes on disk, `stale` flips true (one-way) and the tab bar
/// offers "Restart to update". Event-driven: one vnode source, cancelled on first detection, plus a single
/// stat when the app becomes active as a backstop. No timers.
@MainActor @Observable
final class BuildFreshnessWatcher {
    static let shared = BuildFreshnessWatcher()

    private(set) var stale = false
    @ObservationIgnored private let log = Logger(subsystem: "True", category: "update")
    @ObservationIgnored private var launched: BinaryStamp?
    @ObservationIgnored private var exeURL: URL?
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    /// Restart is only offered from a real .app bundle; a bare `swift run` binary just logs.
    var canRestart: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    /// Pill and menu item show/enable on this.
    var offersRestart: Bool { stale && canRestart }

    func start() {
        guard launched == nil, let url = Bundle.main.executableURL, let stamp = BinaryStamp.read(url) else { return }
        launched = stamp; exeURL = url
        let fd = open(url.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename, .write], queue: .main)
            s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.markStale() } }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
        }
        // Backstop for a swap the vnode watch missed: one stat on activation.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
    }

    func recheck() {
        guard !stale, let launched, let exeURL else { return }
        if BuildFreshness.isStale(launched: launched, current: BinaryStamp.read(exeURL)) { markStale() }
    }

    private func markStale() {
        guard !stale else { return }
        stale = true
        source?.cancel(); source = nil
        if let o = activeObserver { NotificationCenter.default.removeObserver(o); activeObserver = nil }
        log.notice("binary on disk changed since launch; restart to update")
    }

    /// Busy Claude sessions that live under True's own process: the only work a restart interrupts.
    /// (Detached builders and sessions in other apps survive it; seats are covered by their session.)
    private func workingCount() -> Int {
        let mine = BuildFreshness.descendants(of: getpid(), children: ClaudeSessions.liveChildren)
        return HubStore.shared.peers.filter { $0.busy && mine.contains($0.pid) }.count
    }

    /// Dialog text, nil when nothing is mid-work.
    var warning: String? { BuildFreshness.workingWarning(workingCount()) }

    /// The pill / menu entry point: ask first if sessions are mid-task, else go.
    func requestRestart() {
        guard offersRestart else { return }
        if let warning {
            let alert = NSAlert()
            alert.messageText = "Restart True?"
            alert.informativeText = warning
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        restart()
    }

    /// Spawn the relauncher, THEN terminate normally so applicationShouldTerminate records the sessions.
    func restart() {
        let args = BuildFreshness.relauncherArguments(pid: getpid(), bundlePath: Bundle.main.bundleURL.path)
        guard BuildFreshness.spawnDetached("/bin/sh", args) else {
            log.error("restart: could not spawn relauncher; staying open")
            return
        }
        NSApp.terminate(nil)
    }
}
