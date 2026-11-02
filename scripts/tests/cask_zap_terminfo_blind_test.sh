#!/usr/bin/env bash
#
# Regression (blind): the Homebrew cask's `zap trash:` list must name the
# path where macOS's own /usr/bin/tic actually installs the xterm-kitty
# terminfo entry the app provisions (Sources/Blackbird/Terminal/
# KittyTerminfo.swift compiles Resources/Terminfo/kitty.terminfo into
# ~/.terminfo with `tic -x`).
#
# Terminal/ncurses convention: terminfo entries live in a one-character
# subdirectory named after the first letter of the entry. Classic ncurses
# uses the letter itself (`x/xterm-kitty`); Apple's ncurses uses the
# two-digit lowercase HEX of that letter's ASCII code (`x` = 0x78, so
# `78/xterm-kitty`). The cask must follow whatever the platform's tic does,
# otherwise `brew uninstall --zap blackbird` leaves the installed entry
# behind.
#
# This test does NOT hard-code either directory name. It compiles the
# bundled kitty terminfo with the real /usr/bin/tic into a throw-away HOME,
# observes which file(s) appear, and asserts every one of them is covered
# by an entry in the cask's zap list. It never touches the real
# ~/.terminfo and never launches the app.

# The cask spells paths with a literal leading "~/" (Homebrew expands it);
# we compare those strings verbatim, so the quoted tildes are intentional.
# shellcheck disable=SC2088
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "cask_zap_terminfo_blind_test.sh"

CASK="$BB_REPO_ROOT/packaging/homebrew/blackbird.rb"
SRC="$BB_REPO_ROOT/Sources/Blackbird/Resources/Terminfo/kitty.terminfo"
TIC="/usr/bin/tic"

assert_file_exists "$CASK" "Homebrew cask exists"
assert_file_exists "$SRC" "bundled kitty terminfo source exists"

if [[ ! -x "$TIC" ]]; then
    # The app itself shells out to this exact binary; a macOS runner
    # without it cannot exercise the scenario at all. Fail rather than
    # silently pass so the gap is visible.
    fail "$TIC missing or not executable - cannot observe where macOS tic installs xterm-kitty"
    test_end
    exit 1
fi

TMP_HOME="$(mk_tmp bb-cask-zap-terminfo)"
trap 'rm -rf "$TMP_HOME"' EXIT

# ---------------------------------------------------------------------------
# 1. Observe where tic really installs the entry (throw-away HOME).
# ---------------------------------------------------------------------------

TIC_LOG="$TMP_HOME/tic.log"
TIC_RC="$(
    unset TERMINFO TERMINFO_DIRS
    export HOME="$TMP_HOME"
    run_capture "$TIC_LOG" "$TIC" -x -o "$TMP_HOME/.terminfo" "$SRC"
)"
assert_exit_code "$TIC_RC" "0" "tic -x compiles the bundled kitty terminfo"

INSTALLED=()
while IFS= read -r line; do
    [[ -n "$line" ]] && INSTALLED+=("$line")
done < <(cd "$TMP_HOME" && find .terminfo -type f -name 'xterm-kitty' | sort)

assert_eq "${#INSTALLED[@]}" "1" \
    "tic installed exactly one xterm-kitty file (saw: ${INSTALLED[*]:-<none>})"

if (( ${#INSTALLED[@]} != 1 )); then
    test_end
    exit 1
fi

# Path of the installed file as the cask would spell it, e.g.
# "~/.terminfo/78/xterm-kitty".
INSTALLED_TILDE="~/${INSTALLED[0]}"
echo "    observed tic install location: $INSTALLED_TILDE"

# ---------------------------------------------------------------------------
# 2. Parse the cask's zap trash list.
# ---------------------------------------------------------------------------

# Everything between `zap trash: [` and the closing `]`, quoted strings only.
ZAP_ENTRIES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && ZAP_ENTRIES+=("$line")
done < <(
    awk '
        /^[[:space:]]*zap[[:space:]]+trash:[[:space:]]*\[/ { inzap = 1; next }
        inzap && /^[[:space:]]*\]/ { inzap = 0 }
        inzap { print }
    ' "$CASK" | sed -n 's/^[^#"]*"\([^"]*\)".*$/\1/p'
)

if (( ${#ZAP_ENTRIES[@]} == 0 )); then
    fail "parsed zero entries from the cask's zap trash list - parser or cask layout broke"
    test_end
    exit 1
fi

# Precondition: the parser actually sees the list (not vacuous). These two
# entries are long-standing and unrelated to the terminfo directory.
ZAP_JOINED="$(printf '%s\n' "${ZAP_ENTRIES[@]}")"
assert_contains "$ZAP_JOINED" "~/.local/share/blackbird" \
    "parser sees the zap list (known entry ~/.local/share/blackbird present)"
assert_contains "$ZAP_JOINED" "~/Library/Preferences/dev.conjfrnk.blackbird.plist" \
    "parser sees the zap list (known entry for the prefs plist present)"

# ---------------------------------------------------------------------------
# 3. The observed install location must be covered by a zap entry.
#    Exact match, or a glob that matches it (Homebrew expands globs in
#    trash paths). Entries are compared as absolute paths under TMP_HOME.
# ---------------------------------------------------------------------------

INSTALLED_ABS="$TMP_HOME/${INSTALLED[0]}"
COVERED_BY=""
for entry in "${ZAP_ENTRIES[@]}"; do
    [[ "$entry" == "~/"* ]] || continue
    rest="${entry#\~/}"
    # Quoted prefix = literal; unquoted remainder = shell glob pattern.
    # shellcheck disable=SC2053
    if [[ "$INSTALLED_ABS" == "$TMP_HOME"/$rest ]]; then
        COVERED_BY="$entry"
        break
    fi
done

TERMINFO_ENTRIES="$(printf '%s\n' "${ZAP_ENTRIES[@]}" | grep -F '.terminfo' || true)"

if [[ -n "$COVERED_BY" ]]; then
    pass "zap list covers $INSTALLED_TILDE (via $COVERED_BY)"
else
    fail "zap list does not cover the file macOS tic installs: $INSTALLED_TILDE; terminfo zap entries present: [${TERMINFO_ENTRIES:-<none>}]"
fi

test_end
