import Foundation
import Observation

/// One line in the sheet: a scanned file plus where its rewrite stands.
struct CleanerRow: Identifiable, Equatable {
    enum Status: Equatable {
        case idle, queued, rewriting
        case done(RewriteOutcome)
        case error(String)
    }
    let file: ContextFile
    var rewriteChecked: Bool
    var applyChecked = false
    var status: Status = .idle
    var applyResult: String?
    var id: String { file.id }

    var outcome: RewriteOutcome? { if case .done(let o) = status { return o }; return nil }
    var tokensAfter: Int? { outcome.map { $0.output.utf8.count / 4 } }
    /// Only a finished, non-lean, error-free rewrite can be applied.
    var canApply: Bool { if let o = outcome { return !o.isLean }; return false }
}

/// The Context Cleaner sheet's state. Scan runs once each time the sheet opens; nothing watches disk and
/// nothing ticks — job progress arrives as callbacks.
@MainActor @Observable
final class ContextCleaner {
    static let shared = ContextCleaner()

    var isOpen = false
    var rows: [CleanerRow] = []
    var selectedID: String?
    var model: AgentModel = .opus
    var scanning = false
    var running = false
    var banner: String?

    private var work: Task<Void, Never>?
    var runner: CleanerRunning = ProcessCleanerRunner()
    var applier = CleanerApplier()
    /// Jev fact check + ordering. Nil turns both off (tests).
    var jev: JevClient? = JevClient.shared

    func open() {
        isOpen = true
        scan()
    }

    /// Closing the sheet cancels queued jobs and terminates running `claude` processes.
    func close() {
        work?.cancel(); work = nil
        running = false
        isOpen = false
    }

    func scan() {
        work?.cancel()
        scanning = true; banner = nil; running = false
        work = Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) { () -> [ContextFile] in
                let roots = ProjectList.build(ProjectStore().load()).map(\.path) + [NSHomeDirectory()]
                return ContextScanner().scan(roots: roots)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.rows = files.map { CleanerRow(file: $0, rewriteChecked: $0.defaultChecked) }
            self.selectedID = self.rows.first?.id
            self.scanning = false
        }
    }

    // MARK: Rewrite

    var selectableRows: [CleanerRow] { rows.filter { $0.file.lock == nil } }
    var toRewrite: [CleanerRow] { rows.filter { $0.rewriteChecked && $0.file.lock == nil } }

    func rewriteSelected() {
        let targets = toRewrite.map(\.file)
        guard !targets.isEmpty, !running else { return }
        guard let binary = CleanerLaunch.resolveBinary(candidates: CleanerLaunch.candidates()) else {
            banner = "Couldn't find the claude binary. Set CLAUDE_BIN or install it in ~/.local/bin."
            for f in targets { setStatus(sha: f.sha, .error("claude binary not found")) }
            return
        }
        banner = nil; running = true
        let shas = Set(targets.map(\.sha))
        for i in rows.indices where shas.contains(rows[i].file.sha) && rows[i].rewriteChecked {
            rows[i].status = .queued; rows[i].applyChecked = false; rows[i].applyResult = nil
        }
        let engine = CleanerEngine(runner: runner, binary: binary, cwd: CleanerLaunch.emptyDir(),
                                   env: CleanerLaunch.scrubbedEnv(), jev: jev)
        let m = model
        let jev = self.jev
        work = Task { [weak self] in
            // Biggest wins first; Jev being slow or absent leaves scan order (bounded to ~5 s).
            let queue = await CleanerOrdering.order(targets, jev: jev)
            await engine.rewrite(queue, model: m) { sha, event in
                Task { @MainActor in self?.handle(sha: sha, event) }
            }
            guard let self else { return }
            self.running = false
            // Cancelled jobs never report back: put their rows back to idle.
            for i in self.rows.indices where self.rows[i].status == .queued || self.rows[i].status == .rewriting {
                self.rows[i].status = .idle
            }
        }
    }

    private func handle(sha: String, _ event: JobEvent) {
        switch event {
        case .started: setStatus(sha: sha, .rewriting)
        case .finished(let r):
            switch r {
            case .failure(let e): setStatus(sha: sha, .error(e.message))
            case .success(let o):
                for i in rows.indices where rows[i].file.sha == sha && rows[i].status != .idle {
                    rows[i].status = .done(o)
                    // Apply defaults on only for a clean, non-lean rewrite: dropped facts are his call.
                    rows[i].applyChecked = !o.isLean && o.dropped.isEmpty && !o.factCheck.blocksApply
                }
            }
        }
    }

    private func setStatus(sha: String, _ s: CleanerRow.Status) {
        for i in rows.indices where rows[i].file.sha == sha && (rows[i].rewriteChecked || rows[i].status != .idle) {
            rows[i].status = s
        }
    }

    // MARK: Review totals

    var appliable: [CleanerRow] { rows.filter { $0.applyChecked && $0.canApply } }

    var totals: (files: Int, before: Int, after: Int) {
        let a = appliable
        return (a.count, a.reduce(0) { $0 + $1.file.tokens }, a.reduce(0) { $0 + ($1.tokensAfter ?? 0) })
    }

    // MARK: Apply / undo

    func applySelected() {
        let reqs = appliable.compactMap { r in r.outcome.map { ApplyRequest(file: r.file, newContent: $0.output + "\n") } }
        guard !reqs.isEmpty else { return }
        let applier = self.applier
        Task {
            let results = await Task.detached { applier.apply(reqs) }.value
            var ok = 0
            for res in results {
                guard let i = rows.firstIndex(where: { $0.file.path == res.path }) else { continue }
                rows[i].applyResult = res.error ?? "Applied"
                rows[i].applyChecked = false
                if res.error == nil { ok += 1 }
            }
            banner = "Applied \(ok) of \(results.count). Backup in ~/.true/cleaner-backups. Rescan to re-read."
        }
    }

    func undoLast() {
        let applier = self.applier
        Task {
            let r = await Task.detached { applier.undoLast() }.value
            if let n = r.note { banner = n; return }
            banner = "Restored \(r.restored.count)" + (r.skipped.isEmpty ? "." : ", skipped \(r.skipped.count) edited since apply.")
        }
    }
}
