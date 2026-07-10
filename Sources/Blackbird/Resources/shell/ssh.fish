# Blackbird ssh terminfo wrapper (fish, ≥ 3.1 for `set` cmdsub status
# passthrough and VAR=val command prefixes).
#
# Auto-loaded by Blackbird's fish vendor conf.d bootstrap; manual
# sourcing from ~/.config/fish/config.fish also works. Guarantees issue
# #23 can't happen: by DEFAULT every `ssh` from a Blackbird session runs
# with TERM=xterm-256color (VS Code parity; rationale inside the ssh
# function below). BB_SSH_REMOTE_TERM=kitty opts into the v0.6.0
# behavior: install the xterm-kitty terminfo remotely (once, cached per
# host) and keep the kitty TERM, falling back when the install can't
# land. Port of ssh.zsh — keep the three dialects in sync. No top-level
# `exit` in a sourced fish file (audit S4-001) — the guard nests instead.

if not set -q __BB_SSH_WRAPPER_LOADED
    set -g __BB_SSH_WRAPPER_LOADED 1

    # Respect user customization: never shadow an existing ssh function
    # (fish aliases ARE functions, so this covers both).
    if not functions -q ssh
        function __bb_ssh_cache_file
            # Empty-but-set falls back like the zsh/bash dialects'
            # ${XDG_STATE_HOME:-…} (XDG: empty means "use the default").
            if set -q XDG_STATE_HOME; and test -n "$XDG_STATE_HOME"
                printf '%s\n' "$XDG_STATE_HOME/blackbird/ssh-terminfo-hosts"
            else
                printf '%s\n' "$HOME/.local/state/blackbird/ssh-terminfo-hosts"
            end
        end

        # Canonical "user@hostname:port" via `ssh -G` (resolves aliases,
        # Match blocks, ProxyJump). Non-zero when ssh can't parse argv.
        function __bb_ssh_dest
            command ssh -G $argv 2>/dev/null | command awk '
                $1 == "user"     && u == "" { u = $2 }
                $1 == "hostname" && h == "" { h = $2 }
                $1 == "port"     && p == "" { p = $2 }
                END { if (h == "") exit 1; print u "@" h ":" p }'
        end

        # True (0) when the invocation must NOT pre-flight a terminfo
        # install: argv carries an operand after the destination (a
        # remote command), or a session mode with no interactive
        # terminal (-N -f -W -O). Option clusters are walked
        # left-to-right: the FIRST arg-taking letter decides — last
        # char of the token ⇒ the arg is the NEXT token (consume it);
        # not last ⇒ the arg is ATTACHED in this token (consume
        # nothing). The old last-char-only check misread attached forms
        # like `-oStrictHostKeyChecking=no` and swallowed the
        # destination, appending `tic -x -` to the user's remote
        # command. `contains` compares exactly — no glob hazards from
        # attached values holding * or ?.
        function __bb_ssh_has_remote_command
            set -l seen_dest 0
            set -l end_opts 0
            set -l skip_next 0
            for a in $argv
                if test $skip_next -eq 1
                    set skip_next 0
                    continue
                end
                if test $seen_dest -eq 1
                    return 0
                end
                if test $end_opts -eq 1
                    set seen_dest 1
                    continue
                end
                if test "$a" = "--"
                    set end_opts 1
                    continue
                end
                switch "$a"
                    case '-'
                        set seen_dest 1
                    case '-*'
                        set -l chars (string split '' -- "$a")
                        set -l len (count $chars)
                        for j in (seq 2 $len)
                            set -l c $chars[$j]
                            if contains -- "$c" N f W O
                                return 0
                            end
                            if contains -- "$c" B b c D E e F I i J L l m O o P p Q R S W w
                                if test $j -eq $len
                                    set skip_next 1
                                end
                                break
                            end
                        end
                    case '*'
                        set seen_dest 1
                end
            end
            return 1
        end

        function ssh
            if test "$TERM" != xterm-kitty
                command ssh $argv
                return $status
            end
            # DEFAULT: hand the remote TERM=xterm-256color — the one
            # value every stack recognizes (VS Code parity). Keeping
            # xterm-kitty remotely breaks string-sniffing color-depth
            # detection (codex's composer bar, npm supports-color) since
            # COLORTERM never survives ssh and those tools don't read
            # terminfo. Kitty KEYBOARD protocol is unaffected (runtime
            # CSI ?u negotiation, TERM-independent). Opt-in
            # BB_SSH_REMOTE_TERM=kitty restores the v0.6.0
            # install-terminfo-and-keep-kitty-TERM behavior.
            if test "$BB_SSH_REMOTE_TERM" != kitty
                TERM=xterm-256color command ssh $argv
                return $status
            end
            set -l dest (__bb_ssh_dest $argv)
            if test $status -ne 0; or test -z "$dest"
                TERM=xterm-256color command ssh $argv
                return $status
            end
            set -l cache (__bb_ssh_cache_file)
            if test -r "$cache"; and command grep -qxF -- "$dest" "$cache" 2>/dev/null
                command ssh $argv
                return $status
            end
            if __bb_ssh_has_remote_command $argv
                TERM=xterm-256color command ssh $argv
                return $status
            end
            # Capture the terminfo source BEFORE connecting: `tic -x -`
            # exits 0 on EMPTY stdin, so piping a failed local infocmp
            # straight into the remote would "succeed", cache the host,
            # and permanently pin a broken kitty TERM there (panel
            # finding). Empty source ⇒ downgrade, uncached.
            set -l src (command infocmp -x xterm-kitty 2>/dev/null | string collect)
            if test -z "$src"
                printf 'blackbird: local xterm-kitty terminfo source unavailable — using TERM=xterm-256color for this connection\n' >&2
                TERM=xterm-256color command ssh $argv
                return $status
            end
            printf 'blackbird: installing xterm-kitty terminfo on %s (first connect — may authenticate twice)\n' "$dest" >&2
            if printf '%s\n' "$src" | command ssh $argv 'tic -x - 2>/dev/null'
                command mkdir -p -- (dirname -- "$cache") 2>/dev/null
                if printf '%s\n' "$dest" >> "$cache" 2>/dev/null
                    command chmod 600 -- "$cache" 2>/dev/null
                else
                    printf 'blackbird: could not write %s — terminfo will reinstall next connect\n' "$cache" >&2
                end
                command ssh $argv
            else
                printf 'blackbird: remote terminfo install failed — using TERM=xterm-256color for this connection\n' >&2
                TERM=xterm-256color command ssh $argv
            end
        end
    end
end
