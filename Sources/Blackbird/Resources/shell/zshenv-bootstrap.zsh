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
    # Runs at the first precmd, under whatever options .zshrc left on.
    # ksh_arrays (also set by `emulate sh|ksh`) makes `$arr` its first element
    # only, which would truncate precmd_functions below. LOCAL_OPTIONS
    # restores the user's setting on return.
    setopt localoptions noksharrays
    # One-shot: remove ourselves first so a failing source can't loop.
    precmd_functions=(${precmd_functions:#__bb_load_integration})
    local dir="${BB_SHELL_INTEGRATION_DIR-}"
    if [[ -r "$dir/osc133.zsh" ]]; then
      local __bb_was_loaded=${+__BB_OSC133_LOADED}
      builtin source "$dir/osc133.zsh"
      # zsh iterates a copy of precmd_functions, so the hook osc133.zsh just
      # appended first fires at the SECOND prompt. Announce the first one
      # here (A only: no command has run, so no D). A manual source from
      # .zshrc already registered its hook ahead of this prompt: skip.
      if (( ! __bb_was_loaded && ${+functions[__bb_osc133_a]} )); then
        __bb_osc133_a
      fi
    fi
    [[ -r "$dir/ssh.zsh"    ]] && builtin source "$dir/ssh.zsh"
    builtin unfunction __bb_load_integration 2>/dev/null
    return 0
  }
  precmd_functions+=(__bb_load_integration)
fi
