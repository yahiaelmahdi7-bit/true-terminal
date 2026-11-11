import Foundation

enum SeatProvider: String, Codable, CaseIterable, Sendable {
    case claude, codex
    var label: String { self == .claude ? "Claude" : "Codex" }
}

struct SeatCapabilities: Equatable, Codable, Sendable {
    enum Feature: String, Codable, CaseIterable, Sendable {
        case liveStatus, needsYou, answer, stopTurn, resume, failure, usageReset, overseer, modelChoice, handoff
        var label: String {
            switch self {
            case .liveStatus: return "Live status"
            case .needsYou: return "Shows when it needs you"
            case .answer: return "Answer from True"
            case .stopTurn: return "Stop the current turn"
            case .resume: return "Resume the same conversation"
            case .failure: return "Says when a turn failed"
            case .usageReset: return "Usage-limit reset time"
            case .overseer: return "Turn review"
            case .modelChoice: return "Model choice"
            case .handoff: return "Switch provider with context"
            }
        }
    }
    struct Row: Equatable, Codable, Sendable, Identifiable {
        let feature: Feature
        let supported: Bool
        let reason: String?
        let verified: Bool
        var id: Feature { feature }
        var label: String { feature.label }
        var note: String? { verified ? reason : "Checked on another Codex version" }
    }
    let rows: [Row]
    func supports(_ feature: Feature) -> Bool { rows.contains { $0.feature == feature && $0.supported && $0.verified } }
    static func make(_ provider: SeatProvider, verified: Bool = true) -> Self {
        Self(rows: Feature.allCases.map { feature in
            var reason: String?
            if feature == .handoff { reason = "Coming later" }
            if provider == .codex {
                switch feature {
                case .failure: reason = "Failed turns show as done"
                case .usageReset, .overseer: reason = "Not available for Codex"
                case .modelChoice: reason = "Your Codex default"
                default: break
                }
            }
            return Row(feature: feature, supported: reason == nil, reason: reason, verified: verified)
        })
    }
}

struct SeatScreen {
    var dialogVisible: (String) -> Bool
    var answerKeys: (approve: String, deny: String)
    var isBusy: (String) -> Bool
    var interruptKey: String
}

protocol SeatProviding {
    var kind: SeatProvider { get }
    var capabilities: SeatCapabilities { get }
    var screen: SeatScreen { get }
    /// Codex starts its session only after submission; Claude announces startup before submission.
    var startsOnFirstPrompt: Bool { get }
    func install(for agent: Agent, all: [Agent], paths: AgentPaths)
    func argv(for agent: Agent, paths: AgentPaths, resumeID: String?, initialPrompt: String?) -> [String]
    func shellCommand(argv: [String]) -> String
    func resumeID(for agent: Agent) -> String?
}

extension ClaudeSeat {
    var kind: SeatProvider { .claude }
    var capabilities: SeatCapabilities { .make(kind) }
    var startsOnFirstPrompt: Bool { false }
    var screen: SeatScreen {
        SeatScreen(dialogVisible: ClaudePermissionDialog.isVisible, answerKeys: ("1", "\u{1B}"),
                   isBusy: { $0.lowercased().contains("esc to interrupt") }, interruptKey: "\u{1B}")
    }
    func install(for agent: Agent, all: [Agent], paths: AgentPaths) { AgentHooks.installClaude(for: agent, all: all, paths: paths) }
    func argv(for agent: Agent, paths: AgentPaths, resumeID: String?, initialPrompt: String?) -> [String] {
        Self.argv(agent, paths: paths, resumeID: resumeID, initialPrompt: initialPrompt)
    }
    func shellCommand(argv: [String]) -> String { Self.shellCommand(argv: argv) }
    func resumeID(for agent: Agent) -> String? { Self.resumeID(for: agent, claudeDir: configDir) }
}

enum SeatStartupIssue: String, Equatable, Sendable {
    case hooksApproval, signIn
    var label: String {
        switch self {
        case .hooksApproval: return "Needs you: approve True's hooks in the pane"
        case .signIn: return "Sign in to Codex in the pane"
        }
    }
    static func detect(_ screen: String) -> Self? {
        if screen.contains("Hooks need review") { return .hooksApproval }
        if screen.contains("Welcome to Codex") && screen.contains("Sign in with ChatGPT") { return .signIn }
        return nil
    }
}

enum SeatProviders {
    static func `for`(_ agent: Agent, claudeDir: URL = AgentLaunch.claudeConfigDir,
                      codexDir: URL = CodexSeat.codexDir) -> any SeatProviding {
        switch agent.seatProvider {
        case .claude: return ClaudeSeat(configDir: claudeDir)
        case .codex: return CodexSeat(configDir: codexDir)
        }
    }
    static func implementation(_ provider: SeatProvider) -> any SeatProviding {
        switch provider { case .claude: return ClaudeSeat(); case .codex: return CodexSeat() }
    }
    /// One bounded version probe per application process. Discovery never writes Codex config.
    static let codexRuntime = CodexRuntime.inspect()
}

struct CodexRuntime: Equatable, Sendable {
    static let capturedVersion = "codex-cli 0.167.0"
    let installed: Bool
    let version: String?
    var verified: Bool { version == Self.capturedVersion }
    var capabilities: SeatCapabilities { .make(.codex, verified: installed && verified) }
    static func inspect(finder: ProgramFinder = .shared) -> Self {
        guard let path = finder.resolve("codex") else { return Self(installed: false, version: nil) }
        let out = ProgramFinder.run(path, ["--version"], ProcessInfo.processInfo.environment, 2)
        return Self(installed: true, version: out.flatMap { $0.status == 0 && !$0.timedOut ? $0.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil })
    }
    func disabledReason(for provider: SeatProvider, agent: Agent, awake: Bool) -> String? {
        if awake { return "Put the seat to sleep to switch" }
        if agent.duty != nil || agent.role == .watcher { return "Duty seats use Claude" }
        if provider == .codex && !installed { return "Codex is not installed" }
        return nil
    }
}
