import Foundation
import AppKit

/// Panes opened for a peer's job, so the tab can say "· from <label>" (Run 29).
final class PeerOrigin: @unchecked Sendable {
    static let shared = PeerOrigin()
    private let lock = NSLock()
    private var panes: [UUID: String] = [:]
    func mark(_ pane: UUID, label: String) { lock.lock(); panes[pane] = label; lock.unlock() }
    func label(for pane: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return panes[pane] }
}

/// The real Mac side of the peers engine: finds the clone, makes the worktree with git, opens a True tab or a builder.
/// Called from the engine's work queue, so UI work hops to the main actor.
final class PeerLauncherLive: PeerLauncher, @unchecked Sendable {
    private static func onMain<T: Sendable>(_ f: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { f() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { f() } }
    }

    /// `git <args>` in `dir`; (exit status, trimmed output). Never prompts.
    static func git(_ args: [String], in dir: String) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return (127, "git is not available") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func remoteURL(ofRepoAt path: String) -> String? {
        let (rc, out) = Self.git(["remote", "get-url", "origin"], in: path)
        return rc == 0 && !out.isEmpty ? out : nil
    }

    /// Candidates: each allowed root and its immediate children that look like a git checkout.
    static func candidates(roots: [String] = SpawnRequest.allowedRoots()) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for r in roots {
            if fm.fileExists(atPath: r + "/.git") { out.append(r) }
            for n in (try? fm.contentsOfDirectory(atPath: r)) ?? [] where !n.hasPrefix(".") && !n.hasSuffix(".peers") {
                let d = r + "/" + n
                if fm.fileExists(atPath: d + "/.git") { out.append(d) }
            }
        }
        return out
    }

    func resolveClone(repo: String) -> String? {
        PeerRepo.resolve(repo: repo, candidates: Self.candidates(), originOf: { remoteURL(ofRepoAt: $0) })
    }

    func prepareWorktree(clone: String, base: String, branch: String, worktree: String) -> String? {
        let (frc, fout) = Self.git(["fetch", "origin"], in: clone)
        guard frc == 0 else { return "Couldn't fetch the repo (\(fout.split(separator: "\n").last.map(String.init) ?? "git error"))" }
        if FileManager.default.fileExists(atPath: worktree + "/.git") { return nil }     // a retry of the same job
        try? FileManager.default.createDirectory(atPath: (worktree as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let (rc, out) = Self.git(["worktree", "add", "-b", branch, worktree, "origin/\(base)"], in: clone)
        return rc == 0 ? nil : "Couldn't make a worktree (\(out.split(separator: "\n").last.map(String.init) ?? "git error"))"
    }

    func headSHA(worktree: String) -> String? {
        let (rc, out) = Self.git(["rev-parse", "--short=12", "HEAD"], in: worktree)
        return rc == 0 && !out.isEmpty ? out : nil
    }

    func launchPane(agentName: String, label: String, cwd: String, flags: [String], rolePath: String, firstPrompt: String) -> UUID? {
        Self.onMain {
            AgentHooks.installPaneHooks(paths: AgentPaths.standard)
            let argv = ["claude", "--name", agentName] + flags + ["--append-system-prompt-file", rolePath, firstPrompt]
            let cmd = CommandExecutor.startupCommand(argv: argv, settings: AgentPaths.standard.paneSettingsPath)
            let pane = WorkspaceModel.shared.openProjectBeside(path: cwd, startupCommand: cmd)
            PeerOrigin.shared.mark(pane, label: label)
            return pane
        }
    }

    var canRunBackground: Bool { FileManager.default.isExecutableFile(atPath: SpawnRequest.builderPath()) }

    func launchBackground(agentName: String, parent: String, cwd: String, prompt: String) -> String? {
        guard let file = CommandExecutor.writePrompt(prompt, name: agentName) else { return "Couldn't write the job prompt" }
        let req = SpawnRequest(name: agentName, promptFile: file, repo: cwd, worktree: false, model: "sonnet", from: parent)
        final class Box: @unchecked Sendable { var err: String? }
        let box = Box(), sem = DispatchSemaphore(value: 0)
        Task.detached {
            if case .failure(let e) = await BuilderSpawn.run(req, callerRepo: cwd, runner: BuilderSpawn.systemRunner) { box.err = e.message }
            sem.signal()
        }
        sem.wait()
        return box.err
    }

    func deliverLine(agent: String, line: String) {
        Self.onMain {
            guard let pane = AgentRegistry.shared.panes[agent] else { return }      // only an awake local agent gets the line
            PaneDelivery.write(line, intent: .prompt, to: pane)
        }
    }

    /// Panes end the way an agent goes to sleep (TERM to the group, KILL after 3 s); builders get `builder kill`.
    func stop(panes: [UUID], builders: [String]) {
        Self.onMain {
            for pane in panes {
                guard let view = TerminalRegistry.shared.view(for: pane) else { WorkspaceModel.shared.paneExited(pane); continue }
                view.resumeChild()
                let pid = view.process.shellPid
                guard pid > 0 else { WorkspaceModel.shared.paneExited(pane); continue }
                if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if TerminalRegistry.shared.view(for: pane) != nil, kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
                }
            }
            let ids = HubStore.shared.builders.filter { builders.contains($0.name) && $0.state == .running }.map(\.id)
            for id in ids {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: SpawnRequest.builderPath())
                p.arguments = ["kill", id]
                try? p.run()
            }
        }
    }
}

/// Hub builder list → peers engine: only touches the engine when a peer-named builder exists.
@MainActor enum PeerBuilders {
    static func report(_ records: [BuilderRecord]) {
        for r in records where r.name.hasPrefix("peer-") {
            PeerService.engine.builderUpdate(name: r.name, running: r.state == .running)
        }
    }
}
