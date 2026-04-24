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

if [[ "${BB_TEST_RELEASE_FAILURE:-0}" != "1" ]]; then
    echo "    skip: release.sh failure-path test is opt-in via BB_TEST_RELEASE_FAILURE=1"
    echo "          (F-S8-001 codesign-log swallow regression-guard; will FAIL until the"
    echo "           CODESIGN_LOG=\$(...) capture is fixed in scripts/release.sh)"
    test_end
    exit 0
fi

# Build a fixture rooted at $tmp that contains:
#   scripts/release.sh   (real script, copied)
#   scripts/build-core.sh (no-op stub — release.sh sources this for Rust core)
#   stub-bin/xcodebuild  (fabricates archive + exports a fake .app)
#   stub-bin/codesign    (always fails with FAKE_CODESIGN_DIAG_TOKEN)
#   stub-bin/hdiutil     (no-op)
mk_release_fixture() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/stub-bin" "$root/dist"

    cp "$BB_REPO_ROOT/scripts/release.sh" "$root/scripts/release.sh"
    chmod +x "$root/scripts/release.sh"

    cp "$BB_REPO_ROOT/scripts/ExportOptions.plist" "$root/scripts/ExportOptions.plist"

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
        ;;
esac
exit 0
STUB
    chmod +x "$root/stub-bin/xcodebuild"

    # codesign stub — ALWAYS fails with a known diagnostic. This is the
    # F-S8-001 trigger. We expect release.sh to print the diagnostic
    # before aborting; instead, the bug swallows it.
    cat >"$root/stub-bin/codesign" <<'STUB'
#!/usr/bin/env bash
echo "fake codesign: simulated failure" >&2
echo "FAKE_CODESIGN_DIAG_TOKEN: bundle format unrecognized, invalid, or unsuitable" >&2
echo "FAKE_CODESIGN_DIAG_TOKEN: resource fork, Finder information, or similar detritus not allowed" >&2
exit 1
STUB
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

    mk_release_fixture "$tmp"

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

case_codesign_log_swallow

test_end
