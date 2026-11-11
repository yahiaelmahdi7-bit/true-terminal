import Foundation
import Testing
@testable import True

private func sh(_ dir: URL, _ args: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
    p.currentDirectoryURL = dir; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}
private func repo() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("panegit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    sh(dir, ["init", "-q", "-b", "main"]); sh(dir, ["config", "user.name", "T"]); sh(dir, ["config", "user.email", "t@t"])
    try "a\nb\nc\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    sh(dir, ["add", "-A"]); sh(dir, ["commit", "-q", "-m", "first"])
    return dir
}
private func count(_ dir: URL) -> Int {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["rev-list", "--count", "HEAD"]
    p.currentDirectoryURL = dir; let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    return Int(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
}

@Suite struct PaneGitTests {
    @Test func cleanRepo() throws {
        let s = PaneGitReader.read(folder: try repo().path)
        #expect(s.isRepo && s.branch == "main" && s.added == 0 && s.removed == 0 && s.files == 0)
    }
    @Test func addedAndRemoved() throws {
        let d = try repo()
        try "a\nx\ny\nz\n".write(to: d.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let s = PaneGitReader.read(folder: d.path)
        #expect(s.added == 3 && s.removed == 2 && s.files == 1)
    }
    @Test func untrackedCountsLines() throws {
        let d = try repo()
        try "1\n2\n3\n4\n".write(to: d.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let s = PaneGitReader.read(folder: d.path)
        #expect(s.added == 4 && s.removed == 0 && s.files == 1)
    }
    @Test func binaryUntrackedIsZeroLines() throws {
        let d = try repo()
        try Data([0, 1, 2, 0, 0, 255]).write(to: d.appendingPathComponent("b.bin"))
        let s = PaneGitReader.read(folder: d.path)
        #expect(s.added == 0 && s.files == 1)
    }
    @Test func notARepo() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("plain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        #expect(PaneGitReader.read(folder: d.path) == .notGit)
        #expect(!PaneGitReader.read(folder: d.path).isRepo)
    }

    @Test func commitCommitsAndNeverPushes() throws {
        let d = try repo()
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        sh(remote, ["init", "-q", "--bare", "-b", "main"])
        sh(d, ["remote", "add", "origin", remote.path])
        try "q\n".write(to: d.appendingPathComponent("g.txt"), atomically: true, encoding: .utf8)
        let line = PaneCommit.commit(folder: d.path, message: "add g")
        #expect(line == TaskDetailCopy.committed(1))
        #expect(count(d) == 2)
        #expect(PaneGitReader.read(folder: d.path).files == 0)
        #expect(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("refs/heads/main").path))
    }
    @Test func nothingToCommitAndEmptyMessage() throws {
        let d = try repo()
        #expect(PaneCommit.commit(folder: d.path, message: "x") == TaskDetailCopy.nothingToCommit)
        #expect(PaneCommit.commit(folder: d.path, message: "  ") == TaskDetailCopy.writeMessage)
        #expect(count(d) == 1)
    }

    @Test func noEditorsInstalled() {
        let list = PaneEditor.installed(find: { _ in nil })
        #expect(list.isEmpty)
        #expect(PaneEditor.preferred(in: list, last: "dev.zed.Zed") == nil)
    }
    @Test func lastPickWins() {
        let u = URL(fileURLWithPath: "/Applications/X.app")
        let list = [PaneEditor(id: "a", name: "A", url: u), PaneEditor(id: "b", name: "B", url: u)]
        #expect(PaneEditor.preferred(in: list, last: "b")?.id == "b")
        #expect(PaneEditor.preferred(in: list, last: nil)?.id == "a")
    }
}

@Suite struct DiffContrastTests {
    @Test func diffColoursPassOnEveryTrueBackground() {
        for (name, p, d) in [("dark", Theme.Palette.dark, Theme.DiffPalette.dark), ("light", Theme.Palette.light, Theme.DiffPalette.light)] {
            for fill in p.backgrounds {
                for (t, hex) in [("add", d.add), ("remove", d.remove)] {
                    #expect(Contrast.ratio(hex, fill) >= 4.5, "\(name) \(t) on \(String(fill, radix: 16))")
                }
            }
        }
    }
}

@Suite struct TaskScreenDataTests {
    @Test func turnBadgeAndMessages() {
        var t = AgentTurn(seat: "s", folder: "/x", pid: 1, started: Date(), before: AgentTurnSnapshot())
        t.files = ["a", "b", "c"]; t.ended = Date(); t.sharedFolder = true
        #expect(t.summary == "3 files")
        #expect(t.overlapMessage == TaskDetailCopy.anotherSeat)
        t.questionPending = true; t.end = .session
        #expect(t.questionLabel == TaskDetailCopy.expired)
    }
    @Test func checkStatesHaveDistinctLabels() {
        let labels = [TaskChecks.notRun, .noCheck, .passed, .failed(2), .flaky(1)].map(\.label)
        #expect(Set(labels).count == 5)
    }
    @Test func pagesOf300() {
        let f = (0..<650).map { TaskChangedFile(path: "f\($0)", added: 1, removed: 0, bytes: 1, binary: false) }
        let c = TaskChanges(files: f)
        #expect(c.page(0).count == 300 && c.page(2).count == 50 && c.page(3).isEmpty)
    }
}
