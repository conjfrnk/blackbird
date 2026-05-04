#!/usr/bin/env bash
#
# Hermetic tests for scripts/make-appcast.sh.
#
# Findings cross-ref:
#   - F-S8-008: `ls -t dist/Blackbird-*.dmg | head -1` picks freshest
#     by mtime — wrong when a stale-dated rebuild of a newer version
#     sits next to the version actually being published. The fix per
#     F-S8-008 is to take an explicit DMG path arg. This test asserts:
#       * given two DMGs in dist/ with deterministic names, the
#         currently-shipped script picks ONE of them and reports the
#         picked path in some form (env var or script behavior).
#       * the picked DMG matches a deterministic rule (today: lexically
#         largest filename ≈ semver-newest), NOT mtime.
#     Currently expected to FAIL until the explicit-arg fix lands —
#     this is the regression-guard.
#
# We can't fully run make-appcast.sh end-to-end (it requires
# sign_update + hdiutil mounting). Instead we exercise the DMG-pick
# code path by stubbing hdiutil + sign_update + PlistBuddy and observing
# which DMG_NAME ends up in the printed XML.

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "make_appcast_test.sh"

mk_appcast_fixture() {
    local root="$1"
    mkdir -p "$root/scripts" "$root/dist" "$root/stub-bin"

    cp "$BB_REPO_ROOT/scripts/make-appcast.sh" "$root/scripts/make-appcast.sh"
    chmod +x "$root/scripts/make-appcast.sh"

    # Stubbed hdiutil — accept attach, accept detach, no-op.
    # We DO need to fabricate a fake mounted Info.plist so PlistBuddy
    # has something to read. The script passes -mountpoint $MOUNT_POINT
    # to hdiutil, and the path it reads from is
    # "$MOUNT_POINT/Blackbird.app/Contents/Info.plist".
    cat >"$root/stub-bin/hdiutil" <<'STUB'
#!/usr/bin/env bash
# Parse args looking for `attach` and `-mountpoint <path>`.
mode=""; mp=""; prev=""
for arg in "$@"; do
    case "$arg" in
        attach|detach) mode="$arg" ;;
    esac
    if [[ "$prev" == "-mountpoint" ]]; then mp="$arg"; fi
    prev="$arg"
done
if [[ "$mode" == "attach" && -n "$mp" ]]; then
    mkdir -p "$mp/Blackbird.app/Contents"
    cat >"$mp/Blackbird.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleVersion</key>
    <string>42</string>
</dict>
</plist>
PLIST
fi
exit 0
STUB
    chmod +x "$root/stub-bin/hdiutil"

    # Stubbed sign_update — print the line shape make-appcast expects.
    cat >"$root/stub-bin/sign_update" <<'STUB'
#!/usr/bin/env bash
DMG="${1:-}"
echo "sparkle:edSignature=\"FAKE_SIG_FOR_$(basename "$DMG")\" length=\"123\""
exit 0
STUB
    chmod +x "$root/stub-bin/sign_update"
}

