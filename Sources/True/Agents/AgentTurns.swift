import Foundation
import Darwin

struct AgentTurnSnapshot: Codable, Equatable, Sendable {
    var head: String = ""
    var hashes: [String: String] = [:]
    var message: String?
    static func capture(folder: String, seconds: TimeInterval = 2, maxFiles: Int = 2_000) -> Self {
        let git = TaskGit(folder: folder, deadline: Date().addingTimeInterval(seconds))
        guard let head = git.value(["rev-parse", "--verify", "HEAD"]) else {
            return Self(message: Date() >= git.deadline ? TaskDetailCopy.tooMany : TaskDetailCopy.notGit)
        }
        let lockPath = git.value(["rev-parse", "--git-path", "index.lock"]) ?? ".git/index.lock"
        let lock = lockPath.hasPrefix("/") ? URL(fileURLWithPath: lockPath) : URL(fileURLWithPath: folder).appendingPathComponent(lockPath)
        // Retry the lock observation once. No git operation writes or refreshes the index.
        if FileManager.default.fileExists(atPath: lock.path) {
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + min(0.025, max(0, git.deadline.timeIntervalSinceNow)))
            if FileManager.default.fileExists(atPath: lock.path) { return Self(head: head, message: TaskDetailCopy.busy) }
        }
        let status = git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        guard status.code == 0 else { return Self(head: head, message: TaskDetailCopy.tooMany) }
        let entries = status.text.split(separator: "\0")
        var names = Set<String>(), index = 0
        while index < entries.count {
            let entry = entries[index]; index += 1
            guard entry.count >= 3 else { continue }
            let code = entry.prefix(2)
            names.insert(String(entry.dropFirst(3)))
            // Porcelain -z puts the destination first, then the old name for a rename/copy.
            if code.contains("R") || code.contains("C") { index += 1 }
        }
        let paths = names.sorted()
        guard paths.count <= maxFiles else { return Self(head: head, message: TaskDetailCopy.tooMany) }
        var hashes: [String: String] = [:], existing: [String] = []
        for path in paths {
            let full = URL(fileURLWithPath: folder).appendingPathComponent(path).path
            if FileManager.default.fileExists(atPath: full) { existing.append(path) }
            else { hashes[path] = "deleted" }
        }
        // Batch arguments keep a normal turn below a second; chunking avoids ARG_MAX.
        for start in stride(from: 0, to: existing.count, by: 100) {
            let batch = Array(existing.dropFirst(start).prefix(100))
            let result = git.run(["hash-object", "--no-filters", "--"] + batch)
            let values = result.text.split(separator: "\n").map(String.init)
            guard result.code == 0, values.count == batch.count else { return Self(head: head, message: TaskDetailCopy.tooMany) }
            for (path, hash) in zip(batch, values) { hashes[path] = hash }
        }
        return Self(head: head, hashes: hashes)
    }
}

struct AgentTurn: Codable, Equatable, Sendable, Identifiable {
    enum End: String, Codable, Sendable { case stop, failure, session, recovered }
    var id = UUID()
    var seat: String
    var folder: String
    var pid: Int32
    var started: Date
    var before: AgentTurnSnapshot
    var ended: Date?
    var end: End?
    var files: [String] = []
    var sharedFolder = false
    var questionPending: Bool?
    var questionExpired: Bool { questionPending == true && (end == .recovered || end == .session) }
    var questionLabel: String? { questionExpired ? TaskDetailCopy.expired : nil }
    var message: String?
    var isOpen: Bool { ended == nil }
    var summary: String { message ?? TaskDetailCopy.files(files.count) }
    var overlapMessage: String? { sharedFolder ? TaskDetailCopy.anotherSeat : nil }
    var state: TaskRunState { isOpen ? .running : end == .recovered ? .stopped : end == .failure ? .failed(.provider) : .finished }
}

