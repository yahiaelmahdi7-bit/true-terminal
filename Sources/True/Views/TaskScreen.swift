import SwiftUI

/// Which task the screen shows. Builders and seats resolve to a `TaskDetail` off the main thread.
enum TaskTarget: Identifiable {
    case builder(BuilderRecord)
    case seat(Agent, AgentTurn)
    case folder(String)
    /// One mission job; `folder` is the job's worktree ("" until its worker has started).
    case mission(MissionTaskInfo, folder: String, provider: String)
    var id: String {
        switch self {
        case .builder(let b): "b-" + b.id
        case .seat(let a, let t): "s-" + a.name + t.id.uuidString
        case .folder(let f): "f-" + f
        case .mission(let m, _, _): "m-" + m.branch
        }
    }

    /// Reads git, the gate file and the allowance. Never call on the main thread.
    func load() -> (detail: TaskDetail, report: String) {
        switch self {
        case .builder(let b):
            let report = HubScanner.detail(of: b)
            let reset = TaskUsageLimit.read()
            return (TaskDetail.builder(b, owner: TaskDetailCopy.me, provider: Self.provider(b.model), report: report, allowanceReset: reset), report)
        case .seat(let agent, let turn):
            return (TaskDetail.seat(agent, turn: turn, reset: nil), "")
        case .mission(let m, let folder, let provider):
            let checks: TaskChecks = m.job.check == nil ? .noCheck : .notRun
            return (TaskDetail.mission(job: m.job, progress: m.progress, folder: folder, base: m.base, branch: m.branch,
                                       checks: checks, owner: TaskDetailCopy.me, provider: provider), "")
        case .folder(let folder):
            let changes = TaskChangesReader(folder: folder).read()
            let branch = TaskGit(folder: folder).value(["branch", "--show-current"]) ?? ""
            let name = URL(fileURLWithPath: folder).lastPathComponent
            return (TaskDetail(title: name, owner: TaskDetailCopy.me, provider: "", branch: branch,
                               state: TaskStateLine(text: "", nextAction: ""), finished: false, checks: .notRun,
                               merged: changes.merged, changes: changes, report: ""), "")
        }
    }
    /// The builder's result.md, which the PR text is built from.
    var resultFile: String? {
        if case .builder(let b) = self { return b.dir.map { $0 + "/result.md" } }
        return nil
    }
    var isSeat: Bool { if case .seat = self { true } else { false } }
    var isFolder: Bool { if case .folder = self { true } else { false } }
    static func provider(_ model: String) -> String {
        model.lowercased().contains("gpt") || model.lowercased().contains("codex") ? TaskDetailCopy.codex
            : model.lowercased().contains("deepseek") ? TaskDetailCopy.deepSeek : TaskDetailCopy.claude
    }
}

/// Loads a task and its diffs without touching git on the main thread; a diff loads only when its row opens.
@MainActor @Observable
final class TaskScreenModel {
    var detail: TaskDetail?
    var diffs: [String: String] = [:]
    var open: String?
    var pages = 1
    let target: TaskTarget
    /// The gate / PR line; nil for tasks that have none (main, folders, no branch).
    var pr: TaskPRModel?
    init(_ target: TaskTarget) { self.target = target }

    func load() async {
        let target = target
        let loaded = await Task.detached(priority: .utility) { target.load().detail }.value
        detail = loaded
        // The line belongs to a task on its own branch; a folder shows changes only.
        guard !target.isFolder, !target.isSeat, !loaded.branch.isEmpty, loaded.branch != "main" else { return }
        let model = TaskPRModel(folder: folder, branch: loaded.branch, name: loaded.title, resultFile: target.resultFile)
        pr = model
        await model.load()
    }

    func toggle(_ file: TaskChangedFile, uncommitted: Bool) {
        let key = Self.key(file, uncommitted)
        if open == key { open = nil; return }
        open = key
        guard diffs[key] == nil, let detail else { return }
        let changes = detail.changes
        let folder = folder
        Task {
            let text = await Task.detached(priority: .utility) {
                TaskChangesReader(folder: folder).diff(file, changes: changes, uncommitted: uncommitted)
            }.value
            diffs[key] = text ?? TaskDetailCopy.noDiff
        }
    }

    var folder: String {
        switch target {
        case .builder(let b): b.worktree ?? b.cwd
        case .seat(_, let t): t.folder
        case .folder(let f): f
        case .mission(_, let f, _): f
        }
    }
    static func key(_ f: TaskChangedFile, _ uncommitted: Bool) -> String { (uncommitted ? "u:" : "c:") + f.path }
}

