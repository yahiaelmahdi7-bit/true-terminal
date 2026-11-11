import Testing
import Foundation
import SwiftUI
import AppKit
@testable import True

/// Wedge 3 UI: what the editor row, the accounts pane and the seat card say. Pure facts, no probes, no Keychain.
@MainActor
@Suite struct AccountsUITests {
    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("acct-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static let work = Account(id: "w1", provider: .claude, label: "Work", configDir: NSHomeDirectory() + "/.claude-work")

    @Test func unknownNeverReadsAsSignedIn() {
        for reading in [AccountReading(), AccountReading(note: "Folder not found"), nil] {
            let row = EditorAccountRow.make(provider: .claude, accounts: [Self.work], selected: "w1", reading: reading)
            #expect(!row.signInWord.contains("Signed in"))
        }
        #expect(EditorAccountRow.make(provider: .claude, accounts: [], selected: nil, reading: AccountReading()).signInWord == "Unknown")
        let r = AccountRowFacts.make(ResolvedAccount(provider: .codex, id: "c", label: "Home", configDir: "/x", directory: URL(fileURLWithPath: "/x")),
                                     reading: AccountReading(signIn: .unknown, plan: "plus", email: "a@example.com"))
        #expect(r.word == "Unknown" && r.offersSignIn)                 // a plan on an unknown answer is not shown as a login
        #expect(AccountWords.signIn(.signedIn, plan: "max") == "Signed in · Max")
        #expect(AccountWords.signIn(.signedIn, plan: nil) == "Signed in")
        #expect(AccountWords.signIn(.notSignedIn, plan: "max") == "Not signed in")
    }

    @Test func editorListsDefaultFirstAndOnlyThatProvidersAccounts() {
        let other = Account(id: "c1", provider: .codex, label: "Codex work", configDir: "/tmp/c")
        let row = EditorAccountRow.make(provider: .claude, accounts: [Self.work, other], selected: "gone", reading: nil)
        #expect(row.choices.map(\.label) == ["Default", "Work"])
        #expect(row.selected == nil)                                   // a deleted account falls back to Default
        #expect(EditorAccountRow.make(provider: .claude, accounts: [Self.work], selected: "w1", reading: nil).selected == "w1")
    }

    @Test func draftCarriesTheAccountThrough() {
        var a = Agent(name: "lead-x", role: .lead, repo: "/tmp/x", account: "w1")
        var d = BuilderDraft(editing: a)
        #expect(d.account == "w1")
        #expect(d.agent(existing: [])?.account == "w1")
        d.account = nil; a.account = nil
        #expect(d.agent(existing: [])?.account == nil)
    }

    @Test func emailHiddenUntilAsked() throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = AccountsModel(accountStore: AccountStore(url: dir.appendingPathComponent("a.json")),
                              routingStore: RoutingStore(url: dir.appendingPathComponent("r.json")), repos: [])
        m.readings["default-claude"] = AccountReading(signIn: .signedIn, plan: "max", email: "work@example.com")
        let row = try #require(m.rows(.claude).first)
        #expect(!m.isEmailShown(row.id))
        m.toggleEmail(row.id); #expect(m.isEmailShown(row.id))
        m.toggleEmail(row.id); #expect(!m.isEmailShown(row.id))
        #expect(row.tooltip == nil)
        let codex = AccountRowFacts.make(AccountStore().defaultAccount(.codex), reading: AccountReading(signIn: .signedIn))
        #expect(codex.tooltip == "Credentials found; not checked with OpenAI.")
    }

