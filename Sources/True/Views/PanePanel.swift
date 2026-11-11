import AppKit
import SwiftUI

/// A bento tile: glass over an 85% bg3 fill (pure glass vanishes on True black), solid bg3 under Reduce Transparency.
private struct PanelTile: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var solid = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if reduceTransparency || solid {
            content.background(Theme.Token.bg3, in: shape).overlay(shape.strokeBorder(Theme.Token.line, lineWidth: 1))
        } else {
            content.background(Theme.Token.bg3.opacity(0.85), in: shape).glassSurface(shape)
        }
    }
}

private struct PillSurface: ViewModifier {
    var solid: Bool
    func body(content: Content) -> some View {
        if solid { content.background(Theme.Token.bg3, in: Capsule()).overlay(Capsule().strokeBorder(Theme.Token.line, lineWidth: 1)) }
        else { content.background(Theme.Token.bg3.opacity(0.85), in: Capsule()).glassSurface(Capsule()) }
    }
}

/// One 32 pt row: 16 pt icon in the muted tone, 8 pt gap, 13 pt label.
struct PanelRow<Trailing: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.Token.text2).frame(width: 20)
            Text(label).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Token.text0).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8).frame(height: Theme.Hit.control).contentShape(Rectangle())
    }
}

/// The closed state: branch and "+N −M" in a small glass pill (a folder glyph alone when not in git).
struct PanePill: View {
    let status: PaneGitStatus
    var solid = false   // stills only
    var body: some View {
        HStack(spacing: 6) {
            if status.isRepo {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 12)).foregroundStyle(Theme.Token.text2)
                Text(status.branch).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Token.text0)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                PlusMinus(added: status.added, removed: status.removed)
            } else {
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Theme.Token.text1)
            }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Theme.Token.bg3.opacity(0.0001))
        .modifier(PillSurface(solid: solid))
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.isRepo ? "\(status.branch), \(status.added) added, \(status.removed) removed" : "Folder")
        .accessibilityAddTraits(.isButton)
    }
}

/// The open state: two stacked tiles, 280 pt wide. Pure view; actions come in as closures.
struct PanePanelView: View {
    let status: PaneGitStatus
    var macName = Host.current().localizedName ?? TaskDetailCopy.thisMac
    var editors: [PaneEditor] = []
    var chosenEditor: PaneEditor?
    var shadow = false
    /// Stills: the solid fill (what Reduce Transparency shows); glass can't be drawn off-screen on a flat backdrop.
    var solid = false
    var onReveal: () -> Void = {}
    var onOpenEditor: (PaneEditor) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onChanges: () -> Void = {}
    /// The Agents and Usage tiles sit above Place and Git; nil leaves the panel exactly as it was.
    var agents: [ActivityRow]?
    var usage: UsagePanelData?
    /// Teammates' agents under the Agents tile. Empty = exactly Wedge 1.
    var teammates: [TeammateAgents] = []
    /// Stills: draw the Agents drop-down open.
    var agentsExpanded = false
    /// The Macs on this repo, this Mac first. nil = just this Mac, no folder line. Stand-in data in stills.
    var places: [PlaceRow]?
    var placesExpanded = false
    /// Stills: the clock and calendar the "last seen" line is read against.
    var placesNow = Date()
    var placesCalendar = Calendar.current
    var onOpenAgent: (ActivityRow) -> Void = { _ in }
    /// A teammate's Place row was renamed here (peer id, name). Saved on this Mac only.
    var onRenamePeer: (String, String) -> Void = { id, name in PeerNicknames.load().setting(id: id, name: name).save() }
    var onCheckNow: () -> Void = {}
    var onOpenHistory: () -> Void = {}
    var onOpenTeam: () -> Void = {}
    /// False when every pane shows its own strip: the top panel is then account-wide only (Agents, Usage).
    var showsProject = true

    var body: some View {
        GlassContainer(spacing: 6) {
            VStack(spacing: 6) {
                if let agents { AgentsTile(rows: agents, teammates: teammates, expanded: agentsExpanded, onOpen: onOpenAgent).modifier(PanelTile(solid: solid)) }
                if let usage, usage.showsTile { UsageTile(data: usage, onCheckNow: onCheckNow, onOpenHistory: onOpenHistory, onOpenTeam: onOpenTeam).modifier(PanelTile(solid: solid)) }
                if showsProject {
                    place.modifier(PanelTile(solid: solid))
                    if status.isRepo { git.modifier(PanelTile(solid: solid)) }
                }
            }
        }
        .frame(width: 280)
        .shadow(color: .black.opacity(shadow ? 0.8 : 0), radius: 22, y: 18)
    }

