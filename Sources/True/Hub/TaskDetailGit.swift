import Foundation

/// Read-only git access. Output goes to files so a large diff cannot fill a pipe and deadlock.
/// Call from a utility task, never while rendering a view. Every invocation has a deadline.
struct TaskGit {
    let folder: String
    var deadline: Date = Date().addingTimeInterval(10)
    struct Output { var code: Int32; var data: Data; var text: String { String(decoding: data, as: UTF8.self) } }
    func run(_ args: [String], input: Data? = nil) -> Output {
        guard Date() < deadline else { return Output(code: -2, data: Data()) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let out = root.appendingPathComponent("out")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["--no-optional-locks", "-C", folder] + args
            var env = ProcessInfo.processInfo.environment
            env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = env
            process.standardOutput = handle; process.standardError = FileHandle.nullDevice
            var inputHandle: FileHandle?
            if let input {
                let inputURL = root.appendingPathComponent("in")
                try input.write(to: inputURL)
                inputHandle = try FileHandle(forReadingFrom: inputURL)
            }
            defer { try? inputHandle?.close() }
            process.standardInput = inputHandle ?? FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + 0.1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return Output(code: -2, data: Data())
            }
            process.waitUntilExit()
            return Output(code: process.terminationStatus, data: (try? Data(contentsOf: out)) ?? Data())
        } catch { return Output(code: -1, data: Data()) }
    }
    func value(_ args: [String]) -> String? {
        let r = run(args)
        return r.code == 0 ? r.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    func names(_ args: [String]) -> [String] {
        run(args).text.split(separator: "\0").map(String.init)
    }
}

struct TaskChangedFile: Equatable, Sendable, Identifiable {
    var path: String
    var oldPath: String?
    var added: Int?
    var removed: Int?
    var bytes: Int
    var binary: Bool
    var id: String { path }
    var canShowDiff: Bool { !binary && bytes <= 1_048_576 }
}

struct TaskChanges: Equatable, Sendable {
    var base: String?
    var mergeBase: String?
    var head: String?
    var commits: [String] = []
    var files: [TaskChangedFile] = []
    var notCommitted: [TaskChangedFile] = []
    var emptyMessage: String?
    var merged = false
    static let pageSize = 300
    func page(_ number: Int, uncommitted: Bool = false) -> [TaskChangedFile] {
        let list = uncommitted ? notCommitted : files
        guard number >= 0, number < (list.count + Self.pageSize - 1) / Self.pageSize else { return [] }
        return Array(list.dropFirst(number * Self.pageSize).prefix(Self.pageSize))
    }
}

