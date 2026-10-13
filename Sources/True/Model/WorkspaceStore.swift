import Foundation

/// Reads/writes `~/.true/workspace.json`. Never throws to the caller: a missing, corrupt or
/// inconsistent file means "start fresh" (the bad file is kept as `workspace.corrupt.json`).
struct WorkspaceStore: Sendable {
    let url: URL

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/workspace.json")
    }

    init(url: URL = WorkspaceStore.defaultURL) { self.url = url }

    func load() -> WorkspaceState {
        guard let data = try? Data(contentsOf: url) else { return .fresh() }
        if let state = try? JSONDecoder().decode(WorkspaceState.self, from: data), state.isConsistent {
            return state
        }
        let aside = url.deletingLastPathComponent().appendingPathComponent("workspace.corrupt.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return .fresh()
    }

    func save(_ state: WorkspaceState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("True: workspace save failed: \(error)")
        }
    }
}
