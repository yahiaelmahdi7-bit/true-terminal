import Foundation

/// Every command a True shell runs is written to history the moment it's entered, so history
/// survives quit, crash and force-quit alike. Stock macOS zsh writes history only when a shell
/// exits cleanly, and keeps 1,000 lines.
///
/// Done the way Ghostty and VS Code integrate with zsh, never by editing the user's dotfiles: zsh
/// starts with ZDOTDIR pointing at True's own `.zshenv`, which puts the user's ZDOTDIR straight
/// back, so every one of their startup files runs exactly as it would anywhere else.
enum ShellIntegration {
    static let defaultDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/shell/zsh")

    static let zshenv = """
    # Written by True; overwritten when it changes. See ShellIntegration.swift.
    if [[ -n "${TRUE_USER_ZDOTDIR+x}" ]]; then ZDOTDIR=$TRUE_USER_ZDOTDIR; else unset ZDOTDIR; fi
    unset TRUE_USER_ZDOTDIR
    [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
    # Runs once at the first prompt, after every rc file (so none of them resets it), then removes itself.
    _true_history() {
      setopt INC_APPEND_HISTORY
      (( SAVEHIST < 100000 )) && SAVEHIST=100000
      (( HISTSIZE < 100000 )) && HISTSIZE=100000
      precmd_functions=(${precmd_functions:#_true_history})
      unfunction _true_history
    }
    precmd_functions+=(_true_history)

    """

    /// Route a zsh through the shim. Any other shell, or a shim that can't be written, is left alone.
    static func apply(to env: inout [String: String], shell: String, dir: URL = defaultDir) {
        guard (shell as NSString).lastPathComponent == "zsh", install(in: dir) else { return }
        if let own = env["ZDOTDIR"] { env["TRUE_USER_ZDOTDIR"] = own }
        env["ZDOTDIR"] = dir.path
    }

    /// Write the shim unless it's already current. Cheap enough to check per pane.
    static func install(in dir: URL) -> Bool {
        let file = dir.appendingPathComponent(".zshenv")
        if (try? String(contentsOf: file, encoding: .utf8)) == zshenv { return true }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try zshenv.write(to: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
