import Testing
import Foundation
import SwiftUI
import AppKit
@testable import True

/// Renders the Peers "On this network" section to PNGs: `TRUE_SNAPSHOT_DIR=$PWD/.out/stills/run39-lan swift test --filter PeerLanSnapshotTests`.
@MainActor
@Suite(.serialized, .enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty,
                             "TRUE_SNAPSHOT_DIR not set"))
struct PeerLanSnapshotTests {
    private var dir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp") }

    private func snapshot<V: View>(name: String, width: CGFloat, height: CGFloat? = nil, dark: Bool, @ViewBuilder view: () -> V) throws {
        let root = view().frame(width: width, height: height, alignment: .topLeading).environment(\.colorScheme, dark ? .dark : .light)
            // The Peers window is a plain titled NSWindow that follows the system appearance, not True's black chrome.
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: width, height: height ?? max(host.fittingSize.height, 100))
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

    private func both(_ state: String, _ lan: PeerLanCoordinator) throws {
        for dark in [true, false] {
            try snapshot(name: "lan-\(state)-\(dark ? "dark" : "light")", width: 420, dark: dark) {
                VStack(alignment: .leading) { PeerLanSection(lan: lan) }.padding(16)
            }
        }
    }

    private func settle(_ w: PeerLanFlowTests.World) { w.settle(); w.nodes.forEach { $0.lan.rebuild() } }

    @Test func empty() throws {
        let w = PeerLanFlowTests.World(); defer { w.close() }
        let a = w.node("Me"); a.lan.open()
        try both("empty", a.lan)
    }

    @Test func found() throws {
        let w = PeerLanFlowTests.World(); defer { w.close() }
        let a = w.node("Me"), b = w.node("Mahmoud's MacBook Pro"), c = w.node("Studio iMac")
        a.lan.open(); b.lan.open(); c.lan.open()
        let row = try #require(a.rowId("Studio iMac"))
        a.lan.invite(rowId: row); w.net.run()
        a.lan.confirmSend(); c.lan.accept(); w.net.run()
        settle(w)
        #expect(a.lan.rows.count == 2 && a.lan.sendState[row] == .paired)
        try both("found", a.lan)
    }

    @Test func senderCheck() throws {
        let w = PeerLanFlowTests.World(); defer { w.close() }
        let a = w.node("Mahmoud's MacBook Pro"), b = w.node("Studio iMac")
        a.lan.open(); b.lan.open()
        let row = try #require(a.rowId("Studio iMac"))
        a.lan.invite(rowId: row); w.net.run()
        guard case .check? = a.lan.sendState[row] else { Issue.record("no code"); return }
        try both("sender-check", a.lan)
    }

    @Test func receiverPrompt() throws {
        let w = PeerLanFlowTests.World(); defer { w.close() }
        let a = w.node("Mahmoud's MacBook Pro"), b = w.node("Studio iMac")
        a.lan.open(); b.lan.open()
        a.lan.invite(rowId: try #require(a.rowId("Studio iMac"))); w.net.run()
        #expect(b.lan.prompt != nil)
        try both("receiver-prompt", b.lan)
    }

    @Test func denied() throws {
        let w = PeerLanFlowTests.World(); defer { w.close() }
        let a = w.node("Me"); a.lan.open()
        a.transport.onBrowse?(.state(.denied))
        #expect(a.lan.lanState == .denied)
        try both("denied", a.lan)
    }
}
