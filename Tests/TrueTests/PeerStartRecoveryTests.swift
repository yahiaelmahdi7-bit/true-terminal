import Testing
import Foundation
@testable import True

/// A job from a paired Mac must never be stranded as "Starting", and its prompt must never be typed twice.
@Suite(.serialized) struct PeerStartRecoveryTests {
    final class Snap: @unchecked Sendable { var root: URL?; var seenAtArrival: Data?; var inboundAtArrival: Data? }

    func rig() -> PeerEngineTests.Rig { PeerEngineTests().rig() }

    /// Copy of the receiver's folder taken the moment the job has been saved (the "crash right here" state).
    func hookSnapshot(_ r: PeerEngineTests.Rig) -> Snap {
        let snap = Snap(), root = r.b.root
        r.b.engine.onJobArrived = { _ in
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("true-peers-snap-\(UUID().uuidString)")
            try? FileManager.default.copyItem(at: root, to: dst)
            snap.root = dst
            snap.seenAtArrival = try? Data(contentsOf: root.appendingPathComponent("seen.json"))
            snap.inboundAtArrival = try? Data(contentsOf: root.appendingPathComponent("inbound.json"))
        }
        return snap
    }

    func restart(_ r: PeerEngineTests.Rig, from root: URL, launcher: FakeLauncher, desk: Bool = false) -> PeerEngine {
        let clock = r.clock
        let e = PeerEngine(root: root, identity: r.b.identity, launcher: launcher, transport: r.relay.transport(for: r.b.identity.mailboxId),
                           inboundMode: { .bypass }, ownName: "Bo", desk: { desk }, lanes: { 1 }, now: { clock.now() }, scheduler: { _, _ in })
        e.drain()
        return e
    }

