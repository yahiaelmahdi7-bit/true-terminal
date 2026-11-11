import Testing
import Foundation
import SwiftUI
import AppKit
@testable import True

/// Capability honesty: the editor's list, the card's Stop turn and `truectl status` all read one `SeatCapabilities`.
@MainActor
@Suite struct CodexSeatsUITests {
    static let known = SeatRuntimeInfo(installed: true, version: CodexRuntime.capturedVersion)

    @Test func editorListMatchesCapabilities() {
        for provider in SeatProvider.allCases {
            let caps = Self.known.capabilities(for: provider)
            let lines = SeatCapabilityLine.lines(caps)
            #expect(lines.map(\.feature) == SeatCapabilities.Feature.allCases)
            for l in lines { #expect(l.on == caps.supports(l.feature)) }
            for l in lines where !l.on { #expect(l.note?.isEmpty == false) }   // every "no" carries a plain reason
            #expect(SeatCapabilityLine.versionNote(caps) == nil)
        }
        // Other Codex version: nothing is claimed, and it says why.
        let other = SeatRuntimeInfo(installed: true, version: "codex-cli 9.9.9").capabilities(for: .codex)
        #expect(SeatCapabilityLine.lines(other).allSatisfy { !$0.on && $0.note == nil })   // said once, not per row
        #expect(SeatCapabilityLine.versionNote(other) == "Not checked on your Codex version")
        #expect(Self.known.capabilities(for: .codex) == CodexRuntime(installed: true, version: CodexRuntime.capturedVersion).capabilities)
    }

    @Test func threeSurfacesAgree() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ws = WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("w.json")))
        let r = AgentRegistry(store: AgentStore(url: dir.appendingPathComponent("agents.json")), paths: AgentPaths(root: dir),
                              workspace: ws, claudeDir: dir, codexDir: dir)
        for p in SeatProvider.allCases {
            let a = Agent(name: "seat-\(p.rawValue)", role: .helper, repo: dir.path, provider: p)
            r.save(a)
            let registryCaps = try #require(r.capabilities(for: a.name))
            let row = try #require(AgentControl.agentRows(r).first { $0.name == a.name })
            #expect(row.capabilities == registryCaps)                                   // truectl status
            let live = SeatActions.live(r)
            #expect(live.capabilities(a.name) == registryCaps)                          // the card
            for status in [AgentStatus.asleep, .idle, .working, .needsYou, .done] {
                let facts = SeatCardFacts(provider: p, status: status, capabilities: live.capabilities(a.name), runtime: nil, issue: nil)
                #expect(facts.showsStop == (status == .working && registryCaps.supports(.stopTurn)))
            }
            // The editor reads the same rows (Codex checked on the captured version).
            let editorCaps = SeatRuntimeInfo(installed: true, version: CodexRuntime.capturedVersion).capabilities(for: p)
            let editorOn = Set(SeatCapabilityLine.lines(editorCaps).filter(\.on).map(\.feature))
            if p == .claude { #expect(editorOn == Set(registryCaps.rows.filter(\.supported).map(\.feature))) }
            if p == .codex {
                let verified = SeatCapabilities.make(.codex, verified: true)
                #expect(editorOn == Set(verified.rows.filter(\.supported).map(\.feature)))
                // On an unknown version the registry's own list claims nothing too, unless this machine's Codex matches.
                #expect(registryCaps.supports(.stopTurn) == SeatProviders.codexRuntime.capabilities.supports(.stopTurn))
            }
        }
    }

    @Test func lifecycleWordsAndUnknownNeverSignedIn() {
        func line(_ rt: SeatRuntimeInfo?, _ status: AgentStatus = .asleep, issue: SeatStartupIssue? = nil, provider: SeatProvider = .codex) -> String? {
            SeatCardFacts(provider: provider, status: status, capabilities: nil, runtime: rt, issue: issue).lifecycle
        }
        #expect(line(SeatRuntimeInfo(installed: false)) == "Codex not installed")
        #expect(line(SeatRuntimeInfo(installed: true, signIn: .notSignedIn)) == "Not signed in to Codex")
        #expect(line(SeatRuntimeInfo(installed: true, signIn: .unknown)) == "Codex sign-in not checked")
        #expect(line(SeatRuntimeInfo(installed: true, signIn: .unknown), .working) == nil)
        let until = Calendar.current.date(bySettingHour: 14, minute: 20, second: 0, of: Date())!
        #expect(line(SeatRuntimeInfo(installed: true, signIn: .signedIn, limitedUntil: until))?.hasPrefix("Limited until ") == true)
        #expect(line(SeatRuntimeInfo(installed: true, signIn: .unknown), .needsYou, issue: .hooksApproval) == "Approve True's hooks")
        #expect(line(SeatRuntimeInfo(installed: false), provider: .claude) == nil)          // Claude cards never change
        #expect(SeatCardFacts(provider: .claude, status: .idle, capabilities: nil, runtime: nil, issue: nil).markLabel == nil)
        for text in ["Codex not installed", "Not signed in to Codex", "Codex sign-in not checked", "Not checked on your Codex version", "Approve True's hooks", "Sign in to Codex"] {
            #expect(!text.contains("_") && !text.contains("0x"))                              // human words, no raw codes
        }
    }

