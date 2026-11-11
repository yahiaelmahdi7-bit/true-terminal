import Testing
import Foundation
import TrueRemoteClient
@testable import True

/// M0: when the mask cuts part of a line, the sender is told the kind and place of each cut, never the secret.
@Suite(.serialized) struct MaskNoticeTests {
    /// One fake secret per mask pattern, in table order. `prefix text ` keeps each secret at a known character offset (8).
    static let perPattern: [(key: String, secret: String)] = [
        ("secret_key", "sk-FAKEFAKEFAKE1234"),
        ("github_token", "ghp_FAKEFAKEFAKE1234"),
        ("bearer_token", "Bearer FAKEFAKE123456"),
        ("hex_secret", String(repeating: "ab12", count: 8)),
        ("private_key", "-----BEGIN RSA PRIVATE KEY-----FAKEFAKE-----END RSA PRIVATE KEY-----"),
        ("pgp_key", "-----BEGIN PGP PRIVATE KEY BLOCK-----FAKEFAKE-----END PGP PRIVATE KEY BLOCK-----"),
        ("password_line", "password: FAKEFAKE"),
        ("credential", "token=FAKEVALUE98765"),
        ("resend_key", "re_FAKEFAKEFAKEFAKE1234"),
        ("aws_key", "AKIAFAKEFAKEFAKE1234"),
        ("jwt", "eyJFAKEFAKE1.FAKEFAKE12.FAKEFAKE34"),
        ("slack_token", "xoxb-FAKE123456789"),
        ("github_token", "github_pat_FAKEFAKEFAKEFAKEFAKE1"),
        ("stripe_key", "sk_live_FAKEFAKE1234"),
        ("google_key", "AIza" + String(repeating: "x1", count: 16)),
        ("gitlab_token", "glpat-" + String(repeating: "a1", count: 11)),
        ("url_password", "://bob:FAKEPASS@"),
        ("welcome_code", "bob-K7M2PQ9XTV"),
        ("welcome_code", "ann-k7m2pq9xtv"),
        ("session_token", "Q" + String(repeating: "z", count: 42)),
    ]

    @Test func everyPatternHasACaseWithKindAndPlace() {
        for (key, secret) in Self.perPattern {
            let kind = ChatMask.phrase(key)
            // passwords mask to the end of the line, so that case has nothing after it
            let toEnd = key == "password_line"
            let line = toEnd ? "before \(secret)" : "before \(secret) after"
            let r = PeerMask.report(line)
            #expect(r.masked == PeerMask.mask(line), "report must match mask for \(kind)")
            #expect(r.cuts.count == 1, "\(kind): \(r.cuts)")
            guard let c = r.cuts.first else { continue }
            #expect(c.kind == kind, "\(kind) got \(c.kind)")
            #expect(c.offset == 8, "\(kind) offset \(c.offset)")
            #expect(c.length == secret.count, "\(kind) length \(c.length)")
            #expect(!r.masked.contains(secret))
            #expect(!c.phrase.contains(secret) && !c.kind.contains("FAKE"))
        }
        // one case per mask rule, in rule order: a new rule with no case here fails
        #expect(Self.perPattern.count == PeerMask.kinds.count)
        for (case_, rule) in zip(Self.perPattern, ChatMask.rules) { #expect(case_.key == rule.kind, "case for \(case_.key) is not the rule \(rule.kind)") }
    }

    /// Same fixture the chat client and Steward run: every single-line case must mask identically here.
    @Test func fixtureLinesMaskTheSameAsTheChatClient() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TrueRemoteClientTests/Fixtures/mask-lines.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        var checked = 0
        func walk(_ v: Any) {
            if let a = v as? [Any] { a.forEach(walk) }
            else if let d = v as? [String: Any] {
                if let input = d["line"] as? String, let want = d["masked"] as? String {
                    #expect(PeerMask.mask(input) == want, "PeerMask differs from the fixture on \(d["name"] ?? "?")")
                    checked += 1
                } else { d.values.forEach(walk) }
            }
        }
        walk(json)
        #expect(checked > 10, "fixture shape changed: only \(checked) lines checked")
    }

