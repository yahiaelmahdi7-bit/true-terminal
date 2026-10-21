import AppKit
import Foundation
import Observation
@preconcurrency import UserNotifications

/// What changed between two polls that deserves a macOS notification: a job that just started waiting for an
/// answer, or just finished. Pure so it tests without a notification center. The first poll only seeds.
enum CloudChange {
    enum Kind: Equatable { case needsYou, done }
    static func transitions(old: [String: String]?, new: [CloudJob]) -> [(job: CloudJob, kind: Kind)] {
        guard let old else { return [] }
        return new.compactMap { j in
            guard let before = old[j.id], before != j.status else { return nil }
            if j.needsYou { return (j, .needsYou) }
            if j.isDone { return (j, .done) }
            return nil
        }
    }
}

/// The macOS banner for a cloud job. A click opens the Hub on All, where the Cloud section sits.
final class CloudNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = CloudNotifier()

    static func body(_ kind: CloudChange.Kind, title: String) -> String {
        switch kind {
        case .needsYou: return "Cloud job needs you: \(title)"
        case .done: return "Cloud job done: \(title)"
        }
    }

    func post(_ kind: CloudChange.Kind, job: CloudJob) {
        // A bare `swift run`/test binary has no bundle id, and UNUserNotificationCenter traps without one.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let body = Self.body(kind, title: job.title)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "True"
            c.body = body
            c.sound = .default
            c.categoryIdentifier = "true.cloud.job"
            center.add(UNNotificationRequest(identifier: "cloud-\(job.id)-\(job.status)", content: c, trigger: nil))
        }
    }

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

/// Cloud jobs as the Hub sees them. Polls (the factory has no push): every 5 s while the Hub shows them, 15 s
/// while a job is working, 60 s otherwise. Notifies on needsYou / done transitions.
@MainActor
@Observable
final class CloudStore {
    static let shared = CloudStore()

    private(set) var jobs: [CloudJob] = []
    /// Why the last poll failed, in plain words; nil when it worked.
    private(set) var error: String?
    private(set) var loaded = false
    var visible = false

    @ObservationIgnored var client: CloudClient
    @ObservationIgnored var notify: (CloudChange.Kind, CloudJob) -> Void = { CloudNotifier.shared.post($0, job: $1) }
    @ObservationIgnored private var lastStatus: [String: String]?
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(client: CloudClient = CloudClient()) { self.client = client }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let wait: Double = self.error != nil ? 60 : self.visible ? 5 : (self.jobs.contains { $0.isWorking } ? 15 : 60)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    func refresh() async {
        do {
            let list = try await client.jobs()
            apply(list)
            error = nil
        } catch {
            self.error = (error as? CloudError)?.errorDescription ?? "Cloud unavailable"
        }
        loaded = true
    }

    /// Public for tests: take a fresh list, fire notifications for transitions, remember statuses.
    func apply(_ list: [CloudJob]) {
        for t in CloudChange.transitions(old: lastStatus, new: list) { notify(t.kind, t.job) }
        lastStatus = Dictionary(list.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        jobs = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    var attention: Int { jobs.filter { $0.needsYou }.count }
}
