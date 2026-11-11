import Testing
import SwiftUI
import AppKit
@testable import True

/// Missions M1 stills: offscreen renders of the changed views (status labels, desk rows), light + dark.
@MainActor @Suite(.serialized) struct PeerStillsM1Tests {
    struct Sample: View {
        var body: some View {
            let at = Date(timeIntervalSince1970: 1_800_000_000)
            VStack(alignment: .leading, spacing: 10) {
                Text(PeerStatusText.label(.paused, resumeAt: at, peer: "Bea"))
                Text(PeerStatusText.label(.needsYou, note: "Pick which repo to use", needsYouAsSender: true))
                Text(PeerStatusText.label(.canceled))
                Divider()
                PeerDeskRow(desk: .init(key: "bea|app", peer: "Bea", project: "app", running: "Fix the login", inLine: 1, lane: 1))
                PeerDeskRow(desk: .init(key: "bea|app", peer: "Bea", project: "app", running: nil, inLine: 0, lane: 2))
            }
            .font(.callout).padding(16).frame(width: 440, alignment: .leading)
        }
    }

    @Test func rendersStills() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(".out/stills/missions-m1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: Sample().background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: ap)
            view.frame = NSRect(x: 0, y: 0, width: 440, height: 220)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("status-and-desks-\(name).png"))
        }
    }
}