    private var place: some View {
        VStack(spacing: 0) {
            PlaceList(rows: places ?? [PlaceRow(id: "me", name: macName, folder: "", isThisMac: true)],
                      expanded: placesExpanded, now: placesNow, calendar: placesCalendar, onReveal: onReveal, onRename: onRenamePeer)
            if let editor = chosenEditor {
                PanelRow(icon: "chevron.left.forwardslash.chevron.right", label: TaskDetailCopy.openIn(editor.name)) {
                    let chevron = Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Token.text1)
                        .frame(width: 28, height: 28)
                    if shadow { chevron } else {   // stills draw it flat; a Menu renders as a placeholder there
                        Menu {
                            ForEach(editors) { e in Button(e.name) { onOpenEditor(e) } }
                        } label: { chevron }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                .onTapGesture { onOpenEditor(editor) }
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
    }

    private var git: some View {
        VStack(spacing: 0) {
            PanelRow(icon: "arrow.triangle.branch", label: status.branch) { EmptyView() }
                .help(TaskDetailCopy.currentBranch)
            Button(action: onCommit) { PanelRow(icon: "checkmark.circle", label: TaskDetailCopy.panelCommit) { EmptyView() } }
                .buttonStyle(.plain)
            Button(action: onChanges) {
                PanelRow(icon: "doc.text", label: TaskDetailCopy.panelChanges) {
                    if status.showsCounts { PlusMinus(added: status.added, removed: status.removed) }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
    }
}

/// The Commit sheet: a message, "N files", one button, one plain result line. Never pushes.
struct CommitSheet: View {
    let files: Int
    var result: String?
    var onCommit: (String) -> Void = { _ in }
    var onClose: () -> Void = {}
    @State var message = ""
    /// Stills only: a text field can't be drawn off-screen, so show this text in its place.
    var preview: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TaskDetailCopy.panelCommit).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Token.text0)
            Group {
                if let preview { Text(preview).frame(maxWidth: .infinity, alignment: .leading) }
                else { TextField(TaskDetailCopy.messageHint, text: $message, axis: .vertical).lineLimit(3...6) }
            }
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.Token.text0)
                .padding(10).background(Theme.Token.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(TaskDetailCopy.files(files)).font(.system(size: 13)).foregroundStyle(Theme.Token.text1)
            if let result { Text(result).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Token.text0) }
            HStack {
                Spacer()
                Button(result == nil ? TaskDetailCopy.cancel : TaskDetailCopy.done, action: onClose)
                Button { onCommit(message) } label: {
                    Text(TaskDetailCopy.commitAll).font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(height: 28)
                }
                    .buttonStyle(PillButtonStyle(shape: Capsule(), rest: Theme.Token.text0, hover: Theme.Token.text0, fill: Theme.Token.strongLine, hoverFill: Theme.Token.text3.opacity(Theme.Alpha.strongLine)))
                    .keyboardShortcut(.defaultAction)
                    .disabled((preview ?? message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || files == 0)
            }
        }
        .padding(18).frame(width: 340).background(Theme.Token.bg0)
    }
}

/// Follows the focused pane. Reads git off the main thread; refreshes on focus change, on open, and every 3 s
/// only while the pill is on screen and the window is visible.
@MainActor @Observable
final class PaneGitStore {
    var status = PaneGitStatus.notGit
    var busy = false
    func refresh(folder: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let result = await Task.detached(priority: .utility) { PaneGitReader.read(folder: folder) }.value
        if result != status { status = result }
    }
}

struct PanePillHost: View {
    @State private var store = PaneGitStore()
    @State private var open = false
    @State private var committing = false
    @State private var task: TaskTarget?
    @State private var commitResult: String?
    @State private var editors = PaneEditor.installed()
    @State private var activity = AgentActivity.shared
    @State private var usage = UsageStore.shared
    @State private var tray = TrayPanelController.shared
    @State private var natural = CGRect.zero   // the pill's own place, before any shift
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model = WorkspaceModel.shared

    private var usageData: UsagePanelData { UsagePanelData(providers: usage.providers, windows: usage.windows, checking: usage.checking) }

    /// How far the pill slides left to clear the screenshot tray (window space, y down).
    private var trayShift: CGFloat {
        guard let w = MainWindow.current ?? NSApp.keyWindow, let screen = w.screen, let t = tray.restingFrame(on: screen),
              natural != .zero else { return 0 }
        let inWindow = w.convertFromScreen(t)
        let flipped = CGRect(x: inWindow.minX, y: w.frame.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
        return PillAvoidsTray.shift(pill: natural, tray: flipped)
    }

    private var folder: String {
        let tab = model.selectedTab
        return tab.cwds[tab.focusedPane] ?? NSHomeDirectory()
    }

    /// Each pane with a strip shows its own project; the pill carries the focused pane's only when a visible pane is collapsed.
    private var showsProject: Bool {
        let size = PaneStripStore.shared.areaSize
        guard size != .zero else { return true }
        return PaneStrip.pillShowsProject(widths: model.selectedTab.tree.layout(in: size).panes.values.map(\.width))
    }

    var body: some View {
        let folder = folder
        let showsProject = showsProject
        let shift = trayShift
        let teamOpen: () -> Void = {}
        let teammates: [TeammateAgents] = []
        let count = TeammateAgents.badgeCount(own: activity.runningCount, teammates: teammates)
        let idle = AgentsPill.isIdle(running: count, usage: usageData)
        Button { open.toggle(); usage.refresh(); Task { await store.refresh(folder: folder) } } label: {
            AgentsPill(running: count, needsYou: activity.needsYou, idle: idle)
        }
            .buttonStyle(.plain)
            .background(GeometryReader { g in
                let f = g.frame(in: .global)
                Color.clear.onAppear { natural = f.offsetBy(dx: shift, dy: 0) }
                    .onChange(of: f) { _, new in natural = new.offsetBy(dx: shift, dy: 0) }
            })
            .offset(x: -shift)
            .animation(Motion.panel.animation(reduceMotion: reduceMotion), value: shift)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                PanePanelView(status: store.status, editors: editors,
                              chosenEditor: PaneEditor.preferred(in: editors, last: UserDefaults.standard.string(forKey: PaneEditor.lastKey)),
                              onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]); open = false },
                              onOpenEditor: { e in UserDefaults.standard.set(e.id, forKey: PaneEditor.lastKey); e.open(folder: folder); open = false },
                              onCommit: { commitResult = nil; open = false; committing = true },
                              onChanges: { open = false; task = openTarget(folder) },
                              agents: activity.rows, usage: usageData, teammates: teammates,
                              places: showsProject ? PlaceSource.live(folder: folder).rows() : nil,
                              onOpenAgent: { open = false; openAgent($0) }, onCheckNow: { usage.checkNow() },
                              onOpenHistory: { open = false; UsageHistoryStore.shared.open(windows: usageData.windows) },
                              onOpenTeam: teamOpen,
                              showsProject: showsProject)
                    .padding(8)
            }
            .sheet(isPresented: $committing) {
                CommitSheet(files: store.status.files, result: commitResult, onCommit: { text in
                    Task {
                        commitResult = await Task.detached(priority: .utility) { PaneCommit.commit(folder: folder, message: text) }.value
                        await store.refresh(folder: folder)
                    }
                }, onClose: { committing = false })
            }
            .sheet(item: $task) { TaskScreen(target: $0) }
            .sheet(isPresented: Bindable(UsageHistoryStore.shared).isOpen) { UsageHistorySheet(store: UsageHistoryStore.shared) }
            // One loop per folder: restarts on focus change, ends when the pill leaves the screen.
            .task(id: showsProject ? folder : "") {
                activity.start()
                var tick = 0
                while !Task.isCancelled {
                    if tick % 20 == 0 { usage.refresh() }
                    tick += 1
                    if showsProject, NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }) {
                        await store.refresh(folder: folder)
                    }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
    }

    /// A seat line focuses its pane; a builder or mission job line opens its task screen.
    private func openAgent(_ row: ActivityRow) {
        switch row.kind {
        case .seat:
            if let pane = row.pane { model.focus(pane: pane) }
        case .builder:
            if let b = HubStore.shared.builders.first(where: { $0.id == row.id }) { task = .builder(b) }
        case .mission:
            guard let info = activity.missionInfo[row.id] else { return }
            let b = info.progress.launchKey.flatMap { activity.builderNames[$0] }
            task = .mission(info, folder: b.map { $0.worktree ?? $0.cwd } ?? "", provider: b.map { TaskTarget.provider($0.model) } ?? TaskDetailCopy.claude)
        }
    }

    /// A seat's pane opens that seat's own task screen; any other pane opens its working tree.
    private func openTarget(_ folder: String) -> TaskTarget {
        let registry = AgentRegistry.shared
        if let name = registry.name(for: model.selectedTab.focusedPane), let agent = registry.agent(named: name),
           let turn = registry.turnRecords[name] {
            return .seat(agent, turn)
        }
        return .folder(folder)
    }
}
