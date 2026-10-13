import SwiftUI
import AppKit
import SwiftTerm
import Darwin

/// paneID -> live view, weakly held. Lets the model ask "what is this pane's shell doing?"
/// (its pid → cwd) without owning any AppKit views.
@MainActor
final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private final class Box { weak var view: TrueTerminalView?; init(_ v: TrueTerminalView) { view = v } }
    private var views: [UUID: Box] = [:]

    func register(_ id: UUID, _ v: TrueTerminalView) { views[id] = Box(v) }
    func unregister(_ id: UUID, _ v: TrueTerminalView) {
        if views[id]?.view === v { views[id] = nil }
    }
    func view(for id: UUID) -> TrueTerminalView? { views[id]?.view }

    /// The shell's current directory, read from the kernel (no shell cooperation needed).
    func cwd(of id: UUID) -> String? {
        guard let pid = view(for: id)?.process.shellPid, pid > 0 else { return nil }
        return Self.cwd(ofPid: pid)
    }

    nonisolated static func cwd(ofPid pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}

/// One terminal pane: SwiftTerm running the user's login shell in `startDir`.
struct EmbeddedTerminal: NSViewRepresentable {
    let paneID: UUID
    let startDir: String
    let isFocused: Bool
    /// Its tab is the selected one. A background tab's pane keeps its shell but does not paint.
    let isVisible: Bool

    @AppStorage(TerminalSettings.fontFamilyKey) private var family = TerminalSettings.systemMono
    @AppStorage(TerminalSettings.fontSizeKey) private var fontSize = TerminalSettings.defaultFontSize
    @AppStorage(TerminalSettings.cursorKey) private var cursor = TerminalSettings.Cursor.steadyBlock.rawValue
    @AppStorage(TerminalSettings.scrollbackKey) private var scrollback = TerminalSettings.defaultScrollback
    @AppStorage(TerminalSettings.colorKey) private var color = TerminalSettings.defaultColor

    /// The pane's claude-burn token: filename-safe, short, and the same for the same pane every launch.
    nonisolated static func burnToken(_ pane: UUID) -> String { "true-" + pane.uuidString.prefix(8).lowercased() }

    func makeCoordinator() -> Coordinator { Coordinator(paneID: paneID) }

    func makeNSView(context: Context) -> TrueTerminalView {
        TrueTerminalView.installEventMonitor()
        let term = TrueTerminalView(frame: .zero)
        term.paneID = paneID
        term.applyThemeColors()
        term.hideScroller()
        term.enableDrops()
        term.processDelegate = context.coordinator
        term.getTerminal().changeScrollback(TerminalSettings.clampScrollback(scrollback))
        term.font = TerminalSettings.font(family: family, size: fontSize)
        term.getTerminal().setCursorStyle((TerminalSettings.Cursor(rawValue: cursor) ?? .steadyBlock).style)

        let pane = paneID
        term.onFocusClick = { Task { @MainActor in WorkspaceModel.shared.focus(pane: pane) } }
        // One-shot re-read after Return (a `cd` may have run) — no polling timer.
        term.onCommandSubmitted = {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                WorkspaceModel.shared.refreshCwd(pane: pane)
            }
            Task { @MainActor in SessionSnapshot.scheduleAfterReturn(pane: pane) }
        }
        TerminalRegistry.shared.register(paneID, term)

