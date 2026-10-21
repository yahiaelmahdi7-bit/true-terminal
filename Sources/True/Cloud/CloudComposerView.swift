import AppKit
import SwiftUI

/// Pick a repo, describe the job, choose a model + effort → sync the repo to the VPS → create the job.
/// The sheet owns the side effects; `CloudComposerContent` only draws a `CloudComposerModel`, so the snapshot
/// tests can render every state.
struct NewCloudJobSheet: View {
    let projects: [String]
    var done: () -> Void
    @State private var model: CloudComposerModel

    init(projects: [String], done: @escaping () -> Void) {
        self.projects = projects
        self.done = done
        _model = State(initialValue: CloudComposerModel(projects: projects))
    }

    var body: some View {
        CloudComposerContent(model: model, onRun: { Task { await run() } }, onCancel: done,
                             onChooseFolder: chooseFolder, onRecheck: { Task { await checkCloud() } })
            .frame(width: CloudComposerContent.width)
            .presentationBackground(CloudComposerContent.base)
            .environment(\.colorScheme, .dark)
            .task {
                async let repos: Void = model.loadRepos()
                async let health: Void = checkCloud()
                _ = await (repos, health)
            }
    }

    private func checkCloud() async {
        let store = CloudStore.shared
        await model.refreshHealth(client: store.client, running: store.jobs.filter(\.isWorking).count)
    }

    private func run() async {
        await model.run(client: CloudStore.shared.client,
                        sync: { path, progress in try CloudSync().sync(localRepo: path, progress: progress) },
                        onDone: done)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Choose"
        if p.runModal() == .OK, let u = p.url { Task { await model.chooseFolder(u.path) } }
    }
}

/// The composer, drawn from its model. Dark glass family of the Hub; 8 pt rhythm; no system bezels.
struct CloudComposerContent: View {
    static let width: CGFloat = 640
    static let base = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var model: CloudComposerModel
    var now: Double = Date().timeIntervalSince1970
    var onRun: () -> Void = {}
    var onCancel: () -> Void = {}
    var onChooseFolder: () -> Void = {}
    var onRecheck: () -> Void = {}

