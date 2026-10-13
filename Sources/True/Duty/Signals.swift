import Foundation

/// One thing a source noticed. Facts are strings so every signal logs and sends the same way.
struct WatcherSignal: Equatable, Sendable {
    var source: String            // builders | git | abandonedFailures
    var kind: String
    var subject: String           // builder id | repo@branch | pane
    var repo: String
    var facts: [String: String]
    var evidence: String
    /// A failure code itself observed (failed / died / stuck / ahead): `problem` = 1, no wake gate needed for it.
    var codeFact: Bool
    var title: String

    var fingerprint: String { InboxItem.fingerprint(source: source, kind: kind, subject: subject) }
}

enum BuilderSignals {
    static let stuckSeconds: Double = 20 * 60

    /// Source 1. `killed` never wakes (the user did it). `resultText` reads result.md (injected for tests).
    static func scan(_ builders: [BuilderRecord], now: Double, handled: Set<String> = [],
                     resultText: (BuilderRecord) -> String?, isAlive: (Int32) -> Bool = { PeerSession.isAlive($0) }) -> [WatcherSignal] {
        var out: [WatcherSignal] = []
        for b in builders {
            let facts: [String: String] = ["builder": b.name, "id": b.id, "repo": (b.originCwd as NSString).lastPathComponent,
                                           "status": b.state.rawValue, "acked": String(b.acked),
                                           "cost_usd": b.cost.map { String(format: "%.2f", $0) } ?? "",
                                           "budget_usd": b.budget.map { String(format: "%.2f", $0) } ?? ""]
            func make(_ kind: String, _ code: Bool, _ title: String, _ ev: String) -> WatcherSignal {
                WatcherSignal(source: "builders", kind: kind, subject: b.id, repo: b.originCwd, facts: facts, evidence: ev, codeFact: code, title: title)
            }
            let result = resultText(b) ?? ""
            switch b.state {
            case .failed, .died:
                guard !b.acked else { continue }
                out.append(make(b.state.rawValue, true, "Builder \(b.name) \(b.state == .died ? "died" : "failed")",
                                result.isEmpty ? "The builder \(b.state.rawValue) and left no result.md." : result))
            case .paused:
                guard !b.acked else { continue }
                out.append(make("paused", true, "Builder \(b.name) paused: needs a go-ahead",
                                result.isEmpty ? "The builder paused and left no result.md." : result))
            case .done:
                guard !b.acked, !result.isEmpty else { continue }
                out.append(make("doneUnchecked", false, "Builder \(b.name) finished: check its gates", result))
            case .running:
                guard let w = b.lastWrite, now - w >= stuckSeconds, b.claudePID > 0, isAlive(b.claudePID) else { continue }
                out.append(make("stuck", true, "Builder \(b.name) looks stuck",
                                "The builder's claude process is alive but stream.jsonl has not been written for \(Int((now - w) / 60)) minutes."))
            case .killed: continue
            }
        }
        return out.filter { !handled.contains($0.fingerprint) }
    }
}

enum GitSignals {
    static let minAge: Double = 24 * 3600
    /// Fixed read-only argv, never `fetch`. First lists branches with upstreams, then the commits ahead of each.
    static func branchesArgv(repo: String) -> [String] {
        ["git", "-C", repo, "for-each-ref", "--format=%(refname:short)%09%(upstream:short)", "refs/heads"]
    }
    static func aheadArgv(repo: String, upstream: String, branch: String) -> [String] {
        ["git", "-C", repo, "log", "--format=%ct%x09%s", "\(upstream)..\(branch)"]
    }

    static func parseBranches(_ out: String) -> [(branch: String, upstream: String)] {
        out.split(separator: "\n").compactMap { l in
            let p = l.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return p.count == 2 && !p[1].isEmpty ? (p[0], p[1]) : nil
        }
    }

    struct Commit: Equatable, Sendable { var at: Double; var subject: String }
    static func parseAhead(_ out: String) -> [Commit] {
        out.split(separator: "\n").compactMap { l in
            let p = l.split(separator: "\t", maxSplits: 1).map(String.init)
            guard p.count == 2, let t = Double(p[0]) else { return nil }
            return Commit(at: t, subject: p[1])
        }
    }

