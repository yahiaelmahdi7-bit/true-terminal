import CoreGraphics
import Testing
@testable import True

struct MainWindowSpanTests {
    @Test func spansThreeSideBySideScreens() {
        let screens = [CGRect(x: -1920, y: 0, width: 1920, height: 1055),
                       CGRect(x: 0, y: 0, width: 1920, height: 1055),
                       CGRect(x: 1920, y: 0, width: 2560, height: 1415)]
        #expect(MainWindow.spanningFrame(screens) == CGRect(x: -1920, y: 0, width: 6400, height: 1415))
    }
    @Test func noScreensGivesNil() { #expect(MainWindow.spanningFrame([]) == nil) }
}
