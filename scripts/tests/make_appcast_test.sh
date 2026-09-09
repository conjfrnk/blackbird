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
# Parse args looking for `attach`, the attached DMG path, and
# `-mountpoint <path>`. The fabricated Info.plist mirrors the real
# contract: CFBundleShortVersionString matches the version in the
# attached DMG's filename (make-appcast.sh cross-checks it — a content
# mismatch is a refusal path tested separately).
mode=""; mp=""; dmg=""; prev=""
for arg in "$@"; do
    case "$arg" in
        attach|detach) mode="$arg" ;;
        *.dmg) dmg="$arg" ;;
    esac
    if [[ "$prev" == "-mountpoint" ]]; then mp="$arg"; fi
    prev="$arg"
done
if [[ "$mode" == "attach" && -n "$mp" ]]; then
    short="$(basename "$dmg" | sed -E 's/^Blackbird-(.*)\.dmg$/\1/')"
    mkdir -p "$mp/Blackbird.app/Contents"
    cat >"$mp/Blackbird.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleVersion</key>
    <string>42</string>
    <key>CFBundleShortVersionString</key>
    <string>${short}</string>
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
        # Hermetic environment: an APPCAST_DMG leaked from the operator's
        # shell would silently flip these auto-pick cases onto the
        # explicit-pin branch (pass-for-wrong-reason hazard).
        unset APPCAST_DMG
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
        unset APPCAST_DMG
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

    # Streams are separated deliberately: the script's contract is
    # XML on stdout, operator diagnostics (the "==> Appcast DMG:"
    # selection breadcrumb) on stderr. publish-update.sh relies on
    # exactly this when it redirects stdout into the staged appcast.
    local log errlog; log="$(mktemp)"; errlog="$(mktemp)"
    local rc=0
    (
        cd "$tmp"
        unset APPCAST_DMG
        export PATH="$tmp/stub-bin:$PATH"
        export APPCAST_BASE_URL="https://example.test/blackbird"
        export APPCAST_FEED_URL="https://example.test/appcast.xml"
        export SIGN_UPDATE="$tmp/stub-bin/sign_update"
        bash "$tmp/scripts/make-appcast.sh" --full
    ) >"$log" 2>"$errlog" || rc=$?
    assert_eq "$rc" "0" "make-appcast.sh --full exits 0"

    # Validate that stdout was a complete RSS document.
    if python3 -c "import xml.etree.ElementTree as E; E.parse('$log')" 2>/dev/null; then
        pass "make-appcast.sh --full emits well-formed XML on stdout"
    else
        fail "make-appcast.sh --full emitted malformed XML on stdout"
        head -30 "$log" | sed 's/^/      | /' >&2
        head -5 "$errlog" | sed 's/^/      | stderr: /' >&2
    fi
    rm -f "$log" "$errlog"
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

