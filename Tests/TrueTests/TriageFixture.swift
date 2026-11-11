import Testing
import Foundation
@testable import True

private let now = 1_800_000_000.0

@MainActor
enum TriageFixture {
    static func builder(_ id: String, _ project: String, _ state: BuilderState, ago: Double = 600, acked: Bool = false) -> BuilderRecord {
        let cwd = "/Users/u/Projects/\(project)"
        return BuilderRecord(id: id, name: id, cwd: cwd, originCwd: cwd, model: "sonnet", sessionID: "s-\(id)", claudePID: 0,
                             started: now - ago - 900, ended: state == .running ? nil : now - ago, state: state, acked: acked,
                             parent: nil, branch: nil, worktree: nil, cost: 1, budget: 5, dir: nil)
    }


    static func groups(_ builders: [BuilderRecord]) -> [HubProjectGroup] {
        HubModel.build(seats: [], seatStatus: { _ in .asleep }, seatAwake: { _ in false }, peers: [], builders: builders,
                       now: now, hasGit: { _ in true })
    }

    static func buckets(_ builders: [BuilderRecord], cloud: [CloudJob] = []) -> [TriageBucket] {
        HubTriage.build(groups: groups(builders), seatStatus: { _ in .asleep }, cloud: cloud, watcher: [], now: now)
    }
}