run_make_appcast() {
    local fixture="$1" log="$2"
    local rc=0
    (
        cd "$fixture"
        export PATH="$fixture/stub-bin:$PATH"
        export APPCAST_BASE_URL="https://example.test/blackbird"
        export APPCAST_FEED_URL="https://example.test/appcast.xml"
        export SIGN_UPDATE="$fixture/stub-bin/sign_update"
        bash "$fixture/scripts/make-appcast.sh"
    ) >"$log" 2>&1 || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# CASE 1 — Two DMGs, mtime-newer is older-version. Today's script picks
# by mtime → 0.2.0 wins (wrong by version). The test asserts the
# version-newest DMG (0.3.0) is picked, regardless of mtime ordering.
# Expected to FAIL until F-S8-008 fix.
# ---------------------------------------------------------------------------

case_dmg_selection_deterministic() {
    local tmp; tmp="$(mk_tmp bb-mkapc-1)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"

    # Create both DMGs. 0.3.0 is OLDER mtime, 0.2.0 is NEWER mtime.
    # If selection is by version (correct), 0.3.0 wins.
    # If selection is by mtime (current bug), 0.2.0 wins.
    printf 'fake dmg 0.3.0\n' > "$tmp/dist/Blackbird-0.3.0.dmg"
    sleep 1   # ensure mtime ordering is observable on filesystems with second resolution
    printf 'fake dmg 0.2.0\n' > "$tmp/dist/Blackbird-0.2.0.dmg"

    local log; log="$(mktemp)"
    local rc; rc="$(run_make_appcast "$tmp" "$log")"
    assert_eq "$rc" "0" "make-appcast.sh exits 0 with two DMGs present"

    # The XML output should reference the picked DMG via the
    # <enclosure url="..."> line. Inspect.
    local picked
    picked="$(grep -oE 'Blackbird-[0-9.]+\.dmg' "$log" | head -1 || true)"
    if [[ -z "$picked" ]]; then
        fail "make-appcast didn't reference any DMG in its output"
        head -30 "$log" | sed 's/^/      | /' >&2
        rm -f "$log"
        return
    fi
    echo "    info: make-appcast picked $picked"

    # Per F-S8-008, the deterministic rule should pick the
    # version-newest DMG. Today's mtime-based rule will pick 0.2.0.
    if [[ "$picked" == "Blackbird-0.3.0.dmg" ]]; then
        pass "F-S8-008: version-newest DMG selected (deterministic by version)"
    elif [[ "$picked" == "Blackbird-0.2.0.dmg" ]]; then
        fail "F-S8-008: mtime-newest DMG selected — should be by version (regression-guard)"
    else
        fail "F-S8-008: unexpected DMG name '$picked' picked by make-appcast"
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 2 — APPCAST_BASE_URL missing → must abort with non-zero. This
# is the existing contract pinning.
# ---------------------------------------------------------------------------

case_missing_base_url() {
    local tmp; tmp="$(mk_tmp bb-mkapc-2)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    printf 'fake\n' > "$tmp/dist/Blackbird-0.2.0.dmg"

    local log; log="$(mktemp)"
    local rc=0
    (
        cd "$tmp"
        export PATH="$tmp/stub-bin:$PATH"
        unset APPCAST_BASE_URL
        export SIGN_UPDATE="$tmp/stub-bin/sign_update"
        bash "$tmp/scripts/make-appcast.sh"
    ) >"$log" 2>&1 || rc=$?

    if [[ "$rc" != "0" ]]; then
        pass "make-appcast.sh refuses to run without APPCAST_BASE_URL (rc=$rc)"
    else
        fail "make-appcast.sh ran without APPCAST_BASE_URL (rc=0)"
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 3 — No DMGs in dist/ → abort with clear error.
# ---------------------------------------------------------------------------

case_no_dmgs() {
    local tmp; tmp="$(mk_tmp bb-mkapc-3)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    # dist/ is empty.

    local log; log="$(mktemp)"
    local rc; rc="$(run_make_appcast "$tmp" "$log")"
    if [[ "$rc" != "0" ]]; then
        pass "make-appcast.sh aborts when dist/ has no DMGs (rc=$rc)"
    else
        fail "make-appcast.sh exited 0 with empty dist/"
    fi
    if grep -q "No DMG found" "$log"; then
        pass "operator gets a clear 'No DMG found' message"
    else
        fail "missing diagnostic message for no-DMG case"
        cat "$log" | sed 's/^/      | /' >&2
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 4 — Output is well-formed XML when --full is passed.
# ---------------------------------------------------------------------------

case_full_xml_wellformed() {
    local tmp; tmp="$(mk_tmp bb-mkapc-4)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    printf 'fake\n' > "$tmp/dist/Blackbird-0.2.0.dmg"

    local log; log="$(mktemp)"
    local rc=0
    (
        cd "$tmp"
        export PATH="$tmp/stub-bin:$PATH"
        export APPCAST_BASE_URL="https://example.test/blackbird"
        export APPCAST_FEED_URL="https://example.test/appcast.xml"
        export SIGN_UPDATE="$tmp/stub-bin/sign_update"
        bash "$tmp/scripts/make-appcast.sh" --full
    ) >"$log" 2>&1 || rc=$?
    assert_eq "$rc" "0" "make-appcast.sh --full exits 0"

    # Validate that stdout was a complete RSS document.
    if python3 -c "import xml.etree.ElementTree as E; E.parse('$log')" 2>/dev/null; then
        pass "make-appcast.sh --full emits well-formed XML"
    else
        fail "make-appcast.sh --full emitted malformed XML"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 5 — C1 (semver inversion). `sort -V` orders "0.2.0-rc.1" AFTER
# "0.2.0" — opposite of semver §11. The selector must NOT pick the
# prerelease DMG when a same-MAJOR.MINOR.PATCH GA DMG also sits in dist/.
# Regression-guard for the prerelease-shadows-release bug.
# ---------------------------------------------------------------------------
case_dmg_selection_semver_prerelease() {
    local tmp; tmp="$(mk_tmp bb-mkapc-5)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"

    printf 'fake dmg 0.2.0\n' > "$tmp/dist/Blackbird-0.2.0.dmg"
    printf 'fake dmg 0.2.0-rc.1\n' > "$tmp/dist/Blackbird-0.2.0-rc.1.dmg"

    local log; log="$(mktemp)"
    local rc; rc="$(run_make_appcast "$tmp" "$log")"
    assert_eq "$rc" "0" "make-appcast.sh exits 0 with GA + prerelease DMGs"

    local picked
    picked="$(grep -oE 'Blackbird-[0-9A-Za-z.-]+\.dmg' "$log" | head -1 || true)"
    if [[ "$picked" == "Blackbird-0.2.0.dmg" ]]; then
        pass "C1: GA DMG selected over same-version prerelease (sort -V semver inversion)"
    elif [[ "$picked" == "Blackbird-0.2.0-rc.1.dmg" ]]; then
        fail "C1: prerelease DMG shadowed the GA — sort -V picked '0.2.0-rc.1' over '0.2.0'"
    else
        fail "C1: unexpected DMG selection '$picked'"
        head -20 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

case_dmg_selection_deterministic
case_missing_base_url
case_no_dmgs
case_full_xml_wellformed
case_dmg_selection_semver_prerelease

test_end
