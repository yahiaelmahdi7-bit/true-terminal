import Foundation
import AppKit

/// The real backend: reads the workspace and writes into the live terminal views. Every call hops to
/// the main actor (the server's threads never touch AppKit); they are short and main never waits on
/// a server thread, so the synchronous hop cannot deadlock.
struct RemoteBackendLive: RemoteBackend {
    private static func onMain<T: Sendable>(_ f: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { f() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { f() } }
    }

    func tabsJSON() -> Data {
        Self.onMain {
            let reg = AgentRegistry.shared
            let needs = Set(NeedsYouQueue.shared.rows.map(\.paneID))
            let model = WorkspaceModel.shared
            let tabs: [[String: Any]] = model.state.tabs.map { tab in
                let panes: [[String: Any]] = tab.tree.leafIDs.map { id in
                    let cwd = tab.cwds[id] ?? ""
                    let agent = reg.name(for: id)
                    return ["id": id.uuidString,
                            "title": agent ?? TabState.basename(cwd.isEmpty ? "~" : cwd),
                            "cwd": cwd,
                            "agent": agent ?? NSNull(),
                            "needsYou": needs.contains(id),
                            "claude": agent != nil || reg.latest[id] != nil,
                            "busy": reg.latest[id]?.kind == .progress,
                            "live": TerminalRegistry.shared.view(for: id) != nil]
                }
                return ["id": tab.id.uuidString, "title": tab.title, "selected": tab.id == model.state.selectedTab,
                        "panes": panes]
            }
            let obj: [String: Any] = ["tabs": tabs, "now": Date().timeIntervalSince1970]
            return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
    }

    func snapshot(pane: UUID) -> (cols: Int, rows: Int, bytes: [UInt8])? {
        Self.onMain {
            guard let v = TerminalRegistry.shared.view(for: pane) else { return nil }
            let t = v.getTerminal()
            return (t.cols, t.rows, RemoteSnapshot.render(t))
        }
    }

    func input(pane: UUID, bytes: [UInt8]) -> Bool {
        Self.onMain {
            guard let v = TerminalRegistry.shared.view(for: pane) else { return false }
            v.send(data: ArraySlice(bytes))
            return true
        }
    }

    func paneInput(pane: UUID, intent: PaneInputIntent, text: String, attachments: [String]) -> String? {
        final class Box: @unchecked Sendable { var outcome = "unverified"; var known = true }
        let box = Box(), done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard TerminalRegistry.shared.view(for: pane) != nil else { box.known = false; done.signal(); return }
                let reg = AgentRegistry.shared
                let isClaude = reg.name(for: pane) != nil || reg.latest[pane] != nil
                if intent == .prompt, !isClaude {
                    // A plain shell: nothing to verify against. Type, then Return, both through the one door.
                    PaneDelivery.write(text, intent: .stage, attachments: attachments, to: pane) { _ in
                        PaneDelivery.write("", intent: .submitOnly, to: pane) { _ in
                            box.outcome = PaneDelivery.Outcome.unverified.wire; done.signal()
                        }
                    }
                    return
                }
                PaneDelivery.write(text, intent: intent.deliveryIntent, attachments: attachments, to: pane) { o in
                    box.outcome = o.wire; done.signal()
                }
            }
        }
        // PaneDelivery verifies for ~6 s (twice on a retry); never hold a server thread past that.
        if done.wait(timeout: .now() + 20) == .timedOut { return PaneDelivery.Outcome.unverified.wire }
        return box.known ? box.outcome : nil
    }
}
