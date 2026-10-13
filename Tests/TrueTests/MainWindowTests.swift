import AppKit
import Testing
@testable import True

@MainActor
@Suite struct MainWindowTests {
    private func window(_ title: String) -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        w.title = title
        w.isReleasedWhenClosed = false
        return w
    }

    private func id(_ w: NSWindow?) -> ObjectIdentifier? { w.map(ObjectIdentifier.init) }

    @Test func onlyTheMainWindowLosesItsButtons() {
        let main = window("True"), settings = window("True Settings"), remote = window("Remote Access")
        #expect(MainWindow.shouldHideButtons(window: ObjectIdentifier(main), main: id(main)))
        #expect(!MainWindow.shouldHideButtons(window: ObjectIdentifier(settings), main: id(main)))
        #expect(!MainWindow.shouldHideButtons(window: ObjectIdentifier(remote), main: id(main)))
        #expect(!MainWindow.shouldHideButtons(window: ObjectIdentifier(settings), main: nil))
    }

    @Test func mainWindowSnapshots() {
        let main = window("True")
        #expect(MainWindow.shouldSnapshot(closing: id(main), main: id(main)))
    }

    @Test func retitledMainWindowStillSnapshots() {
        let main = window("~/Projects/true")
        #expect(MainWindow.shouldSnapshot(closing: id(main), main: id(main)))
    }

    @Test func titlelessSheetLikeWindowDoesNot() {
        let sheet = window(""), main = window("True")   // kept alive: a freed window could reuse an address
        #expect(!MainWindow.shouldSnapshot(closing: id(sheet), main: id(main)))
    }

    @Test func otherWindowTitledTrueDoesNot() {
        let other = window("True"), main = window("True")
        #expect(!MainWindow.shouldSnapshot(closing: id(other), main: id(main)))
    }

    @Test func noMainCapturedOrNoWindowDoesNot() {
        let w = window("True")
        #expect(!MainWindow.shouldSnapshot(closing: id(w), main: id(nil)))
        #expect(!MainWindow.shouldSnapshot(closing: id(nil), main: id(w)))
    }
}
