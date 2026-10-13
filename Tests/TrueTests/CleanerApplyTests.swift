import Testing
import Foundation
@testable import True

/// Scans one file in a temp home and returns it plus the applier pointed at a temp backup root.
private func fixture(_ text: String = bigText) -> (file: ContextFile, applier: CleanerApplier, root: URL) {
    let home = cleanerTemp()
    let path = cleanerWrite(home.appendingPathComponent("p/CLAUDE.md"), text)
    try? FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
    let file = ContextScanner(home: home.path).scan(roots: [home.appendingPathComponent("p").path])[0]
    let root = home.appendingPathComponent("backups")
    return (file, CleanerApplier(backupRoot: root), root)
}

private func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "<missing>" }

@Suite struct CleanerApplyTests {
    @Test func applyBacksUpWritesAndRecordsManifest() throws {
        let (f, applier, root) = fixture()
        let res = applier.apply([ApplyRequest(file: f, newContent: "# Title\nshort\n")])
        #expect(res == [ApplyResult(path: f.path, error: nil)])
        #expect(read(f.path) == "# Title\nshort\n")
        let perms = try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o640)

        let dirs = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(dirs.count == 1)
        let dir = root.appendingPathComponent(dirs[0])
        #expect(read(dir.path + "/files" + f.path) == bigText)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as? [[String: String]]
        #expect(manifest?.count == 1)
        #expect(manifest?[0]["path"] == f.path)
        #expect(manifest?[0]["shaBefore"] == f.sha)
        #expect(manifest?[0]["shaAfter"] == sha256Hex(Data("# Title\nshort\n".utf8)))
    }

    @Test func refusesWhenChangedSinceRead() {
        let (f, applier, root) = fixture()
        try? (bigText + "edited by a session\n").write(toFile: f.path, atomically: true, encoding: .utf8)
        let res = applier.apply([ApplyRequest(file: f, newContent: "# Title\nx")])
        #expect(res[0].error == "changed since read — rescan")
        #expect(read(f.path).hasSuffix("edited by a session\n"))
        #expect(!FileManager.default.fileExists(atPath: root.path))   // no backup dir for a refused apply
    }

    @Test func refusesWhenOnlyMtimeChanged() {
        let (f, applier, _) = fixture()
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        #expect(applier.apply([ApplyRequest(file: f, newContent: "# T\nx")])[0].error == "changed since read — rescan")
    }

    @Test func undoRoundTrip() {
        let (f, applier, _) = fixture()
        _ = applier.apply([ApplyRequest(file: f, newContent: "# Title\nshort\n")])
        let report = applier.undoLast()
        #expect(report.restored == [f.path])
        #expect(report.skipped.isEmpty)
        #expect(read(f.path) == bigText)
        // Second undo: manifest was consumed, nothing left.
        #expect(applier.undoLast().note == "Nothing to undo")
    }

    @Test func undoSkipsFilesEditedAfterApply() {
        let (f, applier, _) = fixture()
        _ = applier.apply([ApplyRequest(file: f, newContent: "# Title\nshort\n")])
        try? "# Title\nshort\nmore edits\n".write(toFile: f.path, atomically: true, encoding: .utf8)
        let report = applier.undoLast()
        #expect(report.restored.isEmpty)
        #expect(report.skipped == [f.path])
        #expect(read(f.path) == "# Title\nshort\nmore edits\n")
    }

    @Test func twoAppliesInOneSecondKeepSeparateBackups() throws {
        let (f, applier, root) = fixture()
        var a = applier
        a.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        _ = a.apply([ApplyRequest(file: f, newContent: bigText + "one\n")])
        let f2 = ContextScanner(home: root.deletingLastPathComponent().path, now: { Date().addingTimeInterval(3600) })
            .scan(roots: [root.deletingLastPathComponent().appendingPathComponent("p").path])[0]
        _ = a.apply([ApplyRequest(file: f2, newContent: "# Title\ntwo\n")])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }
}
