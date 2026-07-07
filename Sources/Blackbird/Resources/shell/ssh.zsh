# Blackbird ssh terminfo wrapper (zsh).
#
# Auto-loaded by Blackbird's shell integration (see zshenv-bootstrap.zsh),
# or source it manually from ~/.zshrc. Guarantees issue #23 can't happen:
# every `ssh` from a Blackbird session either has the xterm-kitty
# terminfo installed on the remote host (once, cached per host) or runs
# that connection with TERM=xterm-256color. Reference dialect — keep
# ssh.bash / ssh.fish in sync.

if (( ${+__BB_SSH_WRAPPER_LOADED} )); then return 0; fi
typeset -g __BB_SSH_WRAPPER_LOADED=1

# Respect user customization: never shadow an existing ssh function/alias.
if (( ${+functions[ssh]} )) || (( ${+aliases[ssh]} )); then return 0; fi

__bb_ssh_cache_file() {
  print -r -- "${XDG_STATE_HOME:-$HOME/.local/state}/blackbird/ssh-terminfo-hosts"
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

# True (0) when argv contains an operand after the destination — i.e. a
# remote command. Flags that consume a separate argument per ssh(1).
__bb_ssh_has_remote_command() {
  local opts_with_arg="BbcDEeFIiJLlmOoPpRSWw"
  local -a args
  args=("$@")
  local i=1 seen_dest=0 end_opts=0 a last
  while (( i <= ${#args} )); do
    a="${args[i]}"
    if (( seen_dest )); then return 0; fi
    if (( end_opts )) || [[ "$a" != -?* ]]; then
      seen_dest=1
    elif [[ "$a" == "--" ]]; then
      end_opts=1
    else
      last="${a[-1]}"
      if [[ "$opts_with_arg" == *"$last"* ]]; then
        (( i += 1 ))
      fi
    fi
    (( i += 1 ))
  done
  return 1
}

ssh() {
  if [[ "$TERM" != "xterm-kitty" ]]; then
    command ssh "$@"; return $?
  fi
  local dest cache
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
  print -u2 -- "blackbird: installing xterm-kitty terminfo on ${dest} (first connect — may authenticate twice)"
  if command infocmp -x xterm-kitty 2>/dev/null | command ssh "$@" 'tic -x - 2>/dev/null'; then
    command mkdir -p -- "${cache:h}" 2>/dev/null
    if print -r -- "$dest" >> "$cache" 2>/dev/null; then
      command chmod 600 -- "$cache" 2>/dev/null
    else
      print -u2 -- "blackbird: could not write ${cache} — terminfo will reinstall next connect"
    fi
    command ssh "$@"
  else
    print -u2 -- "blackbird: remote terminfo install failed — using TERM=xterm-256color for this connection"
    TERM=xterm-256color command ssh "$@"
  fi
}
