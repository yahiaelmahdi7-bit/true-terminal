import Testing
import Foundation
import AppKit
@testable import True

/// Thread-safe sink for the injected trash function.
final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    func add(_ u: URL) { lock.lock(); _urls.append(u); lock.unlock() }
}

@Suite struct TrayStoreTests {
    let tmp: URL
    let log = TrashLog()
    let store: TrayStore

    init() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("traytest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let log = self.log
        let trashDir = tmp.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        store = TrayStore(root: tmp.appendingPathComponent("tray", isDirectory: true), trash: { url in
            let dest = trashDir.appendingPathComponent(url.lastPathComponent)
            guard (try? FileManager.default.moveItem(at: url, to: dest)) != nil else { return nil }
            log.add(dest)
            return dest
        })
    }

    /// A real PNG of the given size so ImageIO reports dimensions.
    @discardableResult
    func makeShot(_ dir: URL, name: String, w: Int = 40, h: Int = 20, age: TimeInterval = 0) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = dir.appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        let d = Date(timeIntervalSince1970: 1_800_000_000 - age)
        try FileManager.default.setAttributes([.modificationDate: d, .creationDate: d], ofItemAtPath: url.path)
        return url
    }

    var src: URL { tmp.appendingPathComponent("src", isDirectory: true) }

    @Test func ingestCopiesAndLeavesOriginalUntouched() throws {
        let o = try makeShot(src, name: "Screenshot a.png", w: 40, h: 20)
        let before = try Data(contentsOf: o)
        let e = try #require(store.ingest(o))
        #expect(e.kind == .original && e.parent == nil && e.source == o.path)
        #expect(e.width == 40 && e.height == 20)
        #expect(e.file == "shots/\(e.id).png")
        #expect(FileManager.default.fileExists(atPath: store.url(for: e).path))
        #expect(try Data(contentsOf: o) == before)
        #expect(FileManager.default.fileExists(atPath: o.path))
        #expect(store.load().shots.map(\.id) == [e.id])
    }

    @Test func idFormat() throws {
        let e = try #require(store.ingest(try makeShot(src, name: "Screenshot a.png")))
        #expect(e.id.range(of: #"^\d{8}-\d{6}-[0-9a-f]{4}$"#, options: .regularExpression) != nil)
    }

    @Test func dedupeBySourceSizeMtime() throws {
        let o = try makeShot(src, name: "Screenshot a.png")
        #expect(store.ingest(o) != nil)
        #expect(store.ingest(o) == nil)
        #expect(store.load().shots.count == 1)
        // Same path, different content/size → a new entry.
        try makeShot(src, name: "Screenshot a.png", w: 80, h: 80, age: 5)
        #expect(store.ingest(o) != nil)
        #expect(store.load().shots.count == 2)
    }

    @Test func pruneBeyond24GoesToTrashNotDelete() throws {
        for i in 0..<26 { try makeShot(src, name: "Screenshot \(i).png", age: TimeInterval(i * 10)) }
        for i in (0..<26).reversed() { store.ingest(src.appendingPathComponent("Screenshot \(i).png")) }
        let idx = store.load()
        #expect(idx.shots.count == 24)
        #expect(log.urls.count == 2)
        for u in log.urls { #expect(FileManager.default.fileExists(atPath: u.path)) }   // moved, still on disk
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: store.shotsDir.path)) ?? []).count == 24)
        #expect(idx.shots == idx.shots.sorted { $0.created > $1.created })
    }

    @Test func indexRoundTripAndContractShape() throws {
        let o = try makeShot(src, name: "Screenshot a.png")
        let e = try #require(store.ingest(o, created: Date(timeIntervalSinceNow: -3600)))
        _ = store.addMarkup(png: try Data(contentsOf: o), parent: e.id, width: 40, height: 20)
        let data = try Data(contentsOf: store.indexURL)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["version"] as? Int == 1)
        #expect(obj["updated"] is String)
        let shots = try #require(obj["shots"] as? [[String: Any]])
        #expect(shots.count == 2)
        #expect(Set(shots[0].keys) == ["id", "file", "created", "kind", "parent", "source", "width", "height"])
        #expect(shots[0]["kind"] as? String == "markup")
        #expect(shots[0]["parent"] as? String == e.id)
        #expect(shots[0]["source"] is NSNull)
        #expect(shots[1]["parent"] is NSNull)
        #expect(TrayStore(root: store.root).load() == store.load())   // round trip through a fresh instance
    }

    @Test func atomicWriteLeavesNoTempFiles() throws {
        for i in 0..<3 { store.ingest(try makeShot(src, name: "Screenshot \(i).png", age: TimeInterval(i))) }
        let names = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        #expect(names.sorted() == ["index.json", "shots"])
        #expect(try JSONDecoder().decode(TrayIndex.self, from: Data(contentsOf: store.indexURL)).shots.count == 3)
    }

    @Test func corruptIndexRebuildsFromShotsKeepingEveryFile() throws {
        for i in 0..<4 { store.ingest(try makeShot(src, name: "Screenshot \(i).png", age: TimeInterval(i * 10))) }
        let ids = Set(store.load().shots.map(\.id))
        try Data("{ not json".utf8).write(to: store.indexURL)
        let rebuilt = store.load()
        #expect(Set(rebuilt.shots.map(\.id)) == ids)
        #expect(rebuilt.shots == rebuilt.shots.sorted { $0.created > $1.created })
        #expect(rebuilt.shots.allSatisfy { $0.width == 40 })
        // And the repaired index is now valid on disk.
        #expect(try JSONDecoder().decode(TrayIndex.self, from: Data(contentsOf: store.indexURL)).shots.count == 4)
        // Missing index rebuilds too.
        try FileManager.default.removeItem(at: store.indexURL)
        #expect(Set(store.load().shots.map(\.id)) == ids)
    }

    @Test func outboxAppendFormat() throws {
        store.appendOutbox(id: "20261008-101010-abcd", path: "/x/shots/20261008-101010-abcd.png")
        store.appendOutbox(id: "b", path: "/x/b.png")
        let lines = try String(contentsOf: store.outboxURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let o = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        #expect(Set(o.keys) == ["ts", "id", "path", "action"])
        #expect(o["action"] == "send" && o["id"] == "20261008-101010-abcd")
        #expect(TrayStore.parseISO(o["ts"]!) != nil)
    }

    @Test func outboxTrimsOnlyPast1000() throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let lines = (0..<1000).map { "{\"ts\":\"t\",\"id\":\"\($0)\",\"path\":\"p\",\"action\":\"send\"}" }
        try (lines.joined(separator: "\n") + "\n").write(to: store.outboxURL, atomically: true, encoding: .utf8)
        // Exactly 1000 + this append = 1001 > 1000 → trim to the last 200.
        store.appendOutbox(id: "last", path: "p")
        let out = try String(contentsOf: store.outboxURL, encoding: .utf8).split(separator: "\n")
        #expect(out.count == 200)
        #expect(out.last!.contains("\"last\""))
        #expect(out.first!.contains("\"801\""))
    }

    @Test func outboxUntouchedAt1000() throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let lines = (0..<999).map { "{\"id\":\"\($0)\"}" }
        try (lines.joined(separator: "\n") + "\n").write(to: store.outboxURL, atomically: true, encoding: .utf8)
        store.appendOutbox(id: "last", path: "p")   // 1000 lines: not past 1000
        #expect(try String(contentsOf: store.outboxURL, encoding: .utf8).split(separator: "\n").count == 1000)
    }

    @Test func firstRunBackfillPicksNewest24AcrossTwoFolders() throws {
        #expect(store.isFirstRun())
        let a = tmp.appendingPathComponent("Pictures", isDirectory: true)
        let b = tmp.appendingPathComponent("Desktop", isDirectory: true)
        for i in 0..<20 { try makeShot(a, name: "Screenshot A\(i).png", age: TimeInterval(i * 100)) }          // 0,100,…1900
        for i in 0..<20 { try makeShot(b, name: "Screenshot B\(i).png", age: TimeInterval(i * 100 + 50)) }     // 50,150,…1950
        try makeShot(a, name: "holiday.png", age: 0)   // not a screenshot name: ignored
        let added = store.backfill(folders: [a, b])
        #expect(added.count == 24)
        let sources = Set(store.load().shots.compactMap { $0.source.map { ($0 as NSString).lastPathComponent } })
        #expect(sources.contains("Screenshot A0.png") && sources.contains("Screenshot B0.png"))
        #expect(!sources.contains("holiday.png"))
        // The 16 oldest of the 40 are left out: A19 (1900) and B19 (1950) are the oldest.
        #expect(!sources.contains("Screenshot B19.png") && !sources.contains("Screenshot A19.png"))
        #expect(!store.isFirstRun())
    }

    @Test func ingestNewerSkipsWhatIsAlreadyInTheIndex() throws {
        let a = tmp.appendingPathComponent("Pictures", isDirectory: true)
        try makeShot(a, name: "Screenshot 1.png", age: 100)
        store.backfill(folders: [a])
        try makeShot(a, name: "Screenshot 2.png", age: 0)
        let added = store.ingestNewer(in: a)
        #expect(added.map { ($0.source! as NSString).lastPathComponent } == ["Screenshot 2.png"])
        #expect(store.load().shots.count == 2)
    }

    @Test func removeTrashesAndRestoreBringsBack() throws {
        let e = try #require(store.ingest(try makeShot(src, name: "Screenshot a.png")))
        let r = try #require(store.remove(id: e.id))
        #expect(store.load().shots.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: e).path))
        #expect(log.urls.count == 1)
        #expect(store.restore(r))
        #expect(store.load().shots.map(\.id) == [e.id])
        #expect(FileManager.default.fileExists(atPath: store.url(for: e).path))
    }

    @Test func markupIsNewestFirstWithParent() throws {
        let o = try makeShot(src, name: "Screenshot a.png")
        let e = try #require(store.ingest(o, created: Date(timeIntervalSinceNow: -3600)))
        let m = try #require(store.addMarkup(png: try Data(contentsOf: o), parent: e.id, width: 40, height: 20))
        #expect(store.load().shots.map(\.id) == [m.id, e.id])
        #expect(m.kind == .markup && m.parent == e.id)
    }
}
