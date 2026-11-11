import Foundation
import Testing
@testable import True

/// Wedge 3 step 8: accounts, the one sign-in reader, the sign-in command. Every external program here is a fake
/// script in a temp dir: these tests never run the real claude, codex or security, and never touch the Keychain.
@Suite(.serialized) struct AccountsTests {
    // MARK: rig

    final class Rig {
        let dir: URL
        let bin: URL
        let log: URL
        var secLog: URL { dir.appendingPathComponent("security.log") }
        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-test-" + UUID().uuidString)
            bin = dir.appendingPathComponent("bin")
            log = dir.appendingPathComponent("calls.log")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
        func script(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        /// A fake `claude` that records its env then answers `status` with `exit`.
        func claude(json: String, exit code: Int) throws {
            try script("claude", """
            echo "CLAUDE|$CLAUDE_CONFIG_DIR|oauth=$CLAUDE_CODE_OAUTH_TOKEN|key=$ANTHROPIC_API_KEY|user=$USER|home=$HOME|args=$*" >> '\(log.path)'
            printf '%s' '\(json)'; exit \(code)
            """)
        }
        func security(exit code: Int) throws {
            try script("security", "echo \"$*\" >> '\(secLog.path)'; exit \(code)")
        }
        func codex(out: String, exit code: Int) throws {
            try script("codex", """
            echo "CODEX|$CODEX_HOME|args=$*" >> '\(log.path)'
            printf '%s\\n' '\(out)'; exit \(code)
            """)
        }
        func lines(_ url: URL) -> [String] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        func dirMade(_ name: String) throws -> URL {
            let d = dir.appendingPathComponent(name); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
        }
        func reader(timeout: TimeInterval = 20, env: [String: String] = [:]) -> AccountSignInReader {
            let finder = ProgramFinder(environment: ["PATH": bin.path, "HOME": dir.path], roots: [bin.path], tailscaleCopies: [], probeTimeout: 20)
            var base = ["HOME": dir.path, "USER": "tester", "CLAUDE_CODE_OAUTH_TOKEN": "FAKE-OAUTH-VALUE", "ANTHROPIC_API_KEY": "FAKE-KEY-VALUE"]
            base.merge(env) { $1 }
            let store = AccountStore(url: dir.appendingPathComponent("accounts.json"),
                                     defaultClaudeDir: dir.appendingPathComponent("default-claude"),
                                     defaultCodexDir: dir.appendingPathComponent("default-codex"))
            return AccountSignInReader(finder: finder, store: store, baseEnv: base, security: bin.appendingPathComponent("security").path,
                                       timeout: timeout)
        }
        func account(_ provider: SeatProvider, dir d: URL?) -> ResolvedAccount {
            ResolvedAccount(provider: provider, id: d == nil ? nil : "x", label: "L", configDir: d?.path,
                            directory: d ?? dir.appendingPathComponent("default-\(provider.rawValue)"))
        }
    }
    static let signedInJSON = #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","planTier":"max_20x","email":"p***@example.com"}"#
    static let loggedOutJSON = #"{"loggedIn":false,"authMethod":"none"}"#

    // MARK: Keychain service name

    @Test func keychainServiceNameRule() {
        #expect(SignInProbe.keychainService(configDir: nil) == "Claude Code-credentials")
        // sha256("abc") = ba7816bf8f01cfea...
        #expect(SignInProbe.sha8("abc") == "ba7816bf")
        #expect(SignInProbe.keychainService(configDir: "abc") == "Claude Code-credentials-ba7816bf")
        // The path is hashed as given: no trailing-slash or home normalisation.
        #expect(SignInProbe.keychainService(configDir: "/a/b/") != SignInProbe.keychainService(configDir: "/a/b"))
        #expect(SignInProbe.keychainService(configDir: "~/x") != SignInProbe.keychainService(configDir: NSHomeDirectory() + "/x"))
        // Spike C1 captured value for a real temp dir path.
        #expect(SignInProbe.sha8("/tmp/c1/cfgA").count == 8)
    }

    // MARK: Claude: Signed in, Not signed in, Unknown

    @Test func claudeSignedInReadsPlanAndEmailWithConfigDir() throws {
        let rig = try Rig(); try rig.claude(json: Self.signedInJSON, exit: 0); try rig.security(exit: 0)
        let acct = try rig.dirMade("acctA")
        let r = rig.reader().readNow(rig.account(.claude, dir: acct))
        #expect(r.signIn == .signedIn && r.plan == "max" && r.email == "p***@example.com")
        #expect(rig.lines(rig.log).count == 1 && rig.lines(rig.log)[0].contains("|\(acct.path)|"))
        #expect(rig.lines(rig.secLog).isEmpty)   // no Keychain call when the CLI says signed in
    }

