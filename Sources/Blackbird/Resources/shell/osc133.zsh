# Blackbird OSC 133 prompt-marks integration (zsh).
#
# Auto-loaded since the issue-#23 fix: Blackbird points ZDOTDIR at a
# bootstrap .zshenv at spawn, which restores your real ZDOTDIR, chains
# your own .zshenv, and sources this file (plus ssh.zsh) at first prompt.
# Opt-out: Settings → "Automatic shell integration". Blackbird never
# edits your rc files.
#
# Manual sourcing remains supported (and covers nested `zsh` sessions,
# which the auto-injection deliberately does not reach — see
# KNOWN_ISSUES "Shell integration auto-injection"). Add to ~/.zshrc:
#
#   [[ "$TERM_PROGRAM" == "Blackbird" ]] && \
#     source /Applications/Blackbird.app/Contents/Resources/osc133.zsh
#
# (Resources are flat in the bundle — there is no shell/ subdirectory.)
#
# What it does: emits OSC 133 A/B/C/D sequences around your prompt + command
# lifecycle so Blackbird knows where prompts start, commands begin, commands
# end, and what their exit codes were. Invisible to the renderer — tracked
# as metadata only.

# Guard against double-sourcing.
if (( ${+__BB_OSC133_LOADED} )); then return 0; fi
typeset -g __BB_OSC133_LOADED=1

# Emit escape bytes. zsh's %{ ... %} tells the line editor "zero-width
# content" so PS1 width tracking stays correct.
__bb_osc133_a() { print -n '\e]133;A\e\\' }
__bb_osc133_b() { print -n '\e]133;B\e\\' }
__bb_osc133_c() { print -n '\e]133;C\e\\' }
__bb_osc133_d() { print -n "\e]133;D;${1:-0}\e\\" }

# preexec hook fires just before a user command runs — emit C (cmd output).
# precmd hook fires just before the next prompt renders — emit D + A.
__bb_osc133_cmd_start()   { __bb_osc133_c }
__bb_osc133_before_prompt() {
    local last_exit=$?
    __bb_osc133_d "$last_exit"
    __bb_osc133_a
}

# Chain into zsh's existing hooks non-destructively.
typeset -ag precmd_functions
typeset -ag preexec_functions
precmd_functions+=(__bb_osc133_before_prompt)
preexec_functions+=(__bb_osc133_cmd_start)

# PS1 emits B at the start of user-editable input.
PS1='%{$(__bb_osc133_b)%}'"${PS1}"
