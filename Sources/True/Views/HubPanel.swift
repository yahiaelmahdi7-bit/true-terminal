import SwiftUI
import AppKit

/// The Hub as a centered pop-up over the terminal (the terminal never resizes). A scrim dims the terminal and
/// the glass is tinted near-opaque, so text reads over busy output. Click the scrim or press Esc to close
/// (Esc is caught in `TrueTerminalView`'s key monitor so it never reaches Claude, where it interrupts a turn).
/// It sits below the title-bar zone because this lives in the window's content area.
struct HubOverlay: View {
    let registry: AgentRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    /// Gap kept between the card and the window edge when the window is small.
    static let margin: CGFloat = 24
    static let sizeKey = "hub.size"
    /// Legibility over a busy terminal wins over glass: a dark scrim, a solid black backing under the glass and a
    /// near-opaque tint on it (~0.94 black in all), so terminal text never bleeds through the rows.
    static let scrimOpacity = 0.5
    static let backingOpacity = 0.7
    static let tintOpacity = 0.8
    @State private var live: CGSize?
    @State private var dragStart: CGSize?

    private static func saved() -> CGSize? {
        guard let a = UserDefaults.standard.array(forKey: sizeKey) as? [Double], a.count == 2 else { return nil }
        return CGSize(width: a[0], height: a[1])
    }

    /// Opens at ~75% of the screen (never under 1000×680), or at the size the user last dragged it to.
    private func cardSize(in window: CGSize) -> CGSize {
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return HubLayout.size(saved: live ?? Self.saved(), screen: screen, window: window, margin: Self.margin)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if registry.panelOpen {
                    // Near-clear black (not clear) so the scrim takes the click that closes the Hub.
                    Color.black.opacity(Self.scrimOpacity)
                        .contentShape(Rectangle())
                        .onTapGesture { registry.panelOpen = false }
                        .transition(.opacity)
                    let size = cardSize(in: geo.size)
                    HubPanel(registry: registry)
                        .frame(width: size.width, height: size.height)
                        .overlay(alignment: .bottomTrailing) { resizeGrip(size: size, window: geo.size) }
                        .modifier(HubCardSurface(shape: Self.shape, solid: reduceTransparency))
                        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                        // Swallow clicks on the card so they never reach the scrim or the terminal.
                        .contentShape(Self.shape)
                        .onTapGesture {}
                        .background {
                            // Esc while a Hub control (not the terminal) has focus.
                            Button("") { registry.panelOpen = false }.keyboardShortcut(.cancelAction).hidden()
                        }
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Closed, the overlay must let the terminal keep every click.
        .allowsHitTesting(registry.panelOpen)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: registry.panelOpen)
    }
}

/// The Hub card's surface: glass over a black backing, or a solid `bg2` card with a visible edge under Reduce Transparency.
private struct HubCardSurface: ViewModifier {
    let shape: RoundedRectangle
    let solid: Bool
    func body(content: Content) -> some View {
        if solid {
            content
                .background(Theme.Token.bg2, in: shape)
                .overlay(shape.strokeBorder(Theme.Token.strongLine, lineWidth: 1))
        } else {
            content
                .glassSurface(shape, tint: .black.opacity(HubOverlay.tintOpacity), hairline: false)
                .background(shape.fill(Color.black.opacity(HubOverlay.backingOpacity)))
                .overlay(shape.strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
        }
    }
}

extension HubOverlay {
    /// Bottom-right corner handle: drag to resize, size is remembered across launches.
    fileprivate func resizeGrip(size: CGSize, window: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right").font(Theme.Fonts.icon(.xs, .semibold))
            .foregroundStyle(Theme.dimText).frame(width: Theme.Hit.control, height: Theme.Hit.control).contentShape(.rect)
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    let base = dragStart ?? size
                    dragStart = base
                    // The card is centered, so it grows by twice the drag on each axis.
                    live = HubLayout.size(saved: CGSize(width: base.width + v.translation.width * 2,
                                                        height: base.height + v.translation.height * 2),
                                          screen: .zero, window: window, margin: Self.margin)
                }
                .onEnded { _ in
                    dragStart = nil
                    if let l = live { UserDefaults.standard.set([Double(l.width), Double(l.height)], forKey: Self.sizeKey) }
                })
            .help("Drag to resize")
            .accessibilityHidden(true)
    }
}

