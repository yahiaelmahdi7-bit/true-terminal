import Testing
import Foundation
import SwiftUI
import AppKit
@testable import True

private let realShaped = """
{"written_at":"2026-11-01T19:59:37Z","extra":1,
 "top":[{"id":"steward-s2","title":"Steward 2","why":"finish before start","waits_on":[],"source":"true:docs/designs/steward.md#Steps","future":true},
        {"id":"gm3","title":"Go-live GM3","plain":"Quarterly VAT proof","why":"write the brief","waits_on":["ready","brief"],"source":"ledger:docs/designs/go-live-2027.md#Schedule (weeks)"},
        {"id":"x3","title":"Three"},{"id":"x4","title":"Four"},{"id":"x5","title":"Five"},{"id":"x6","title":"Six"}],
 "calls":[{"id":"oss-d1","title":"One source for enums","what":"build-it","question":"Build D1?"},
          {"id":"oss-d1","title":"dup","what":"build-it"},
          {"id":"call-oracle","title":"Oracle UAE","what":"spend","question":"Approve?"}],
 "running":[{"id":"wq-w4"}],"last_launches":["a"]}
"""

private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("wq-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

struct WorkQueueTests {
    @Test func decodesRealShape() throws {
        guard case .snapshot(let s) = WorkQueue.parse(Data(realShaped.utf8)) else { Issue.record("not a snapshot"); return }
        #expect(s.top.count == 6)
        #expect(s.top[0].headline == "Steward 2")
        #expect(s.top[1].headline == "Quarterly VAT proof")
        #expect(s.top[1].waitsOn == ["ready", "brief"])
        #expect(s.top[2].why == nil && s.top[2].source == nil)
        #expect(s.calls.count == 3)
        #expect(s.writtenAt != nil)
        let p = NextUpPresentation.make(.snapshot(s), now: s.writtenAt!.addingTimeInterval(60))
        #expect(p.rows.count == 5)       // top five only
        #expect(p.notice == nil && p.staleLine == nil)
    }

    @Test func missingFile() {
        let dir = tmpDir()
        #expect(WorkQueue.load(dir: dir) == .missing)
        #expect(NextUpPresentation.make(.missing, now: Date()).notice == "Work queue not set up")
    }

    @Test func emptyList() {
        let l = WorkQueue.parse(Data(#"{"written_at":"2026-11-01T19:59:37Z","top":[],"calls":[]}"#.utf8))
        guard case .snapshot(let s) = l else { Issue.record("x"); return }
        let p = NextUpPresentation.make(l, now: s.writtenAt!)
        #expect(p.notice == "No ready work" && p.rows.isEmpty && p.staleLine == nil)
    }

    @Test func staleWrittenAt() {
        let l = WorkQueue.parse(Data(realShaped.utf8))
        guard case .snapshot(let s) = l, let w = s.writtenAt else { Issue.record("x"); return }
        let utc = TimeZone(identifier: "UTC")!
        let p = NextUpPresentation.make(l, now: w.addingTimeInterval(16 * 60), timeZone: utc)
        #expect(p.staleLine == "Stale since 19:59")
        #expect(p.rows.count == 5)
        #expect(NextUpPresentation.make(l, now: w.addingTimeInterval(14 * 60), timeZone: utc).staleLine == nil)
    }

    @Test func garbageIsUnreadable() {
        #expect(WorkQueue.parse(Data("nope".utf8)) == .unreadable)
    }

    @Test func sourceResolution() {
        let u = WorkQueue.sourceURL("ledger:docs/designs/a.md#Steps", home: "/h")
        #expect(u?.path == "/h/Projects/ledger-app/docs/designs/a.md")
        #expect(WorkQueue.sourceURL("true:x/y.md", home: "/h")?.path == "/h/Projects/true/x/y.md")
        #expect(WorkQueue.sourceURL("true-cloud:z.md", home: "/h")?.path == "/h/Projects/true-cloud/z.md")
        #expect(WorkQueue.sourceURL("other:z.md", home: "/h") == nil)
        #expect(WorkQueue.sourceURL("true:../etc/passwd", home: "/h") == nil)
        #expect(WorkQueue.sourceURL("nocolon", home: "/h") == nil)
    }

    @Test func workqHomeWins() {
        let c = URL(fileURLWithPath: "/c")
        #expect(WorkQueue.directory(claudeDir: c, env: ["WORKQ_HOME": "/w"]).path == "/w")
        #expect(WorkQueue.directory(claudeDir: c, env: [:]).path == "/c/workq")
    }

    @MainActor @Test func callAppearsThenDisappearsInNeedsYou() async throws {
        let claude = tmpDir(), wq = tmpDir()
        let store = HubStore(claudeDir: claude, workqDir: wq)
        await store.reload()
        #expect(NeedsYouQueue.callEntries(store.workQueue).isEmpty)
        try Data(realShaped.utf8).write(to: wq.appendingPathComponent("next.json"))
        await store.reload()
        #expect(NeedsYouQueue.callEntries(store.workQueue).map(\.id) == ["oss-d1", "call-oracle"])   // deduped by id
        let without = realShaped.replacingOccurrences(of: #"{"id":"call-oracle","title":"Oracle UAE","what":"spend","question":"Approve?"}"#, with: "")
            .replacingOccurrences(of: ",\n          {\"id\":\"oss-d1\",\"title\":\"dup\",\"what\":\"build-it\"},\n          ", with: "")
        try Data(without.utf8).write(to: wq.appendingPathComponent("next.json"))
        await store.reload()
        #expect(NeedsYouQueue.callEntries(store.workQueue).map(\.id) == ["oss-d1"])
        try Data(#"{"written_at":"2026-11-01T19:59:37Z","top":[],"calls":[]}"#.utf8).write(to: wq.appendingPathComponent("next.json"))
        await store.reload()
        #expect(NeedsYouQueue.callEntries(store.workQueue).isEmpty)
    }
}

/// Stills of the Next up section. Skipped unless TRUE_SNAPSHOT_DIR is set.
@MainActor
@Suite(.enabled(if: !(ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "").isEmpty, "TRUE_SNAPSHOT_DIR not set"))
struct NextUpStillsTests {
    private var dir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUE_SNAPSHOT_DIR"] ?? "/tmp") }

    private func snap(_ name: String, dark: Bool, _ load: WorkQueueLoad, now: Date) throws {
        let ink = HubInk(dark ? .dark : .light)
        let pres = NextUpPresentation.make(load, now: now)
        let size = NSSize(width: 600, height: 400)
        let root = NextUpSection(model: pres).padding(20)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environment(\.colorScheme, dark ? .dark : .light).background(ink.surface)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { Issue.record("no rep"); return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { Issue.record("no png"); return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    @Test func stills() throws {
        let normal = WorkQueue.parse(Data(realShaped.utf8))
        guard case .snapshot(let s) = normal, let w = s.writtenAt else { Issue.record("x"); return }
        var empty = s; empty.top = []
        for dark in [true, false] {
            try snap("1-normal", dark: dark, normal, now: w.addingTimeInterval(60))
            try snap("2-empty", dark: dark, .snapshot(empty), now: w.addingTimeInterval(60))
            try snap("3-missing", dark: dark, .missing, now: w)
            try snap("4-stale", dark: dark, normal, now: w.addingTimeInterval(40 * 60))
        }
    }
}
