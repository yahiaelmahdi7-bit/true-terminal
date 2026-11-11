import Foundation

/// All copy owned by the task/turn engine. Raw tool errors and status codes never become labels.
enum TaskDetailCopy {
    static let running = "Running", finished = "Finished", stopped = "Stopped when True quit"
    static let ready = "Ready to resume", resume = "Resume", runGate = "Run gate"
    static let answer = "Answer the question", permission = "Allow the request"
    static let failed = "Failed", failureReason = "The work couldn't finish", gateFailure = "The gate failed"
    static let providerFailure = "The provider couldn't finish the turn", processFailure = "The process stopped"
    static let review = "Review changes", openPane = "Open the pane", automatic = "Resumes automatically"
    static let noChanges = "No changes", notGit = "This folder isn't tracked by git", noBase = "Choose a base branch"
    static let notCommitted = "Not committed", noCheck = "No check set", notRun = "Not run", passed = "Passed"
    static let yes = "Yes", no = "No", expired = "Expired"
    static let anotherSeat = "Another seat was working here too", tooMany = "Too many changes to list", busy = "Busy, try again"
    static let needsQuestion = "Needs you: a question", needsPermission = "Needs you: permission"
    static let me = "Me", unassigned = "Unassigned", notChosen = "Not chosen"
    static let claude = "Claude", codex = "Codex", deepSeek = "DeepSeek", peer = "A peer"
    static let finishedLabel = "Finished", gateLabel = "Gate", mergedLabel = "Merged", reportLabel = "Report"
    static func waiting(_ time: String) -> String { "Waiting for the usage limit, resumes \(time)" }
    static func wait(_ time: String) -> String { "Wait until \(time)" }
    static func continueInPane(_ time: String) -> String { "Type continue in the pane after \(time)" }
    static func failures(_ count: Int) -> String { "\(count) failed" }
    static func flaky(_ count: Int) -> String { "Passed with \(count) flaky" }
    static func files(_ count: Int) -> String { "\(count) \(count == 1 ? "file" : "files")" }
}

