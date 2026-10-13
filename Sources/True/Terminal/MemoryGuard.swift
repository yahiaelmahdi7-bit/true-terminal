import Foundation
import Darwin

/// The circuit breaker. True may not eat the machine, whatever else goes wrong.
///
/// ## Why a guard and not just a fix
///
/// A pane's child can write faster than anything downstream can consume, and the terminal stack
/// below us does not bound what it keeps while catching up. Measured on Axon's unmodified app: a
/// single process printing flat out drove the footprint to **21 GB in 30 seconds**, and on a
/// longer run to **68 GB (peak 70 GB, 68 GB of it swapped)** before macOS killed the process —
/// with the machine thrashing swap the whole time. Instrumenting it found ~6.9 million leaked
/// `DispatchIO` read operations: SwiftTerm re-issues a read from inside its own read handler, and
/// under sustained load that queue never goes idle, so its autorelease pool never drains.
///
/// `TrueTerminalView`'s flow control (SIGSTOP the writer until the backlog clears) cuts that by
/// more than an order of magnitude and is the primary defence. But it is a rate reduction, not a
/// bound — the leak is upstream, in a dependency, behind `private` — so this guard is the
/// backstop: if the process footprint crosses a ceiling it stops every pane child outright and
/// leaves them stopped. Stopping is deliberately not automatic-recovery; `resumeAll()` is wired
/// to the user saying so.
///
/// **Idle cost (True's rule: idle ≈ 0% CPU).** Axon ran this check on an always-on 2 s timer. Here
/// the timer exists ONLY while a pane is flooding (`noteFlood()`, called from the flood detector)
/// and stops itself once the flood ends — a runaway can only happen during a flood, so nothing is
/// lost, and a quiet app runs no timer at all.
@MainActor
final class MemoryGuard {
    static let shared = MemoryGuard()

    private final class Box {
        weak var view: TrueTerminalView?
        init(_ v: TrueTerminalView) { view = v }
    }
    private var panes: [ObjectIdentifier: Box] = [:]

    /// Where the breaker trips: far above anything True legitimately needs, far below swapping.
    static let ceilingBytes: UInt64 = 6 * 1024 * 1024 * 1024

    private(set) var tripped = false
    private(set) var trippedAtBytes: UInt64 = 0

    private var timer: Timer?

    private init() {}

    func register(_ view: TrueTerminalView) { panes[ObjectIdentifier(view)] = Box(view) }
    func unregister(_ view: TrueTerminalView) { panes.removeValue(forKey: ObjectIdentifier(view)) }

    /// A pane is flooding: make sure the watch is running. Cheap and idempotent.
    func noteFlood() {
        guard timer == nil, !tripped else { return }
        // 2 s is far more often than a runaway needs (fastest observed climb ~700 MB/s, so
        // ~1.4 GB between checks — inside the headroom above the ceiling).
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in MemoryGuard.shared.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        if !TrueTerminalView.isFlooding {
            timer?.invalidate()
            timer = nil
            return
        }
        guard !tripped, let footprint = Self.footprint(), footprint > Self.ceilingBytes else { return }
        tripped = true
        trippedAtBytes = footprint
        timer?.invalidate()
        timer = nil
        for box in panes.values { box.view?.haltForMemoryGuard() }
        NotificationCenter.default.post(name: .trueMemoryGuardTripped, object: nil)
    }

    /// Let everything run again — the user's call, not ours.
    func resumeAll() {
        tripped = false
        trippedAtBytes = 0
        for box in panes.values { box.view?.resumeChild() }
    }

    /// This process's physical footprint — the number Activity Monitor and `vmmap` report, and the
    /// one that matters for memory pressure (RSS misses everything swapped).
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}

extension Notification.Name {
    /// Posted when `MemoryGuard` stops the panes.
    static let trueMemoryGuardTripped = Notification.Name("io.github.true-terminal.True.memoryGuardTripped")
}
