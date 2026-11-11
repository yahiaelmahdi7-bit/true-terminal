import Testing
import Foundation
import SwiftUI
import AppKit
@testable import True

/// `TRUE_SNAPSHOT_DIR=$PWD/.out/stills/peers-health swift test --filter PeerHealthSnapshotTests`: the Peers list in each health state, light + dark.
@MainActor
@Suite(.serialized, .enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty, "TRUE_SNAPSHOT_DIR not set"))
struct PeerHealthSnapshotTests {
    private var dir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp") }

    private func snapshot<V: View>(name: String, dark: Bool, @ViewBuilder view: () -> V) throws {
        let width: CGFloat = 420
        let root = view().frame(width: width, alignment: .topLeading).environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: width, height: max(host.fittingSize.height, 100))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { Issue.record("no bitmap rep"); return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { Issue.record("no png"); return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @Test func eachHealthState() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000), tz = TimeZone(identifier: "UTC")!
        func st(_ heard: TimeInterval?, card: Bool = true, v: String = PeerCaps.currentVersion) -> PeerHealth.State {
            PeerHealth.state(heard: heard.map { now.addingTimeInterval(-$0) }, sentCard: card, cardVersion: v, linkAge: 9999, now: now)
        }
        let rows: [(String, String)] = [
            ("Bea", PeerHealth.line(st(120), build: "2026-11-02", flowing: true, tz: tz)),
            ("Cy", PeerHealth.line(st(3 * 3600), build: nil, flowing: false, tz: tz)),
            ("Dee", PeerHealth.line(st(60, v: "1.0"), build: nil, flowing: false, tz: tz)),
            ("Eli", PeerHealth.line(st(nil, card: false), build: nil, flowing: false, tz: tz)),
            ("Fay", "Link removed by them at 00:50")]
        for dark in [false, true] {
            try snapshot(name: "peers-health-\(dark ? "dark" : "light")", dark: dark) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(PeerHealth.relayLine(connected: true)).font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
                    Text("Your peers").font(.headline).padding(.bottom, 4)
                    ForEach(rows, id: \.0) { r in PeerHealthRow(label: r.0, line: r.1, revoke: {}) { EmptyView() } }
                    Text("Peer problems").font(.headline).padding(.top, 12)
                    Text("00:50 · Bea removed the link").font(.callout).foregroundStyle(.secondary).frame(minHeight: 44, alignment: .leading)
                }.padding(16)
            }
        }
    }
}
