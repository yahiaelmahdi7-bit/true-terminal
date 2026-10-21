import Foundation

/// Opens and closes `tailscale serve` mappings for dev servers. It only ever removes mappings it created itself
/// (remembered in `sites.json`), never `serve reset`, and never touches :443 / :8444 or any foreign entry.
final class SiteExposure: @unchecked Sendable {
    /// Runs `tailscale <args>`; nil = failed.
    typealias Runner = @Sendable ([String]) -> Data?

    private let runner: Runner
    private let file: URL
    private let lock = NSLock()
    private var owned: SiteOwnership

    init(runner: @escaping Runner, file: URL) {
        self.runner = runner; self.file = file
        owned = (try? JSONDecoder().decode(SiteOwnership.self, from: Data(contentsOf: file))) ?? SiteOwnership()
    }

    static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("True", isDirectory: true).appendingPathComponent("sites.json")
    }

    var mappings: [Int: Int] { lock.lock(); defer { lock.unlock() }; return owned.mappings }

    func servePort(for port: Int) -> Int? { lock.lock(); defer { lock.unlock() }; return owned.mappings[port] }

    func currentServePorts() -> Set<Int> {
        guard let d = runner(["serve", "status", "--json"]) else { return [] }
        return SitesLogic.servePorts(fromStatus: d)
    }

    /// Expose local `port`; returns the tailnet https port, or nil when nothing is free / tailscale refused.
    func expose(port: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let taken = currentServePorts()
        if let existing = owned.mappings[port], taken.contains(existing) { return existing }
        // A stale record whose serve entry vanished is simply replaced.
        owned.mappings[port] = nil
        guard let sp = SitesLogic.allocate(preferred: port, taken: taken) else { return nil }
        guard runner(["serve", "--bg", "--https=\(sp)", "http://127.0.0.1:\(port)"]) != nil else { return nil }
        guard currentServePorts().contains(sp) else { return nil }
        owned.mappings[port] = sp
        save()
        return sp
    }

    /// Remove True's own mapping for `port`. A port True does not own is left alone.
    @discardableResult
    func unexpose(port: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let sp = owned.mappings[port], owned.mayRemove(servePort: sp) else { return false }
        if currentServePorts().contains(sp) {
            guard runner(["serve", "--https=\(sp)", "off"]) != nil else { return false }
        }
        owned.mappings[port] = nil
        save()
        return true
    }

    /// Tear down every owned mapping whose dev server is no longer live (called each scan and at launch).
    func reconcile(livePorts: Set<Int>) {
        let stale = { lock.lock(); defer { lock.unlock() }; return owned.stale(livePorts: livePorts) }()
        for p in stale { unexpose(port: p) }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(owned) { try? d.write(to: file, options: .atomic) }
    }
}
