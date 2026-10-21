import Testing
import Foundation
import TrueRemoteClient
@testable import True

@Suite struct PairLinkTests {
    @Test func linkCarriesHostAndCodeAndRoundTrips() throws {
        let s = RemoteAccess.pairLink(host: "mac.tail1234.ts.net:8444", code: "123456")
        #expect(s == "true://pair?host=mac.tail1234.ts.net:8444&code=123456")
        let url = try #require(URL(string: s))
        let p = try #require(PairLink(url: url))
        #expect(p.address == "mac.tail1234.ts.net:8444")
        #expect(p.code == "123456")
    }

    @Test func codeIsOmittedWhenThereIsNone() throws {
        let s = RemoteAccess.pairLink(host: "mac.ts.net:8444", code: nil)
        #expect(!s.contains("code"))
        let p = try #require(PairLink(string: s))
        #expect(p.address == "mac.ts.net:8444")
        #expect(p.code == nil)
    }

    @Test func rejectsWrongSchemeHostPathAndBadCodes() {
        #expect(PairLink(string: "https://pair?host=a.b:1&code=123456") == nil)
        #expect(PairLink(string: "true://pane/abc") == nil)
        #expect(PairLink(string: "true://pair?host=a.b/evil&code=123456") == nil)
        #expect(PairLink(string: "true://pair?host=https://a.b&code=123456") == nil)
        #expect(PairLink(string: "true://pair?host=a.b:1&code=12345") == nil)
        #expect(PairLink(string: "true://pair?host=a.b:1&code=12345a") == nil)
        #expect(PairLink(string: "true://pair?code=123456") == nil)
        #expect(PairLink(string: "true://pair/x?host=a.b:1") == nil)
    }
}
