import Testing
import Foundation
@testable import True

/// Proof harness (skipped unless TRU_PROOF_MARKERS is set): feeds a real tru marker through the same decision code
/// the snapshot uses (find -> SessionRecorder.decide -> ResumePlan.apply) and writes the startup command out.
@Suite @MainActor struct TruRestoreProofTests {
    @Test func markerToStartupCommand() throws {
        let env = ProcessInfo.processInfo.environment
        guard let m = env["TRU_PROOF_MARKERS"], let s = env["TRU_PROOF_SESSIONS"], let out = env["TRU_PROOF_OUT"],
              let pidS = env["TRU_PROOF_PID"], let pid = pid_t(pidS) else { return }
        let interrupted = env["TRU_PROOF_INTERRUPTED"] == "1"
        let found = ClaudeSessions.find(under: 1, sessionsDir: URL(fileURLWithPath: "/nonexistent"),
                                        truDir: URL(fileURLWithPath: m)) { $0 == 1 ? [pid] : [] }
        let rec = SessionRecorder.decide(previous: nil, agent: nil, alive: true, found: found)
        var ws = WorkspaceState.fresh(cwd: "/tmp")
        let p = ws.tabs[0].focusedPane
        ws.tabs[0].resume = rec.map { [p: $0] }
        if interrupted { ws.tabs[0].interrupted = [p] }
        let r = ResumePlan.apply(ws, claudeDir: URL(fileURLWithPath: "/nonexistent"), settings: "/s",
                                 truSessionsDir: URL(fileURLWithPath: s))
        let text = "RECORD: \(String(describing: rec))\nBUSY: \(found?.busy ?? false)\nCWD: \(r.state.tabs[0].cwds[p] ?? "-")\nSTARTUP: \(r.startups[p] ?? "NONE")\n"
        try text.write(toFile: out, atomically: true, encoding: .utf8)
        #expect(r.startups[p] != nil)
    }
}
