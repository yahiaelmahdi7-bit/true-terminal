import Foundation
import CryptoKit

/// What the phone's ⌘K needs from the Mac. A protocol so the whole proposal/confirm/rate-limit logic is tested with fakes;
/// the live version (RemoteCommandsLive) hops to the main actor.
protocol RemoteCommands: Sendable {
    func environment() -> BarEnvironment
    func isExecutable(_ name: String) -> Bool
    var jevEnabled: Bool { get }
    /// One Jev read for the route (nil = Jev down or timed out → the deterministic route, as on the Mac).
    func jev(text: String, context: CommandContext, rule: RuleMatch?) -> JevReply?
    func launch(_ plan: Plan, route: Route) -> RemoteLaunch
    func history() -> [String]
    func pushHistory(_ text: String)
    func hubJSON() -> Data
    func builderDetail(id: String) -> Data?
    func ackBuilder(id: String) -> Bool
    func record(_ line: [String: Any])
    /// Phone-started background builders still running (or just launched and not on the Hub yet).
    func phoneBuildersRunning() -> Int
    func markPhoneBuilder(_ name: String)
    func seatIsWorking(_ name: String) -> Bool
}

enum RemoteLaunch: Equatable, Sendable {
    case pane(UUID), background(String), done, failed(String)
}

/// One proposal, held server-side. The phone only ever holds its random id.
struct RemoteRouteEntry {
    var device: UUID
    var text: String
    var route: Route
    var context: CommandContext
    var created: Date
    var armed = false
}

enum RemoteRunResult: Equatable {
    case ok(RemoteLaunch)
    case needsConfirm(String)
    case refused(String)
    case rateLimited
    case tooManyBuilders
    case gone
}

/// The phone's ⌘K: the server proposes (CommandRules → Jev picks among code-built candidates → CommandRouter), the phone
/// edits slots from the server's own candidate lists and taps Run. routeIds are random, single-use, 2 min, per device.
/// There is no way to submit a raw command or a route payload: `run` takes an id and nothing else.
final class RemoteBar: @unchecked Sendable {
    static let expiry: TimeInterval = 120
    static let maxRunsPerMinute = 10
    static let maxProposalsPerMinute = 30
    static let maxText = 4000
    static let maxPhoneBuilders = 3
    static let backgroundConfirm = "background_builder"

    private let commands: RemoteCommands
    private let lock = NSLock()
    private var entries: [String: RemoteRouteEntry] = [:]
    private var runStamps: [UUID: [Date]] = [:]
    private var proposalStamps: [UUID: [Date]] = [:]

    init(commands: RemoteCommands) { self.commands = commands }

