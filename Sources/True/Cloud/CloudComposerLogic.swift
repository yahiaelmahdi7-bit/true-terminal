import Foundation
import Observation

/// What the composer's repo picker shows for one folder. Built from three read-only git calls; the parsing is
/// pure (`parse`) so it tests without a repo.
struct CloudRepoInfo: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case ready, notGit, noCommit }
    var path: String
    var kind: Kind = .ready
    var branch = ""
    var sha = ""
    var subject = ""
    var committedAt: Double?
    var dirtyCount = 0

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var shortSha: String { String(sha.prefix(7)) }
    var isRunnable: Bool { kind == .ready }

    /// "clean" / "3 uncommitted changes · won't be sent": only committed work is synced.
    var stateLabel: String {
        switch kind {
        case .notGit: return "Not a git repo"
        case .noCommit: return "No commits yet"
        case .ready:
            if dirtyCount == 0 { return "clean" }
            return "\(dirtyCount) uncommitted change\(dirtyCount == 1 ? "" : "s") · won't be sent"
        }
    }

    /// Inline error for a folder that can't run, nil when it can.
    var problem: String? {
        switch kind {
        case .notGit: return "\(name) isn't a git repo. The cloud works on a committed copy, so pick a repo."
        case .noCommit: return "\(name) has no commits yet. Make a first commit, then run it."
        case .ready: return nil
        }
    }

    /// `log` = `%H\u{1f}%s\u{1f}%ct` of HEAD (empty when there are none), `branch` = `rev-parse --abbrev-ref HEAD`,
    /// `porcelain` = `status --porcelain`. `isGit` is whether git recognised the folder at all.
    static func parse(path: String, isGit: Bool, log: String, branch: String, porcelain: String) -> CloudRepoInfo {
        guard isGit else { return CloudRepoInfo(path: path, kind: .notGit) }
        let f = log.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard f.count == 3, f[0].count >= 40 else { return CloudRepoInfo(path: path, kind: .noCommit) }
        let dirty = porcelain.split(whereSeparator: \.isNewline).count
        let b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudRepoInfo(path: path, kind: .ready, branch: b == "HEAD" ? "detached" : b, sha: f[0], subject: f[1],
                             committedAt: Double(f[2].trimmingCharacters(in: .whitespacesAndNewlines)), dirtyCount: dirty)
    }

    /// Read-only git reads. Call off the main thread.
    static func read(path: String, run: CloudRun = cloudRunLive) -> CloudRepoInfo {
        let git = "/usr/bin/git"
        guard run(git, ["-C", path, "rev-parse", "--is-inside-work-tree"]).status == 0 else {
            return parse(path: path, isGit: false, log: "", branch: "", porcelain: "")
        }
        let log = run(git, ["-C", path, "log", "-1", "--format=%H%x1f%s%x1f%ct"])
        let branch = run(git, ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        let status = run(git, ["-C", path, "status", "--porcelain"])
        return parse(path: path, isGit: true, log: log.status == 0 ? log.out : "",
                     branch: branch.status == 0 ? branch.out : "", porcelain: status.status == 0 ? status.out : "")
    }

    /// "now", "5m", "3h", "2d", "6w".
    static func age(of ts: Double?, now: Double) -> String {
        guard let ts else { return "" }
        let s = max(now - ts, 0)
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60))m"
        case ..<86_400: return "\(Int(s / 3600))h"
        case ..<(86_400 * 14): return "\(Int(s / 86_400))d"
        default: return "\(Int(s / (86_400 * 7)))w"
        }
    }
}

/// The three choices the composer remembers between runs.
struct CloudPrefs {
    var defaults: UserDefaults = .standard
    static let repoKey = "cloud.lastRepo", modelKey = "cloud.lastModel", effortKey = "cloud.lastEffort"

    var repo: String? {
        get { defaults.string(forKey: Self.repoKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.repoKey) }
    }
    var model: String {
        get { defaults.string(forKey: Self.modelKey) ?? CloudModel.defaultID }
        nonmutating set { defaults.set(newValue, forKey: Self.modelKey) }
    }
    var effort: String {
        get { defaults.string(forKey: Self.effortKey) ?? CloudModel.defaultEffort }
        nonmutating set { defaults.set(newValue, forKey: Self.effortKey) }
    }
}

enum CloudSendStep: Int, CaseIterable, Sendable {
    case packing, uploading, starting
    var label: String {
        switch self {
        case .packing: return "Packing repo"
        case .uploading: return "Uploading"
        case .starting: return "Starting job"
        }
    }
}

enum CloudSendState: Equatable {
    case idle
    case running(CloudSendStep)
    case failed(CloudSendStep, String)
}

enum CloudComposerLink: Equatable { case checking, online, offline }

/// The composer's state. Side effects (git reads, sync, HTTP) are injected so the snapshot tests can drive every
/// state without touching the cloud.
@MainActor
@Observable
final class CloudComposerModel {
    var repos: [CloudRepoInfo] = []
    var loadingRepos = false
    var selected: CloudRepoInfo?
    var search = ""
    var cursor = 0
    var prompt = ""
    var title = ""
    var model: String
    var effort: String
    var showMore = false
    var health: CloudHealth?
    var link: CloudComposerLink = .checking
    var runningJobs = 0
    var send: CloudSendState = .idle

    @ObservationIgnored let prefs: CloudPrefs
    @ObservationIgnored let projects: [String]

    init(projects: [String], prefs: CloudPrefs = CloudPrefs()) {
        self.projects = projects
        self.prefs = prefs
        model = prefs.model
        effort = prefs.effort
    }

