import Testing
import Foundation
@testable import True

@MainActor
struct ClipboardShareTests {
    final class Fake: @unchecked Sendable {
        var snap = ClipboardShare.Snapshot(changeCount: 1, types: ["public.utf8-plain-text"], text: nil)
        func copy(_ text: String?, types: [String] = ["public.utf8-plain-text"]) {
            snap = .init(changeCount: snap.changeCount + 1, types: types, text: text)
        }
    }

    func makeShare() -> (ClipboardShare, Fake, RemoteInbox, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("true-clip-\(UUID().uuidString)")
        let inbox = RemoteInbox(root: root)
        let fake = Fake()
        return (ClipboardShare(read: { fake.snap }, inbox: inbox), fake, inbox, root)
    }

    @Test func changeSharesOnceAndReplaces() throws {
        let (share, fake, inbox, root) = makeShare(); defer { try? FileManager.default.removeItem(at: root) }
        inbox.add(name: "a.txt", kind: .file, data: Data("file".utf8))
        fake.copy("one"); share.tick()
        share.tick()                                   // unchanged count → nothing
        #expect(inbox.list().filter { $0.source == .clipboardShare }.count == 1)
        fake.copy("one"); share.tick()                 // same text again → no new item
        fake.copy("two"); share.tick()
        let shared = inbox.list().filter { $0.source == .clipboardShare }
        #expect(shared.count == 1)
        #expect(inbox.previewText(shared[0].id) == "two")
        #expect(inbox.list().count == 2)               // the file was never evicted
    }

    @Test func concealedAndEmptyAreSkipped() {
        let (share, fake, inbox, root) = makeShare(); defer { try? FileManager.default.removeItem(at: root) }
        fake.copy("hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]); share.tick()
        fake.copy(nil); share.tick()
        fake.copy(""); share.tick()
        #expect(inbox.list().isEmpty)
    }

    @Test func phonePushDoesNotEchoBack() {
        let (share, fake, inbox, root) = makeShare(); defer { try? FileManager.default.removeItem(at: root) }
        share.noteExternal("from phone")
        fake.copy("from phone"); share.tick()
        #expect(inbox.list().isEmpty)
    }

    @Test func timerRunsOnlyWhileStarted() {
        let (share, _, _, root) = makeShare(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(!share.isRunning)
        share.start(); #expect(share.isRunning)
        share.stop(); #expect(!share.isRunning)
    }

    @Test func oldIndexWithoutSourceStillDecodes() throws {
        let json = #"[{"id":"0011223344556677","name":"x","kind":"text","size":1,"created":1}]"#
        let items = try JSONDecoder().decode([PhoneInboxItem].self, from: Data(json.utf8))
        #expect(items[0].source == nil)
    }
}
