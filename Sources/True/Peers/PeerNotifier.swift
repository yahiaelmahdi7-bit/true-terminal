import AppKit
import UserNotifications

/// The macOS notification for an inbound peer job ("<peer> sent a job: <title>"). A click opens the Hub on All, where the
/// job sits under "From peers". Asks for notification permission the first time a job arrives, not at launch.
final class PeerNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = PeerNotifier()
    private static let category = "true.peer.job"

    func jobArrived(_ job: InboundJob) {
        // A bare `swift run`/test binary has no bundle id, and UNUserNotificationCenter traps without one.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let body = PeerText.arrival(peer: job.peerLabel, title: job.req.title, mode: job.inboundMode)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "True"
            c.body = body
            c.sound = .default
            c.categoryIdentifier = Self.category
            center.add(UNNotificationRequest(identifier: "peer-job-" + job.id, content: c, trigger: nil))
        }
    }

    /// Show the banner even while True is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        done()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                HubStore.shared.filter = .all
                AgentRegistry.shared.panelOpen = true
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
