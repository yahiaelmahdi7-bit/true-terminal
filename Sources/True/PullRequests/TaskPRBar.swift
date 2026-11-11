import SwiftUI

/// Plain words for the task screen's PR line. Nothing here is a code, id or raw error.
enum TaskPRCopy {
    static let createPR = "Create PR", merge = "Merge", hold = "Hold", release = "Release", runGate = "Run gate"
    static let held = "Held"
    static let signIn = "Sign in to GitHub"
    static func pr(_ number: Int) -> String { "PR #\(number)" }
    /// "Gate running… 1:05"
    static func gateRunning(_ seconds: Int) -> String { "Gate running… \(seconds / 60):" + String(format: "%02d", seconds % 60) }
    static let gateFailed = "The gate failed."
    /// "Merged PR #42." plus the local-main note when there is one ("Local main not updated (…)").
    static func merged(_ number: Int, local: String?) -> String {
        let head = "Merged PR #\(number)."
        guard let local, !local.isEmpty else { return head }
        let tail = local.hasPrefix("Merged. ") ? String(local.dropFirst("Merged. ".count)) : local
        return head + " " + tail
    }
    /// The merge rule's sentence as written, unless the gate file's reason is raw tool text
    /// (a path, an error dump, a long line): then only "The gate failed." The full text stays in the gate log.
    static func plain(_ note: String) -> String {
        let prefix = "The gate failed: "
        guard note.hasPrefix(prefix) else { return note }
        let why = note.dropFirst(prefix.count)
        let raw = why.count > 60 || why.contains(where: { "\n/\\{}[]()<>=`$|".contains($0) })
            || why.range(of: "error", options: .caseInsensitive) != nil || why.range(of: "exit", options: .caseInsensitive) != nil
        return raw ? gateFailed : note
    }
}

/// The one button on the line that gets the strong fill: the next useful step, never a disabled one.
enum TaskPRPrimary: Equatable, Sendable { case create, merge, release, runGate, signIn, none }

/// What the PR line on the task screen shows. Pure: every rule comes from the merge core
/// (`prMergeCheck`) and the gate reader (`GateReader.word`); this struct only reads their answers.
struct TaskPRState: Equatable, Sendable {
    var gate: GateWord
    var prNumber: Int?
    var held: Bool
    var signedIn: Bool
    /// Seconds since a gate run started; nil = none running.
    var gateRunningFor: Int?
    /// The merge rule said yes.
    var canMerge: Bool
    /// One short plain line under the buttons (why Merge is off, or "A gate is already running.").
    var note: String?
    /// The line could not be read (GitHub CLI missing, no network): this plain sentence replaces the whole line.
    var problem: String? = nil

    var hasPR: Bool { prNumber != nil }
    /// "Not signed in to GitHub." replaces the whole line; the PR buttons are not shown.
    var showsPRControls: Bool { signedIn && problem == nil }
    var showsSignIn: Bool { !signedIn && problem == nil }
    var showsCreate: Bool { showsPRControls && !hasPR }
    var showsMerge: Bool { showsPRControls && hasPR }
    var mergeEnabled: Bool { showsMerge && canMerge && !held }
    var holdLabel: String { held ? TaskPRCopy.release : TaskPRCopy.hold }
    /// Off while a gate runs; the elapsed time already says why.
    var gateButtonEnabled: Bool { gateRunningFor == nil }
    var primary: TaskPRPrimary {
        if problem != nil { return .none }
        if !signedIn { return .signIn }
        if showsCreate { return .create }
        if mergeEnabled { return .merge }
        if held { return .release }
        return gateButtonEnabled ? .runGate : .none
    }

    /// Everything a person can read on the line, in order (the tests check it for raw names).
    var visibleStrings: [String] {
        if let problem { return [problem] }
        guard signedIn else { return [PRCopy.signedOut, TaskPRCopy.signIn] }
        var out = [gate.rawValue]
        if let n = prNumber { out.append(TaskPRCopy.pr(n)) }
        if held { out.append(TaskPRCopy.held) }
        if let s = gateRunningFor { out.append(TaskPRCopy.gateRunning(s)) }
        out.append(contentsOf: showsCreate ? [TaskPRCopy.createPR] : [TaskPRCopy.merge, holdLabel, TaskPRCopy.runGate])
        if let note { out.append(note) }
        return out
    }

