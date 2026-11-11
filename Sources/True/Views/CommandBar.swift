import SwiftUI

/// Isolates the bar's observation so opening it never re-evaluates the whole window body.
struct CommandBarHost: View {
    private let store = CommandBarStore.shared
    var body: some View {
        Group { if store.isOpen { CommandBarView(store: store) } }
            .motion(.panel, value: store.isOpen)
    }
}

/// ⌘K: one text field, one quiet line that says where Return will send it.
struct CommandBarView: View {
    @Bindable var store: CommandBarStore
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(Theme.Alpha.scrim)
                .contentShape(Rectangle())
                .onTapGesture { store.close() }
            card
                .frame(width: 640)
                .padding(.top, 110)
                // Slide-and-fade normally; a plain crossfade under Reduce Motion.
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -Theme.Space.s2)))
        }
        .transition(.opacity)
    }

    private var card: some View {
        CommandBarCard(text: $store.text, route: store.route, plan: store.plan, reading: store.reading, armed: store.armed,
                       focus: $focused, submit: { store.run() }, up: { store.historyUp() }, down: { store.historyDown() },
                       tab: { store.takeRunnerUp() }, choose: { store.choose($0) })
            .background {
                Button("") { store.run(background: true) }.keyboardShortcut(.return, modifiers: .command)
                Button("") { store.close() }.keyboardShortcut(.cancelAction)
            }
    }
}

/// The card itself, free of the store so snapshots can render it from fixtures.
struct CommandBarCard: View {
    @Binding var text: String
    var route: Route?
    var plan: Plan?
    var reading = false
    var armed = false
    var focus: FocusState<Bool>.Binding
    var submit: () -> Void = {}
    var up: () -> Void = {}
    var down: () -> Void = {}
    var tab: () -> Void = {}
    var choose: (CommandKind) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            field
            if route != nil || reading {
                Rectangle().fill(Theme.Token.line).frame(height: 1)
                RouteLine(route: route, plan: plan, reading: reading, armed: armed, choose: choose, cycle: tab)
                    .padding(.horizontal, Theme.Space.s4).padding(.vertical, Theme.Space.s3)
            }
        }
        .floatingCardSurface()
    }

    private var field: some View {
        HStack(spacing: Theme.Space.s3) {
            Image(systemName: "chevron.right").font(Theme.Fonts.h3).foregroundStyle(Theme.Token.text2)
            TextField("Run, ask, or tell True…", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.h3)
                .foregroundStyle(Theme.Token.text0)
                .focused(focus)
                .onSubmit(submit)
                .onKeyPress(.upArrow) { up(); return .handled }
                .onKeyPress(.downArrow) { down(); return .handled }
                .onKeyPress(.tab) { tab(); return .handled }
        }
        .padding(.horizontal, Theme.Space.s4).padding(.vertical, Theme.Space.s4)
        .onAppear { DispatchQueue.main.async { focus.wrappedValue = true } }
    }
}

/// The one-line route: kind · project · target (· model · effort), `?` where Jev was unsure.
struct RouteLine: View {
    var route: Route?
    var plan: Plan?
    var reading = false
    var armed = false
    var choose: (CommandKind) -> Void = { _ in }
    /// Click on the kind pill (or the "Tab: …" hint): the same call as pressing Tab, `store.takeRunnerUp`.
    var cycle: () -> Void = {}

    /// What clicking the kind pill does: the Tab path when the router offers a runner-up, otherwise nothing
    /// (the pill is then a plain label). Exposed so the click path is unit-tested without a window.
    static func kindPillAction(route: Route?, cycle: @escaping () -> Void) -> (() -> Void)? {
        guard let r = route, !r.twoChoice, r.alternatives.first != nil else { return nil }
        return cycle
    }

