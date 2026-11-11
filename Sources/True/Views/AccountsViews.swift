import SwiftUI

/// Plain words for accounts. One place, so the editor row, the accounts pane and the tests read the same rule.
/// Unknown is never shown as signed in, and nothing here prints a raw code.
enum AccountWords {
    static func signIn(_ s: SeatSignIn, plan: String?) -> String {
        switch s {
        case .signedIn: return plan.flatMap(Self.plan).map { "Signed in · \($0)" } ?? "Signed in"
        case .notSignedIn: return "Not signed in"
        case .unknown: return "Unknown"
        }
    }
    /// "max" -> "Max", "max_5x" -> "Max 5x". Empty = no plan to show.
    static func plan(_ raw: String) -> String? {
        let t = raw.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t.prefix(1).uppercased() + t.dropFirst()
    }
    /// `/Users/example/.claude-work` -> `~/.claude-work`.
    static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static let codexSignedInTip = "Credentials found; not checked with OpenAI."
}

// MARK: Seat editor row

/// The Account row under the Provider control: the provider's accounts (normal one first, as "Default"), then
/// "Manage accounts…", and the picked account's sign-in word.
struct EditorAccountRow: Equatable {
    struct Choice: Equatable, Identifiable { let id: String?; let label: String }
    var choices: [Choice]
    var selected: String?
    var signInWord: String

    /// A reference that no longer exists falls back to Default, like `AccountStore.resolve`.
    /// `reading == nil` means the check is still running: never "Signed in".
    static func make(provider: SeatProvider, accounts: [Account], selected: String?, reading: AccountReading?) -> EditorAccountRow {
        let mine = accounts.filter { $0.provider == provider }
        let picked = mine.contains { $0.id == selected } ? selected : nil
        let word = reading.map { AccountWords.signIn($0.signIn, plan: $0.plan) } ?? "Checking…"
        return EditorAccountRow(choices: [Choice(id: nil, label: "Default")] + mine.map { Choice(id: $0.id, label: $0.label) },
                                selected: picked, signInWord: word)
    }
}

struct EditorAccountPicker: View {
    let row: EditorAccountRow
    @Binding var selection: String?
    let manage: () -> Void
    private enum Tag: Hashable { case account(String?), manage }

