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

    // MARK: shared vectors with Steward's card masker (true-cloud steward/tests/mask_vectors.json, run there by test_mask.py)
    struct Vector: Decodable { let name: String; let input: String; let expected: String }
    static let vectorsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mask_vectors.json")

    static func vectors() throws -> [Vector] {
        struct File: Decodable { let vectors: [Vector] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: vectorsURL)).vectors
    }

    /// Steward masks a job card in Python; a Mac masks a share line in Swift. The same input must come out the same on both,
    /// so a card and a chat line cut a secret identically (a password line goes to its end as one ‹masked›).
    @Test func everySharedVectorMasksTheSameAsSteward() throws {
        let vs = try Self.vectors()
        #expect(vs.count >= 15)
        for v in vs {
            #expect(PeerMask.mask(v.input) == v.expected, "vector \(v.name)")
        }
    }

    @Test func passwordLineIsCutToItsEndAsOneMask() {
        #expect(PeerMask.mask("password = hunter2 and TOKEN:abc") == "‹masked›")
        #expect(PeerMask.mask("ok\npassword: a b c\nnext") == "ok\n‹masked›\nnext")
    }

    static var trueCloudVectors: URL {
        let dir = ProcessInfo.processInfo.environment["TRUE_CLOUD_DIR"] ?? NSHomeDirectory() + "/Projects/true-cloud"
        return URL(fileURLWithPath: dir).appendingPathComponent("steward/tests/mask_vectors.json")
    }

    /// Skipped (like ChatPureTests' fixture check) where no true-cloud checkout with the file exists; set TRUE_CLOUD_DIR.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: PeerMaskTests.trueCloudVectors.path),
                   "set TRUE_CLOUD_DIR to a true-cloud checkout that has steward/tests/mask_vectors.json"))
    func vectorsCopyMatchesTrueCloudByteForByte() throws {
        #expect(try Data(contentsOf: Self.trueCloudVectors) == Data(contentsOf: Self.vectorsURL),
                "mask_vectors.json differs from true-cloud's copy")
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
        #expect(text(.everything, tool: "Bash", detail: "npm test --token=abc12345") == "Bash · npm test ‹masked›")
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
