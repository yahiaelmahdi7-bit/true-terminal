import SwiftUI

/// The Watcher under "Your move": one card, then its Inbox. Monochrome; the eye is the only colour.
struct WatcherSection: View {
    @State private var store = WatcherStore.shared
    @State private var open: InboxItem?

    @State private var showAll = false

    var body: some View {
        let needs = store.needsYou
        let rows = showAll ? store.items.sorted { $0.at > $1.at } : needs
        let t = store.today()
        if WatcherStore.active {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "eye").font(.body).foregroundStyle(Theme.verdictWarn).accessibilityHidden(true)
                    Text("Watcher").font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(store.enabled ? "On duty" : "Paused").font(.callout).foregroundStyle(Theme.hubSecondary)
                    Spacer()
                    Button(showAll ? "Needs you" : "All") { showAll.toggle() }.buttonStyle(.plain)
                        .font(.callout).foregroundStyle(Theme.hubSecondary)
                    Text("\(needs.count) waiting").font(.callout).foregroundStyle(Theme.hubSecondary)
                }
                .padding(.horizontal, 4)
                Text(String(format: "$%.2f of $%.2f today · Memory: %d lessons · peak context %dk", t.usd, store.duty.budget.dailyUSD,
                            store.memoryLessonCount, t.peakContext / 1000))
                    .font(.callout).foregroundStyle(Theme.hubSecondary).padding(.horizontal, 4)
                if store.burnHookMissing {
                    Text("Context guard missing: investigations run without it.").font(.callout).foregroundStyle(Theme.verdictWarn).padding(.horizontal, 4)
                }
                if let digest = store.hubChannel?.lastDigest {
                    HubRowFrame {
                        HStack { Text(digest).font(.body).foregroundStyle(Theme.text); Spacer(minLength: 4)
                            Text("Digest").font(.callout).foregroundStyle(Theme.hubSecondary) }
                    }
                    .onTapGesture { store.hubChannel?.dismissDigest() }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens and clears the digest")
                    .accessibilityAddTraits(.isButton)
                }
                ForEach(rows) { item in
                    HubRowFrame {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.tail)
                                Text(WatcherItemSheet.subtitle(item)).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if let l = item.level { Text(l.label).font(.callout).foregroundStyle(Theme.hubSecondary) }
                        }
                    }
                    .onTapGesture { open = item }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(item.title). \(WatcherItemSheet.subtitle(item))")
                    .accessibilityHint("Opens the details")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .sheet(item: $open) { WatcherItemSheet(item: $0, store: store) }
        }
    }
}

struct WatcherItemSheet: View {
    let item: InboxItem
    let store: WatcherStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var notice: String?
    @State private var copied = false

    static func subtitle(_ i: InboxItem) -> String {
        var parts = [(i.repo as NSString).lastPathComponent]
        if let n = i.note { parts.append(n) } else if i.report == nil { parts.append("Evidence only") }
        if i.lookedFixed { parts.append("Looks fixed") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Always read the live copy: the store folds new events while the sheet is open.
    private var live: InboxItem { store.items.first { $0.id == item.id } ?? item }

    var body: some View {
        let it = live
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "eye").foregroundStyle(Theme.verdictWarn).accessibilityHidden(true)
                Text(it.report?.title ?? it.title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let r = it.report {
                        block("What happened", r.what)
                        block("Likely cause", r.cause + (r.sure.isEmpty ? "" : "  (\(r.sure))"))
                        block("Suggested fix", r.fix.summary + (r.fix.steps.isEmpty ? "" : "\n" + r.fix.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")))
                        if !r.unknowns.isEmpty { block("Not sure about", r.unknowns.joined(separator: "\n")) }
                    } else {
                        block("Evidence", it.evidence)
                        if it.canInvestigate { Text("The Watcher has not looked into this yet.").font(.callout).foregroundStyle(Theme.hubSecondary) }
                    }
                    if let n = it.note { Text(n).font(.callout).foregroundStyle(Theme.hubSecondary) }
                    if let n = notice { Text(n).font(.callout).foregroundStyle(Theme.text) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Menu("Not useful") {
                    ForEach(WatcherStore.rejectReasons, id: \.self) { r in Button(r) { store.reject(it.id, reason: r); dismiss() } }
                }.fixedSize()
                Spacer()
                if it.report == nil && it.canInvestigate {
                    Button("Look into it") { busy = true; Task { await store.investigate(it.id); busy = false } }.disabled(busy)
                }
                if it.report != nil && it.level == .askFirst {
                    Button("Approve fix") { busy = true; Task { notice = Self.text(await store.approve(it.id)); busy = false } }
                        .buttonStyle(.borderedProminent).disabled(busy || it.state != .open)
                } else if let r = it.report, it.level == .handOff {
                    Button(copied ? "Copied" : "Copy steps") { Self.copy(r); copied = true }
                }
            }
        }
        .padding(20).frame(width: 480, height: 460)
        .background(Theme.background)
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(Theme.hubSecondary)
            Text(body).font(.body).foregroundStyle(Theme.text).textSelection(.enabled)
        }
    }

    static func text(_ r: WatcherStore.ApproveResult) -> String {
        switch r {
        case .started(let id): "Fix started as builder \(id)"
        case .handOff: "This one is yours to do. Use Copy steps."
        case .refused(let why): why
        }
    }

    static func copy(_ r: ItemReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.fix.text, forType: .string)
    }
}