/// The sheet: loads, then shows `TaskScreenView`.
struct TaskScreen: View {
    let target: TaskTarget
    var onResume: (() -> Void)?
    @State private var model: TaskScreenModel
    @Environment(\.dismiss) private var dismiss
    init(target: TaskTarget, onResume: (() -> Void)? = nil) {
        self.target = target; self.onResume = onResume
        _model = State(initialValue: TaskScreenModel(target))
    }
    var body: some View {
        Group {
            if let detail = model.detail {
                TaskScreenView(detail: detail, diffs: model.diffs, open: model.open, pages: model.pages, folderMode: target.isFolder,
                               onToggle: model.toggle, onMore: { model.pages += 1 }, onResume: onResume, onDone: { dismiss() },
                               pr: model.pr?.state, onCreatePR: { model.pr?.createPR() }, onMerge: { model.pr?.merge() },
                               onHold: { model.pr?.toggleHold() }, onRunGate: { model.pr?.runGate() },
                               onSignIn: { model.pr?.signIn(); dismiss() },
                               prPending: model.pr != nil && model.pr?.state == nil)
            } else {
                Text(TaskDetailCopy.loading).font(.system(size: 13)).foregroundStyle(Theme.Token.text1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Token.bg0)
            }
        }
        .frame(width: 560, height: 640)
        .task { await model.load() }
        // The gate clock only ticks while a run is in flight; closing the screen stops it.
        .onDisappear { model.pr?.stop() }
    }
}

