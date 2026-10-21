import Foundation

/// Records the peers engine persists (Run 29). Plain Codable JSON under `~/.true/peers/`, files 0600, dirs 0700.

extension Notification.Name {
    static let peersChanged = Notification.Name("true.peers.changed")
}

/// A paired peer. Their public keys were pinned at pairing (from the invite, or from a valid pair-request) and are
/// the only thing that decides who a message is from. `confirmed` = the pairing handshake finished.
struct PeerLink: Codable, Equatable, Sendable {
    var label: String
    var mailboxId: String
    var keys: PeerKeys
    var confirmed: Bool
    var created: Date
}

/// An invite this Mac handed out. Only the SHA-256 of the secret is kept.
struct PendingInvite: Codable, Equatable, Sendable {
    var secretHash: String
    var expires: Date
    var used: Bool
}

/// Receiver side: a job a paired peer handed to this Mac.
struct InboundJob: Codable, Equatable, Sendable, Identifiable {
    var req: PeerJobRequest
    var peerLabel: String
    var peerMailbox: String
    var status: PeerStatus
    var note: String
    var inboundMode: PeerInboundMode
    var flags: [String]
    var received: Date
    var finished: Date?
    var branch: String
    var sha: String?
    var clone: String?
    var worktree: String?
    var pane: UUID?
    var builder: String?
    /// Run 30: whether follow-ups were allowed when the job was accepted (nil = a Run 29 record).
    var steering: Bool? = nil
    var target: PeerTarget { req.target }
    var id: String { req.jobId }
}

/// Sender side: a job we handed to a peer.
struct SentJob: Codable, Equatable, Sendable, Identifiable {
    var jobId: String
    var peerLabel: String
    var peerMailbox: String
    var title: String
    var repo: String
    var base: String
    var mode: PeerMode
    var fromAgent: String
    var status: PeerStatus
    var note: String
    var branch: String?
    var sha: String?
    var result: String?
    var created: Date
    var updated: Date
    /// Run 30 (optional so older sent.json still loads).
    var target: PeerTarget? = nil
    var seq: Int? = nil
    var lastActivity: Date? = nil
    var id: String { jobId }
}

/// A sealed message waiting for the relay. `owner` is the peer mailbox, so a revoke can drop it.
struct OutboxItem: Codable, Equatable, Sendable {
    var id: String
    var jobId: String?
    var to: String
    var blob: Data
    var attempt: Int
    var nextAt: Date
    var owner: String?
}

/// What the engine needs from the Mac: finding the clone, making the worktree, opening the work, nudging a lead.
/// A protocol so tests run without git, panes or builders.
protocol PeerLauncher: AnyObject, Sendable {
    func resolveClone(repo: String) -> String?
    /// nil = ready; otherwise a short plain reason.
    func prepareWorktree(clone: String, base: String, branch: String, worktree: String) -> String?
    func launchPane(agentName: String, label: String, cwd: String, flags: [String], rolePath: String, firstPrompt: String) -> UUID?
    /// nil = started; otherwise a short plain reason.
    func launchBackground(agentName: String, parent: String, cwd: String, prompt: String) -> String?
    /// Whether a background builder can run here at all (the builder script is installed).
    var canRunBackground: Bool { get }
    func headSHA(worktree: String) -> String?
    func remoteURL(ofRepoAt path: String) -> String?
    func deliverLine(agent: String, line: String)
    func stop(panes: [UUID], builders: [String])
    /// Run 30: type a follow-up line into a job's pane (submitted). False = no live pane.
    func deliverToPane(_ pane: UUID, line: String) -> Bool
    /// Run 30: the pane is showing a permission dialog right now (a `say` must wait for the owner to answer).
    func atPermissionPrompt(pane: UUID) -> Bool
}

extension PeerLauncher {
    func atPermissionPrompt(pane: UUID) -> Bool { false }
    func deliverToPane(_ pane: UUID, line: String) -> Bool { false }
}

enum PeerSendResult: Equatable, Sendable {
    /// The relay took it.
    case delivered
    /// Not connected, rate-limited or queue full: try again later.
    case retry
    /// The relay will never take it (too large).
    case refused
}

/// The wire: one message-based pipe to the relay. `send` blocks until the relay answers (call it off the main thread).
/// Inbound messages arrive on `onMessage`; the transport confirms them to the relay once the handler returns.
protocol PeerTransport: AnyObject, Sendable {
    func send(to: String, id: String, blob: Data) -> PeerSendResult
    var onMessage: (@Sendable (_ from: String, _ id: String, _ blob: Data) -> Void)? { get set }
    /// Called with true when the relay connection is ready, false when it drops.
    var onStatus: (@Sendable (Bool) -> Void)? { get set }
    /// Connected only while there is somebody to talk to.
    func setWanted(_ on: Bool)
    var isConnected: Bool { get }
}
