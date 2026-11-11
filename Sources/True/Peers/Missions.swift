import Foundation
import Darwin

struct MissionValidationError: Error, CustomStringConvertible {
    var line: Int
    var reason: String
    var description: String { "Line \(line): \(reason)" }
}

struct MissionJob: Equatable {
    var title: String
    var line: Int
    var repo = ""
    var whereTo = "auto"
    var needs: [String] = []
    var tool: String?
    var review: String?
    var check: String?
    var brief = ""
    var fieldLines: [String: Int] = [:]
    /// A step a person does: `tool: human` + `where: <person or role>`. It has no repo and no worker.
    var isHuman: Bool { tool == "human" }
}

struct MissionFile {
    var name: String
    var into: String?
    var check: String?
    /// The Steward workspace (id or key) human steps are filed in, e.g. the firm.
    var workspace: String?
    var jobs: [MissionJob]

    /// Field lines are metadata only outside fenced Markdown code blocks. All other text is the brief.
    static func parse(_ markdown: String, peers: [String]) throws -> MissionFile {
        var mission = MissionFile(name: "", jobs: [])
        var fenced = false
        func fail(_ line: Int, _ why: String) throws -> Never { throw MissionValidationError(line: line, reason: why) }
        for (offset, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = offset + 1, text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") || text.hasPrefix("~~~") { fenced.toggle() }
            if !fenced && text.hasPrefix("# Mission: ") {
                guard mission.name.isEmpty, mission.jobs.isEmpty else { try fail(line, "Use one mission heading") }
                mission.name = String(text.dropFirst(11)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if !fenced && text.hasPrefix("## ") {
                guard !mission.name.isEmpty else { try fail(line, "Add a mission heading first") }
                mission.jobs.append(MissionJob(title: String(text.dropFirst(3)), line: line))
                continue
            }
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map(String.init) ?? ""
            let value = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if !fenced && parts.count == 2 {
                if mission.jobs.isEmpty {
                    if key == "into" { mission.into = value; continue }
                    if key == "check" { mission.check = value; continue }
                    if key == "workspace" { mission.workspace = value; continue }
                } else if ["repo", "where", "needs", "tool", "review", "check"].contains(key) {
                    let i = mission.jobs.count - 1
                    guard mission.jobs[i].fieldLines[key] == nil else { try fail(line, "Use one \(key) field") }
                    mission.jobs[i].fieldLines[key] = line
                    switch key {
                    case "repo": mission.jobs[i].repo = value
                    case "where": mission.jobs[i].whereTo = value
                    case "needs": mission.jobs[i].needs = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    case "tool": mission.jobs[i].tool = value.isEmpty ? nil : value
                    case "review": mission.jobs[i].review = value
                    default: mission.jobs[i].check = value
                    }
                    continue
                }
            }
            if !mission.jobs.isEmpty { mission.jobs[mission.jobs.count - 1].brief += raw + "\n" }
        }
        guard !mission.name.isEmpty else { try fail(1, "Add a mission heading") }
        guard !mission.jobs.isEmpty else { try fail(1, "Add a job") }
        var titles = Set<String>()
        for job in mission.jobs {
            guard !job.title.isEmpty, titles.insert(job.title).inserted else { try fail(job.line, "Job titles must be unique") }
            if job.isHuman {
                guard job.whereTo != "auto", !job.whereTo.isEmpty else { try fail(job.fieldLines["where"] ?? job.line, "Say who does this step") }
                guard mission.workspace?.isEmpty == false else { try fail(job.line, "Add a workspace for the people's steps") }
                continue
            }
            guard !job.repo.isEmpty else { try fail(job.fieldLines["repo"] ?? job.line, "Add the repo") }
            guard ["auto", "mine"].contains(job.whereTo) || peers.contains(job.whereTo) else {
                try fail(job.fieldLines["where"] ?? job.line, "Choose auto, mine or a paired peer")
            }
        }
        // The published LEDGER file uses the unique heading prefix before ':' in needs fields.
        for i in mission.jobs.indices {
            mission.jobs[i].needs = try mission.jobs[i].needs.map { need in
                if titles.contains(need) { return need }
                let matches = mission.jobs.filter { $0.title.components(separatedBy: ":").first == need }
                guard matches.count == 1 else { try fail(mission.jobs[i].fieldLines["needs"] ?? mission.jobs[i].line, "Unknown or ambiguous dependency \(need)") }
                return matches[0].title
            }
        }
        var visiting = Set<String>(), visited = Set<String>()
        func visit(_ job: MissionJob) throws {
            if visited.contains(job.title) { return }
            visiting.insert(job.title)
            for title in job.needs {
                if visiting.contains(title) { try fail(job.fieldLines["needs"] ?? job.line, "Dependencies form a cycle") }
                try visit(mission.jobs.first { $0.title == title }!)
            }
            visiting.remove(job.title); visited.insert(job.title)
        }
        for job in mission.jobs { try visit(job) }
        return mission
    }
}

enum MissionDestination: Codable, Equatable {
    case mine, peer(String), waiting(String)
}

struct MissionPeer {
    var label: String
    var card: PeerCaps?
}

enum MissionRouter {
    /// Deliberately a rule in code: M1 owns lanes and preflight, not this router.
    static func route(_ job: MissionJob, peers: [MissionPeer], localRepos: [String], now: Date) -> MissionDestination {
        if job.whereTo != "auto" && job.whereTo != "mine" { return .peer(job.whereTo) }
        let hash = PeerRepo.hash(job.repo)
        if job.whereTo == "auto", let peer = peers.first(where: {
            guard let card = $0.card, !card.isStale(at: now), let hash else { return false }
            return card.repos.contains(hash) && (job.tool.map { card.tools[$0] == true } ?? true)
        }) { return .peer(peer.label) }
        if let hash, localRepos.contains(where: { PeerRepo.hash($0) == hash }) { return .mine }
        return .waiting("Repo isn't available on either Mac")
    }
}

enum MissionState: String, Codable { case running, needsYou = "needs-you", done, canceled }
enum MissionJobState: String, Codable {
    case paused, waiting, blocked, starting, running, completed, merged, needsYou = "input-required", failed, declined, skipped, canceled
    /// A person's step that was marked done.
    case answered
    var satisfied: Bool { self == .merged || self == .skipped || self == .answered }
}

struct MissionJobProgress: Codable, Equatable {
    var state: MissionJobState = .waiting
    var reason = ""
    var destination: MissionDestination?
    var attempt = 0
    var launchKey: String?
    var mergeBlocked = false
    var fixRounds = 0
    /// The job branch head the last status saw, and the head whose merge check failed (short SHA).
    var head: String?
    var failedHead: String?
    var resumeAt: Date?
    /// The Steward work item a human step is filed as. The step's `launchKey` is that item's idempotency key.
    var item: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case state, reason, destination, attempt, launchKey, mergeBlocked, fixRounds, head, failedHead, item, resumeAt
    }

    /// A state file written before a field existed must still load with today's default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(MissionJobState.self, forKey: .state) ?? .waiting
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        destination = try c.decodeIfPresent(MissionDestination.self, forKey: .destination)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        launchKey = try c.decodeIfPresent(String.self, forKey: .launchKey)
        mergeBlocked = try c.decodeIfPresent(Bool.self, forKey: .mergeBlocked) ?? false
        fixRounds = try c.decodeIfPresent(Int.self, forKey: .fixRounds) ?? 0
        head = try c.decodeIfPresent(String.self, forKey: .head)
        failedHead = try c.decodeIfPresent(String.self, forKey: .failedHead)
        item = try c.decodeIfPresent(String.self, forKey: .item)
        resumeAt = try c.decodeIfPresent(Date.self, forKey: .resumeAt)
    }
}

