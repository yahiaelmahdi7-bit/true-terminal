import AppKit
import SwiftUI

/// The per-pane header strip: which project THIS terminal is on. Pure rules first, then the store, then the view.
enum PaneStripMode: Equatable { case strip, collapsed }

enum PaneStrip {
    /// The strip sits on the terminal (always black), so it uses the terminal's own foregrounds in both app themes.
    static let bright = Theme.text, dim = Color.white.opacity(0.55), hover = Color.white
    static let add = Color(nsColor: NSColor(hex: Theme.DiffPalette.dark.add)), remove = Color(nsColor: NSColor(hex: Theme.DiffPalette.dark.remove))

    /// Below this pane width the strip hides and the top pill carries the focused pane's project.
    /// 600 pt: on a 1440 pt window two panes are ~720 pt (strips stay), three are ~480 pt (collapse).
    static let minWidth: CGFloat = 600
    /// One terminal line. The strip sits in the pane's top margin, so it costs the terminal one row at most.
    static let height: CGFloat = 18

    /// The strip sits in the top margin: the terminal starts just under it (strip height + 2 pt gap) instead of 4 pt from the edge.
    static func insets(_ base: EdgeInsets, strip: Bool) -> EdgeInsets {
        strip ? EdgeInsets(top: height + 2, leading: base.leading, bottom: base.bottom, trailing: base.trailing) : base
    }

    static func mode(width: CGFloat) -> PaneStripMode { width >= minWidth ? .strip : .collapsed }

    /// The top pill shows the project sections unless every visible pane has its own strip.
    static func pillShowsProject(widths: [CGFloat]) -> Bool {
        widths.isEmpty || widths.contains { mode(width: $0) == .collapsed }
    }

    /// Folders to read for the panes that show a strip: each folder once, in first-seen order, however many panes share it.
    static func foldersToRead(_ panes: [(folder: String, width: CGFloat)]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for p in panes where mode(width: p.width) == .strip && !p.folder.isEmpty && seen.insert(p.folder).inserted { out.append(p.folder) }
        return out
    }

    /// "true" for ~/Projects/true, "~" for home itself.
    static func folderName(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        let n = (path as NSString).lastPathComponent
        return n.isEmpty ? path : n
    }

    /// Online teammates on this repo, by the names Place already resolved (PeerNicknames).
    static func teammates(_ rows: [PlaceRow]) -> [String] { rows.filter { !$0.isThisMac && $0.online }.map(\.name) }

    /// "Alex", "Alex +2".
    static func teammateText(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count == 1 ? first : "\(first) +\(names.count - 1)"
    }
}

struct PaneStripInfo: Equatable {
    var git = PaneGitStatus.notGit
    var places: [PlaceRow] = []
}

@MainActor @Observable
final class PaneStripStore {
    static let shared = PaneStripStore()
    var infos: [String: PaneStripInfo] = [:]
    /// The terminal area's size, so the top pill can derive each pane's width with the same layout the panes use.
    var areaSize = CGSize.zero

    /// One read per unique folder, however many panes share it.
    nonisolated static func readAll(_ folders: [String], read: (String) -> PaneStripInfo) -> [String: PaneStripInfo] {
        var out: [String: PaneStripInfo] = [:]
        for f in folders where out[f] == nil { out[f] = read(f) }
        return out
    }

    nonisolated static func liveRead(_ folder: String) -> PaneStripInfo {
        PaneStripInfo(git: PaneGitReader.read(folder: folder), places: PlaceSource.live(folder: folder).rows())
    }

    func refresh(_ folders: [String]) async {
        let result = await Task.detached(priority: .utility) { Self.readAll(folders, read: Self.liveRead) }.value
        if result != infos { infos = result }   // folders no longer shown drop out here
    }
}

/// The strip itself. Pure view: the host passes data and the click.
struct PaneStripBar: View {
    let folder: String
    let info: PaneStripInfo
    var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Text(PaneStrip.folderName(folder)).foregroundStyle(hovering ? PaneStrip.hover : PaneStrip.bright).lineLimit(1).truncationMode(.middle)
            if info.git.isRepo {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(info.git.branch).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                }.foregroundStyle(PaneStrip.dim)
                if info.git.showsCounts {
                    HStack(spacing: 6) {
                        Text("+\(info.git.added)").foregroundStyle(info.git.added == 0 ? PaneStrip.dim : PaneStrip.add)
                        Text("−\(info.git.removed)").foregroundStyle(info.git.removed == 0 ? PaneStrip.dim : PaneStrip.remove)
                    }.font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
                }
            }
            if let t = PaneStrip.teammateText(PaneStrip.teammates(info.places)) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2").font(.system(size: 10))
                    Text(t).lineLimit(1)
                }.foregroundStyle(PaneStrip.dim)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(height: PaneStrip.height).fixedSize(horizontal: true, vertical: false).contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.git.isRepo ? "\(PaneStrip.folderName(folder)), \(info.git.branch), \(info.git.added) added, \(info.git.removed) removed" : PaneStrip.folderName(folder))
        .accessibilityAddTraits(.isButton)
    }
}

/// A strip with its own popover: the existing project sections (Place, Open in editor, Commit, Changes), scoped to this pane's folder.
struct PaneStripHost: View {
    let pane: UUID
    let folder: String
    let info: PaneStripInfo
    @State private var open = false
    @State private var hovering = false
    @State private var committing = false
    @State private var task: TaskTarget?
    @State private var commitResult: String?
    @State private var editors = PaneEditor.installed()

    var body: some View {
        Button { open.toggle() } label: { PaneStripBar(folder: folder, info: info, hovering: hovering) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                PanePanelView(status: info.git, editors: editors,
                              chosenEditor: PaneEditor.preferred(in: editors, last: UserDefaults.standard.string(forKey: PaneEditor.lastKey)),
                              onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]); open = false },
                              onOpenEditor: { e in UserDefaults.standard.set(e.id, forKey: PaneEditor.lastKey); e.open(folder: folder); open = false },
                              onCommit: { commitResult = nil; open = false; committing = true },
                              onChanges: { open = false; task = target },
                              places: info.places).padding(8)
            }
            .sheet(isPresented: $committing) {
                CommitSheet(files: info.git.files, result: commitResult, onCommit: { text in
                    Task {
                        commitResult = await Task.detached(priority: .utility) { PaneCommit.commit(folder: folder, message: text) }.value
                        await PaneStripStore.shared.refresh([folder])
                    }
                }, onClose: { committing = false })
            }
            .sheet(item: $task) { TaskScreen(target: $0) }
    }

    private var target: TaskTarget {
        let registry = AgentRegistry.shared
        if let name = registry.name(for: pane), let agent = registry.agent(named: name), let turn = registry.turnRecords[name] { return .seat(agent, turn) }
        return .folder(folder)
    }
}

/// One loop for the whole tab. It restarts when the set of folders changes (a pane closed or cd'd) and ends when the tab hides.
struct PaneStripDriver: View {
    let folders: [String]
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: folders) {
                guard !folders.isEmpty else { PaneStripStore.shared.infos = [:]; return }
                while !Task.isCancelled {
                    if NSApp.windows.contains(where: { $0.isVisible && $0.occlusionState.contains(.visible) }) {
                        await PaneStripStore.shared.refresh(folders)
                    }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
    }
}
