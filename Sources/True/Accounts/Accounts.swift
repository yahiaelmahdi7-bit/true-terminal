import Foundation

/// One extra account for a provider: a label and a config directory. Paths and labels only, never a token.
/// The provider's normal directory (`~/.claude`, `~/.codex`) is the implicit default account and is not stored;
/// a seat with `account == nil` uses it.
struct Account: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var provider: SeatProvider
    var label: String
    /// Absolute path, exactly as it should be exported (Claude's Keychain name hashes this string unchanged).
    var configDir: String
}

/// A seat's account after lookup. `configDir == nil` is the default account: no env var is set for it.
struct ResolvedAccount: Equatable, Sendable {
    var provider: SeatProvider
    var id: String?
    var label: String
    var configDir: String?
    /// The directory the probe looks at (the default dir for the default account).
    var directory: URL
    var isDefault: Bool { configDir == nil }
}

/// `~/.true/accounts.json`. The path is injectable so tests use a temp dir. A missing or corrupt file means
/// "no extra accounts" (a corrupt one is kept aside as `accounts.corrupt.json`); one bad entry never drops the rest.
struct AccountStore: Sendable {
    let url: URL
    var defaultClaudeDir: URL = ClaudeSeat.claudeConfigDir
    var defaultCodexDir: URL = CodexSeat.codexDir

    init(url: URL = AgentPaths.standard.root.appendingPathComponent("accounts.json"),
         defaultClaudeDir: URL = ClaudeSeat.claudeConfigDir, defaultCodexDir: URL = CodexSeat.codexDir) {
        self.url = url; self.defaultClaudeDir = defaultClaudeDir; self.defaultCodexDir = defaultCodexDir
    }

    private struct Lossy: Decodable {
        let value: Account?
        init(from decoder: Decoder) throws { value = try? Account(from: decoder) }
    }
    private struct File: Decodable {
        let accounts: [Lossy]
    }

    func load() -> [Account] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            let aside = url.deletingLastPathComponent().appendingPathComponent("accounts.corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return []
        }
        var seen = Set<String>()
        return file.accounts.compactMap(\.value).filter { !$0.id.isEmpty && !$0.configDir.isEmpty && seen.insert($0.id).inserted }
    }

    func save(_ accounts: [Account]) {
        struct Out: Encodable { var version = 1; var accounts: [Account] }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(Out(accounts: accounts)).write(to: url, options: .atomic)
        } catch { NSLog("True: accounts save failed: \(error)") }
    }

    func defaultDir(_ provider: SeatProvider) -> URL { provider == .claude ? defaultClaudeDir : defaultCodexDir }

    func defaultAccount(_ provider: SeatProvider) -> ResolvedAccount {
        ResolvedAccount(provider: provider, id: nil, label: "Default", configDir: nil, directory: defaultDir(provider))
    }

    func resolved(_ a: Account) -> ResolvedAccount {
        ResolvedAccount(provider: a.provider, id: a.id, label: a.label, configDir: a.configDir,
                        directory: URL(fileURLWithPath: a.configDir))
    }

    /// nil reference, or one that no longer exists in the file, means the provider's default account.
    func resolve(ref: String?, provider: SeatProvider) -> ResolvedAccount {
        guard let ref, let a = load().first(where: { $0.id == ref && $0.provider == provider }) else { return defaultAccount(provider) }
        return resolved(a)
    }

    /// Only these may be probed on a timer or at launch; the live default dir is read on demand.
    func storedAccounts() -> [ResolvedAccount] { load().map(resolved) }
}
