import SwiftUI

/// "now", "2m", "3h", "6d": one coarse unit, same for finished and running rows.
func triageTime(_ item: TriageItem, now: Double) -> String { HubTriage.age(now - item.at) }

extension TriageTone {
    var glyph: String {
        switch self {
        case .failed: return "xmark.circle.fill"
        case .needsYou: return "exclamationmark.circle.fill"
        case .working: return "circle.dotted"
        case .done: return "checkmark.circle"
        case .idle: return "circle"
        }
    }
    var color: Color {
        switch self {
        case .failed: return Theme.hubFailed
        case .needsYou: return Theme.verdictWarn
        case .working: return Theme.text
        case .done: return Theme.hubSecondary
        case .idle: return Theme.dimText
        }
    }
    var word: String {
        switch self {
        case .failed: return "failed"
        case .needsYou: return "needs you"
        case .working: return "working"
        case .done: return "done"
        case .idle: return "idle"
        }
    }
}

struct TriageGlyph: View {
    let tone: TriageTone
    var cloud = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: tone.glyph).font(.system(size: 15, weight: .medium)).foregroundStyle(tone.color)
            .symbolEffect(.pulse, isActive: tone == .working && !reduceMotion)
            .frame(width: 20, height: 20)
            .overlay(alignment: .bottomTrailing) {
                if cloud {
                    Image(systemName: "icloud.fill").font(.system(size: 8)).foregroundStyle(Theme.hubSecondary)
                        .padding(1.5).background(Color.black, in: .circle).offset(x: 4, y: 3)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The one button on a row. Needs-you rows get the inverted capsule (same device as the attention pill).
struct TriageButton: View {
    let label: String
    let loud: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.callout.weight(.medium)).lineLimit(1).fixedSize()
                .foregroundStyle(loud ? Color.black : Theme.text)
                .frame(minWidth: 72).padding(.horizontal, 10).padding(.vertical, 3)
                .background(loud ? Color.white : Color.white.opacity(0.10), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

struct ProjectChip: View {
    let name: String
    var body: some View {
        if !name.isEmpty {
            Text(name).font(.caption).foregroundStyle(Theme.hubSecondary).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.white.opacity(0.07), in: .capsule)
                .frame(maxWidth: 112, alignment: .leading)
        }
    }
}

/// Column widths shared by every compact row so chips, ages and buttons line up down the list.
private enum Col {
    static let chip: CGFloat = 112, age: CGFloat = 34, button: CGFloat = 92, dismiss: CGFloat = 22
}

/// Row chrome: hover and keyboard selection share one fill. 34 pt tall.
private struct TriageRowFrame<Content: View>: View {
    let selected: Bool
    var indent: CGFloat = 0
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        content
            .padding(.leading, 10 + indent).padding(.trailing, 6).frame(height: 34)
            .background(selected ? Color.white.opacity(0.10) : hovering ? Theme.hubHoverFill : .clear,
                        in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.18 : 0), lineWidth: 1))
            .contentShape(.rect(cornerRadius: 8, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// The × on a row: dim until the row is hovered or selected, always in the layout so columns never shift.
private struct DismissButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.hubSecondary)
                .frame(width: Col.dismiss, height: Col.dismiss).contentShape(.circle)
        }
        .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss")
    }
}

struct TriageRowView: View {
    let item: TriageItem
    let now: Double
    let selected: Bool
    var indent: CGFloat = 0
    var showProject = true
    let onAction: (TriageItem) -> Void
    var onDismiss: (TriageItem) -> Void = { _ in }