        var env: [String: String] = [:]
        for (k, v) in ProcessInfo.processInfo.environment
        where k != "CLAUDECODE" && !k.hasPrefix("CLAUDE_CODE_") && !k.hasPrefix("BURN_") { env[k] = v }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Every pane names itself so the hook forwarder can say which pane an event came from.
        env["TRUE_PANE_ID"] = paneID.uuidString
        // Pane ids survive restore, so claude-burn in this pane keeps one token (and one HANDOFF-<token>.md)
        // across True restarts instead of orphaning it under a fresh pid token.
        env["BURN_WRAPPER_TOKEN"] = Self.burnToken(paneID)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        ShellIntegration.apply(to: &env, shell: shell)
        let dir = FileManager.default.fileExists(atPath: startDir) ? startDir : NSHomeDirectory()
        // An agent pane runs its launch line instead of an interactive shell (registry set the spec at wake).
        // `-i` matters: `claude` reaches PATH through ~/.zshrc, which only an INTERACTIVE shell reads, so a
        // plain `-l -c` (2026-09-30) failed with "'claude' was not found on PATH" and dropped to a shell.
        // The launch line single-quotes argv[0], so the interactive `claude` alias never expands.
        var args = ["-l"]
        if let spec = AgentRegistry.shared.launchSpecs[paneID] {
            args = ["-l", "-i", "-c", spec.shellCommand]
            env["TRUE_AGENT"] = spec.agent
            // Appended, not prepended: the rc files above prepend their own dirs and must keep winning,
            // but `truectl` has to resolve for the agent's Bash tool whatever they did to PATH.
            let bin = NSHomeDirectory() + "/.true/bin"
            env["PATH"] = env["PATH"].map { "\($0):\(bin)" } ?? bin
        } else if let cmd = PaneStartup.shared.take(paneID) {
            // Open Project ▸ with Claude: interactive login so the user's `claude` alias applies. NOT an agent
            // (no TRUE_AGENT, no launch spec) and the command's own `exec $SHELL -l` keeps the pane alive.
            args = PaneStartup.shellArgs(for: cmd)
        } else if let snap = ScrollbackStore.standard.take(paneID) {
            // A plain shell gets its last screen back (one-shot, files deleted): the shell prints its prompt below.
            let t = term.getTerminal()
            t.resize(cols: snap.header.cols, rows: snap.header.rows)
            term.feed(byteArray: ArraySlice(snap.bytes))
            term.feed(byteArray: ArraySlice(Array(("\r\n" + ScrollbackStore.markerLine(snap.header) + "\r\n").utf8)))
        }
        term.startProcess(executable: shell, args: args,
                          environment: env.map { "\($0.key)=\($0.value)" },
                          execName: nil, currentDirectory: dir)
        term.isFocusedPane = isFocused
        term.setOnScreen(isVisible)
        return term
    }

    func updateNSView(_ term: TrueTerminalView, context: Context) {
        term.isFocusedPane = isFocused
        term.setOnScreen(isVisible)
        let font = TerminalSettings.font(family: family, size: fontSize)
        if term.font != font { term.font = font }
        let style = (TerminalSettings.Cursor(rawValue: cursor) ?? .steadyBlock).style
        if context.coordinator.appliedCursor != cursor {
            context.coordinator.appliedCursor = cursor
            term.getTerminal().setCursorStyle(style)
        }
        let sb = TerminalSettings.clampScrollback(scrollback)
        if context.coordinator.appliedScrollback != sb {
            context.coordinator.appliedScrollback = sb
            term.getTerminal().changeScrollback(sb)
        }
        if context.coordinator.appliedColor != color {
            context.coordinator.appliedColor = color
            term.applyColorMode(color)
        }
        if isFocused, !ProjectPalette.shared.isOpen, let w = term.window, w.firstResponder !== term {
            w.makeFirstResponder(term)
        }
    }

    static func dismantleNSView(_ term: TrueTerminalView, coordinator: Coordinator) {
        TerminalRegistry.shared.unregister(coordinator.paneID, term)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let paneID: UUID
        var appliedCursor: String?
        var appliedScrollback: Int?
        var appliedColor: Bool?
        init(paneID: UUID) { self.paneID = paneID }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory else { return }
            let id = paneID
            Task { @MainActor in
                let path = URL(string: directory)?.path ?? directory
                WorkspaceModel.shared.updateCwd(pane: id, path)
            }
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let id = paneID
            Task { @MainActor in WorkspaceModel.shared.paneExited(id) }
        }
    }
}