enum TaskChecks: Equatable, Sendable {
    case notRun, noCheck, passed, failed(Int), flaky(Int)
    var label: String {
        switch self {
        case .notRun: TaskDetailCopy.notRun
        case .noCheck: TaskDetailCopy.noCheck
        case .passed: TaskDetailCopy.passed
        case .failed(let n): TaskDetailCopy.failures(n)
        case .flaky(let n): TaskDetailCopy.flaky(n)
        }
    }
    static func read(commit: String?, directory: URL = AgentPaths.standard.root.appendingPathComponent("gate")) -> TaskChecks {
        guard let commit, !commit.isEmpty, commit.allSatisfy({ $0.isHexDigit }),
              let data = try? Data(contentsOf: directory.appendingPathComponent(commit + ".json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["commit"] as? String == commit,
              object["passed"] != nil, object["failed"] != nil, object["flaky"] != nil else { return .notRun }
        func count(_ key: String) -> Int {
            if let a = object[key] as? [Any] { return a.count }
            return (object[key] as? Int) ?? 0
        }
        let failures = count("failed"), flaky = count("flaky")
        if failures > 0 { return .failed(failures) }
        // Build failures, crashes and timeouts can have no test names.
        if let reason = object["reason"] as? String, !reason.isEmpty, reason != "passed", reason != "ok", reason != "flaky" { return .failed(1) }
        if object["passed"] as? Bool == false { return .failed(1) }
        return flaky > 0 ? .flaky(flaky) : .passed
    }
}

enum TaskKind: Sendable { case builder, mission, seat }
enum TaskFailure: Sendable {
    case work, checks, provider, process
    var label: String {
        switch self {
        case .work: TaskDetailCopy.failureReason
        case .checks: TaskDetailCopy.gateFailure
        case .provider: TaskDetailCopy.providerFailure
        case .process: TaskDetailCopy.processFailure
        }
    }
}
enum TaskRunState: Equatable, Sendable {
    case running, needsQuestion, needsPermission, waiting(Date?), stopped, finished
    case failed(TaskFailure)
}
struct TaskStateLine: Equatable, Sendable {
    var text: String
    var nextAction: String
    var blocker: String?
    var resumeEnabled = false
    static func make(kind: TaskKind, state: TaskRunState, now: Date, time: (Date) -> String) -> Self {
        switch state {
        case .running: return Self(text: TaskDetailCopy.running, nextAction: TaskDetailCopy.openPane)
        case .needsQuestion: return Self(text: TaskDetailCopy.needsQuestion, nextAction: TaskDetailCopy.answer, blocker: TaskDetailCopy.needsQuestion)
        case .needsPermission: return Self(text: TaskDetailCopy.needsPermission, nextAction: TaskDetailCopy.permission, blocker: TaskDetailCopy.needsPermission)
        case .stopped: return Self(text: TaskDetailCopy.stopped, nextAction: TaskDetailCopy.openPane, blocker: TaskDetailCopy.stopped)
        case .failed(let reason): return Self(text: TaskDetailCopy.failed + ": " + reason.label, nextAction: TaskDetailCopy.review, blocker: reason.label)
        case .finished: return Self(text: TaskDetailCopy.finished, nextAction: TaskDetailCopy.runGate)
        case .waiting(let reset):
            if let reset, reset > now {
                let t = time(reset)
                let action = kind == .builder ? TaskDetailCopy.automatic : kind == .mission ? TaskDetailCopy.wait(t) : TaskDetailCopy.continueInPane(t)
                return Self(text: TaskDetailCopy.waiting(t), nextAction: action, blocker: TaskDetailCopy.waiting(t))
            }
            // Expired times cannot re-enter a wait or trigger a launch.
            if kind == .mission { return Self(text: TaskDetailCopy.ready, nextAction: TaskDetailCopy.resume, resumeEnabled: true) }
            return Self(text: kind == .builder ? TaskDetailCopy.running : TaskDetailCopy.stopped,
                        nextAction: kind == .builder ? TaskDetailCopy.automatic : TaskDetailCopy.openPane)
        }
    }
}

/// A screen can render these values directly, in declaration order; report is deliberately last.
struct TaskDetail: Sendable {
    var title: String
    var owner: String
    var provider: String
    var branch: String
    var state: TaskStateLine
    var finished: Bool
    var checks: TaskChecks
    var merged: Bool
    var changes: TaskChanges
    var report: String
    var reportInitiallyCollapsed: Bool { true }

    static func builder(_ record: BuilderRecord, owner: String, provider: String, report: String = "",
                        gateDirectory: URL = AgentPaths.standard.root.appendingPathComponent("gate"),
                        allowanceReset: Date? = nil, now: Date = Date()) -> Self {
        let changes = TaskChangesReader(folder: record.worktree ?? record.cwd).read()
        let state: TaskRunState
        switch record.state {
        case .done, .landed: state = .finished
        case .failed, .unlanded: state = .failed(.work)
        case .died, .killed: state = .failed(.process)
        case .held: state = .needsQuestion
        case .waiting, .paused: state = .waiting(record.resumeAt.map(Date.init(timeIntervalSince1970:)) ?? allowanceReset)
        default: state = .running
        }
        return Self(title: record.name, owner: owner, provider: provider, branch: record.branch ?? "",
                    state: .make(kind: .builder, state: state, now: now, time: clock),
                    finished: state == .finished, checks: .read(commit: changes.head, directory: gateDirectory),
                    merged: changes.merged, changes: changes, report: report)
    }

    static func mission(job: MissionJob, progress: MissionJobProgress, folder: String, base: String, branch: String,
                        checks: TaskChecks, checkCommand: String? = nil, owner: String? = nil, provider: String? = nil, report: String = "", now: Date = Date()) -> Self {
        let changes = TaskChangesReader(folder: folder).read(missionBase: base)
        let state: TaskRunState
        switch progress.state {
        case .completed, .merged: state = .finished
        case .failed, .declined, .canceled: state = .failed(progress.failedHead == nil ? .work : .checks)
        case .paused: state = .waiting(progress.resumeAt)
        case .needsYou where progress.mergeBlocked:
            if case .failed = checks { state = .failed(.checks) }
            else { state = .failed(.work) }
        case .needsYou: state = .needsQuestion
        default: state = .running
        }
        let resolvedOwner: String
        let resolvedProvider: String
        switch progress.destination {
        case .mine:
            resolvedOwner = TaskDetailCopy.me; resolvedProvider = TaskDetailCopy.claude
        case .peer(let name):
            resolvedOwner = name; resolvedProvider = TaskDetailCopy.peer
        default:
            resolvedOwner = job.whereTo == "auto" ? TaskDetailCopy.unassigned : job.whereTo == "mine" ? TaskDetailCopy.me : job.whereTo
            resolvedProvider = TaskDetailCopy.notChosen
        }
        return Self(title: job.title, owner: owner ?? resolvedOwner, provider: provider ?? resolvedProvider, branch: branch,
                    state: .make(kind: .mission, state: state, now: now, time: clock), finished: state == .finished,
                    checks: (job.check ?? checkCommand)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? checks : .noCheck, merged: changes.merged, changes: changes, report: report)
    }
    static func seat(_ agent: Agent, turn: AgentTurn, now: Date = Date(), reset: Date? = nil) -> Self {
        var changes = TaskChangesReader(folder: turn.folder).read()
        changes.commits = []; changes.files = []
        changes.notCommitted = changes.notCommitted.filter { turn.files.contains($0.path) }
        for path in turn.files where !changes.notCommitted.contains(where: { $0.path == path }) {
            // A dirty file restored to HEAD still belongs to the turn; its current HEAD diff is empty.
            changes.notCommitted.append(TaskChangedFile(path: path, added: 0, removed: 0, bytes: 0, binary: false))
        }
        changes.emptyMessage = changes.notCommitted.isEmpty ? (turn.message ?? TaskDetailCopy.noChanges) : nil
        return Self(title: agent.name, owner: agent.name, provider: TaskDetailCopy.claude,
                    branch: TaskGit(folder: turn.folder).value(["branch", "--show-current"]) ?? "",
                    state: .make(kind: .seat, state: reset.map { .waiting($0) } ?? turn.state, now: now, time: clock),
                    finished: turn.end == .stop, checks: .notRun, merged: false, changes: changes, report: "")
    }
    static func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }
}

/// Uses the installed AllowanceReader output rather than duplicating its stream/window policy.
enum TaskUsageLimit {
    static func reset(reading: Data, now: Date) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: reading) as? [String: Any],
              let windows = object["windows"] as? [String: Any] else { return nil }
        return windows.values.compactMap { value -> Date? in
            guard let w = value as? [String: Any], let reset = w["resets_at"] as? Double,
                  (w["status"] as? String == "rejected" || (w["util"] as? Double ?? 0) >= 1),
                  reset > now.timeIntervalSince1970 else { return nil }
            return Date(timeIntervalSince1970: reset)
        }.max()
    }
    static func read(paths: AgentPaths = .standard, now: Date = Date()) -> Date? {
        // The reader's read command is local and does not run a probe.
        let script = AllowanceReader.scriptPath(paths)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script, "read"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return process.terminationStatus == 0 ? reset(reading: data, now: now) : nil
    }
}
