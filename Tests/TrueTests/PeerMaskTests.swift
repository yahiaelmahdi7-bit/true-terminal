import Testing
import Foundation
@testable import True

/// Run 36a step 3 (A3): the mask table, and what each share level lets out.
@Suite struct PeerMaskTests {
    static let cases: [(String, String)] = [
        ("-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----", "MIIEowIBAAKCAQEA"),
        ("export API_KEY=hunter2hunter2", "hunter2hunter2"),
        ("password: correcthorse", "correcthorse"),
        ("send with re_AbCdEf0123456789xyz now", "re_AbCdEf0123456789xyz"),
        ("aws AKIAIOSFODNN7EXAMPLE end", "AKIAIOSFODNN7EXAMPLE"),
        ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3.SflKxwRJSMeKKF2QT4fw here", "SflKxwRJSMeKKF2QT4fw"),
        ("slack xoxb-1234567890-abcdefghij", "xoxb-1234567890-abcdefghij"),
        ("github_pat_11ABCDEFG0123456789abcdef", "github_pat_11ABCDEFG0123456789abcdef"),
        ("key sk_live_abcdef123456", "sk_live_abcdef123456"),
        ("git clone https://bob:s3cretpw@example.com/x.git", "s3cretpw"),
        ("Bearer abcdef123456", "abcdef123456"),
    ]

    @Test func secretsAreMasked() {
        for (input, secret) in Self.cases {
            let out = PeerMask.mask(input)
            #expect(!out.contains(secret), "leaked from: \(input)")
            #expect(out.contains("‹masked›"), "no mask in: \(input)")
        }
    }

    @Test func plainProseUntouched() {
        for s in ["Fixed the login bug in auth.swift", "Ran 12 tests, all passed", "Use https://example.com/docs for details",
                  "The token bucket limits to 20 per minute", "a 7-line change"] {
            #expect(PeerMask.mask(s) == s)
        }
    }

    @Test func activityHidesCommandsEverythingShowsThem() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func text(_ level: PeerShare, tool: String, detail: String?) -> String {
            PeerEngine.items(kind: .progress, message: tool, tool: tool, detail: detail, at: at, level: level).first?.text ?? ""
        }
        #expect(text(.activity, tool: "Bash", detail: "npm test --token=abc12345") == "Bash")
        #expect(text(.everything, tool: "Bash", detail: "npm test --token=abc12345") == "Bash · npm test --‹masked›")
        #expect(text(.activity, tool: "Read", detail: "/src/a.swift") == "Read · /src/a.swift")
        #expect(text(.activity, tool: "WebFetch", detail: "https://example.com/private?x=1") == "WebFetch · example.com")
        #expect(text(.activity, tool: "Task", detail: "do secret thing") == "Task")
        #expect(text(.everything, tool: "Task", detail: "do the thing") == "Task · do the thing")
    }

    @Test func assistantLengthByLevel() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let long = String(repeating: "word ", count: 3_000)
        let a = PeerEngine.items(kind: .stop, message: long, tool: nil, detail: nil, at: at, level: .activity)
        let e = PeerEngine.items(kind: .stop, message: long, tool: nil, detail: nil, at: at, level: .everything)
        #expect(a.first?.text.count == 1024)
        #expect(e.first?.text.count == 8 * 1024)
    }
}
