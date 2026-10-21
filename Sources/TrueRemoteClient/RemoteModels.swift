import Foundation

/// Typed mirrors of the JSON True's phone server returns. Keys match the server exactly; fields the Mac
/// omits (or the mock omits) are optional or default to zero so a missing key never fails a whole poll.

// MARK: Hub (GET /api/hub)

public struct HubSnapshot: Codable, Equatable, Sendable {
    public var now: Double?
    public var working: Int
    public var needsYou: Int
    public var failed: Int
    public var summary: String
    public var projects: [HubProject]

    public init(now: Double? = nil, working: Int = 0, needsYou: Int = 0, failed: Int = 0, summary: String = "", projects: [HubProject] = []) {
        self.now = now; self.working = working; self.needsYou = needsYou; self.failed = failed
        self.summary = summary; self.projects = projects
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        now = try c.decodeIfPresent(Double.self, forKey: .now)
        working = try c.decodeIfPresent(Int.self, forKey: .working) ?? 0
        needsYou = try c.decodeIfPresent(Int.self, forKey: .needsYou) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        projects = try c.decodeIfPresent([HubProject].self, forKey: .projects) ?? []
    }

    /// Ids of every row whose status is "needs you" (the unit the phone notifies on).
    public var needsYouIDs: Set<String> {
        Set(projects.flatMap(\.rows).filter { $0.statusKey == "needsYou" }.map(\.id))
    }
}

public struct HubProject: Codable, Equatable, Sendable {
    public var key: String?
    public var title: String
    public var summary: String
    public var working: Int
    public var needsYou: Int
    public var failed: Int
    public var rows: [HubRow]

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        working = try c.decodeIfPresent(Int.self, forKey: .working) ?? 0
        needsYou = try c.decodeIfPresent(Int.self, forKey: .needsYou) ?? 0
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        rows = try c.decodeIfPresent([HubRow].self, forKey: .rows) ?? []
    }
}

/// `kind` is "seat" | "background" | "other"; `statusKey` is the AgentStatus raw value
/// ("working", "needsYou", "idle", "done", "failed", "asleep"...). Kept as strings so a new Mac value never breaks decoding.
public struct HubRow: Codable, Equatable, Sendable, Identifiable {
    public var kind: String
    public var id: String
    public var name: String
    public var status: String
    public var statusKey: String
    public var model: String?
    public var pane: String?
    public var cwd: String?
    /// Always text for display ("41m", "1h 2m"). The Mac sends builder rows a number of seconds and may send
    /// seats a label; both decode, so a type change on one side never reads as "Mac offline" on the phone.
    public var elapsed: String?
    public var builderId: String?
    public var acked: Bool?
    public var branch: String?
    public var updated: Double?
    /// Needs-you rows only: what the pane is asking (≤ 300 chars each, all optional).
    public var question: String?
    public var tool: String?
    public var detail: String?
    /// Needs-you rows only: "permission" or "question" (nil from an older Mac).
    public var needKind: String?

    public init(kind: String, id: String, name: String, status: String, statusKey: String, model: String? = nil,
                pane: String? = nil, cwd: String? = nil, elapsed: String? = nil, builderId: String? = nil,
                acked: Bool? = nil, branch: String? = nil, updated: Double? = nil,
                question: String? = nil, tool: String? = nil, detail: String? = nil, needKind: String? = nil) {
        self.kind = kind; self.id = id; self.name = name; self.status = status; self.statusKey = statusKey
        self.model = model; self.pane = pane; self.cwd = cwd; self.elapsed = elapsed; self.builderId = builderId
        self.acked = acked; self.branch = branch; self.updated = updated
        self.question = question; self.tool = tool; self.detail = detail; self.needKind = needKind
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        statusKey = try c.decodeIfPresent(String.self, forKey: .statusKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
        pane = try c.decodeIfPresent(String.self, forKey: .pane)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        builderId = try c.decodeIfPresent(String.self, forKey: .builderId)
        acked = try c.decodeIfPresent(Bool.self, forKey: .acked)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        updated = try c.decodeIfPresent(Double.self, forKey: .updated)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        needKind = try c.decodeIfPresent(String.self, forKey: .needKind)
        if let text = try? c.decodeIfPresent(String.self, forKey: .elapsed) { elapsed = text }
        else if let secs = try? c.decodeIfPresent(Double.self, forKey: .elapsed) { elapsed = Self.elapsedLabel(secs) }
        else { elapsed = nil }
    }

    /// 0...59 s -> "41s", under an hour -> "12m", otherwise "1h 2m".
    public static func elapsedLabel(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

public struct BuilderDetail: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var status: String
    public var acked: Bool
    public var canAck: Bool
    public var text: String
}

// MARK: Inbox, shots, clip

public struct InboxResponse: Codable, Equatable, Sendable { public var items: [InboxItem] }

/// `kind` is "text" or "file"; `preview` only exists for text items.
public struct InboxItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var size: Int
    public var created: Double?
    public var preview: String?
    /// "clipboardShare" on the one item the Mac auto-shares from its clipboard.
    public var source: String?
}

public struct ShotsResponse: Codable, Equatable, Sendable { public var shots: [Shot] }

/// `created` is ISO-8601; `w`/`h` are pixel sizes.
public struct Shot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var created: String
    public var kind: String
    public var w: Int
    public var h: Int
}

public struct DropResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var `where`: String?
    public var id: String?
    public var name: String?
}

// MARK: Command bar (route / slot / run / recent)

public struct RecentResponse: Codable, Equatable, Sendable { public var items: [String] }