    /// nil if the system random source fails: no route is created without real randomness.
    static func newID() -> String? {
        var b = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { return nil }
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fresh(_ stamps: inout [UUID: [Date]], _ device: UUID, now: Date) -> [Date] {
        let v = (stamps[device] ?? []).filter { now.timeIntervalSince($0) < 60 }
        stamps[device] = v
        return v
    }

    private func sweep(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.created) < Self.expiry }
    }

    // MARK: Propose

    /// Tab is the only control character allowed; a line break would act as Enter in a shell.
    static func isSingleLine(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }
    }

    /// nil = rate limited, bad text (see `isSingleLine`), or no randomness. Never runs anything.
    func propose(device: UUID, text raw: String, now: Date = Date()) -> (id: String, entry: RemoteRouteEntry)? {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxText))
        guard !text.isEmpty, Self.isSingleLine(text) else { return nil }
        lock.lock()
        sweep(now: now)
        var stamps = fresh(&proposalStamps, device, now: now)
        guard stamps.count < Self.maxProposalsPerMinute else { lock.unlock(); return nil }
        stamps.append(now); proposalStamps[device] = stamps
        lock.unlock()

        let env = commands.environment()
        // The phone never aims at "the pane the Mac is looking at": the context has no focused pane.
        let ctx = CommandContext(focused: FocusedPane(kind: .empty, project: nil, seat: nil, cwd: nil),
                                 projects: CommandRouter.candidates(text: text, projects: env.projects, recent: env.recent),
                                 seats: env.seats, all: env.projects)
        let rule = CommandRules.match(text, projects: env.projects, seats: env.seats, recent: env.recent,
                                      isExecutable: { self.commands.isExecutable($0) })
        var reply: JevReply?
        if commands.jevEnabled, !(rule?.kind == .trueAction && rule?.authoritative == true) {
            reply = commands.jev(text: text, context: ctx, rule: rule)
        }
        let route = CommandRouter.route(text: text, reply: reply, context: ctx, rule: rule)
        let entry = RemoteRouteEntry(device: device, text: text, route: route, context: ctx, created: now)
        guard let id = Self.newID() else { return nil }
        lock.lock(); entries[id] = entry; lock.unlock()
        commands.record(["event": "propose", "device": device.uuidString, "textHash": Self.hash(text),
                         "route": Self.summary(route), "at": ISO8601DateFormatter().string(from: now)])
        return (id, entry)
    }

    func entry(_ id: String, device: UUID, now: Date = Date()) -> RemoteRouteEntry? {
        lock.lock(); defer { lock.unlock() }
        sweep(now: now)
        guard let e = entries[id], e.device == device else { return nil }
        return e
    }

    // MARK: Candidates & slots

    struct Option: Equatable { var value: String; var label: String }
    static let slots = ["kind", "project", "target", "model", "effort"]

    static func kindLabel(_ k: CommandKind) -> String {
        switch k {
        case .shellCommand: "Shell command"
        case .agentTask: "Agent task"
        case .questionForClaude: "Question"
        case .trueAction: "True action"
        case .none: "Nothing"
        }
    }

    /// The only values each chip's picker may offer, and the only ones `setSlot` accepts.
    static func candidates(_ e: RemoteRouteEntry) -> [String: [Option]] {
        let r = e.route
        var kinds = ([r.kind] + r.alternatives).filter { $0 != .none }
        if r.twoChoice { for k in [CommandKind.shellCommand, .agentTask] where !kinds.contains(k) { kinds.append(k) } }
        var out: [String: [Option]] = [:]
        out["kind"] = kinds.map { Option(value: $0.rawValue, label: kindLabel($0)) }
        guard r.kind != .trueAction else { return out }
        out["project"] = [Option(value: "current", label: "No project")] + e.context.all.map { Option(value: $0.name, label: $0.name) }
        if r.kind.sendsToClaude {
            var t = [Option(value: "new_claude_pane", label: "New pane"), Option(value: "background_builder", label: "Background")]
            let project = r.project?.name
            for s in e.context.seats where project == nil || s.project == project {
                t.append(Option(value: "seat_\(s.name)", label: "Seat \(s.name)"))
            }
            out["target"] = t
            out["model"] = [Option(value: "default", label: "Default")] + AgentModel.allCases.map { Option(value: $0.rawValue, label: $0.label) }
            out["effort"] = [Option(value: "default", label: "Default")] + AgentEffort.allCases.map { Option(value: $0.rawValue, label: $0.label) }
        }
        return out
    }

    enum SlotResult { case ok(RemoteRouteEntry), gone, invalid }

    func setSlot(_ id: String, device: UUID, slot: String, value: String, now: Date = Date()) -> SlotResult {
        lock.lock(); defer { lock.unlock() }
        sweep(now: now)
        guard var e = entries[id], e.device == device else { return .gone }
        guard Self.candidates(e)[slot]?.contains(where: { $0.value == value }) == true else { return .invalid }
        var r = e.route
        switch slot {
        case "kind":
            guard let k = CommandKind(rawValue: value) else { return .invalid }
            r = CommandRouter.switching(r, to: k, context: e.context)
        case "project":
            r.project = value == "current" ? nil : e.context.all.first { $0.name == value }
            r.uncertain.remove(.project)
            if case .seat(let n) = r.target, let p = r.project, e.context.seats.first(where: { $0.name == n })?.project != p.name {
                r.target = .newClaudePane; r.seat = nil
            }
        case "target":
            guard let t = CommandTarget(id: value) else { return .invalid }
            r.target = t
            if case .seat(let n) = t { r.seat = n } else { r.seat = nil }
            r.uncertain.remove(.target)
        case "model": r.model = AgentModel(rawValue: value)
        case "effort": r.effort = AgentEffort(rawValue: value)
        default: return .invalid
        }
        e.route = r
        e.armed = false      // any edit re-asks the danger gate
        entries[id] = e
        return .ok(e)
    }

    // MARK: Run

    /// Doors the phone may open. Everything lands as a normal, visible tab on the Mac; nothing types into an existing pane.
    static func allowed(_ door: Plan.Door) -> Bool {
        switch door {
        case .newShellSplit, .newClaudePane, .seat, .background: true
        case .trueAction(let a): [.openProject, .newTab, .wakeSeat, .sleepSeat].contains(a)
        case .typeInFocusedShell, .writeToFocusedClaude, .nothing: false
        }
    }

    func run(_ id: String, device: UUID, background: Bool, confirm: Bool, now: Date = Date()) -> RemoteRunResult {
        lock.lock()
        sweep(now: now)
        guard var e = entries[id], e.device == device else { lock.unlock(); return .gone }
        var stamps = fresh(&runStamps, device, now: now)
        guard stamps.count < Self.maxRunsPerMinute else { lock.unlock(); return .rateLimited }
        let r = e.route
        let plan = CommandExecutor.plan(route: r, background: background, context: e.context, stamp: Int(now.timeIntervalSince1970),
                                        fromPhone: true)
        guard !r.twoChoice, Self.allowed(plan.door) else { lock.unlock(); return .refused("Nothing to run from the phone") }
        var building = false
        if case .background = plan.door { building = true }
        if building, commands.phoneBuildersRunning() >= Self.maxPhoneBuilders { lock.unlock(); return .tooManyBuilders }
        // Fail closed from the phone: a Claude task Jev never judged, or text the danger list flags, asks first.
        var why: String?
        if plan.needsSecondReturn { why = r.dangerTop ?? "destructive" }
        else if building { why = Self.backgroundConfirm }
        else if r.kind.sendsToClaude && r.destructive == nil { why = "unjudged" }
        else if CommandRules.isDangerous(e.text) { why = "dangerous_text" }
        else if case .trueAction(.sleepSeat) = plan.door, let n = plan.argv.first, commands.seatIsWorking(n) { why = "seat_working" }
        if let why, !(e.armed && confirm) {
            e.armed = true; entries[id] = e
            lock.unlock()
            return .needsConfirm(why)
        }
        entries[id] = nil                       // single use
        stamps.append(now); runStamps[device] = stamps
        lock.unlock()

        let result = commands.launch(plan, route: r)
        if building, case .background(let name, _, _) = plan.door { commands.markPhoneBuilder(name) }
        commands.pushHistory(e.text)
        var res = "ok"
        if case .failed(let why) = result { res = "failed: \(why)" }
        commands.record(["event": "run", "device": device.uuidString, "textHash": Self.hash(e.text),
                         "route": Self.summary(r), "door": Self.doorName(plan.door), "background": background,
                         "result": res, "at": ISO8601DateFormatter().string(from: now)])
        if case .failed(let why) = result { return .refused(why) }
        return .ok(result)
    }

    /// The door's case name only: the associated values carry builder names and paths, which stay out of the log.
    static func doorName(_ d: Plan.Door) -> String {
        switch d {
        case .typeInFocusedShell: "typeInFocusedShell"
        case .newShellSplit: "newShellSplit"
        case .writeToFocusedClaude: "writeToFocusedClaude"
        case .newClaudePane: "newClaudePane"
        case .seat: "seat"
        case .background: "background"
        case .trueAction: "trueAction"
        case .nothing: "nothing"
        }
    }

    // MARK: JSON

    static func summary(_ r: Route) -> String {
        "kind=\(r.kind.rawValue) project=\(r.project?.name ?? "-") target=\(r.target.id) action=\(r.action.rawValue) "
            + "model=\(r.model?.rawValue ?? "-") effort=\(r.effort?.rawValue ?? "-")"
    }

    static func whereLabel(_ r: Route, plan: Plan) -> String {
        switch plan.door {
        case .newShellSplit: "New shell pane"
        case .newClaudePane: "New pane"
        case .seat(let n): "Seat \(n)"
        case .background: "Background"
        case .trueAction(let a): a.rawValue.replacingOccurrences(of: "_", with: " ")
        default: "-"
        }
    }

    static func routeJSON(id: String, _ e: RemoteRouteEntry) -> [String: Any] {
        let r = e.route
        let plan = CommandExecutor.plan(route: r, background: false, context: e.context, fromPhone: true)
        func opts(_ o: [Option]?) -> [[String: String]] { (o ?? []).map { ["value": $0.value, "label": $0.label] } }
        let cands = candidates(e)
        return [
            "routeId": id,
            "route": [
                "text": r.text, "kind": r.kind.rawValue, "kindLabel": kindLabel(r.kind),
                "project": r.project?.name ?? NSNull(), "target": r.target.id, "where": whereLabel(r, plan: plan),
                "model": r.model?.rawValue ?? NSNull(), "effort": r.effort?.rawValue ?? NSNull(),
                "uncertain": r.uncertain.map(\.rawValue).sorted(), "twoChoice": r.twoChoice,
                "dangerous": plan.needsSecondReturn, "typedOnly": plan.door != .nothing && !plan.autoSubmit,
                "runnable": allowed(plan.door) && !r.twoChoice,
            ] as [String: Any],
            "alternatives": r.alternatives.map(\.rawValue),
            "candidates": Dictionary(uniqueKeysWithValues: cands.map { ($0.key, opts($0.value)) }),
        ]
    }
}
