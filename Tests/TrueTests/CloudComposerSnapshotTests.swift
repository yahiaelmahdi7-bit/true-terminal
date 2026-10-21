import Testing
import Foundation
import SwiftUI
import AppKit
@testable import True

/// A synthetic, dense, multi-colour terminal: what the Hub and composer must stay legible over. Never a real capture.
struct BusyBackdrop: View {
    let size: CGSize
    private static let palette: [Color] = [.green, .cyan, .yellow, .pink, .orange, .white, .mint, .purple]
    private static let words = ["swift", "build", "Compiling", "error:", "warning:", "PASS", "FAIL", "git", "commit", "0x7ffee4", "func",
                                "await", "struct", "Tests/", "Sources/True/", "✔", "✘", "[142/303]", "main", "diff", "--stat", "@@", "+++", "---"]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<Int(size.height / 15) + 1, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<14, id: \.self) { col in
                        let k = row * 31 + col * 17
                        Text(Self.words[k % Self.words.count] + " " + String(format: "%04x", (k * 2654435761) & 0xffff) + " ")
                            .foregroundStyle(Self.palette[(row + col * 3) % Self.palette.count].opacity(0.85))
                    }
                }
            }
        }
        .font(.system(size: 12, design: .monospaced)).lineLimit(1).fixedSize()
        .frame(width: size.width, height: size.height, alignment: .topLeading).clipped().background(Color.black)
    }
}

/// Renders the "Run in cloud" composer over the busy backdrop, in every state. Skipped unless TRUE_SNAPSHOT_DIR is set.
@MainActor
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty, "TRUE_SNAPSHOT_DIR not set"))
struct CloudComposerSnapshotTests {
    private var dir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp") }
    private static let window = CGSize(width: 1600, height: 1000)

    private func snapshot<V: View>(_ name: String, @ViewBuilder _ view: () -> V) throws {
        let (w, h) = (Self.window.width, Self.window.height)
        let root = view().frame(width: w, height: h).environment(\.colorScheme, .dark).background(Color.black)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { Issue.record("no bitmap rep"); return }
        rep.size = NSSize(width: w, height: h)
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { Issue.record("no png"); return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// The composer as the sheet sits over the pop-up: backdrop, scrim, then the card with the sheet's shadow.
    private func scene(_ model: CloudComposerModel) -> some View {
        ZStack {
            BusyBackdrop(size: Self.window)
            Color.black.opacity(HubOverlay.scrimOpacity)
            CloudComposerContent(model: model)
                .frame(width: CloudComposerContent.width)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.55), radius: 36, y: 14)
        }
    }

    private static let sha = String(repeating: "a", count: 40)
    private func fake(_ name: String, branch: String, subject: String, ageH: Double, dirty: Int) -> CloudRepoInfo {
        CloudRepoInfo(path: "/Users/example/Projects/\(name)", kind: .ready, branch: branch, sha: Self.sha, subject: subject,
                      committedAt: Date().timeIntervalSince1970 - ageH * 3600, dirtyCount: dirty)
    }

    /// Read-only: the git repos directly under ~/Projects, newest commit first.
    private func realRepos() -> [CloudRepoInfo] {
        let root = NSHomeDirectory() + "/Projects"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        let infos = names.filter { !$0.hasPrefix(".") && !$0.contains(".builders") }
            .map { CloudRepoInfo.read(path: root + "/" + $0) }.filter(\.isRunnable)
        return Array(infos.sorted { ($0.committedAt ?? 0) > ($1.committedAt ?? 0) }.prefix(8))
    }

    private func model(repos: [CloudRepoInfo], selected: CloudRepoInfo? = nil, prompt: String = "", link: CloudComposerLink = .online) -> CloudComposerModel {
        let suite = UserDefaults(suiteName: "cloud-snap-\(UUID().uuidString)")!
        let m = CloudComposerModel(projects: [], prefs: CloudPrefs(defaults: suite))
        m.repos = repos; m.selected = selected; m.prompt = prompt; m.link = link
        m.health = link == .online ? CloudHealth(running: 1, queued: 0, maxJobs: 2) : nil
        m.runningJobs = 1
        return m
    }

    @Test func states() throws {
        let sample = [fake("true", branch: "main", subject: "Hub v3: real-data + sample proofs", ageH: 2, dirty: 0),
                      fake("prism", branch: "feature/editor", subject: "Fix Tiptap paste handling", ageH: 30, dirty: 3)]
        let real = realRepos()
        let task = "Fix the failing login test and add a regression test"
        try snapshot("composer-1-empty") { scene(model(repos: sample)) }
        try snapshot("composer-2-real-repos") { scene(model(repos: real)) }
        let dirty = fake("prism", branch: "feature/editor", subject: "Fix Tiptap paste handling", ageH: 30, dirty: 3)
        let m3 = model(repos: sample, selected: dirty, prompt: task); m3.showMore = true; m3.effort = "xhigh"; m3.model = "claude-opus-5-5"
        try snapshot("composer-3-dirty-repo-selected") { scene(m3) }
        let m4 = model(repos: sample, selected: sample[0], prompt: task); m4.send = .running(.uploading)
        try snapshot("composer-4-sending-step-2") { scene(m4) }
        let m5 = model(repos: sample, selected: sample[0], prompt: task)
        m5.send = .failed(.uploading, "Couldn't copy the repo to the cloud: ssh: connect to host 100.120.234.70 port 22: Operation timed out")
        try snapshot("composer-5-failed-retry") { scene(m5) }
        let m6 = model(repos: sample, selected: sample[0], prompt: task, link: .offline)
        try snapshot("composer-6-offline") { scene(m6) }
        let notGit = CloudRepoInfo(path: "/Users/example/Documents/notes", kind: .notGit)
        try snapshot("composer-7-not-git") { scene(model(repos: sample, selected: notGit, prompt: task)) }
        let summary = real.map { "\($0.name)\t\($0.branch)\t\($0.stateLabel)" }.joined(separator: "\n")
        try summary.write(to: dir.appendingPathComponent("real-repos-summary.txt"), atomically: true, encoding: .utf8)
    }
}
