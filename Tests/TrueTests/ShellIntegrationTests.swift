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

@Suite struct InlineSuggestionTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("true-shim-\(UUID().uuidString)")

    @Test func shimLoadsAutosuggestionsOnlyWhenUserHasNot() {
        let z = ShellIntegration.zshenv
        #expect(z.contains("(( $+functions[_zsh_autosuggest_start] ))"))
        #expect(z.contains("source $_true_dir/zsh-autosuggestions.zsh"))
        #expect(z.contains("ZSH_AUTOSUGGEST_STRATEGY=(history completion)"))
        #expect(z.contains("(( $+functions[compdef] )) || {"))   // compinit only when not already loaded
        #expect(z.contains("zstyle -L ':completion:*'"))        // menu-select only without the user's own styles
        #expect(z.contains("bindkey '^[[1;3C' forward-word"))
    }

    @Test func offSwitchIsHandedToTheShim() throws {
        var on = [String: String](), off = [String: String]()
        ShellIntegration.apply(to: &on, shell: "/bin/zsh", dir: dir, inlineSuggestions: true)
        ShellIntegration.apply(to: &off, shell: "/bin/zsh", dir: dir, inlineSuggestions: false)
        #expect(on["TRUE_INLINE_SUGGEST"] == "1")
        #expect(off["TRUE_INLINE_SUGGEST"] == "0")
        #expect(ShellIntegration.zshenv.contains("_true_suggest=${TRUE_INLINE_SUGGEST:-1}"))
        #expect(ShellIntegration.zshenv.contains("[[ $_true_suggest != 0 &&"))
    }

    @Test func vendoredFilesAreWrittenBesideTheShim() throws {
        var env = [String: String]()
        ShellIntegration.apply(to: &env, shell: "/bin/zsh", dir: dir)
        #expect(try String(contentsOf: dir.appendingPathComponent("zsh-autosuggestions.zsh"), encoding: .utf8) == ZshAutosuggestions.source)
        #expect(try String(contentsOf: dir.appendingPathComponent("LICENSE-zsh-autosuggestions"), encoding: .utf8).contains("Permission is hereby granted"))
        #expect(ZshAutosuggestions.source.contains("_zsh_autosuggest_start()"))
    }

    @Test func otherShellsGetNoSwitch() {
        var env = [String: String]()
        ShellIntegration.apply(to: &env, shell: "/bin/bash", dir: dir)
        #expect(env.isEmpty)
    }
}

@Suite struct ClaudeAutostartTests {
    @Test func defaultIsOnUnlessPlistSaysFalse() {
        #expect(TerminalSettings.claudeAutostartDefault(info: nil))
        #expect(TerminalSettings.claudeAutostartDefault(info: [:]))
        #expect(TerminalSettings.claudeAutostartDefault(info: ["TrueClaudeAutostartDefault": true]))
        #expect(!TerminalSettings.claudeAutostartDefault(info: ["TrueClaudeAutostartDefault": false]))
    }

    @MainActor private func model(on: Bool, file: String? = nil) throws -> (WorkspaceModel, PaneStartup) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("true-as-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let store = WorkspaceStore(url: d.appendingPathComponent("w.json"))
        let startup = PaneStartup()
        if file == "restored" {   // a previous run's workspace: one plain shell tab
            store.save(WorkspaceState.fresh())
        }
        return (WorkspaceModel(store: store, claudeDir: d, settings: "/s.json", startup: startup, claudeAutostart: { on }), startup)
    }

    @Test @MainActor func newTabRegistersClaudeWhenOn() throws {
        let (m, s) = try model(on: true, file: "restored")
        _ = s.take(m.selectedTab.focusedPane)
        m.newTab()
        #expect(s.take(m.selectedTab.focusedPane) == PaneStartup.claudeCommand(settings: "/s.json"))
    }

    @Test @MainActor func newTabIsPlainWhenOff() throws {
        let (m, s) = try model(on: false, file: "restored")
        m.newTab()
        #expect(s.take(m.selectedTab.focusedPane) == nil)
    }

    @Test @MainActor func splitsStayPlain() throws {
        let (m, s) = try model(on: true, file: "restored")
        _ = s.take(m.selectedTab.focusedPane)
        let new = m.split(.horizontal, cwd: nil)
        #expect(s.take(new) == nil)
    }

    @Test @MainActor func freshBootStartsClaudeOnlyWhenNothingWasRestored() throws {
        let (fresh, fs) = try model(on: true)
        #expect(fs.take(fresh.selectedTab.focusedPane) == PaneStartup.claudeCommand(settings: "/s.json"))
        let (restored, rs) = try model(on: true, file: "restored")
        #expect(rs.take(restored.selectedTab.focusedPane) == nil)
        let (off, os) = try model(on: false)
        #expect(os.take(off.selectedTab.focusedPane) == nil)
    }
}