struct MissionLaunch {
    var key: String
    var job: MissionJob
    var base: String
    var branch: String
    var missionName: String? = nil
    var note: String? = nil
}

struct MissionJobStatus {
    var state: MissionJobState
    var reason: String = ""
    /// The branch head the launcher last saw for this job (short SHA); nil when it has none.
    var head: String? = nil
    var resumeAt: Date? = nil
}

/// The fix-round prompt for a worker whose merge check failed. `note` is the check output tail or rebase reason.
enum MissionFixPrompt {
    static func resume(note: String, branch: String) -> String {
        "The merge check failed:\n\(note)\nFix it and push to \(branch) again."
    }
}

/// The key is persisted before calling start. Implementations must recover an existing launch by key.
/// Recovery never blindly calls start when a launch's outcome is unknown.
protocol MissionJobLauncher: AnyObject {
    func start(_ launch: MissionLaunch, at destination: MissionDestination) throws
    func status(key: String, at destination: MissionDestination) -> MissionJobStatus?
    func stop(key: String, at destination: MissionDestination) throws
    func resume(_ launch: MissionLaunch, at destination: MissionDestination) throws
}

enum MissionLaunchError: Error { case refused(String) }

extension MissionJobLauncher {
    func resume(_ launch: MissionLaunch, at destination: MissionDestination) throws {
        throw MissionLaunchError.refused("This job can't be resumed here")
    }
}

