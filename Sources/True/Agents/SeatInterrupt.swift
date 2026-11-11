import Foundation

/// One Esc per turn, even if verification times out or two callers race. A new prompt resets it.
@MainActor
final class SeatInterrupt {
    private var attempted: Set<UUID> = []
    private var generations: [UUID: Int] = [:]
    func generation(_ pane: UUID) -> Int { generations[pane, default: 0] }
    func reset(_ pane: UUID) { attempted.remove(pane); generations[pane, default: 0] += 1 }
    func perform(pane: UUID, facts: SeatScreen, working: () -> Bool,
                 read: () -> String?, event: () -> PaneEvent?, send: (String) -> Void,
                 pause: () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }) async -> PaneDelivery.Outcome {
        guard let text = read() else { return .noPane }
        guard !attempted.contains(pane), working(), facts.isBusy(text), !facts.dialogVisible(text) else { return .promptGone }
        // Read again at the write boundary: a completed turn or a new dialog must win the race.
        guard let current = read() else { return .noPane }
        guard working(), facts.isBusy(current), !facts.dialogVisible(current) else { return .promptGone }
        let token = generation(pane), pressedAt = Date()
        attempted.insert(pane)
        send(facts.interruptKey)
        for _ in 0..<12 {
            await pause()
            guard generation(pane) == token else { return .promptGone }
            guard let now = read() else { return .noPane }
            if let e = event(), e.at >= pressedAt, [.stop, .done, .idle].contains(e.kind) { return .landed }
            if !facts.isBusy(now), !facts.dialogVisible(now) { return .landed }
        }
        return .unverified
    }
}