    @Test func claudeNotSignedInNeedsExit1AndLoggedInFalseAndKeychain44() throws {
        let rig = try Rig(); try rig.claude(json: Self.loggedOutJSON, exit: 1); try rig.security(exit: 44)
        let acct = try rig.dirMade("acctA")
        let r = rig.reader().readNow(rig.account(.claude, dir: acct))
        #expect(r.signIn == .notSignedIn)
        let sec = rig.lines(rig.secLog)
        #expect(sec == ["find-generic-password -s Claude Code-credentials-" + SignInProbe.sha8(acct.path)])
    }

    @Test func defaultAccountUsesUnsuffixedServiceAndNoConfigDirEnv() throws {
        let rig = try Rig(); try rig.claude(json: Self.loggedOutJSON, exit: 1); try rig.security(exit: 44)
        let r = rig.reader().readNow(rig.account(.claude, dir: nil))
        #expect(r.signIn == .notSignedIn)
        #expect(rig.lines(rig.secLog) == ["find-generic-password -s Claude Code-credentials"])
        #expect(rig.lines(rig.log)[0].hasPrefix("CLAUDE||"))   // CLAUDE_CONFIG_DIR empty for the default account
    }

    @Test(arguments: [(0, "found"), (1, "other"), (2, "usage"), (36, "locked"), (45, "denied"), (127, "missing"), (255, "x")])
    func keychainAnyExitButExactly44IsUnknown(code: Int, _: String) throws {
        let rig = try Rig(); try rig.claude(json: Self.loggedOutJSON, exit: 1); try rig.security(exit: code)
        let r = rig.reader().readNow(rig.account(.claude, dir: try rig.dirMade("a")))
        #expect(r.signIn == .unknown && !r.signIn.isSignedIn)
    }

    @Test func keychainCheckIsExistenceOnlyNeverReadsTheSecret() throws {
        let rig = try Rig(); try rig.claude(json: Self.loggedOutJSON, exit: 1); try rig.security(exit: 44)
        _ = rig.reader().readNow(rig.account(.claude, dir: try rig.dirMade("a")))
        for line in rig.lines(rig.secLog) {
            let words = line.split(separator: " ").map(String.init)
            #expect(!words.contains("-w") && !words.contains("-g") && !words.contains("-a"))
            #expect(words.first == "find-generic-password")
        }
    }

