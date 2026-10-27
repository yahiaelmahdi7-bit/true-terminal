import SwiftUI
import AppKit

@main
struct TrueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = WorkspaceModel.shared
    private let registry = AgentRegistry.shared

    private static func ago(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    var body: some Scene {
        Window("True", id: "main") {
            // The Hub is a centered pop-up over the terminal (HubOverlay: scrim + glass card); the terminal never resizes.
            TerminalArea(model: model)
                .overlay { HubOverlay(registry: registry) }
            // Content stays below the title-bar zone: on macOS 26 SwiftUI lays views out there under
            // `.ignoresSafeArea` but never paints them (a red test strip never reached the screen).
            // The tab numbers live in that zone as an AppKit-hosted view instead (`installTabs`).
            .background { Theme.background.ignoresSafeArea(); WindowConfigurator().frame(width: 0, height: 0) }
            .background(MainWindowMarker().frame(width: 0, height: 0))
            .preferredColorScheme(.dark)
            .frame(minWidth: 480, minHeight: 300)
            .overlay { ProjectPaletteHost() }
            .overlay { CommandBarHost() }
            .sheet(item: Bindable(registry).builder) { AgentBuilderSheet(draft: $0, registry: registry) }
            .sheet(isPresented: Bindable(ContextCleaner.shared).isOpen) { CleanerSheet(cleaner: ContextCleaner.shared) }
            .sheet(isPresented: Bindable(ResultsStore.shared).isOpen) { ResultsSheet(store: ResultsStore.shared) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { model.newTab() }.keyboardShortcut("t")
                Button("Open Project…") { ProjectPalette.shared.toggle() }.keyboardShortcut("o")
                Button("Command Bar…") { CommandBarStore.shared.toggle() }.keyboardShortcut("k")
                Button("Close Pane") { model.closeFocusedPane() }.keyboardShortcut("w")
                Button("Reopen Closed Pane") { if model.reopenClosed() == .nothing { NSSound.beep() } }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.closed.entries.isEmpty)
                Menu("Reopen Closed") {
                    ForEach(model.closed.entries.prefix(10)) { e in
                        Button("\(e.title) · \(Self.ago(e.closedAt))") { model.reopenClosed(e.id) }
                    }
                }.disabled(model.closed.entries.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(UndoCloseRoute.title(newest: model.closed.newest, now: Date(), launchID: model.launchID)) {
                    let key = NSApp.keyWindow
                    switch UndoCloseRoute.decide(keyWindowIsMain: key != nil && key === MainWindow.current,
                                                 responderIsText: key?.firstResponder is NSText,
                                                 newest: model.closed.newest, now: Date(), launchID: model.launchID) {
                    case .forwardUndo: NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                    case .reopen(let id): model.reopenClosed(id)
                    case .beep: NSSound.beep()
                    }
                }.keyboardShortcut("z")
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appInfo) {
                Button("Restart to Update") { BuildFreshnessWatcher.shared.requestRestart() }
                    .disabled(!BuildFreshnessWatcher.shared.offersRestart)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Fill All Displays") { MainWindow.fillAllDisplays() }
                    .keyboardShortcut("f", modifiers: [.control, .option, .command])
            }
            CommandMenu("Shell") {
                Button("Split Right") { model.splitFocused(.horizontal) }.keyboardShortcut("d")
                Button("Split Down") { model.splitFocused(.vertical) }.keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Focus Left") { model.moveFocus(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Focus Right") { model.moveFocus(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Focus Up") { model.moveFocus(.up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Focus Down") { model.moveFocus(.down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("Capture Screen") { CaptureController.shared.start() }
                    .keyboardShortcut(CaptureHotKey.primary.keyEquivalent, modifiers: CaptureHotKey.primary.modifiers)
                Button("Screenshots…") { TrayPanelController.shared.toggleExpanded() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Show Shots") { ShotsOverlayController.shared.toggle() }
                    .keyboardShortcut(ShotsHotKey.keyEquivalent, modifiers: ShotsHotKey.eventModifiers)
                Button(TrayPanelController.shared.visible ? "Hide Screenshot Panel" : "Show Screenshot Panel") {
                    TrayPanelController.shared.setVisible(!TrayPanelController.shared.visible)
                }
                Button("Paste Latest Screenshot") { ScreenshotWatcher.shared.pasteLatest() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                Divider()
                Button("Send Clipboard to Phone") { PhoneOutbox.sendClipboard() }
                Button("Remote Access…") { RemoteAccessWindow.shared.show() }
                Button("Peers…") { PeersWindow.shared.show() }
            }
            CommandMenu("Hub") {
                Button(registry.panelOpen ? "Hide Hub" : "Show Hub") { registry.panelOpen.toggle() }.keyboardShortcut("e")
                Button("Needs You") { NeedsYouQueue.shared.trayOpen.toggle() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("New Agent…") { registry.panelOpen = true; registry.builder = BuilderDraft() }
                Button("Context Cleaner…") { ContextCleaner.shared.isOpen = true }
                Button("Show Results") { ResultsStore.shared.open() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Tabs") {
                Button("Next Tab") { model.cycleTab(by: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { model.cycleTab(by: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Tab (Control)") { model.cycleTab(by: 1) }.keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Tab (Control)") { model.cycleTab(by: -1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Tab \(n)") { model.selectTab(number: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
        }
        Settings { SettingsView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var agentSocket: AgentEventSocket?
    private var controlSocket: AgentControlSocket?
    private var peerSocket: PeerSocket?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable starts with no bundle policy; without this it gets no menu bar/Dock icon.
        NSApp.setActivationPolicy(.regular)
        // Launch side effect: lift the 256 open-file default so a slow descriptor leak can't crash True within minutes.
        Subprocess.raiseFileLimit()
        // Launch side effect: bind 127.0.0.1:8801 for the phone view — ONLY when the user turned Remote Access on
        // (default off), so a fresh install never listens.
        RemoteAccess.shared.startIfEnabled()
        // Launch side effect: paint the live Dock tile with the bare cursive T. The bundle icon alone gets
        // boxed into a grey tile by macOS 26; a runtime image is drawn as-is. One-shot, no ongoing cost.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        // Closing the main window quits True, and its views may be dismantled before applicationShouldTerminate.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { n in
            let closing = (n.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                let main = MainWindow.current.map(ObjectIdentifier.init)
                guard MainWindow.shouldSnapshot(closing: closing, main: main) else { return }
                SessionSnapshot.atQuit()
        if WatcherStore.active { WatcherStore.shared.snapshotPending(OverseerStore.shared.standingFailures.compactMap { AbandonedSignals.signal(pane: $0.pane, verdict: $0.verdict) }) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                               queue: .main) { n in
            guard let w = n.object as? NSWindow else { return }
            Task { @MainActor in
                guard MainWindow.shouldHideButtons(window: ObjectIdentifier(w),
                                                   main: MainWindow.current.map(ObjectIdentifier.init)) else { return }
                WindowChrome.hideButtons(w)
            }
        }
        // The only launch-time side effect of Agents mode: a listening socket. It is event-driven
        // (blocks in accept) and costs nothing until an awake agent's hook rings it; it wakes nobody.
        agentSocket = AgentEventSocket(path: AgentPaths.standard.socketPath) { e in
            Task { @MainActor in
                AgentRegistry.shared.handle(e)
                OverseerStore.shared.handle(e)
            }
        }
        _ = agentSocket?.start()
        // Same kind of side effect, for `truectl`: one more thread parked in accept() — 0% idle, nothing
        // polls. It only acts when an awake agent runs `truectl summon`, and the reply says who was woken.
        controlSocket = AgentControlSocket(path: AgentPaths.standard.controlSocketPath, registry: AgentRegistry.shared)
        _ = controlSocket?.start()
        // `true-peer`: same shape, for delegating to a paired friend's True. The engine is built only on first use.
        peerSocket = PeerSocket(path: PeerCLI.socketPath(.standard)) { PeerService.engine }
        _ = peerSocket?.start()
        PeerCLI.install(paths: .standard)
        PeerService.startIfPaired()
        AgentHooks.installClient(paths: AgentPaths.standard)   // the door's client, before any agent wakes
        AgentHooks.installPaneHooks(paths: AgentPaths.standard)  // two small files, rewritten only if stale
        // The Hub's data: one directory scan plus a few kqueue watches on ~/.claude/sessions and
        // ~/.claude/builders — event-driven, 0% CPU when idle, no timer. Read-only; never opens *.key.
        HubStore.shared.start()
        // Cloud jobs (true-factory on streambox): a slow poll (60 s idle) so needsYou/done can notify. Read-only until you act.
        CloudStore.shared.start()
        // The Watcher: events only (builder changes, the WorkAwake tick, dropped Overseer failures). Nothing runs while it is off.
        if AgentRegistry.shared.agent(named: Duty.watcherName) == nil { AgentRegistry.shared.save(Duty.watcherAgent()) }
        WatcherStore.active = true
        OverseerStore.shared.onDropped = { pane, v in Task { @MainActor in WatcherStore.shared.abandoned(pane: pane, verdict: v) } }
        Task { @MainActor in await WatcherStore.shared.replayPending(); WatcherStore.shared.digestIfDue() }
        // Wake from sleep is a trigger too (events only, no timer).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in WatcherStore.shared.checkStuck() }
        }
        // The screen stays on (so it never locks) only while agents work (IdleGate); 120 s after everything
        // is idle it is released and the Mac follows its normal sleep timers. Event-driven; the exit drops it.
        WorkAwake.shared.start()
        // One kqueue watch on the screenshot folder: 0% CPU when idle, and it is what makes "fresh" possible.
        ScreenshotWatcher.shared.start()
        // The always-on screenshot panel: one non-activating floating window, shown at launch (0% idle; it
        // redraws only when the tray changes). Hidden/shown by the Shell menu, remembered in UserDefaults.
        TrayPanelController.shared.start()
        // The Shots overlay's global hotkey: one Carbon registration at launch, no Accessibility permission, 0% idle.
        ShotsHotKeyRegistrar.shared.register()
        CaptureHotKeyRegistrar.shared.register()
        // One vnode watch on our own executable (+ one stat on activation): 0% idle. It only flips a flag that
        // shows the "Restart to update" pill; it never restarts anything by itself.
        BuildFreshnessWatcher.shared.start()
        // Public build only (Info.plist TrueUpdateRepo): fetch new releases in the background. No key, no network.
        Updater.shared.start()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Before any view is torn down: the shells are still alive, so their Claude children can be found.
        SessionSnapshot.atQuit()
        if WatcherStore.active { WatcherStore.shared.snapshotPending(OverseerStore.shared.standingFailures.compactMap { AbandonedSignals.signal(pane: $0.pane, verdict: $0.verdict) }) }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        // Final save so restored tabs carry each shell's latest cwd (not the last debounced one).
        WorkspaceModel.shared.saveNow()
        // Normal quit only: swap in a staged, signature-verified update. Two renames; a failure keeps the old app.
        Updater.shared.installStagedAtQuit()
        agentSocket?.stop()
        controlSocket?.stop()
        peerSocket?.stop()
    }
}
