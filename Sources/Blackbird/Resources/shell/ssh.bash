# Blackbird ssh terminfo wrapper (bash).
#
# bash is not auto-injected (see KNOWN_ISSUES "Shell integration
# auto-injection") — source this from ~/.bashrc alongside osc133.bash:
#
#   [[ "$TERM_PROGRAM" == "Blackbird" ]] && \
#     source /Applications/Blackbird.app/Contents/Resources/ssh.bash
#
# Guarantees issue #23 can't happen: every `ssh` from a Blackbird
# session either has the xterm-kitty terminfo installed on the remote
# host (once, cached per host) or runs that connection with
# TERM=xterm-256color. Line-by-line port of ssh.zsh — keep the three
# dialects in sync.

if [[ -n "${__BB_SSH_WRAPPER_LOADED-}" ]]; then return 0; fi
__BB_SSH_WRAPPER_LOADED=1

# Respect user customization: never shadow an existing ssh function/alias.
__bb_ssh_type="$(type -t ssh 2>/dev/null)"
if [[ "$__bb_ssh_type" == "function" || "$__bb_ssh_type" == "alias" ]]; then
  unset __bb_ssh_type
  return 0
fi
unset __bb_ssh_type

__bb_ssh_cache_file() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/blackbird/ssh-terminfo-hosts"
}

# Canonical "user@hostname:port" via `ssh -G` (resolves aliases, Match
# blocks, ProxyJump). Fails (non-zero) when ssh can't parse the argv.
__bb_ssh_dest() {
  command ssh -G "$@" 2>/dev/null | command awk '
    $1 == "user"     && u == "" { u = $2 }
    $1 == "hostname" && h == "" { h = $2 }
    $1 == "port"     && p == "" { p = $2 }
    END { if (h == "") exit 1; print u "@" h ":" p }'
}

# True (0) when the invocation must NOT pre-flight a terminfo install:
# argv carries an operand after the destination (a remote command), or a
# session mode with no interactive terminal (-N -f -W -O). Option
# clusters are walked left-to-right: the FIRST arg-taking letter decides
# — last char of the token ⇒ the arg is the NEXT token (consume it); not
# last ⇒ the arg is ATTACHED inside this token (consume nothing). The
# old last-char-only check misread attached forms like
# `-oStrictHostKeyChecking=no` (value ends in an arg-taking letter) and
# swallowed the destination — which made `ssh -oX=no host cmd` look
# interactive and appended `tic -x -` to the user's remote command.
__bb_ssh_has_remote_command() {
  local opts_with_arg="BbcDEeFIiJLlmOoPpQRSWw"
  local args=("$@")
  local i=0 seen_dest=0 end_opts=0 a c j len
  while (( i < ${#args[@]} )); do
    a="${args[i]}"
    if (( seen_dest )); then return 0; fi
    if (( end_opts )) || [[ "$a" != -?* ]]; then
      seen_dest=1
    elif [[ "$a" == "--" ]]; then
      end_opts=1
    else
      len=${#a}
      for (( j = 1; j < len; j++ )); do
        c="${a:j:1}"
        if [[ "NfWO" == *"$c"* ]]; then
          return 0
        fi
        if [[ "$opts_with_arg" == *"$c"* ]]; then
          if (( j == len - 1 )); then
            i=$((i + 1))
          fi
          break
        fi
      done
    fi
    i=$((i + 1))
  done
  return 1
}

ssh() {
  if [[ "$TERM" != "xterm-kitty" ]]; then
    command ssh "$@"; return $?
  fi
  local dest cache src
  if ! dest="$(__bb_ssh_dest "$@")"; then
    TERM=xterm-256color command ssh "$@"; return $?
  fi
  cache="$(__bb_ssh_cache_file)"
  if [[ -r "$cache" ]] && command grep -qxF -- "$dest" "$cache" 2>/dev/null; then
    command ssh "$@"; return $?
  fi
  if __bb_ssh_has_remote_command "$@"; then
    TERM=xterm-256color command ssh "$@"; return $?
  fi
  # Capture the terminfo source BEFORE connecting: `tic -x -` exits 0 on
  # EMPTY stdin, so piping a failed local infocmp straight into the
  # remote would "succeed", cache the host, and permanently pin a broken
  # kitty TERM there (panel finding). Empty source ⇒ downgrade, uncached.
  src="$(command infocmp -x xterm-kitty 2>/dev/null)"
  if [[ -z "$src" ]]; then
    printf 'blackbird: local xterm-kitty terminfo source unavailable — using TERM=xterm-256color for this connection\n' >&2
    TERM=xterm-256color command ssh "$@"; return $?
  fi
  printf 'blackbird: installing xterm-kitty terminfo on %s (first connect — may authenticate twice)\n' "$dest" >&2
  if printf '%s\n' "$src" | command ssh "$@" 'tic -x - 2>/dev/null'; then
    command mkdir -p -- "${cache%/*}" 2>/dev/null
    if printf '%s\n' "$dest" >> "$cache" 2>/dev/null; then
      command chmod 600 -- "$cache" 2>/dev/null
    else
      printf 'blackbird: could not write %s — terminfo will reinstall next connect\n' "$cache" >&2
    fi
    command ssh "$@"
  else
    printf 'blackbird: remote terminfo install failed — using TERM=xterm-256color for this connection\n' >&2
    TERM=xterm-256color command ssh "$@"
  fi
}
