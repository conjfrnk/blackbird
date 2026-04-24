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

case_atomic_appcast
case_arg_validation
case_push_then_deploy

test_end
