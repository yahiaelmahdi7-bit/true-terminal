import SwiftUI

/// Run 32 — the Hub's Chat tab: channels on the left, the last 200 lines on the right, a box that sends.
/// ⌘↩ sends; typing `@` completes agent names. Reloads when the bus or the peers change (no timers).
struct ChatView: View {
    var roster: [String]
    @State private var channels: [(channel: String, members: [String], last: ChatMessage?)] = []
    @State private var selected = "#here"
    @State private var lines: [ChatMessage] = []
    @State private var presence: [String: Int] = [:]
    @State private var draft = ""
    @State private var note: String?

    private var bus: ChatBus? { PeerService.engine.chat }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                transcript
                composer
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .peersChanged)) { _ in reload() }
        .onChange(of: selected) { _, _ in reload() }
    }

    private var sidebar: some View {
        List(selection: $selected) {
            Section("Channels") {
                ForEach(channels, id: \.channel) { c in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.channel).font(.callout.weight(.medium))
                        if !c.members.isEmpty { Text(c.members.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }.tag(c.channel)
                }
            }
            if !presence.isEmpty {
                Section("Active") {
                    ForEach(presence.sorted { $0.value > $1.value }.prefix(8), id: \.key) { p in
                        Text("\(p.key) · \(Self.ago(p.value))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty { Text("Nothing here yet").foregroundStyle(.secondary).padding(.top, 20) }
                    ForEach(lines) { m in
                        (Text(m.from.agent).fontWeight(.semibold) + Text(m.from.mac.isEmpty ? "" : " · \(m.from.mac)").foregroundStyle(.secondary)
                            + Text("  ") + Text(m.text)).font(.callout).textSelection(.enabled).id(m.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: lines.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hint = completions.first {
                Button("↹ \(hint)") { complete(hint) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .bottom) {
                TextField("Message \(selected) — @ names an agent", text: $draft, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                Button("Send", action: send).keyboardShortcut(.return, modifiers: .command).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
    }

    /// Agent names that complete the `@word` being typed at the end of the draft.
    private var completions: [String] {
        guard let r = draft.range(of: #"@[A-Za-z0-9_-]*$"#, options: .regularExpression) else { return [] }
        let word = draft[r].dropFirst().lowercased()
        return roster.filter { $0.lowercased().hasPrefix(word) && $0.lowercased() != word }.prefix(3).map { $0 }
    }

    private func complete(_ name: String) {
        if let r = draft.range(of: #"@[A-Za-z0-9_-]*$"#, options: .regularExpression) { draft.replaceSubrange(r, with: "@" + name + " ") }
    }

    private func send() {
        switch PeerService.engine.postChat(channel: selected, agent: "human", text: draft) {
        case .success: draft = ""; note = nil
        case .failure(.invalid(let why)): note = why
        }
        reload()
    }

    private func reload() {
        guard let bus else { channels = []; lines = []; return }
        channels = bus.channels()
        if !channels.contains(where: { $0.channel == selected }), let f = channels.first { selected = f.channel }
        lines = bus.tail(selected, last: 200)
        presence = bus.presence()
    }

    static func ago(_ ts: Int) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970) - ts)
        return s < 60 ? "active just now" : "active \(s / 60) min ago"
    }
}
