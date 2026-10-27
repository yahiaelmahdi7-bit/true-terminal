import SwiftUI
import AppKit

/// The Hub as a centered pop-up over the terminal (the terminal never resizes). A scrim dims the terminal and
/// the glass is tinted near-opaque, so text reads over busy output. Click the scrim or press Esc to close
/// (Esc is caught in `TrueTerminalView`'s key monitor so it never reaches Claude, where it interrupts a turn).
/// It sits below the title-bar zone because this lives in the window's content area.
struct HubOverlay: View {
    let registry: AgentRegistry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .glassSurface(Self.shape, tint: .black.opacity(Self.tintOpacity), hairline: false)
                        .background(Self.shape.fill(Color.black.opacity(Self.backingOpacity)))
                        .overlay(Self.shape.strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
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

extension HubOverlay {
    /// Bottom-right corner handle: drag to resize, size is remembered across launches.
    fileprivate func resizeGrip(size: CGSize, window: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.dimText).frame(width: 24, height: 24).contentShape(.rect)
            .padding(4)
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
    @State private var crew = CrewStore.shared
    @State private var overseer = OverseerStore.shared
    @State private var crewNotice: String?
    @State private var cloud = CloudStore.shared
    @State private var watcher = WatcherStore.shared
    @State private var cloudDetail: CloudJob?
    @State private var showNewCloud = false
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
            HubPanelContent(groups: groups, allSeats: registry.crew, filter: $hub.filter, now: now,
                            actions: seatActions,
                            onNew: { registry.builder = BuilderDraft() },
                            onClose: { registry.panelOpen = false },
                            onDetail: { detail = $0 },
                            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0.cwd)]) },
                            crew: crew.snapshot, crewNotice: crewNotice,
                            onCrewPick: { pickCrew($0) },
                            yourMove: YourMoveRow.build(overseer.verdicts, seatName: { registry.name(for: $0) },
                                                        tabTitle: { p in WorkspaceModel.shared.state.tabs.first { $0.tree.leafIDs.contains(p) }?.title }),
                            onFocusPane: { WorkspaceModel.shared.focus(pane: $0); registry.panelOpen = false },
                            peerVerdict: { overseer.verdict(forSession: $0.sessionID)?.kind },
                            cloudJobs: cloud.jobs, cloudLink: .of(error: cloud.error, loaded: cloud.loaded),
                            watcherItems: WatcherStore.active ? watcher.needsYou : [],
                            inboundJobs: inbound,
                            builders: hub.builders,
                            openPanes: Set(WorkspaceModel.shared.state.tabs.flatMap { $0.tree.leafIDs }),
                            dismissed: dismissed,
                            activity: { HubScanner.lastActivity(of: $0) },
                            onDismiss: { dismissed.formUnion($0); HubDismissals.add($0) },
                            onRunCloud: { showNewCloud = true },
                            onRetryCloud: { Task { await cloud.refresh() } },
                            onTriage: { triageAction($0) })
        }
        .onReceive(NotificationCenter.default.publisher(for: .peersChanged)) { _ in reloadInbound() }
        .onAppear { reloadInbound(); hub.hubAppeared(); cloud.visible = true; cloud.start(); Task { await cloud.refresh() } }
        .onDisappear { cloud.visible = false }
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
        .sheet(item: $detail) { BuilderDetailSheet(record: $0) }
        .sheet(item: $cloudDetail) { CloudJobSheet(job: $0) { cloudDetail = nil } }
        .sheet(isPresented: $showNewCloud) { NewCloudJobSheet(projects: projectKeys) { showNewCloud = false } }
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
        case .cloud(let id): cloudDetail = cloud.jobs.first { $0.id == id }
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
    var openPanes: Set<UUID>? = nil
    var dismissed: Set<String> = []
    var activity: (BuilderRecord) -> String? = { _ in nil }
    var onDismiss: ([String]) -> Void = { _ in }
    /// Test hook: draw the Backlog already open.
    var backlogOpen = false
    var onRunCloud: () -> Void = {}
    var onRetryCloud: () -> Void = {}
    var onTriage: (TriageItem) -> Void = { _ in }
    @State private var jump: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var buckets: [TriageBucket] {
        HubTriage.build(groups: groups, seatStatus: actions.status, cloud: cloudJobs, watcher: watcherItems,
                        builders: builders, yourMove: yourMove, openPanes: openPanes, inbound: inboundJobs,
                        dismissed: dismissed, activity: activity, now: now)
    }

    var body: some View {
        let buckets = filter == .all ? self.buckets : []
        VStack(spacing: 0) {
            header(buckets)
            if filter == .chat {
                ChatView(roster: allSeats.map(\.name))
            } else if filter == .crew {
                CrewTabView(snapshot: crew, notice: crewNotice, onPick: onCrewPick)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: crewNotice)
            } else if groups.isEmpty && allSeats.isEmpty && buckets.allSatisfy({ $0.count == 0 }) {
                ContentUnavailableView {
                    Label("No agents yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("An agent is a saved Claude setup. Create one, then wake it in a tab.")
                } actions: {
                    // Custom (not .borderedProminent): prominent buttons dim when the window isn't key. Same inverted
                    // white-on-black device as the attention pill.
                    Button(action: onNew) {
                        Text("New Agent").font(.callout.weight(.semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 16).padding(.vertical, 6).background(.white, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            } else if filter == .all {
                TriageListView(buckets: buckets, now: now, jump: $jump, peers: AnyView(PeerJobsSection()), onAction: onTriage,
                               onDismiss: { onDismiss([$0.id]) }, onClearBacklog: onDismiss, backlogStartsOpen: backlogOpen)
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
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top))
    }

    /// One row for a modal: title + live summary on the left; filter, cloud, New Agent and Close on the right.
    private func header(_ buckets: [TriageBucket]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text("Hub").font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                    if filter == .all { cloudPill }
                }
                if filter != .crew && filter != .chat { summary(buckets) }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Picker("Show", selection: $filter) {
                Text("All").tag(HubFilter.all)
                Text("Agents").tag(HubFilter.seats)
                Text("Crew").tag(HubFilter.crew)
                Text("Chat").tag(HubFilter.chat)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 250)
            .accessibilityLabel("Show")
            .accessibilityHint("All: everything running and your agents. Agents: only your agents. Crew: specialists Claude can call in.")
            if filter == .all { headerButton("icloud.and.arrow.up", help: "Run in cloud", hint: "Sends a repo and a prompt to the cloud factory", action: onRunCloud) }
            headerButton("plus", help: "New Agent", hint: "Opens the agent builder", action: onNew)
            headerButton("xmark", help: "Close (Esc)", hint: "Closes the Hub", action: onClose)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    }

    /// "Cloud · connected" / "Cloud · offline — retry": one compact pill, the offline one is the retry button.
    private var cloudPill: some View {
        let offline = cloudLink == .offline
        return Button { if offline { onRetryCloud() } } label: {
            HStack(spacing: 5) {
                Circle().fill(cloudLink == .connected ? Theme.text : offline ? Theme.verdictWarn : Theme.dimText).frame(width: 6, height: 6)
                Text(cloudLink.label).font(.caption).foregroundStyle(Theme.hubSecondary).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.white.opacity(0.07), in: .capsule).contentShape(.capsule)
        }
        .buttonStyle(.plain).disabled(!offline)
        .help(offline ? "The cloud factory did not answer. Try again" : "Cloud factory")
        .accessibilityLabel(cloudLink.label)
    }

    /// "3 need you · 2 working · 1 to review": the same numbers as the sections below (the Backlog never counts).
    @ViewBuilder private func summary(_ buckets: [TriageBucket]) -> some View {
        if filter == .all {
            let needs = buckets.first { $0.section == .needsYou }?.count ?? 0
            let working = buckets.first { $0.section == .working }?.count ?? 0
            let review = buckets.first { $0.section == .review }?.count ?? 0
            let failed = HubTriage.count(buckets, tone: .failed)
            HStack(spacing: 0) {
                if needs + working + review == 0 { Text("Nothing running") }
                if needs > 0 {
                    if failed > 0 {
                        Button { jump = HubTriage.firstID(buckets, tone: .failed) } label: { Text("\(needs) need\(needs == 1 ? "s" : "") you") }
                            .buttonStyle(.plain).foregroundStyle(Theme.hubFailed).help("Jump to the first failure")
                    } else { Text("\(needs) need\(needs == 1 ? "s" : "") you") }
                }
                if working > 0 { Text("\(needs > 0 ? " · " : "")\(working) working") }
                if review > 0 { Text("\(needs + working > 0 ? " · " : "")\(review) to review") }
            }
            .font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1).fixedSize()
        } else {
            Text(liveSummary).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
        }
    }

    private func headerButton(_ symbol: String, help: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                .frame(width: 28, height: 28).background(Color.white.opacity(0.10), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help.replacingOccurrences(of: " (Esc)", with: ""))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8).frame(minHeight: 52)
            .background(hovering ? Theme.hubHoverFill : .clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
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

/// Read-only: the build's meta plus its report, or the tail of what it last did. Loaded off the main actor.
struct BuilderDetailSheet: View {
    let record: BuilderRecord
    @State private var text = "Loading…"
    @Environment(\.dismiss) private var dismiss

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background task").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(record.name).font(.headline).lineLimit(1).truncationMode(.middle)
                        StatusPill(status: record.status)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            VStack(alignment: .leading, spacing: 2) {
                detailLine("Folder", record.cwd)
                if !record.model.isEmpty { detailLine("Model", record.model.capitalized) }
                if let b = record.branch { detailLine("Branch", b) }
                if let c = record.cost {
                    detailLine("Cost", String(format: "$%.2f", c) + (record.budget.map { String(format: " of $%.2f", $0) } ?? ""))
                }
                if let p = record.parent { detailLine("Started by", p) }
            }
            Divider()
            ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(16).frame(width: 480, height: 420)
        .task { text = await Task.detached { HubScanner.detail(of: record) }.value }
    }
}
