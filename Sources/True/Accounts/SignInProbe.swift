import Foundation
import CryptoKit

/// What one sign-in read found. `email` is personal: held in memory for the "click to show" row, never stored.
struct AccountReading: Equatable, Sendable {
    var signIn: SeatSignIn = .unknown
    var plan: String?
    var email: String?
    /// Plain-words reason when the answer is Unknown, or a tooltip for Signed in.
    var note: String?
}

/// THE sign-in reader (Wedge 3, spike C1 `t3-parity-signin-spike.md`). ProgramFinder's launch probe and the
/// accounts screen both come through here, so there is one rule for "Not signed in".
/// Hard lines: no token, key or cookie value is ever read into a log or stored; the Keychain is asked only whether
/// an item exists (never `-w` or `-g`); and anything that is not a clean documented answer is Unknown.
enum SignInProbe {
    static let strippedEnv = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]
    static let defaultSecurity = "/usr/bin/security"
    static let claudeDefaultService = "Claude Code-credentials"
    /// `security` exit status for "item not found".
    static let keychainNotFound: Int32 = 44

    /// Unsuffixed for the default account; `-<first 8 hex of sha256(path exactly as given)>` for a set config dir.
    static func keychainService(configDir: String?) -> String {
        guard let configDir else { return claudeDefaultService }
        return claudeDefaultService + "-" + sha8(configDir)
    }
    static func sha8(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Real USER/HOME kept (Claude's Keychain account is USER; without it a signed-in dir reads "not logged in").
    /// Inherited credentials the account did not configure are dropped so a stray key cannot mask a missing login.
    static func environment(base: [String: String], provider: SeatProvider, configDir: String?) -> [String: String] {
        var env = base
        for key in strippedEnv { env.removeValue(forKey: key) }
        let name = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        env.removeValue(forKey: name)
        if let configDir { env[name] = configDir }
        if env["USER"]?.isEmpty != false { env["USER"] = NSUserName() }
        if env["HOME"]?.isEmpty != false { env["HOME"] = NSHomeDirectory() }
        return env
    }

    static func read(provider: SeatProvider, exe: String, directory: URL, configDir: String?, base: [String: String],
                     run: ProgramFinder.Runner, security: String = defaultSecurity, timeout: TimeInterval,
                     now: Date = Date()) -> AccountReading {
        // A missing or unreadable directory looks exactly like a logout to both CLIs, so it is Unknown.
        // (The default directory is exempt: Claude's Keychain check below settles it, and Codex says so itself.)
        if configDir != nil {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue,
                  FileManager.default.isReadableFile(atPath: directory.path) else {
                return AccountReading(note: "Folder not found")
            }
        }
        let env = environment(base: base, provider: provider, configDir: configDir)
        switch provider {
        case .claude: return claude(exe: exe, env: env, configDir: configDir, run: run, security: security, timeout: timeout, now: now)
        case .codex: return codex(exe: exe, env: env, directory: directory, run: run, timeout: timeout)
        }
    }

    static func claude(exe: String, env: [String: String], configDir: String?, run: ProgramFinder.Runner,
                       security: String, timeout: TimeInterval, now: Date) -> AccountReading {
        guard let out = run(exe, ["auth", "status", "--json"], env, timeout), !out.timedOut,
              let json = (try? JSONSerialization.jsonObject(with: Data(out.text.utf8))) as? [String: Any],
              let loggedIn = json["loggedIn"] as? Bool, out.status == (loggedIn ? 0 : 1) else {
            return AccountReading(note: "Could not read")
        }
        if loggedIn {
            // Env-injected credentials (oauth_token, api_key) are unverified: not a login True can vouch for.
            guard json["authMethod"] as? String == "claude.ai" else { return AccountReading(note: "Not a Claude account login") }
            if let text = json["loginExpiresAt"] as? String, let at = parseDate(text), at <= now {
                return AccountReading(note: "Login may have expired")
            }
            return AccountReading(signIn: .signedIn, plan: nonEmpty(json["subscriptionType"] as? String),
                                  email: nonEmpty(json["email"] as? String))
        }
        // "Not logged in" is also what a failed Keychain lookup prints. Existence check only: exit 44 exactly.
        let service = keychainService(configDir: configDir)
        guard let kc = run(security, ["find-generic-password", "-s", service], env, timeout), !kc.timedOut,
              kc.status == keychainNotFound else { return AccountReading(note: "Could not confirm") }
        return AccountReading(signIn: .notSignedIn)
    }

    static func codex(exe: String, env: [String: String], directory: URL, run: ProgramFinder.Runner,
                      timeout: TimeInterval) -> AccountReading {
        guard let out = run(exe, ["login", "status"], env, timeout), !out.timedOut else { return AccountReading(note: "Could not read") }
        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.status == 1 && text == "Not logged in" { return AccountReading(signIn: .notSignedIn) }
        if out.status == 0 && text == "Logged in using ChatGPT" {
            let claims = CodexAuthClaims.read(authFile: directory.appendingPathComponent("auth.json"))
            return AccountReading(signIn: .signedIn, plan: claims.plan, email: claims.email,
                                  note: "Credentials found; not checked with OpenAI.")
        }
        if text.hasPrefix("API key configured") { return AccountReading(note: "API key, not checked") }
        return AccountReading(note: "Could not read")
    }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
    private static func parseDate(_ text: String) -> Date? {
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Email and plan from the `id_token` claims in `$CODEX_HOME/auth.json`, decoded locally. Only the payload is
/// decoded and only two claims are kept; the token itself never leaves this function.
enum CodexAuthClaims {
    static func read(authFile: URL) -> (email: String?, plan: String?) {
        guard let data = try? Data(contentsOf: authFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any], let jwt = tokens["id_token"] as? String else { return (nil, nil) }
        return claims(fromJWT: jwt)
    }
    static func claims(fromJWT jwt: String) -> (email: String?, plan: String?) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (nil, nil) }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let payload = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return (nil, nil) }
        let auth = obj["https://api.openai.com/auth"] as? [String: Any]
        let email = (obj["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let plan = (auth?["chatgpt_plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (email, plan)
    }
}

/// Reads sign-in per account, off the calling thread, each call bounded by `timeout`.
/// Timing rule (the CLI writes into the config dir): `readStored` covers only directories in accounts.json;
/// the live default directory is read only through `readDefault`, called when the accounts screen opens or a seat
/// wakes. Nothing here schedules itself; do not call these from a timer.
final class AccountSignInReader: @unchecked Sendable {
    let finder: ProgramFinder
    let store: AccountStore
    private let baseEnv: [String: String]
    private let security: String
    private let runner: ProgramFinder.Runner
    private let timeout: TimeInterval

    init(finder: ProgramFinder = .shared, store: AccountStore = AccountStore(),
         baseEnv: [String: String] = ProcessInfo.processInfo.environment, security: String = SignInProbe.defaultSecurity,
         runner: @escaping ProgramFinder.Runner = ProgramFinder.run, timeout: TimeInterval = 3) {
        self.finder = finder; self.store = store; self.baseEnv = baseEnv; self.security = security
        self.runner = runner; self.timeout = timeout
    }

    /// Blocking; call from a worker. Uses the real binary the finder resolves (never the shell alias).
    func readNow(_ account: ResolvedAccount) -> AccountReading {
        guard let exe = finder.resolve(account.provider.rawValue) else { return AccountReading(note: "Not installed") }
        var env = baseEnv; env["PATH"] = finder.path
        return SignInProbe.read(provider: account.provider, exe: exe, directory: account.directory, configDir: account.configDir,
                                base: env, run: runner, security: security, timeout: timeout)
    }

    func read(_ account: ResolvedAccount) async -> AccountReading {
        await Task.detached(priority: .utility) { [self] in readNow(account) }.value
    }

    /// Accounts in accounts.json only, keyed by account id.
    func readStored() async -> [String: AccountReading] {
        var out: [String: AccountReading] = [:]
        for account in store.storedAccounts() { if let id = account.id { out[id] = await read(account) } }
        return out
    }

    /// On demand only: the accounts screen opening, or a seat waking.
    func readDefault(_ provider: SeatProvider) async -> AccountReading { await read(store.defaultAccount(provider)) }
}

/// What a "Sign in" pane runs. Pure: this builds the line, it never runs it. True never handles a token; the
/// provider's own login does the work in a terminal pane.
struct SignInCommand: Equatable, Sendable {
    let argv: [String]
    /// Variables set for the pane (the account's config dir only for a non-default account).
    let env: [String: String]
    /// Variables removed so an inherited key cannot answer for the login.
    let unset: [String]
    let shellCommand: String

    static func make(provider: SeatProvider, configDir: String?, executable: String? = nil) -> SignInCommand {
        let exe = executable ?? provider.rawValue
        let argv = provider == .claude ? [exe, "auth", "login"] : [exe, "login"]
        var env: [String: String] = [:]
        let name = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        if let configDir { env[name] = configDir }
        let unset = SignInProbe.strippedEnv + (configDir == nil ? [name] : [])
        var line = "unset " + unset.joined(separator: " ") + "; "
        if let configDir { line += "export \(name)=\(AgentLaunch.shellQuote(configDir)); " }
        line += "exec " + argv.map(AgentLaunch.shellQuote).joined(separator: " ")
        return SignInCommand(argv: argv, env: env, unset: unset, shellCommand: line)
    }
}
