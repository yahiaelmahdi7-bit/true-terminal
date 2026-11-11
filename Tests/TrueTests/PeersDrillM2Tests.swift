import Testing
import Foundation
@testable import True

// The M2 scripted drill: the fix round of Peers missions, end to end through MissionService, the real MissionGitMergeGate,
// a temp git owner repo and a bare remote. Gated on TRUE_DRILL=1. The drill owns its fakes (launcher, clock, scheduler).
// A red merge check must send the job back (launcher.resume with the failing output as `note`), at most 2 fix rounds per
// job, then needsYou. The check is a script that fails the first K times it sees a job (K per job, set by the run).

private final class DrillClock { var now = Date(timeIntervalSince1970: 1_000) }

private final class DrillSchedule {
    var callbacks: [() -> Void] = []
    func enqueue(_ delay: TimeInterval, _ callback: @escaping () -> Void) { callbacks.append(callback) }
}

private final class DrillWorld {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("drill-m2-" + UUID().uuidString)
    var owner: String { root.appendingPathComponent("owner").path }
    var remote: String { root.appendingPathComponent("remote.git").path }
    var worker: String { root.appendingPathComponent("worker").path }
    let clock = DrillClock(), schedule = DrillSchedule()
    var pushed = Set<String>(), rounds: [String: Int] = [:]
    var starts: [String] = [], resumes: [(title: String, note: String)] = [], baseAtStart: [String: String] = [:]
    var service: MissionService?

    @discardableResult func git(_ args: [String], in dir: String) throws -> String {
        let r = PeerLauncherLive.git(["-c", "user.name=Drill", "-c", "user.email=drill@localhost"] + args, in: dir)
        guard r.0 == 0 else { throw PeerError.invalid(args.joined(separator: " ") + ": " + r.1) }
        return r.1
    }
    func setup(reds: [String: Int]) throws {
        try FileManager.default.createDirectory(atPath: owner, withIntermediateDirectories: true)
        try git(["init", "--bare", "-b", "main", remote], in: root.path)
        try git(["init", "-b", "main"], in: owner)
        try Data("base\n".utf8).write(to: URL(fileURLWithPath: owner + "/file.txt"))
        try git(["add", "."], in: owner); try git(["commit", "-m", "base"], in: owner)
        try git(["remote", "add", "origin", remote], in: owner); try git(["push", "origin", "main"], in: owner)
        try git(["clone", remote, worker], in: root.path)
        let script = """
        d="\(root.path)"
        j=$(git diff --name-only HEAD^1 HEAD | head -1 | cut -d- -f1)
        n=$(cat "$d/n-$j" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/n-$j"
        k=$(cat "$d/red-$j" 2>/dev/null || echo 0)
        if [ "$n" -le "$k" ]; then echo "check-red $j try $n"; exit 1; fi
        """
        try Data(script.utf8).write(to: root.appendingPathComponent("check.sh"))
        for (job, k) in reds { try Data("\(k)".utf8).write(to: root.appendingPathComponent("red-" + job)) }
    }
    func remoteSha(_ ref: String) -> String { (try? git(["rev-parse", "refs/heads/" + ref], in: remote)) ?? "?" }
    func baseFiles(_ base: String) -> String { (try? git(["ls-tree", "-r", "--name-only", "refs/heads/" + base], in: remote)) ?? "" }
    func makeService() -> MissionService {
        MissionService(root: root.appendingPathComponent("missions"), launcher: DrillLauncher(world: self), now: { [clock] in clock.now },
                       scheduler: schedule.enqueue, peers: { ["Bea"] }, route: { job, _ in job.whereTo == "Bea" ? .peer("Bea") : .mine },
                       gate: { [owner] in MissionGitMergeGate(folder: $0, resolveClone: { _ in owner }) },
                       prepare: { gate, mission, id in try (gate as! MissionGitMergeGate).prepare(mission, id: id) })
    }
    func clean() { service?.close(); try? FileManager.default.removeItem(at: root) }
}

/// Commits and pushes to the job's branch in the bare remote, then reports completed. A resume does the same and records its note.
private final class DrillLauncher: MissionJobLauncher {
    unowned let w: DrillWorld
    init(world: DrillWorld) { w = world }
    private func push(_ l: MissionLaunch) throws {
        let n = (w.rounds[l.key] ?? 0) + 1; w.rounds[l.key] = n
        try w.git(["fetch", "origin"], in: w.worker)
        let have = (try? w.git(["rev-parse", "--verify", "-q", "refs/remotes/origin/" + l.branch], in: w.worker)) != nil
        try w.git(["checkout", "-q", "-B", l.branch, "origin/" + (have ? l.branch : l.base)], in: w.worker)
        try Data("\(l.job.title) \(n)\n".utf8).write(to: URL(fileURLWithPath: w.worker + "/\(l.job.title)-\(n).txt"))
        try w.git(["add", "."], in: w.worker); try w.git(["commit", "-m", "\(l.job.title) \(n)"], in: w.worker)
        try w.git(["push", "origin", l.branch], in: w.worker)
        w.pushed.insert(l.key)
    }
    func start(_ launch: MissionLaunch, at destination: MissionDestination) throws {
        w.starts.append(launch.job.title); w.baseAtStart[launch.job.title] = w.baseFiles(launch.base)
        try push(launch)
    }
    func resume(_ launch: MissionLaunch, at destination: MissionDestination) throws {
        w.resumes.append((launch.job.title, launch.note ?? ""))
        try push(launch)
    }
    func status(key: String, at destination: MissionDestination) -> MissionJobStatus? {
        w.pushed.contains(key) ? MissionJobStatus(state: .completed) : nil
    }
    func stop(key: String, at destination: MissionDestination) throws {}
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TRUE_DRILL"] == "1"))
struct PeersDrillM2Tests {
    private static func mission(_ w: DrillWorld, bWhere: String) -> String {
        """
        # Mission: Drill
        check: sh \(w.root.path)/check.sh

        ## A
        repo: repo
        where: mine
        Add the A file.

        ## B
        repo: repo
        where: \(bWhere)
        Add the B file.

        ## C
        repo: repo
        where: mine
        needs: A
        Add the C file.
        """
    }