# ---------------------------------------------------------------------------
# CASE 6 — APPCAST_BASE_URL with XML-metacharacter must be rejected.
# Audit S4-013: an operator running with a hostile env value
# `APPCAST_BASE_URL='https://x" garbage="'` previously got an
# unescaped attribute injection into the emitted <enclosure>. The fix
# is to validate every URL input against a safe-charset regex at
# intake and abort with a clear error.
# ---------------------------------------------------------------------------
case_rejects_xml_metachar_in_base_url() {
    local tmp; tmp="$(mk_tmp bb-mkapc-6)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    printf 'fake\n' > "$tmp/dist/Blackbird-0.2.0.dmg"

    local log; log="$(mktemp)"
    local rc=0
    (
        cd "$tmp"
        unset APPCAST_DMG
        export PATH="$tmp/stub-bin:$PATH"
        # Hostile value: closing-quote that would terminate the
        # <enclosure url="..."> attribute mid-stream.
        export APPCAST_BASE_URL='https://x" garbage="'
        export SIGN_UPDATE="$tmp/stub-bin/sign_update"
        bash "$tmp/scripts/make-appcast.sh"
    ) >"$log" 2>&1 || rc=$?

    if [[ "$rc" != "0" ]]; then
        pass "S4-013: make-appcast.sh refuses XML-unsafe APPCAST_BASE_URL (rc=$rc)"
    else
        fail "S4-013: hostile APPCAST_BASE_URL accepted — XML injection surface"
        head -20 "$log" | sed 's/^/      | /' >&2
    fi
    if grep -q "unsafe for XML" "$log"; then
        pass "S4-013: operator gets a clear diagnostic"
    else
        fail "S4-013: missing diagnostic message"
        head -20 "$log" | sed 's/^/      | /' >&2
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# Helper for the APPCAST_DMG cases — run make-appcast.sh with an explicit
# APPCAST_DMG env value (plus --full when asked) and echo the exit code.
# ---------------------------------------------------------------------------
run_make_appcast_dmg() {
    local fixture="$1" dmg="$2" log="$3"; shift 3
    local rc=0
    (
        cd "$fixture"
        export PATH="$fixture/stub-bin:$PATH"
        export APPCAST_BASE_URL="https://example.test/blackbird"
        export APPCAST_FEED_URL="https://example.test/appcast.xml"
        export SIGN_UPDATE="$fixture/stub-bin/sign_update"
        export APPCAST_DMG="$dmg"
        bash "$fixture/scripts/make-appcast.sh" "$@"
    ) >"$log" 2>&1 || rc=$?
    echo "$rc"
}

# Extract the basename of the DMG referenced by the first .dmg-bearing
# url="..." attribute (the <enclosure url="...">) in the given log.
enclosure_dmg_basename() {
    local log="$1"
    local url
    url="$(grep -oE 'url="[^"]*\.dmg"' "$log" | head -1 \
        | sed -E 's/^url="//; s/"$//')"
    [[ -n "$url" ]] && basename "$url"
}

# ---------------------------------------------------------------------------
# CASE 7 — A1: APPCAST_DMG pins the EXACT DMG to publish. Even with a
# higher-GA-version DMG sitting in dist/, the enclosure must reference
# the pinned DMG's basename. Exit 0.
# ---------------------------------------------------------------------------
case_appcast_dmg_pins_exact_dmg() {
    local tmp; tmp="$(mk_tmp bb-mkapc-7)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    printf 'fake dmg 0.4.0-rc.1\n' > "$tmp/dist/Blackbird-0.4.0-rc.1.dmg"
    printf 'fake dmg 0.5.0\n' > "$tmp/dist/Blackbird-0.5.0.dmg"

    local log; log="$(mktemp)"
    local rc
    rc="$(run_make_appcast_dmg "$tmp" \
        "$tmp/dist/Blackbird-0.4.0-rc.1.dmg" "$log" --full)"
    assert_eq "$rc" "0" "A1: make-appcast.sh exits 0 with APPCAST_DMG set"

    local picked
    picked="$(enclosure_dmg_basename "$log" || true)"
    if [[ -z "$picked" ]]; then
        fail "A1: no .dmg-bearing enclosure url found in output"
        head -30 "$log" | sed 's/^/      | /' >&2
    else
        assert_eq "$picked" "Blackbird-0.4.0-rc.1.dmg" \
            "A1: enclosure basename equals APPCAST_DMG basename despite higher-GA DMG in dist/"
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 8 — A2: a prerelease-named APPCAST_DMG generates successfully and
# the feed carries the prerelease as the shortVersionString.
# ---------------------------------------------------------------------------
case_appcast_dmg_prerelease_short_version() {
    local tmp; tmp="$(mk_tmp bb-mkapc-8)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    printf 'fake dmg 0.4.0-rc.1\n' > "$tmp/dist/Blackbird-0.4.0-rc.1.dmg"

    local log; log="$(mktemp)"
    local rc
    rc="$(run_make_appcast_dmg "$tmp" \
        "$tmp/dist/Blackbird-0.4.0-rc.1.dmg" "$log" --full)"
    assert_eq "$rc" "0" "A2: prerelease APPCAST_DMG generates (exit 0)"

    if grep -q "<sparkle:shortVersionString>0.4.0-rc.1</sparkle:shortVersionString>" "$log"; then
        pass "A2: feed carries shortVersionString 0.4.0-rc.1"
    else
        fail "A2: <sparkle:shortVersionString>0.4.0-rc.1</sparkle:shortVersionString> missing from output"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 9 — A3: APPCAST_DMG pointing at a nonexistent path must abort
# with a diagnostic that mentions APPCAST_DMG.
# ---------------------------------------------------------------------------
case_appcast_dmg_nonexistent_path() {
    local tmp; tmp="$(mk_tmp bb-mkapc-9)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    # dist/ has a perfectly good DMG — the script must NOT fall back to
    # it when the operator explicitly pinned a (bad) path.
    printf 'fake dmg 0.3.0\n' > "$tmp/dist/Blackbird-0.3.0.dmg"

    local log; log="$(mktemp)"
    local rc
    rc="$(run_make_appcast_dmg "$tmp" \
        "$tmp/dist/Blackbird-9.9.9.dmg" "$log")"
    if [[ "$rc" != "0" ]]; then
        pass "A3: nonexistent APPCAST_DMG aborts (rc=$rc)"
    else
        fail "A3: make-appcast.sh exited 0 with nonexistent APPCAST_DMG"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    if grep -q "APPCAST_DMG" "$log"; then
        pass "A3: diagnostic mentions APPCAST_DMG"
    else
        fail "A3: diagnostic does not mention APPCAST_DMG"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 10 — A4: APPCAST_DMG whose basename is not Blackbird-<semver>.dmg
# must abort even though the file exists.
# ---------------------------------------------------------------------------
case_appcast_dmg_bad_basename() {
    local tmp; tmp="$(mk_tmp bb-mkapc-10)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    printf 'fake dmg nightly\n' > "$tmp/dist/Blackbird-nightly.dmg"

    local log; log="$(mktemp)"
    local rc
    rc="$(run_make_appcast_dmg "$tmp" \
        "$tmp/dist/Blackbird-nightly.dmg" "$log")"
    if [[ "$rc" != "0" ]]; then
        pass "A4: non-semver APPCAST_DMG basename rejected (rc=$rc)"
    else
        fail "A4: make-appcast.sh accepted APPCAST_DMG with non-semver basename"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 11 — A5: without APPCAST_DMG the auto-pick behavior is unchanged:
# highest GA version wins and prerelease-named DMGs are NOT auto-picked,
# even when the prerelease carries a higher base version.
# ---------------------------------------------------------------------------
case_autopick_skips_prerelease() {
    local tmp; tmp="$(mk_tmp bb-mkapc-11)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    printf 'fake dmg 0.3.0\n' > "$tmp/dist/Blackbird-0.3.0.dmg"
    printf 'fake dmg 0.4.0-rc.1\n' > "$tmp/dist/Blackbird-0.4.0-rc.1.dmg"

    local log; log="$(mktemp)"
    local rc=0
    (
        cd "$tmp"
        unset APPCAST_DMG
        export PATH="$tmp/stub-bin:$PATH"
        export APPCAST_BASE_URL="https://example.test/blackbird"
        export APPCAST_FEED_URL="https://example.test/appcast.xml"
        export SIGN_UPDATE="$tmp/stub-bin/sign_update"
        unset APPCAST_DMG
        bash "$tmp/scripts/make-appcast.sh" --full
    ) >"$log" 2>&1 || rc=$?
    assert_eq "$rc" "0" "A5: auto-pick exits 0 with GA + higher prerelease in dist/"

    local picked
    picked="$(enclosure_dmg_basename "$log" || true)"
    if [[ "$picked" == "Blackbird-0.3.0.dmg" ]]; then
        pass "A5: auto-pick selects highest GA DMG, not the higher-versioned prerelease"
    else
        fail "A5: auto-pick selected '$picked' — expected GA Blackbird-0.3.0.dmg"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# Helper for the release-notes cases — run make-appcast.sh --full with
# APPCAST_RELEASE_NOTES_URL controlled explicitly. "$notes_mode" is one
# of: set (export the given URL), empty (export ""), unset (remove the
# variable). stdout goes to $log, stderr to $errlog, exit code echoed.
# The operator's own shell value is never inherited: every mode starts
# from a clean slate so the "no element" cases can't pass because the
# variable happened to be absent in the outer environment.
# ---------------------------------------------------------------------------
run_make_appcast_notes() {
    local fixture="$1" notes_mode="$2" notes_url="$3" log="$4" errlog="$5"
    local rc=0
    (
        cd "$fixture"
        unset APPCAST_DMG
        unset APPCAST_RELEASE_NOTES_URL
        export PATH="$fixture/stub-bin:$PATH"
        export APPCAST_BASE_URL="https://example.test/blackbird"
        export APPCAST_FEED_URL="https://example.test/appcast.xml"
        export SIGN_UPDATE="$fixture/stub-bin/sign_update"
        case "$notes_mode" in
            set)   export APPCAST_RELEASE_NOTES_URL="$notes_url" ;;
            empty) export APPCAST_RELEASE_NOTES_URL="" ;;
            unset) ;;
        esac
        bash "$fixture/scripts/make-appcast.sh" --full
    ) >"$log" 2>"$errlog" || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# CASE 12 — APPCAST_RELEASE_NOTES_URL set → the <item> carries
# <sparkle:releaseNotesLink>URL</sparkle:releaseNotesLink>, placed inside
# the item and BEFORE the <enclosure> element (Sparkle reads the link
# from the item body; publish-update.sh points it at the rendered
# website/releases/vX.Y.Z.html page). The full document must still be
# well-formed XML.
# ---------------------------------------------------------------------------
case_release_notes_link_emitted() {
    local tmp; tmp="$(mk_tmp bb-mkapc-12)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    printf 'fake dmg 0.2.0\n' > "$tmp/dist/Blackbird-0.2.0.dmg"

    local notes_url="https://example.test/releases/v0.2.0.html"
    local log errlog; log="$(mktemp)"; errlog="$(mktemp)"
    local rc
    rc="$(run_make_appcast_notes "$tmp" set "$notes_url" "$log" "$errlog")"
    assert_eq "$rc" "0" "releaseNotesLink: make-appcast.sh --full exits 0 with APPCAST_RELEASE_NOTES_URL set"

    local expected="<sparkle:releaseNotesLink>${notes_url}</sparkle:releaseNotesLink>"
    if grep -qF "$expected" "$log"; then
        pass "releaseNotesLink: exact element emitted with the configured URL"
    else
        fail "releaseNotesLink: '$expected' missing from stdout"
        head -40 "$log" | sed 's/^/      | /' >&2
        head -5 "$errlog" | sed 's/^/      | stderr: /' >&2
    fi

    # Ordering: <item> ... <sparkle:releaseNotesLink> ... <enclosure.
    # Compare line numbers of the first occurrence of each.
    local item_line notes_line encl_line
    item_line="$(grep -n '<item>' "$log" | head -1 | cut -d: -f1 || true)"
    notes_line="$(grep -nF 'releaseNotesLink' "$log" | head -1 | cut -d: -f1 || true)"
    encl_line="$(grep -n '<enclosure' "$log" | head -1 | cut -d: -f1 || true)"
    if [[ -n "$item_line" && -n "$notes_line" && -n "$encl_line" ]] \
        && (( item_line < notes_line )) && (( notes_line < encl_line )); then
        pass "releaseNotesLink: sits inside <item> and before <enclosure> (lines $item_line < $notes_line < $encl_line)"
    else
        fail "releaseNotesLink: ordering wrong — item=$item_line notes=$notes_line enclosure=$encl_line"
        head -40 "$log" | sed 's/^/      | /' >&2
    fi

    # Exactly one link element — a duplicate would be a template bug.
    local count
    count="$(grep -c 'releaseNotesLink' "$log" || true)"
    # Opening + closing tag live on the same line, so one line == one element.
    assert_eq "$count" "1" "releaseNotesLink: emitted exactly once"

    if python3 -c "import xml.etree.ElementTree as E; E.parse('$log')" 2>/dev/null; then
        pass "releaseNotesLink: document still well-formed XML"
    else
        fail "releaseNotesLink: emitted document is malformed XML"
        head -40 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log" "$errlog"
}

# ---------------------------------------------------------------------------
# CASE 13 — APPCAST_RELEASE_NOTES_URL unset or empty → no
# releaseNotesLink element at all. An empty <sparkle:releaseNotesLink/>
# would make Sparkle fetch "" and show a broken notes pane, so both the
# unset and the empty-string forms must suppress the element entirely.
# ---------------------------------------------------------------------------
case_release_notes_link_omitted() {
    local tmp; tmp="$(mk_tmp bb-mkapc-13)"
    trap "rm -rf '$tmp'" RETURN

    mk_appcast_fixture "$tmp"
    printf 'fake dmg 0.2.0\n' > "$tmp/dist/Blackbird-0.2.0.dmg"

    local mode
    for mode in unset empty; do
        local log errlog; log="$(mktemp)"; errlog="$(mktemp)"
        local rc
        rc="$(run_make_appcast_notes "$tmp" "$mode" "" "$log" "$errlog")"
        assert_eq "$rc" "0" "releaseNotesLink ($mode): make-appcast.sh --full exits 0"

        if grep -q 'releaseNotesLink' "$log"; then
            fail "releaseNotesLink ($mode): element emitted despite no URL"
            grep -n 'releaseNotesLink' "$log" | sed 's/^/      | /' >&2
        else
            pass "releaseNotesLink ($mode): no releaseNotesLink element emitted"
        fi

        # The item itself must still be intact — suppressing the link
        # must not swallow the enclosure.
        if grep -q '<enclosure' "$log"; then
            pass "releaseNotesLink ($mode): <enclosure> still present"
        else
            fail "releaseNotesLink ($mode): <enclosure> missing from output"
            head -40 "$log" | sed 's/^/      | /' >&2
        fi
        rm -f "$log" "$errlog"
    done
}

case_dmg_selection_deterministic
case_missing_base_url
case_no_dmgs
case_full_xml_wellformed
case_dmg_selection_semver_prerelease
case_rejects_xml_metachar_in_base_url
case_appcast_dmg_pins_exact_dmg
case_appcast_dmg_prerelease_short_version
case_appcast_dmg_nonexistent_path
case_appcast_dmg_bad_basename
case_autopick_skips_prerelease
case_release_notes_link_emitted
case_release_notes_link_omitted

test_end
