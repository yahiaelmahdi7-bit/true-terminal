import SwiftUI
import AppKit

/// Quiet "Restart to update" pill for the tab bar; exists only once the binary on disk is newer than the
/// running one. Never a modal on detection: the alert appears only after the user clicks, and only if
/// Claude sessions are mid-task.
struct RestartPill: View {
    let watcher: BuildFreshnessWatcher
    @State private var hovering = false

    var body: some View {
        UpdateNoticePill()
            .onChange(of: Updater.shared.countdownEnd) { RestartToast.shared.sync() }
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

/// "Restarting True in 60 s to update to vX.Y.Z — Now · Cancel". Non-modal glass card, bottom-right of the key window.
/// Exists only while `Updater.countdownEnd` is set; the 1 s redraw is a TimelineView that dies with the card.
struct RestartToastView: View {
    let end: Date
    let version: String

    static func text(remaining: Int, version: String) -> String { "Restarting True in \(max(0, remaining)) s to update to v\(version)" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = Int(end.timeIntervalSince(ctx.date).rounded(.up))
            HStack(spacing: 12) {
                Text(Self.text(remaining: left, version: version))
                    .font(.callout).foregroundStyle(Theme.text)
                Button("Now") { Updater.shared.restartNow() }.buttonStyle(.plain).fontWeight(.semibold)
                Button("Cancel") { Updater.shared.cancelCountdownByUser() }.buttonStyle(.plain).foregroundStyle(Theme.hubSecondary)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: Color.black.opacity(0.55), hairline: true)
            .accessibilityElement(children: .combine)
        }
        .fixedSize()
    }
}

@MainActor
final class RestartToast {
    static let shared = RestartToast()
    private var panel: NSPanel?

    /// Show or hide to match the updater's countdown.
    func sync() {
        guard let end = Updater.shared.countdownEnd, let v = Updater.shared.countdownVersion else { hide(); return }
        guard panel == nil, let host = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let view = NSHostingView(rootView: RestartToastView(end: end, version: v).preferredColorScheme(.dark))
        let size = view.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = view
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.hidesOnDeactivate = false
        let f = host.frame
        p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 16, y: f.minY + 16))
        host.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
        panel = p
        NSAccessibility.post(element: p, notification: .announcementRequested,
                             userInfo: [.announcement: RestartToastView.text(remaining: Int(UpdateLogic.restartCountdown), version: v) + ". Now or Cancel.",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func hide() {
        guard let p = panel else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        panel = nil
    }
}
