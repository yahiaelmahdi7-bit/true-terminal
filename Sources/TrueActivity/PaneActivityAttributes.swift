import ActivityKit
import Foundation

/// One Live Activity per pane that needs you. Shared by the app (starts/updates it) and the TrueActivity extension (draws it).
struct PaneActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var question: String
        var tool: String?
        /// "needsYou" | "working" | "done" | "sent" (an Approve/Deny was just pressed; buttons are gone until the next poll).
        var status: String
        var since: Date
        /// "permission" | "question" (nil from an older Mac = permission).
        var kind: String?
    }

    var paneId: String
    var name: String
}
