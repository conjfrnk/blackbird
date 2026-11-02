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

# Sets $? to $1 (`return` is illegal in a top-level eval).
__bb_osc133_ret() { return "$1"; }

# Capture the exit code of the *last user-run* command before PROMPT_COMMAND
# mangles $?. The trick: PROMPT_COMMAND runs just before the next prompt
# renders, so $? at its entry is the command's exit code.
#
# The emits below clobber $? and PIPESTATUS, which the user's own
# PROMPT_COMMAND (the `[1]`-in-PS1 idiom) reads on entry, and returning
# from a function flattens PIPESTATUS to one element. So the hook also
# publishes __BB_PC_RESTORE, a statement that re-creates both; the chained
# string below evals it in the same list as the user's command, because
# only a pipeline still live in that list keeps its stages.
#
# The hook itself always returns 0, and a restore that recreates a failure
# ends in `&& :`: a failing command that is not last in an `&&` list leaves
# the list's status as its own but is exempt from `set -e` and from the
# user's ERR trap, so re-raising the status can't kill an errexit shell at
# the prompt or fire the trap a second time. (Status 0 needs no guard, and
# `&& :` would flatten PIPESTATUS there, so it is added only for s != 0.)
__bb_osc133_prompt() {
    # One `local`: $? and PIPESTATUS must both be read before any
    # assignment here resets them.
    local s=$? p=("${PIPESTATUS[@]}") i
    __BB_LAST_EXIT=$s
    __bb_osc133_d
    __bb_osc133_a
    # Re-running the stages reproduces $? too (the last stage, or the
    # rightmost failure under pipefail) — except under `!` negation, which
    # matches neither: fall back to $? alone.
    local w=${p[${#p[@]} - 1]}
    if [[ -o pipefail ]]; then
        for i in "${p[@]}"; do (( i )) && w=$i; done
    fi
    if (( ${#p[@]} > 1 && s == w )); then
        __BB_PC_RESTORE="(exit ${p[0]})"
        for (( i = 1; i < ${#p[@]}; i++ )); do
            __BB_PC_RESTORE+=" | (exit ${p[i]})"
        done
    else
        __BB_PC_RESTORE="__bb_osc133_ret $s"
    fi
    (( s )) && __BB_PC_RESTORE+=" && :"
    __BB_PC_RESTORE+="; "
}

# Bash's PS0 is expanded just AFTER reading a command and just BEFORE executing
# it — the exact window we want to emit C (command output starts here).
# Literal bytes for the same reason as PS1's B below: a $(...) left in
# PS0 needs `promptvars` (on by default, but off in hardened setups),
# where it would print verbatim before every command's output. The
# doubled trailing backslash survives PS0's prompt decode collapsing
# `\\` → `\` when user PS0 content follows — don't "simplify" it.
PS0="$(printf '\e]133;C\e\\\\')${PS0:-}"

# Hook PROMPT_COMMAND so D+A fire at prompt time. Preserve the user's
# existing PROMPT_COMMAND by chaining.
if [[ "${PROMPT_COMMAND[*]:-}" == *__bb_osc133_prompt* ]]; then
    # Already hooked: PROMPT_COMMAND is exported, so a nested shell (`bash`,
    # `exec bash`, a tmux window) inherits the parent's wrapped chain while
    # the double-source guard above is not exported and sourcing runs again.
    # Wrapping a wrapper would make the chain eval itself without end.
    :
elif [[ -z "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND=__bb_osc133_prompt
else
    # If the user already has PROMPT_COMMAND as an array (bash 5.1+), append
    # (their elements still run first, with the real $?). Otherwise run the
    # hook first and the user's string after it, behind the restore step.
    # The user's text is embedded in the string (shell-quoted, so eval gets
    # it back verbatim) rather than parked in a side variable: PROMPT_COMMAND
    # is what gets exported, so the chain stays complete in a nested shell.
    if declare -p PROMPT_COMMAND 2>/dev/null | grep -q 'declare -a'; then
        PROMPT_COMMAND+=(__bb_osc133_prompt)
    else
        PROMPT_COMMAND='__bb_osc133_prompt; eval "$__BB_PC_RESTORE" '"$(printf %q "$PROMPT_COMMAND")"
    fi
fi

# PS1 carries B at the END of the prompt — where user-editable input
# actually begins. The bytes are embedded LITERALLY at source time (the
# $(printf …) runs once, right here): a substitution left inside PS1
# would silently stop firing under `shopt -u promptvars`, and the zsh
# sibling can't use one at all (stock zsh has PROMPT_SUBST off) — keep
# the dialects on the same shape.
#
# The ST terminator ends in a literal backslash, and bash's prompt
# decoder would collapse it with `\]`'s backslash (`\\` → `\`), eating
# the non-print marker and printing a stray `]` — so the embed emits a
# DOUBLED trailing backslash that decodes back to a single one. Don't
# "simplify" it away.
PS1="${PS1}\[$(printf '\e]133;B\e\\\\')\]"