    @Test(arguments: [
        (#"{"loggedIn":false}"#, 0),                                  // exit disagrees with the JSON
        (#"{"loggedIn":true,"authMethod":"claude.ai"}"#, 1),          // exit disagrees the other way
        ("Not logged in. Run claude auth login to authenticate.", 1), // text, not JSON
        (#"Claude configuration file at /x/.claude.json is corrupted: JSON Parse error"#, 1),
        (#"{"authMethod":"claude.ai"}"#, 0),                          // loggedIn missing
        (#"{"loggedIn":"yes"}"#, 0),                                  // loggedIn not a boolean
        (#"{"loggedIn":true,"authMethod":"oauth_token"}"#, 0),        // env-injected credentials
        (#"{"loggedIn":true,"authMethod":"api_key","apiKeySource":"ANTHROPIC_API_KEY"}"#, 0),
        (#"{"loggedIn":true}"#, 0),                                   // no authMethod
        (#"{"loggedIn":true,"authMethod":"claude.ai","loginExpiresAt":"2020-01-01T00:00:00.000Z"}"#, 0),  // already expired
        ("", 3), ("", 0), ("", 127),
    ])
    func claudeOddAnswersAreUnknownNeverSignedIn(json: String, code: Int) throws {
        let rig = try Rig(); try rig.claude(json: json, exit: code); try rig.security(exit: 44)
        let r = rig.reader().readNow(rig.account(.claude, dir: try rig.dirMade("a")))
        #expect(r.signIn == .unknown && !r.signIn.isSignedIn && r.plan == nil && r.email == nil)
    }

    @Test func claudeTimeoutIsUnknownAndBounded() throws {
        let rig = try Rig(); try rig.script("claude", "exec /bin/sleep 20"); try rig.security(exit: 44)
        let start = Date()
        let r = rig.reader(timeout: 0.4).readNow(rig.account(.claude, dir: try rig.dirMade("a")))
        #expect(r.signIn == .unknown && Date().timeIntervalSince(start) < 8)
    }

    @Test func missingConfigDirIsUnknownAndRunsNothing() throws {
        let rig = try Rig(); try rig.claude(json: Self.loggedOutJSON, exit: 1); try rig.security(exit: 44)
        try rig.codex(out: "Not logged in", exit: 1)
        let gone = rig.dir.appendingPathComponent("nope")
        for p in [SeatProvider.claude, .codex] {
            #expect(rig.reader().readNow(rig.account(p, dir: gone)).signIn == .unknown)
        }
        #expect(rig.lines(rig.log).isEmpty && rig.lines(rig.secLog).isEmpty)
        // A path that is a regular file is not a directory either.
        let file = rig.dir.appendingPathComponent("afile"); try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(rig.reader().readNow(rig.account(.claude, dir: file)).signIn == .unknown)
    }

    @Test func notInstalledIsUnknown() throws {
        let rig = try Rig()
        #expect(rig.reader().readNow(rig.account(.claude, dir: try rig.dirMade("a"))).signIn == .unknown)
    }

    // MARK: env

    @Test func probeStripsInheritedCredentialsAndKeepsUserAndHome() throws {
        let rig = try Rig(); try rig.claude(json: Self.signedInJSON, exit: 0)
        let acct = try rig.dirMade("acctA")
        _ = rig.reader(env: ["CLAUDE_CONFIG_DIR": "/inherited/wrong"]).readNow(rig.account(.claude, dir: acct))
        let line = try #require(rig.lines(rig.log).first)
        #expect(line.contains("|\(acct.path)|oauth=|key=|user=tester|home=\(rig.dir.path)|"))
        #expect(!line.contains("FAKE-") && !line.contains("/inherited/wrong"))
        // Pure function view of the same rule, including the Codex variable.
        let env = SignInProbe.environment(base: ["CLAUDE_CODE_OAUTH_TOKEN": "t", "ANTHROPIC_API_KEY": "k", "CODEX_HOME": "/old", "PATH": "/bin"],
                                          provider: .codex, configDir: "/new")
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == nil && env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["CODEX_HOME"] == "/new" && env["PATH"] == "/bin" && env["USER"] != nil && env["HOME"] != nil)
        let def = SignInProbe.environment(base: ["CODEX_HOME": "/old", "USER": "u", "HOME": "/h"], provider: .codex, configDir: nil)
        #expect(def["CODEX_HOME"] == nil && def["USER"] == "u" && def["HOME"] == "/h")
    }

    // MARK: Codex

    @Test func codexNotSignedInOnlyOnExit1AndExactText() throws {
        let rig = try Rig()
        let acct = try rig.dirMade("cx")
        try rig.codex(out: "Not logged in", exit: 1)
        #expect(rig.reader().readNow(rig.account(.codex, dir: acct)).signIn == .notSignedIn)
        #expect(rig.lines(rig.log)[0] == "CODEX|\(acct.path)|args=login status")
        for (out, code) in [("Not logged in", 0), ("not logged in", 1), ("Not logged in.", 1), ("Not logged in\nplus more", 1),
                            ("Error checking login status: failed to deserialize", 1), ("", 1), ("", 127)] {
            try rig.codex(out: out, exit: code)
            let r = rig.reader().readNow(rig.account(.codex, dir: acct))
            #expect(r.signIn == .unknown, "\(out) / \(code)")
        }
    }

    @Test func codexApiKeyAndOddSignedInTextAreUnknown() throws {
        let rig = try Rig(); let acct = try rig.dirMade("cx")
        for out in ["API key configured - ***", "Logged in using an API key", "Logged in using ChatGPT (extra)", "Logged in"] {
            try rig.codex(out: out, exit: 0)
            #expect(rig.reader().readNow(rig.account(.codex, dir: acct)).signIn == .unknown, "\(out)")
        }
    }

    static func jwt(_ claims: [String: Any]) -> String {
        func b64(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let header = b64(Data(#"{"alg":"none"}"#.utf8))
        let payload = b64(try! JSONSerialization.data(withJSONObject: claims))
        return header + "." + payload + ".sig"
    }

    @Test func codexSignedInReadsEmailAndPlanFromIdTokenClaims() throws {
        let rig = try Rig(); let acct = try rig.dirMade("cx")
        try rig.codex(out: "Logged in using ChatGPT", exit: 0)
        let token = Self.jwt(["email": "a***@example.com", "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]])
        let auth: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["id_token": token, "access_token": "FAKE-ACCESS", "refresh_token": "FAKE-REFRESH"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: acct.appendingPathComponent("auth.json"))
        let r = rig.reader().readNow(rig.account(.codex, dir: acct))
        #expect(r.signIn == .signedIn && r.email == "a***@example.com" && r.plan == "plus")
        #expect(r.note == "Credentials found; not checked with OpenAI.")
        #expect(!String(describing: r).contains("FAKE-"))
    }

    @Test func codexSignedInWithoutIdTokenStaysSignedInWithNothingShown() throws {
        let rig = try Rig(); let acct = try rig.dirMade("cx")
        try rig.codex(out: "Logged in using ChatGPT", exit: 0)
        for body in [nil, "{}", #"{"tokens":{}}"#, "not json", #"{"tokens":{"id_token":"abc"}}"#, #"{"tokens":{"id_token":"a.!!!.c"}}"#] {
            let f = acct.appendingPathComponent("auth.json")
            if let body { try body.write(to: f, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: f) }
            let r = rig.reader().readNow(rig.account(.codex, dir: acct))
            #expect(r.signIn == .signedIn && r.plan == nil && r.email == nil)
        }
    }

    // MARK: reader timing rule

    @Test func readerProbesStoredAccountsOnlyAndDefaultOnlyOnDemand() async throws {
        let rig = try Rig(); try rig.claude(json: Self.signedInJSON, exit: 0)
        let acct = try rig.dirMade("stored")
        let reader = rig.reader()
        reader.store.save([Account(id: "work", provider: .claude, label: "Work", configDir: acct.path)])
        let stored = await reader.readStored()
        #expect(stored.keys.sorted() == ["work"] && stored["work"]?.signIn == .signedIn)
        #expect(rig.lines(rig.log).count == 1 && rig.lines(rig.log)[0].contains("|\(acct.path)|"))   // the live default dir was not touched
        let def = await reader.readDefault(.claude)
        #expect(def.signIn == .signedIn && rig.lines(rig.log).count == 2 && rig.lines(rig.log)[1].hasPrefix("CLAUDE||"))
    }

    @Test func resultLandsInTheSeatSignInField() async throws {
        let rig = try Rig(); try rig.claude(json: Self.signedInJSON, exit: 0)
        let reader = rig.reader()
        let info = await ClaudeSeat().probeSignIn(account: nil, reader: reader)
        #expect(info.signIn == .signedIn && info.plan == "max" && info.installed)
        try rig.claude(json: "garbage", exit: 1)
        let odd = await ClaudeSeat().probeSignIn(account: nil, reader: reader)
        #expect(odd.signIn == .unknown && !odd.signIn.isSignedIn)
    }

    // MARK: ProgramFinder launch probe uses the same reader

    @Test func programFinderClaudeProbeCrossChecksKeychain() throws {
        let rig = try Rig()
        try rig.script("claude", "if [ \"$1\" = '--version' ]; then exit 0; fi\nprintf '%s' '\(Self.loggedOutJSON)'; exit 1")
        func state(security code: Int) throws -> ProgramFinder.Result {
            try rig.security(exit: code)
            return ProgramFinder(environment: ["HOME": rig.dir.path], roots: [rig.bin.path], tailscaleCopies: [], probeTimeout: 30,
                                 securityPath: rig.bin.appendingPathComponent("security").path).inspect("claude")
        }
        let absent = try state(security: 44)
        #expect(absent.state == .notSignedIn && absent.signIn == .notSignedIn)
        let present = try state(security: 0)
        #expect(present.state == .ready && present.signIn == .unknown)
    }

    // MARK: accounts.json

    @Test func accountsFileHoldsPathsAndLabelsOnly() throws {
        let rig = try Rig()
        let store = AccountStore(url: rig.dir.appendingPathComponent("sub/accounts.json"))
        store.save([Account(id: "work", provider: .claude, label: "Work", configDir: "/Users/x/.claude_work"),
                    Account(id: "alt", provider: .codex, label: "Alt", configDir: "/Users/x/.codex_alt")])
        let raw = try String(contentsOf: store.url, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        var keys = Set<String>()
        func walk(_ v: Any) {
            if let d = v as? [String: Any] { for (k, x) in d { keys.insert(k); walk(x) } }
            if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(obj)
        #expect(keys == ["version", "accounts", "id", "provider", "label", "configDir"])
        let banned = try NSRegularExpression(pattern: "token|secret|password|cookie|api_?key|credential|email", options: .caseInsensitive)
        for k in keys { #expect(banned.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) == nil, "\(k)") }
        #expect(!raw.contains("FAKE-"))
        #expect(store.load().count == 2 && store.load()[0].configDir == "/Users/x/.claude_work")
        // Reading sign-in never writes anything into the store.
        try rig.claude(json: Self.signedInJSON, exit: 0)
        _ = rig.reader().readNow(rig.account(.claude, dir: try rig.dirMade("z")))
        #expect(try String(contentsOf: store.url, encoding: .utf8) == raw)
    }

    @Test func corruptOrPartlyBadAccountsFileLoadsWhatItCan() throws {
        let rig = try Rig(); let url = rig.dir.appendingPathComponent("accounts.json")
        let store = AccountStore(url: url)
        #expect(store.load().isEmpty)   // missing file
        try #"{"accounts":[{"id":"a","provider":"claude","label":"A","configDir":"/x"},{"id":"b"},{"id":"c","provider":"nope","label":"C","configDir":"/y"},{"id":"a","provider":"codex","label":"dup","configDir":"/z"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(store.load().map(\.id) == ["a"])
        try "{{{ not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(store.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("accounts.corrupt.json").path))
    }

    @Test func missingReferenceFallsBackToTheDefaultAccount() throws {
        let rig = try Rig()
        let store = AccountStore(url: rig.dir.appendingPathComponent("accounts.json"), defaultClaudeDir: rig.dir.appendingPathComponent("dc"))
        store.save([Account(id: "work", provider: .claude, label: "Work", configDir: "/w")])
        #expect(store.resolve(ref: nil, provider: .claude).isDefault)
        #expect(store.resolve(ref: "gone", provider: .claude).isDefault)
        #expect(store.resolve(ref: "work", provider: .codex).isDefault)   // wrong provider
        let w = store.resolve(ref: "work", provider: .claude)
        #expect(!w.isDefault && w.configDir == "/w")
    }

    // MARK: agents.json

    @Test func oldAndCorruptAgentFilesStillDecodeWithoutAnAccount() throws {
        let old = #"{"agents":[{"name":"lead-x","role":"lead","repo":"/tmp/x"}]}"#
        let file = try JSONDecoder().decode(AgentsFile.self, from: Data(old.utf8))
        #expect(file.agents.count == 1 && file.agents[0].account == nil)
        let bad = #"{"agents":[{"name":"lead-x","role":"lead","repo":"/tmp/x","account":42}]}"#
        #expect(try JSONDecoder().decode(AgentsFile.self, from: Data(bad.utf8)).agents[0].account == nil)
        // Round trip keeps a real reference, and omits the key when there is none.
        var a = Agent(name: "lead-x", role: .lead, repo: "/tmp/x"); a.account = "work"
        let enc = JSONEncoder()
        #expect(try JSONDecoder().decode(Agent.self, from: enc.encode(a)).account == "work")
        #expect(!String(decoding: try enc.encode(Agent(name: "lead-y", role: .lead, repo: "/tmp/y")), as: UTF8.self).contains("account"))
        // Through the real store, an old file loads with every other field intact.
        let rig = try Rig(); let url = rig.dir.appendingPathComponent("agents.json")
        try old.write(to: url, atomically: true, encoding: .utf8)
        let loaded = AgentStore(url: url).load()
        #expect(loaded.map(\.name) == ["lead-x"] && loaded[0].account == nil && loaded[0].seatProvider == .claude)
    }

    // MARK: sign-in command

    @Test func signInCommandUsesProviderLoginWithTheAccountsDirAndRunsNothing() {
        let c = SignInCommand.make(provider: .claude, configDir: "/Users/x/it's dir", executable: "/Users/x/.local/bin/claude")
        #expect(c.argv == ["/Users/x/.local/bin/claude", "auth", "login"])
        #expect(c.env == ["CLAUDE_CONFIG_DIR": "/Users/x/it's dir"])
        #expect(c.unset == ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"])
        #expect(c.shellCommand == #"unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY; export CLAUDE_CONFIG_DIR='/Users/x/it'\''s dir'; exec '/Users/x/.local/bin/claude' 'auth' 'login'"#)
        let x = SignInCommand.make(provider: .codex, configDir: "/h/.codex_alt")
        #expect(x.argv == ["codex", "login"] && x.env == ["CODEX_HOME": "/h/.codex_alt"])
        #expect(x.shellCommand == "unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY; export CODEX_HOME='/h/.codex_alt'; exec 'codex' 'login'")
        // Default account: nothing exported, an inherited config dir variable is cleared.
        let d = SignInCommand.make(provider: .codex, configDir: nil)
        #expect(d.env.isEmpty && d.unset.contains("CODEX_HOME") && !d.shellCommand.contains("export"))
        #expect(SignInCommand.make(provider: .claude, configDir: nil).argv == ["claude", "auth", "login"])
    }
}