    @Test func reportAgreesWithMaskOnFuzzedLines() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) }
        let bits = Self.perPattern.map(\.secret) + ["password==", "token:", "secret = ", "bearer ", "Bearer", "://", "@", "AKIA", "sk-", "re_", "ghp_",
                                                    "eyJ", "xoxb-", "abc123def", " ", "  ", "\n", "x", "é", "👍", "=", ":", "1234", "token=", "api_key: "]
        var bad = 0
        for _ in 0..<100_000 {
            let line = (0..<(1 + next(5))).map { _ in bits[next(bits.count)] }.joined()
            let r = PeerMask.report(line)
            let want = PeerMask.mask(line)
            var rebuilt = "", at = line.startIndex, sorted = true, last = 0
            for c in r.cuts {
                if c.offset <= last { sorted = false }
                let lo = line.index(line.startIndex, offsetBy: c.offset - 1), hi = line.index(lo, offsetBy: c.length)
                rebuilt += line[at..<lo] + "‹masked›"; at = hi; last = c.offset + c.length - 1
            }
            rebuilt += line[at...]
            if r.masked != want || rebuilt != want || !sorted { bad += 1; if bad < 4 { Issue.record("report/mask disagree on \(line.debugDescription): \(r)") } }
        }
        #expect(bad == 0)
    }

    @Test func adjacentSecretsAreReportedAsMaskHidesThem() {
        let r = PeerMask.report("AKIAFAKEFAKEFAKE1234 password==")
        #expect(r.masked == PeerMask.mask("AKIAFAKEFAKEFAKE1234 password=="))
        #expect(r.cuts.map { [$0.offset, $0.length] } == [[1, 20], [22, 10]])     // the key and the password are both named
    }

    @Test func aCleanLineHasNoCuts() {
        for s in ["Fixed the login bug", "The token bucket limits to 20 per minute", "see https://example.com/docs", ""] {
            let r = PeerMask.report(s)
            #expect(r.cuts.isEmpty && r.masked == s)
            #expect(ChatNaming.maskNotice(ChatNaming.maskCuts(s)) == nil)
        }
    }

    @Test func theStagingLinkCase() {
        let line = "open https://staging.example.com/join?token=FAKELINKVALUE123 now"
        let cuts = ChatNaming.maskCuts(line)
        #expect(cuts.count == 1 && cuts[0].offset == 39)
        let notice = ChatNaming.maskNotice(cuts) ?? ""
        #expect(notice.hasPrefix("Part of this message was hidden") && !notice.contains("FAKELINKVALUE123"))
    }

    @Test func overlapsAndSeveralCutsStayDistinctAndOrdered() {
        // a password cuts to the end of the line, so it goes last
        let line = "sk-FAKEFAKEFAKE1234 and AKIAFAKEFAKEFAKE1234 then a password: hunter2"
        let r = PeerMask.report(line)
        #expect(r.masked == PeerMask.mask(line))
        #expect(r.cuts.count == 3 && r.cuts[0].offset < r.cuts[1].offset && r.cuts[1].offset < r.cuts[2].offset)
        #expect(r.cuts[0].offset == 1)
    }

    @Test func offsetsCountCharactersNotBytes() {
        let cuts = ChatNaming.maskCuts("héllo 👍 token=FAKEVALUE98765")
        #expect(cuts.first?.offset == 9)
    }

    // MARK: the CLI, end to end

    func rig() -> (side: PeerSide, sock: String, run: (_ args: [String], _ env: [String: String]) throws -> (out: String, err: String, code: Int32)) {
        let side = PeerSide("Al", relay: FakeRelay(), clock: Clock())
        _ = side.attachChat()
        let sock = "/tmp/tc-\(UUID().uuidString.prefix(8)).sock"
        let engine = side.engine
        let server = PeerSocket(path: sock) { engine }
        #expect(server.start())
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("true-chat-\(UUID().uuidString)")
        try? ChatCLI.script(socketPath: sock).write(to: script, atomically: true, encoding: .utf8)
        func run(_ args: [String], _ env: [String: String]) throws -> (out: String, err: String, code: Int32) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-I", script.path] + args
            p.environment = ["TRUE_PEER_SOCK": sock, "PATH": "/usr/bin:/bin"].merging(env) { $1 }
            let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
            try p.run()
            let od = o.fileHandleForReading.readDataToEndOfFile(), ed = e.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self), p.terminationStatus)
        }
        return (side, sock, run)
    }

    @Test func sendWithASecretSaysWhatWasCutAndExitsThree() throws {
        let r = rig(); defer { r.side.close(); try? FileManager.default.removeItem(atPath: r.sock) }
        let secret = "FAKELINKVALUE123"
        let res = try r.run(["send", "#here", "open https://staging.example.com/join?token=\(secret) now"], [:])
        #expect(res.code == 3)
        #expect(res.err.hasPrefix("Part of this message was hidden:") && res.err.contains("at character 39"))
        #expect(!res.err.contains(secret) && !res.out.contains(secret))
        // the line still went out, masked as before
        let tail = try r.run(["tail", "#here", "-n", "1"], [:])
        #expect(tail.code == 0 && tail.out.contains("‹masked›") && !tail.out.contains(secret))
        print("EXIT", res.code, "STDERR:", res.err, "STDOUT:", res.out, "TAIL:", tail.out)
    }

    @Test func aCleanSendIsSilentAndExitsZero() throws {
        let r = rig(); defer { r.side.close(); try? FileManager.default.removeItem(atPath: r.sock) }
        let res = try r.run(["send", "#here", "standup in five"], [:])
        #expect(res.code == 0 && res.err.isEmpty && res.out.isEmpty)
        print("EXIT", res.code, "STDERR:", res.err)
    }

    @Test func aFailedSendKeepsItsOwnCode() throws {
        let r = rig(); defer { r.side.close(); try? FileManager.default.removeItem(atPath: r.sock) }
        let res = try r.run(["send", "nope", "x"], [:])
        #expect(res.code == 1)
        let gone = try r.run(["send", "#here", "x"], ["TRUE_PEER_SOCK": "/tmp/tc-missing.sock"])
        #expect(gone.code == 2)
    }
}
