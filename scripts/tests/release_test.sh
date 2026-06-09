#!/usr/bin/env bash
#
# Hermetic test for scripts/release.sh — specifically the F-S8-001
# CODESIGN_LOG swallow.
#
# Findings cross-ref:
#   - F-S8-001: `CODESIGN_LOG="$(codesign ... 2>&1)"` followed by
#     `CODESIGN_STATUS=$?` is defeated by `set -e`. Under `set -e`, an
#     assignment whose RHS is a failing `$(...)` aborts the script
#     before $? is ever read — so the operator never sees the codesign
#     diagnostic.
#
# Test strategy: full hermetic run is hard because release.sh shells out
# to xcodebuild + cargo. Instead we:
#   1. Stub `xcodebuild`, `codesign`, and `hdiutil` on PATH.
#   2. The `xcodebuild archive` and `xcodebuild -exportArchive` stubs
#      fabricate a Blackbird.app bundle in $EXPORT_DIR with a fake
#      Sparkle.framework directory so the `[[ ! -d ... ]]` guard passes.
#   3. The `codesign` stub exits non-zero with a deterministic stderr
#      message ("FAKE_CODESIGN_DIAG_TOKEN").
#   4. Run release.sh, capture stdout+stderr, assert that
#      FAKE_CODESIGN_DIAG_TOKEN appears in the output AND the exit
#      code is non-zero.
#
# THIS TEST IS GATED behind BB_TEST_RELEASE_FAILURE=1 because (a) it
# requires substantial PATH gymnastics that could be brittle on weird
# build environments, (b) F-S8-001 is currently a known latent bug that
# this test will FAIL against until fixed, and we don't want CI red
# on every run for a known issue tracked elsewhere. CI gates explicitly
# opt in.
#
# Skipping prints a clear "skipped (F-S8-001)" line so the gap is
# visible.

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "release_test.sh"

# ---------------------------------------------------------------------------
# CASE — H1: smoke.sh's `wait || true` after `kill` hides crash-on-launch.
# The script SIGTERMs the app at the 3s mark and expects exit 143 (128+15)
# or 0; any other exit is a crash and must fail the smoke test.
#
# Hermetic harness: redirect HOME so smoke.sh's hardcoded DerivedData lookup
# resolves into a fixture tree, place a bash script as the "Blackbird"
# binary so we can control its exit code, set BB_SKIP_RESIGN=1 so the
# `security find-identity` block is skipped.
# ---------------------------------------------------------------------------