/// Serialized by its owner. Atomic replacement means a quit during close leaves either the open
/// record (recoverable) or the complete closed record. It never changes anything in the repo.
final class AgentTurnStore: @unchecked Sendable {
    let directory: URL
    private let snapshot: (String) -> AgentTurnSnapshot
    private let write: (Data, URL) throws -> Void
    init(directory: URL = AgentPaths.standard.root.appendingPathComponent("turns"),
         snapshot: @escaping (String) -> AgentTurnSnapshot = { AgentTurnSnapshot.capture(folder: $0) },
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.directory = directory; self.snapshot = snapshot; self.write = write
    }
    private func url(_ seat: String) -> URL {
        let safe = seat.utf8.map { String(format: "%02x", $0) }.joined()
        // Normal seat slugs preserve the specified <seat>.jsonl layout.
        let name = !seat.isEmpty && seat.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } ? seat : safe
        return directory.appendingPathComponent(name + ".jsonl")
    }
    func records(_ seat: String) -> [AgentTurn] {
        guard let data = try? Data(contentsOf: url(seat)) else { return [] }
        return data.split(separator: 10).compactMap { try? JSONDecoder().decode(AgentTurn.self, from: Data($0)) }
    }
    private func save(_ records: [AgentTurn], seat: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = Data()
        for record in records.suffix(50) { bytes.append(try JSONEncoder().encode(record)); bytes.append(10) }
        try write(bytes, url(seat))
    }
    func allRecords() -> [AgentTurn] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.flatMap { file -> [AgentTurn] in
                guard let data = try? Data(contentsOf: file) else { return [] }
                return data.split(separator: 10).compactMap { try? JSONDecoder().decode(AgentTurn.self, from: Data($0)) }
            }
    }
    @discardableResult
    func open(seat: String, folder: String, pid: Int32, at: Date = Date()) throws -> AgentTurn {
        var records = records(seat)
        if let open = records.last, open.isOpen { return open }
        let canonical = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        var record = AgentTurn(seat: seat, folder: canonical, pid: pid, started: at, before: snapshot(canonical))
        for other in allRecords() where other.isOpen && other.folder == canonical && other.seat != seat {
            record.sharedFolder = true
            var theirs = self.records(other.seat)
            if let index = theirs.firstIndex(where: { $0.id == other.id }) {
                theirs[index].sharedFolder = true; try save(theirs, seat: other.seat)
            }
        }
        records.append(record); try save(records, seat: seat)
        return record
    }
    func markQuestion(seat: String, pending: Bool = true) throws {
        var records = records(seat)
        guard let index = records.indices.last, records[index].isOpen else { return }
        records[index].questionPending = pending
        try save(records, seat: seat)
    }
    @discardableResult
    func close(seat: String, end: AgentTurn.End, at: Date = Date()) throws -> AgentTurn? {
        var records = records(seat)
        guard let index = records.indices.last, records[index].isOpen else { return records.last }
        var record = records[index]
        let after = snapshot(record.folder)
        record.ended = at; record.end = end; record.message = after.message ?? record.before.message
        if record.message == nil {
            let paths = Set(record.before.hashes.keys).union(after.hashes.keys)
            record.files = paths.filter { record.before.hashes[$0] != after.hashes[$0] }.sorted()
            if after.head != record.before.head {
                // HEAD movement is not evidence of this turn's edits. Keep only working changes
                // at the end; pulled/merged clean files are absent from this snapshot.
                record.files = record.files.filter { after.hashes[$0] != nil }
            }
        }
        records[index] = record; try save(records, seat: seat)
        return record
    }
    /// T3's rule: at most `limit` automatic continues per seat in `window`, so a True that crashes right
    /// after continuing cannot loop. Each restart-closed turn counts as one. A small file read, no git.
    func autoContinueAllowed(seat: String, now: Date = Date(), limit: Int = 3, window: TimeInterval = 300) -> Bool {
        records(seat).filter { $0.end == .recovered && ($0.ended ?? .distantPast) > now.addingTimeInterval(-window) }.count < limit
    }
    func recover(alive: (Int32) -> Bool = { $0 > 0 && (kill($0, 0) == 0 || errno == EPERM) }, at: Date = Date()) throws -> [AgentTurn] {
        for record in allRecords() where record.isOpen && !alive(record.pid) {
            try close(seat: record.seat, end: .recovered, at: at)
        }
        return allRecords().filter { $0.isOpen || $0.end == .recovered }
    }
}