    /// Builds the line from the cores' own answers. `facts` = nil when there is no PR.
    /// Merge is allowed only when `prMergeCheck` returns `.merge`; its refusal text is shown as written.
    static func make(signedIn: Bool, headSha: String, commits: [String], facts: PRFacts?, gatedSha: String,
                     gates: GateReader = GateReader(), hold: HoldEntry?, gateRunningFor: Int? = nil,
                     gateBusyClicked: Bool = false) -> TaskPRState {
        let word = gates.word(head: headSha, commits: commits)
        // While a gate runs the elapsed time is the whole story: no refusal line under it.
        let busyNote = gateBusyClicked && gateRunningFor == nil ? PRGate.busy : nil
        guard let facts else {
            return TaskPRState(gate: word, prNumber: nil, held: false, signedIn: signedIn, gateRunningFor: gateRunningFor,
                               canMerge: false, note: busyNote)
        }
        let gate = gates.result(facts.headSha)
        let verdict = prMergeCheck(facts: facts, gatedSha: gatedSha, gate: gate,
                                   runFileOK: gate.map(gates.runFileOK) ?? false, held: hold)
        var note: String?
        var ok = false
        switch verdict {
        case .merge: ok = true
        case .refuse(let reason): note = TaskPRCopy.plain(reason)
        }
        if gateRunningFor != nil { note = nil } else if let busyNote { note = busyNote }
        return TaskPRState(gate: word, prNumber: facts.number, held: hold != nil, signedIn: signedIn,
                           gateRunningFor: gateRunningFor, canMerge: ok, note: note)
    }
}

/// The gate / PR line and its buttons, on the task screen for a branch that is not main.
struct TaskPRBar: View {
    let state: TaskPRState
    var onCreate: () -> Void = {}
    var onMerge: () -> Void = {}
    var onHold: () -> Void = {}
    var onRunGate: () -> Void = {}
    var onSignIn: () -> Void = {}

    private func ink(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem = state.problem {
                Text(problem).font(ink(13)).foregroundStyle(Theme.Token.text1).fixedSize(horizontal: false, vertical: true)
            } else if !state.signedIn {
                Text(PRCopy.signedOut).font(ink(13)).foregroundStyle(Theme.Token.text1)
                HStack(spacing: 8) {
                    button(TaskPRCopy.signIn, primary: true, action: onSignIn)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Text(state.gate.rawValue).font(ink(15, .semibold)).foregroundStyle(Theme.Token.text0)
                    if let n = state.prNumber {
                        Text(TaskPRCopy.pr(n)).font(ink(13)).monospacedDigit().foregroundStyle(Theme.Token.text1)
                    }
                    if state.held {
                        Text(TaskPRCopy.held).font(ink(12, .medium)).foregroundStyle(Theme.Token.text0)
                            .padding(.horizontal, 9).frame(height: 20)
                            .background(Capsule().fill(Theme.Token.line))
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                    if let s = state.gateRunningFor {
                        Text(TaskPRCopy.gateRunning(s)).font(ink(13)).monospacedDigit()
                            .foregroundStyle(Theme.Token.text1)
                    }
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 8) {
                    if state.showsCreate {
                        button(TaskPRCopy.createPR, primary: state.primary == .create, action: onCreate)
                    } else {
                        button(TaskPRCopy.merge, primary: state.primary == .merge, enabled: state.mergeEnabled, action: onMerge)
                        button(state.holdLabel, primary: state.primary == .release, action: onHold)
                    }
                    button(TaskPRCopy.runGate, primary: state.primary == .runGate, enabled: state.gateButtonEnabled, action: onRunGate)
                    Spacer(minLength: 0)
                }
                if let note = state.note {
                    Text(note).font(ink(13)).foregroundStyle(Theme.Token.text1).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Token.bg3.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func button(_ title: String, primary: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(ink(13, .medium)).padding(.horizontal, 12).frame(height: 28)
        }
        .buttonStyle(PillButtonStyle(shape: Capsule(), rest: Theme.Token.text0, hover: Theme.Token.text0,
                                     fill: primary ? Theme.Token.strongLine : Theme.Token.line,
                                     hoverFill: Theme.Token.text3.opacity(Theme.Alpha.strongLine)))
        .disabled(!enabled).opacity(enabled ? 1 : Theme.Alpha.disabled + 0.1)
    }
}
