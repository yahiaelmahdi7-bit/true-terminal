import SwiftUI

/// Shared bits of the Pull requests list and review view. Text is the app's system font (`Theme.Fonts`); monospace only
/// in the diff body and the +N/−M counts. "Mono" elsewhere means monochrome: colour only on diff +/- lines and counts.
enum PRFont {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}


struct PRCounts: View {
    let added: String, removed: String
    var body: some View {
        HStack(spacing: 6) {
            Text(added).foregroundStyle(Theme.Diff.add)
            Text(removed).foregroundStyle(Theme.Diff.remove)
        }
        .font(PRFont.mono(12, .medium)).monospacedDigit().fixedSize()
    }
}

struct PRHeldPill: View {
    var body: some View {
        Text(TaskPRCopy.held).font(Theme.Fonts.label.weight(.medium)).foregroundStyle(Theme.Token.text0)
            .padding(.horizontal, 9).frame(height: 20)
            .background(Capsule().fill(Theme.Token.line))
            .fixedSize()
    }
}

/// Gate word as plain text: Green and Red read bright, Not run and Old read dim. No colour.
struct PRGateWord: View {
    let word: String
        var body: some View {
        let bright = word == GateWord.green.rawValue || word == GateWord.red.rawValue
        Text(word).font(bright ? Theme.Fonts.smallStrong : Theme.Fonts.small)
            .foregroundStyle(bright ? Theme.Token.text0 : Theme.Token.text2).fixedSize()
    }
}

struct PRButton: View {
    let title: String
    var primary = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.Fonts.smallStrong).padding(.horizontal, 12).frame(height: 28)
        }
        .buttonStyle(PillButtonStyle(shape: Capsule(), rest: Theme.Token.text0, hover: Theme.Token.text0,
                                     fill: primary ? Theme.Token.strongLine : Theme.Token.line,
                                     hoverFill: Theme.Token.text3.opacity(Theme.Alpha.strongLine)))
        .disabled(!enabled).opacity(enabled ? 1 : Theme.Alpha.disabled + 0.1)
    }
}

/// Signed out of GitHub: one plain line and one button (same words as the task screen's PR line).
struct PRSignInEmpty: View {
    var onSignIn: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PRCopy.signedOut).font(Theme.Fonts.body).foregroundStyle(Theme.Token.text1)
            PRButton(title: TaskPRCopy.signIn, primary: true, action: onSignIn)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A file header's counts: a zero side is hidden ("+2 −0" is "+2"), same rule as the pane strip.
struct PRFileCounts: View {
    let added: Int, removed: Int
    static func parts(added: Int, removed: Int) -> [(text: String, add: Bool)] {
        (added > 0 ? [("+\(added)", true)] : []) + (removed > 0 ? [("−\(removed)", false)] : [])
    }
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.parts(added: added, removed: removed).enumerated()), id: \.offset) { _, p in
                Text(p.text).foregroundStyle(p.add ? Theme.Diff.add : Theme.Diff.remove)
            }
        }
        .font(PRFont.mono(12, .medium)).monospacedDigit().fixedSize()
    }
}