    var body: some View {
        LabeledContent("Account") {
            HStack(spacing: 8) {
                Text(row.signInWord).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Picker("Account", selection: Binding<Tag>(
                    get: { .account(row.selected) },
                    set: { if case .account(let id) = $0 { selection = id } else { manage() } })) {
                    ForEach(row.choices) { Text($0.label).tag(Tag.account($0.id)) }
                    Divider()
                    Text("Manage accounts…").tag(Tag.manage)
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}

// MARK: Accounts pane

/// One account line in the pane. Email is held but hidden until asked for.
struct AccountRowFacts: Equatable, Identifiable {
    var id: String
    var provider: SeatProvider
    var label: String
    var path: String
    var signIn: SeatSignIn
    var plan: String?
    var email: String?
    var note: String?
    var isDefault: Bool
    /// The account's own config folder; nil for the provider's normal one. What Sign in points the login at.
    var configDir: String? = nil

    var word: String { AccountWords.signIn(signIn, plan: plan) }
    /// "Sign in" belongs on Not signed in and Unknown, never on a confirmed login.
    var offersSignIn: Bool { signIn != .signedIn }
    /// Codex "Signed in" is only "credentials found".
    var tooltip: String? { provider == .codex && signIn == .signedIn ? AccountWords.codexSignedInTip : nil }
    /// Why it is Unknown, in the reading's own plain words.
    var detail: String? { signIn == .unknown ? note : nil }

    static func make(_ a: ResolvedAccount, reading: AccountReading?, home: String = NSHomeDirectory()) -> AccountRowFacts {
        AccountRowFacts(id: a.id ?? "default-\(a.provider.rawValue)", provider: a.provider, label: a.label,
                        path: AccountWords.shortPath(a.directory.path, home: home),
                        signIn: reading?.signIn ?? .unknown, plan: reading?.plan, email: reading?.email,
                        note: reading?.note, isDefault: a.isDefault, configDir: a.configDir)
    }

    /// The login this row's "Sign in" runs: the provider's own, in this account's folder.
    var signInCommand: SignInCommand { SignInCommand.make(provider: provider, configDir: configDir) }
}

/// A project's routing line: its model and its fallback, as picked in the pane.
struct ProjectDefaultsRow: Identifiable, Equatable {
    var repo: String
    var model: ModelChoice?
    var fallback: ModelChoice?
    var id: String { repo }
    var name: String { (repo as NSString).lastPathComponent }
}



extension ModelChoice {
    var label: String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return model.flatMap(AgentModel.init(rawValue:)).map { "Claude · \($0.label)" } ?? "Claude"
        }
    }
    /// What the two project menus offer.
    static var options: [ModelChoice] {
        AgentModel.allCases.map { ModelChoice(provider: .claude, model: $0.rawValue) } + [ModelChoice(provider: .codex, model: nil)]
    }
}

/// Everything the Accounts pane shows and changes. Reads and writes `accounts.json` and `routing.json` only
/// (labels, paths and choices); it holds no token field and never stores one.
@MainActor @Observable final class AccountsModel {
    let accountStore: AccountStore
    let routingStore: RoutingStore
    let reader: AccountSignInReader?
    var accounts: [Account]
    var readings: [String: AccountReading] = [:]   // by row id
    var routing: RoutingFile
    var repos: [String]
    var emailShown: Set<String> = []
    var adding: SeatProvider?
    var newLabel = ""
    var newFolder = ""
    var checking = false

    init(accountStore: AccountStore = AccountStore(), routingStore: RoutingStore = RoutingStore(),
         reader: AccountSignInReader? = nil, repos: [String]) {
        self.accountStore = accountStore; self.routingStore = routingStore; self.reader = reader
        self.accounts = accountStore.load(); self.routing = routingStore.load(); self.repos = repos
    }

    func rows(_ provider: SeatProvider) -> [AccountRowFacts] {
        var out = [AccountRowFacts.make(accountStore.defaultAccount(provider), reading: readings["default-\(provider.rawValue)"])]
        out += accounts.filter { $0.provider == provider }.map { AccountRowFacts.make(accountStore.resolved($0), reading: readings[$0.id]) }
        return out
    }
    /// Only the provider's normal account: nothing to manage yet.
    var onlyDefaults: Bool { accounts.isEmpty }

    /// On open only (never on a timer): the live default dirs and the stored accounts.
    func refresh() async {
        guard let reader, !checking else { return }   // opening and becoming key arrive together: read once
        checking = true
        for p in SeatProvider.allCases { readings["default-\(p.rawValue)"] = await reader.readDefault(p) }
        for (id, r) in await reader.readStored() { readings[id] = r }
        checking = false
    }

    func toggleEmail(_ id: String) { if !emailShown.insert(id).inserted { emailShown.remove(id) } }
    func isEmailShown(_ id: String) -> Bool { emailShown.contains(id) }

    var canAdd: Bool {
        !newLabel.trimmingCharacters(in: .whitespaces).isEmpty && !newFolder.trimmingCharacters(in: .whitespaces).isEmpty
    }
    func addAccount() {
        guard let p = adding, canAdd else { return }
        let dir = (newFolder.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        accounts.append(Account(id: UUID().uuidString.prefix(8).lowercased().description, provider: p,
                                label: newLabel.trimmingCharacters(in: .whitespaces), configDir: dir))
        accountStore.save(accounts)
        adding = nil; newLabel = ""; newFolder = ""
        if let reader, let a = accounts.last { Task { readings[a.id] = await reader.read(accountStore.resolved(a)) } }
    }

    var projects: [ProjectDefaultsRow] {
        repos.map { ProjectDefaultsRow(repo: $0, model: routing.projects[$0]?.defaultModel, fallback: routing.projects[$0]?.fallbackModel) }
    }
    func setModel(_ repo: String, _ choice: ModelChoice?) { edit(repo) { $0.defaultModel = choice } }
    func setFallback(_ repo: String, _ choice: ModelChoice?) { edit(repo) { $0.fallbackModel = choice } }
    private func edit(_ repo: String, _ change: (inout ProjectRouting) -> Void) {
        var p = routing.projects[repo] ?? ProjectRouting()
        change(&p)
        routing.projects[repo] = p
        routingStore.save(routing)
    }
}

struct AccountsView: View {
    @Bindable var model: AccountsModel
    var signIn: (AccountRowFacts) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Accounts").font(.title3.weight(.semibold)).foregroundStyle(Theme.Token.text0)
                ForEach(SeatProvider.allCases, id: \.self) { providerBlock($0) }
                if !model.repos.isEmpty { projectDefaults }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 300)
        .background(Theme.Token.bg0)
        .task { await model.refresh() }
    }

    private func providerBlock(_ p: SeatProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.label).font(.callout.weight(.semibold)).foregroundStyle(Theme.Token.text1)
            VStack(spacing: 0) {
                let rows = model.rows(p)
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Rectangle().fill(Theme.Token.line).frame(height: 1) }
                    AccountRow(row: row, emailShown: model.isEmailShown(row.id),
                               toggleEmail: { model.toggleEmail(row.id) }, signIn: { signIn(row) })
                }
            }
            .tile()
            if model.adding == p { addForm(p) } else {
                Button { model.adding = p } label: { Label("Add account", systemImage: "plus") }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(Theme.Token.text1)
            }
        }
    }

    private func addForm(_ p: SeatProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label", text: $model.newLabel).textFieldStyle(.roundedBorder)
            TextField("Folder, for example ~/.claude-work", text: $model.newFolder)
                .textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced))
            HStack {
                Spacer()
                Button("Cancel") { model.adding = nil }
                Button("Add") { model.addAccount() }.disabled(!model.canAdd).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).tile()
    }

    private var projectDefaults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project defaults").font(.callout.weight(.semibold)).foregroundStyle(Theme.Token.text1)
            VStack(spacing: 0) {
                ForEach(Array(model.projects.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Rectangle().fill(Theme.Token.line).frame(height: 1) }
                    projectRow(row)
                }
            }
            .tile()
        }
    }

    private func projectRow(_ row: ProjectDefaultsRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name).font(.body.weight(.semibold)).foregroundStyle(Theme.Token.text0)
            HStack(spacing: 16) {
                choice("Model", none: "Seat's choice", row.model) { model.setModel(row.repo, $0) }
                choice("If limited, use", none: "Don't switch", row.fallback) { model.setFallback(row.repo, $0) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choice(_ title: String, none: String, _ value: ModelChoice?, set: @escaping @MainActor (ModelChoice?) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout).foregroundStyle(Theme.Token.text2)
            Picker(title, selection: Binding(get: { value }, set: set)) {
                Text(none).tag(ModelChoice?.none)
                Divider()
                ForEach(ModelChoice.options, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            .labelsHidden().fixedSize()
        }
    }
}

private struct AccountRow: View {
    let row: AccountRowFacts
    let emailShown: Bool
    let toggleEmail: () -> Void
    let signIn: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.label).font(.body.weight(.semibold)).foregroundStyle(Theme.Token.text0)
                Text(row.path).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.Token.text2).lineLimit(1)
                if row.signIn == .signedIn, row.email != nil {
                    HStack(spacing: 8) {
                        if emailShown, let email = row.email {
                            Text(email).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.Token.text1)
                        }
                        Button(emailShown ? "Hide email" : "Show email", action: toggleEmail)
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.Token.text2)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(row.word).font(.callout).foregroundStyle(row.signIn == .signedIn ? Theme.Token.text0 : Theme.Token.text1)
                    .help(row.tooltip ?? "")
                if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(Theme.Token.text2) }
                if row.offersSignIn {
                    Button(action: signIn) {
                        Text("Sign in").font(.callout.weight(.medium))
                            .padding(.horizontal, 12).frame(minHeight: Theme.Hit.control - 8)
                            .overlay(Capsule().strokeBorder(Theme.Veil.edgeOn, lineWidth: 1))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(PillButtonStyle(shape: Capsule(), rest: Theme.text, hover: Theme.text))
                }
            }
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Glass tile: ~85 % bg3 with a hairline. No tint.
    func tile() -> some View {
        background(Theme.Token.bg3.opacity(0.85), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Token.line, lineWidth: 1))
    }
}

