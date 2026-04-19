# Blackbird OSC 133 prompt-marks integration (fish).
#
# Usage: add this line to ~/.config/fish/config.fish:
#
#   test "$TERM_PROGRAM" = "Blackbird"; and source \
#     /Applications/Blackbird.app/Contents/Resources/shell/osc133.fish
#
# Emits OSC 133 A/B/C/D sequences around the prompt + command lifecycle.
# Invisible to the renderer; Blackbird tracks them as metadata for future
# "jump to previous prompt" UX. Opt-in, shell-side only.

# Guard against double-sourcing.
if set -q __bb_osc133_loaded
    exit 0
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

# fish doesn't have a separate B hook — the prompt function emits it at
# the very end. Define a wrapper that users can append to fish_prompt:
#
#   function fish_prompt
#       ...your prompt contents...
#       __bb_osc133_b
#   end
#
# If the user already defines fish_prompt, they should add the
# `__bb_osc133_b` call manually at the end.
