import Testing
import Foundation
import SwiftUI
import AppKit
@testable import True

/// Renders the Hub from fixtures to PNGs (the only way to see it without launching True.app).
/// Skipped unless TRUE_SNAPSHOT_DIR is set: `TRUE_SNAPSHOT_DIR=$PWD/docs/design/hub-v4 swift test --filter HubSnapshotTests`.
@MainActor
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty,
                "TRUE_SNAPSHOT_DIR not set"))
struct HubSnapshotTests {
    private var dir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp")
    }

    /// Host in an offscreen borderless window (never ordered front), dark appearance, 2x PNG.
    private func snapshot<V: View>(_ name: String, width: CGFloat, height: CGFloat? = nil, @ViewBuilder _ view: () -> V) throws {
        let root = view().frame(width: width, height: height, alignment: .topLeading).environment(\.colorScheme, .dark).background(Theme.background)
        let host = NSHostingView(rootView: root)
        let fitted = host.fittingSize
        let size = NSSize(width: width, height: height ?? max(fitted.height, 100))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (transitions, .task) before capture.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { Issue.record("no bitmap rep"); return }
        rep.size = NSSize(width: size.width, height: size.height)
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { Issue.record("no png"); return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: fixtures

    private static let now = 1_800_000_000.0
    private let lead = Agent(name: "lead", role: .lead, repo: "/Users/example/Projects/true", model: .opus, effort: .high,
                             permission: .auto, symbol: "crown", hue: "coral")
    private let helper = Agent(name: "true-hub-design-helper-with-a-very-long-name", role: .helper,
                               repo: "/Users/example/Projects/true", model: .sonnet, effort: .low, permission: .default)
    private let cfo = Agent(name: "cfo", role: .lead, repo: "/Users/example/Projects/finance-desk", model: .opus,
                            effort: .medium, permission: .acceptEdits)

    private func builder(_ id: String, _ cwd: String, state: BuilderState, parent: String?, acked: Bool = false) -> BuilderRecord {
        BuilderRecord(id: id, name: id, cwd: cwd, originCwd: cwd, model: "sonnet", sessionID: "s-\(id)", claudePID: 0,
                      started: Self.now - 1500, ended: state == .running ? nil : Self.now - 200, state: state,
                      acked: acked, parent: parent, branch: nil, worktree: nil, cost: 1.2, budget: 5, dir: nil)
    }

    private var statuses: [String: AgentStatus] { ["lead": .working, helper.name: .asleep, "cfo": .needsYou] }
    private var actions: SeatActions {
        var a = SeatActions.inert
        let s = statuses
        a.status = { s[$0] ?? .asleep }
        a.isAwake = { (s[$0] ?? .asleep) != .asleep }
        return a
    }

    private func groups(seatsOnly: Bool = false) -> [HubProjectGroup] {
        let peers = [PeerSession(pid: Int32(ProcessInfo.processInfo.processIdentifier), sessionID: "p1",
                                 cwd: "/Users/example/Projects/true", name: "scratch", kind: "interactive", busy: true,
                                 updatedAt: Self.now - 60)]
        let builders = [builder("true-hub-design", "/Users/example/Projects/true", state: .running, parent: "lead"),
                        builder("true-fixes", "/Users/example/Projects/true", state: .done, parent: nil),
                        builder("ledger-audit", "/Users/example/Projects/finance-desk", state: .failed, parent: "cfo")]
        return HubModel.build(seats: [lead, helper, cfo], seatStatus: { self.statuses[$0] ?? .asleep },
                              seatAwake: { (self.statuses[$0] ?? .asleep) != .asleep }, peers: peers,
                              builders: builders, now: Self.now, seatsOnly: seatsOnly, hasGit: { _ in true })
    }

    private func hub(groups: [HubProjectGroup], seats: [Agent], seatsOnly: Bool = false) -> some View {
        HubPanelContent(groups: groups, allSeats: seats, filter: .constant(seatsOnly ? .seats : .all), now: Self.now, actions: actions)
    }

    // MARK: snapshots

    @Test func hubAll() throws {
        try snapshot("hub-all", width: HubPanelContent.width) { hub(groups: groups(), seats: [lead, helper, cfo]) }
    }

    @Test func hubSeats() throws {
        try snapshot("hub-seats", width: HubPanelContent.width) {
            hub(groups: groups(seatsOnly: true), seats: [lead, helper, cfo], seatsOnly: true)
        }
    }

    @Test func hubEmpty() throws {
        try snapshot("hub-empty", width: HubPanelContent.width, height: 420) { hub(groups: [], seats: []) }
    }

    // MARK: Overseer

    @Test func overseerVerdicts() throws {
        let t = Date(timeIntervalSince1970: Self.now)
        let kinds: [(VerdictKind, String, Double)] = [
            (.blocked, "Hit an error", 90), (.asksYou, "Waiting on your answer", 300),
            (.unverified, "Says done; no check ran", 600), (.asksToContinue, "Wants to carry on", 900),
            (.partial, "Stopped with work left", 1500), (.verified, "A check ran after the work", 30)]
        var verdicts: [UUID: OverseerVerdict] = [:]
        var names: [UUID: String] = [:]
        var titles: [UUID: String] = [:]
        for (i, k) in kinds.enumerated() {
            let id = UUID()
            verdicts[id] = OverseerVerdict(kind: k.0, reason: k.1, at: t.addingTimeInterval(-k.2), sessionID: "v\(i)",
                                           cwd: i % 2 == 0 ? "/Users/example/Projects/true" : "/Users/example/Projects/finance-desk")
            if i < 2 { names[id] = i == 0 ? "lead" : "cfo" }
            // Plain panes: a default title (the folder name, said once) and a custom-named tab.
            else { titles[id] = i == 3 ? "invoices" : (verdicts[id]?.cwd as NSString?)?.lastPathComponent }
        }
        let rows = YourMoveRow.build(verdicts, seatName: { names[$0] }, tabTitle: { titles[$0] })
        var a = actions
        a.verdict = { $0 == "lead" ? .blocked : $0 == "cfo" ? .asksYou : nil }
        try snapshot("overseer-all-card", width: 1000, height: 780) {
            popUp {
                HubPanelContent(groups: groups(), allSeats: [lead, helper, cfo], filter: .constant(.all), now: Self.now,
                                actions: a, yourMove: rows, peerVerdict: { _ in .unverified })
            }
        }
        try snapshot("overseer-badges", width: 420) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(VerdictKind.allCases, id: \.self) { VerdictBadge(kind: $0) }
            }.padding(20)
        }
    }

    // MARK: crew + card

    private func crewAgent(_ n: String, _ d: String, _ m: String = "sonnet") -> CrewAgent {
        CrewAgent(name: n, summary: d, fullDescription: d, model: m, color: nil)
    }

    private var crewSnapshot: CrewSnapshot {
        let project = CrewGroup(title: "Engineering", agents: [
            crewAgent("true-cto", "Crew lead for True. Routing, architecture calls, ADRs, gate enforcement.", "inherit"),
            crewAgent("true-swift-engineer", "Swift engineer for True. Writing or fixing SwiftUI and SwiftPM code."),
            crewAgent("true-security", "Defensive security for True. Secrets, auth, dependencies.")])
        let design = CrewGroup(title: "Design", agents: [
            crewAgent("true-ui-designer", "Visual designer for True. Every v1 passes /taste before the user sees it.", "opus"),
            crewAgent("true-ux-designer", "")])
        let global = [CrewGroup(title: "studio", agents: [crewAgent("studio-ai-engineer", "Implements AI features."),
                                                          crewAgent("studio-joker", "Lightens the mood.", "haiku")]),
                      CrewGroup(title: "argus", agents: [crewAgent("argus-orchestrator", "Conducts the Argus build.")])]
        return CrewSnapshot(projectTitle: "true", project: [project, design], global: global)
    }

    /// The pop-up as it sits in a window: busy fake terminal text, the 0.35 scrim, and the card centered at the real
    /// width/height rule. Real glass can't render offscreen, so the backing approximates it (black ~0.7 over
    /// ultraThinMaterial): judges hierarchy, spacing, width use and contrast, not refraction.
    private func popUp<V: View>(window: CGSize = CGSize(width: 1000, height: 780), @ViewBuilder _ content: () -> V) -> some View {
        let w = min(HubPanelContent.width, window.width - 2 * HubOverlay.margin)
        let h = min(window.height * HubOverlay.heightShare, HubOverlay.maxHeight)
        return ZStack {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<56, id: \.self) { i in
                    Text("$ swift test --filter Hub\(i) … Test run with \(320 + i) tests passed after 0.\(i)s in suite HubSnapshotTests")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.green.opacity(0.8)).lineLimit(1)
                }
            }.frame(width: window.width, height: window.height, alignment: .topLeading).clipped()
            Color.black.opacity(0.35)
            content()
                .frame(width: w, height: h)
                .background(Color.black.opacity(0.7), in: HubOverlay.shape)
                .background(.ultraThinMaterial, in: HubOverlay.shape)
                .overlay(HubOverlay.shape.strokeBorder(Theme.hubCardStroke, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        }
    }

    @Test func crewTab() throws {
        try snapshot("hub-crew", width: HubPanelContent.width) {
            HubPanelContent(groups: [], allSeats: [lead], filter: .constant(.crew), now: Self.now, actions: actions,
                            crew: crewSnapshot, crewNotice: "Copied")
        }
    }

    @Test func crewCard() throws {
        try snapshot("hub-crew-card", width: 1000, height: 780) {
            popUp {
                HubPanelContent(groups: [], allSeats: [lead], filter: .constant(.crew), now: Self.now, actions: actions,
                                crew: crewSnapshot, crewNotice: "Copied")
            }
        }
    }

    @Test func seatsCard() throws {
        try snapshot("hub-seats-card", width: 1000, height: 780) {
            popUp { hub(groups: groups(seatsOnly: true), seats: [lead, helper, cfo], seatsOnly: true) }
        }
    }

    @Test func allCard() throws {
        try snapshot("hub-all-card", width: 1000, height: 780) {
            popUp { hub(groups: groups(), seats: [lead, helper, cfo]) }
        }
    }

    @Test func builderColour() throws {
        try snapshot("builder-colour", width: 420) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    AgentAvatar(hue: .aqua, symbol: "crown", status: .idle, size: 56)
                    VStack(alignment: .leading) {
                        Text("lead").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("Opus · Auto").font(.caption).foregroundStyle(Theme.hubSecondary)
                    }
                }
                Text("Colour").font(.caption.weight(.medium)).foregroundStyle(Theme.hubSecondary)
                HueRow(selection: .constant(.aqua))
            }.padding(20)
        }
    }

    @Test func avatars() throws {
        let states: [AgentStatus] = [.asleep, .idle, .working, .needsYou]
        try snapshot("avatars", width: 480) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(AgentHue.allCases, id: \.self) { h in
                    HStack(spacing: 18) {
                        Text(h.rawValue).font(.caption).foregroundStyle(Theme.hubSecondary).frame(width: 64, alignment: .leading)
                        ForEach(states, id: \.self) { s in AgentAvatar(hue: h, symbol: "crown", status: s, size: 40).frame(width: 52, height: 52) }
                    }
                }
                HStack(spacing: 18) {
                    AgentAvatar(hue: .rose, symbol: "hammer", status: .working, size: 28, parentHue: .azure)
                    AgentAvatar(hue: nil, symbol: "terminal", status: .idle, size: 28)
                }
            }.padding(20)
        }
    }
}
