import Testing
import Foundation
@testable import True

@Suite struct DownloadsListTests {
    private func item(_ name: String, _ t: TimeInterval, dir: Bool = false) -> DownloadItem {
        DownloadItem(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"), isDirectory: dir, size: 1,
                     modified: Date(timeIntervalSince1970: t))
    }

    @Test func newestFirstThenName() {
        let r = DownloadsList.recent([item("b", 10), item("a", 10), item("c", 20)])
        #expect(r.map(\.name) == ["c", "a", "b"])
    }

    @Test func limitIsEight() {
        let r = DownloadsList.recent((0..<12).map { item("f\($0)", Double($0)) })
        #expect(r.count == 8)
        #expect(r.first?.name == "f11")
    }

    @Test func dotfilesAndPartialsSkipped() {
        let names = [".DS_Store", "a.crdownload", "b.DOWNLOAD", "c.Part", "d.partial", "e.TMP", "keep.pdf", "tmp"]
        let r = DownloadsList.recent(names.enumerated().map { item($1, Double($0)) })
        #expect(Set(r.map(\.name)) == ["keep.pdf", "tmp"])
    }

    @Test func foldersKept() {
        let r = DownloadsList.recent([item("Stuff", 5, dir: true)])
        #expect(r.count == 1 && r[0].isDirectory)
    }

    @Test func emptyAndMissingDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        #expect(DownloadsList.list(directory: tmp) == nil)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(DownloadsList.list(directory: tmp) == [])
    }

    @Test func listReadsRealDirectoryWithMtimes() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp.appendingPathComponent("folder"), withIntermediateDirectories: false)
        for (n, t) in [("old.txt", 100.0), ("new.txt", 300.0), (".hidden", 400.0), ("x.crdownload", 500.0)] {
            let u = tmp.appendingPathComponent(n)
            try Data("hi".utf8).write(to: u)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: u.path)
        }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)],
                             ofItemAtPath: tmp.appendingPathComponent("folder").path)
        let r = try #require(DownloadsList.list(directory: tmp))
        #expect(r.map(\.name) == ["new.txt", "folder", "old.txt"])
        #expect(r[1].isDirectory)
    }
}