    var models: [CloudModel] { health?.models ?? CloudModel.builtIn }
    var efforts: [String] { health?.efforts ?? CloudModel.builtInEfforts }

    var filtered: [CloudRepoInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? repos : repos.filter { $0.name.lowercased().contains(q) || $0.branch.lowercased().contains(q) }
    }
    var showsSearch: Bool { repos.count > 6 }

    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSending: Bool { if case .running = send { return true } else { return false } }
    var canRun: Bool { link == .online && (selected?.isRunnable ?? false) && !trimmedPrompt.isEmpty && !isSending }

    /// Placeholder for the optional title: the task's first line.
    var titlePlaceholder: String {
        let first = trimmedPrompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Defaults to the first line of the task"
        return String(first.prefix(70))
    }

    /// What Run is blocked on, in words (nil when it can run).
    var blocker: String? {
        if link == .offline { return "The cloud isn't reachable" }
        if selected == nil { return "Pick a repo" }
        if selected?.isRunnable == false { return selected?.problem }
        if trimmedPrompt.isEmpty { return "Describe the job" }
        return nil
    }

    func loadRepos(read: @escaping @Sendable (String) -> CloudRepoInfo = { CloudRepoInfo.read(path: $0) }) async {
        loadingRepos = true
        let paths = Array(NSOrderedSet(array: projects.filter { !$0.isEmpty })) as? [String] ?? projects
        let infos: [CloudRepoInfo] = await Task.detached {
            await withTaskGroup(of: CloudRepoInfo.self) { g in
                for p in paths { g.addTask { read(p) } }
                var out: [CloudRepoInfo] = []
                for await i in g { out.append(i) }
                return out
            }
        }.value
        // Newest work first; a folder git doesn't know is left out of the recents (Choose folder… still reaches it).
        repos = infos.filter(\.isRunnable).sorted { ($0.committedAt ?? 0) > ($1.committedAt ?? 0) }
        loadingRepos = false
        if selected == nil, let last = prefs.repo, let hit = repos.first(where: { $0.path == last }) { selected = hit }
    }

    func choose(_ info: CloudRepoInfo) {
        selected = info
        prefs.repo = info.path
        if !repos.contains(where: { $0.path == info.path }), info.isRunnable { repos.insert(info, at: 0) }
    }

    /// A folder from the open panel: read it off-main, then select it (non-git shows the inline error).
    func chooseFolder(_ path: String, read: @escaping @Sendable (String) -> CloudRepoInfo = { CloudRepoInfo.read(path: $0) }) async {
        let info = await Task.detached { read(path) }.value
        choose(info)
    }

    func clearSelection() { selected = nil; search = ""; cursor = 0 }

    func moveCursor(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        cursor = min(max(cursor + delta, 0), n - 1)
    }

    func pickCursor() {
        let list = filtered
        if list.indices.contains(cursor) { choose(list[cursor]) }
    }

    func refreshHealth(client: CloudClient, running: Int) async {
        runningJobs = running
        do {
            health = try await client.health()
            link = .online
            if !models.contains(where: { $0.id == model }) { model = health?.defaultModel ?? models.first?.id ?? model }
            if !efforts.contains(effort) { effort = efforts.contains(CloudModel.defaultEffort) ? CloudModel.defaultEffort : (efforts.first ?? effort) }
        } catch {
            // Old server or a hiccup: the built-in lists stay. Only a transport/auth failure means offline.
            if let e = error as? CloudError, case .http = e { link = .online } else if let e = error as? CloudError, e == .bad { link = .online } else { link = .offline }
        }
    }

    var statusLine: String {
        switch link {
        case .checking: return "Checking the cloud…"
        case .offline: return "Cloud offline · can't run right now"
        case .online:
            if let h = health { var c = h; if c.running == nil { c.running = runningJobs }; return c.statusLine }
            return "Connected · streambox · \(runningJobs) running"
        }
    }

    /// The whole send: pack → upload (inside `sync`) → create. Inputs stay as they are on failure; `send` says
    /// which step broke so the sheet can show Retry on it.
    func run(client: CloudClient, sync: @escaping @Sendable (String, @escaping @Sendable (CloudSendStep) -> Void) throws -> CloudSync.Result,
             onDone: () -> Void) async {
        guard canRun, let repo = selected else { return }
        prefs.model = model; prefs.effort = effort; prefs.repo = repo.path
        let (text, ttl, mdl, eff) = (trimmedPrompt, title.trimmingCharacters(in: .whitespacesAndNewlines), model, effort)
        send = .running(.packing)
        let box = StepBox()
        let outcome: Result<CloudSync.Result, Error> = await Task.detached {
            Result { try sync(repo.path) { step in
                box.set(step)
                Task { @MainActor in if self.isSending { self.send = .running(step) } }
            } }
        }.value
        switch outcome {
        case .failure(let e):
            send = .failed(box.value, e.localizedDescription)
            return
        case .success(let r):
            send = .running(.starting)
            do {
                _ = try await client.create(repo: r.repoName, job: text, title: ttl.isEmpty ? nil : ttl, base: r.sha, model: mdl, effort: eff)
                await CloudStore.shared.refresh()
                send = .idle
                onDone()
            } catch {
                send = .failed(.starting, error.localizedDescription)
            }
        }
    }
}

final class StepBox: @unchecked Sendable {
    private let lock = NSLock()
    private var step = CloudSendStep.packing
    func set(_ s: CloudSendStep) { lock.withLock { step = s } }
    var value: CloudSendStep { lock.withLock { step } }
}