/// The ⌘E panel: every Claude session on this Mac, grouped by project (SPEC Run 7). Store-bound shell;
/// the drawing lives in `HubPanelContent` so snapshot tests can render it from fixtures.
struct HubPanel: View {
    let registry: AgentRegistry
    @State private var hub = HubStore.shared
    @State private var detail: BuilderRecord?
    @State private var seatTask: TaskTarget?
    @State private var crew = CrewStore.shared
    @State private var overseer = OverseerStore.shared
    @State private var crewNotice: String?
    @State private var watcher = WatcherStore.shared
    @State private var watcherOpen: InboxItem?
    @State private var inbound: [InboundJob] = []
    @State private var dismissed: Set<String> = HubDismissals.load()

    private struct CrewTrigger: Hashable { var active: Bool; var cwd: String }

    private var focusedCwd: String {
        let t = WorkspaceModel.shared.selectedTab
        return t.cwds[t.focusedPane] ?? NSHomeDirectory()
    }

    var body: some View {
        // The elapsed-time ticker lives here, not in the model: a TimelineView only ticks while it is in
        // the view hierarchy, so a hidden Hub costs no wakeups (idle-CPU rule). 30 s is plenty for "12m".
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date.timeIntervalSince1970
            let groups = HubModel.build(seats: registry.crew, seatStatus: { registry.statusOf($0) },
                                        seatAwake: { registry.isAwake($0) }, peers: hub.peers,
                                        builders: hub.builders, now: now, seatsOnly: hub.filter == .seats)
            let cloudJobsNow: [CloudJob] = []
            let cloudLinkNow = CloudLink.notSetUp
            let teamFeedNow: StewardFeed? = nil, teamMeNow: String? = nil
            let newJob: () -> Void = { registry.builder = BuilderDraft() }
            let retryCloud: () -> Void = {}
            HubPanelContent(groups: groups, allSeats: registry.crew, filter: $hub.filter, now: now,
                            actions: seatActions,
                            onNew: newJob,
                            onClose: { registry.panelOpen = false },
                            onDetail: { detail = $0 },
                            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0.cwd)]) },
                            crew: crew.snapshot, crewNotice: crewNotice,
                            onCrewPick: { pickCrew($0) },
                            yourMove: YourMoveRow.build(overseer.verdicts, seatName: { registry.name(for: $0) },
                                                        tabTitle: { p in WorkspaceModel.shared.state.tabs.first { $0.tree.leafIDs.contains(p) }?.title }),
                            onFocusPane: { WorkspaceModel.shared.focus(pane: $0); registry.panelOpen = false },
                            peerVerdict: { overseer.verdict(forSession: $0.sessionID)?.kind },
                            cloudJobs: cloudJobsNow, cloudLink: cloudLinkNow,
                            watcherItems: WatcherStore.active ? watcher.needsYou : [],
                            inboundJobs: inbound,
                            builders: hub.builders,
                            workQueue: hub.workQueue,
                            teamFeed: teamFeedNow, teamMe: teamMeNow,
                            openPanes: Set(WorkspaceModel.shared.state.tabs.flatMap { $0.tree.leafIDs }),
                            dismissed: dismissed,
                            activity: { HubScanner.lastActivity(of: $0) },
                            onDismiss: { dismissed.formUnion($0); HubDismissals.add($0) },
                            onRunCloud: newJob,
                            onRetryCloud: retryCloud,
                            onTriage: { triageAction($0) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .peersChanged)) { _ in reloadInbound() }
        .onAppear { reloadInbound(); hub.hubAppeared() }
        // Crew scan: only while the Crew tab is showing, and again when the focused pane's cwd changes.
        // `.task(id:)` runs once per id change and cancels with the view: no watcher, timer or poll.
        .task(id: CrewTrigger(active: hub.filter == .crew, cwd: focusedCwd)) {
            if hub.filter == .crew { await crew.refresh(cwd: focusedCwd) }
        }
        // One-shot auto-hide of the "Copied" notice; a new notice restarts it.
        .task(id: crewNotice) {
            guard crewNotice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { crewNotice = nil }
        }
        .sheet(item: $detail) { TaskScreen(target: .builder($0)) }
        .sheet(item: $seatTask) { TaskScreen(target: $0) }
        .sheet(item: $watcherOpen) { WatcherItemSheet(item: $0, store: watcher) }
    }

    private func reloadInbound() {
        inbound = PeerService.engine.inboundJobs().filter { $0.status == .queued && $0.inboundMode == .ask }
    }

    private var projectKeys: [String] {
        HubModel.build(seats: registry.crew, seatStatus: { registry.statusOf($0) }, seatAwake: { registry.isAwake($0) },
                       peers: hub.peers, builders: hub.builders, now: Date().timeIntervalSince1970).map(\.key)
    }

    /// A row's one button. Pop-up closes only when it lands you in a pane.
    private func triageAction(_ item: TriageItem) {
        switch item.action {
        case .builder(let id): detail = hub.builders.first { $0.id == id }
        case .cloud: break
        case .watcher(let id): watcherOpen = watcher.items.first { $0.id == id }
        case .seat(let name): seatActions.wake(name)
        case .peer(let pid):
            if let p = hub.peers.first(where: { $0.pid == pid }) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.cwd)]) }
        case .inbound(let id): PeerService.engine.accept(id); reloadInbound()
        case .pane(let pane): WorkspaceModel.shared.focus(pane: pane); registry.panelOpen = false
        }
    }

    /// The pop-up covers the terminal, so anything that lands you in a pane closes it: waking / focusing a seat,
    /// and a crew pick that typed its starter prompt. "Copied" keeps it open so the notice shows.
    private var seatActions: SeatActions {
        var actions = SeatActions.live(registry)
        let wake = actions.wake
        actions.wake = { wake($0); registry.panelOpen = false }
        actions.openTurn = { name in
            if let agent = registry.agent(named: name), let turn = registry.turnRecords[name] { seatTask = .seat(agent, turn) }
        }
        return actions
    }

    private func pickCrew(_ agent: CrewAgent) {
        crewNotice = CrewDelivery.pick(agent)
        if crewNotice == nil { registry.panelOpen = false }
    }
}