    var body: some View {
        HStack(spacing: Theme.Space.s2) {
            if let r = route {
                if r.twoChoice {
                    Text("Which one?").font(Theme.Fonts.small).foregroundStyle(Theme.Token.text2)
                    choice("Run in shell", .shellCommand)
                    choice("Send to Claude", .agentTask)
                } else {
                    chips(r)
                }
            }
            Spacer(minLength: Theme.Space.s2)
            if reading {
                ProgressView().controlSize(.mini)
                Text("reading…").font(Theme.Fonts.label).foregroundStyle(Theme.Token.text3)
            }
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private func chips(_ r: Route) -> some View {
        chip(kindLabel(r.kind), "return.right", r.uncertain.contains(.kind), action: Self.kindPillAction(route: r, cycle: cycle))
        if r.kind != .none {
            chip(r.project?.name ?? "this pane", "folder", r.uncertain.contains(.project))
        }
        if r.kind.sendsToClaude {
            chip(targetLabel(r.target), "arrow.turn.down.right", r.uncertain.contains(.target))
            if newProcess(r.target) {
                if let m = r.model { chip(m.label, nil, false) }
                if let e = r.effort { chip(e.label, nil, false) }
            }
        }
        if r.kind.sendsToClaude, r.isDestructive {
            warn(armed ? "Return again to send" : "will ask first")
        }
        if r.kind == .shellCommand, let p = plan, !p.autoSubmit {
            warn("typed, not sent")
        }
        if let alt = r.alternatives.first {
            Button(action: cycle) {
                Text("Tab: \(kindLabel(alt))").font(Theme.Fonts.label)
                    .padding(.horizontal, Theme.Space.s2)
                    .frame(minHeight: Theme.Hit.control)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PillButtonStyle(shape: Rectangle(), rest: Theme.Token.text3, hover: Theme.Token.text1))
            .help("Switch to \(kindLabel(alt)) (Tab)")
        }
    }

    private func warn(_ text: String) -> some View {
        Text(text).font(Theme.Fonts.smallStrong)
            .foregroundStyle(Theme.Token.warn)
            .padding(.horizontal, Theme.Space.s2).padding(.vertical, Theme.Space.s1)
            .background(Theme.Token.warn.opacity(Theme.Alpha.tint), in: Capsule())
    }

    private func newProcess(_ t: CommandTarget) -> Bool { t == .newClaudePane || t == .backgroundBuilder }

    private func kindLabel(_ k: CommandKind) -> String {
        switch k {
        case .shellCommand: "Run in shell"
        case .agentTask: "Send to Claude"
        case .questionForClaude: "Ask Claude"
        case .trueAction: "True action"
        case .none: "Nothing to do"
        }
    }

    private func targetLabel(_ t: CommandTarget) -> String {
        switch t {
        case .focusedPane: "current"
        case .newClaudePane: "new pane"
        case .backgroundBuilder: "background"
        case .seat(let n): n
        }
    }

    @ViewBuilder
    private func chip(_ text: String, _ icon: String?, _ unsure: Bool, action: (() -> Void)? = nil) -> some View {
        let label = HStack(spacing: Theme.Space.s1) {
            if let icon { Image(systemName: icon).font(Theme.Fonts.label) }
            Text(unsure ? text + " ?" : text).font(Theme.Fonts.label)
        }
        .padding(.horizontal, Theme.Space.s3)
        .frame(minHeight: Theme.Hit.control)
        .contentShape(Capsule())
        let rest = unsure ? Theme.Token.text0 : Theme.Token.text2
        if let action {
            Button(action: action) { label }
                .buttonStyle(PillButtonStyle(shape: Capsule(), rest: rest, hover: Theme.Token.text0,
                                             fill: unsure ? Theme.Token.strongLine : Theme.Token.pressFill,
                                             hoverFill: Theme.Token.strongLine))
                .help("Switch the route (Tab)")
        } else {
            label.foregroundStyle(rest).background(unsure ? Theme.Token.strongLine : Theme.Token.pressFill, in: Capsule())
        }
    }

    private func choice(_ text: String, _ k: CommandKind) -> some View {
        Button { choose(k) } label: {
            Text(text).font(Theme.Fonts.smallStrong)
                .padding(.horizontal, Theme.Space.s4)
                .frame(minHeight: Theme.Hit.control)
                .contentShape(Capsule())
        }
        .buttonStyle(PillButtonStyle(shape: Capsule(), rest: Theme.Token.text0, hover: Theme.Token.text0,
                                     fill: Theme.Token.strongLine, hoverFill: Theme.Token.text3.opacity(Theme.Alpha.strongLine)))
    }
}

/// Hover + press state for a pill: brighter text and a stronger fill under the pointer, quiet press dip.
/// Animations use the `micro` spring (crossfade under Reduce Motion).
struct PillButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    var rest: Color
    var hover: Color
    var fill: Color = .clear
    var hoverFill: Color = Theme.Token.hoverFill
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? hover : rest)
            .background(configuration.isPressed ? Theme.Token.pressFill : (hovering ? hoverFill : fill), in: shape)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .motion(.micro, value: hovering)
    }
}
