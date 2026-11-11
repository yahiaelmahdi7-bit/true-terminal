import SwiftUI

/// What one provider's capability list shows in the editor, from the same `SeatCapabilities` that
/// `truectl status` prints. A row is "on" only when it is supported AND verified on this Codex version.
struct SeatCapabilityLine: Equatable, Identifiable {
    let feature: SeatCapabilities.Feature
    let label: String
    let on: Bool
    let note: String?
    var id: SeatCapabilities.Feature { feature }

    static func lines(_ caps: SeatCapabilities) -> [SeatCapabilityLine] {
        caps.rows.map { r in
            let on = r.supported && r.verified
            return SeatCapabilityLine(feature: r.feature, label: r.label, on: on, note: on || !r.verified ? nil : r.reason)
        }
    }
    /// One line for the whole list when this Codex version was never checked (instead of the same note on every row).
    static func versionNote(_ caps: SeatCapabilities) -> String? {
        caps.rows.contains { !$0.verified } ? "Not checked on your Codex version" : nil
    }
}

extension SeatRuntimeInfo {
    /// Same rule as `CodexRuntime.capabilities`: Codex rows count only on the Codex version they were checked on.
    func capabilities(for provider: SeatProvider) -> SeatCapabilities {
        provider == .claude ? .make(.claude)
            : .make(.codex, verified: installed && version == CodexRuntime.capturedVersion)
    }
}

/// Everything a Codex seat card says about its provider, as plain words. Pure, so stills and tests read one source.
struct SeatCardFacts: Equatable {
    var provider: SeatProvider
    var status: AgentStatus
    var capabilities: SeatCapabilities?
    var runtime: SeatRuntimeInfo?
    var issue: SeatStartupIssue?
    /// Set while the seat runs on its fallback (from `AgentRegistry.fallbackCards`). Shown verbatim.
    var fallback: FallbackCard?

    /// The mark beside the name: Codex only, Claude seats look as they always did.
    var markLabel: String? { provider == .codex ? "CODEX" : nil }
    /// Same rule as `AgentRegistry.canStopTurn`.
    var showsStop: Bool { status == .working && capabilities?.supports(.stopTurn) == true }
    /// "Use Claude": only while the seat runs on its fallback.
    var useOriginalText: String? { fallback?.buttonText }
    /// One plain line, most urgent first. Unknown sign-in is never shown as signed in, and is only
    /// mentioned while the seat sleeps (the moment it matters); a running seat that works needs no caveat.
    var lifecycle: String? {
        if let fallback { return fallback.text }
        // Claude cards stay as they were, except for the one limit line (same words and builder as Codex's).
        if provider == .claude { return status == .working ? nil : runtime?.limitLabel }
        guard provider == .codex else { return nil }
        if let issue, status == .needsYou { return issue.card }
        guard let rt = runtime else { return nil }
        if !rt.installed { return "Codex not installed" }
        if rt.signIn == .notSignedIn { return "Not signed in to Codex" }
        if let limit = rt.limitLabel { return limit }
        if rt.signIn == .unknown && status == .asleep { return "Codex sign-in not checked" }
        return nil
    }
}

extension SeatStartupIssue {
    /// Short card wording (the pane banner keeps the longer one).
    var card: String {
        switch self {
        case .hooksApproval: return "Approve True's hooks"
        case .signIn: return "Sign in to Codex"
        }
    }
}

/// A small mono tag, not a brand colour: True is black and white.
struct ProviderMark: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced).weight(.medium)).tracking(0.6)
            .foregroundStyle(Theme.hubSecondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hubCardStroke, lineWidth: 1))
            .accessibilityLabel("Runs on \(label.capitalized)")
    }
}

/// The footer of a seat card: lifecycle words on the left, Stop turn while Working on the right.
struct SeatCardFooter: View {
    let facts: SeatCardFacts
    let stop: () -> Void
    var useOriginal: () -> Void = {}
    var body: some View {
        if facts.lifecycle != nil || facts.showsStop || facts.useOriginalText != nil {
            HStack(spacing: 8) {
                if let line = facts.lifecycle {
                    Text(line).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let text = facts.useOriginalText {
                    Button(action: useOriginal) {
                        Text(text).font(.callout.weight(.medium))
                            .padding(.horizontal, 12).frame(minHeight: Theme.Hit.control - 8)
                            .overlay(Capsule().strokeBorder(Theme.Veil.edgeOn, lineWidth: 1))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(PillButtonStyle(shape: Capsule(), rest: Theme.text, hover: Theme.text))
                    .help("End this session; the seat wakes again on its own provider.")
                }
                if facts.showsStop {
                    Button(action: stop) {
                        Text("Stop turn").font(.callout.weight(.medium))
                            .padding(.horizontal, 12).frame(minHeight: Theme.Hit.control - 8)
                            .overlay(Capsule().strokeBorder(Theme.Veil.edgeOn, lineWidth: 1))
                            .contentShape(.capsule)
                    }
                    .buttonStyle(PillButtonStyle(shape: Capsule(), rest: Theme.text, hover: Theme.text))
                    .help("Interrupt this turn. The conversation stays.")
                }
            }
        }
    }
}

/// Seat editor section: Claude | Codex, its one-line reason when locked, and the honest capability list.
struct SeatProviderSection: View {
    @Binding var provider: SeatProvider
    /// Why the control is locked (awake, duty seat, Codex missing); nil = free to switch.
    let lockedReason: String?
    /// nil while the Codex probe is still running.
    let runtime: SeatRuntimeInfo?
    /// The Account row, directly under the Provider control. nil = not shown (duty seats, old callers).
    var accountRow: AnyView?

    var body: some View {
        Section("Runs on") {
            Picker("Provider", selection: $provider) {
                ForEach(SeatProvider.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(lockedReason != nil)
            if let accountRow { accountRow }
            VStack(alignment: .leading, spacing: 6) {
            if let lockedReason {
                Text(lockedReason).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 4)
            }
            if provider == .codex && runtime == nil {
                Text("Checking Codex…").font(.footnote).foregroundStyle(.secondary)
            } else {
                let caps = (runtime ?? SeatRuntimeInfo(installed: true)).capabilities(for: provider)
                if let note = SeatCapabilityLine.versionNote(caps) {
                    Text(note).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 4)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(SeatCapabilityLine.lines(caps)) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: line.on ? "circle.fill" : "circle")
                                .font(.caption2).imageScale(.small).foregroundStyle(line.on ? Color.primary : Color.secondary)
                                .frame(width: 10)
                            Text(line.label).font(.callout).foregroundStyle(line.on ? Color.primary : Color.secondary)
                            if let note = line.note {
                                Spacer(minLength: 6)
                                Text(note).font(.caption).foregroundStyle(Color.secondary).multilineTextAlignment(.trailing)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(line.on ? line.label : "\(line.label), not available. \(line.note ?? "")")
                    }
                }
                .padding(.vertical, 2)
            }
            }
        }
    }
}
