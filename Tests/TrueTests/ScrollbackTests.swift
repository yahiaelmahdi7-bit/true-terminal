import Testing
import Foundation
import SwiftTerm
@testable import True

@Suite struct ScrollbackTests {
    func term(_ cols: Int = 20, _ rows: Int = 6) -> Terminal {
        let t = HeadlessTerminal(onEnd: { _ in }).terminal!
        t.resize(cols: cols, rows: rows)
        return t
    }

    func lines(_ t: Terminal) -> [BufferLine] {
        var out: [BufferLine] = []
        var r = t.buffer.totalLinesTrimmed
        while let l = t.getScrollInvariantLine(row: r) { out.append(l); r += 1 }
        return out
    }

    let sample = "\u{1b}[31mred\u{1b}[0m \u{1b}[92mbright\u{1b}[0m \u{1b}[38;5;200mc256\u{1b}[0m "
        + "\u{1b}[38;2;10;20;30;48;2;1;2;3mtrue\u{1b}[0m \u{1b}[1;3;4mstyle\u{1b}[0m 世界 \u{1b}[2;7mdi\u{1b}[0m\r\n"
        + "this is a long line that must soft wrap around the edge\r\n"
        + (1...8).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n"

    @Test func roundTripKeepsEveryCell() {
        let a = term()
        a.feed(text: sample)
        let text = ScrollbackSerializer.serialize(a)
        #expect(text.contains("\u{1b}["))
        let b = term()
        b.feed(text: text)
        let la = lines(a), lb = lines(b)
        #expect(lb.count >= 10 && la.count >= lb.count)
        for (i, l) in lb.enumerated() {
            #expect(l.isWrapped == la[i].isWrapped, "wrap flag row \(i)")
            for c in 0..<l.count {
                let x = la[i][c], y = l[c]
                #expect(a.getCharacter(for: x) == b.getCharacter(for: y) && x.width == y.width
                        && x.attribute == y.attribute, "row \(i) col \(c)")
            }
        }
        for l in la.dropFirst(lb.count) { #expect(!l.hasAnyContent()) }
    }

    @Test func trailingBlanksTrimmedAndEmptyTailDropped() {
        let a = term()
        a.feed(text: "hi   \r\n\r\n\r\n")
        #expect(ScrollbackSerializer.serialize(a) == "hi")
    }

    @Test func capsLinesAndBytes() {
        let a = term()
        a.feed(text: (1...100).map { "row\($0)" }.joined(separator: "\r\n"))
        let capped = ScrollbackSerializer.serialize(a, maxLines: 10)
        #expect(capped.components(separatedBy: "\r\n") == (91...100).map { "row\($0)" })
        let bytes = ScrollbackSerializer.serialize(a, maxBytes: 30)
        #expect(bytes.utf8.count <= 30 && bytes.hasSuffix("row100") && !bytes.contains("row1\r"))
    }

    @Test func storeIsOneShotOwnerOnlyAndPrunes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("true-sb-\(UUID().uuidString)")
        let store = ScrollbackStore(dir: dir)
        let p = UUID(), gone = UUID()
        let h = ScrollbackStore.Header(cols: 80, rows: 24, savedAt: Date(timeIntervalSince1970: 1_790_000_000), wasRunning: "npm")
        store.save(pane: p, text: "abc", header: h)
        store.save(pane: gone, text: "x", header: h)
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("\(p.uuidString).ans").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        store.prune(keeping: [p])
        #expect(store.take(gone) == nil)
        let snap = try #require(store.take(p))
        #expect(snap.bytes == Array("abc".utf8) && snap.header == h)
        #expect(store.take(p) == nil)
        #expect(ScrollbackStore.markerLine(h).contains("was running: npm"))
        var h2 = h; h2.wasRunning = nil
        #expect(!ScrollbackStore.markerLine(h2).contains("was running"))
    }
}
