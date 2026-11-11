import SwiftUI

/// Colours for the Work board in dark (the main mode, black first) and light. One accent: amber. The rest of the
/// Hub still draws with `Theme` (white on black); everything on this board and in its sheets reads the scheme.
struct HubInk {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }
    var primary: Color { dark ? Theme.HubLadder.darkPrimary : Theme.HubLadder.lightPrimary }
    var secondary: Color { dark ? Theme.HubLadder.darkSecondary : Theme.HubLadder.lightSecondary }
    var faint: Color { dark ? Theme.HubLadder.darkFaint : Theme.HubLadder.lightFaint }
    var tile: Color { dark ? Theme.HubLadder.darkTile : Theme.HubLadder.lightTile }
    var tileStroke: Color { dark ? Theme.HubLadder.darkTileStroke : Theme.HubLadder.lightTileStroke }
    var chip: Color { dark ? Theme.HubLadder.darkChip : Theme.HubLadder.lightChip }
    var accent: Color { dark ? Color(red: 1.0, green: 0.68, blue: 0.30) : Color(red: 0.80, green: 0.42, blue: 0.0) }
    var failed: Color { dark ? Color(red: 1.0, green: 0.42, blue: 0.40) : Color(red: 0.80, green: 0.18, blue: 0.16) }
    /// The loud capsule: inverted, same device as the attention pill.
    var loudFill: Color { dark ? .white : .black }
    var loudText: Color { dark ? .black : .white }
    /// The Hub card's own surface behind the glass.
    var surface: Color { dark ? .black : Color(white: 0.97) }

    func tone(_ t: TriageTone) -> Color {
        switch t {
        case .needsYou: return accent
        case .failed: return failed
        case .working: return primary
        case .done, .idle: return secondary
        }
    }
}

/// Hover and press wash over a chip-style hub button; the drawn chip stays as is.
struct HubChipHoverStyle<S: Shape>: ButtonStyle {
    let shape: S
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(shape.fill(configuration.isPressed ? Theme.Token.pressFill : hovering ? Theme.Token.hoverFill : .clear))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .motion(.micro, value: hovering)
    }
}

/// Full-width row chrome for hub list rows: 44 pt tall, hover wash over the whole row.
struct HubRowHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .frame(minHeight: Theme.Hit.row)
            .background(hovering ? Theme.hubHoverFill : .clear, in: .rect(cornerRadius: Theme.Radius.sm, style: .continuous))
            .contentShape(.rect(cornerRadius: Theme.Radius.sm, style: .continuous))
            .onHover { hovering = $0 }
            .motion(.micro, value: hovering)
    }
}

/// A capsule button: loud (inverted) for the tile's one main action, quiet for the rest.
struct HubTileButton: View {
    let label: String
    var loud = true
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let ink = HubInk(scheme)
        Button(action: action) {
            Text(label).font(.callout.weight(.semibold)).lineLimit(1).fixedSize()
                .foregroundStyle(loud ? ink.loudText : ink.primary)
                .padding(.horizontal, 14).frame(minWidth: Theme.Hit.control, minHeight: Theme.Hit.control)
                .background(loud ? ink.loudFill : ink.chip, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(HubChipHoverStyle(shape: Capsule()))
    }
}

/// Hover and press feedback for a whole-tile button.
private struct HubTileStyle: ButtonStyle {
    let ink: HubInk
    let shape: RoundedRectangle
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(shape.fill(ink.tile).opacity(configuration.isPressed ? 0.6 : hovering ? 1.9 : 1))
            .background(shape.fill(ink.tile.opacity(hovering ? 1 : 0)))
            .overlay(shape.strokeBorder(hovering ? ink.faint : ink.tileStroke, lineWidth: 0.5))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .motion(.micro, value: hovering)
    }
}

/// One tile; the whole tile is the button. Needs-you tiles show a status dot, title and age on one row; only
/// the first (oldest-waiting) carries a loud verb button; a failure tile adds quiet actions. A Running tile
/// shows where it runs, the live step, time and cost.
struct HubTileView: View {
    let tile: HubTile
    let now: Double
    var running = false
    /// The first Needs-you tile: the one loud button on the screen.
    var primary = false
    var canRetry = false
    let onMain: () -> Void
    var onRetry: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    private var height: CGFloat { running ? 96 : 80 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }
    /// How long the tile has waited: its oldest item.
    private var oldest: Double { tile.items.map(\.at).min() ?? now }
    private var failure: Bool { tile.kind == .failures }

