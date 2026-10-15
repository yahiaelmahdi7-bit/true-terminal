import SwiftUI

/// Quiet "Restart to update" pill for the tab bar; exists only once the binary on disk is newer than the
/// running one. Never a modal on detection: the alert appears only after the user clicks, and only if
/// Claude sessions are mid-task.
struct RestartPill: View {
    let watcher: BuildFreshnessWatcher
    @State private var hovering = false

    var body: some View {
        UpdateNoticePill()
        if watcher.offersRestart {
            Button { watcher.requestRestart() } label: {
                HStack(spacing: 5) {
                    Circle().fill(Theme.text).frame(width: 5, height: 5)
                    Text("Restart to update")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(hovering ? Color.white.opacity(0.10) : Theme.hubCardFill, in: Capsule())
                .overlay(Capsule().stroke(hovering ? Color.white.opacity(0.16) : Theme.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(PillPressStyle())
            .onHover { hovering = $0 }
            .help("A newer True is built. Restart to use it; your sessions resume.")
        }
    }
}

private struct PillPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// "True 1.2.3 is out": shown only when a newer release exists that the updater could not install in place
/// (the app sits somewhere read-only). Click opens the release page. Non-modal; absent otherwise.
struct UpdateNoticePill: View {
    @State private var hovering = false

    var body: some View {
        if let r = Updater.shared.notice {
            Button { Updater.shared.openNoticePage() } label: {
                Text("True \(r.version) is out")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(hovering ? Color.white.opacity(0.10) : Theme.hubCardFill, in: Capsule())
                    .overlay(Capsule().stroke(hovering ? Color.white.opacity(0.16) : Theme.hairline, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("This copy of True can't update itself. Open the download page.")
        }
    }
}
