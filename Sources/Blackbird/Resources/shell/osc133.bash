# Blackbird OSC 133 prompt-marks integration (bash).
#
# bash is the one shell Blackbird does NOT auto-inject (a login bash
# ignores --rcfile; see KNOWN_ISSUES "Shell integration auto-injection").
# Usage: add these lines to ~/.bashrc:
#
#   [[ "$TERM_PROGRAM" == "Blackbird" ]] && \
#     source /Applications/Blackbird.app/Contents/Resources/osc133.bash && \
#     source /Applications/Blackbird.app/Contents/Resources/ssh.bash
#
# (Resources are flat in the bundle — there is no shell/ subdirectory.)
#
# What it does: emits OSC 133 A/B/C/D sequences around your prompt + command
# execution so Blackbird knows where prompts start, commands begin, commands
# end, and what their exit codes were. No visible output — the sequences are
# invisible to your terminal's renderer, which just tracks them as metadata.
#
# Blackbird never edits your rc files. zsh and fish get this file injected
# automatically at spawn via env-var redirection (ZDOTDIR / XDG_DATA_DIRS,
# opt-out in Settings); sourcing it yourself as above remains supported and
# is idempotent alongside the auto-injection.

# Guard against double-sourcing (e.g. rc is reloaded). The PROMPT_COMMAND
# edits below would otherwise stack and emit the sequences twice per prompt.
if [[ -n "${__BB_OSC133_LOADED:-}" ]]; then return 0; fi
__BB_OSC133_LOADED=1

# Emit escape bytes via printf %b so backslash escapes are interpreted.
__bb_osc133_a() { printf '\e]133;A\e\\'; }
__bb_osc133_b() { printf '\e]133;B\e\\'; }
__bb_osc133_c() { printf '\e]133;C\e\\'; }
__bb_osc133_d() { printf '\e]133;D;%s\e\\' "${__BB_LAST_EXIT:-0}"; }

# Capture the exit code of the *last user-run* command before PROMPT_COMMAND
# mangles $?. The trick: PROMPT_COMMAND runs just before the next prompt
# renders, so $? at its entry is the command's exit code.
__bb_osc133_prompt() {
    __BB_LAST_EXIT=$?
    __bb_osc133_d
    __bb_osc133_a
}

# Bash's PS0 is expanded just AFTER reading a command and just BEFORE executing
# it — the exact window we want to emit C (command output starts here).
PS0='$(__bb_osc133_c)'"${PS0:-}"

# Hook PROMPT_COMMAND so D+A fire at prompt time. Preserve the user's
# existing PROMPT_COMMAND by chaining.
if [[ -z "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND=__bb_osc133_prompt
else
    # If the user already has PROMPT_COMMAND as an array (bash 5.1+), append.
    # Otherwise prefix to the string form. Both preserve the user's intent.
    if declare -p PROMPT_COMMAND 2>/dev/null | grep -q 'declare -a'; then
        PROMPT_COMMAND+=(__bb_osc133_prompt)
    else
        PROMPT_COMMAND="__bb_osc133_prompt; ${PROMPT_COMMAND}"
    fi
fi

# PS1 emits B at the start of user-editable input. Prepend so we don't
# clobber the user's prompt formatting.
PS1='\[$(__bb_osc133_b)\]'"${PS1}"
