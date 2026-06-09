#!/usr/bin/env bash
#
# Hermetic tests for scripts/cut-release.sh.
#
# Findings cross-ref:
#   - F-S8-002 / SFH-026: `git add ... 2>/dev/null || true` masks add
#     failures. Test asserts a forced-failure on git add propagates a
#     non-zero exit code (i.e. the script does NOT silently proceed to
#     "Nothing staged to commit" and exit 1 with a misleading message).
#     Currently FAILS until the `|| true` is removed — that's the point.
#   - TST-S8-001: running cut-release.sh twice produces a strictly
#     increasing CFBundleVersion and an Info.plist that validates.
#   - F-S8-005: the version-bump sed should match exactly one location
#     in project.yml (regression-guard against multi-target rewrites).
#
# Strategy: we copy the relevant repo fixtures into a fresh tmp dir,
# wrap them in a fresh git repo + bare origin, point the script there
# via $PATH stubs and `cd`, and run the real `cut-release.sh`. We never
# invoke `git push` against the real `origin` remote, never call gh, and
# never call out to xcodegen against the real .xcodeproj — the tests
# stub xcodegen with a script that writes the expected Info.plist value.
#
# IMPORTANT: this test must NEVER be run against the real repo's git
# state. The harness verifies $PWD before each invocation.

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "cut_release_test.sh"

# ---------------------------------------------------------------------------
# Helpers — one fixture builder, parameterised by which failure to inject.
# ---------------------------------------------------------------------------

