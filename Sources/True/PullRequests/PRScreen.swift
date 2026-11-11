import SwiftUI
import AppKit

/// Opens the Pull requests screen (Hub menu). One model per opening, aimed at the focused pane's folder.
@MainActor @Observable
final class PRScreenStore {
    static let shared = PRScreenStore()
    var isOpen = false
    private(set) var model: PRScreenModel?

    func open(workspace: WorkspaceModel = .shared) {
        let ws = workspace
        let folder = ws.selectedTab.cwds[ws.selectedTab.focusedPane] ?? NSHomeDirectory()
        model = PRScreenModel(folder: folder)
        isOpen = true
    }
    func close() { isOpen = false }
}

/// The list, or the open PR's review, wired to the model. Loads when shown, again when the window gains focus,
/// and every 60 s while visible.
struct PullRequestsScreen: View {
    let model: PRScreenModel

    var body: some View {
        Group {
            if let r = model.review {
                PRReviewView(state: r, onBack: { model.back() },
                             onMerge: { Task { await model.merge() } },
                             onRunGate: { Task { await model.runGate() } },
                             onHold: { Task { await model.toggleHold() } },
                             onOpen: { model.openOnGitHub() },
                             onUpdate: { Task { await model.update() } },
                             onSignIn: { model.signIn() })
            } else {
                PullRequestsView(state: model.list, onOpen: { row in Task { await model.openReview(row) } }, onSignIn: { model.signIn() })
            }
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshOnFocus() }
        }
    }
}

struct PullRequestsSheet: View {
    let store: PRScreenStore
    var body: some View {
        if let m = store.model {
            PullRequestsScreen(model: m)
                .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 560)
                .overlay(alignment: .topTrailing) {
                    Button("Done") { store.close() }.keyboardShortcut(.cancelAction).controlSize(.large).padding(14)
                }
        }
    }
}
