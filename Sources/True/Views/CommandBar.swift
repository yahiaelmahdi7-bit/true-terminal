import SwiftUI

/// Isolates the bar's observation so opening it never re-evaluates the whole window body.
struct CommandBarHost: View {
    private let store = CommandBarStore.shared
    var body: some View {
        if store.isOpen { CommandBarView(store: store) }
    }
}

/// ⌘K: one text field, one quiet line that says where Return will send it.
struct CommandBarView: View {
    @Bindable var store: CommandBarStore
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { store.close() }
            card
                .frame(width: 640)
                .padding(.top, 110)
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
                Divider().opacity(0.5)
                RouteLine(route: route, plan: plan, reading: reading, armed: armed, choose: choose)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.title3).foregroundStyle(.secondary)
            TextField("Run, ask, or tell True…", text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused(focus)
                .onSubmit(submit)
                .onKeyPress(.upArrow) { up(); return .handled }
                .onKeyPress(.downArrow) { down(); return .handled }
                .onKeyPress(.tab) { tab(); return .handled }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
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

    var body: some View {
        HStack(spacing: 6) {
            if let r = route {
                if r.twoChoice {
                    Text("Which one?").font(.callout).foregroundStyle(Color.white.opacity(0.62))
                    choice("Run in shell", .shellCommand)
                    choice("Send to Claude", .agentTask)
                } else {
                    chips(r)
                }
            }
            Spacer(minLength: 8)
            if reading {
                ProgressView().controlSize(.mini)
                Text("reading…").font(.caption).foregroundStyle(Color.white.opacity(0.4))
            }
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private func chips(_ r: Route) -> some View {
        chip(kindLabel(r.kind), "return.right", r.uncertain.contains(.kind))
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
            Text("Tab: \(kindLabel(alt))").font(.caption).foregroundStyle(Color.white.opacity(0.4))
        }
    }

    private func warn(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium))
            .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.35))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color(red: 1, green: 0.6, blue: 0.2).opacity(0.16), in: Capsule())
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

    private func chip(_ text: String, _ icon: String?, _ unsure: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(unsure ? text + " ?" : text).font(.caption)
        }
        .foregroundStyle(Color.white.opacity(unsure ? 0.92 : 0.62))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.white.opacity(unsure ? 0.12 : 0.07), in: Capsule())
    }

    private func choice(_ text: String, _ k: CommandKind) -> some View {
        Button(text) { choose(k) }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(.white.opacity(0.14), in: Capsule())
    }
}