    var body: some View {
        TriageRowFrame(selected: selected, indent: indent) {
            HStack(spacing: 10) {
                TriageGlyph(tone: item.tone, cloud: item.isCloud)
                HStack(spacing: 8) {
                    Text(item.title).font(.body).foregroundStyle(item.section == .backlog ? Theme.hubSecondary : Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    if !item.modelChip.isEmpty { ModelChip(text: item.modelChip) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProjectChip(name: showProject ? item.project : "").frame(width: Col.chip, alignment: .leading)
                Text(triageTime(item, now: now)).font(.callout.monospacedDigit()).foregroundStyle(Theme.hubSecondary)
                    .frame(width: Col.age, alignment: .trailing)
                Group {
                    if item.actionLabel.isEmpty { Color.clear } else {
                        TriageButton(label: item.actionLabel, loud: item.tone == .needsYou || item.tone == .failed) { onAction(item) }
                    }
                }
                .frame(width: Col.button, alignment: .trailing)
                DismissButton { onDismiss(item) }
            }
        }
        .onTapGesture(count: 2) { onAction(item) }
        .help(item.subtitle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.isCloud ? "cloud, " : "")\(item.tone.word), \(item.project), \(item.subtitle)")
        .accessibilityAction(named: item.actionLabel) { onAction(item) }
        .accessibilityAction(named: "Dismiss") { onDismiss(item) }
    }
}

struct TriageGroupView: View {
    let id: String
    let project: String
    let tone: TriageTone
    let label: String
    let items: [TriageItem]
    let now: Double
    let expanded: Bool
    let selected: String?
    let toggle: () -> Void
    let onAction: (TriageItem) -> Void
    var onDismiss: (TriageItem) -> Void = { _ in }

    private var groupTime: String {
        HubTriage.age(now - (items.map(\.at).max() ?? now))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TriageRowFrame(selected: selected == id) {
                HStack(spacing: 10) {
                    TriageGlyph(tone: tone, cloud: items.allSatisfy(\.isCloud))
                    (Text(project).foregroundStyle(Theme.text) + Text(" · \(label)").foregroundStyle(Theme.hubSecondary))
                        .font(.body).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(groupTime).font(.callout.monospacedDigit()).foregroundStyle(Theme.hubSecondary)
                        .frame(width: Col.age, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.hubSecondary).rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: Col.button + Col.dismiss + 10, alignment: .trailing)
                }
            }
            .onTapGesture(perform: toggle)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(project), \(label)")
            .accessibilityHint(expanded ? "Collapses the list" : "Shows each one")
            .accessibilityAddTraits(.isButton)
            if expanded {
                ForEach(items) { i in
                    TriageRowView(item: i, now: now, selected: selected == i.id, indent: 20, showProject: false,
                                  onAction: onAction, onDismiss: onDismiss)
                        .id(i.id)
                }
            }
        }
    }
}

/// One live thing: an open agent, a running builder or a cloud job. Name, project, how long, what it is doing.
struct WorkingCardView: View {
    let item: TriageItem
    let now: Double
    let selected: Bool
    let onAction: (TriageItem) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TriageGlyph(tone: .working, cloud: item.isCloud)
                Text(item.title).font(.body.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(HubTriage.age(now - item.at)).font(.callout.monospacedDigit()).foregroundStyle(Theme.hubSecondary)
            }
            Text(item.activity.isEmpty ? item.subtitle : item.activity).font(.callout).foregroundStyle(Theme.hubSecondary)
                .lineLimit(1).truncationMode(.tail)
            HStack(spacing: 8) {
                ProjectChip(name: item.project)
                if !item.modelChip.isEmpty { ModelChip(text: item.modelChip) }
                Spacer(minLength: 4)
                TriageButton(label: item.actionLabel.isEmpty ? "Open" : item.actionLabel, loud: false) { onAction(item) }
            }
        }
        .padding(12)
        .background(selected ? Color.white.opacity(0.10) : hovering ? Theme.hubHoverFill : Color.white.opacity(0.04),
                    in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.18 : 0.06), lineWidth: 1))
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onAction(item) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.isCloud ? "cloud, " : "")working, \(item.project), \(item.activity.isEmpty ? item.subtitle : item.activity)")
        .accessibilityAction(named: item.actionLabel.isEmpty ? "Open" : item.actionLabel) { onAction(item) }
    }
}

/// The All tab body. Wide: inbox on the left (Needs you, Done to review, Backlog), Working cards on the right.
/// Narrow: one column (Needs you, Working, Review, Backlog). ↑↓ walk the inbox, ⏎ presses the row's button.
struct TriageListView: View {
    let buckets: [TriageBucket]
    let now: Double
    /// Set by the header's counts: select that row and scroll to it.
    @Binding var jump: String?
    var peers: AnyView = AnyView(EmptyView())
    let onAction: (TriageItem) -> Void
    var onDismiss: (TriageItem) -> Void = { _ in }
    var onClearBacklog: ([String]) -> Void = { _ in }
    /// Test hook: start with the Backlog open.
    var backlogStartsOpen = false
    /// Most Backlog rows drawn at once; the rest are counted.
    static let backlogCap = 150

    @State private var selected: String?
    @State private var expanded: Set<String> = []
    @State private var backlogOpen = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func bucket(_ s: TriageSection) -> TriageBucket {
        buckets.first { $0.section == s } ?? TriageBucket(section: s, entries: [], count: 0)
    }