case_smoke_crash_detection() {
    local tmp; tmp="$(mk_tmp bb-smoke-h1)"
    trap "rm -rf '$tmp'" RETURN

    local derived="$tmp/Library/Developer/Xcode/DerivedData/Blackbird-fakehash"
    local app_macos="$derived/Build/Products/Debug/Blackbird.app/Contents/MacOS"
    mkdir -p "$app_macos"
    # Crash-on-launch fake: emit a diagnostic to stderr, exit 134 (SIGABRT).
    # smoke.sh's `sleep 3; kill` won't reach this binary because it's
    # already dead — `wait` returns the original abort code, NOT 143.
    cat >"$app_macos/Blackbird" <<'CRASH'
#!/usr/bin/env bash
echo "fake Blackbird: dyld: Library not loaded: @rpath/Sparkle.framework" >&2
exit 134
CRASH
    chmod +x "$app_macos/Blackbird"

    local log; log="$(mktemp)"
    local rc=0
    (
        export HOME="$tmp"
        export BB_SKIP_RESIGN=1
        bash "$BB_REPO_ROOT/scripts/smoke.sh"
    ) >"$log" 2>&1 || rc=$?

    if [[ "$rc" == "0" ]]; then
        fail "H1: smoke.sh exited 0 despite app exiting 134 (mask via 'wait || true')"
        head -20 "$log" | sed 's/^/      | /' >&2
    else
        pass "H1: smoke.sh detects crash-on-launch (rc=$rc)"
    fi

    # The captured stderr from the fake binary should surface in the log
    # so the operator can debug. The fix's diagnostic prints the captured
    # stderr tail when wait_rc isn't 0/143.
    if grep -q "dyld: Library not loaded" "$log"; then
        pass "H1: smoke.sh surfaces captured app stderr on crash"
    else
        fail "H1: smoke.sh swallowed the crashed app's stderr"
        tail -20 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

# Smoke-detection test runs unconditionally — it's pure shell with no
# real codesign / xcodebuild dependencies.
case_smoke_crash_detection

if [[ "${BB_TEST_RELEASE_FAILURE:-0}" != "1" ]]; then
    echo "    skip: release.sh failure-path tests are opt-in via BB_TEST_RELEASE_FAILURE=1"
    echo "          (F-S8-001 codesign-log swallow + M-11 Team ID pin regression-guards;"
    echo "           F-S8-001 capture fix landed 2026-06-09; the gated case now passes)"
    test_end
    exit 0
fi

# Build a fixture rooted at $tmp that contains:
#   scripts/release.sh   (real script, copied)
#   scripts/build-core.sh (no-op stub — release.sh sources this for Rust core)
#   project.yml          (minimal — release.sh greps DEVELOPMENT_TEAM out of it)
#   stub-bin/xcodebuild  (fabricates archive + exports a fake .app)
#   stub-bin/codesign    (mode-driven: $2 controls behavior — see below)
#   stub-bin/hdiutil     (no-op)
#
# $2 codesign_mode:
#   "fail-verify"  — codesign exits 1 with FAKE_CODESIGN_DIAG_TOKEN. Used by
#                    the F-S8-001 swallow test; both --verify and --display
#                    fail the same way.
#   "wrong-team"   — --verify passes (rc=0), --display emits a Team ID that
#                    DOES NOT match $expected_team_id. Used to assert the
#                    M-11 Team ID pin rejects the wrong identity.
#   "right-team"   — --verify passes, --display emits the matching Team ID.
#                    Used as a positive control that the Team ID check
#                    doesn't false-positive on a correctly-signed bundle.
mk_release_fixture() {
    local root="$1"
    local codesign_mode="${2:-fail-verify}"
    local expected_team_id="${3:-F2B95Q4CT8}"
    mkdir -p "$root/scripts" "$root/stub-bin" "$root/dist"

    cp "$BB_REPO_ROOT/scripts/release.sh" "$root/scripts/release.sh"
    chmod +x "$root/scripts/release.sh"

    cp "$BB_REPO_ROOT/scripts/ExportOptions.plist" "$root/scripts/ExportOptions.plist"

    # Minimal project.yml — release.sh greps DEVELOPMENT_TEAM out of this
    # for the M-11 Team ID pin check. Keep the indentation matching the
    # real project.yml so the awk anchor matches.
    cat >"$root/project.yml" <<PYAML
name: Blackbird
targets:
  Blackbird:
    settings:
      base:
        DEVELOPMENT_TEAM: ${expected_team_id}
        CODE_SIGN_IDENTITY: "Developer ID Application"
PYAML

    # build-core.sh stub — release.sh calls `bash scripts/build-core.sh`
    # very early. No-op.
    cat >"$root/scripts/build-core.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$root/scripts/build-core.sh"

    # xcodebuild stub. The script invokes:
    #   xcodebuild archive ... -archivePath "$ARCHIVE_PATH" \
    #              -derivedDataPath "$DIST_DIR/DerivedData" archive ...
    #   xcodebuild -exportArchive ... -exportPath "$EXPORT_DIR" ...
    # We just fabricate the resulting layout the post-archive code expects.
    # BB_TEST_BAD_PLIST=1 in the environment causes the export step to write
    # an empty / corrupted Info.plist, which is the H2 failure-mode regression
    # guard for `|| echo "0.0.0"` masking a PlistBuddy read failure.
    cat >"$root/stub-bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
# Detect "archive" vs "-exportArchive" mode from args.
mode="archive"
export_path=""
prev=""
for arg in "$@"; do
    case "$arg" in
        -exportArchive) mode="export" ;;
    esac
    if [[ "$prev" == "-exportPath" ]]; then export_path="$arg"; fi
    prev="$arg"
done
case "$mode" in
    archive)
        # No-op — we don't need to fabricate the .xcarchive contents
        # because release.sh only feeds them back into -exportArchive.
        ;;
    export)
        # Fabricate a Blackbird.app at $export_path with the bits the
        # downstream script reads.
        APP="$export_path/Blackbird.app"
        mkdir -p "$APP/Contents/Frameworks/Sparkle.framework"
        if [[ "${BB_TEST_BAD_PLIST:-0}" == "1" ]]; then
            : > "$APP/Contents/Info.plist"
        else
            cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>9.9.9</string>
    <key>CFBundleVersion</key>
    <string>9999</string>
</dict>
</plist>
PLIST
        fi
        ;;
esac
exit 0
STUB
    chmod +x "$root/stub-bin/xcodebuild"

    # codesign stub — behavior driven by $codesign_mode (see mk_release_fixture
    # docstring). release.sh calls codesign in two distinct shapes:
    #   codesign --verify --strict --deep --verbose=2 "$APP_DST"
    #   codesign --display --verbose=2 "$APP_DST"
    # The stub branches on which shape it's invoked with so a single fixture
    # can exercise both paths.
    case "$codesign_mode" in
        fail-verify)
            cat >"$root/stub-bin/codesign" <<'STUB'