/// Pure view over groups + closures. No store, no registry.
struct HubPanelContent: View {
    static let width: CGFloat = 600
    let groups: [HubProjectGroup]
    /// Every saved seat — a builder's `parent` may live in another project's group.
    let allSeats: [Agent]
    @Binding var filter: HubFilter
    let now: Double
    let actions: SeatActions
    var onNew: () -> Void = {}
    var onClose: () -> Void = {}
    var onDetail: (BuilderRecord) -> Void = { _ in }
    var onReveal: (PeerSession) -> Void = { _ in }
    var crew: CrewSnapshot?
    var crewNotice: String?
    var onCrewPick: (CrewAgent) -> Void = { _ in }
    /// Overseer: panes whose last turn needs a look (All filter only) and the verdict of an Other-session row.
    var yourMove: [YourMoveRow] = []
    var onFocusPane: (UUID) -> Void = { _ in }
    var peerVerdict: (PeerSession) -> VerdictKind? = { _ in nil }
    /// All tab: cloud jobs and Watcher items fold into the same triage sections.
    var cloudJobs: [CloudJob] = []
    var cloudLink: CloudLink = .checking
    var watcherItems: [InboxItem] = []
    var inboundJobs: [InboundJob] = []
    /// Raw builder records (for the Watcher rows' "is it acked / how old"), the panes open in True, the × 'd ids.
    var builders: [BuilderRecord] = []
    /// next.json as the Hub read it; nil draws no Next up section (stills of other states).
    var workQueue: WorkQueueLoad?
    /// The team server's items. Used for Next up only when there is no local queue; Team now always uses it. nil = not loaded (stills).
    var teamFeed: StewardFeed?
    var teamMe: String?
    var openPanes: Set<UUID>? = nil
    var dismissed: Set<String> = []
    var activity: (BuilderRecord) -> String? = { _ in nil }
    var onDismiss: ([String]) -> Void = { _ in }
    /// Test hook: draw the Backlog already open.
    var backlogOpen = false
    var onRunCloud: () -> Void = {}
    var onRetryCloud: () -> Void = {}
    var onTriage: (TriageItem) -> Void = { _ in }
    /// Retry on a failure tile. nil = no retry engine yet: the tile opens the item, where its existing actions live.
    var onRetry: ((HubTile) -> Void)?
    @State private var jump: String?
    @State private var showBacklog = false
    @State private var workFilter: HubFilter = .all
    @State private var openTile: HubTile?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Test hook: draw these buckets instead of building them from the groups (stills of a fixed load).
    var bucketsOverride: [TriageBucket]?