    var body: some View {
        let ink = HubInk(scheme)
        Button(action: onMain) {
            VStack(alignment: .leading, spacing: 4) {
                if running, let item = tile.items.first {
                    HStack(spacing: 8) {
                        whereChip(item.runsOn, ink)
                        Spacer(minLength: 4)
                        if let cost = item.cost { Text(String(format: "$%.2f", cost)).font(.caption.monospacedDigit()).foregroundStyle(ink.secondary) }
                        age(ink)
                    }
                    Text(tile.title).font(.headline).foregroundStyle(ink.primary).lineLimit(1).multilineTextAlignment(.leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(ink.tone(tile.tone)).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(tile.title).font(.headline).foregroundStyle(ink.primary).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        if tile.kind != .more { age(ink) }
                    }
                }
                HStack(spacing: 6) {
                    Text(tile.detail).font(.callout).foregroundStyle(ink.secondary)
                        .lineLimit(1).truncationMode(.tail).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    // The action sits at the end of the detail line, so a tile without one has no empty row.
                    if showsButtons {
                        if primary && !failure { pill(tile.button, loud: true, ink) }
                        if failure {
                            pill(tile.button, loud: false, ink)
                            if canRetry { quiet("Retry", ink, onRetry) }
                        }
                    } else {
                        Image(systemName: "chevron.right").font(Theme.Fonts.icon(.sm, .semibold)).foregroundStyle(ink.faint)
                    }
                }
                .frame(minHeight: 28)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        }
        .buttonStyle(HubTileStyle(ink: ink, shape: shape))
        .accessibilityLabel("\(tile.title), \(tile.detail)")
        .accessibilityHint(tile.button)
    }

    private var showsButtons: Bool { !running && ((primary && !failure) || failure) }

    private func age(_ ink: HubInk) -> some View {
        Text(HubTriage.age(now - oldest)).font(.caption.monospacedDigit()).foregroundStyle(ink.secondary)
    }

    /// Visual label only: the tile Button underneath takes the click.
    private func pill(_ label: String, loud: Bool, _ ink: HubInk) -> some View {
        Text(label).font(.callout.weight(.semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(loud ? ink.loudText : ink.primary)
            .padding(.horizontal, 14).frame(height: 26)
            .background(loud ? ink.loudFill : ink.chip, in: .capsule)
    }

    private func quiet(_ label: String, _ ink: HubInk, _ action: @escaping () -> Void) -> some View {
        HubTileButton(label: label, loud: false, action: action)
    }

    private func whereChip(_ w: HubWhere, _ ink: HubInk) -> some View {
        HStack(spacing: 4) {
            Image(systemName: w.symbol).font(Theme.Fonts.icon(.xs, .medium))
            Text(w.label).font(.caption.weight(.medium))
        }
        .foregroundStyle(ink.secondary).padding(.horizontal, 8).padding(.vertical, 3)
        .background(ink.chip, in: .capsule)
    }
}

/// The Work view's first screen: Needs you / Running / Done today as tiles. No rows, no backlog.
struct HubBoardView: View {
    let board: HubBoard
    let now: Double
    var onNew: () -> Void = {}
    let onMain: (HubTile) -> Void
    /// nil until a retry engine exists: no Retry button is drawn.
    var onRetry: ((HubTile) -> Void)?
    let onItem: (TriageItem) -> Void
    /// The work queue's Next up section; nil draws nothing.
    var nextUp: NextUpPresentation?
    /// Team now: what others are on. Empty hides the section.
    var teamNow: [TeamNowRow] = []
    /// False on a Mac with no cloud key: no "Start a job" call to action.
    var cloudAvailable = true
    var onOpenSource: (WorkItem) -> Void = { _ in }
    /// Test hook: start with Done today open.
    var doneStartsOpen = false
    @State private var doneOpen = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = HubInk(scheme)
        GeometryReader { geo in
            if board.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(spacing: 6) {
                            Text("All clear").font(.title2.weight(.semibold)).foregroundStyle(ink.primary)
                            if !board.done.isEmpty {
                                Text("\(board.done.count) done today").font(.callout).foregroundStyle(ink.secondary)
                            }
                            if cloudAvailable {
                                HubTileButton(label: "New", action: onNew).padding(.top, 10)
                                Text("Start a job — it runs in the cloud").font(.caption).foregroundStyle(ink.faint)
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.top, 36)
                        if let nextUp { NextUpSection(model: nextUp, onOpen: onOpenSource).accessibilityIdentifier("scr.hub.nextup") }
                        if !board.done.isEmpty { doneStrip(ink) }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            } else {
                let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: HubLayout.tileColumns(width: geo.size.width))
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if !board.needsYou.isEmpty {
                            band("Needs you", count: board.needsYouCount, ink) {
                                LazyVGrid(columns: cols, spacing: 12) {
                                    ForEach(Array(board.needsYou.enumerated()), id: \.element.id) { n, t in
                                        HubTileView(tile: t, now: now, primary: n == 0, canRetry: onRetry != nil,
                                                    onMain: { onMain(t) }, onRetry: { onRetry?(t) })
                                    }
                                }
                            }
                        }
                        if !board.running.isEmpty {
                            band("Running", count: board.running.count, ink) {
                                LazyVGrid(columns: cols, spacing: 12) {
                                    ForEach(board.running) { t in
                                        HubTileView(tile: t, now: now, running: true, onMain: { onMain(t) })
                                    }
                                }
                            }
                        }
                        if let nextUp { NextUpSection(model: nextUp, onOpen: onOpenSource).accessibilityIdentifier("scr.hub.nextup") }
                        if !board.done.isEmpty { doneStrip(ink) }
                    }
                    .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear { if doneStartsOpen { doneOpen = true } }
    }

    private func band<C: View>(_ title: String, count: Int, _ ink: HubInk, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(ink.primary)
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(ink.secondary)
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// One quiet strip; tap opens the list.
    private func doneStrip(_ ink: HubInk) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(reduceMotion ? nil : .snappy) { doneOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(Theme.Fonts.icon(.md, .regular)).foregroundStyle(ink.secondary)
                    Text("Done today").font(.callout.weight(.semibold)).foregroundStyle(ink.primary)
                    Text("\(board.done.count)").font(.callout.monospacedDigit()).foregroundStyle(ink.secondary)
                    Text(board.done.prefix(3).map(\.title).joined(separator: " · "))
                        .font(.callout).foregroundStyle(ink.faint).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(Theme.Fonts.icon(.sm, .semibold)).foregroundStyle(ink.secondary)
                        .rotationEffect(.degrees(doneOpen ? 90 : 0))
                }
                .padding(.horizontal, 14).frame(minHeight: Theme.Hit.row).contentShape(shape)
            }
            .buttonStyle(HubChipHoverStyle(shape: shape))
            .accessibilityHint(doneOpen ? "Hides the list" : "Shows what finished today")
            if doneOpen {
                VStack(spacing: 0) {
                    ForEach(board.done) { i in HubMiniRow(item: i, now: now, onAction: onItem, showProject: true) }
                }
                .padding(.bottom, 6)
            }
        }
        .background(ink.tile.opacity(0.7), in: shape)
        .overlay(shape.strokeBorder(ink.tileStroke, lineWidth: 0.5))
    }
}