    @Test func providerLockReasons() {
        var d = BuilderDraft(repo: "/tmp/x", role: .helper)
        #expect(d.providerLock(awake: false, codexInstalled: true) == nil)
        #expect(d.providerLock(awake: true, codexInstalled: true) == "Put the seat to sleep to switch")
        #expect(d.providerLock(awake: false, codexInstalled: false) == "Codex is not installed")
        d.provider = .codex                                   // a Codex seat can always go back to Claude
        #expect(d.providerLock(awake: false, codexInstalled: false) == nil)
        #expect(BuilderDraft(repo: "", role: .watcher).providerLock(awake: false, codexInstalled: true) == "Duty seats use Claude")
    }
}

/// Stills: skipped unless TRUE_SNAPSHOT_DIR is set.
/// `TRUE_SNAPSHOT_DIR=$PWD/docs/designs/stills/codex-seats swift test --filter CodexSeatsStillsTests`
@MainActor
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty, "TRUE_SNAPSHOT_DIR not set"))
struct CodexSeatsStillsTests {
    private func render(_ name: String, _ scheme: ColorScheme, _ view: some View, width: CGFloat) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp")
        let framed = view.frame(width: width).background(scheme == .dark ? Color.black : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: framed)
        let size = NSSize(width: width, height: max(host.fittingSize.height, 60))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
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
        try png.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    }

    private func registry() throws -> AgentRegistry {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stills-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AgentRegistry(store: AgentStore(url: dir.appendingPathComponent("agents.json")), paths: AgentPaths(root: dir),
                             workspace: WorkspaceModel(store: WorkspaceStore(url: dir.appendingPathComponent("w.json"))),
                             claudeDir: dir, codexDir: dir)
    }

    private let known = SeatRuntimeInfo(installed: true, version: CodexRuntime.capturedVersion, signIn: .signedIn)

    private func sheet(_ agent: Agent?, provider: SeatProvider, role: AgentRole = .lead, awake: Bool = false,
                       runtime: SeatRuntimeInfo, duty: Bool = false) throws -> some View {
        let r = try registry()
        var d = agent.map(BuilderDraft.init(editing:)) ?? BuilderDraft(repo: "/Users/example/Projects/true", role: role)
        d.provider = provider
        if duty { d.isDutySeat = true }
        return AgentBuilderSheet(draft: d, registry: r, awakeOverride: awake, runtimeOverride: runtime)
    }

    @Test(arguments: [ColorScheme.dark, .light]) func editors(scheme: ColorScheme) throws {
        let claudeSeat = Agent(name: "true-lead", role: .lead, repo: "/Users/example/Projects/true")
        let codexSeat = Agent(name: "true-lead", role: .lead, repo: "/Users/example/Projects/true", provider: .codex)
        try render("editor-1-claude", scheme, try sheet(claudeSeat, provider: .claude, runtime: known), width: 740)
        try render("editor-2-codex", scheme, try sheet(codexSeat, provider: .codex, runtime: known), width: 740)
        try render("editor-3-awake", scheme, try sheet(codexSeat, provider: .codex, awake: true, runtime: known), width: 740)
        try render("editor-4-not-installed", scheme,
                   try sheet(claudeSeat, provider: .claude, runtime: SeatRuntimeInfo(installed: false)), width: 740)
        let duty = Agent(name: "true-watch", role: .watcher, repo: "/Users/example/Projects/true")
        try render("editor-5-duty-seat", scheme, try sheet(duty, provider: .claude, runtime: known), width: 740)
        try render("editor-6-codex-other-version", scheme,
                   try sheet(codexSeat, provider: .codex, runtime: SeatRuntimeInfo(installed: true, version: "codex-cli 9.9.9", signIn: .unknown)),
                   width: 740)
    }

    @Test(arguments: [ColorScheme.dark, .light]) func cards(scheme: ColorScheme) throws {
        let codex = Agent(name: "true-lead", role: .lead, repo: "/Users/example/Projects/true", model: .sonnet, provider: .codex)
        let claude = Agent(name: "true-docs", role: .helper, repo: "/Users/example/Projects/true", model: .opus)
        let until = Calendar.current.date(bySettingHour: 14, minute: 20, second: 0, of: Date())!
        func card(_ a: Agent, _ status: AgentStatus, _ rt: SeatRuntimeInfo?, issue: SeatStartupIssue? = nil) -> some View {
            var acts = SeatActions.inert
            let caps = rt.map { $0.capabilities(for: a.seatProvider) } ?? SeatCapabilities.make(a.seatProvider)
            acts.status = { _ in status }; acts.isAwake = { _ in status != .asleep }
            acts.capabilities = { _ in caps }; acts.runtime = { _ in rt }; acts.startupIssue = { _ in issue }
            return AgentCard(agent: a, actions: acts).padding(20)
        }
        try render("card-1-working-stop", scheme, card(codex, .working, known), width: 400)
        try render("card-2-not-installed", scheme, card(codex, .asleep, SeatRuntimeInfo(installed: false)), width: 400)
        try render("card-3-not-signed-in", scheme, card(codex, .asleep, SeatRuntimeInfo(installed: true, version: CodexRuntime.capturedVersion, signIn: .notSignedIn)), width: 400)
        try render("card-4-unknown", scheme, card(codex, .asleep, SeatRuntimeInfo(installed: true, version: CodexRuntime.capturedVersion, signIn: .unknown)), width: 400)
        try render("card-5-limited", scheme, card(codex, .idle, SeatRuntimeInfo(installed: true, version: CodexRuntime.capturedVersion, signIn: .signedIn, limitedUntil: until)), width: 400)
        try render("card-6-approve-hooks", scheme, card(codex, .needsYou, known, issue: .hooksApproval), width: 400)
        try render("card-7-claude-working", scheme, card(claude, .working, nil), width: 400)
    }
}
