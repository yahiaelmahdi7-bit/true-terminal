import Foundation

/// The result of one rewrite, already sanitized and checked.
struct RewriteOutcome: Equatable, Sendable {
    let output: String
    /// Facts from the original that are missing verbatim from the output.
    let dropped: [String]
    /// Output is ≥ 97% of the original: not worth applying.
    let isLean: Bool
    /// Jev's second opinion on vanished blocks; only ever adds warnings.
    var factCheck: FactCheck = .notRun
}

enum JobEvent: Sendable {
    case started
    case finished(Result<RewriteOutcome, CleanerError>)
}

/// Runs the rewrites: one job per UNIQUE content (identical copies share it), at most `maxConcurrent`
/// at a time. Cancelling the calling task terminates running processes and skips queued jobs.
struct CleanerEngine: Sendable {
    let runner: CleanerRunning
    let binary: URL
    let cwd: URL
    let env: [String: String]
    var maxConcurrent = 3
    /// Nil = no fact check (tests, or Jev not wired in).
    var jev: JevClient?
    var timeout = CleanerLaunch.timeout

    /// `onEvent(sha, …)` fires from worker tasks; the sha identifies the content, not the file.
    func rewrite(_ files: [ContextFile], model: AgentModel,
                 onEvent: @escaping @Sendable (String, JobEvent) -> Void) async {
        var seen = Set<String>()
        let unique = files.filter { seen.insert($0.sha).inserted }
        await withTaskGroup(of: Void.self) { group in
            var it = unique.makeIterator()
            var running = 0
            func next() -> ContextFile? { Task.isCancelled ? nil : it.next() }
            while running < maxConcurrent, let f = next() {
                group.addTask { await job(f, model: model, onEvent: onEvent) }; running += 1
            }
            while await group.next() != nil {
                if let f = next() { group.addTask { await job(f, model: model, onEvent: onEvent) } }
            }
        }
    }

    private func job(_ f: ContextFile, model: AgentModel,
                     onEvent: @Sendable (String, JobEvent) -> Void) async {
        onEvent(f.sha, .started)
        do {
            let raw = try await runner.run(binary: binary, argv: CleanerLaunch.argv(model: model),
                                           stdin: Data(f.content.utf8), cwd: cwd, env: env, timeout: timeout)
            switch CleanerChecks.sanitize(raw, original: f.content) {
            case .failure(let e): onEvent(f.sha, .finished(.failure(e)))
            case .success(let out):
                let lean = CleanerChecks.isLean(original: f.content, output: out)
                var check = FactCheck.notRun
                if !lean, let jev { check = await CleanerFactCheck.run(original: f.content, output: out, jev: jev) }
                onEvent(f.sha, .finished(.success(RewriteOutcome(
                    output: out,
                    dropped: CleanerChecks.droppedFacts(original: f.content, output: out),
                    isLean: lean, factCheck: check))))
            }
        } catch is CancellationError {
            // Sheet closed: the row goes back to idle, nothing to report.
        } catch let e as CleanerError {
            onEvent(f.sha, .finished(.failure(e)))
        } catch {
            onEvent(f.sha, .finished(.failure(CleanerError(message: error.localizedDescription))))
        }
    }
}