struct TaskChangesReader {
    let folder: String
    func read(missionBase: String? = nil) -> TaskChanges {
        let git = TaskGit(folder: folder)
        guard let head = git.value(["rev-parse", "--verify", "HEAD"]) else {
            return TaskChanges(emptyMessage: TaskDetailCopy.notGit)
        }
        let candidates = [missionBase, git.value(["rev-parse", "--abbrev-ref", "@{upstream}"]),
                          git.value(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]), "main"]
        let base = candidates.compactMap { $0 }.first { git.value(["rev-parse", "--verify", "--end-of-options", $0 + "^{commit}"]) != nil }
        guard let base, let ancestor = git.value(["merge-base", base, head]) else {
            return TaskChanges(head: head, emptyMessage: TaskDetailCopy.noBase)
        }
        let committed = git.run(["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "-M", ancestor, head, "--"])
        let uncommitted = git.run(["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "-M", "HEAD", "--"])
        guard committed.code == 0, uncommitted.code == 0 else {
            return TaskChanges(base: base, mergeBase: ancestor, head: head, emptyMessage: TaskDetailCopy.busy)
        }
        let files = Self.numstat(committed.data, git: git, ref: head, oldRef: ancestor)
        var dirty = Self.numstat(uncommitted.data, git: git, ref: nil, oldRef: head)
        for path in git.names(["ls-files", "--others", "--exclude-standard", "-z"]) {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(path)
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            let size = Self.size(url)
            let binary = data?.prefix(8192).contains(0) ?? false
            let lines = size > 1_048_576 ? nil : data.map { $0.filter { $0 == 10 }.count + ($0.last != 10 && !$0.isEmpty ? 1 : 0) }
            dirty.append(TaskChangedFile(path: path, added: binary ? nil : lines, removed: binary || size > 1_048_576 ? nil : 0, bytes: size, binary: binary))
        }
        let ancestry = git.run(["merge-base", "--is-ancestor", head, base]).code == 0
        let cherry = git.value(["cherry", base, head])
        var merged = ancestry || (cherry != nil && !(cherry!.split(separator: "\n").contains { $0.hasPrefix("+") }))
        // Read the commit list first: the squash search below may use up the shared deadline.
        let commits = (git.value(["log", "--format=%s", ancestor + ".." + head, "--"]) ?? "").split(separator: "\n").map(String.init)
        // git cherry cannot recognise a many-commit squash. Compare the aggregate patch against
        // each first-parent patch in the base history as well (no writes to the object database).
        if !merged, !files.isEmpty {
            let patch = git.run(["diff", "--no-ext-diff", "--no-textconv", "--binary", ancestor, head, "--"])
            let patchID = patch.code == 0 ? git.run(["patch-id", "--stable"], input: patch.data).text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) : nil
            let history = git.value(["rev-list", "--first-parent", "--max-count=200", ancestor + ".." + base]) ?? ""
            for sha in history.split(separator: "\n") {
                let candidate = git.run(["diff", "--no-ext-diff", "--no-textconv", "--binary", String(sha) + "^", String(sha), "--"])
                let candidateID = candidate.code == 0 ? git.run(["patch-id", "--stable"], input: candidate.data).text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) : nil
                if let patchID, candidateID == patchID {
                    merged = true; break
                }
            }
        }
        return TaskChanges(base: base, mergeBase: ancestor, head: head, commits: commits, files: files,
                           notCommitted: dirty, emptyMessage: files.isEmpty && dirty.isEmpty ? TaskDetailCopy.noChanges : nil, merged: merged)
    }
    func diff(_ file: TaskChangedFile, changes: TaskChanges, uncommitted: Bool = false) -> String? {
        guard file.canShowDiff, let base = uncommitted ? "HEAD" : changes.mergeBase else { return nil }
        let refs = uncommitted ? [base] : [base, changes.head ?? "HEAD"]
        let git = TaskGit(folder: folder)
        if uncommitted, git.run(["ls-files", "--error-unmatch", "--", file.path]).code != 0 {
            let result = git.run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", URL(fileURLWithPath: folder).appendingPathComponent(file.path).path])
            return result.code == 1 ? result.text : nil
        }
        return git.value(["diff", "--no-ext-diff", "--no-textconv"] + refs + ["--", file.oldPath ?? file.path, file.path])
    }
    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    static func numstat(_ data: Data, git: TaskGit, ref: String?, oldRef: String? = nil) -> [TaskChangedFile] {
        func sizes(_ ref: String?) -> [String: Int] {
            guard let ref else { return [:] }
            var result: [String: Int] = [:]
            for record in git.run(["ls-tree", "-r", "-l", "-z", ref]).text.split(separator: "\0") {
                guard let tab = record.firstIndex(of: "\t"),
                      let size = record[..<tab].split(whereSeparator: { $0.isWhitespace }).last.flatMap({ Int($0) }) else { continue }
                result[String(record[record.index(after: tab)...])] = size
            }
            return result
        }
        let currentSizes = sizes(ref), previousSizes = sizes(oldRef)
        let chunks = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
        var result: [TaskChangedFile] = [], i = 0
        while i < chunks.count {
            let fields = chunks[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false); i += 1
            guard fields.count == 3 else { continue }
            var path = String(fields[2]), old: String?
            if path.isEmpty, i + 1 < chunks.count { old = String(chunks[i]); path = String(chunks[i + 1]); i += 2 }
            let bytes: Int
            if ref != nil { bytes = max(currentSizes[path] ?? 0, previousSizes[old ?? path] ?? 0) }
            else { bytes = max(size(URL(fileURLWithPath: git.folder).appendingPathComponent(path)), previousSizes[old ?? path] ?? 0) }
            result.append(TaskChangedFile(path: path, oldPath: old, added: bytes > 1_048_576 ? nil : Int(fields[0]), removed: bytes > 1_048_576 ? nil : Int(fields[1]), bytes: bytes, binary: fields[0] == "-"))
        }
        return result
    }
}
