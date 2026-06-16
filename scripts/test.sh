#!/usr/bin/env bash
# Local test runner that mirrors the CI test invocation, with one deliberate
# divergence: a scoped -only-testing run keeps the scheme's ASan ON (see the
# Sanitizers note below). It bypasses code signing entirely so xcodebuild
# doesn't prompt the keychain for
# access to the signing key when it re-signs embedded frameworks
# (XCUIAutomation, libclang_rt.asan_osx_dynamic, etc.).
#
# "Always allow" in the keychain prompt is brittle — a new process
# spawn or a detached framework signing path can re-ask, and if the
# ACL didn't persist the user gets stuck clicking through repeatedly.
# Disabling signing for test builds avoids the codepath altogether.
# CI does exactly this (.github/workflows/ci.yml: CODE_SIGNING_ALLOWED=NO).
#
# Pass through any extra xcodebuild args: `scripts/test.sh -only-testing:BlackbirdTests/TabStripStressTests`.
#
# Sanitizers: a WHOLE-suite run (no -only-testing) is run with ASan/UBSan OFF
# to match CI exactly (.github/workflows/ci.yml). Both the runtime flags
# (-enable*Sanitizer NO) AND the build-setting overrides
# (ENABLE_*_SANITIZER=NO) are required -- the -enable flag alone only governs
# the test action's RUNTIME, leaving the binary ASan-instrumented so it still
# SEGVs. Under ASan the long-lived xctest host
# accumulates shadow/VM mappings across the ~900-test suite until a ceiling is
# hit; past it, a CoreAnimation transaction flush on the main runloop pops an
# autorelease pool that releases an already-freed AppKit object -> SEGV in
# whichever test happens to be pumping the runloop (the "full-suite-only"
# crash). CI dodges it the same way. A SCOPED run (-only-testing:...) stays
# well under the ceiling, so it KEEPS the scheme's ASan/UBSan ON -- that's
# where local memory-safety coverage actually runs, and it's the common
# workflow. The Blackbird scheme is untouched (ASan stays on for Xcode Cmd-U),
# per CLAUDE.md hard-rule 6.
#
# BB_SUPPRESS_BELL silences the prompt-nav NSSound.beep() and AppKit's
# unhandled-key NSBeep in the xctest host so an automated run doesn't emit a
# stream of system beeps (production + Xcode Cmd-U ring normally).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Sanitizers OFF for the whole suite (CI parity); ON (scheme default) for a
# scoped run. WHOLE_SUITE also gates the infra-restart absorption below.
SAN_FLAGS=""
WHOLE_SUITE=1
case " $* " in
    # Only an explicit -only-testing keeps ASan ON; a -skip-testing run is
    # still ~whole-suite, so it deliberately falls through to ASan-OFF.
    *" -only-testing"*) WHOLE_SUITE=0 ;;
esac
if [[ "$WHOLE_SUITE" -eq 1 ]]; then
    SAN_FLAGS="-enableAddressSanitizer NO -enableUndefinedBehaviorSanitizer NO ENABLE_ADDRESS_SANITIZER=NO ENABLE_UNDEFINED_BEHAVIOR_SANITIZER=NO"
fi

# A whole-suite run can trip a known infra quirk even with ASan off: at ~900
# tests the xctest host occasionally exits mid-run, xctest restarts it cleanly,
# every suite passes on the restart, but xcodebuild still exits 65 and pins a
# phantom entry under "Failing tests:". CI absorbs this identically
# (.github/workflows/ci.yml): trust the suites' own "passed" verdict, but never
# absorb a real per-test failure or any AddressSanitizer error. A scoped run is
# NOT absorbed -- its RC=65 is a genuine failure, not the ~900-test quirk.
LOG="$(mktemp "${TMPDIR:-/tmp}/bb-test.XXXXXX")"
set +e
# shellcheck disable=SC2086  # SAN_FLAGS is an intentional word-split (empty or four flags).
env TEST_RUNNER_BB_SUPPRESS_BELL=1 xcodebuild test \
    -scheme Blackbird \
    -destination 'platform=macOS,arch=arm64' \
    -skipPackagePluginValidation \
    $SAN_FLAGS \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    "$@" 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
set -e

if [[ "$rc" -ne 0 && "$WHOLE_SUITE" -eq 1 ]] \
    && grep -q "Test Suite 'BlackbirdTests.xctest' passed" "$LOG" \
    && grep -q "Test Suite 'Selected tests' passed" "$LOG" \
    && ! grep -qE "Test Case .* failed" "$LOG" \
    && ! grep -q "AddressSanitizer:" "$LOG"; then
    echo "note: xcodebuild exited $rc on an infra restart, but every suite passed and no test failed -- treating as success (CI parity; see .github/workflows/ci.yml)." >&2
    rc=0
fi
rm -f "$LOG"
exit "$rc"