/// A compact row for sheets and the Done strip: title, project, age, one button, optional dismiss.
struct HubMiniRow: View {
    let item: TriageItem
    let now: Double
    let onAction: (TriageItem) -> Void
    var onDismiss: ((TriageItem) -> Void)?
    /// Done strip and backlog show the project on each row and an age column; a sheet groups by project instead.
    var showProject = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = HubInk(scheme)
        HStack(spacing: 10) {
            Circle().fill(ink.tone(item.tone)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.body).foregroundStyle(ink.primary).lineLimit(1).truncationMode(.middle)
                Text(([showProject ? item.project : ""] + [HubTriage.plainStatus(item, now: now)]).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(ink.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if showProject { Text(HubTriage.age(now - item.at)).font(.callout.monospacedDigit()).foregroundStyle(ink.secondary) }
            if !item.actionLabel.isEmpty {
                HubTileButton(label: HubTriage.plainVerb(item.actionLabel), loud: false) { onAction(item) }
            }
            if let onDismiss {
                Button { onDismiss(item) } label: {
                    Image(systemName: "xmark").font(Theme.Fonts.icon(.xs, .semibold)).foregroundStyle(ink.secondary)
                        .frame(width: Theme.Hit.control, height: Theme.Hit.control).contentShape(.circle)
                }
                .buttonStyle(HubChipHoverStyle(shape: Circle())).help("Dismiss").accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .modifier(HubRowHover())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: HubTriage.plainVerb(item.actionLabel)) { onAction(item) }
    }
}

/// A tile's detail sheet: what it stands for, each item with its own button, and Dismiss. Everything beyond the
/// tile's one main button lives here.
struct HubTileSheet: View {
    let tile: HubTile
    let now: Double
    let onItem: (TriageItem) -> Void
    var onDismissItem: ((TriageItem) -> Void)?
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 520
    /// The item that has waited longest: what "Review next" opens.
    private var oldest: TriageItem? { tile.items.min { $0.at < $1.at } }
    private var byProject: [(project: String, items: [TriageItem])] {
        Dictionary(grouping: tile.items, by: \.project).map { ($0.key, $0.value.sorted { $0.at < $1.at }) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        let ink = HubInk(scheme)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.title).font(.title3.weight(.semibold)).foregroundStyle(ink.primary)
                    if !tile.detail.isEmpty { Text(tile.detail).font(.callout).foregroundStyle(ink.secondary).lineLimit(2) }
                }
                Spacer(minLength: 8)
                if let next = oldest {
                    HubTileButton(label: tile.button == "Review" ? "Review next" : "Open next") { onItem(next) }
                }
                HubTileButton(label: "Done", loud: false, action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider().overlay(ink.tileStroke)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(byProject, id: \.project) { g in
                        if byProject.count > 1 || !g.project.isEmpty {
                            Text(g.project.isEmpty ? "Other" : g.project).font(.caption.weight(.semibold)).foregroundStyle(ink.faint)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2)
                        }
                        ForEach(g.items) { HubMiniRow(item: $0, now: now, onAction: onItem, onDismiss: onDismissItem) }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: Self.width).frame(minHeight: 200, maxHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(ink.surface)
    }
}

/// The backlog's own view: a count in the header opens it. Old rows, a Clear button, a way back.
struct HubBacklogView: View {
    let items: [TriageItem]
    let now: Double
    let onItem: (TriageItem) -> Void
    var onDismiss: (TriageItem) -> Void = { _ in }
    var onClear: ([String]) -> Void = { _ in }
    let onBack: () -> Void
    /// Most rows drawn at once; the rest are counted.
    static let cap = 150
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = HubInk(scheme)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HubTileButton(label: "Back", loud: false, action: onBack)
                Text("Backlog").font(.callout.weight(.semibold)).foregroundStyle(ink.primary)
                Text("\(items.count)").font(.callout.monospacedDigit()).foregroundStyle(ink.secondary)
                Spacer()
                if !items.isEmpty { HubTileButton(label: "Clear backlog", loud: false) { onClear(items.map(\.id)) } }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
            if items.isEmpty {
                Text("Nothing older").font(.callout).foregroundStyle(ink.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items.prefix(Self.cap)) { HubMiniRow(item: $0, now: now, onAction: onItem, onDismiss: onDismiss) }
                        if items.count > Self.cap {
                            Text("+ \(items.count - Self.cap) older").font(.callout).foregroundStyle(ink.faint).padding(10)
                        }
                    }
                }
            }
        }
    }
}

