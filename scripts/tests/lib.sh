#!/usr/bin/env bash
#
# Shared helpers for Blackbird release-script tests. Sourced by every
# `*_test.sh` file in this directory.
#
# Provides:
#   - test scaffolding (test_start, test_end, fail, pass)
#   - assertion helpers (assert_eq, assert_ne, assert_contains,
#     assert_not_contains, assert_file_exists, assert_file_missing,
#     assert_exit_code, assert_nonempty_file)
#   - hermetic-tmp helpers (mk_tmp, with each test installing its own
#     trap to clean up — we don't override EXIT centrally because tests
#     may need finer-grained cleanup ordering for hdiutil mounts etc.)
#
# Convention: TESTS contribute one line per assertion to TEST_LOG; the
# enclosing test_start / test_end frame totals.

set -euo pipefail

# Resolved by run.sh and exported; if a test is run in isolation, fall
# back to the obvious paths.
: "${BB_TESTS_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${BB_REPO_ROOT:=$(cd "$BB_TESTS_DIR/../.." && pwd)}"
export BB_TESTS_DIR BB_REPO_ROOT

# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------

# Per-file totals; reset by test_start.
_BB_TEST_FILE=""
_BB_TEST_PASSED=0
_BB_TEST_FAILED=0
_BB_TEST_FAILURES=()

test_start() {
    _BB_TEST_FILE="${1:-$(basename "${BASH_SOURCE[1]:-unknown}")}"
    _BB_TEST_PASSED=0
    _BB_TEST_FAILED=0
    _BB_TEST_FAILURES=()
    echo "  [start] $_BB_TEST_FILE"
}

# Frame the file. Exits non-zero if any assertion failed.
test_end() {
    local total=$((_BB_TEST_PASSED + _BB_TEST_FAILED))
    if (( _BB_TEST_FAILED == 0 )); then
        echo "  [done]  $_BB_TEST_FILE: $_BB_TEST_PASSED/$total assertions passed"
        return 0
    fi
    echo "  [done]  $_BB_TEST_FILE: $_BB_TEST_PASSED/$total passed; $_BB_TEST_FAILED FAILED" >&2
    for f in "${_BB_TEST_FAILURES[@]}"; do
        echo "          - $f" >&2
    done
    return 1
}

pass() {
    _BB_TEST_PASSED=$((_BB_TEST_PASSED + 1))
    echo "    ok   ${1:-anonymous assertion}"
}

fail() {
    _BB_TEST_FAILED=$((_BB_TEST_FAILED + 1))
    _BB_TEST_FAILURES+=("${1:-anonymous failure}")
    echo "    FAIL ${1:-anonymous failure}" >&2
}

# ---------------------------------------------------------------------------
# Assertions — each takes (actual, expected, label) or (haystack, needle, label).
# ---------------------------------------------------------------------------

assert_eq() {
    local actual="$1" expected="$2" label="${3:-eq}"
    if [[ "$actual" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label: expected '$expected', got '$actual'"
    fi
}

assert_ne() {
    local actual="$1" expected="$2" label="${3:-ne}"
    if [[ "$actual" != "$expected" ]]; then
        pass "$label"
    else
        fail "$label: both sides == '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" label="${3:-contains}"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label: '$needle' not found in output"
        # Print up to 30 lines of context to ease debugging.
        printf '%s' "$haystack" | head -30 | sed 's/^/        | /' >&2
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-not_contains}"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$label: forbidden substring '$needle' present"
        printf '%s' "$haystack" | head -30 | sed 's/^/        | /' >&2
    else
        pass "$label"
    fi
}

assert_file_exists() {
    local path="$1" label="${2:-file_exists}"
    if [[ -e "$path" ]]; then
        pass "$label ($path)"
    else
        fail "$label: '$path' does not exist"
    fi
}

assert_file_missing() {
    local path="$1" label="${2:-file_missing}"
    if [[ ! -e "$path" ]]; then
        pass "$label ($path)"
    else
        fail "$label: '$path' should not exist"
    fi
}

assert_nonempty_file() {
    local path="$1" label="${2:-nonempty_file}"
    if [[ -s "$path" ]]; then
        pass "$label ($path, $(wc -c <"$path" | tr -d ' ') bytes)"
    else
        fail "$label: '$path' missing or empty"
    fi
}

assert_exit_code() {
    local actual="$1" expected="$2" label="${3:-exit_code}"
    if [[ "$actual" == "$expected" ]]; then
        pass "$label (exit $actual)"
    else
        fail "$label: expected exit $expected, got $actual"
    fi
}

# Run a command, capture stdout+stderr to a temp file, and echo the
# exit code. Caller decides what to do with the captured log.
#
# Usage:
#   log="$(mktemp)"
#   rc=$(run_capture "$log" some-command --with --args)
#   echo "exit=$rc"
#   cat "$log"
run_capture() {
    local logfile="$1"; shift
    local rc=0
    "$@" >"$logfile" 2>&1 || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# Hermetic tmp dirs
# ---------------------------------------------------------------------------

mk_tmp() {
    local prefix="${1:-bb-s8-test}"
    mktemp -d -t "$prefix.XXXXXX"
}

# Initialize a minimal git repo at $1 with one commit and origin remote
# pointing at a bare repo on disk (so `git push origin main` works without
# touching the real network). Echoes nothing.
mk_git_fixture() {
    local repo="$1"
    local origin_dir="${2:-${repo}-origin.git}"
    (
        set -e
        mkdir -p "$origin_dir"
        git init --quiet --bare "$origin_dir"
        cd "$repo"
        git init --quiet -b main
        git config user.name "Blackbird Test"
        git config user.email "test@example.invalid"
        git config commit.gpgsign false
        git config tag.gpgsign false
        git remote add origin "$origin_dir"
        # Initial commit so HEAD exists. If the caller already wrote a
        # .gitignore (e.g. to ignore a stub-bin/ tree), preserve it —
        # appending an init marker rather than clobbering.
        if [[ -f .gitignore ]]; then
            printf '\n# init marker\n' >> .gitignore
        else
            printf '# init marker\n' > .gitignore
        fi
        git add .gitignore
        git -c commit.gpgsign=false commit -q -m "init"
        git push -q --set-upstream origin main
    )
}

# Place a fake binary at $1 that emits the given stdout/stderr/exit-code.
# Useful for stubbing codesign / sign_update / git etc.
#
# Usage:
#   mk_stub /tmp/bin/codesign 1 "" "fake codesign: bad signature on Foo.app"
mk_stub() {
    local path="$1" rc="$2" stdout="$3" stderr="$4"
    mkdir -p "$(dirname "$path")"
    cat >"$path" <<STUB
#!/usr/bin/env bash
# Auto-generated test stub.
[[ -n "$stdout" ]] && printf '%s\n' "$stdout"
[[ -n "$stderr" ]] && printf '%s\n' "$stderr" >&2
exit $rc
STUB
    chmod +x "$path"
}

# Resolve a script path under $BB_REPO_ROOT/scripts.
script_path() {
    echo "$BB_REPO_ROOT/scripts/$1"
}
