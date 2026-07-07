# Blackbird fish bootstrap. Materialized by the app (ShellIntegration) as
# ~/.local/share/blackbird/shell/fish/vendor_conf.d/blackbird.fish and
# reached via an XDG_DATA_DIRS entry Blackbird prepends at spawn.
#
# vendor_conf.d files run BEFORE the user's config.fish, so integration
# loading is deferred to the first fish_prompt event — user config wins,
# and a user-defined `ssh` function defined in config.fish is respected
# by the wrapper's own guard. No top-level `exit` here: in a sourced
# fish file `exit` terminates the whole shell (see osc133.fish header,
# audit S4-001) — the guard lives inside the event function instead.
function __bb_load_integration --on-event fish_prompt
    functions -e __bb_load_integration
    if status is-interactive
        and test "$TERM_PROGRAM" = Blackbird
        and set -q BB_SHELL_INTEGRATION_DIR
        test -r "$BB_SHELL_INTEGRATION_DIR/osc133.fish"; and source "$BB_SHELL_INTEGRATION_DIR/osc133.fish"
        test -r "$BB_SHELL_INTEGRATION_DIR/ssh.fish"; and source "$BB_SHELL_INTEGRATION_DIR/ssh.fish"
    end
end