    @FocusState private var listFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    repoSection
                    taskSection
                    modelSection
                    effortSection
                    moreSection
                }
                .padding(20)
                .disabled(model.isSending)
            }
            .scrollIndicators(.hidden)
            Divider().overlay(Theme.hairline)
            footer
        }
        .background(Self.base)
        .foregroundStyle(Theme.text)
        .frame(maxHeight: 840)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "icloud.and.arrow.up").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.hubSecondary)
            Text("Run in cloud").font(.title3.weight(.semibold))
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Circle().fill(model.link == .offline ? Theme.verdictWarn : model.link == .online ? Color.white : Theme.dimText)
                    .frame(width: 6, height: 6)
                Text(model.statusLine).font(.callout).foregroundStyle(model.link == .offline ? Theme.verdictWarn : Theme.hubSecondary)
                    .lineLimit(1)
                if model.link == .offline { PlainButton("Retry", action: onRecheck) }
            }
        }
        .padding(.horizontal, 24).frame(height: 56)
    }

    // MARK: repo

    private var repoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Repo")
            if let sel = model.selected {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        RepoRow(info: sel, now: now, highlighted: false).frame(maxWidth: .infinity)
                        PlainButton("Change") { model.clearSelection() }
                    }
                    .padding(.vertical, 8).padding(.leading, 12).padding(.trailing, 12)
                    .background(Theme.hubCardFill, in: Self.shape)
                    .overlay(Self.shape.strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
                    if let p = sel.problem {
                        Label(p, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.hubFailed)
                    }
                }
            } else {
                repoPicker
            }
        }
    }

    private var repoPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.showsSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.dimText)
                    TextField("Search repos", text: Binding(get: { model.search }, set: { model.search = $0; model.cursor = 0 }))
                        .textFieldStyle(.plain).font(.body)
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(Color.white.opacity(0.05), in: Self.shape)
                .overlay(Self.shape.strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
            }
            let list = model.filtered
            VStack(spacing: 0) {
                if model.loadingRepos && list.isEmpty {
                    Text("Reading your projects…").font(.callout).foregroundStyle(Theme.hubSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else if list.isEmpty {
                    Text(model.search.isEmpty ? "No git projects found yet. Choose a folder below." : "Nothing matches “\(model.search)”.")
                        .font(.callout).foregroundStyle(Theme.hubSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, info in
                                    RepoRow(info: info, now: now, highlighted: i == model.cursor)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(i == model.cursor ? Theme.hubHoverFill : .clear)
                                        .contentShape(.rect)
                                        .onTapGesture { model.choose(info) }
                                        .id(info.id)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxHeight: 3 * 56)
                        .onChange(of: model.cursor) { _, c in if list.indices.contains(c) { proxy.scrollTo(list[c].id) } }
                    }
                }
                Divider().overlay(Theme.hairline)
                Button(action: onChooseFolder) {
                    Label("Choose folder…", systemImage: "folder.badge.plus").font(.callout).foregroundStyle(Theme.hubSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 40).contentShape(.rect)
                }.buttonStyle(.plain)
            }
            .background(Theme.hubCardFill, in: Self.shape)
            .overlay(Self.shape.strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
            .focusable().focusEffectDisabled().focused($listFocus)
            .onKeyPress(.upArrow) { model.moveCursor(-1); return .handled }
            .onKeyPress(.downArrow) { model.moveCursor(1); return .handled }
            .onKeyPress(.return) { guard model.filtered.indices.contains(model.cursor) else { return .ignored }; model.pickCursor(); return .handled }
            .onAppear { listFocus = true }
        }
    }

    // MARK: task

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Task")
            @Bindable var m = model
            TextEditor(text: $m.prompt)
                .font(.body).scrollContentBackground(.hidden)
                .padding(.horizontal, 8).padding(.vertical, 8)
                .frame(height: Self.editorHeight(for: model.prompt))
                .background(Color.white.opacity(0.05), in: Self.shape)
                .overlay(alignment: .topLeading) {
                    if model.prompt.isEmpty {
                        Text("Describe the job, e.g. Fix the failing login test and add a regression test")
                            .font(.body).foregroundStyle(Theme.dimText).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
                .overlay(Self.shape.strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
        }
    }

    /// ~6 lines to start, grows with the text to ~14, then the editor scrolls.
    static func editorHeight(for text: String, perLine: CGFloat = 20) -> CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / 72).rounded(.up))) }
        return CGFloat(min(max(lines, 6), 14)) * perLine + 16
    }

    // MARK: model + effort

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Model")
            HStack(spacing: 8) {
                ForEach(model.models) { m in
                    let on = m.id == model.model
                    Button { model.model = m.id } label: {
                        VStack(spacing: 2) {
                            Text(m.label).font(.callout.weight(.medium))
                            Text(m.hint).font(.caption).foregroundStyle(on ? Theme.hubSecondary : Theme.dimText)
                        }
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(on ? Color.white.opacity(0.14) : Color.white.opacity(0.04), in: Self.shape)
                        .overlay(Self.shape.strokeBorder(on ? Color.white.opacity(0.4) : Theme.hubCardStroke, lineWidth: on ? 1 : 0.5))
                        .foregroundStyle(on ? Color.white : Theme.hubSecondary)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(m.label), \(m.hint)").accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private var effortSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Effort")
            HStack(spacing: 0) {
                ForEach(model.efforts, id: \.self) { e in
                    let on = e == model.effort
                    Button { model.effort = e } label: {
                        Text(CloudModel.effortLabel(e)).font(.callout.weight(on ? .semibold : .regular))
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(on ? Color.white.opacity(0.16) : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(on ? Color.white : Theme.hubSecondary).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Color.white.opacity(0.05), in: Self.shape)
            .overlay(Self.shape.strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
        }
    }

    // MARK: more options

    private var moreSection: some View {
        @Bindable var m = model
        return VStack(alignment: .leading, spacing: 16) {
            Button { withAnimation(.snappy(duration: 0.2)) { model.showMore.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(model.showMore ? 90 : 0))
                    Text("More options").font(.callout)
                }.foregroundStyle(Theme.hubSecondary).contentShape(.rect)
            }.buttonStyle(.plain)
            if model.showMore {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 16) {
                        Text("Title").font(.callout).foregroundStyle(Theme.hubSecondary).frame(width: 48, alignment: .leading)
                        TextField(model.titlePlaceholder, text: $m.title).textFieldStyle(.plain).font(.body)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Color.white.opacity(0.05), in: Self.shape)
                            .overlay(Self.shape.strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
                    }
                    HStack(spacing: 16) {
                        Text("Base").font(.callout).foregroundStyle(Theme.hubSecondary).frame(width: 48, alignment: .leading)
                        Text(baseLine).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.hubSecondary)
                    }
                }
            }
        }
    }

    private var baseLine: String {
        guard let s = model.selected, s.isRunnable else { return "Pick a repo first" }
        return "\(s.shortSha) · \(s.branch) · current commit"
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 16) {
            if model.send != .idle { SendProgress(state: model.send, onRetry: onRun) }
            HStack(spacing: 16) {
                Text("The cloud works on a copy. You review the diff before anything lands here.")
                    .font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel).buttonStyle(.plain).font(.body).foregroundStyle(Theme.hubSecondary)
                    .keyboardShortcut(.cancelAction).padding(.horizontal, 8).frame(height: 32)
                runButton
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var runButton: some View {
        Button(action: onRun) {
            HStack(spacing: 8) {
                Text("Run in cloud").font(.body.weight(.semibold))
                Text("⌘↩").font(.callout).opacity(0.55)
            }
            .foregroundStyle(.black).padding(.horizontal, 16).frame(height: 32)
            .background(Color.white.opacity(model.canRun ? 0.92 : 0.28), in: .capsule)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canRun)
        .help(model.blocker ?? "Pack the repo, upload it and start the job")
    }
}

