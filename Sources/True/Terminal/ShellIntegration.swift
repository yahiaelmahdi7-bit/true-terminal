import Foundation

/// Every command a True shell runs is written to history the moment it's entered, so history
/// survives quit, crash and force-quit alike. Stock macOS zsh writes history only when a shell
/// exits cleanly, and keeps 1,000 lines.
///
/// Done the way Ghostty and VS Code integrate with zsh, never by editing the user's dotfiles: zsh
/// starts with ZDOTDIR pointing at True's own `.zshenv`, which puts the user's ZDOTDIR straight
/// back, so every one of their startup files runs exactly as it would anywhere else.
///
/// The same first-prompt hook also loads inline suggestions (vendored zsh-autosuggestions, written next to the
/// shim) unless the user already loaded their own or turned "Inline suggestions" off.
enum ShellIntegration {
    static let defaultDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".true/shell/zsh")

    static let zshenv = """
    # Written by True; overwritten when it changes. See ShellIntegration.swift.
    typeset -g _true_dir=$ZDOTDIR _true_suggest=${TRUE_INLINE_SUGGEST:-1}
    unset TRUE_INLINE_SUGGEST
    if [[ -n "${TRUE_USER_ZDOTDIR+x}" ]]; then ZDOTDIR=$TRUE_USER_ZDOTDIR; else unset ZDOTDIR; fi
    unset TRUE_USER_ZDOTDIR
    [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
    # Runs once at the first prompt, after every rc file (so none of them resets it), then removes itself.
    _true_history() {
      setopt INC_APPEND_HISTORY
      (( SAVEHIST < 100000 )) && SAVEHIST=100000
      (( HISTSIZE < 100000 )) && HISTSIZE=100000
      # Inline suggestions: only when switched on, and never over the user's own zsh-autosuggestions.
      if [[ $_true_suggest != 0 && -r $_true_dir/zsh-autosuggestions.zsh ]] && ! (( $+functions[_zsh_autosuggest_start] )); then
        # Menu-select tab completion, only for a user with no completion styles of their own.
        if [[ -z "$(zstyle -L ':completion:*' 2>/dev/null)" ]]; then
          (( $+functions[compdef] )) || { autoload -Uz compinit && compinit -i; }
          zstyle ':completion:*' menu select
          zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
        fi
        ZSH_AUTOSUGGEST_STRATEGY=(history completion)
        ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=243'
        builtin source $_true_dir/zsh-autosuggestions.zsh
        # → and End accept the whole suggestion (the defaults); ⌥→ accepts one word.
        bindkey '^[[1;3C' forward-word
        bindkey '^[[1;5C' forward-word
      fi
      unset _true_dir _true_suggest
      precmd_functions=(${precmd_functions:#_true_history})
      unfunction _true_history
    }
    precmd_functions+=(_true_history)

    """

    /// Route a zsh through the shim. Any other shell, or a shim that can't be written, is left alone.
    static func apply(to env: inout [String: String], shell: String, dir: URL = defaultDir,
                      inlineSuggestions: Bool = TerminalSettings.inlineSuggestions) {
        guard (shell as NSString).lastPathComponent == "zsh", install(in: dir) else { return }
        env["TRUE_INLINE_SUGGEST"] = inlineSuggestions ? "1" : "0"
        if let own = env["ZDOTDIR"] { env["TRUE_USER_ZDOTDIR"] = own }
        env["ZDOTDIR"] = dir.path
    }

    /// Write the shim unless it's already current. Cheap enough to check per pane.
    static func install(in dir: URL) -> Bool {
        let files = [(".zshenv", zshenv), ("zsh-autosuggestions.zsh", ZshAutosuggestions.source),
                     ("LICENSE-zsh-autosuggestions", ZshAutosuggestions.license)]
        for (name, text) in files {
            let file = dir.appendingPathComponent(name)
            if (try? String(contentsOf: file, encoding: .utf8)) == text { continue }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                return false
            }
        }
        return true
    }
}
