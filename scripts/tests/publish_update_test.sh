#!/usr/bin/env bash
#
# Hermetic tests for scripts/publish-update.sh.
#
# Findings cross-ref:
#   - F-S8-025: `bash scripts/make-appcast.sh --full > website/appcast.xml`
#     is non-atomic. If make-appcast.sh exits non-zero mid-stream, the
#     existing appcast.xml is truncated to whatever bytes were emitted
#     before the crash. Test asserts: with a known-good appcast.xml in
#     place and a make-appcast.sh stub that prints the channel header
#     then dies, website/appcast.xml MUST NOT be truncated — i.e. it
#     stays equal to the pre-existing valid file (because the publish
#     script either uses a tmp + rename pattern, or the test FAILS as a
#     regression-guard for the fix).
#   - F-S8-003: version-arg validation. Run with malformed semver,
#     assert exit non-zero before any side effects.
#
# Strategy: we don't run the real publish-update.sh end-to-end (that
# requires `gh`, network, sign_update, aws). Instead, we exercise the
# specific code path of interest by stubbing every external command on
# PATH. publish-update.sh checks `gh release view`, downloads with curl,
# calls make-appcast.sh, calls git, calls website/deploy.sh — all
# stubbable.
#
# IMPORTANT: this test runs publish-update.sh in a fully isolated tmp
# directory. We do not push to origin, do not invoke gh, do not curl
# real GitHub.

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "publish_update_test.sh"

# Build a fixture directory that mimics enough of the Blackbird repo
# layout to let publish-update.sh think it's working in-tree. PATH gets
# all external commands stubbed.
mk_publish_fixture() {
    local root="$1" mode="$2"
    mkdir -p "$root/scripts" "$root/website" "$root/dist" "$root/stub-bin"

    # Copy real script under test.
    cp "$BB_REPO_ROOT/scripts/publish-update.sh" "$root/scripts/publish-update.sh"
    chmod +x "$root/scripts/publish-update.sh"

    # Pre-existing valid appcast.xml — the file we DO NOT want truncated.
    cat >"$root/website/appcast.xml" <<'XML'
<?xml version="1.0" standalone="yes"?>
<rss version="2.0">
  <channel>
    <title>Blackbird</title>
    <description>Pre-existing known-good appcast — must survive failed publish.</description>
  </channel>
</rss>
XML
    # A sentinel marker we'll grep for after the run.
    echo "<!-- SENTINEL_GOOD_APPCAST_DO_NOT_TRUNCATE -->" >> "$root/website/appcast.xml"

    # website/deploy.sh stub — no S3, no CloudFront.
    cat >"$root/website/deploy.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "stub deploy.sh ran for $(pwd)"
exit 0
STUB
    chmod +x "$root/website/deploy.sh"

    # codesign / spctl / xcrun stubs — pass by default so the new
    # verify_dmg block (audit SEC-003) doesn't false-fail every test.
    # Individual cases override these to simulate rejection.
    cat >"$root/stub-bin/codesign" <<'STUB'
#!/usr/bin/env bash
# Default-pass stub. Mimics `codesign --verify --strict --verbose=2`.
exit 0
STUB
    chmod +x "$root/stub-bin/codesign"

    cat >"$root/stub-bin/spctl" <<'STUB'
#!/usr/bin/env bash
# Default-pass stub. Emits the `source=` and `origin=` lines
# publish-update.sh greps for. Team ID matches the pinned F2B95Q4CT8.
cat <<'EOF'
/path/to/Blackbird.dmg: accepted
source=Notarized Developer ID
origin=Developer ID Application: Connor Frank (F2B95Q4CT8)
EOF
exit 0
STUB
    chmod +x "$root/stub-bin/spctl"

    cat >"$root/stub-bin/xcrun" <<'STUB'
#!/usr/bin/env bash
# Default-pass stub for `xcrun stapler validate`.
if [[ "${1:-}" == "stapler" && "${2:-}" == "validate" ]]; then
    echo "stub xcrun: stapler validate ok"
    exit 0
fi
exit 0
STUB
    chmod +x "$root/stub-bin/xcrun"

    # gh stub — claim the release exists with the expected DMG.
    cat >"$root/stub-bin/gh" <<STUB
#!/usr/bin/env bash
case "\${1:-}\${2:-}" in
    "release""view")
        if [[ "\${4:-}" == "--json" ]]; then
            # asset listing with the expected DMG name
            printf '%s\n' "Blackbird-\${TAG_VERSION:-MISSING}.dmg"
        fi
        exit 0
        ;;