    @Test func projectDefaultsRoundTripThroughRoutingStore() throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rs = RoutingStore(url: dir.appendingPathComponent("r.json"))
        let m = AccountsModel(accountStore: AccountStore(url: dir.appendingPathComponent("a.json")), routingStore: rs, repos: ["/tmp/app"])
        m.setModel("/tmp/app", ModelChoice(provider: .claude, model: "opus"))
        m.setFallback("/tmp/app", ModelChoice(provider: .codex, model: nil))
        #expect(rs.load().projects["/tmp/app"] == ProjectRouting(defaultModel: ModelChoice(provider: .claude, model: "opus"),
                                                                 fallbackModel: ModelChoice(provider: .codex, model: nil)))
        #expect(m.projects.first?.fallback?.label == "Codex")
        m.setFallback("/tmp/app", nil)
        #expect(rs.load().projects["/tmp/app"]?.fallbackModel == nil)
    }

    @Test func accountsPaneStoresLabelAndFolderOnly() throws {
        let dir = try Self.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = AccountStore(url: dir.appendingPathComponent("a.json"))
        let m = AccountsModel(accountStore: store, routingStore: RoutingStore(url: dir.appendingPathComponent("r.json")), repos: [])
        m.adding = .claude; m.newLabel = "Work"; m.newFolder = "~/.claude-work"
        m.readings["default-claude"] = AccountReading(signIn: .signedIn, plan: "max", email: "secret-mail@example.com")
        m.addAccount()
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("Work") && text.contains(".claude-work") && !text.contains("~"))
        #expect(!text.contains("secret-mail") && !text.lowercased().contains("token") && !text.lowercased().contains("secret"))
        #expect(store.load().count == 1)
        // The pane's own source has no secure field: it never asks for a credential.
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/TrueTests/AccountsUITests.swift", with: "Sources/True/Views/AccountsViews.swift"), encoding: .utf8)
        #expect(!src.contains("SecureField") && !src.contains("Keychain"))
    }

    @Test func cardWordsAreTheBuilderWordsVerbatim() throws {
        let now = RoutingTests.now
        guard case let .useFallback(card) = FallbackOnWake.decide(chosen: .claude, chosenFacts: RoutingTests.claudeFull, fallback: RoutingTests.fallback,
                                                                  fallbackFacts: RoutingTests.codexGood, explicitModel: false, isFreshWake: true, now: now)
        else { Issue.record("expected a fallback"); return }
        let f = SeatCardFacts(provider: .codex, status: .idle, capabilities: nil, runtime: nil, issue: nil, fallback: card)
        #expect(f.lifecycle == card.text && f.useOriginalText == card.buttonText)
        #expect(card.buttonText == "Use Claude" && card.text.hasPrefix("Using Codex · Claude "))
        // Limited: Claude and Codex cards use the one builder (`SeatRuntimeInfo.limitLabel`).
        let rt = SeatRuntimeInfo(installed: true, signIn: .signedIn, limitedUntil: now)
        let claude = SeatCardFacts(provider: .claude, status: .idle, capabilities: nil, runtime: rt, issue: nil).lifecycle
        let codex = SeatCardFacts(provider: .codex, status: .idle, capabilities: nil, runtime: rt, issue: nil).lifecycle
        #expect(claude == codex && claude == rt.limitLabel && claude?.hasPrefix("Limited until ") == true)
        // A Claude seat with no limit and no fallback shows nothing new.
        #expect(SeatCardFacts(provider: .claude, status: .idle, capabilities: nil, runtime: SeatRuntimeInfo(installed: true), issue: nil).lifecycle == nil)
    }

    @Test func useOriginalEndsTheFallbackAndSkipsItOnce() throws {
        let t = RoutingWakeTests()
        let (reg, _, _, dir) = try t.make(); defer { try? FileManager.default.removeItem(at: dir) }
        reg.save(Agent(name: "lead-app", role: .lead, repo: "/tmp", provider: .claude))
        let pane = try #require(reg.wake("lead-app"))
        #expect(reg.fallbackCards["lead-app"]?.buttonText == "Use Claude")
        reg.useOriginal("lead-app")                  // ends the pane (no live terminal in tests: the pane is released)
        reg.paneClosed(pane)
        _ = try #require(reg.wake("lead-app"))
        #expect(reg.agent(named: "lead-app")?.seatProvider == .claude && reg.fallbackCards["lead-app"] == nil)
    }
}

