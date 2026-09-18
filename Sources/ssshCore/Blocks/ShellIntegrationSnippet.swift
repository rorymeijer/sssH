import Foundation

/// The shell-side half of command blocks.
///
/// sssh cannot make a remote shell emit `OSC 133`; only the shell's own
/// configuration can. So the app offers the snippet and the user installs it —
/// deliberately by hand. Writing to someone's `.bashrc` over an SSH session
/// they opened to do something else is not a convenience, it is an edit to a
/// machine they did not ask us to edit, and it is exactly the kind of thing an
/// SSH client should never do on its own.
///
/// The snippets are the standard FinalTerm/iTerm2 sequences, and are
/// compatible with every other terminal that reads them: installing this does
/// not tie the user's shell to sssh.
public enum ShellIntegrationSnippet: String, CaseIterable, Identifiable, Sendable {
    case bash
    case zsh
    case fish

    public var id: String { rawValue }

    /// Where it goes. Shown next to the snippet, because "paste this
    /// somewhere" is not an instruction.
    public var configurationFile: String {
        switch self {
        case .bash: return "~/.bashrc"
        case .zsh: return "~/.zshrc"
        case .fish: return "~/.config/fish/config.fish"
        }
    }

    public var displayName: String {
        switch self {
        case .bash: return "bash"
        case .zsh: return "zsh"
        case .fish: return "fish"
        }
    }

    public var script: String {
        switch self {
        case .bash: return Self.bashScript
        case .zsh: return Self.zshScript
        case .fish: return Self.fishScript
        }
    }

    // `PS0` is printed after a command line is read but before it runs, which
    // is exactly where `C` belongs. It needs bash 4.4 or newer; on anything
    // older the `D` and `A` markers still work and only the boundary between
    // the typed command and its output is lost.
    //
    // The `\[` and `\]` around the `B` marker tell readline the bytes take no
    // screen columns. Without them, bash miscounts the prompt width and line
    // editing corrupts the display on long command lines.
    private static let bashScript = #"""
    # sssh command blocks (OSC 133). Standard sequences: other terminals read
    # them too.
    __sssh_precmd() {
      local __sssh_status=$?
      printf '\033]133;D;%s\007\033]133;A\007' "$__sssh_status"
      return $__sssh_status
    }
    PS0=$'\033]133;C\007'"${PS0-}"
    PS1="${PS1-}"'\[\033]133;B\007\]'
    case ";${PROMPT_COMMAND-};" in
      *";__sssh_precmd;"*) ;;
      *) PROMPT_COMMAND="__sssh_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    esac
    """#

    // `%{ %}` is zsh's prompt-width escape, the same idea as bash's `\[ \]`.
    private static let zshScript = #"""
    # sssh command blocks (OSC 133). Standard sequences: other terminals read
    # them too.
    __sssh_precmd() {
      local __sssh_status=$?
      print -n -- $'\e]133;D;'"${__sssh_status}"$'\a\e]133;A\a'
    }
    __sssh_preexec() { print -n -- $'\e]133;C\a' }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __sssh_precmd
    add-zsh-hook preexec __sssh_preexec
    PS1="${PS1}"$'%{\e]133;B\a%}'
    """#

    // fish has no prompt-width escape, so the `B` marker goes at the very end
    // of the prompt function where a miscounted width cannot wrap anything.
    private static let fishScript = #"""
    # sssh command blocks (OSC 133). Standard sequences: other terminals read
    # them too.
    function __sssh_preexec --on-event fish_preexec
        printf '\e]133;C\a'
    end
    function __sssh_postexec --on-event fish_postexec
        printf '\e]133;D;%s\a' $status
    end
    if not functions -q __sssh_original_fish_prompt
        functions --copy fish_prompt __sssh_original_fish_prompt
        function fish_prompt
            printf '\e]133;A\a'
            __sssh_original_fish_prompt
            printf '\e]133;B\a'
        end
    end
    """#
}