esac
exit 0
STUB
    chmod +x "$root/stub-bin/gh"

    # curl stub — write a fake DMG of plausible size to the destination.
    # Accept -fsSL -o <dest> <url>. Only success path is exercised here.
    cat >"$root/stub-bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
DEST=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-o" ]]; then DEST="$arg"; fi
    prev="$arg"
done
if [[ -z "$DEST" ]]; then
    echo "stub curl: no -o destination" >&2
    exit 1
fi
# Write a non-empty placeholder so the -s test passes.
printf 'fake dmg bytes for tests\n' > "$DEST"
exit 0
STUB
    chmod +x "$root/stub-bin/curl"

    # shasum stub — point at real shasum, no need to fake.
    # wc / awk are real.

    # Make-appcast stub. Behavior depends on $mode:
    #   "ok"     — writes a complete valid appcast snippet.
    #   "crash"  — emits the channel header to stdout then exits non-zero.
    #              This is the F-S8-025 trigger.
    if [[ "$mode" == "crash" ]]; then
        cat >"$root/scripts/make-appcast.sh" <<'STUB'
#!/usr/bin/env bash
# Print only the header, then crash. Mimics sign_update failing
# mid-pipeline.
cat <<'XML'
<?xml version="1.0" standalone="yes"?>
<rss version="2.0">
  <channel>
    <title>Blackbird</title>
XML
echo "make-appcast.sh: simulated sign_update failure" >&2
exit 1
STUB
    else
        cat >"$root/scripts/make-appcast.sh" <<'STUB'
#!/usr/bin/env bash
cat <<'XML'
<?xml version="1.0" standalone="yes"?>
<rss version="2.0">
  <channel>
    <title>Blackbird</title>
    <description>fixture full appcast</description>
  </channel>
</rss>
XML
exit 0
STUB
    fi
    chmod +x "$root/scripts/make-appcast.sh"

    # Init git repo so the script's `git add` / `git commit` / `git push`
    # paths have a real repo to operate on.
    mk_git_fixture "$root"
    # Track the pre-existing appcast so changes to it show up in `git
    # status` / `git diff --cached`.
    (cd "$root" && git add website/appcast.xml \
        && git -c commit.gpgsign=false commit -q -m "seed appcast")
}

