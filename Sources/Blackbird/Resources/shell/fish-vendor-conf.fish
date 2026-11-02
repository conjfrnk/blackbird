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
        if test -r "$BB_SHELL_INTEGRATION_DIR/osc133.fish"
            set -q __bb_osc133_loaded
            set -l was_loaded $status
            source "$BB_SHELL_INTEGRATION_DIR/osc133.fish"
            # Handlers osc133.fish just defined first fire at the NEXT
            # prompt, so announce this one here (A only: no command has
            # run, so no D). Skipped when fish itself already emits a
            # native A (the fish >= 4 `mark-prompt` feature is on; probed
            # as a feature, not by version, because users can disable it
            # via fish_features=no-mark-prompt; the probe is non-zero on
            # fish 3, where the feature does not exist) and when a manual
            # source from config.fish already hooked this prompt.
            if test $was_loaded -ne 0
                and not status test-feature mark-prompt
                and functions -q __bb_osc133_a
                __bb_osc133_a
            end
        end
        test -r "$BB_SHELL_INTEGRATION_DIR/ssh.fish"; and source "$BB_SHELL_INTEGRATION_DIR/ssh.fish"
    end
end
