import Foundation

/// Poll `cond` every 20 ms until it holds or `timeout` passes. The timeout is a ceiling for a
/// loaded machine, not the expected wait: a healthy run returns as soon as the condition is true.
@MainActor
func eventually(_ timeout: Duration = .seconds(30), _ cond: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !cond() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}
