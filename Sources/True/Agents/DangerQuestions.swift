import Foundation

/// The five narrow danger questions, verbatim from SPEC Run 14c. ONE source: the Command bar's router and the
/// Watcher's permission gate both ask exactly these strings (a test pins the equality).
enum DangerQuestions {
    static let all: [(id: String, text: String)] = [
        ("danger_push", "Does `text` ask for git commits to be pushed to a remote repository?"),
        ("danger_delete", "Does `text` ask to delete, wipe, purge or drop existing data, files or records?"),
        ("danger_deploy", "Does `text` ask to deploy or publish something to production or a live site? Starting or spawning agents or helpers is not a deploy."),
        ("danger_send", "Does `text` ask for messages or emails to be sent to people? Forbidding or delaying sending is not asking to send."),
        ("danger_live", "Does `text` ask to change data, settings or secrets on a live hosted service, such as a production database or environment variables?"),
    ]
}