enum MissionMergeAnswer {
    case merged
    case inputRequired(String)
    /// A red check or merge conflict: send the job back to its worker with this note (a fix round).
    case fix(String)
}
protocol MissionMergeGate: AnyObject {
    /// U2 owns the real gate and idempotency by remote SHA. Repeating this call must be safe.
    func merge(_ launch: MissionLaunch, at destination: MissionDestination, check: String?) throws -> MissionMergeAnswer
}

/// What Steward says about the work item behind a human step.
enum HumanStepState: Equatable {
    case open(owner: String?)
    case done
    case gone
}

enum HumanStepError: Error, Equatable {
    /// Steward answered with a plain sentence the person can act on.
    case refused(String)
    /// Steward could not be reached; try again later.
    case offline
}

/// where a mission's human steps live. Steward is the authority for whether a step is done; the mission only
/// remembers the item id. `open` must be idempotent by `key` (a replay returns the same item), so a restart or a crash
/// between asking and remembering never files a step twice.
protocol MissionHumanSteps: AnyObject {
    func open(key: String, title: String, who: String, brief: String, workspace: String) throws -> String
    func state(item: String) throws -> HumanStepState
    /// Best effort when a mission is canceled or a step is skipped: take the step off the person's list.
    func release(item: String, reason: String) throws
}

/// Serial owner for one mission folder. No CLI or UI starts this engine in U1.
/// Caller supplies the clock, scheduling policy and platform seams; all disk errors reach the owner.
final class MissionRunner {
    static var liveRoot: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/missions") }
    let id: String
    let folder: URL
    let mission: MissionFile
    private(set) var state: MissionState = .running
    private(set) var jobs: [String: MissionJobProgress] = [:]
    private let launcher: MissionJobLauncher
    private let gate: MissionMergeGate
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let routing: (MissionJob, Date) -> MissionDestination
    private let prepare: () throws -> Void
    private let humans: MissionHumanSteps?
    private var lastHumanPoll: Date?
    /// How often an open human step asks Steward whether it is done. `mission.status` and startup ask at once.
    static let humanPollEvery: TimeInterval = 10
    private let lock = NSRecursiveLock()
    private var armed = false
    private var generation = 0
    private var active = true
    private var lease: Int32 = -1

    private struct Event: Codable {
        var time: Date
        var state: MissionState
        var jobs: [String: MissionJobProgress]
    }

