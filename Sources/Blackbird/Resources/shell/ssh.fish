# Blackbird ssh terminfo wrapper (fish, ≥ 3.1 for `set` cmdsub status
# passthrough and VAR=val command prefixes).
#
# Auto-loaded by Blackbird's fish vendor conf.d bootstrap; manual
# sourcing from ~/.config/fish/config.fish also works. Guarantees issue
# #23 can't happen: every `ssh` from a Blackbird session either has the
# xterm-kitty terminfo installed on the remote host (once, cached per
# host) or runs that connection with TERM=xterm-256color. Port of
# ssh.zsh — keep the three dialects in sync. No top-level `exit` in a
# sourced fish file (audit S4-001) — the guard nests instead.

if not set -q __BB_SSH_WRAPPER_LOADED
    set -g __BB_SSH_WRAPPER_LOADED 1

    # Respect user customization: never shadow an existing ssh function
    # (fish aliases ARE functions, so this covers both).
    if not functions -q ssh
        function __bb_ssh_cache_file
            if set -q XDG_STATE_HOME
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

        # True (0) when argv has an operand after the destination — a
        # remote command. Flags that consume a separate argument per ssh(1).
        function __bb_ssh_has_remote_command
            set -l opts_with_arg "BbcDEeFIiJLlmOoPpRSWw"
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
                        set -l last (string sub -s -1 -- "$a")
                        if string match -q -- "*$last*" "$opts_with_arg"
                            set skip_next 1
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
            printf 'blackbird: installing xterm-kitty terminfo on %s (first connect — may authenticate twice)\n' "$dest" >&2
            if command infocmp -x xterm-kitty 2>/dev/null | command ssh $argv 'tic -x - 2>/dev/null'
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
