import SwiftUI

extension AgentModel {
    /// Tier as brightness — True is black and white only: the heavier the model, the whiter.
    var tint: Color {
        switch self {
        case .haiku: return Color(white: 0.55)
        case .sonnet: return Color(white: 0.70)
        case .opus: return Color(white: 0.85)
        case .fable: return Color(white: 1.0)
        }
    }
}

extension AgentStatus {
    var tint: Color {
        switch self {
        case .asleep: return Color(white: 0.25)
        case .idle: return Color(white: 0.45)
        case .working: return Color(white: 0.90)
        case .needsYou: return Color(white: 1.0)
        case .done: return Color(white: 0.65)
        case .failed: return Color(white: 0.55)
        }
    }
}

/// Five lit/unlit bars — the effort level at a glance.
struct EffortMeter: View {
    let level: Int
    let tint: Color
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Capsule().fill(i <= level ? tint : Color.primary.opacity(0.15))
                    .frame(width: 3, height: 3 + CGFloat(i) * 1.6)
            }
        }
        .frame(height: 11, alignment: .bottom)
        .accessibilityLabel("Effort \(level) of 5")
    }
}

struct StatusPill: View {
    let status: AgentStatus
    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(status.tint.opacity(0.22), in: .capsule)
            .foregroundStyle(status == .asleep ? Color.secondary : status.tint)
    }
}

/// The attention pill on a seat card: only for the two states that want a human. Inverted (white on
/// black text) for needsYou so it is the loudest thing in the panel without using colour.
struct AttentionPill: View {
    let status: AgentStatus
    var body: some View {
        if status == .needsYou {
            Text(status.label).font(.caption.weight(.semibold)).foregroundStyle(.black)
                .padding(.horizontal, 8).padding(.vertical, 2).background(.white, in: .capsule)
        } else if status == .failed {
            Text(status.label).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
    }
}

/// Everything a seat card needs from the registry, as closures — the seam that lets the Hub render from
/// fixtures (snapshot tests) while production passes `.live(registry)` and behaves exactly as before.
struct SeatActions {
    var status: (String) -> AgentStatus
    var isAwake: (String) -> Bool
    var wake: (String) -> Void
    var sleep: (String) -> Void
    var edit: (Agent) -> Void
    var talk: (String, String, @escaping (PaneDelivery.Outcome) -> Void) -> Void
    /// Overseer verdict for a seat by name; nil = none.
    var verdict: (String) -> VerdictKind? = { _ in nil }

    @MainActor static func live(_ r: AgentRegistry) -> SeatActions {
        SeatActions(status: { r.statusOf($0) }, isAwake: { r.isAwake($0) }, wake: { r.wake($0) },
                    sleep: { r.sleep($0) }, edit: { r.builder = BuilderDraft(editing: $0) },
                    talk: { name, text, done in r.talk(name, text, onOutcome: done) },
                    verdict: { n in OverseerStore.shared.verdict(forSession: r.agent(named: n)?.lastSessionID)?.kind })
    }

    static var inert: SeatActions { SeatActions(status: { _ in .asleep }, isAwake: { _ in false }, wake: { _ in },
                                   sleep: { _ in }, edit: { _ in }, talk: { _, _, _ in }) }
}

/// A seat card — the ONLY container in the Hub. Tap wakes / focuses; sleep and edit appear on hover and
/// are also in the context menu and as accessibility actions, so nothing is hover-only.
struct AgentCard: View {
    let agent: Agent
    let actions: SeatActions
    /// Fixture hook: render the hover state (snapshots can't hover).
    var forceHover = false
    @State private var message = ""
    @State private var note: String?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = actions.status(agent.name)
        let awake = actions.isAwake(agent.name)
        let showActions = hovering || forceHover
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AgentAvatar(hue: agent.resolvedHue, symbol: agent.symbol, status: status, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(agent.name).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        HStack(spacing: 2) {
                            iconButton(awake ? "moon.zzz" : "sun.max", awake ? "Sleep" : "Wake") { toggle(awake) }
                            iconButton("slider.horizontal.3", "Edit") { actions.edit(agent) }
                        }
                        .opacity(showActions ? 1 : 0).allowsHitTesting(showActions).accessibilityHidden(true)
                        // A live Needs you pill already says "look here"; a second badge would repeat it.
                        if status != .needsYou, let v = actions.verdict(agent.name) { VerdictBadge(kind: v) }
                        AttentionPill(status: status)
                    }
                    HStack(spacing: 6) {
                        Text(agent.model.label)
                        Text("·").foregroundStyle(Theme.hubSecondary.opacity(0.6))
                        Label(agent.permission.label, systemImage: agent.permission.symbol).labelStyle(.titleAndIcon)
                        EffortMeter(level: agent.effort.level, tint: Theme.hubSecondary).padding(.leading, 2)
                        Spacer(minLength: 0)
                        if status != .needsYou && status != .failed {
                            Text(status.label).contentTransition(.opacity)
                        }
                    }
                    .font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1)
                }
            }
            if agent.role != .helper { messageField }
        }
        .padding(14)
        .background(Theme.hubCardFill, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hubCardStroke, lineWidth: 1))
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        .onTapGesture { actions.wake(agent.name) }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showActions)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: status)
        .help(awake ? "Focus its tab" : "Wake \(agent.name)")
        .contextMenu {
            Button(awake ? "Sleep" : "Wake") { toggle(awake) }
            Button("Edit…") { actions.edit(agent) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent.name), \(agent.model.label), effort \(agent.effort.level) of 5, \(agent.permission.label), \(status.label)")
        .accessibilityAction(named: awake ? "Sleep" : "Wake") { toggle(awake) }
        .accessibilityAction(named: "Edit") { actions.edit(agent) }
    }

    private func toggle(_ awake: Bool) { awake ? actions.sleep(agent.name) : actions.wake(agent.name) }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 24, height: 24).contentShape(.circle)
        }
        .buttonStyle(.borderless).help(help)
    }

    /// iMessage-style: a plain field in a capsule; the send arrow only exists once there is text.
    private var messageField: some View {
        HStack(spacing: 6) {
            TextField("Message \(agent.name)…", text: $message)
                .textFieldStyle(.plain).font(.body).onSubmit(send)
            if let note { Text(note).font(.callout).foregroundStyle(Theme.hubSecondary).lineLimit(1) }
            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(.white)
                }
                .buttonStyle(.plain).help("Send").transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 32)
        .background(Color.white.opacity(0.06), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.hubCardStroke, lineWidth: 1))
        .animation(reduceMotion ? nil : .snappy, value: message.isEmpty)
    }

    private func send() {
        let text = message
        message = ""
        note = actions.isAwake(agent.name) ? nil : "waking…"
        actions.talk(agent.name, text) { outcome in
            Task { @MainActor in
                switch outcome {
                case .landed, .staged: note = nil
                case .unverified: note = "sent — not confirmed"
                case .stuckInComposer: note = "still in the composer"
                case .noPane, .promptGone: note = "couldn't deliver"
                }
            }
        }
    }
}