    /// Advances the fake clock and scheduler until nothing changes for a few ticks; gives the one first-merge approval it is asked for.
    private static func drive(_ w: DrillWorld, _ id: String, approvals: inout Int) -> [String: Any] {
        var last = "", quiet = 0, reply: [String: Any] = [:]
        for _ in 0..<80 where quiet < 4 {
            w.clock.now.addTimeInterval(1)
            let due = w.schedule.callbacks; w.schedule.callbacks = []
            due.forEach { $0() }
            reply = w.service!.handle(["op": "mission.status", "missionId": id])
            for row in reply["jobs"] as? [[String: String]] ?? [] where row["reason"]?.hasPrefix("First merge") == true {
                approvals += 1
                reply = w.service!.handle(["op": "mission.approve", "missionId": id, "job": row["title"] ?? ""])
            }
            let sig = "\(reply["state"] ?? "")\(reply["jobs"] ?? "")"
            quiet = sig == last ? quiet + 1 : 0; last = sig
        }
        return reply
    }

    private static func states(_ reply: [String: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (reply["jobs"] as? [[String: String]] ?? []).map { ($0["title"] ?? "", $0["state"] ?? "") })
    }

    private func run(_ n: Int, reds: [String: Int], bWhere: String) throws -> (facts: String, bad: [String]) {
        let w = DrillWorld(); defer { w.clean() }
        try w.setup(reds: reds)
        let main = w.remoteSha("main")
        w.service = w.makeService()
        let started = w.service!.handle(["op": "mission.start", "source": Self.mission(w, bWhere: bWhere)])
        guard let id = started["missionId"] as? String else { return ("start-failed", ["start: \(started["error"] ?? "?")"]) }
        let base = "mission/" + id
        var approvals = 0
        let reply = Self.drive(w, id, approvals: &approvals)
        let jobs = Self.states(reply), mission = reply["state"] as? String ?? "?"
        var bad: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { bad.append(what) } }
        func notes(_ title: String) -> [String] { w.resumes.filter { $0.title == title }.map(\.note) }

        switch n {
        case 1:
            expect(w.resumes.map(\.title) == ["B"], "expected one resume of B, got \(w.resumes.map(\.title))")
            expect(notes("B").first?.contains("check-red B try 1") == true, "B note lacks the check output: \(notes("B"))")
            expect(approvals == 1, "expected 1 first-merge approval, got \(approvals)")
            expect(jobs.values.allSatisfy { $0 == "merged" } && mission == "done", "expected all merged, got \(jobs) \(mission)")
        case 2:
            expect(w.resumes.map(\.title) == ["A"], "expected one resume of A, got \(w.resumes.map(\.title))")
            expect(notes("A").first?.contains("check-red A try 1") == true, "A note lacks the check output: \(notes("A"))")
            expect(jobs.values.allSatisfy { $0 == "merged" } && mission == "done", "expected all merged, got \(jobs) \(mission)")
            expect(w.baseAtStart["C"]?.contains("A-2.txt") == true, "C started before A's fix was merged")
        default:
            expect(w.resumes.map(\.title) == ["A", "A"], "expected exactly 2 resumes of A, got \(w.resumes.map(\.title))")
            expect(notes("A").allSatisfy { $0.contains("check-red A try") }, "A notes lack the check output: \(notes("A"))")
            expect(jobs["A"] == "input-required" && mission == "needs-you", "expected A needsYou, got \(jobs) \(mission)")
            expect(!w.baseFiles(base).contains("A-"), "a red A job was merged")
            expect(!w.starts.contains("C"), "C started behind a red A")
        }

        // Crash replay: a new owner on the same folder must neither merge nor resume nor start anything again.
        let head = w.remoteSha(base), resumes = w.resumes.count, starts = w.starts.count
        w.service!.close()
        w.service = w.makeService(); w.service!.recover()
        _ = Self.drive(w, id, approvals: &approvals)
        let after = Self.states(w.service!.handle(["op": "mission.status", "missionId": id]))
        expect(w.remoteSha(base) == head, "replay moved the mission branch")
        expect(w.resumes.count == resumes && w.starts.count == starts, "replay resumed or started again")
        expect(after == jobs, "replay changed job states \(after)")
        expect(w.remoteSha("main") == main, "main moved")
        let list = jobs.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return ("resumes=\(resumes) approvals=\(approvals) mission=\(mission) jobs=\(list)", bad)
    }

    @Test func m2Drill() throws {
        let plans: [(reds: [String: Int], bWhere: String)] = [(["B": 1], "Bea"), (["A": 1], "mine"), (["A": 3], "mine")]
        for (i, plan) in plans.enumerated() {
            let (facts, bad) = try run(i + 1, reds: plan.reds, bWhere: plan.bWhere)
            print("DRILL M2 run=\(i + 1) \(facts) \(bad.isEmpty ? "PASS" : "FAIL \(bad)")")
            for b in bad { Issue.record("run \(i + 1): \(b)") }
        }
    }
}