    private var buckets: [TriageBucket] {
        if let bucketsOverride { return bucketsOverride }
        return HubTriage.build(groups: groups, seatStatus: actions.status, cloud: cloudJobs, watcher: watcherItems,
                        builders: builders, yourMove: yourMove, openPanes: openPanes, inbound: inboundJobs,
                        dismissed: dismissed, activity: activity, now: now)
    }

    var body: some View {
        let buckets = filter == .all ? self.buckets : []
        VStack(spacing: 0) {
            header(buckets)
                .onChange(of: filter) { _, new in if new != .chat { workFilter = new } }
            if filter == .chat && HubChatTab.visible {
                ChatView(roster: allSeats.map(\.name))
            } else if filter == .crew {
                CrewTabView(snapshot: crew, notice: crewNotice, onPick: onCrewPick)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: crewNotice)
            } else if filter == .all {
                workBoard(buckets)
            } else if groups.isEmpty {
                ContentUnavailableView("Nothing running", systemImage: "moon.zzz",
                                       description: Text("No Claude sessions or background tasks right now."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(groups) { group in
                            groupView(group).transition(rowTransition)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 20)
                    .animation(reduceMotion ? nil : .snappy, value: groups.map(\.id))
                }
            }
        }
        // Seats and Crew read best narrow; the All tab uses the whole card.
        .frame(maxWidth: filter == .all || filter == .chat ? .infinity : Self.width)
        .frame(maxWidth: .infinity)
        .sheet(item: $openTile) { t in
            HubTileSheet(tile: t, now: now, onItem: { openTile = nil; onTriage($0) },
                         onDismissItem: { onDismiss([$0.id]); openTile = nil }, onClose: { openTile = nil })
        }
    }

    /// Work · All: the tile board, or the backlog's own view when the header count was tapped.
    @ViewBuilder private func workBoard(_ buckets: [TriageBucket]) -> some View {
        if showBacklog {
            HubBacklogView(items: buckets.first { $0.section == .backlog }.map(Self.flatItems) ?? [], now: now,
                           onItem: onTriage, onDismiss: { onDismiss([$0.id]) }, onClear: onDismiss,
                           onBack: { showBacklog = false })
        } else {
            let teamNowRows: [TeamNowRow] = []
            HubBoardView(board: HubTriage.board(buckets), now: now, onNew: onNew, onMain: mainAction,
                         onRetry: onRetry.map { r in { t in r(t) } }, onItem: onTriage,
                         nextUp: nextUpModel,
                         teamNow: teamNowRows,
                         cloudAvailable: cloudLink != .notSetUp,
                         onOpenSource: { i in
                             if let u = i.source.flatMap({ WorkQueue.sourceURL($0) }) { NSWorkspace.shared.open(u) }
                         })
        }
    }

    /// Local `next.json` present (or unreadable): exactly as before. Missing: this person's items from Steward.
    private var nextUpModel: NextUpPresentation? {
        guard let workQueue else { return nil }
        return NextUpPresentation.make(workQueue, now: Date(timeIntervalSince1970: now))
    }

