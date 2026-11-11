import SwiftUI

/// The "Needs you" badge for the tab bar. Zero footprint while nobody is blocked; a static count
/// otherwise; click (or ⇧⌘U) for the list of agents waiting on a permission answer.
struct NeedsYouTray: View {
    private let queue = NeedsYouQueue.shared

    var body: some View {
        let rows = queue.rows
        let calls = queue.calls
        let total = rows.count + calls.count
        if total == 0 {
            EmptyView()
        } else {
            @Bindable var q = queue
            Button { queue.trayOpen.toggle() } label: {
                Label("\(total)", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).frame(minHeight: Theme.Hit.control)
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
            .controlSize(.small)
            .help(total == 1 ? "1 thing needs you  ⇧⌘U" : "\(total) things need you  ⇧⌘U")
            .popover(isPresented: $q.trayOpen, arrowEdge: .bottom) { NeedsYouList(rows: rows, calls: calls) }
        }
    }
}

private struct NeedsYouList: View {
    let rows: [NeedsYouRow]
    var calls: [NeedsYouCall] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    NeedsYouRowView(row: row)
                    if row.id != rows.last?.id || !calls.isEmpty { Divider() }
                }
                ForEach(calls) { call in
                    NeedsYouCallView(call: call)
                    if call.id != calls.last?.id { Divider() }
                }
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 420)
    }
}

private struct NeedsYouCallView: View {
    let call: NeedsYouCall

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "person.fill.questionmark").font(.caption).foregroundStyle(.secondary)
                Text(call.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                if let what = call.what {
                    Text(what).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .rect(cornerRadius: 3))
                }
            }
            if let q = call.question {
                Text(q).font(.callout).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct NeedsYouRowView: View {
    let row: NeedsYouRow
    private let queue = NeedsYouQueue.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(row.color).frame(width: 7, height: 7)
                Text(row.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(Self.age(row.since)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(row.question).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let tool = row.tool {
                HStack(spacing: 6) {
                    Text(tool).font(.caption.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .rect(cornerRadius: 3))
                    if let detail = row.detail {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            HStack(spacing: 8) {
                actionButton("Allow") { queue.answer(row, approve: true) }
                actionButton("Deny") { queue.answer(row, approve: false) }
                actionButton("Jump") { queue.jump(to: row.paneID) }
                Spacer()
                if let note = Self.note(row.status) {
                    Text(note).font(.caption).foregroundStyle(Theme.text)
                }
            }
            .disabled(row.status == .sending)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func actionButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout.weight(.medium))
                .padding(.horizontal, Theme.Space.s4).frame(minWidth: Theme.Hit.control, minHeight: Theme.Hit.control)
        }
        .buttonStyle(PillButtonStyle(shape: Capsule(), rest: Theme.Token.text0, hover: Theme.Token.text0,
                                     fill: Theme.Token.pressFill, hoverFill: Theme.Token.strongLine))
    }

    private static func note(_ s: NeedsYouRow.Status) -> String? {
        switch s {
        case .idle: return nil
        case .sending: return "sending…"
        case .promptGone: return "prompt gone — Jump to check"
        case .unconfirmed: return "sent — not confirmed"
        }
    }

    /// "45s", "2m", "1h" — coarse on purpose.
    static func age(_ since: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
