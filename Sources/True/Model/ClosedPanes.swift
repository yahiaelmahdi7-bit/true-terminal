import Foundation
import Observation
import Darwin

/// Where a closed pane sat, read from its tab's tree before removal. nil `axis` = it was alone (or a whole tab).
struct ClosedPlace: Codable, Equatable, Sendable {
    var tabID: UUID
    var tabIndex: Int
    var axis: SplitTree.Axis?
    var before: Bool
    var siblingLeaves: [UUID]
    var anchorLeaf: UUID?
}

/// One undoable close: a slice of the existing `TabState` (so resume records, cwds, interrupted marks and custom
/// names are reused), where it sat, and when. ⌘W stores a one-pane slice; a tab ✕ stores the whole tab.
struct ClosedEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var closedAt: Date
    /// This True launch (an in-memory constant): marks and the ⌘Z gate only trust closes from the same launch.
    var launchID: UUID
    var title: String
    var tab: TabState
    var wholeTab: Bool
    var place: ClosedPlace

    /// Every pane this entry brings back.
    var panes: [UUID] { tab.tree.leafIDs }

    /// Old id → new id applied to this entry's `place` (chains: a pane, then its tab).
    func remapped(_ alias: [UUID: UUID]) -> ClosedEntry {
        var e = self
        e.place.tabID = alias[place.tabID] ?? place.tabID
        e.place.siblingLeaves = place.siblingLeaves.map { alias[$0] ?? $0 }
        e.place.anchorLeaf = place.anchorLeaf.map { alias[$0] ?? $0 }
        return e
    }
}

/// The stack of closes, newest first. Persisted to `closed.json` on every change, synchronously: the last-pane
/// close calls `saveNow()` then `NSApp.terminate`.
@MainActor
@Observable
final class ClosedStack {
    static let maxEntries = 20
    static let maxScrollbackBytes = 40 * 1024 * 1024
    static let fileVersion = 1

    private(set) var entries: [ClosedEntry] = []
    @ObservationIgnored let url: URL
    @ObservationIgnored let scrollback: ScrollbackStore
    @ObservationIgnored let maxEntries: Int
    @ObservationIgnored let maxBytes: Int
    /// The old Claude pid per entry, for the reopen race. Never persisted.
    @ObservationIgnored var pids: [UUID: [pid_t]] = [:]

    static var defaultURL: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/closed.json") }
    static var defaultScrollbackDir: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/closed-scrollback") }
    static let standard = ClosedStack()

    init(url: URL = ClosedStack.defaultURL, scrollback: ScrollbackStore = ScrollbackStore(dir: ClosedStack.defaultScrollbackDir),
         maxEntries: Int = ClosedStack.maxEntries, maxBytes: Int = ClosedStack.maxScrollbackBytes) {
        self.url = url
        self.scrollback = scrollback
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    var newest: ClosedEntry? { entries.first }
    func entry(_ id: UUID) -> ClosedEntry? { entries.first { $0.id == id } }

    // MARK: Changes (each one writes the file)

    func push(_ e: ClosedEntry, pids pidList: [pid_t] = []) {
        entries.insert(e, at: 0)
        if !pidList.isEmpty { pids[e.id] = pidList }
        trim()
        save()
    }

    /// Take one out (it was reopened). Its scrollback is NOT deleted here: reopen moves it first.
    @discardableResult
    func take(_ id: UUID) -> ClosedEntry? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        pids[id] = nil
        let e = entries.remove(at: i)
        save()
        return e
    }

    /// Drop one and delete its scrollback.
    func remove(_ id: UUID) {
        guard let e = take(id) else { return }
        for p in e.panes { scrollback.remove(p) }
    }

    /// Apply an alias map to every remaining entry's place, then write.
    func remap(_ alias: [UUID: UUID]) {
        entries = entries.map { $0.remapped(alias) }
        save()
    }

    /// Past the caps the oldest entries go, scrollback and all. The newest always stays.
    private func trim() {
        while entries.count > maxEntries { dropOldest() }
        while entries.count > 1, scrollbackBytes() > maxBytes { dropOldest() }
    }