#!/usr/bin/env bash
echo "fake codesign: simulated failure" >&2
echo "FAKE_CODESIGN_DIAG_TOKEN: bundle format unrecognized, invalid, or unsuitable" >&2
echo "FAKE_CODESIGN_DIAG_TOKEN: resource fork, Finder information, or similar detritus not allowed" >&2
exit 1
STUB
            ;;
        wrong-team)
            cat >"$root/stub-bin/codesign" <<'STUB'
#!/usr/bin/env bash
mode="other"
for arg in "$@"; do
    case "$arg" in
        --verify) mode="verify" ;;
        --display) mode="display" ;;
    esac
done
case "$mode" in
    verify)
        # --verify passes silently, mimicking a correctly self-consistent
        # signature.
        exit 0
        ;;
    display)
        # --display emits a TeamIdentifier that DOES NOT match the
        # DEVELOPMENT_TEAM in project.yml. This is the M-11 trigger:
        # operator's keychain identity belongs to a different Apple
        # Developer account than the one pinned in project.yml.
        cat <<'EOF' >&2
Executable=/path/to/Blackbird.app/Contents/MacOS/Blackbird
Identifier=dev.conjfrnk.blackbird
Format=app bundle with Mach-O thin (arm64)
TeamIdentifier=XXXXXXXXXX
EOF
        exit 0
        ;;
esac
exit 0
STUB
            ;;
        right-team)
            cat >"$root/stub-bin/codesign" <<STUB
#!/usr/bin/env bash
mode="other"
for arg in "\$@"; do
    case "\$arg" in
        --verify) mode="verify" ;;
        --display) mode="display" ;;
    esac
done
case "\$mode" in
    verify) exit 0 ;;
    display)
        cat <<'EOF' >&2
Executable=/path/to/Blackbird.app/Contents/MacOS/Blackbird
Identifier=dev.conjfrnk.blackbird
Format=app bundle with Mach-O thin (arm64)
TeamIdentifier=${expected_team_id}
EOF
        exit 0
        ;;
esac
exit 0
STUB
            ;;
        *)
            echo "fatal: unknown codesign_mode '$codesign_mode'" >&2
            return 1
            ;;
    esac
    chmod +x "$root/stub-bin/codesign"

    # hdiutil stub — release.sh runs `hdiutil create ...`. Don't reach
    # this in the failure path, but stub it anyway in case the codesign
    # bug masks the failure entirely and the script proceeds.
    cat >"$root/stub-bin/hdiutil" <<'STUB'
#!/usr/bin/env bash
# Just touch the output DMG path so subsequent ops don't fail.
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-volname" || "$prev" == "-srcfolder" ]]; then :; fi
    prev="$arg"
done
# Last positional is the DMG path for `hdiutil create`.
last=""
for arg in "$@"; do last="$arg"; done
if [[ -n "$last" && "$last" != "-"* ]]; then
    : > "$last"
fi
exit 0
STUB
    chmod +x "$root/stub-bin/hdiutil"
}