    func start(_ r: PeerEngineTests.Rig, _ snap: Snap) throws -> (id: String, snapRoot: URL) {
        let id = try #require(PeerEngineTests().delegate(r))
        return (id, try #require(snap.root))
    }

    @Test func jobIsSavedBeforeItIsMarkedSeen() throws {
        let r = rig(); defer { r.close() }
        let snap = hookSnapshot(r)
        let (blob, id) = craftedJob(from: r.a.identity, to: r.b)
        r.b.engine.receive(blob); settle(r.a, r.b)
        let inboundThen = try String(decoding: #require(snap.inboundAtArrival), as: UTF8.self)
        #expect(inboundThen.contains(id))                                        // saved when handleJob reached the callback...
        let seenThen = snap.seenAtArrival.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let seenBefore = seenThen.count                                          // (pairing envelopes only)
        let seenNow = try JSONSerialization.jsonObject(with: Data(contentsOf: r.b.root.appendingPathComponent("seen.json"))) as? [String: Any]
        #expect(seenNow?.count == seenBefore + 1)                                // the job's envelope is marked once handleJob returned
    }

    @Test func redeliveryAfterACrashBeforeTheSaveIsAcceptedAndRuns() {
        let r = rig(); defer { r.close() }
        let (blob, id) = craftedJob(from: r.a.identity, to: r.b)
        // Crash before inbound was saved: with the fix nothing was marked seen either, so the folder holds pairing only.
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("true-peers-snap-\(UUID().uuidString)")
        try? FileManager.default.copyItem(at: r.b.root, to: dst)
        defer { try? FileManager.default.removeItem(at: dst) }
        let l2 = FakeLauncher()
        let e2 = restart(r, from: dst, launcher: l2)
        e2.receive(blob); e2.drain()
        #expect(e2.inboundJobs().map(\.id) == [id])
        #expect(l2.panes.count == 1)
    }

    @Test func paneLessJobWithNoMarkerRunsOnceAfterRestart() throws {
        let r = rig(); defer { r.close() }
        let snap = hookSnapshot(r)
        let (id, root) = try start(r, snap); defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("starting.json"))   // also: a folder from before this change
        let saved = try String(contentsOf: root.appendingPathComponent("inbound.json"), encoding: .utf8)
        let rec = try #require((try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [[String: Any]])?.first)
        #expect(saved.contains(id) && rec["pane"] == nil)
        let l2 = FakeLauncher()
        let e2 = restart(r, from: root, launcher: l2)
        #expect(l2.panes.count == 1 && l2.paneLines.isEmpty)
        let j = try #require(e2.inboundJobs().first)
        #expect(j.pane != nil && j.status == .accepted)
        // a second restart finds it running: nothing is typed again
        let l3 = FakeLauncher()
        _ = restart(r, from: root, launcher: l3)
        #expect(l3.panes.isEmpty && l3.paneLines.isEmpty)
        settle(r.a, r.b)
    }

    @Test func paneLessJobWithMarkerIsNotRerunAndTheSenderIsTold() throws {
        let r = rig(); defer { r.close() }
        let snap = hookSnapshot(r)
        let (id, root) = try start(r, snap); defer { try? FileManager.default.removeItem(at: root) }
        try Data("[\"\(id)\"]".utf8).write(to: root.appendingPathComponent("starting.json"))
        let l2 = FakeLauncher()
        let e2 = restart(r, from: root, launcher: l2)
        #expect(l2.panes.isEmpty && l2.paneLines.isEmpty && l2.builders.isEmpty)
        let j = try #require(e2.inboundJobs().first)
        #expect(j.status == .failed && j.note == "Interrupted while starting. Send it again.")
        settle(r.a, r.b)
        let s = try #require(r.a.engine.status(jobId: id).first)
        #expect(s.status == .failed)
        let l3 = FakeLauncher()                                                 // and it stays failed on the next restart
        _ = restart(r, from: root, launcher: l3)
        #expect(l3.panes.isEmpty)
    }

    @Test func aNormalJobTypesItsPromptOnceAndClearsTheMarker() throws {
        let r = rig(); defer { r.close() }
        let id = try #require(PeerEngineTests().delegate(r))
        #expect(r.b.launcher.panes.count == 1 && r.b.launcher.paneLines.isEmpty && r.b.launcher.delivered.isEmpty)
        let j = try #require(r.b.engine.inboundJobs().first { $0.id == id })
        #expect(j.pane != nil)
        let marks = try JSONSerialization.jsonObject(with: Data(contentsOf: r.b.root.appendingPathComponent("starting.json"))) as? [String]
        #expect(marks == [])
    }

    @Test func aDeskJobTypesItsPromptOnce() throws {
        let r = rig(); defer { r.close() }
        r.b.knobs.desk = true; r.b.knobs.lanes = 1
        let id = try #require(PeerEngineTests().delegate(r))
        #expect(r.b.launcher.panes.count == 1 && r.b.launcher.delivered.isEmpty)
        #expect(r.b.engine.inboundJobs().first { $0.id == id }?.pane != nil)
        _ = try #require(PeerEngineTests().delegate(r))                       // in line behind the first: still nothing typed twice
        #expect(r.b.launcher.panes.count == 1 && r.b.launcher.delivered.isEmpty)
    }

    /// Copy of the receiver's folder as it stands now (the app quits here).
    func snapshot(_ r: PeerEngineTests.Rig) -> URL {
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("true-peers-snap-\(UUID().uuidString)")
        try? FileManager.default.copyItem(at: r.b.root, to: dst)
        return dst
    }

    @Test func aJobInLineStaysInLineWhileTheJobAheadIsStillOn() throws {
        let r = rig(); defer { r.close() }
        r.b.knobs.desk = true; r.b.knobs.lanes = 1
        let first = try #require(PeerEngineTests().delegate(r))
        let second = try #require(PeerEngineTests().delegate(r))
        #expect(r.b.engine.inboundJobs().first { $0.id == second }?.pane == nil)   // held in line
        let root = snapshot(r); defer { try? FileManager.default.removeItem(at: root) }
        let l2 = FakeLauncher()                                                   // after a restart the old tab is gone
        l2.deadPanes = Set(r.b.engine.inboundJobs().compactMap { $0.id == first ? $0.pane : nil })
        let e2 = restart(r, from: root, launcher: l2, desk: true)
        let j = try #require(e2.inboundJobs().first { $0.id == second })
        #expect(j.pane == nil && j.status == .accepted)                           // not started over the job ahead
        settle(r.a, r.b)
    }

    @Test func aJobInLineWhoseJobAheadAlreadyEndedRunsAfterRestart() throws {
        let r = rig(); defer { r.close() }
        r.b.knobs.desk = true; r.b.knobs.lanes = 1
        let first = try #require(PeerEngineTests().delegate(r))
        let second = try #require(PeerEngineTests().delegate(r))
        // The first job ended but the app quit before the next in line was started.
        r.b.engine.mutateForTest(first) { $0.status = .done; $0.finished = r.clock.now() }
        let root = snapshot(r); defer { try? FileManager.default.removeItem(at: root) }
        let l2 = FakeLauncher()
        l2.deadPanes = Set(r.b.engine.inboundJobs().compactMap { $0.id == first ? $0.pane : nil })
        let e2 = restart(r, from: root, launcher: l2, desk: true)
        #expect(e2.inboundJobs().first { $0.id == second }?.pane != nil)          // never stranded in line
        #expect(l2.panes.count == 1)
        settle(r.a, r.b)
    }

    @Test func redeliveryOfASavedJobIsIgnored() throws {
        let r = rig(); defer { r.close() }
        let (blob, id) = craftedJob(from: r.a.identity, to: r.b)
        r.b.engine.receive(blob); settle(r.a, r.b)
        let again = craftedJob(from: r.a.identity, to: r.b, id: id)             // same job, fresh envelope (the relay resent it)
        r.b.engine.receive(again.blob); settle(r.a, r.b)
        #expect(r.b.engine.inboundJobs().count == 1 && r.b.launcher.panes.count == 1)
    }

    @Test func oldFolderWithoutAStartingFileLoads() throws {
        let r = rig(); defer { r.close() }
        let snap = hookSnapshot(r)
        let (_, root) = try start(r, snap); defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("starting.json"))
        let e2 = restart(r, from: root, launcher: FakeLauncher())
        #expect(e2.inboundJobs().count == 1)
    }
}