    /// A nonblocking folder lease prevents two owners from dispatching the same mission.
    init(id: String, root: URL = MissionRunner.liveRoot, source: String? = nil, peers: [String],
         launcher: MissionJobLauncher, gate: MissionMergeGate, now: @escaping () -> Date,
         scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         route: @escaping (MissionJob, Date) -> MissionDestination, prepare: @escaping () throws -> Void = {},
         humans: MissionHumanSteps? = nil) throws {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else {
            throw MissionValidationError(line: 1, reason: "Choose a mission name")
        }
        self.id = id; folder = root.appendingPathComponent(id, isDirectory: true)
        self.launcher = launcher; self.gate = gate; self.now = now; schedule = scheduler; routing = route; self.prepare = prepare; self.humans = humans
        let fm = FileManager.default
        let text: String
        if let source {
            // Validate before creating any mission artifacts.
            mission = try MissionFile.parse(source, peers: peers)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            text = source
            try Data(text.utf8).write(to: folder.appendingPathComponent("mission.md"), options: .withoutOverwriting)
        } else {
            text = try String(contentsOf: folder.appendingPathComponent("mission.md"), encoding: .utf8)
            mission = try MissionFile.parse(text, peers: peers)
        }
        lease = open(folder.appendingPathComponent("runner.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            if lease >= 0 { Darwin.close(lease); lease = -1 }
            throw MissionValidationError(line: 1, reason: "Mission is already open")
        }
        do {
            jobs = Dictionary(uniqueKeysWithValues: mission.jobs.map { ($0.title, MissionJobProgress()) })
            let events = folder.appendingPathComponent("events.jsonl")
            if fm.fileExists(atPath: events.path) {
                var data = try Data(contentsOf: events)
                // A crash can leave only the last append incomplete. Remove that uncommitted tail before appending.
                if !data.isEmpty, data.last != 10 {
                    let end = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
                    data = data.prefix(end)
                    let handle = try FileHandle(forWritingTo: events)
                    try handle.truncate(atOffset: UInt64(end)); try handle.synchronize(); try handle.close()
                }
                for line in data.split(separator: 10) {
                    let event = try JSONDecoder().decode(Event.self, from: Data(line))
                    guard Set(event.jobs.keys) == Set(jobs.keys) else { throw MissionValidationError(line: 1, reason: "Mission events don't match the file") }
                    state = event.state; jobs = event.jobs
                }
            }
            if source != nil { try persist() }
        } catch { Darwin.close(lease); lease = -1; throw error }
    }

    deinit { if lease >= 0 { Darwin.close(lease) } }

    private func persist() throws {
        var bytes = try JSONEncoder().encode(Event(time: now(), state: state, jobs: jobs)); bytes.append(10)
        let url = folder.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes); try handle.synchronize()
    }

    private func update(_ title: String, _ progress: MissionJobProgress) throws {
        guard jobs[title] != progress else { return }
        let previous = jobs[title]; jobs[title] = progress
        do { try persist() } catch { jobs[title] = previous; throw error }
    }

    private func setState(_ value: MissionState) throws {
        guard state != value else { return }
        let previous = state; state = value
        do { try persist() } catch { state = previous; throw error }
    }

    private func launch(for job: MissionJob, progress: MissionJobProgress) -> MissionLaunch {
        MissionLaunch(key: progress.launchKey!, job: job, base: mission.into ?? "mission/\(id)",
                      branch: PeerNaming.missionBranch(id: id, job: job.title, index: mission.jobs.firstIndex(where: { $0.title == job.title })!, attempt: progress.attempt), missionName: mission.name)
    }

    private func who(_ job: MissionJob) -> String { job.whereTo.prefix(1).uppercased() + job.whereTo.dropFirst() }

