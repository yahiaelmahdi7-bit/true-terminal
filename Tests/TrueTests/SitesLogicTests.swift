import Testing
import Foundation
@testable import True

@Suite("SitesLogic")
struct SitesLogicTests {
    @Test func portFilter() {
        #expect(SitesLogic.isWebCandidate(port: 3000))
        #expect(SitesLogic.isWebCandidate(port: 8765))
        #expect(!SitesLogic.isWebCandidate(port: 80))
        #expect(!SitesLogic.isWebCandidate(port: 1023))
        for p in [5432, 6379, 27017, 3306, 9229, 443, 8444, 8800, 8801] { #expect(!SitesLogic.isWebCandidate(port: p)) }
    }

    @Test func lsofParsingKeepsLoopbackAndWildcardOnly() {
        let out = "p100\ncnode\nn*:3000\nn127.0.0.1:3000\np200\ncpython3\nn[::1]:8765\nn192.168.1.5:9000\n"
        let l = SitesLogic.parseLsof(out)
        #expect(l == [.init(pid: 100, command: "node", port: 3000), .init(pid: 200, command: "python3", port: 8765)])
    }

    @Test func psParsing() {
        #expect(SitesLogic.parsePs("  10     1\n  11    10\nbad\n") == [10: 1, 11: 10])
    }

    @Test func descendantMatch() {
        let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 11, 20: 1, 21: 20]
        #expect(SitesLogic.descendants(of: 10, parents: parents) == [11, 12])
        #expect(SitesLogic.descendants(of: 20, parents: parents) == [21])
        // cycle must not hang
        #expect(SitesLogic.descendants(of: 5, parents: [6: 7, 7: 6]).isEmpty)
    }

    @Test func attributionDropsForeignAndNonWeb() {
        let paneA = UUID(), paneB = UUID()
        let parents: [Int32: Int32] = [10: 1, 11: 10, 20: 1, 21: 20, 30: 1]
        let ls: [SitesLogic.Listener] = [
            .init(pid: 11, command: "node", port: 3000),
            .init(pid: 21, command: "python", port: 8765),
            .init(pid: 11, command: "node", port: 5432),     // non-web
            .init(pid: 30, command: "foreign", port: 4000),  // no pane ancestor
        ]
        let r = SitesLogic.attribute(listeners: ls, shells: [paneA: 10, paneB: 20], parents: parents)
        #expect(r.count == 2)
        #expect(r.first { $0.listener.port == 3000 }?.pane == paneA)
        #expect(r.first { $0.listener.port == 8765 }?.pane == paneB)
    }

    @Test func allocationAvoidsTakenAndForeign() {
        #expect(SitesLogic.allocate(preferred: 3000, taken: [443, 8444]) == 3000)
        #expect(SitesLogic.allocate(preferred: 3000, taken: [3000]) == 8450)
        #expect(SitesLogic.allocate(preferred: 8444, taken: []) == 8450)
        #expect(SitesLogic.allocate(preferred: 443, taken: []) == 8450)
        #expect(SitesLogic.allocate(preferred: 3000, taken: [3000, 8450, 8451]) == 8452)
        #expect(SitesLogic.allocate(preferred: 3000, taken: Set([3000] + Array(8450...8499))) == nil)
    }

    @Test func servePortsFromStatus() {
        let json = #"{"TCP":{"443":{"HTTPS":true},"8444":{"HTTPS":true}},"Web":{"h.ts.net:443":{},"h.ts.net:8444":{}}}"#
        #expect(SitesLogic.servePorts(fromStatus: Data(json.utf8)) == [443, 8444])
        #expect(SitesLogic.servePorts(fromStatus: Data("{}".utf8)).isEmpty)
    }

    @Test func ownershipOnlyCleanup() {
        let o = SiteOwnership(mappings: [3000: 3000, 4000: 8450])
        #expect(o.stale(livePorts: [3000]) == [4000])
        #expect(o.stale(livePorts: []) == [3000, 4000])
        #expect(o.mayRemove(servePort: 8450))
        #expect(!o.mayRemove(servePort: 8444))
        #expect(!o.mayRemove(servePort: 443))
    }

    @Test func titleExtraction() {
        #expect(SitesLogic.title(fromHTML: "<html><head><TITLE>\n  My   App \n</TITLE>") == "My App")
        #expect(SitesLogic.title(fromHTML: "<p>none</p>") == nil)
        #expect(SitesLogic.title(fromHTML: "<title></title>") == nil)
    }

    @Test func blockedHostDetection() {
        #expect(SitesLogic.blockedHostFix(status: 403, body: "Blocked request. This host (\"x.ts.net\") is not allowed.")?.framework == "Vite")
        #expect(SitesLogic.blockedHostFix(status: 200, body: "Cross origin request detected from x")?.snippet == "allowedDevOrigins: ['*.ts.net']")
        #expect(SitesLogic.blockedHostFix(status: 403, body: "Invalid Host header")?.framework == "webpack-dev-server")
        #expect(SitesLogic.blockedHostFix(status: 200, body: "<html>hello</html>") == nil)
    }
}