    private static func flatItems(_ b: TriageBucket) -> [TriageItem] {
        b.entries.flatMap { e -> [TriageItem] in
            switch e {
            case .row(let i): return [i]
            case .group(_, _, _, _, let xs): return xs
            }
        }
    }

    /// A tile's one main button: a single item goes straight to its action, a queue opens its sheet.
    private func mainAction(_ t: HubTile) {
        switch t.kind {
        case .single: if let i = t.items.first { onTriage(i) }
        case .failures: if t.items.count == 1 { onTriage(t.items[0]) } else { openTile = t }
        case .group, .more: openTile = t
        }
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top))
    }

    /// One row for a modal: title + live summary on the left; filter, cloud, New Agent and Close on the right.
    private func header(_ buckets: [TriageBucket]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text("Hub").font(.title2.weight(.semibold)).foregroundStyle(HubInk(scheme).primary)
                    if filter == .all && (cloudLink == .offline || cloudLink == .notSetUp) { cloudPill }
                }
                if filter != .crew && filter != .chat { summary(buckets) }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if HubChatTab.visible {
                Picker("View", selection: Binding(
                    get: { HubView(filter: filter) },
                    set: { filter = $0.filter(workFilter: workFilter) })) {
                    Text("Work").tag(HubView.work)
                    Text("Chat").tag(HubView.chat)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .accessibilityLabel("View")
                .accessibilityHint("Work: what needs you and what is running. Chat: talk to Claude.")
            }
            if filter != .chat { filterMenu }
            if filter == .all { backlogButton(buckets) }
            if cloudLink != .notSetUp { headerButton("plus", help: "New", hint: "Starts a new job in the cloud", action: onNew) }
            headerButton("xmark", help: "Close (Esc)", hint: "Closes the Hub", action: onClose)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    }

    /// All / Agents / Crew live here, inside Work.
    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                Text("All").tag(HubFilter.all)
                Text("Agents").tag(HubFilter.seats)
                Text("Crew").tag(HubFilter.crew)
            }
        } label: {
            Label(filter == .seats ? "Agents" : filter == .crew ? "Crew" : "All", systemImage: "line.3.horizontal.decrease")
                .font(.callout).foregroundStyle(HubInk(scheme).faint)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Filter")
        .accessibilityHint("Show everything, only your agents, or the crew.")
    }

    /// "Backlog 144": a count, never rows on the board. Opens the backlog's own view; tapping again goes back.
    @ViewBuilder private func backlogButton(_ buckets: [TriageBucket]) -> some View {
        let n = buckets.first { $0.section == .backlog }?.count ?? 0
        if n > 0 {
            Button { showBacklog.toggle() } label: {
                HStack(spacing: 5) {
                    Text("Backlog").font(.callout)
                    Text("\(n)").font(.callout.monospacedDigit())
                }
                .foregroundStyle(showBacklog ? HubInk(scheme).primary : HubInk(scheme).secondary)
                .padding(.horizontal, 11).frame(minHeight: Theme.Hit.control)
                .background(HubInk(scheme).chip.opacity(showBacklog ? 1.6 : 1), in: .capsule).contentShape(.capsule)
            }
            .buttonStyle(HubChipHoverStyle(shape: Capsule())).help("Older work").accessibilityLabel("Backlog, \(n)")
            .accessibilityHint(showBacklog ? "Back to the board" : "Opens older work")
        }
    }

    /// "Cloud · connected" / "Cloud · offline — retry": one compact pill, the offline one is the retry button.
    private var cloudPill: some View {
        let offline = cloudLink == .offline
        return Button { if offline { onRetryCloud() } } label: {
            HStack(spacing: 5) {
                Circle().fill(cloudLink == .connected ? HubInk(scheme).primary : offline ? Theme.verdictWarn : HubInk(scheme).faint).frame(width: 6, height: 6)
                Text(cloudLink.label).font(.caption).foregroundStyle(HubInk(scheme).secondary).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 9).frame(minHeight: Theme.Hit.control)
            .background(HubInk(scheme).chip, in: .capsule).contentShape(.capsule)
        }
        .buttonStyle(HubChipHoverStyle(shape: Capsule())).disabled(!offline)
        .help(offline ? "The cloud factory did not answer. Try again" : cloudLink == .notSetUp ? "Cloud jobs are not set up on this Mac" : "Cloud factory")
        .accessibilityLabel(cloudLink.label)
        .accessibilityIdentifier(cloudLink == .notSetUp ? "scr.hub.cloud.nothere" : "scr.hub.cloud")
    }

    /// "3 need you · 2 working · 1 to review": the same numbers as the sections below (the Backlog never counts).
    @ViewBuilder private func summary(_ buckets: [TriageBucket]) -> some View {
        if filter == .all {
            let needs = buckets.first { $0.section == .needsYou }?.count ?? 0
            let working = buckets.first { $0.section == .working }?.count ?? 0
            let review = buckets.first { $0.section == .review }?.count ?? 0
            HStack(spacing: 0) {
                if needs + working + review == 0 { Text("Nothing running") }
                if needs > 0 {
                    Circle().fill(HubInk(scheme).accent).frame(width: 6, height: 6).padding(.trailing, 6)
                    Text("\(needs) need\(needs == 1 ? "s" : "") you")
                }
                if working > 0 { Text("\(needs > 0 ? " · " : "")\(working) working") }
                if review > 0 { Text("\(needs + working > 0 ? " · " : "")\(review) to review") }
            }
            .font(.callout).foregroundStyle(HubInk(scheme).secondary).lineLimit(1).fixedSize()
        } else {
            Text(liveSummary).font(.callout).foregroundStyle(HubInk(scheme).secondary).lineLimit(1)
        }
    }

    private func headerButton(_ symbol: String, help: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(Theme.Fonts.icon(.sm, .semibold)).foregroundStyle(HubInk(scheme).primary)
                .frame(width: Theme.Hit.control, height: Theme.Hit.control).background(HubInk(scheme).chip, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(HubChipHoverStyle(shape: Circle())).help(help).accessibilityLabel(help.replacingOccurrences(of: " (Esc)", with: ""))
        .accessibilityHint(hint)
    }

    /// The one-line "what is happening now" under the title: totals across every project.
    private var liveSummary: String {
        var parts: [String] = []
        let working = groups.reduce(0) { $0 + $1.working }, needs = groups.reduce(0) { $0 + $1.needsYou }
        let failed = groups.reduce(0) { $0 + $1.failed }
        if working > 0 { parts.append("\(working) working") }
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "Nothing running" : parts.joined(separator: " · ")
    }

    private func groupView(_ g: HubProjectGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(g.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if !g.summary.isEmpty {
                    Text(g.summary).font(.callout.monospacedDigit()).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
            // A lone "Agents" label over the cards would be noise; it only appears to tell them apart from the rows below.
            if !g.seats.isEmpty && (!g.background.isEmpty || !g.others.isEmpty) { sectionLabel("Agents") }
            ForEach(g.seats) { AgentCard(agent: $0, actions: actions).transition(rowTransition) }
            if !g.background.isEmpty {
                sectionLabel("Background")
                ForEach(g.background) { b in
                    BuilderRow(record: b, now: now, parentHue: HubAvatar.parentHue(of: b.parent, seats: allSeats))
                        .onTapGesture { onDetail(b) }.transition(rowTransition)
                }
            }
            if !g.others.isEmpty {
                sectionLabel("Other Claude sessions")
                ForEach(g.others) { p in
                    PeerRow(peer: p, verdict: peerVerdict(p)).onTapGesture { onReveal(p) }.transition(rowTransition)
                }
            }
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.callout.weight(.medium)).foregroundStyle(Theme.hubSecondary)
            .padding(.horizontal, 4).padding(.top, 8)
    }
}

enum HubAvatar {
    /// The hue of the seat a builder was started by (`record.parent` = a seat name), if we have that seat.
    static func parentHue(of parent: String?, seats: [Agent]) -> AgentHue? {
        guard let parent else { return nil }
        return seats.first { $0.name == parent }?.resolvedHue
    }
}

/// "12m", "1h 05m" — coarse on purpose; the ticker refreshes every 30 s.
func hubElapsed(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    return m < 60 ? "\(max(m, 0))m" : String(format: "%dh %02dm", m / 60, m % 60)
}

/// What kind of session a peer file says it is, in words: `interactive` is a person at a terminal.
func hubKindLabel(_ kind: String) -> String {
    switch kind.lowercased() {
    case "interactive", "cli": return "Terminal"
    case "", "session": return "Session"
    default: return kind.prefix(1).uppercased() + kind.dropFirst()
    }
}

/// The trailing status on a light row: only "Working" and "Failed" are loud; everything else is quiet.
struct HubStatusWord: View {
    let status: AgentStatus
    /// A builder state with its own plain word ("In line", "Merged"…); `neutral` = an unknown status, shown as written in grey.
    var label: String? = nil
    var neutral = false
    var body: some View {
        if let label {
            Text(label).font(.callout).foregroundStyle(neutral ? Color.gray : Theme.hubSecondary).lineLimit(1)
        } else {
            word
        }
    }
    @ViewBuilder private var word: some View {
        let loud = status == .working || status == .failed
        Text(status.label).font(.callout.weight(loud ? .semibold : .regular))
            .foregroundStyle(loud ? Theme.text : Theme.hubSecondary).lineLimit(1)
    }
}

/// A lighter row than a seat card: nothing at rest, a faint fill on hover, 52 pt tall.
struct HubRowFrame<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 52)
            .background(hovering ? Theme.hubHoverFill : .clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
            .onHover { hovering = $0 }
            .motion(.micro, value: hovering)
    }
}

