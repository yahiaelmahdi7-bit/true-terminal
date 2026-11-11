import SwiftUI

/// One PR: diff (black, colour only on +/- lines), the gate word for the head, and the buttons.
/// Buttons and refusal lines come from `TaskPRState` via `PRReviewState`; no comment box.
struct PRReviewView: View {
    let state: PRReviewState
    var onBack: () -> Void = {}
    var onMerge: () -> Void = {}
    var onRunGate: () -> Void = {}
    var onHold: () -> Void = {}
    var onOpen: () -> Void = {}
    var onUpdate: () -> Void = {}
    var onSignIn: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.Token.line)
            diff
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Token.bg0)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onBack) { Text("‹ " + PRScreenCopy.back).font(Theme.Fonts.small).foregroundStyle(Theme.Token.text2) }.buttonStyle(.plain)
            Text(state.title).font(Theme.Fonts.h3.weight(.semibold)).foregroundStyle(Theme.Token.text0)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(TaskPRCopy.pr(state.number)).foregroundStyle(Theme.Token.text1)
                Text(state.author).foregroundStyle(Theme.Token.text2)
                PRCounts(added: "+\(state.additions)", removed: "−\(state.deletions)")
                if let pr = state.pr {
                    if let s = pr.gateRunningFor {
                        Text(TaskPRCopy.gateRunning(s)).foregroundStyle(Theme.Token.text1).monospacedDigit()
                    } else {
                        PRGateWord(word: pr.gate.rawValue)
                    }
                    if pr.held { PRHeldPill() }
                }
                Spacer(minLength: 0)
            }
            .font(Theme.Fonts.small).lineLimit(1)
            buttons
            ForEach(Array(state.notes.enumerated()), id: \.offset) { _, n in
                Text(n).font(Theme.Fonts.small).foregroundStyle(Theme.Token.text1).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    @ViewBuilder private var buttons: some View {
        if let pr = state.pr, pr.showsSignIn {
            VStack(alignment: .leading, spacing: 10) {
                Text(PRCopy.signedOut).font(Theme.Fonts.small).foregroundStyle(Theme.Token.text1)
                HStack(spacing: 8) {
                    PRButton(title: TaskPRCopy.signIn, primary: true, action: onSignIn)
                    PRButton(title: PRScreenCopy.openOnGitHub, action: onOpen)
                }
            }
        } else {
            HStack(spacing: 8) {
                if let pr = state.pr, state.showsButtons {
                    PRButton(title: TaskPRCopy.merge, primary: state.shown == .merge, enabled: pr.mergeEnabled, action: onMerge)
                    if state.showsUpdate {
                        PRButton(title: PRScreenCopy.updateBranch, primary: state.shown == .update, enabled: state.updateEnabled, action: onUpdate)
                    }
                    PRButton(title: TaskPRCopy.runGate, primary: state.shown == .runGate,
                             enabled: pr.gateButtonEnabled, action: onRunGate)
                    PRButton(title: pr.holdLabel, primary: state.shown == .release, action: onHold)
                }
                PRButton(title: PRScreenCopy.openOnGitHub, primary: state.shown == .openOnGitHub, action: onOpen)
                Spacer(minLength: 0)
            }
        }
    }

    /// Short states pin to the top, under the header, like a loaded diff does.
    @ViewBuilder private var diff: some View {
        switch state.body {
        case .loading: message(PRScreenCopy.loadingDiff)
        case .tooLarge: message(PRScreenCopy.diffTooLarge)
        case .couldNotLoad: message(PRCopy.notLoaded)
        case .diff(let lines):
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in row(l, first: i == 0) }
                }
                .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(Theme.Fonts.body).foregroundStyle(Theme.Token.text1)
            .padding(.horizontal, 20).padding(.top, 16).frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// File row: path (system font) + its counts (mono), like the task screen's Changes row. Diff body is mono; same left gutter as the header.
    @ViewBuilder private func row(_ l: PRDiffLine, first: Bool) -> some View {
        switch l.kind {
        case .file:
            HStack(spacing: 10) {
                Text(l.text).font(Theme.Fonts.smallStrong).foregroundStyle(Theme.Token.text0).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                PRFileCounts(added: l.added, removed: l.removed)
            }
            .padding(.horizontal, 20).padding(.top, first ? 4 : 18).padding(.bottom, 6)
        case .hunk:
            if l.text.isEmpty { Color.clear.frame(height: 10) }
            else { Text(l.text).font(PRFont.mono(12)).foregroundStyle(Theme.Token.text2).lineLimit(1).padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2) }
        case .added, .removed, .context:
            let ink: Color = l.kind == .added ? Theme.Diff.add : l.kind == .removed ? Theme.Diff.remove : Theme.Token.text1
            Text(l.text.isEmpty ? " " : l.text).font(PRFont.mono(12)).foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