/// Hub > Accounts… and the editor's "Manage accounts…". One window, built on demand.
@MainActor final class AccountsWindow {
    static let shared = AccountsWindow()
    private var window: NSWindow?
    private var keyObserver: NSObjectProtocol?

    func show(registry: AgentRegistry) {
        let repos = Array(Set(registry.agents.map(\.repo).filter { !$0.isEmpty })).sorted()
        let model = AccountsModel(reader: AccountSignInReader(), repos: repos)
        let w = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Accounts"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: AccountsView(model: model, signIn: { [weak self] row in self?.signIn(row) }))
        // Coming back after a login is an "open": read again so the row says Signed in. Never on a timer.
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
            Task { @MainActor in await model.refresh() }
        }
        if window == nil { w.center() }
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// A new tab running the provider's own login in this account's folder. True never sees the token.
    private func signIn(_ row: AccountRowFacts) {
        let ws = WorkspaceModel.shared
        let pane = ws.openShellTab(cwd: NSHomeDirectory())
        if let i = ws.tabIndex(containing: pane) { ws.rename(tab: ws.state.tabs[i].id, to: "Sign in · \(row.label)") }
        PaneStartup.shared.set(row.signInCommand.shellCommand, for: pane)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible && $0 !== window }?.makeKeyAndOrderFront(nil)
    }
}