    /// Human steps: file each as a Steward item once its `needs:` are met, then wait for a person to mark it done.
    private func reconcileHumans(force: Bool) throws {
        guard mission.jobs.contains(where: \.isHuman) else { return }
        let t = now()
        let due = force || lastHumanPoll.map { t.timeIntervalSince($0) >= Self.humanPollEvery } ?? true
        var asked = false
        for (index, job) in mission.jobs.enumerated() where job.isHuman {
            var p = jobs[job.title]!
            func open() throws {
                guard let humans else { p.reason = "The group isn't connected"; try update(job.title, p); return }
                asked = true
                do {
                    p.item = try humans.open(key: p.launchKey!, title: "\(mission.name): \(job.title)", who: job.whereTo,
                                             brief: String(job.brief.trimmingCharacters(in: .whitespacesAndNewlines).prefix(480)),
                                             workspace: mission.workspace ?? "")
                    p.reason = "Waiting for \(who(job))"
                } catch HumanStepError.refused(let reason) { p.reason = reason }
                catch { p.reason = "Group offline, will try again" }
                try update(job.title, p)
            }
            switch p.state {
            case .waiting, .blocked:
                if let dependency = job.needs.first(where: { jobs[$0]?.state.satisfied != true }) {
                    p.state = .blocked; p.reason = "Waiting for \(dependency)"
                    try update(job.title, p); continue
                }
                p.launchKey = "mission-\(id)-\(index)-\(p.attempt)"
                p.state = .needsYou; p.reason = "Asking \(who(job))"
                try update(job.title, p) // durable intent BEFORE the side effect; the key makes a replay find the same item
                try open()
            case .needsYou where p.launchKey != nil:
                guard due else { continue }
                guard let item = p.item else { try open(); continue }
                guard let humans else { continue }
                asked = true
                do {
                    switch try humans.state(item: item) {
                    case .done: p.state = .answered; p.reason = ""
                    case .open(let owner): p.reason = "Waiting for \(owner.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? who(job))"
                    case .gone: p.reason = "The step was removed. Retry to ask again"
                    }
                } catch { p.reason = "Group offline, will try again" }
                try update(job.title, p)
            default: continue
            }
        }
        if asked || due { lastHumanPoll = t }
    }

    private func releaseHuman(_ job: MissionJob, _ p: MissionJobProgress, _ reason: String) {
        guard job.isHuman, let item = p.item, let humans else { return }
        try? humans.release(item: item, reason: reason)
    }

