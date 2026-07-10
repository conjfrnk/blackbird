# Blackbird OSC 133 prompt-marks integration (fish).
#
# Auto-loaded since the issue-#23 fix: Blackbird prepends a vendor-conf.d
# data dir to XDG_DATA_DIRS at spawn; fish sources the bundled bootstrap,
# which loads this file (plus ssh.fish) at first prompt. Opt-out:
# Settings → "Automatic shell integration". Blackbird never edits your
# config files. Manual sourcing remains supported — add to
# ~/.config/fish/config.fish:
#
#   test "$TERM_PROGRAM" = "Blackbird"; and source \
#     /Applications/Blackbird.app/Contents/Resources/osc133.fish
#
# (Resources are flat in the bundle — there is no shell/ subdirectory.)
#
# Emits OSC 133 A/B/C/D sequences around the prompt + command lifecycle.
# Invisible to the renderer; Blackbird tracks them as metadata for future
# "jump to previous prompt" UX.

# Guard against double-sourcing. `return` exits the sourced file and
# yields control back to the caller; `exit` would terminate the entire
# interactive shell, killing the user's session on re-source (the bash
# and zsh siblings use the equivalent `return 0`). Audit S4-001.
if set -q __bb_osc133_loaded
    return
end
set -g __bb_osc133_loaded 1

function __bb_osc133_a;  printf '\e]133;A\e\\'; end
function __bb_osc133_b;  printf '\e]133;B\e\\'; end
function __bb_osc133_c;  printf '\e]133;C\e\\'; end
function __bb_osc133_d;  printf '\e]133;D;%s\e\\' $argv[1]; end

# fish fires fish_preexec just before a user command runs → C.
# fish fires fish_prompt just before the prompt renders → D (with $status
# of the last command) + A.
function __bb_osc133_cmd_start --on-event fish_preexec
    __bb_osc133_c
end

function __bb_osc133_before_prompt --on-event fish_prompt
    set -l last_exit $status
    __bb_osc133_d $last_exit
    __bb_osc133_a
end

# fish has no separate B hook, so wrap fish_prompt to emit B after the
# prompt text — where user-editable input begins — matching the zsh/bash
# dialects (they append the literal bytes to PS1; kitty's fish
# integration wraps the same way). This file loads at the first
# fish_prompt event, so the user's (or their theme's) fish_prompt
# already exists and is preserved via a copy. A later redefinition of
# fish_prompt drops the mark — the same accepted trade as a PS1
# reassignment in zsh/bash; such users can call `__bb_osc133_b` at the
# end of their own fish_prompt.
if functions -q fish_prompt
    and not functions -q __bb_original_fish_prompt
    # Never wrap a prompt that already emits B — a `funcsave fish_prompt`
    # while wrapped persists the WRAPPER body, and copying that into
    # __bb_original_fish_prompt next session would make it call itself
    # (immediate-recursion error on every prompt; see KNOWN_ISSUES
    # "funcsave fish_prompt").
    and not string match -q '*__bb_osc133_b*' -- (functions fish_prompt | string collect)
    and functions -c fish_prompt __bb_original_fish_prompt
    # Wrapper defined only when the copy above succeeded — otherwise it
    # would call a function that doesn't exist on every prompt. The
    # in-wrapper existence check covers a persisted (funcsave'd) wrapper
    # body running in a session where the copy was never made: degrade
    # to a bare-but-working prompt instead of a per-prompt error.
    function fish_prompt
        if functions -q __bb_original_fish_prompt
            __bb_original_fish_prompt
        end
        __bb_osc133_b
    end
end