    /// Pure: a signal when the oldest commit ahead is >= 24 h old; `byBuilder` when a commit falls inside a builder
    /// run in that repo (the relay-commits-on-main risk).
    static func signal(repo: String, branch: String, commits: [Commit], builders: [BuilderRecord], now: Double) -> WatcherSignal? {
        guard let oldest = commits.map(\.at).min(), now - oldest >= minAge else { return nil }
        let ageH = Int((now - oldest) / 3600)
        let run = builders.first { b in
            b.originCwd == repo && commits.contains { $0.at >= b.started && $0.at <= (b.ended ?? now) + 60 }
        }
        var facts = ["repo": (repo as NSString).lastPathComponent, "branch": branch, "count": String(commits.count),
                     "oldest_age_hours": String(ageH), "subjects": commits.prefix(5).map(\.subject).joined(separator: " | ")]
        if let run { facts["byBuilder"] = run.name }
        let ev = "\(commits.count) commit(s) on \(branch) not pushed for \(ageH) h:\n" + commits.prefix(5).map { "- \($0.subject)" }.joined(separator: "\n")
            + (run.map { "\nSome were made during builder run \($0.name)." } ?? "")
        return WatcherSignal(source: "git", kind: "unpushed", subject: "\((repo as NSString).lastPathComponent)@\(branch)", repo: repo,
                             facts: facts, evidence: ev, codeFact: true, title: "\(commits.count) unpushed commit(s) on \(branch), \(ageH) h old")
    }

    /// Off-main, 5 s timeout per call. nil on any failure.
    static let systemRunner: @Sendable ([String]) -> String? = { argv in
        OffMain.assertOffMain()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: kill)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); kill.cancel()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Whole check for one repo.
    static func check(repo: String, builders: [BuilderRecord], now: Double, run: @Sendable ([String]) -> String?) -> [WatcherSignal] {
        guard let list = run(branchesArgv(repo: repo)) else { return [] }
        return parseBranches(list).compactMap { b in
            run(aheadArgv(repo: repo, upstream: b.upstream, branch: b.branch)).flatMap {
                signal(repo: repo, branch: b.branch, commits: parseAhead($0), builders: builders, now: now)
            }
        }
    }
}

enum AbandonedSignals {
    static func signal(pane: UUID, verdict: OverseerVerdict) -> WatcherSignal? {
        guard OverseerStore.isFailure(verdict.kind), let cwd = verdict.cwd, !cwd.isEmpty else { return nil }
        let ev = verdict.evidence ?? verdict.reason
        return WatcherSignal(source: "abandonedFailures", kind: verdict.kind.rawValue, subject: "pane-\(pane.uuidString.prefix(8))", repo: cwd,
                             facts: ["verdict": verdict.kind.rawValue, "reason": verdict.reason, "repo": (cwd as NSString).lastPathComponent],
                             evidence: ev, codeFact: false, title: "A session ended on a \(verdict.kind.label.lowercased()) result")
    }

    /// `pending.jsonl` lines for the quit snapshot, handled next launch.
    static func encode(_ s: WatcherSignal) -> String? {
        let o: [String: Any] = ["source": s.source, "kind": s.kind, "subject": s.subject, "repo": s.repo, "facts": s.facts,
                                "evidence": s.evidence, "codeFact": s.codeFact, "title": s.title]
        return (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) }
    }
    static func decode(_ line: String) -> WatcherSignal? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let source = o["source"] as? String, let kind = o["kind"] as? String, let subject = o["subject"] as? String,
              let repo = o["repo"] as? String else { return nil }
        return WatcherSignal(source: source, kind: kind, subject: subject, repo: repo, facts: o["facts"] as? [String: String] ?? [:],
                             evidence: o["evidence"] as? String ?? "", codeFact: o["codeFact"] as? Bool ?? false, title: o["title"] as? String ?? kind)
    }
}