/// "Next up": the work queue's top items, read-only. Tapping a row opens its plan file.
struct NextUpSection: View {
    let model: NextUpPresentation
    var onOpen: (WorkItem) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = HubInk(scheme)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Next up").font(.callout.weight(.semibold)).foregroundStyle(ink.primary)
                if !model.rows.isEmpty { Text("\(model.rows.count)").font(.callout.monospacedDigit()).foregroundStyle(ink.secondary) }
            }
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            if let stale = model.staleLine {
                Text(stale).font(.callout).foregroundStyle(ink.accent)
            }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(ink.secondary)
            }
            if !model.rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.rows) { item in
                        NextUpRow(item: item, onOpen: onOpen)
                        if item.id != model.rows.last?.id { Divider().opacity(0.4) }
                    }
                }
                .background(ink.tile.opacity(0.7), in: shape)
                .overlay(shape.strokeBorder(ink.tileStroke, lineWidth: 0.5))
            }
        }
    }
}

private struct NextUpRow: View {
    let item: WorkItem
    let onOpen: (WorkItem) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = HubInk(scheme)
        let canOpen = item.source.flatMap { WorkQueue.sourceURL($0) } != nil
        Button { onOpen(item) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.headline).font(.body).foregroundStyle(ink.primary).lineLimit(2)
                if let why = item.why { Text(why).font(.callout).foregroundStyle(ink.secondary).lineLimit(2) }
                if !item.waitsOn.isEmpty {
                    Text("Waits on " + item.waitsOn.joined(separator: ", ")).font(.callout).foregroundStyle(ink.faint).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: Theme.Hit.row).contentShape(.rect)
        }
        .buttonStyle(HubChipHoverStyle(shape: Rectangle()))
        .accessibilityHint(canOpen ? "Opens the plan" : "")
    }
}