    func reconcile(pollHumans: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard active, state != .done else { return }
        if state == .canceled { try cancel(); return }
        // Read existing work before deciding which dependency edges are now satisfied.
        for job in mission.jobs {
            var p = jobs[job.title]!
            guard ([.starting, .running].contains(p.state) || ([.needsYou, .paused].contains(p.state) && !p.mergeBlocked)), let key = p.launchKey, let destination = p.destination else { continue }
            if let status = launcher.status(key: key, at: destination) {
                p.head = status.head
                p.resumeAt = status.resumeAt
                if status.state == .completed, let failed = p.failedHead, status.head == failed {
                    // The old red head is still there: the fix round hasn't produced a new head yet. No gate call, no round.
                    p.state = .running
                } else {
                    p.state = status.state; p.reason = status.reason
                }
            } else {
                p.state = .needsYou; p.reason = "Couldn't confirm whether the job started"
            }
            try update(job.title, p)
        }
        for job in mission.jobs {
            var p = jobs[job.title]!
            if p.state == .completed, let destination = p.destination {
                let answer: MissionMergeAnswer
                do {
                    answer = try gate.merge(launch(for: job, progress: p), at: destination, check: mission.check)
                } catch {
                    // A gate outage needs input for this job; independent work can still proceed.
                    answer = .inputRequired("Couldn't merge the job")
                }
                switch answer {
                case .merged: p.state = .merged; p.reason = ""; p.mergeBlocked = false; p.failedHead = nil
                case .inputRequired(let reason): p.state = .needsYou; p.reason = reason; p.mergeBlocked = true
                case .fix(let note):
                    if p.fixRounds >= 2 {
                        // The 2nd fix round is still red: hand it to the user with the plain reason, no 3rd resume.
                        p.state = .needsYou; p.reason = note; p.mergeBlocked = true
                    } else {
                        p.fixRounds += 1
                        p.failedHead = p.head
                        p.reason = ""; p.mergeBlocked = false
                        p.state = .running
                        try update(job.title, p) // durable intent BEFORE the resume side effect, so a replay never resumes twice
                        var resumeLaunch = launch(for: job, progress: p)
                        resumeLaunch.note = note
                        do { try launcher.resume(resumeLaunch, at: destination) }
                        catch { p.state = .needsYou; p.reason = "Couldn't resume the job"; p.mergeBlocked = true }
                    }
                }
                try update(job.title, p)
            }
        }
        try reconcileHumans(force: pollHumans)
        for job in mission.jobs where !job.isHuman {
            var p = jobs[job.title]!
            guard [.waiting, .blocked].contains(p.state) else { continue }
            if let dependency = job.needs.first(where: { jobs[$0]?.state.satisfied != true }) {
                p.state = .blocked; p.reason = "Waiting for \(dependency)"
                try update(job.title, p); continue
            }
            let destination = routing(job, now())
            if case .waiting(let reason) = destination {
                p.state = .waiting; p.reason = reason; p.destination = destination
                try update(job.title, p); continue
            }
            var preparationError: String?
            do { try prepare() }
            catch PeerError.invalid(let reason) { preparationError = reason }
            catch { preparationError = "Couldn't prepare the mission branch" }
            if let reason = preparationError {
                p.state = .needsYou; p.reason = reason; p.destination = destination
                try update(job.title, p); continue
            }
            p.state = .starting; p.reason = ""; p.destination = destination
            p.launchKey = "mission-\(id)-\(mission.jobs.firstIndex(where: { $0.title == job.title })!)-\(p.attempt)"
            try update(job.title, p) // durable intent BEFORE the side effect
            do {
                if let existing = launcher.status(key: p.launchKey!, at: destination) {
                    p.state = existing.state; p.reason = existing.reason; p.resumeAt = existing.resumeAt
                } else {
                    try launcher.start(launch(for: job, progress: p), at: destination)
                    p.state = .running
                }
            } catch MissionLaunchError.refused(let reason) {
                p.state = .failed; p.reason = reason; p.launchKey = nil
            } catch {
                p.state = .needsYou; p.reason = "Couldn't start the job"
            }
            try update(job.title, p)
        }
        let values = jobs.values
        if values.allSatisfy({ $0.state.satisfied }) { try setState(.done) }
        else if values.contains(where: { [.failed, .declined, .needsYou, .canceled].contains($0.state) || ($0.state == .paused && ($0.resumeAt ?? .distantPast) <= now()) }) { try setState(.needsYou) }
        else { try setState(.running) }
        arm()
    }

