import Foundation

/// The CLI and app share these owners. MissionRunner's folder lease also excludes other processes.
final class MissionService: @unchecked Sendable {
    let root: URL
    private let launcher: MissionJobLauncher
    private let now: () -> Date
    private let scheduler: (TimeInterval, @escaping () -> Void) -> Void
    private let peers: () -> [String]
    private let route: (MissionJob, Date) -> MissionDestination
    private let makeGate: (URL) -> MissionMergeGate
    private let prepare: (MissionMergeGate, MissionFile, String) throws -> Void
    private let humans: MissionHumanSteps?
    private let templateDirs: [URL]
    private var runners: [String: MissionRunner] = [:]
    private var gates: [String: MissionMergeGate] = [:]
    private let lock = NSRecursiveLock()

    init(root: URL, launcher: MissionJobLauncher, now: @escaping () -> Date,
         scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         peers: @escaping () -> [String], route: @escaping (MissionJob, Date) -> MissionDestination,
         gate: @escaping (URL) -> MissionMergeGate,
         prepare: @escaping (MissionMergeGate, MissionFile, String) throws -> Void = { _, _, _ in },
         humans: MissionHumanSteps? = nil, templateDirs: [URL] = MissionTemplates.dirs) {
        self.humans = humans; self.templateDirs = templateDirs
        self.root = root; self.launcher = launcher; self.now = now; self.scheduler = scheduler
        self.peers = peers; self.route = route; makeGate = gate; self.prepare = prepare
    }
    private func open(_ id: String, source: String? = nil) throws -> MissionRunner {
        if let runner = runners[id] { return runner }
        let gate = makeGate(root.appendingPathComponent(id))
        let preparation = prepare, labels = peers(), folder = root.appendingPathComponent(id)
        let runner = try MissionRunner(id: id, root: root, source: source, peers: peers(), launcher: launcher,
                                       gate: gate, now: now, scheduler: scheduler, route: route, prepare: {
            let text = try String(contentsOf: folder.appendingPathComponent("mission.md"), encoding: .utf8)
            try preparation(gate, MissionFile.parse(text, peers: labels), id)
        }, humans: humans)
        runners[id] = runner; gates[id] = gate
        return runner
    }
    func recover() {
        lock.lock(); defer { lock.unlock() }
        for id in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            do { try open(id).reconcile(pollHumans: true) } catch { /* Another process may own this folder. Leave its lease alone. */ }
        }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        for runner in runners.values { runner.close() }
        runners.removeAll(); gates.removeAll()
    }
    func handle(_ request: [String: Any]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        do {
            let op = request["op"] as? String ?? ""
            let runner: MissionRunner
            if op == "mission.templates" { return ["ok": true, "templates": MissionTemplates.names(in: templateDirs)] }
            if op == "mission.start" {
                var source = request["source"] as? String
                if let template = request["template"] as? String {
                    let vars = (request["vars"] as? [String: String]) ?? [:]
                    source = try MissionTemplates.fill(MissionTemplates.load(template, in: templateDirs), vars: vars)
                }
                guard let source else { throw PeerError.invalid("Choose a mission file") }
                _ = try MissionFile.parse(source, peers: peers())
                let id = UUID().uuidString.lowercased()
                runner = try open(id, source: source)
                try runner.reconcile()
            } else {
                guard let id = request["missionId"] as? String else { throw PeerError.invalid("Choose a mission") }
                runner = try open(id)
                switch op {
                case "mission.status": try runner.reconcile(pollHumans: true)
                case "mission.cancel": try runner.cancel()
                case "mission.approve":
                    guard let title = request["job"] as? String, runner.jobs[title] != nil,
                          let gate = gates[id] as? MissionGitMergeGate else { throw PeerError.invalid("Choose a job waiting for approval") }
                    try gate.approve(job: title); try runner.retryJob(title)
                default: throw PeerError.invalid("Unknown mission command")
                }
            }
            let rows: [[String: String]] = runner.mission.jobs.map { job in
                let progress = runner.jobs[job.title]!
                let mac: String
                switch progress.destination {
                case .peer(let name): mac = name
                case .mine: mac = "My Mac"
                default: mac = job.whereTo == "auto" ? "Waiting for a Mac" : job.whereTo == "mine" ? "My Mac" : job.whereTo
                }
                let who = job.whereTo.prefix(1).uppercased() + job.whereTo.dropFirst()
                return ["title": job.title, "mac": job.isHuman ? who : mac, "state": progress.state == .answered ? "done" : progress.state.rawValue, "reason": progress.reason.components(separatedBy: .newlines).joined(separator: " ")]
            }
            return ["ok": true, "missionId": runner.id, "state": runner.state.rawValue, "jobs": rows]
        } catch let error as MissionValidationError {
            return ["ok": false, "error": error.description]
        } catch PeerError.invalid(let reason) {
            return ["ok": false, "error": reason]
        } catch {
            return ["ok": false, "error": "Couldn't open the mission"]
        }
    }

    static func live(engine: PeerEngine, platform: PeerLauncher, now: @escaping () -> Date,
                     scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void) -> MissionService {
        let local = MissionLocalLauncher(platform: platform, records: {
            HubScanner.builders(in: HubScanner.claudeDir.appendingPathComponent("builders"))
        })
        func resolve(_ repo: String) -> String? {
            if let path = engine.shares().first(where: { PeerRepo.normalize($0.repo.url) == PeerRepo.normalize(repo) && !$0.repo.path.isEmpty })?.repo.path { return path }
            return platform.resolveClone(repo: repo)
        }
        let humans: MissionHumanSteps? = nil
        return MissionService(root: engine.root.deletingLastPathComponent().appendingPathComponent("missions"),
                              launcher: MissionLaunchers(local: local, peer: MissionPeerLauncher(engine: engine)),
                              now: now, scheduler: scheduler, peers: { engine.peerLinks().map(\.label) },
                              route: { job, date in
            MissionRouter.route(job, peers: engine.peerLinks().map { MissionPeer(label: $0.label, card: engine.peerCaps($0.mailboxId)) },
                                localRepos: resolve(job.repo) == nil ? [] : [job.repo], now: date)
        }, gate: { MissionGitMergeGate(folder: $0, resolveClone: resolve) }, prepare: { gate, mission, id in
            try (gate as! MissionGitMergeGate).prepare(mission, id: id)
        }, humans: humans)
    }
}
