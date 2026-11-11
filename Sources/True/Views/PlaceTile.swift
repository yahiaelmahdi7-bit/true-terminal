import SwiftUI

/// One Mac in the Place tile: this Mac, or a peer the pane's repo is shared with.
struct PlaceRow: Equatable, Identifiable {
    var id: String
    var name: String
    /// The working folder as a full path; "" when unknown (the folder line is then left out).
    var folder: String
    var isThisMac = false
    /// Peers only. Offline rows are dimmed; this Mac is always online.
    var online = true
    /// Peers only: when an offline peer was last seen; nil = unknown.
    var lastSeen: Date?
    /// Peers only: "+1" when the peer sent more folders than the one shown.
    var moreFolders = 0
    /// Peers only: shown in place of a folder line ("Folder not shared yet" for an older True).
    var note: String?

    /// Peers only: the peer's own label, what a cleared nickname falls back to.
    var label = ""
    /// Only a teammate's row can be renamed.
    var canRename: Bool { !isThisMac }

    var dimmed: Bool { !isThisMac && !online }
    /// Only this Mac's row has the Reveal button.
    var hasRevealButton: Bool { isThisMac }

    /// `~`-abbreviated; middle truncation happens in the view.
    static func shortFolder(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !path.isEmpty else { return "" }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The secondary line under an offline peer's name: "last seen 14:05", "last seen 8 Nov", or "offline".
    /// nil for this Mac and for online peers. Clock, calendar and zone are injected so tests are deterministic.
    func offlineLine(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard dimmed else { return nil }
        guard let seen = lastSeen else { return "offline" }
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = calendar.isDate(seen, inSameDayAs: now) ? "HH:mm" : "d MMM"
        return "last seen " + f.string(from: seen)
    }

    /// One label per row: "Alex's MacBook, ~/code/true, last seen 14:05".
    func accessibilityText(now: Date = Date(), calendar: Calendar = .current) -> String {
        [name, Self.shortFolder(folder), offlineLine(now: now, calendar: calendar) ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var accessibilityText: String { accessibilityText() }
}

enum PlaceLayout {
    static let collapsedRows = 3
    /// You first, then online teammates, then offline ones; each group sorted by name (stable for equal names).
    static func order(_ rows: [PlaceRow]) -> [PlaceRow] {
        func group(_ r: PlaceRow) -> Int { r.isThisMac ? 0 : (r.online ? 1 : 2) }
        let indexed = rows.enumerated().sorted { a, b in
            let (ga, gb) = (group(a.element), group(b.element))
            if ga != gb { return ga < gb }
            let c = a.element.name.localizedCaseInsensitiveCompare(b.element.name)
            return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
        }
        return indexed.map(\.element)
    }
    /// All rows when expanded, else the first three; the disclosure exists past three.
    static func visible(_ rows: [PlaceRow], expanded: Bool) -> (rows: [PlaceRow], hasDisclosure: Bool) {
        let all = order(rows)
        return (expanded ? all : Array(all.prefix(collapsedRows)), all.count > collapsedRows)
    }
}

/// The Macs working on this pane's repo. Pure view: rows and actions come in.
struct PlaceList: View {
    let rows: [PlaceRow]
    var onReveal: () -> Void = {}
    var now = Date()
    var calendar = Calendar.current
    /// (peer id, new name); an empty name clears the nickname.
    var onRename: (String, String) -> Void = { _, _ in }
    /// Stills only: a real TextField does not render offscreen, so the field is drawn as text with a caret.
    var flatField = false
    @State private var expanded: Bool
    @State private var editing: String?
    @State private var draft = ""
    /// Names typed this session, so the row changes at once without waiting for the panel to rebuild.
    @State private var renamed: [String: String] = [:]
    @FocusState private var focused: Bool

    init(rows: [PlaceRow], expanded: Bool = false, now: Date = Date(), calendar: Calendar = .current,
         editing: String? = nil, draft: String = "", flatField: Bool = false,
         onReveal: @escaping () -> Void = {}, onRename: @escaping (String, String) -> Void = { _, _ in }) {
        self.flatField = flatField; self.rows = rows; self.onReveal = onReveal; self.onRename = onRename; self.now = now; self.calendar = calendar
        _expanded = State(initialValue: expanded); _editing = State(initialValue: editing); _draft = State(initialValue: draft)
    }

    private func shownName(_ r: PlaceRow) -> String {
        guard let n = renamed[r.id] else { return r.name }
        return n.isEmpty ? (r.label.isEmpty ? r.name : r.label) : n
    }
    private func commit(_ r: PlaceRow) {
        let n = PeerNicknames.clean(draft)
        renamed[r.id] = n; editing = nil; onRename(r.id, n)
    }

    var body: some View {
        let v = PlaceLayout.visible(rows, expanded: expanded)
        VStack(spacing: 0) {
            ForEach(v.rows) { line($0) }
            if v.hasDisclosure {
                Button { withAnimation(Motion.list.spring) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(AgentsCopy.all(rows.count)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.Token.text2)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.Token.text2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? AgentsCopy.showFewer : AgentsCopy.all(rows.count))
            }
        }
    }

    private func line(_ r: PlaceRow) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").font(.system(size: 16)).foregroundStyle(Theme.Token.text2).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    if editing == r.id, flatField {
                        Text(draft + "▏").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Token.text0)
                            .padding(.vertical, 2).overlay(alignment: .bottom) { Rectangle().fill(Theme.Token.text2).frame(height: 1) }
                    } else if editing == r.id {
                        TextField(GroupCopy.renamePlaceholder, text: $draft)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Token.text0)
                            .focused($focused).onSubmit { commit(r) }.onExitCommand { editing = nil }
                            .padding(.vertical, 2).overlay(alignment: .bottom) { Rectangle().fill(Theme.Token.text2).frame(height: 1) }
                            .onAppear { focused = true }
                    } else {
                        Text(shownName(r)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.Token.text0)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if let off = r.offlineLine(now: now, calendar: calendar) {
                        Text(off).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.Token.text2).lineLimit(1)
                    }
                    if let note = r.note {
                        Text(note).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.Token.text2).lineLimit(1)
                    } else if !r.folder.isEmpty {
                        Text((r.isThisMac ? PlaceRow.shortFolder(r.folder) : r.folder) + (r.moreFolders > 0 ? "  " + GroupCopy.moreFolders(r.moreFolders) : "")).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.Token.text2).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
            }
            .opacity(r.dimmed ? AgentsPill.idleOpacity : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(({ var x = r; x.name = shownName(r); return x })().accessibilityText(now: now, calendar: calendar))
            .contextMenu {
                if r.canRename { Button(GroupCopy.rename) { draft = shownName(r); editing = r.id } }
            }
            if r.hasRevealButton {
                Button(action: onReveal) {
                    Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(Theme.Token.text1)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(TaskDetailCopy.showInFinder).accessibilityLabel(TaskDetailCopy.showInFinder)
            }
        }
        .padding(.horizontal, 8).frame(minHeight: Theme.Hit.control).padding(.vertical, 2)
    }
}
