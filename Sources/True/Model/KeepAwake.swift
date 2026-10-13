import Foundation
import IOKit.pwr_mgt

/// The lease on the idle timers, behind a protocol so the controller's tests use a fake.
@MainActor
protocol PowerAssertion: AnyObject {
    var held: Bool { get }
    func hold(reason: String)
    func release()
}

/// The real backend: one IOPM display-sleep assertion. A power assertion is a lease on the idle timers:
/// a display-sleep assertion (what `caffeinate -d` takes) stops the screen dimming and the
/// screensaver starting, so the password lock that follows either one never comes. It also implies
/// no system sleep. `WorkAwake` holds it only while agents work; the kernel drops it the moment the
/// process exits, so a quit (or a crash) can never leave the Mac pinned awake. (Closing a laptop lid still sleeps: that
/// is not an idle timer.)
@MainActor
final class KeepAwake: PowerAssertion {
    static let shared = KeepAwake(reason: "True: agents working")
    private(set) var reason: String
    private var assertion: IOPMAssertionID = 0
    private(set) var held = false

    init(reason: String) { self.reason = reason }

    func hold(reason: String) { self.reason = reason; hold() }

    func hold() {
        guard !held else { return }
        let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             reason as CFString, &assertion)
        held = ok == kIOReturnSuccess
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        held = false
    }
}
