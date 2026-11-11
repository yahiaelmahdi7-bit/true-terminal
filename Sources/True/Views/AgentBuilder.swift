import SwiftUI
import UniformTypeIdentifiers

/// The character creator: live card on the left, native controls on the right.
struct AgentBuilderSheet: View {
    @State var draft: BuilderDraft
    let registry: AgentRegistry
    @Environment(\.dismiss) private var dismiss
    @State private var pickingRepo = false
    @State private var request = ""
    @State private var fillTask: Task<Void, Never>?
    @State private var fillError: String?
    /// Fixture seams for stills; nil in the app (awake comes from the registry, Codex from a bounded probe).
    var awakeOverride: Bool?
    var runtimeOverride: SeatRuntimeInfo?
    var accountsOverride: [Account]?
    var readingOverride: AccountReading?
    @State private var probed: SeatRuntimeInfo?
    @State private var storedAccounts: [Account] = []
    @State private var accountReading: AccountReading?

    var body: some View {
        let existing = registry.agents
        let name = draft.name(existing: existing)
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 8) {
                // frame width matches the old card so the sheet doesn't resize

                let a = preview(existing)
                AgentAvatar(hue: a.resolvedHue, symbol: a.symbol, status: .idle, size: 56, showsPresence: false)
                    .padding(.top, 24)
                Text(name ?? (draft.role == .global ? "name it" : "pick a repo"))
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text("\(draft.provider == .codex ? "Codex" : draft.model.label) · \(draft.effort.label) · \(draft.permission.label)")
                    .font(.caption).foregroundStyle(Theme.hubSecondary)
                EffortMeter(level: draft.effort.level, tint: Theme.hubSecondary)
                Spacer(minLength: 0)
            }
            .frame(width: 290)
            Form {
                Section("Describe") {
                    // A TextField inside a grouped Form makes its placeholder the row LABEL and right-aligns
                    // the typed text, clipped (2026-09-30 "broken text box"). An editor with a faint prompt
                    // overlaid reads and wraps like the Charter box below.
                    TextEditor(text: $request)
                        .font(.body).frame(height: 64)
                        .overlay(alignment: .topLeading) {
                            if request.isEmpty {
                                Text("What should this agent do? Job, what it may touch, how much to ask you.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    HStack {
                        Button {
                            if fillTask != nil { fillTask?.cancel() } else { startFill() }
                        } label: {
                            Label(fillTask != nil ? "Cancel" : "Fill", systemImage: fillTask != nil ? "xmark" : "sparkles")
                        }
                        .disabled(fillTask == nil && request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if fillTask != nil { ProgressView().controlSize(.small) }
                    }
                    .controlSize(.large)
                    if let fillError {
                        Text(fillError).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    // A global has no repo: its folder is optional and empty means the home folder, and it
                    // may be re-pointed while editing because its name does not derive from the folder.
                    let isGlobal = draft.role == .global
                    LabeledContent(isGlobal ? "Folder" : "Repo") {
                        HStack {
                            Text(draft.repo.isEmpty ? (isGlobal ? "Home" : "None") : (draft.repo as NSString).lastPathComponent)
                                .foregroundStyle(.secondary)
                            if draft.editing == nil || isGlobal { Button("Choose…") { pickingRepo = true } }
                            if isGlobal && !draft.repo.isEmpty { Button("Clear") { draft.repo = "" } }
                        }
                        .controlSize(.large)
                    }
                    if isGlobal && draft.editing == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Name") {
                                TextField("name", text: $draft.globalName).textFieldStyle(.roundedBorder)
                            }
                            if let note = globalNameNote(existing) {
                                Text(note).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    } else {
                        LabeledContent("Name", value: name ?? (draft.repo.isEmpty ? "—" : "no free slot"))
                    }
                    if draft.editing == nil {
                        Picker("Role", selection: $draft.role) {
                            ForEach(AgentRole.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: draft.role) { _, r in
                            if Self.isDefault(draft.symbol) { draft.symbol = r.defaultSymbol }
                            draft.team = []   // a lead's helpers and a global's leads are different pools
                        }
                    }
                }
                SeatProviderSection(provider: $draft.provider, lockedReason: providerLock, runtime: runtime,
                                    accountRow: draft.showsProviderPicker ? AnyView(accountPicker) : nil)
                Section {
                    if draft.provider == .codex {
                        LabeledContent("Model", value: "Your Codex default")
                    } else {
                        Picker("Model", selection: $draft.model) {
                            ForEach(AgentModel.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    LabeledContent("Effort") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Slider(value: effortBinding, in: 0...4, step: 1)
                            Text(draft.effort.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Permissions", selection: $draft.permission) {
                        ForEach(AgentPermission.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Colour") {
                    HueRow(selection: Binding(get: { draft.hue ?? AgentHue.derived(from: name ?? "") },
                                              set: { draft.hue = $0 }))
                }
                Section("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 8), spacing: 6) {
                        ForEach(BuilderDraft.symbols, id: \.self) { s in
                            Button { draft.symbol = s } label: {
                                Image(systemName: s).frame(width: 32, height: Theme.Hit.control)
                                    .background(draft.symbol == s ? Theme.Veil.fillOn : .clear,
                                                in: .rect(cornerRadius: Theme.Radius.sm))
                                    .contentShape(.rect(cornerRadius: Theme.Radius.sm))
                            }
                            .buttonStyle(PillButtonStyle(shape: RoundedRectangle(cornerRadius: Theme.Radius.sm),
                                                         rest: Theme.Token.text0, hover: Theme.Token.text0))
                        }
                    }
                }
                Section("Charter") {
                    TextEditor(text: $draft.charter)
                        .font(.body).frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
                if draft.role != .helper {
                    let choices = draft.teamChoices(existing: existing)
                    Section(draft.role == .global ? "Can summon" : "Manages") {
                        if choices.isEmpty {
                            Text(draft.role == .global ? "No leads yet — build them first."
                                                       : "No helpers in this repo yet — build them first.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(choices) { h in
                            Toggle(isOn: Binding(
                                get: { draft.team.contains(h.name) },
                                set: { on in if on { draft.team.insert(h.name) } else { draft.team.remove(h.name) } })) {
                                HStack {
                                    Text(h.name)
                                    if draft.role == .global {
                                        Spacer(minLength: 8)
                                        Text(h.repoName).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 400)
        }
        .padding(16)
        .frame(minHeight: 560)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let editing = draft.editing {
                    Button("Delete", role: .destructive) { registry.delete(editing); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.editing == nil ? "Create" : "Save") {
                    if let a = draft.agent(existing: existing) { registry.save(a) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave(existing: existing))
            }
            .controlSize(.large)
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .onDisappear { fillTask?.cancel() }
        .onChange(of: draft.provider) { _, _ in draft.account = nil }   // accounts belong to one provider
        .task(id: "\(draft.provider.rawValue)|\(draft.account ?? "")") { await loadAccount() }
        .task { if runtimeOverride == nil { probed = await SeatProviders.implementation(.codex).probeRuntime() } }
        .fileImporter(isPresented: $pickingRepo, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { draft.repo = url.path }
        }
    }

    private var accountPicker: some View {
        let accounts = accountsOverride ?? storedAccounts
        let row = EditorAccountRow.make(provider: draft.provider, accounts: accounts, selected: draft.account,
                                        reading: readingOverride ?? accountReading)
        return EditorAccountPicker(row: row, selection: $draft.account) { AccountsWindow.shared.show(registry: registry) }
    }

    /// One bounded read of the picked account when the sheet opens or the pick changes (never on a timer).
    private func loadAccount() async {
        guard accountsOverride == nil else { return }
        let store = AccountStore()
        storedAccounts = store.load()
        accountReading = nil
        accountReading = await AccountSignInReader(store: store).read(store.resolve(ref: draft.account, provider: draft.provider))
    }

    private var runtime: SeatRuntimeInfo? {
        runtimeOverride ?? probed ?? (draft.provider == .claude ? SeatProviders.implementation(.codex).runtimeSnapshot() : nil)
    }
    private var providerLock: String? {
        let awake = awakeOverride ?? draft.editing.map { registry.isAwake($0) } ?? false
        return draft.providerLock(awake: awake, codexInstalled: runtime?.installed ?? true)
    }

    private func startFill() {
        fillError = nil
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = draft
        let editing = snapshot.editing != nil
        fillTask = Task {
            defer { fillTask = nil }
            do {
                try await JevFill.orchestrate(
                    prefill: snapshot,
                    jev: { await JevFill.ask(request: text, editing: editing, jev: .shared) },
                    claude: { try await AgentFill.run(request: text, draft: snapshot) },
                    edit: { change in change(&draft) })
            } catch is CancellationError {
            } catch {
                fillError = error.localizedDescription
            }
        }
    }

    /// The line under a global's name field: nothing while empty or fine.
    private func globalNameNote(_ existing: [Agent]) -> String? {
        let n = draft.globalName.trimmingCharacters(in: .whitespaces).lowercased()
        if n.isEmpty { return nil }
        if !AgentNaming.isValidGlobalName(n) { return "lowercase letters, digits and dashes" }
        return existing.contains { $0.name == n } ? "already taken" : nil
    }

    private var effortBinding: Binding<Double> {
        Binding(get: { Double(draft.effort.level - 1) },
                set: { draft.effort = AgentEffort.allCases[min(max(Int($0.rounded()), 0), 4)] })
    }

    private static func isDefault(_ symbol: String) -> Bool {
        AgentRole.allCases.contains { $0.defaultSymbol == symbol }
    }

    private func preview(_ existing: [Agent]) -> Agent {
        Agent(name: draft.name(existing: existing) ?? "", role: draft.role, repo: draft.repo,
              model: draft.model, effort: draft.effort, permission: draft.permission,
              charter: draft.charter, symbol: draft.symbol, hue: draft.hue?.rawValue)
    }
}

/// Ten 22 pt swatches; the selected one wears a 2 pt white ring, hover grows it a touch.
struct HueRow: View {
    @Binding var selection: AgentHue
    var body: some View {
        HStack(spacing: 8) {
            ForEach(AgentHue.allCases, id: \.self) { h in HueSwatch(hue: h, selected: h == selection) { selection = h } }
        }
    }
}

private struct HueSwatch: View {
    let hue: AgentHue
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Circle().fill(hue.gradient).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Theme.Veil.edgeStrong, lineWidth: 0.5))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.white : .clear, lineWidth: 2))
                .scaleEffect(hovering && !reduceMotion ? 1.08 : 1)
                .frame(width: Theme.Hit.control, height: Theme.Hit.control)
                .background(hovering ? Theme.Token.hoverFill : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.micro, value: hovering)
        .help(hue.rawValue.capitalized)
        .accessibilityLabel(hue.rawValue.capitalized)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