    private func arm() {
        guard !armed, active, state != .done, state != .canceled else { return }
        armed = true
        let token = generation
        schedule(1) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.active, self.generation == token else { return }
            self.armed = false
            do { try self.reconcile() } catch { self.lastError = error }
        }
    }
    private(set) var lastError: Error?

    /// Release ownership on shutdown; queued scheduler callbacks cannot act after this point.
    func close() {
        lock.lock(); defer { lock.unlock() }
        active = false; generation += 1
        if lease >= 0 { Darwin.close(lease); lease = -1 }
    }

    func resume(_ title: String) throws { try retryJob(title) }

    func retryJob(_ title: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard active, state != .canceled, var p = jobs[title], [.failed, .declined, .needsYou, .paused, .canceled].contains(p.state) else { return }
        if let job = mission.jobs.first(where: { $0.title == title }), job.isHuman {
            // Ask Steward again; only a step that is gone (or never filed) is asked anew, under a new key.
            if p.item == nil || p.reason.hasPrefix("The step was removed") {
                p.attempt += 1; p.launchKey = nil; p.item = nil; p.state = .waiting; p.reason = ""
                try update(title, p)
            }
            try reconcile(pollHumans: true); return
        }
        // Retry an existing job through its platform's resume seam rather than sending it twice.
        if let key = p.launchKey, let destination = p.destination,
           let status = launcher.status(key: key, at: destination), status.state == .completed {
            p.state = .completed; p.reason = ""; p.mergeBlocked = false // retry the merge, not the work
        } else {
            // Resume input-required work through M1, retaining its existing job and session.
            if let key = p.launchKey, let destination = p.destination {
                guard let status = launcher.status(key: key, at: destination) else { return }
                if [.needsYou, .paused, .running].contains(status.state) {
                    guard status.resumeAt.map({ $0 <= now() }) ?? true else { return }
                    let job = mission.jobs.first { $0.title == title }!
                    p.state = .running; p.reason = ""; p.resumeAt = nil
                    try update(title, p) // durable intent: recovery polls the existing launch, never resumes twice
                    do { try launcher.resume(launch(for: job, progress: p), at: destination) }
                    catch { p.state = .needsYou; p.reason = "Couldn't resume the job"; try update(title, p); throw error }
                    try reconcile(); return
                }
                guard [.failed, .declined, .canceled].contains(status.state) else { return }
            }
            p.attempt += 1; p.launchKey = nil; p.destination = nil; p.state = .waiting; p.reason = ""
            p.head = nil; p.failedHead = nil
        }
        try update(title, p); try reconcile()
    }

    func skipJob(_ title: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard active, state != .canceled, var p = jobs[title], !p.state.satisfied else { return }
        if let key = p.launchKey, let destination = p.destination { try launcher.stop(key: key, at: destination) }
        if let job = mission.jobs.first(where: { $0.title == title }) { releaseHuman(job, p, "Skipped by sender") }
        p.state = .skipped; p.reason = ""; try update(title, p); try reconcile()
    }

    func cancel() throws {
        lock.lock(); defer { lock.unlock() }
        guard active, state != .done else { return }
        try setState(.canceled) // replay an interrupted cancel until every unfinished job is stopped
        var stopError: Error?
        for job in mission.jobs {
            var p = jobs[job.title]!
            guard !p.state.satisfied, p.state != .canceled else { continue }
            releaseHuman(job, p, "Mission canceled")
            if let key = p.launchKey, let destination = p.destination {
                do { try launcher.stop(key: key, at: destination) }
                catch {
                    // Keep this job unfinished for reconciliation, but attempt every other stop.
                    if stopError == nil { stopError = error }
                    continue
                }
            }
            p.state = .canceled; p.reason = "Stopped by sender"; try update(job.title, p)
        }
        if let stopError { throw stopError }
    }
}

/// Reuses M1's send, persistent sent records and sender stop. No relay or preflight is rebuilt here.
final class MissionPeerLauncher: MissionJobLauncher {
    private let engine: PeerEngine
    init(engine: PeerEngine) { self.engine = engine }
    private func existing(_ key: String) -> SentJob? { engine.sentJobs().first { $0.fromAgent == key } }
    func start(_ launch: MissionLaunch, at destination: MissionDestination) throws {
        guard existing(launch.key) == nil else { return }
        guard case .peer(let peer) = destination else { throw PeerError.invalid("Choose a peer") }
        let prompt = launch.job.brief + "\nStart from \(launch.base). Push the finished work to \(launch.branch)."
        if case .failure(let error) = engine.delegate(peer: peer, repo: launch.job.repo, title: launch.job.title,
                                                      brief: prompt, base: launch.base, mode: .background, fromAgent: launch.key, missionBranch: launch.branch, missionName: launch.missionName) {
            if case .invalid(let reason) = error { throw MissionLaunchError.refused(reason) }
        }
    }
    func resume(_ launch: MissionLaunch, at destination: MissionDestination) throws {
        guard let job = existing(launch.key) else { throw MissionLaunchError.refused("Couldn't find the job") }
        if case .failure(let error) = engine.resumeJob(jobId: job.jobId, note: launch.note) { throw error }
    }
    func status(key: String, at destination: MissionDestination) -> MissionJobStatus? {
        guard let job = existing(key) else { return nil }
        let state: MissionJobState
        switch job.status {
        case .done: state = .completed
        case .failed: state = .failed
        case .declined: state = .declined
        case .canceled: state = .canceled
        case .needsYou, .idle: state = .needsYou
        case .paused: state = .paused
        default: state = .running
        }
        return MissionJobStatus(state: state, reason: job.note, head: job.sha, resumeAt: job.resumeAt)
    }
    func stop(key: String, at destination: MissionDestination) throws {
        guard let job = existing(key), !job.status.isFinal else { return }
        if case .failure(let error) = engine.stopJob(jobId: job.jobId) { throw error }
    }
}