// MARK: pieces

private struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.callout.weight(.semibold)).foregroundStyle(Theme.hubSecondary) }
}

private struct PlainButton: View {
    let title: String
    let action: () -> Void
    init(_ t: String, action: @escaping () -> Void) { title = t; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(Theme.text)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Color.white.opacity(0.09), in: .capsule).contentShape(.capsule)
        }.buttonStyle(.plain)
    }
}

/// name + last commit on the left, branch + state on the right; the same two lines in the list and the summary.
private struct RepoRow: View {
    let info: CloudRepoInfo
    let now: Double
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.system(size: 16)).foregroundStyle(Theme.hubSecondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.body.weight(.medium)).lineLimit(1)
                Text(commitLine).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if info.isRunnable {
                    Text(info.branch).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                }
                Text(info.stateLabel).font(.callout)
                    .foregroundStyle(info.kind != .ready ? Theme.hubFailed : info.dirtyCount > 0 ? Theme.verdictWarn : Theme.dimText.opacity(1.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: 250, alignment: .trailing)
        }
        .frame(height: 40)
    }

    private var commitLine: String {
        guard info.isRunnable else { return info.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        let age = CloudRepoInfo.age(of: info.committedAt, now: now)
        return age.isEmpty ? info.subject : "\(info.subject) · \(age)"
    }
}

/// Packing repo → Uploading → Starting job, a check per finished step, a spinner on the live one, the error and
/// Retry on the one that broke.
struct SendProgress: View {
    let state: CloudSendState
    var onRetry: () -> Void = {}

    private func phase(_ s: CloudSendStep) -> Phase {
        switch state {
        case .idle: return .waiting
        case .running(let cur): return s.rawValue < cur.rawValue ? .done : s == cur ? .live : .waiting
        case .failed(let at, _): return s.rawValue < at.rawValue ? .done : s == at ? .failed : .waiting
        }
    }
    private enum Phase { case waiting, live, done, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                ForEach(CloudSendStep.allCases, id: \.rawValue) { s in
                    let p = phase(s)
                    HStack(spacing: 8) {
                        switch p {
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.white)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.hubFailed)
                        case .live: ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                        case .waiting: Image(systemName: "circle").foregroundStyle(Theme.dimText)
                        }
                        Text(s.label).font(.callout).foregroundStyle(p == .waiting ? Theme.dimText.opacity(1.6) : p == .failed ? Theme.hubFailed : Theme.text)
                    }
                }
                Spacer()
            }
            if case .failed(_, let msg) = state {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(msg).font(.callout).foregroundStyle(Theme.hubFailed).lineLimit(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PlainButton("Retry", action: onRetry)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