# Build a minimal fixture repo that looks enough like Blackbird for
# cut-release.sh to run end-to-end without xcodebuild.
#
# Layout (just under $1):
#   project.yml         (with CFBundleShortVersionString + CFBundleVersion)
#   Sources/Blackbird/Info.plist
#   Blackbird.xcodeproj/project.pbxproj   (placeholder, exists to be added)
#   stub-bin/xcodegen   (writes the new versions into Info.plist)
#   stub-bin/git        (optional: shadows real git when we want to fail
#                        a specific subcommand)
mk_fixture() {
    local root="$1"
    mkdir -p "$root"
    cd "$root"

    # Minimal project.yml — quoted version + quoted build, matching the
    # shape cut-release.sh's regex expects. Don't include other targets;
    # the script's sed pass should match exactly one line per key.
    cat >project.yml <<'YML'
name: Blackbird
options:
  bundleIdPrefix: dev.conjfrnk.test
targets:
  Blackbird:
    info:
      properties:
        CFBundleShortVersionString: "0.1.9"
        CFBundleVersion: "9"
YML

    mkdir -p Sources/Blackbird
    cat >Sources/Blackbird/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>0.1.9</string>
    <key>CFBundleVersion</key>
    <string>9</string>
</dict>
</plist>
PLIST

    mkdir -p Blackbird.xcodeproj
    : > Blackbird.xcodeproj/project.pbxproj

    # Drop in a fake xcodegen stub on PATH that just rewrites Info.plist
    # to whatever cut-release.sh sed'd into project.yml. The real
    # xcodegen would do the same (and a lot more); we only care that
    # the post-condition assertion in cut-release.sh passes when wired
    # correctly.
    mkdir -p "$root/stub-bin" "$root/scripts"
    cat >"$root/stub-bin/xcodegen" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# Read the new versions out of project.yml and stamp them into Info.plist.
# This mirrors what xcodegen does for our minimal fixture without invoking
# Xcode. Match the same patterns cut-release.sh writes.
NEW_SHORT="$(grep -E '^ *CFBundleShortVersionString:' project.yml \
    | head -1 \
    | sed -E 's/^ *CFBundleShortVersionString: *"?([^"]+)"? *$/\1/')"
NEW_BUILD="$(grep -E '^ *CFBundleVersion:' project.yml \
    | head -1 \
    | sed -E 's/^ *CFBundleVersion: *"?([^"]+)"? *$/\1/')"
PLIST=Sources/Blackbird/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_SHORT" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
exit 0
STUB
    chmod +x "$root/stub-bin/xcodegen"

    # Pre-stage the cut-release.sh script copy so that mk_git_fixture's
    # initial commit ALSO captures it as tracked content. cut-release.sh
    # checks `git status --porcelain` and aborts on any dirty files, so
    # everything in the fixture must be committed before the script
    # runs. Add a .gitignore for stub-bin/ since those are test-only
    # commands that shouldn't show up as version-controlled bits.
    cp "$BB_REPO_ROOT/scripts/cut-release.sh" "$root/scripts/cut-release.sh"
    chmod +x "$root/scripts/cut-release.sh"
    cat >"$root/.gitignore" <<'IGN'
stub-bin/
IGN

    # Init the repo with these files committed so the working tree is
    # clean — that's a precondition cut-release.sh enforces.
    mk_git_fixture "$root"
    # mk_git_fixture only commits .gitignore. Add the rest of the
    # fixture content as a second commit so the tree is fully clean.
    (
        cd "$root"
        git add project.yml Sources Blackbird.xcodeproj scripts
        git -c commit.gpgsign=false commit -q -m "fixture content"
        git push -q origin main
    )
}

# Run cut-release.sh inside the fixture with PATH adjusted to use our
# stubs. Echoes the exit code; captures stdout+stderr to $log.
run_cut_release() {
    local fixture="$1" version="$2" log="$3"
    # Sanity guard: the fixture must NOT be the real repo.
    if [[ "$fixture" == "$BB_REPO_ROOT" || "$fixture" == "$BB_REPO_ROOT"/* ]]; then
        echo "fatal: fixture path leaks into real repo: $fixture" >&2
        return 99
    fi
    # PATH order matters: stub-bin first so our xcodegen / git stubs win.
    local rc=0
    (
        cd "$fixture"
        # Reset the working dir for this single run; cut-release.sh
        # cd's to its own SCRIPT_DIR/.. then operates relative to that.
        # We point it at our fixture by giving it a copy of the real
        # script under stub-bin.
        export PATH="$fixture/stub-bin:$PATH"
        # cut-release.sh resolves SCRIPT_DIR via dirname "$0" — the
        # fixture pre-stages a copy at $fixture/scripts/cut-release.sh
        # so the cd to "$SCRIPT_DIR/.." lands inside the fixture.
        bash "$fixture/scripts/cut-release.sh" "$version"
    ) >"$log" 2>&1 || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# CASE 1 — TST-S8-001: two consecutive bumps produce strictly-increasing
# CFBundleVersion and a valid Info.plist.
# ---------------------------------------------------------------------------

case_1() {
    local tmp; tmp="$(mk_tmp bb-cut-rel-1)"
    trap "rm -rf '$tmp'" RETURN

    mk_fixture "$tmp"

    local log1; log1="$(mktemp)"
    local rc1; rc1="$(run_cut_release "$tmp" 0.2.0 "$log1")"
    if [[ "$rc1" != "0" ]]; then
        fail "first cut-release.sh 0.2.0 should succeed (rc=$rc1)"
        head -40 "$log1" | sed 's/^/      | /' >&2
        rm -f "$log1"
        return
    fi
    pass "first cut-release.sh 0.2.0 exit 0"

    # Validate Info.plist structurally.
    if /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
            "$tmp/Sources/Blackbird/Info.plist" >/dev/null 2>&1; then
        pass "Info.plist still parses after first bump"
    else
        fail "Info.plist no longer parses after first bump"
    fi

    local build1; build1="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleVersion' "$tmp/Sources/Blackbird/Info.plist")"
    local short1; short1="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' "$tmp/Sources/Blackbird/Info.plist")"
    assert_eq "$short1" "0.2.0" "first bump: short version becomes 0.2.0"
    assert_eq "$build1" "10" "first bump: CFBundleVersion 9 -> 10"

    # Now do a second bump. cut-release.sh refuses to push to a remote
    # we control (bare repo), but the local commit + tag should land.
    # The remote in our fixture IS the bare local origin we created.
    # So `git push origin main` and `git push origin <tag>` will both
    # succeed against the bare repo.
    local log2; log2="$(mktemp)"
    local rc2; rc2="$(run_cut_release "$tmp" 0.2.1 "$log2")"
    if [[ "$rc2" != "0" ]]; then
        fail "second cut-release.sh 0.2.1 should succeed (rc=$rc2)"
        head -40 "$log2" | sed 's/^/      | /' >&2
        rm -f "$log1" "$log2"
        return
    fi
    pass "second cut-release.sh 0.2.1 exit 0"

    local build2; build2="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleVersion' "$tmp/Sources/Blackbird/Info.plist")"
    local short2; short2="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' "$tmp/Sources/Blackbird/Info.plist")"
    assert_eq "$short2" "0.2.1" "second bump: short version becomes 0.2.1"
    assert_eq "$build2" "11" "second bump: CFBundleVersion 10 -> 11"

    # Strict increase invariant.
    if (( build2 > build1 )); then
        pass "CFBundleVersion strictly increases across bumps ($build1 -> $build2)"
    else
        fail "CFBundleVersion did not increase strictly: $build1 -> $build2"
    fi

    rm -f "$log1" "$log2"
}

# ---------------------------------------------------------------------------
# CASE 2 — F-S8-005: the project.yml sed pass should affect exactly ONE
# CFBundleShortVersionString line. If a future fixture adds a second
# target's plist with the same key, the global sed silently rewrites
# both — this test forces that scenario and asserts cut-release.sh
# either refuses to run or rewrites only the Blackbird target.
#
# Currently expected to FAIL until cut-release.sh anchors its sed to a
# specific target block; we record this as a regression-guard for the
# fix.
# ---------------------------------------------------------------------------

case_2() {
    local tmp; tmp="$(mk_tmp bb-cut-rel-2)"
    trap "rm -rf '$tmp'" RETURN

    mk_fixture "$tmp"

    # Inject a second target's CFBundleShortVersionString line that
    # MUST NOT be rewritten when bumping the Blackbird target.
    cat >>"$tmp/project.yml" <<'YML'
  HelperApp:
    info:
      properties:
        CFBundleShortVersionString: "1.0.0"
        CFBundleVersion: "100"
YML
    (cd "$tmp" && git add project.yml && git -c commit.gpgsign=false \
        commit -q -m "add HelperApp target")

    local log; log="$(mktemp)"
    local rc; rc="$(run_cut_release "$tmp" 0.2.0 "$log")"

    # Whatever the script does, the HelperApp version MUST remain 1.0.0
    # and CFBundleVersion MUST remain 100 — those belong to a different
    # target. If cut-release.sh's sed clobbered them, this assertion
    # fails and the test makes the regression visible.
    if grep -qE 'CFBundleShortVersionString: "1\.0\.0"' "$tmp/project.yml"; then
        pass "F-S8-005: HelperApp short version preserved"
    else
        fail "F-S8-005: HelperApp short version clobbered by global sed"
        grep -nE 'CFBundleShortVersionString' "$tmp/project.yml" \
            | sed 's/^/      | /' >&2
    fi
    if grep -qE 'CFBundleVersion: "100"' "$tmp/project.yml"; then
        pass "F-S8-005: HelperApp CFBundleVersion preserved"
    else
        fail "F-S8-005: HelperApp CFBundleVersion clobbered by global sed"
        grep -nE 'CFBundleVersion' "$tmp/project.yml" \
            | sed 's/^/      | /' >&2
    fi

    # rc may be 0 (script ran) or non-zero (script refused) — both are
    # acceptable for this regression-guard so long as the HelperApp
    # values were preserved. Don't assert on rc.
    echo "    info: cut-release.sh rc=$rc with multi-target project.yml"
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 3 — F-S8-002 / SFH-026: forcibly fail `git add` and assert the
# script propagates a non-zero exit code AND the user can see the git
# error in the log (rather than the misleading "Nothing staged to
# commit" branch).
#
# Strategy: stub git so that `git add` exits non-zero, while `git
# status`, `git rev-parse`, and `git fetch` work normally. We do that by
# wrapping the real git binary with a thin filter that intercepts only
# the `add` subcommand.
#
# Currently expected to FAIL until the `2>/dev/null || true` is dropped
# — that's the explicit bug F-S8-002 is calling out. The test gates the
# fix.
# ---------------------------------------------------------------------------

case_3() {
    local tmp; tmp="$(mk_tmp bb-cut-rel-3)"
    trap "rm -rf '$tmp'" RETURN

    mk_fixture "$tmp"

    # Wrap real git so that `git add ...` fails loudly and every other
    # subcommand passes through.
    local real_git; real_git="$(command -v git)"
    cat >"$tmp/stub-bin/git" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "add" ]]; then
    echo "fake git add: simulated permission denied" >&2
    exit 128
fi
exec "$real_git" "\$@"
STUB
    chmod +x "$tmp/stub-bin/git"

    local log; log="$(mktemp)"
    local rc; rc="$(run_cut_release "$tmp" 0.2.0 "$log")"

    # Assertion 1: exit code MUST be non-zero. If the script silently
    # falls through (current bug), it will exit with the misleading
    # "Nothing staged to commit" branch's exit 1 — same exit code, but
    # the failure mode is wrong. Distinguish by log content next.
    if [[ "$rc" == "0" ]]; then
        fail "F-S8-002: cut-release.sh exited 0 despite git add failure"
    else
        pass "cut-release.sh exits non-zero on git add failure (rc=$rc)"
    fi

    # Assertion 2: the user MUST see the git stderr in the captured log
    # (or some other indication that `git add` failed). The fixed
    # script should let git's own error message through. Currently
    # masked by `2>/dev/null || true`.
    if grep -q "simulated permission denied" "$log"; then
        pass "F-S8-002: git stderr surfaced to operator"
    else
        fail "F-S8-002: git add error message swallowed (review SFH-026 / F-S8-002)"
        echo "      script log tail:" >&2
        tail -20 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 4 — pre-flight rejects malformed semver (regression-guard against
# changes that loosen the validation).
# ---------------------------------------------------------------------------

case_4() {
    local tmp; tmp="$(mk_tmp bb-cut-rel-4)"
    trap "rm -rf '$tmp'" RETURN

    mk_fixture "$tmp"

    # "0.19" is missing a dot — should be rejected by the semver regex.
    local log; log="$(mktemp)"
    local rc; rc="$(run_cut_release "$tmp" "0.19" "$log")"
    if [[ "$rc" == "2" ]]; then
        pass "cut-release.sh rejects malformed semver '0.19' with exit 2"
    else
        fail "cut-release.sh accepted malformed '0.19' or wrong exit code (rc=$rc)"
        head -10 "$log" | sed 's/^/      | /' >&2
    fi

    # Working tree must be untouched after a rejected version.
    if [[ -z "$(cd "$tmp" && git status --porcelain)" ]]; then
        pass "rejected-version run leaves working tree clean"
    else
        fail "rejected-version run mutated the working tree"
        (cd "$tmp" && git status --porcelain) | sed 's/^/      | /' >&2
    fi
    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 5 — C1: project.yml with no CFBundleShortVersionString at all.
# The pre-flight read must abort non-zero WITH a diagnostic naming
# CFBundleShortVersionString — not exit silently, not plow ahead with an
# empty current version.
# ---------------------------------------------------------------------------

case_5() {
    local tmp; tmp="$(mk_tmp bb-cut-rel-5)"
    trap "rm -rf '$tmp'" RETURN

    mk_fixture "$tmp"

    # Strip the CFBundleShortVersionString line from project.yml and
    # commit + push so the clean-tree / up-to-date preconditions still hold.
    sed -i '' '/CFBundleShortVersionString/d' "$tmp/project.yml"
    (cd "$tmp" && git add project.yml \
        && git -c commit.gpgsign=false commit -q -m "drop short version" \
        && git push -q origin main)

    local log; log="$(mktemp)"
    local rc; rc="$(run_cut_release "$tmp" 0.2.0 "$log")"

    if [[ "$rc" != "0" ]]; then
        pass "C1: cut-release.sh aborts when CFBundleShortVersionString is missing (rc=$rc)"
    else
        fail "C1: cut-release.sh exited 0 with no CFBundleShortVersionString in project.yml"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    if grep -q "CFBundleShortVersionString" "$log"; then
        pass "C1: diagnostic names CFBundleShortVersionString"
    else
        fail "C1: no diagnostic naming CFBundleShortVersionString (silent abort)"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 6 — C2: project.yml whose CFBundleVersion is not a plain integer
# ("abc"). Sparkle compares build numbers numerically, so the pre-flight
# must abort non-zero with the "isn't a plain integer" diagnostic rather
# than computing garbage arithmetic on it.
# ---------------------------------------------------------------------------

case_6() {
    local tmp; tmp="$(mk_tmp bb-cut-rel-6)"
    trap "rm -rf '$tmp'" RETURN

    mk_fixture "$tmp"

    sed -i '' 's/CFBundleVersion: "9"/CFBundleVersion: "abc"/' "$tmp/project.yml"
    (cd "$tmp" && git add project.yml \
        && git -c commit.gpgsign=false commit -q -m "corrupt build number" \
        && git push -q origin main)

    local log; log="$(mktemp)"
    local rc; rc="$(run_cut_release "$tmp" 0.2.0 "$log")"

    if [[ "$rc" != "0" ]]; then
        pass "C2: cut-release.sh aborts on non-integer CFBundleVersion (rc=$rc)"
    else
        fail "C2: cut-release.sh exited 0 with CFBundleVersion \"abc\""
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    if grep -q "plain integer" "$log" && [[ -s "$log" ]]; then
        pass "C2: non-empty 'plain integer' diagnostic printed"
    else
        fail "C2: missing 'plain integer' diagnostic for CFBundleVersion=abc"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# CASE 7 — C2 (missing variant): project.yml with no CFBundleVersion line
# at all. Same contract: abort non-zero with the plain-integer-style
# diagnostic — an absent value is not a plain integer either.
# ---------------------------------------------------------------------------

case_7() {
    local tmp; tmp="$(mk_tmp bb-cut-rel-7)"
    trap "rm -rf '$tmp'" RETURN

    mk_fixture "$tmp"

    sed -i '' '/CFBundleVersion:/d' "$tmp/project.yml"
    (cd "$tmp" && git add project.yml \
        && git -c commit.gpgsign=false commit -q -m "drop build number" \
        && git push -q origin main)

    local log; log="$(mktemp)"
    local rc; rc="$(run_cut_release "$tmp" 0.2.0 "$log")"

    if [[ "$rc" != "0" ]]; then
        pass "C2-missing: cut-release.sh aborts when CFBundleVersion is absent (rc=$rc)"
    else
        fail "C2-missing: cut-release.sh exited 0 with no CFBundleVersion in project.yml"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    if [[ -s "$log" ]] && grep -q "CFBundleVersion" "$log"; then
        pass "C2-missing: non-empty diagnostic naming CFBundleVersion printed"
    else
        fail "C2-missing: silent abort — no diagnostic naming CFBundleVersion"
        head -30 "$log" | sed 's/^/      | /' >&2
    fi

    rm -f "$log"
}

# ---------------------------------------------------------------------------
# Run all cases.
# ---------------------------------------------------------------------------

case_1
case_2
case_3
case_4
case_5
case_6
case_7

test_end
