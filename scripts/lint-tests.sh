#!/usr/bin/env bash
# Test-quality lint. Flags low-signal assertions that tend to pass for
# the wrong reason — `XCTAssertNotNil(singleObject)`, Rust `.is_some()`
# in #[test] bodies. These aren't *always* wrong, but they are the
# dominant shape when a test asserts "something ran" instead of "the
# specific expected value". Audit K5 cluster (assertion-hygiene).
#
# This script is a ratchet: it prints the current count and the
# recorded baseline. If the current count exceeds the baseline, it
# exits non-zero and CI fails. Teams reduce the baseline over time by
# fixing existing low-signal assertions.
#
# Baseline is in .test-lint-baseline at repo root. Update it only when
# you've genuinely reduced the count (or added a reviewed, commented
# exception).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE_FILE=".test-lint-baseline"

# Swift: bare XCTAssertNotNil(x) — i.e. no trailing `, "msg"` / no
# comma before the closing paren. Crude but stable.
swift_count=$(grep -Eohr 'XCTAssertNotNil\([^,)]+\)' Tests/BlackbirdTests/ | wc -l | tr -d ' ')

# Rust: `.is_some()` inside test files. Legitimate as a guard before
# deeper assertions; but if it's the only assertion in a test, that's
# rust-tests F1/F2/F3 territory.
rust_count=$(grep -rE '\.is_some\(\)' core/tests/ 2>/dev/null | grep -cvE '^\s*//' || true)

total=$((swift_count + rust_count))

printf 'test-lint: bare XCTAssertNotNil = %d\n' "$swift_count"
printf 'test-lint: .is_some() in core/tests = %d\n' "$rust_count"
printf 'test-lint: total low-signal assertions = %d\n' "$total"

if [[ ! -f $BASELINE_FILE ]]; then
    printf 'test-lint: no baseline at %s, recording current count\n' "$BASELINE_FILE"
    echo "$total" > "$BASELINE_FILE"
    exit 0
fi

baseline=$(cat "$BASELINE_FILE")
printf 'test-lint: baseline = %d\n' "$baseline"

if (( total > baseline )); then
    printf 'test-lint: FAIL — count grew by %d since baseline\n' "$((total - baseline))" >&2
    printf 'test-lint: if the new assertions are genuinely required, update %s\n' "$BASELINE_FILE" >&2
    printf 'test-lint: otherwise replace them with XCTAssertEqual / exact-value checks\n' >&2
    exit 1
fi

if (( total < baseline )); then
    printf 'test-lint: NOTE — count shrank by %d below baseline. Consider updating %s.\n' \
        "$((baseline - total))" "$BASELINE_FILE"
fi

printf 'test-lint: OK\n'