/// Pure view: everything it shows comes in as values, so stills and tests can render any state.
struct TaskScreenView: View {
    let detail: TaskDetail
    var diffs: [String: String] = [:]
    var open: String?
    var pages = 1
    var folderMode = false
    /// Stills only: ImageRenderer can't draw a ScrollView.
    var flat = false
    var onToggle: (TaskChangedFile, Bool) -> Void = { _, _ in }
    var onMore: () -> Void = {}
    var onResume: (() -> Void)?
    var onDone: () -> Void = {}
    /// The gate / PR line; nil for main, seats and folders (nothing to show).
    var pr: TaskPRState?
    var onCreatePR: () -> Void = {}
    var onMerge: () -> Void = {}
    var onHold: () -> Void = {}
    var onRunGate: () -> Void = {}
    var onSignIn: () -> Void = {}
    /// The PR line is still loading: keep the Gate row hidden so it does not flash and vanish.
    var prPending = false
    @State private var reportOpen = false

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !folderMode { stateBlock; threeLines }
            if !folderMode, let pr { TaskPRBar(state: pr, onCreate: onCreatePR, onMerge: onMerge, onHold: onHold, onRunGate: onRunGate, onSignIn: onSignIn) }
            changes
            if !folderMode { report }
        }
        .padding(20)
    }

    var body: some View {
        VStack(spacing: 0) {
            if flat { content } else { ScrollView { content } }
            HStack { Spacer(); Button(action: onDone) { Text(TaskDetailCopy.done).font(.system(size: 13, weight: .medium)).padding(.horizontal, 12).frame(height: 28) }
                .buttonStyle(PillButtonStyle(shape: Capsule(), rest: Theme.Token.text0, hover: Theme.Token.text0, fill: Theme.Token.strongLine, hoverFill: Theme.Token.text3.opacity(Theme.Alpha.strongLine))).keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Theme.Token.bg0)
        }
        .background(Theme.Token.bg0)
    }

    private func ink(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.title).font(ink(20, .semibold)).foregroundStyle(Theme.Token.text0).lineLimit(2)
            let parts = (folderMode ? [detail.branch] : [detail.owner, detail.provider, detail.branch]).filter { !$0.isEmpty }
            Text(parts.joined(separator: " · ")).font(ink(13)).foregroundStyle(Theme.Token.text1).lineLimit(1).truncationMode(.middle)
        }
    }

    private var stateBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(detail.state.text).font(ink(15, .semibold)).foregroundStyle(Theme.Token.text0)
                Spacer()
                if detail.state.resumeEnabled, let onResume {
                    Button(TaskDetailCopy.resume, action: onResume)
                }
            }
            if let blocker = detail.state.blocker, blocker != detail.state.text {
                Text(blocker).font(ink(13)).foregroundStyle(Theme.Token.text1)
            }
            // With the PR line on screen it already says the next step (and the gate word); this line would go stale.
            if showsNextLine {
                Text("\(TaskDetailCopy.nextLabel): \(detail.state.nextAction)").font(ink(13)).foregroundStyle(Theme.Token.text1)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Token.bg3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The Gate row shows only when the PR line does not (the line already says the gate word).
    var showsGateRow: Bool { pr == nil && !prPending }
    /// "Next: …" hides whenever the PR line shows (or is about to), so a Green task never says "Next: Run gate".
    var showsNextLine: Bool { pr == nil && !prPending }

    private var threeLines: some View {
        VStack(spacing: 0) {
            line(TaskDetailCopy.finishedLabel, detail.finished ? TaskDetailCopy.yes : TaskDetailCopy.no)
            Divider().overlay(Theme.Token.line)
            // One name, one place: with the PR line on screen it already says the gate word.
            if showsGateRow {
                line(TaskDetailCopy.gateLabel, detail.checks.label)
                Divider().overlay(Theme.Token.line)
            }
            line(TaskDetailCopy.mergedLabel, detail.merged ? TaskDetailCopy.yes : TaskDetailCopy.no)
        }
        .background(Theme.Token.bg3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(ink(13)).foregroundStyle(Theme.Token.text1)
            Spacer()
            Text(value).font(ink(13, .medium)).foregroundStyle(Theme.Token.text0)
        }
        .padding(.horizontal, 14).frame(minHeight: Theme.Hit.control)
        .accessibilityElement(children: .combine)
    }

    // MARK: Changes

    private var changes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TaskDetailCopy.panelChanges).font(ink(15, .semibold)).foregroundStyle(Theme.Token.text0)
            if let empty = detail.changes.emptyMessage {
                Text(empty).font(ink(13)).foregroundStyle(Theme.Token.text1)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(Theme.Token.bg3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                if !detail.changes.commits.isEmpty { commits }
                group(nil, detail.changes.files, uncommitted: false)
                group(TaskDetailCopy.notCommitted, detail.changes.notCommitted, uncommitted: true)
            }
        }
    }

    private var commits: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(detail.changes.commits.prefix(8).enumerated()), id: \.offset) { _, subject in
                Text(subject).font(ink(13)).foregroundStyle(Theme.Token.text1).lineLimit(1).truncationMode(.tail)
            }
            if detail.changes.commits.count > 8 {
                Text("+\(detail.changes.commits.count - 8)").font(ink(13)).foregroundStyle(Theme.Token.text2)
            }
        }
    }

    @ViewBuilder private func group(_ title: String?, _ files: [TaskChangedFile], uncommitted: Bool) -> some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    Text(title).font(ink(13, .medium)).foregroundStyle(Theme.Token.text1)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                let shown = Array(files.prefix(pages * TaskChanges.pageSize))
                ForEach(shown) { file in
                    fileRow(file, uncommitted: uncommitted)
                    if open == TaskScreenModel.key(file, uncommitted) { diffView(diffs[TaskScreenModel.key(file, uncommitted)]) }
                }
                if shown.count < files.count {
                    Button(TaskDetailCopy.showMore, action: onMore).buttonStyle(.plain)
                        .font(ink(13)).foregroundStyle(Theme.Token.text1)
                        .padding(.horizontal, 14).frame(minHeight: Theme.Hit.control)
                }
            }
            .background(Theme.Token.bg3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func fileRow(_ file: TaskChangedFile, uncommitted: Bool) -> some View {
        Button { onToggle(file, uncommitted) } label: {
            HStack(spacing: 8) {
                Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path).font(ink(13))
                    .foregroundStyle(Theme.Token.text0).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if file.binary || file.added == nil {
                    Text(TaskDetailCopy.sized(file.bytes)).font(ink(12)).foregroundStyle(Theme.Token.text1)
                } else {
                    PlusMinus(added: file.added ?? 0, removed: file.removed ?? 0)
                }
            }
            .padding(.horizontal, 14).frame(minHeight: Theme.Hit.control).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(file.path)
    }

    @ViewBuilder private func diffView(_ text: String?) -> some View {
        let lines = (text ?? TaskDetailCopy.loading).split(separator: "\n", omittingEmptySubsequences: false).prefix(400)
        let rows = VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    let s = String(l)
                    let add = s.hasPrefix("+") && !s.hasPrefix("+++"), rem = s.hasPrefix("-") && !s.hasPrefix("---")
                    Text(s.isEmpty ? " " : s).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(add ? Theme.Diff.add : rem ? Theme.Diff.remove : s.hasPrefix("@@") ? Theme.Token.text2 : Theme.Token.text1)
                        .padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
        Group { if flat { rows } else { ScrollView(.horizontal) { rows } } }
        .frame(maxHeight: 260)
        .background(Theme.Token.bg0)
    }

    private var report: some View {
        DisclosureGroup(isExpanded: $reportOpen) {
            Text(detail.report.isEmpty ? TaskDetailCopy.noReport : detail.report)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Token.text1)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        } label: {
            Text(TaskDetailCopy.reportLabel).font(ink(13, .medium)).foregroundStyle(Theme.Token.text0)
        }
    }
}

/// "+N −M" in tabular digits; a zero is muted. Green and red appear nowhere else but here and in diffs.
struct PlusMinus: View {
    let added: Int
    let removed: Int
    var body: some View {
        HStack(spacing: 6) {
            Text("+\(added)").foregroundStyle(added == 0 ? Theme.Token.text2 : Theme.Diff.add)
            Text("−\(removed)").foregroundStyle(removed == 0 ? Theme.Token.text2 : Theme.Diff.remove)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced)).monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

/// The seat card's turn badge: "3 files", and the two notes the plan asks for.
struct SeatTurnBadge: View {
    let turn: AgentTurn
    var onOpen: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                Text(turn.summary).font(.callout.weight(.medium)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).frame(minHeight: 24)
                    .overlay(Capsule().strokeBorder(Theme.Veil.edge, lineWidth: 1))
            }
            .buttonStyle(.plain).help(TaskDetailCopy.panelChanges)
            if let note = turn.overlapMessage { Text(note).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1) }
            if let q = turn.questionLabel { Text(q).font(.callout).foregroundStyle(Theme.hubSecondary) }
        }
    }
}