    private func dropOldest() {
        guard let e = entries.popLast() else { return }
        pids[e.id] = nil
        for p in e.panes { scrollback.remove(p) }
    }

    func scrollbackBytes() -> Int {
        let fm = FileManager.default
        var total = 0
        for e in entries {
            for p in e.panes {
                let f = scrollback.dir.appendingPathComponent("\(p.uuidString).ans")
                total += ((try? fm.attributesOfItem(atPath: f.path))?[.size] as? Int) ?? 0
            }
        }
        return total
    }

    // MARK: Disk

    private struct File: Codable { var version: Int; var entries: [ClosedEntry] }
    /// One bad entry must not cost the rest: it decodes to nil and is skipped.
    private struct Lossy: Decodable {
        var entry: ClosedEntry?
        init(from d: Decoder) throws { entry = try? ClosedEntry(from: d) }
    }
    private struct LossyFile: Decodable { var entries: [Lossy] }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .secondsSince1970; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }

    func save() {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.encoder.encode(File(version: Self.fileVersion, entries: entries)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("True: closed.json save failed: \(error)")
        }
    }

    /// Launch: read the file (per entry), move an unreadable one aside, then sweep orphan scrollback.
    func load() {
        guard let data = try? Data(contentsOf: url) else { entries = []; sweep(); return }
        if let f = try? Self.decoder.decode(LossyFile.self, from: data) {
            entries = f.entries.compactMap(\.entry).sorted { $0.closedAt > $1.closedAt }
            trim()
        } else {
            let aside = url.deletingLastPathComponent().appendingPathComponent("closed.corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            entries = []
        }
        sweep()
    }

    /// Scrollback files not referenced by an entry are deleted.
    func sweep() { scrollback.prune(keeping: Set(entries.flatMap(\.panes))) }
}

/// What ⌘Z does. Pure, so the table is testable without a window.
enum UndoCloseRoute: Equatable {
    case forwardUndo
    case reopen(UUID)
    case beep

    /// ⌘Z only reopens a close from this launch that is under this old.
    static let maxAge: TimeInterval = 5 * 60

    static func decide(keyWindowIsMain: Bool, responderIsText: Bool, newest: ClosedEntry?, now: Date, launchID: UUID) -> UndoCloseRoute {
        if !keyWindowIsMain || responderIsText { return .forwardUndo }
        guard let e = newest, e.launchID == launchID, now.timeIntervalSince(e.closedAt) < maxAge else { return .beep }
        return .reopen(e.id)
    }

    /// Menu title: names the close when ⌘Z would reopen it, else plain "Undo".
    static func title(newest: ClosedEntry?, now: Date, launchID: UUID) -> String {
        guard case .reopen = decide(keyWindowIsMain: true, responderIsText: false, newest: newest, now: now, launchID: launchID),
              let e = newest else { return "Undo" }
        return e.wholeTab ? "Undo Close Tab" : "Undo Close Pane"
    }
}

/// The reopen race: the closed Claude may still be shutting down when ⌘Z lands.
enum ClosedReopen {
    /// Wait for `pid` to exit; SIGKILL after `timeout` (as `AgentRegistry.sleep` does), then return.
    @MainActor static func waitForExit(pid: pid_t, timeout: TimeInterval = 3, poll: Duration = .milliseconds(100),
                            isAlive: @escaping (pid_t) -> Bool = { kill($0, 0) == 0 },
                            kill: @escaping (pid_t) -> Void = { _ = Darwin.kill(-$0, SIGKILL); _ = Darwin.kill($0, SIGKILL) }) async {
        let start = Date()
        while isAlive(pid) {
            if Date().timeIntervalSince(start) >= timeout { kill(pid); return }
            try? await Task.sleep(for: poll)
        }
    }

    /// The interrupted mark survives only a quick reopen in the same launch, and never on a desk pane.
    static func keepsMark(_ e: ClosedEntry, now: Date, launchID: UUID) -> Bool {
        e.launchID == launchID && now.timeIntervalSince(e.closedAt) < UndoCloseRoute.maxAge
    }
}