/// Existing worktree + background launch path, with a stable builder name for reconciliation.
final class MissionLocalLauncher: MissionJobLauncher {
    private let platform: PeerLauncher
    private let records: () -> [BuilderRecord]
    init(platform: PeerLauncher, records: @escaping () -> [BuilderRecord]) {
        self.platform = platform; self.records = records
    }
    func start(_ launch: MissionLaunch, at destination: MissionDestination) throws {
        guard records().allSatisfy({ $0.name != launch.key }) else { return }
        guard platform.canRunBackground else { throw MissionLaunchError.refused("Background sessions aren't available") }
        guard let clone = platform.resolveClone(repo: launch.job.repo) else { throw MissionLaunchError.refused("Repo isn't available on this Mac") }
        let worktree = clone + ".missions/" + launch.key
        if let reason = platform.prepareWorktree(clone: clone, base: launch.base, branch: launch.branch, worktree: worktree) { throw MissionLaunchError.refused(reason) }
        if let reason = platform.launchBackground(agentName: launch.key, parent: launch.missionName.map { "mission: " + $0 + " · " + launch.job.title } ?? "mission", cwd: worktree,
                                                   prompt: launch.job.brief + "\nPush the finished work to \(launch.branch).") { throw PeerError.invalid(reason) }
    }
    func resume(_ launch: MissionLaunch, at destination: MissionDestination) throws {
        guard let record = records().first(where: { $0.name == launch.key }), !record.sessionID.isEmpty else {
            throw MissionLaunchError.refused("Couldn't find the session")
        }
        let prompt = launch.note.map { MissionFixPrompt.resume(note: $0, branch: launch.branch) } ?? "Continue from where you stopped."
        if let reason = platform.launchBackground(agentName: launch.key, parent: "mission", cwd: record.cwd,
                                                   prompt: prompt, resumeSession: record.sessionID) {
            throw MissionLaunchError.refused(reason)
        }
    }
    func status(key: String, at destination: MissionDestination) -> MissionJobStatus? {
        guard let record = records().first(where: { $0.name == key }) else { return nil }
        switch record.state {
        case .done, .landed: return MissionJobStatus(state: .completed, head: platform.headSHA(worktree: record.worktree ?? record.cwd))
        case .failed, .died, .unlanded: return MissionJobStatus(state: .failed, reason: "Background job failed")
        case .killed: return MissionJobStatus(state: .canceled, reason: "Stopped by sender")
        case .paused: return MissionJobStatus(state: .paused, resumeAt: record.resumeAt.map(Date.init(timeIntervalSince1970:)))
        case .held: return MissionJobStatus(state: .needsYou, reason: record.landReason ?? record.waitReason ?? "Job needs your help")
        default: return MissionJobStatus(state: .running)
        }
    }
    func stop(key: String, at destination: MissionDestination) throws {
        platform.stop(panes: [], builders: [key])
    }
}

final class MissionLaunchers: MissionJobLauncher {
    let local: MissionJobLauncher
    let peer: MissionJobLauncher
    init(local: MissionJobLauncher, peer: MissionJobLauncher) { self.local = local; self.peer = peer }
    private func selected(_ destination: MissionDestination) -> MissionJobLauncher {
        if case .peer = destination { return peer }; return local
    }
    func start(_ launch: MissionLaunch, at destination: MissionDestination) throws { try selected(destination).start(launch, at: destination) }
    func status(key: String, at destination: MissionDestination) -> MissionJobStatus? { selected(destination).status(key: key, at: destination) }
    func stop(key: String, at destination: MissionDestination) throws { try selected(destination).stop(key: key, at: destination) }
    func resume(_ launch: MissionLaunch, at destination: MissionDestination) throws { try selected(destination).resume(launch, at: destination) }
}