struct BuilderRow: View {
    let record: BuilderRecord
    let now: Double
    var parentHue: AgentHue?
    var body: some View {
        let hue = AgentHue.derived(from: record.name)
        HubRowFrame {
            HStack(spacing: 12) {
                AgentAvatar(hue: hue, symbol: "hammer", status: record.status, size: 32, parentHue: parentHue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.name).font(.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Text(secondary).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                HubStatusWord(status: record.status, label: record.rowLabel(), neutral: record.isUnknownStatus)
            }
        }
        .help("Show this task's result")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.name), background task, \(record.statusLabel), \(secondary)")
        .accessibilityHint("Opens its details")
        .accessibilityAddTraits(.isButton)
    }

    /// Who and how long; the status is the trailing word, same place on every row.
    private var secondary: String {
        var parts: [String] = []
        if !record.model.isEmpty { parts.append(record.model.capitalized) }
        if let parent = record.parent { parts.append("from \(parent)") }
        parts.append(hubElapsed(record.elapsed(now: now)))
        return parts.joined(separator: " · ")
    }
}

struct PeerRow: View {
    let peer: PeerSession
    var verdict: VerdictKind?
    var body: some View {
        HubRowFrame {
            HStack(spacing: 12) {
                // Not our crew → no colour, no presence dot: strangers stay grey.
                AgentAvatar(hue: nil, symbol: "terminal", status: peer.busy ? .working : .idle, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(peer.displayName).font(.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                    Text(hubKindLabel(peer.kind)).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let verdict { VerdictBadge(kind: verdict) }
                HubStatusWord(status: peer.busy ? .working : .idle)
            }
        }
        .help("Reveal \(peer.cwd) in Finder")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peer.displayName), Claude session, \(peer.busy ? "working" : "idle"), \(hubKindLabel(peer.kind))")
        .accessibilityHint("Shows its folder in Finder")
        .accessibilityAddTraits(.isButton)
    }
}

/// The Hub's Chat tab (peer `ChatBus` chat) is hidden once team mode is on; its lines are reached through Mac channels in Group.
enum HubChatTab {
    @MainActor static func visible(spaceEnabled: Bool) -> Bool { !spaceEnabled }
    @MainActor static var visible: Bool { true }
}
