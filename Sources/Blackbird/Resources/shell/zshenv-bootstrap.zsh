# Blackbird zsh bootstrap. Materialized by the app (ShellIntegration) as
# ~/.local/share/blackbird/shell/zdotdir/.zshenv and pointed to via
# ZDOTDIR at spawn — authoritative overwrite every launch, same tamper
# posture as the ~/.terminfo install (KittyTerminfo).
#
# Job: restore the user's ZDOTDIR before ANY of their startup files run,
# chain to their real .zshenv exactly as zsh would have, then defer
# loading Blackbird integration (osc133 + ssh wrapper) to the first
# precmd — i.e. after .zshrc — so user config always wins.
if [[ -n "${BB_ORIG_ZDOTDIR-}" ]]; then
  export ZDOTDIR="$BB_ORIG_ZDOTDIR"
  unset BB_ORIG_ZDOTDIR
else
  unset ZDOTDIR
fi
if [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
  builtin source "${ZDOTDIR:-$HOME}/.zshenv"
fi
if [[ -o interactive && "$TERM_PROGRAM" == "Blackbird" && -n "${BB_SHELL_INTEGRATION_DIR-}" ]]; then
  typeset -ga precmd_functions
  __bb_load_integration() {
    # One-shot: remove ourselves first so a failing source can't loop.
    precmd_functions=(${precmd_functions:#__bb_load_integration})
    local dir="${BB_SHELL_INTEGRATION_DIR-}"
    [[ -r "$dir/osc133.zsh" ]] && builtin source "$dir/osc133.zsh"
    [[ -r "$dir/ssh.zsh"    ]] && builtin source "$dir/ssh.zsh"
    builtin unfunction __bb_load_integration 2>/dev/null
    return 0
  }
  precmd_functions+=(__bb_load_integration)
fi
