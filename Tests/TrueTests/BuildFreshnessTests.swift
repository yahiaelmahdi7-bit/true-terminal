import Testing
import Foundation
@testable import True

@Suite struct BuildFreshnessTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    @Test func sameStampIsFresh() {
        let s = BinaryStamp(inode: 5, modified: t0)
        #expect(!BuildFreshness.isStale(launched: s, current: s))
    }
    @Test func newInodeIsStale() {
        let s = BinaryStamp(inode: 5, modified: t0)
        #expect(BuildFreshness.isStale(launched: s, current: BinaryStamp(inode: 6, modified: t0)))
    }
    @Test func newMtimeIsStale() {
        let s = BinaryStamp(inode: 5, modified: t0)
        #expect(BuildFreshness.isStale(launched: s, current: BinaryStamp(inode: 5, modified: t0 + 1)))
    }
    @Test func missingFileIsStale() {
        #expect(BuildFreshness.isStale(launched: BinaryStamp(inode: 5, modified: t0), current: nil))
    }
    @Test func relauncherKeepsInputsOutOfScript() {
        let path = "/Apps/My \"True\"; rm -rf ~/True.app"
        let a = BuildFreshness.relauncherArguments(pid: 42, bundlePath: path)
        #expect(a.count == 5)
        #expect(a[0] == "-c" && a[2] == "sh" && a[3] == "42" && a[4] == path)
        #expect(!a[1].contains("42") && !a[1].contains("rm -rf") && !a[1].contains("open -n"))
        #expect(a[1].contains("-ge 300 ] && exit 0"))
        #expect(a[1].contains("kill -0 \"$1\"") && a[1].contains("/usr/bin/open \"$2\""))
    }
    @Test func warningWording() {
        #expect(BuildFreshness.workingWarning(0) == nil)
        #expect(BuildFreshness.workingWarning(1) == "1 Claude session in True is mid-task. They will pick up where they left off after the restart.")
        #expect(BuildFreshness.workingWarning(3) == "3 Claude sessions in True are mid-task. They will pick up where they left off after the restart.")
    }
    @Test func descendantsWalkTheTreeSafely() {
        let tree: [pid_t: [pid_t]] = [1: [2, 3], 2: [4], 4: [5], 5: [6], 6: [7], 3: [1], 9: [10]]
        let kids: (pid_t) -> [pid_t] = { tree[$0] ?? [] }
        #expect(BuildFreshness.descendants(of: 1, children: kids) == [2, 3, 4, 5, 6, 7])   // default depth 6, cycle 3->1 ignored
        #expect(BuildFreshness.descendants(of: 1, children: kids, maxDepth: 4) == [2, 3, 4, 5, 6])
        #expect(BuildFreshness.descendants(of: 1, children: kids, maxDepth: 1) == [2, 3])
        #expect(BuildFreshness.descendants(of: 8, children: kids).isEmpty)
    }
    @Test func statReadsRealFile() {
        #expect(BinaryStamp.read(URL(fileURLWithPath: "/bin/sh")) != nil)
        #expect(BinaryStamp.read(URL(fileURLWithPath: "/nonexistent/x")) == nil)
    }
}
