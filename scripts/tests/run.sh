#!/usr/bin/env bash
#
# Blackbird release/distribution-script test harness — entry point.
#
# Runs every `*_test.sh` file in this directory. Each test file is a plain
# bash script that:
#   - sources `lib.sh` for the assertion helpers (assert_*, fail, pass, ...)
#   - exits 0 on success, non-zero on failure
#   - never touches global state (no real git push, no real codesign, no
#     network calls).
#
# Skip control:
#   BB_SKIP_S8_TESTS=1   — skip everything (CI runners without shellcheck)
#   BB_TEST_RELEASE_FAILURE=1
#                        — opt in to release.sh's bad-identity test, which
#                          spins up a fake codesign shim. Off by default
#                          because it's the only one that's not pure
#                          fixture work.
#
# Usage:
#   bash scripts/tests/run.sh
#   bash scripts/tests/run.sh release_test.sh   # subset
#
# Exit code: 0 if everything passed (or skipped), non-zero if any test failed.

set -euo pipefail

if [[ "${BB_SKIP_S8_TESTS:-0}" == "1" ]]; then
    echo "BB_SKIP_S8_TESTS=1 set — skipping S8 release-script tests."
    exit 0
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
export BB_TESTS_DIR="$TESTS_DIR"
export BB_REPO_ROOT="$REPO_ROOT"

# Pre-flight: do we have shellcheck? The shellcheck gate is one of the
# tests and will fail loudly if not — but we'd rather skip with a clear
# diagnostic on a runner that genuinely doesn't have it.
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "warning: shellcheck not on PATH — the shellcheck gate will skip."
    echo "         install via 'brew install shellcheck' or set BB_SKIP_S8_TESTS=1 to silence."
fi

# Discover tests. A specific filename can be passed to narrow the run.
declare -a TESTS=()
if [[ $# -gt 0 ]]; then
    for t in "$@"; do
        if [[ -f "$TESTS_DIR/$t" ]]; then
            TESTS+=("$t")
        else
            echo "!! No such test file: $TESTS_DIR/$t" >&2
            exit 2
        fi
    done
else
    while IFS= read -r f; do
        TESTS+=("$(basename "$f")")
    done < <(find "$TESTS_DIR" -maxdepth 1 -name '*_test.sh' -type f | sort)
fi

if (( ${#TESTS[@]} == 0 )); then
    echo "!! No tests found in $TESTS_DIR" >&2
    exit 2
fi

echo "Running ${#TESTS[@]} test file(s) from $TESTS_DIR"
echo

PASSED=0
FAILED=0
FAILED_NAMES=()

for t in "${TESTS[@]}"; do
    echo "=== $t ==="
    # Each test runs in its own subshell so a `set -e` abort or `exit 1`
    # doesn't kill the harness. The tests source lib.sh themselves.
    if bash "$TESTS_DIR/$t"; then
        PASSED=$((PASSED + 1))
        echo "    PASS: $t"
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$t")
        echo "    FAIL: $t" >&2
    fi
    echo
done

echo "================================================================"
echo "Summary: $PASSED passed, $FAILED failed (of ${#TESTS[@]} test files)"
if (( FAILED > 0 )); then
    echo "Failed:"
    for n in "${FAILED_NAMES[@]}"; do
        echo "  - $n"
    done
    exit 1
fi
exit 0
