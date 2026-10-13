import Testing
import Foundation
@testable import True

@Suite struct ShellIntegrationTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("true-shim-\(UUID().uuidString)")

    @Test func zshIsRoutedThroughTheShimAndKeepsItsOwnZdotdir() throws {
        var env = ["HOME": "/Users/x"]
        ShellIntegration.apply(to: &env, shell: "/bin/zsh", dir: dir)
        #expect(env["ZDOTDIR"] == dir.path)
        #expect(env["TRUE_USER_ZDOTDIR"] == nil)   // none before → the shim unsets ZDOTDIR again
        #expect(try String(contentsOf: dir.appendingPathComponent(".zshenv"), encoding: .utf8) == ShellIntegration.zshenv)

        var custom = ["ZDOTDIR": "/Users/x/.config/zsh"]
        ShellIntegration.apply(to: &custom, shell: "/opt/homebrew/bin/zsh", dir: dir)
        #expect(custom["TRUE_USER_ZDOTDIR"] == "/Users/x/.config/zsh")
        #expect(custom["ZDOTDIR"] == dir.path)
    }

    @Test func otherShellsAreLeftAlone() {
        var env = ["ZDOTDIR": "/z"]
        ShellIntegration.apply(to: &env, shell: "/bin/bash", dir: dir)
        #expect(env == ["ZDOTDIR": "/z"])
    }
}