    var body: some View {
        GeometryReader { geo in
            let wide = HubLayout.isTwoColumn(width: geo.size.width)
            ScrollViewReader { proxy in
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 0) {
                            ScrollView { column([.needsYou, .review, .backlog]).padding(.leading, 16).padding(.trailing, 12) }
                                .frame(width: geo.size.width * HubLayout.leftShare)
                            Divider().overlay(Color.white.opacity(0.08))
                            ScrollView { column([.working]).padding(.leading, 12).padding(.trailing, 16) }
                        }
                    } else {
                        ScrollView { column([.needsYou, .working, .review, .backlog]).padding(.horizontal, 16) }
                    }
                }
                .focusable().focused($focused).focusEffectDisabled()
                .onAppear { focused = true; if backlogStartsOpen { backlogOpen = true } }
                .onKeyPress(.upArrow) { selected = HubTriage.move(ids(wide), from: selected, by: -1); return .handled }
                .onKeyPress(.downArrow) { selected = HubTriage.move(ids(wide), from: selected, by: 1); return .handled }
                .onKeyPress(.return) { activate(); return selected == nil ? .ignored : .handled }
                .onChange(of: selected) { _, new in
                    if let new { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(new) } }
                }
                .onChange(of: jump) { _, new in
                    guard let new else { return }
                    selected = new; focused = true
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
                    jump = nil
                }
            }
        }
    }

    private func ids(_ wide: Bool) -> [String] {
        HubTriage.visibleIDs(buckets, expanded: expanded, backlogOpen: backlogOpen, includeWorking: !wide)
    }

    private func activate() {
        guard let selected, let hit = HubTriage.entry(buckets, id: selected) else { return }
        if let item = hit.item { onAction(item) } else if let g = hit.groupID { toggle(g) }
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : .snappy) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func column(_ sections: [TriageSection]) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(sections) { s in section(bucket(s)) }
        }
        .padding(.top, 4).padding(.bottom, 20)
    }

    @ViewBuilder private func section(_ b: TriageBucket) -> some View {
        switch b.section {
        case .backlog: backlog(b)
        case .working:
            VStack(alignment: .leading, spacing: 8) {
                header(b)
                if b.entries.isEmpty { empty(b) } else {
                    ForEach(b.entries) { e in
                        if case .row(let i) = e {
                            WorkingCardView(item: i, now: now, selected: selected == i.id, onAction: onAction)
                                .id(i.id).onTapGesture { selected = i.id }
                        }
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                header(b).padding(.bottom, 2)
                if b.entries.isEmpty { empty(b) } else { entries(b) }
            }
        }
    }

    private func empty(_ b: TriageBucket) -> some View {
        Text(b.section.emptyText).font(.callout).foregroundStyle(Theme.dimText).padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func backlog(_ b: TriageBucket) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { withAnimation(reduceMotion ? nil : .snappy) { backlogOpen.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(backlogOpen ? 90 : 0)).frame(width: 12)
                        header(b)
                    }.contentShape(.rect())
                }
                .buttonStyle(.plain)
                .accessibilityHint(backlogOpen ? "Collapses the Backlog" : "Shows older work")
                if backlogOpen && b.count > 0 {
                    let all = b.entries.flatMap { e -> [String] in
                        if case .row(let i) = e { return [i.id] }
                        if case .group(_, _, _, _, let items) = e { return items.map(\.id) }
                        return []
                    }
                    Button { onClearBacklog(all) } label: {
                        Text("Clear backlog").font(.callout.weight(.medium)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Color.white.opacity(0.10), in: .capsule)
                    }
                    .buttonStyle(.plain).help("Hides all \(b.count) older items")
                }
            }
            if backlogOpen {
                peers
                if b.entries.isEmpty { empty(b) }
                let shown = Array(b.entries.prefix(Self.backlogCap))
                ForEach(shown) { e in
                    if case .row(let i) = e {
                        TriageRowView(item: i, now: now, selected: selected == i.id, onAction: onAction, onDismiss: onDismiss)
                            .id(i.id).onTapGesture { selected = i.id }
                    }
                }
                if b.entries.count > shown.count {
                    Text("+ \(b.entries.count - shown.count) older").font(.callout).foregroundStyle(Theme.dimText)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
        }
    }

    private func header(_ b: TriageBucket) -> some View {
        HStack(spacing: 6) {
            Text(b.section.title).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
            Text("\(b.count)").font(.callout.monospacedDigit()).foregroundStyle(Theme.hubSecondary)
            Spacer()
        }
        .padding(.horizontal, b.section == .backlog ? 0 : 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func entries(_ b: TriageBucket) -> some View {
        ForEach(b.entries) { e in
            switch e {
            case .row(let i):
                TriageRowView(item: i, now: now, selected: selected == i.id, onAction: onAction, onDismiss: onDismiss)
                    .id(i.id).onTapGesture { selected = i.id }
            case .group(let id, let project, let tone, let label, let items):
                TriageGroupView(id: id, project: project, tone: tone, label: label, items: items, now: now,
                                expanded: expanded.contains(id), selected: selected,
                                toggle: { selected = id; toggle(id) }, onAction: onAction, onDismiss: onDismiss)
                    .id(id)
            }
        }
    }
}