public struct RouteOption: Codable, Equatable, Sendable { public var value: String; public var label: String }

public struct RouteInfo: Codable, Equatable, Sendable {
    public var text: String
    public var kind: String
    public var kindLabel: String
    public var project: String?
    public var target: String
    public var whereLabel: String
    public var model: String?
    public var effort: String?
    public var uncertain: [String]
    public var twoChoice: Bool
    public var dangerous: Bool
    public var typedOnly: Bool
    public var runnable: Bool

    enum CodingKeys: String, CodingKey {
        case text, kind, kindLabel, project, target, model, effort, uncertain, twoChoice, dangerous, typedOnly, runnable
        case whereLabel = "where"
    }
}

/// POST /api/route and POST /api/route/{id}/slot. The slot reply carries the same shape.
public struct RouteResponse: Codable, Equatable, Sendable {
    public var routeId: String?
    public var route: RouteInfo
    public var alternatives: [String]
    /// slot name ("kind", "project", "target", "model", "effort") -> the values the Mac will accept for it.
    public var candidates: [String: [RouteOption]]

    public var uncertain: [String] { route.uncertain }
    public var dangerous: Bool { route.dangerous }
    public var runnable: Bool { route.runnable }
    public var twoChoice: Bool { route.twoChoice }
}

/// POST /api/run. 200 -> `ok` with `pane` (a pane UUID) or `background` (a builder name).
/// 409 is NOT an error: `needsConfirm == true` with a `reason`; resend with confirmed: true.
public struct RunResponse: Codable, Equatable, Sendable {
    public var ok: Bool?
    public var pane: String?
    public var background: String?
    public var needsConfirm: Bool?
    public var reason: String?
}

// MARK: Tabs (GET /api/tabs)

public struct TabsResponse: Codable, Equatable, Sendable {
    public var tabs: [RemoteTab]
    public var now: Double?
}

public struct RemoteTab: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var selected: Bool
    public var panes: [RemotePane]
}

public struct RemotePane: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var cwd: String
    public var agent: String?
    public var needsYou: Bool
    public var busy: Bool
    public var live: Bool
    /// The pane runs Claude Code / a seat (Approve/Deny mean something). Older Macs omit it.
    public var claude: Bool
    /// Which repo / branch / session the pane is on. Older Macs omit all of these.
    public var repo: String?
    public var branch: String?
    public var worktree: Bool
    public var sessionID: String?
    /// One line on what the session is doing (handoff heading, else the opening prompt).
    public var topic: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, cwd, agent, needsYou, busy, live, claude, repo, branch, worktree, sessionID, topic
    }
    public init(id: String, title: String, cwd: String, agent: String?, needsYou: Bool, busy: Bool, live: Bool, claude: Bool = false,
                repo: String? = nil, branch: String? = nil, worktree: Bool = false, sessionID: String? = nil, topic: String? = nil) {
        self.id = id; self.title = title; self.cwd = cwd; self.agent = agent
        self.needsYou = needsYou; self.busy = busy; self.live = live; self.claude = claude
        self.repo = repo; self.branch = branch; self.worktree = worktree; self.sessionID = sessionID; self.topic = topic
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        cwd = try c.decode(String.self, forKey: .cwd)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        needsYou = try c.decode(Bool.self, forKey: .needsYou)
        busy = try c.decode(Bool.self, forKey: .busy)
        live = try c.decode(Bool.self, forKey: .live)
        claude = try c.decodeIfPresent(Bool.self, forKey: .claude) ?? (agent != nil)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        worktree = try c.decodeIfPresent(Bool.self, forKey: .worktree) ?? false
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
    }
}

/// What a composer request did, as the Mac's PaneDelivery reported it. Unknown strings decode to `.unknown`.
public enum InputOutcome: Equatable, Sendable {
    case landed, staged, unverified, stuckInComposer, noPane, promptGone
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "landed": self = .landed
        case "staged": self = .staged
        case "unverified": self = .unverified
        case "stuckInComposer": self = .stuckInComposer
        case "noPane": self = .noPane
        case "promptGone": self = .promptGone
        default: self = .unknown(wire)
        }
    }
}

/// What the phone should do with an outcome. Pure, so the doctrine is testable off-device.
public enum ComposerReaction: Equatable, Sendable {
    case nothing
    case toast(String)
    /// Put the text back in the field and say why.
    case restore(toast: String)
    case popPane(toast: String)
}

extension InputOutcome {
    public func reaction(for intent: PaneInputIntent) -> ComposerReaction {
        switch self {
        case .landed, .staged: return .nothing
        case .unverified: return intent == .prompt ? .toast("Sent") : .nothing
        case .stuckInComposer: return .restore(toast: "Didn't go through — try again or use Keys")
        case .noPane: return .popPane(toast: "Pane is gone")
        case .promptGone: return .toast("No prompt on screen")
        case .unknown: return intent == .prompt ? .toast("Sent") : .nothing
        }
    }
}

/// What the composer may ask a pane to do; raw values are the wire names.
public enum PaneInputIntent: String, Sendable, CaseIterable {
    case prompt, stage, control, submitOnly, approve, deny
}

struct PairResponse: Codable { var token: String?; var error: String? }

public extension HubRow {
    /// Belongs in "Needs you": a pane that is asking, or a failure nobody has acknowledged yet.
    /// An acked failure stays listed (the Mac keeps it 24 h) but is no longer anyone's problem.
    var needsAttention: Bool { statusKey == "needsYou" || (statusKey == "failed" && acked != true) }
}