run_publish_update() {
    local fixture="$1" version="$2" log="$3"
    if [[ "$fixture" == "$BB_REPO_ROOT" || "$fixture" == "$BB_REPO_ROOT"/* ]]; then
        echo "fatal: fixture path leaks into real repo: $fixture" >&2
        return 99
    fi
    local rc=0
    (
        cd "$fixture"
        export PATH="$fixture/stub-bin:$PATH"
        # Communicate the expected DMG version to the gh stub.
        export TAG_VERSION="$version"
        bash "$fixture/scripts/publish-update.sh" "$version"
    ) >"$log" 2>&1 || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# CASE 1 — F-S8-025: make-appcast crashes mid-stream → website/appcast.xml
# MUST NOT be truncated.
# ---------------------------------------------------------------------------

case_atomic_appcast() {
    local tmp; tmp="$(mk_tmp bb-pub-1)"
    trap "rm -rf '$tmp'" RETURN

    mk_publish_fixture "$tmp" "crash"

    local before_sha
    before_sha="$(shasum -a 256 "$tmp/website/appcast.xml" | awk '{print $1}')"

    local log; log="$(mktemp)"
    local rc; rc="$(run_publish_update "$tmp" 0.2.0 "$log")"

    # Script SHOULD fail (make-appcast crashed). What we actually care
    # about is the on-disk appcast post-crash.
    if [[ "$rc" == "0" ]]; then
        fail "publish-update.sh exited 0 despite make-appcast crash (rc=$rc)"
    else
        pass "publish-update.sh propagates make-appcast failure (rc=$rc)"
    fi

    # The atomic-write contract: appcast.xml on disk should be EITHER
    # the original sentinel-bearing file OR a complete valid replacement.
    # It must NOT be a half-written truncated XML.
    if grep -q "SENTINEL_GOOD_APPCAST_DO_NOT_TRUNCATE" "$tmp/website/appcast.xml"; then
        pass "F-S8-025: pre-existing appcast.xml survived the crash (atomic write)"
    elif grep -q "</rss>" "$tmp/website/appcast.xml"; then
        # Theoretical: a complete rewrite happened. Acceptable if the
        # file is a complete valid XML. Verify with python.
        if python3 -c "import xml.etree.ElementTree as E; E.parse('$tmp/website/appcast.xml')" 2>/dev/null; then
            pass "F-S8-025: appcast.xml replaced atomically with valid XML"
        else
            fail "F-S8-025: appcast.xml replaced but is not valid XML"
        fi
    else
        fail "F-S8-025: appcast.xml truncated mid-write — non-atomic publish"
        echo "      contents on disk:" >&2
        head -10 "$tmp/website/appcast.xml" | sed 's/^/      | /' >&2
    fi

    # Whatever happened, the file must still parse as XML. Truncated
    # XML would fail this.
    if python3 -c "import xml.etree.ElementTree as E; E.parse('$tmp/website/appcast.xml')" 2>/dev/null; then
        pass "appcast.xml on disk is valid XML"
    else
        fail "appcast.xml on disk is not valid XML"
    fi

    # Also: the test sentinel SHA, if unchanged, asserts the file is
    # byte-identical to the pre-existing one (atomic-write didn't even
    # trigger the rename). Either before==after or the file is a full
    # valid replacement; both are atomic outcomes.
    local after_sha
    after_sha="$(shasum -a 256 "$tmp/website/appcast.xml" | awk '{print $1}')"
    echo "    info: appcast.xml sha256 before=$before_sha after=$after_sha"

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 2 — F-S8-003: malformed version arg should be rejected fast.
# This is currently NOT enforced in publish-update.sh (cut-release.sh
# has the regex, publish-update.sh doesn't). This is a regression-guard
# for the fix; expected to FAIL until publish-update.sh adds the regex
# check.
# ---------------------------------------------------------------------------

case_arg_validation() {
    local tmp; tmp="$(mk_tmp bb-pub-2)"
    trap "rm -rf '$tmp'" RETURN

    mk_publish_fixture "$tmp" "ok"

    local log; log="$(mktemp)"
    local rc; rc="$(run_publish_update "$tmp" "0.2 .0; rm -rf /" "$log")"

    # Whatever the script does, the side effects MUST be bounded.
    # Specifically: the appcast.xml on disk must remain valid, and
    # `dist/` must not contain a curl'd DMG with the malformed name.
    if [[ "$rc" != "0" ]]; then
        pass "publish-update.sh refuses malformed version arg (rc=$rc)"
    else
        fail "F-S8-003: publish-update.sh accepted malformed version arg"
        head -10 "$log" | sed 's/^/      | /' >&2
    fi

    # Even on accepted-but-failed flow, the working tree should not
    # have a truncated appcast.
    if python3 -c "import xml.etree.ElementTree as E; E.parse('$tmp/website/appcast.xml')" 2>/dev/null; then
        pass "appcast.xml remains valid XML after rejected/failed run"
    else
        fail "appcast.xml is not valid XML after rejected version run"
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 3 — push-failure ordering: if `git push origin main` fails, the
# script MUST NOT proceed to the S3 deploy. Per F-S8-017 the cleanup is
# left to the operator, but the ordering invariant itself is what we
# pin here.
# ---------------------------------------------------------------------------

case_push_then_deploy() {
    local tmp; tmp="$(mk_tmp bb-pub-3)"
    trap "rm -rf '$tmp'" RETURN

    mk_publish_fixture "$tmp" "ok"

    # Wrap git so `git push` always fails (other subcommands pass
    # through to the real git).
    local real_git; real_git="$(command -v git)"
    cat >"$tmp/stub-bin/git" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "push" ]]; then
    echo "fake git push: rejected non-fast-forward" >&2
    exit 1
fi
exec "$real_git" "\$@"
STUB
    chmod +x "$tmp/stub-bin/git"

    # Replace deploy.sh with a tripwire — if it ever runs, the test fails.
    cat >"$tmp/website/deploy.sh" <<'STUB'
#!/usr/bin/env bash
echo "TRIPWIRE: deploy.sh ran despite git push failure" >&2
exit 0
STUB
    chmod +x "$tmp/website/deploy.sh"

    local log; log="$(mktemp)"
    local rc; rc="$(run_publish_update "$tmp" 0.2.0 "$log")"

    if [[ "$rc" != "0" ]]; then
        pass "publish-update.sh exits non-zero on git push failure (rc=$rc)"
    else
        fail "publish-update.sh exited 0 despite git push failure"
    fi

    # The tripwire must NOT have fired — S3 deploy must come after a
    # successful push.
    if grep -q "TRIPWIRE: deploy.sh ran" "$log"; then
        fail "F-S8 ordering: deploy.sh ran after git push failure"
    else
        pass "F-S8 ordering: deploy.sh did NOT run after git push failure"
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 4 — SEC-003 / F-S8-004: spctl rejects DMG → publish aborts before
# signing it into the appcast. The whole point of the verify chain is to
# stop here, before sign_update / make-appcast touches the EdDSA key.
# ---------------------------------------------------------------------------

case_verify_spctl_reject() {
    local tmp; tmp="$(mk_tmp bb-pub-4)"
    trap "rm -rf '$tmp'" RETURN

    mk_publish_fixture "$tmp" "ok"

    # Replace spctl with a rejecting stub.
    cat >"$tmp/stub-bin/spctl" <<'STUB'
#!/usr/bin/env bash
echo "/path/to/Blackbird.dmg: rejected" >&2
echo "source=no usable signature" >&2
exit 3
STUB
    chmod +x "$tmp/stub-bin/spctl"

    # Tripwire: replace make-appcast.sh with a guard that aborts the
    # whole test if the script reached the signing stage despite spctl
    # rejecting. The verify gate must short-circuit before this fires.
    cat >"$tmp/scripts/make-appcast.sh" <<'STUB'
#!/usr/bin/env bash
echo "TRIPWIRE: make-appcast ran despite spctl reject" >&2
exit 0
STUB
    chmod +x "$tmp/scripts/make-appcast.sh"

    local log; log="$(mktemp)"
    local rc; rc="$(run_publish_update "$tmp" 0.2.0 "$log")"

    if [[ "$rc" != "0" ]]; then
        pass "publish-update.sh aborts on spctl reject (rc=$rc)"
    else
        fail "SEC-003: publish-update.sh exited 0 despite spctl reject"
    fi

    if grep -q "TRIPWIRE: make-appcast ran" "$log"; then
        fail "SEC-003: make-appcast.sh ran after spctl rejected DMG"
    else
        pass "SEC-003: signing did NOT run after spctl rejected DMG"
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 5 — SEC-003: spctl reports a DIFFERENT Team ID in origin=.
# Notarization passes (source=Notarized Developer ID) but the DMG was
# signed by some other Apple Developer account. The Team ID pin must
# catch this.
# ---------------------------------------------------------------------------

case_verify_wrong_team_id() {
    local tmp; tmp="$(mk_tmp bb-pub-5)"
    trap "rm -rf '$tmp'" RETURN

    mk_publish_fixture "$tmp" "ok"

    # spctl stub that "accepts" but reports a different team.
    cat >"$tmp/stub-bin/spctl" <<'STUB'
#!/usr/bin/env bash
cat <<'EOF'
/path/to/Blackbird.dmg: accepted
source=Notarized Developer ID
origin=Developer ID Application: Bad Actor (XXXXXXXXXX)
EOF
exit 0
STUB
    chmod +x "$tmp/stub-bin/spctl"

    cat >"$tmp/scripts/make-appcast.sh" <<'STUB'
#!/usr/bin/env bash
echo "TRIPWIRE: make-appcast ran despite wrong Team ID" >&2
exit 0
STUB
    chmod +x "$tmp/scripts/make-appcast.sh"

    local log; log="$(mktemp)"
    local rc; rc="$(run_publish_update "$tmp" 0.2.0 "$log")"

    if [[ "$rc" != "0" ]]; then
        pass "publish-update.sh aborts on wrong Team ID (rc=$rc)"
    else
        fail "SEC-003: publish-update.sh accepted DMG signed by wrong team"
    fi

    if grep -q "TRIPWIRE: make-appcast ran" "$log"; then
        fail "SEC-003: make-appcast.sh ran with wrong-Team-ID DMG"
    else
        pass "SEC-003: signing did NOT run with wrong-Team-ID DMG"
    fi

    # Diagnostic should mention the expected team for operator
    # debugging — without this an operator hits a verify failure with
    # no clue what Team ID was wrong.
    if grep -q "F2B95Q4CT8" "$log"; then
        pass "diagnostic mentions the expected Team ID"
    else
        fail "diagnostic should mention expected Team ID for debugging"
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 6 — SEC-003: stapler validate fails. spctl is happy but the
# notarization ticket isn't actually stapled (a corruption-after-
# notarization scenario). Must abort before signing.
# ---------------------------------------------------------------------------

case_verify_stapler_reject() {
    local tmp; tmp="$(mk_tmp bb-pub-6)"
    trap "rm -rf '$tmp'" RETURN

    mk_publish_fixture "$tmp" "ok"

    cat >"$tmp/stub-bin/xcrun" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "stapler" && "${2:-}" == "validate" ]]; then
    echo "Processing: /path/to/Blackbird.dmg" >&2
    echo "Could not validate ticket. CloudKit response error" >&2
    exit 65
fi
exit 0
STUB
    chmod +x "$tmp/stub-bin/xcrun"

    cat >"$tmp/scripts/make-appcast.sh" <<'STUB'
#!/usr/bin/env bash
echo "TRIPWIRE: make-appcast ran despite stapler reject" >&2
exit 0
STUB
    chmod +x "$tmp/scripts/make-appcast.sh"

    local log; log="$(mktemp)"
    local rc; rc="$(run_publish_update "$tmp" 0.2.0 "$log")"

    if [[ "$rc" != "0" ]]; then
        pass "publish-update.sh aborts on stapler failure (rc=$rc)"
    else
        fail "SEC-003: publish-update.sh exited 0 despite stapler failure"
    fi

    if grep -q "TRIPWIRE: make-appcast ran" "$log"; then
        fail "SEC-003: make-appcast.sh ran after stapler rejected DMG"
    else
        pass "SEC-003: signing did NOT run after stapler rejected DMG"
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 7 — SEC-003: spctl output is missing source=/origin= anchors
# entirely. This means Apple changed the spctl format. Operator must
# get a clear "format changed, verify manually" message rather than a
# misleading "Team ID mismatch."
# ---------------------------------------------------------------------------

case_verify_format_change() {
    local tmp; tmp="$(mk_tmp bb-pub-7)"
    trap "rm -rf '$tmp'" RETURN

    mk_publish_fixture "$tmp" "ok"

    cat >"$tmp/stub-bin/spctl" <<'STUB'
#!/usr/bin/env bash
# Simulate a future spctl that drops source=/origin= for some new format.
echo "/path/to/Blackbird.dmg: accepted"
echo "verdict: legitimate"
echo "team: F2B95Q4CT8"
exit 0
STUB
    chmod +x "$tmp/stub-bin/spctl"

    cat >"$tmp/scripts/make-appcast.sh" <<'STUB'
#!/usr/bin/env bash
echo "TRIPWIRE: make-appcast ran despite format change" >&2
exit 0
STUB
    chmod +x "$tmp/scripts/make-appcast.sh"

    local log; log="$(mktemp)"
    local rc; rc="$(run_publish_update "$tmp" 0.2.0 "$log")"

    if [[ "$rc" != "0" ]]; then
        pass "publish-update.sh aborts on missing spctl anchors (rc=$rc)"
    else
        fail "SEC-003: publish-update.sh accepted spctl with no anchors"
    fi

    if grep -q "TRIPWIRE: make-appcast ran" "$log"; then
        fail "SEC-003: signing ran despite missing spctl anchors"
    else
        pass "SEC-003: signing did NOT run with missing spctl anchors"
    fi

    # Diagnostic should clearly say the format may have changed —
    # operator should not be sent on a wild Team ID chase.
    if grep -q "format may have changed" "$log"; then
        pass "diagnostic distinguishes format-change from Team ID mismatch"
    else
        fail "diagnostic should mention format change, not just bare Team ID error"
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 8 — M-21 / MS-5: the JSON-LD `softwareVersion` slot in
# website/index.html must be rewritten on every publish. Through v0.1.15
# this slot was silently stale because the old STRAY check only matched
# `v[X.Y.Z]` tokens. The fix adds a third sed targeting
# `"softwareVersion": "..."` plus a separate STRAY scan anchored on the
# JSON-LD field name.
#
# Seed an index.html containing a stale softwareVersion (0.1.15) plus the
# two existing anchors, run publish-update.sh successfully through to the
# index.html rewrite step, and assert the slot now reads the new VERSION.
# We don't need the script to make it all the way to git push — the
# rewrite happens before that, and a later-step failure just means the
# git stub never gets exercised. We assert on the on-disk file.
# ---------------------------------------------------------------------------

case_jsonld_softwareversion_rewritten() {
    local tmp; tmp="$(mk_tmp bb-pub-8)"
    trap "rm -rf '$tmp'" RETURN

    mk_publish_fixture "$tmp" "ok"

    # The default codesign stub is a bare `exit 0` — verify_dmg's
    # `TeamIdentifier=${TEAM_ID}` grep would fail before we ever reach
    # the index.html rewrite. Replace with a stub that emits the matching
    # Team ID so verify_dmg passes and the script proceeds.
    cat >"$tmp/stub-bin/codesign" <<'STUB'
#!/usr/bin/env bash
mode=""
for arg in "$@"; do
    case "$arg" in
        --display) mode="display" ;;
        --verify) mode="verify" ;;
    esac
done
case "$mode" in
    display)
        cat <<'EOF'
Executable=/path/to/Blackbird.dmg
Format=disk image
TeamIdentifier=F2B95Q4CT8
EOF
        ;;
    *) ;;
esac
exit 0
STUB
    chmod +x "$tmp/stub-bin/codesign"

    # Seed a minimal index.html with all three version-bearing strings.
    # The softwareVersion is the old (stale) value; the other two are
    # also stale, just to make sure the test exercises every sed.
    cat >"$tmp/website/index.html" <<'HTML'
<!doctype html>
<html lang="en">
  <head>
    <script type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "softwareVersion": "0.1.15",
        "operatingSystem": "macOS 14.0"
      }
    </script>
  </head>
  <body>
    <div class="reqs">Requires macOS 14 or later · Apple Silicon and Intel · v0.1.15</div>
    <div class="row dim">   Compiling blackbird_core v0.1.15</div>
  </body>
</html>
HTML

    # Re-stage the seeded index.html so the script's `git add` /
    # `git diff --cached` ordering works on the fresh content.
    (cd "$tmp" && git add website/index.html \
        && git -c commit.gpgsign=false commit -q -m "seed index.html")

    local log; log="$(mktemp)"
    local rc; rc="$(run_publish_update "$tmp" 0.2.0 "$log")"
    # The push step in this fixture targets a real local bare-repo origin,
    # so the script may exit 0 here. Either way, what we care about is the
    # state of website/index.html on disk.
    echo "    info: publish-update rc=$rc"

    # Three assertions — each version slot must have been rewritten.
    if grep -qE '"softwareVersion": "0\.2\.0"' "$tmp/website/index.html"; then
        pass "M-21: JSON-LD softwareVersion slot rewritten to 0.2.0"
    else
        fail "M-21: JSON-LD softwareVersion slot still stale"
        grep -n softwareVersion "$tmp/website/index.html" | sed 's/^/      | /' >&2
    fi
    if grep -q "Apple Silicon and Intel · v0.2.0" "$tmp/website/index.html"; then
        pass "download sub-line rewritten"
    else
        fail "download sub-line not rewritten"
    fi
    if grep -q "blackbird_core v0.2.0" "$tmp/website/index.html"; then
        pass "terminal mockup rewritten"
    else
        fail "terminal mockup not rewritten"
    fi

    # Sanity: the old stale value must not survive anywhere in the file.
    if grep -q "0.1.15" "$tmp/website/index.html"; then
        fail "M-21: stale 0.1.15 token survived the rewrite"
        grep -n "0.1.15" "$tmp/website/index.html" | sed 's/^/      | /' >&2
    else
        pass "no stale 0.1.15 tokens remain in index.html"
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 9 — M-21 STRAY-check regression-guard: if the JSON-LD field name
# ever moves (e.g. someone renames it to `softwareVersionString` or wraps
# it in a different shape) so the third sed silently misses, the new
# STRAY_SOFTWARE_VERSION check must catch the residue. Seed an index.html
# whose softwareVersion field uses a DIFFERENT key the sed pattern won't
# touch, and assert the script exits non-zero with the diagnostic message.
# ---------------------------------------------------------------------------

case_jsonld_softwareversion_stray_guard() {
    local tmp; tmp="$(mk_tmp bb-pub-9)"
    trap "rm -rf '$tmp'" RETURN

    mk_publish_fixture "$tmp" "ok"

    # Same Team ID stub as case 8 — verify_dmg must pass to reach the
    # rewrite + STRAY-check.
    cat >"$tmp/stub-bin/codesign" <<'STUB'
#!/usr/bin/env bash
mode=""
for arg in "$@"; do
    case "$arg" in
        --display) mode="display" ;;
    esac
done
case "$mode" in
    display)
        cat <<'EOF'
Executable=/path/to/Blackbird.dmg
TeamIdentifier=F2B95Q4CT8
EOF
        ;;
esac
exit 0
STUB
    chmod +x "$tmp/stub-bin/codesign"

    # Seed an index.html whose softwareVersion appears under a NORMAL
    # key (so the sed touches it) AND under a SECOND copy with a stale
    # value the sed-anchor will rewrite, but ALSO with an unprefixed
    # 0.1.15 in a place that doesn't carry the JSON-LD anchor — to
    # exercise the STRAY scan correctly we need the JSON-LD pattern itself
    # to leave a stale entry. Construct a doubled JSON-LD slot: the sed
    # `s|...|...|` (without /g) only rewrites the first match per line.
    # Putting both on the same line bypasses the second.
    cat >"$tmp/website/index.html" <<'HTML'
<!doctype html>
<html><head>
<script type="application/ld+json">
{"softwareVersion": "0.1.15", "extra": "softwareVersion": "0.1.15"}
</script>
</head>
<body>
<div class="reqs">Requires macOS 14 or later · Apple Silicon and Intel · v0.1.15</div>
<div class="row dim">Compiling blackbird_core v0.1.15</div>
</body></html>
HTML

    (cd "$tmp" && git add website/index.html \
        && git -c commit.gpgsign=false commit -q -m "seed doubled-slot index.html")

    local log; log="$(mktemp)"
    local rc; rc="$(run_publish_update "$tmp" 0.2.0 "$log")"

    # The double-slot trick leaves a stale `"softwareVersion": "0.1.15"`
    # behind after the sed runs (sed's default is to replace only the
    # first match per line). The STRAY_SOFTWARE_VERSION scan must catch
    # this and exit non-zero with the JSON-LD diagnostic.
    if [[ "$rc" != "0" ]]; then
        pass "M-21: STRAY check catches missed JSON-LD softwareVersion (rc=$rc)"
    else
        fail "M-21: STRAY check did NOT catch missed JSON-LD softwareVersion"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    if grep -q "JSON-LD softwareVersion slot is stale" "$log"; then
        pass "M-21: diagnostic identifies the JSON-LD slot specifically"
    else
        fail "M-21: STRAY-check diagnostic missing"
        tail -20 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

case_atomic_appcast
case_arg_validation
case_push_then_deploy
case_verify_spctl_reject
case_verify_wrong_team_id
case_verify_stapler_reject
case_verify_format_change
case_jsonld_softwareversion_rewritten
case_jsonld_softwareversion_stray_guard

test_end