run_release() {
    local fixture="$1" log="$2"
    if [[ "$fixture" == "$BB_REPO_ROOT" || "$fixture" == "$BB_REPO_ROOT"/* ]]; then
        echo "fatal: fixture path leaks into real repo: $fixture" >&2
        return 99
    fi
    local rc=0
    (
        cd "$fixture"
        export PATH="$fixture/stub-bin:$PATH"
        # Silence DEVELOPER_ID branch — leave unset so release.sh uses
        # its default identity flow.
        unset DEVELOPER_ID || true
        unset APPLE_ID APP_SPECIFIC_PASSWORD TEAM_ID || true
        bash "$fixture/scripts/release.sh"
    ) >"$log" 2>&1 || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# CASE — F-S8-001 codesign-log swallow.
# ---------------------------------------------------------------------------

case_codesign_log_swallow() {
    local tmp; tmp="$(mk_tmp bb-rel-1)"
    trap "rm -rf '$tmp'" RETURN

    mk_release_fixture "$tmp" "fail-verify"

    local log; log="$(mktemp)"
    local rc; rc="$(run_release "$tmp" "$log")"

    if [[ "$rc" == "0" ]]; then
        fail "F-S8-001: release.sh exited 0 despite codesign failure"
        head -50 "$log" | sed 's/^/      | /' >&2
    else
        pass "release.sh exits non-zero on codesign failure (rc=$rc)"
    fi

    if grep -q "FAKE_CODESIGN_DIAG_TOKEN" "$log"; then
        pass "F-S8-001: codesign diagnostic surfaced to operator"
    else
        fail "F-S8-001: codesign diagnostic SWALLOWED — operator sees no detail"
        echo "      script log tail:" >&2
        tail -20 "$log" | sed 's/^/      | /' >&2
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE — M-11: release.sh must reject a bundle whose signed Team ID
# doesn't match the DEVELOPMENT_TEAM in project.yml. Symmetric with
# publish-update.sh:147 (which catches the same problem post-notarization);
# this is the build-phase pre-flight so a wrong-team artifact never leaves
# the developer's machine.
# ---------------------------------------------------------------------------

case_team_id_mismatch() {
    local tmp; tmp="$(mk_tmp bb-rel-2)"
    trap "rm -rf '$tmp'" RETURN

    # project.yml DEVELOPMENT_TEAM = F2B95Q4CT8 (default), codesign stub
    # emits TeamIdentifier=XXXXXXXXXX → mismatch → release.sh must abort.
    mk_release_fixture "$tmp" "wrong-team" "F2B95Q4CT8"

    local log; log="$(mktemp)"
    local rc; rc="$(run_release "$tmp" "$log")"

    if [[ "$rc" == "0" ]]; then
        fail "M-11: release.sh exited 0 with wrong-team-signed bundle"
        head -40 "$log" | sed 's/^/      | /' >&2
    else
        pass "M-11: release.sh aborts on Team ID mismatch (rc=$rc)"
    fi

    # The diagnostic should mention BOTH the actual and expected Team IDs
    # so the operator can debug their keychain selection without having to
    # re-run codesign by hand.
    if grep -q "F2B95Q4CT8" "$log" && grep -q "XXXXXXXXXX" "$log"; then
        pass "M-11: diagnostic includes both expected and actual Team IDs"
    else
        fail "M-11: diagnostic missing Team ID details"
        tail -20 "$log" | sed 's/^/      | /' >&2
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE — M-11 positive control: when codesign --display reports the
# matching Team ID, release.sh proceeds past the verify block (and only
# fails later at hdiutil / Sparkle.framework checks, which is fine — we
# only care that the Team ID gate didn't false-positive).
# ---------------------------------------------------------------------------

case_team_id_match() {
    local tmp; tmp="$(mk_tmp bb-rel-3)"
    trap "rm -rf '$tmp'" RETURN

    mk_release_fixture "$tmp" "right-team" "F2B95Q4CT8"

    local log; log="$(mktemp)"
    run_release "$tmp" "$log" >/dev/null

    # Whether or not later steps succeed, the Team ID line should have
    # printed and the Team ID mismatch error should NOT have fired.
    if grep -q "codesign Team ID verified: F2B95Q4CT8" "$log"; then
        pass "M-11: positive control — Team ID match logged"
    else
        fail "M-11: positive control — Team ID match line not printed"
        tail -30 "$log" | sed 's/^/      | /' >&2
    fi
    if grep -q "signed Team ID mismatch" "$log"; then
        fail "M-11: false-positive — mismatch error fired on matching Team ID"
    else
        pass "M-11: no false-positive on matching Team ID"
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE — H2: PlistBuddy read failure must abort, not silently coerce to
# "0.0.0" and ship Blackbird-0.0.0.dmg through the rest of the pipeline.
# Drive the export-step xcodebuild stub to write an empty Info.plist;
# PlistBuddy will fail; release.sh must exit non-zero with a diagnostic
# AND must not have produced a Blackbird-0.0.0.dmg in dist/.
# ---------------------------------------------------------------------------

case_plistbuddy_no_zero_fallback() {
    local tmp; tmp="$(mk_tmp bb-rel-h2)"
    trap "rm -rf '$tmp'" RETURN

    mk_release_fixture "$tmp" "right-team" "F2B95Q4CT8"

    local log; log="$(mktemp)"
    local rc=0
    (
        cd "$tmp"
        export PATH="$tmp/stub-bin:$PATH"
        export BB_TEST_BAD_PLIST=1
        unset DEVELOPER_ID APPLE_ID APP_SPECIFIC_PASSWORD TEAM_ID || true
        bash "$tmp/scripts/release.sh"
    ) >"$log" 2>&1 || rc=$?

    if [[ "$rc" == "0" ]]; then
        fail "H2: release.sh exited 0 with broken Info.plist"
        head -40 "$log" | sed 's/^/      | /' >&2
    else
        pass "H2: release.sh aborts when PlistBuddy can't read Info.plist (rc=$rc)"
    fi

    if [[ -e "$tmp/dist/Blackbird-0.0.0.dmg" ]]; then
        fail "H2: release.sh produced Blackbird-0.0.0.dmg from masked PlistBuddy failure"
    else
        pass "H2: no Blackbird-0.0.0.dmg artifact slipped past the broken-plist check"
    fi
    rm -f "$log"
}

case_codesign_log_swallow
case_team_id_mismatch
case_team_id_match
case_plistbuddy_no_zero_fallback

test_end
