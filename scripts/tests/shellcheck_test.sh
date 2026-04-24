#!/usr/bin/env bash
#
# Gate every shell script under scripts/ through shellcheck. Any warning
# at `warning` severity or above fails the test (info-level lint is
# tolerated to avoid bikeshed noise on style-only suggestions).
#
# Why this is a release-script gate: F-S8 surfaced multiple `|| true`
# patterns that shellcheck flags directly (SC2069 / SC2015), and the
# CODESIGN_LOG = $(...) bug (F-S8-001) is exactly the SC2069/SC2155 class
# of issue. shellcheck-clean today ≠ shellcheck-clean tomorrow if a new
# script lands without the gate.
#
# Skips with a clear log line on runners without shellcheck installed,
# rather than failing — install via `brew install shellcheck` for a real
# pass.

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "shellcheck_test.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "    skip: shellcheck not on PATH (install via 'brew install shellcheck')"
    test_end
    exit 0
fi

# Discover every tracked .sh under scripts/, excluding the test harness
# itself (lib.sh and *_test.sh have their own conventions and shouldn't
# bring down the production gate). We DO check run.sh — the harness
# entry point is shipped with the repo and held to the same standard.
#
# bash 3.2 (the macOS system bash) doesn't have `mapfile`, so we use a
# while-read loop. NUL-safety isn't a concern: filenames here are
# always plain ASCII paths under scripts/.
TARGETS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && TARGETS+=("$line")
done < <(
    cd "$BB_REPO_ROOT"
    find scripts -maxdepth 1 -name '*.sh' -type f | sort
)

if (( ${#TARGETS[@]} == 0 )); then
    fail "no scripts found under scripts/ — repo layout regression?"
    test_end
    exit 1
fi

echo "    checking ${#TARGETS[@]} script(s) at -S warning"

OVERALL_OK=1
for s in "${TARGETS[@]}"; do
    full="$BB_REPO_ROOT/$s"
    # -x follows external sources; -S warning silences info-only lint.
    # Capture so we can include the diagnostic on failure.
    out="$(shellcheck -x -S warning "$full" 2>&1 || true)"
    if [[ -n "$out" ]]; then
        fail "shellcheck warnings in $s"
        printf '%s\n' "$out" | head -40 | sed 's/^/      | /' >&2
        OVERALL_OK=0
    else
        pass "shellcheck clean: $s"
    fi
done

if (( OVERALL_OK == 1 )); then
    : # all clean
fi

test_end