/// Stills: skipped unless TRUE_SNAPSHOT_DIR is set (dark only).
/// `TRUE_SNAPSHOT_DIR=$PWD/docs/designs/stills/t3-w3 swift test --filter AccountsStillsTests`
@MainActor
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty, "TRUE_SNAPSHOT_DIR not set"))
struct AccountsStillsTests {
    private func render(_ name: String, _ view: some View, width: CGFloat, height: CGFloat? = nil) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp")
        let framed = view.frame(width: width).background(Color.black).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: framed)
        let size = NSSize(width: width, height: height ?? max(host.fittingSize.height, 60))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name)-dark.png"))
    }

    private func sheet(account: String?, accounts: [Account], reading: AccountReading) throws -> some View {
        let dir = try AccountsUITests.tempDir()
        let r = AgentRegistry(store: AgentStore(url: dir.appendingPathComponent("agents.json")), paths: AgentPaths(root: dir),
                              workspace: WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("w.json"))),
                              claudeDir: dir, codexDir: dir)
        var d = BuilderDraft(editing: Agent(name: "true-lead", role: .lead, repo: "/Users/example/Projects/true", account: account))
        d.provider = .claude
        return AgentBuilderSheet(draft: d, registry: r, awakeOverride: false,
                                 runtimeOverride: SeatRuntimeInfo(installed: true, version: CodexRuntime.capturedVersion, signIn: .signedIn),
                                 accountsOverride: accounts, readingOverride: reading)
    }

    private let work = Account(id: "w1", provider: .claude, label: "Work", configDir: NSHomeDirectory() + "/.claude-work")
    private let codexAlt = Account(id: "c1", provider: .codex, label: "Side project", configDir: NSHomeDirectory() + "/.codex-side")

    @Test func editors() throws {
        try render("editor-1-account-default", try sheet(account: nil, accounts: [work],
                   reading: AccountReading(signIn: .signedIn, plan: "max", email: "me@example.com")), width: 740)
        try render("editor-3-account-unknown", try sheet(account: "w1", accounts: [work],
                   reading: AccountReading(note: "Folder not found")), width: 740)
    }

    private func pane(accounts: [Account], readings: [String: AccountReading], emailFor: String? = nil,
                      repos: [String] = ["/Users/example/Projects/true", "/Users/example/Projects/clipping-site"], routing: RoutingFile = RoutingFile(),
                      height: CGFloat) throws -> (AnyView, CGFloat) {
        let dir = try AccountsUITests.tempDir()
        let store = AccountStore(url: dir.appendingPathComponent("a.json"))
        store.save(accounts)
        let rs = RoutingStore(url: dir.appendingPathComponent("r.json")); rs.save(routing)
        let m = AccountsModel(accountStore: store, routingStore: rs, repos: repos)
        m.readings = readings
        if let emailFor { m.emailShown = [emailFor] }
        return (AnyView(AccountsView(model: m)), height)
    }

    @Test func accountsPane() throws {
        let signed = ["default-claude": AccountReading(signIn: .signedIn, plan: "max", email: "work@example.com"),
                      "default-codex": AccountReading(signIn: .signedIn, plan: "plus", email: "work@example.com", note: AccountWords.codexSignedInTip)]
        var (v, h) = try pane(accounts: [], readings: signed, repos: [], height: 330)
        try render("accounts-1-signed-in", v, width: 600, height: h)
        (v, h) = try pane(accounts: [], readings: signed, emailFor: "default-claude", repos: [], height: 330)
        try render("accounts-2-email-shown", v, width: 600, height: h)
        (v, h) = try pane(accounts: [work, codexAlt],
                          readings: signed.merging(["w1": AccountReading(signIn: .notSignedIn), "c1": AccountReading(note: "Folder not found")]) { $1 },
                          repos: [], height: 560)
        try render("accounts-3-not-signed-in-and-unknown", v, width: 600, height: h)
        let routing = RoutingFile(projects: ["/Users/example/Projects/true": ProjectRouting(defaultModel: ModelChoice(provider: .claude, model: "opus"),
                                                                                      fallbackModel: ModelChoice(provider: .codex, model: nil)),
                                             "/Users/example/Projects/clipping-site": ProjectRouting()])
        (v, h) = try pane(accounts: [], readings: signed, routing: routing, height: 560)
        try render("accounts-4-project-defaults", v, width: 600, height: h)
        (v, h) = try pane(accounts: [], readings: [:], repos: [], height: 330)
        try render("accounts-5-empty", v, width: 600, height: h)
    }

    @Test func cards() throws {
        let claude = Agent(name: "true-lead", role: .lead, repo: "/Users/example/Projects/true", model: .opus)
        let until = Calendar.current.date(bySettingHour: 14, minute: 20, second: 0, of: Date())!
        func card(_ rt: SeatRuntimeInfo?, fallback: FallbackCard? = nil, as agent: Agent) -> some View {
            var acts = SeatActions.inert
            acts.status = { _ in .idle }; acts.isAwake = { _ in fallback != nil }
            acts.capabilities = { _ in SeatCapabilities.make(agent.seatProvider) }
            acts.runtime = { _ in rt }; acts.fallback = { _ in fallback }
            return AgentCard(agent: agent, actions: acts).padding(20)
        }
        try render("card-1-limited-until", card(SeatRuntimeInfo(installed: true, signIn: .signedIn, limitedUntil: until), as: claude), width: 400)
        guard case let .useFallback(fb) = FallbackOnWake.decide(chosen: .claude, chosenFacts: RoutingTests.claudeFull, fallback: RoutingTests.fallback,
                                                                fallbackFacts: RoutingTests.codexGood, explicitModel: false, isFreshWake: true, now: RoutingTests.now)
        else { Issue.record("no fallback"); return }
        var onCodex = claude; onCodex.provider = .codex
        try render("card-2-using-fallback", card(SeatRuntimeInfo(installed: true, signIn: .signedIn), fallback: fb, as: onCodex), width: 400)
    }
}

/// "Sign in" runs the provider's own login in that account's folder; the normal account gets no folder override.
@Suite struct AccountSignInRowTests {
    @Test func signInRunsTheLoginInTheAccountsOwnFolder() {
        let work = AccountRowFacts.make(ResolvedAccount(provider: .claude, id: "w", label: "Work", configDir: "/tmp/work",
                                                        directory: URL(fileURLWithPath: "/tmp/work")), reading: nil)
        #expect(work.signInCommand == SignInCommand.make(provider: .claude, configDir: "/tmp/work"))
        #expect(work.signInCommand.env["CLAUDE_CONFIG_DIR"] == "/tmp/work")
        let normal = AccountRowFacts.make(ResolvedAccount(provider: .codex, id: nil, label: "Codex", configDir: nil,
                                                          directory: URL(fileURLWithPath: "/h/.codex")), reading: nil)
        #expect(normal.configDir == nil && normal.signInCommand.env.isEmpty && normal.signInCommand.unset.contains("CODEX_HOME"))
    }
}
