#!/usr/bin/env bash
#
# Validate scripts/ExportOptions.plist — the contract xcodebuild
# -exportArchive uses to pick certs and produce a notarization-ready app
# bundle. A drift here (wrong method, missing teamID, wrong cert string)
# would silently produce an unsigned or wrong-team-signed app that fails
# Apple's notary days later.
#
# Findings cross-ref:
#   - F-S8-014: ExportOptions.plist is minimal; recommend additional
#     hardening keys (destination=export, explicit empty
#     provisioningProfiles dict). This test pins the minimums and warns
#     on the recommended additions.

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

test_start "export_options_test.sh"

PLIST="$BB_REPO_ROOT/scripts/ExportOptions.plist"
assert_file_exists "$PLIST" "ExportOptions.plist exists"

# Parse with plutil — the same tool xcodebuild itself uses to validate
# plists. This catches malformed XML / DTD drift that a hand-written
# regex would miss.
if ! plutil -lint "$PLIST" >/dev/null 2>&1; then
    fail "plutil -lint rejects $PLIST"
    plutil -lint "$PLIST" 2>&1 | head -10 | sed 's/^/      | /' >&2
    test_end
    exit 1
fi
pass "plutil -lint accepts the plist"

# Extract individual keys via plutil -extract. Using `raw` format gives
# us the bare string value without quotes/escapes.
extract_key() {
    # Branch on plutil's EXIT STATUS and discard its output on failure:
    # some macOS releases print "Could not extract value, error: ..." to
    # STDOUT (not stderr) for a missing key, so the old
    # `plutil ... || echo "<missing>"` captured the error text AND the
    # sentinel — the "if present" guards then misread a missing key as a
    # present-but-wrong value. First surfaced when the harness started
    # running on CI runners (GHA macos-14/15) whose plutil does this.
    local key="$1" out
    if out="$(plutil -extract "$key" raw "$PLIST" -o - 2>/dev/null)"; then
        printf '%s' "$out"
    else
        echo "<missing>"
    fi
}

METHOD="$(extract_key method)"
SIGN_STYLE="$(extract_key signingStyle)"
SIGN_CERT="$(extract_key signingCertificate)"
TEAM_ID="$(extract_key teamID)"

assert_eq "$METHOD" "developer-id" "method == developer-id (Mac-distribution outside MAS)"
assert_eq "$SIGN_STYLE" "manual" "signingStyle == manual (we control which cert is picked)"
assert_eq "$SIGN_CERT" "Developer ID Application" "signingCertificate == 'Developer ID Application'"

# Team ID shape: 10 alphanumeric uppercase characters per Apple's spec.
if [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    pass "teamID is a valid 10-char Apple team ID ($TEAM_ID)"
else
    fail "teamID '$TEAM_ID' doesn't match Apple's 10-char alphanumeric pattern"
fi

# A teamID of all zeros / all letters / repeated chars is shaped right
# but obviously a placeholder. Connor's real team ID is F2B95Q4CT8;
# regression-guard against anyone "fixing" this to a placeholder.
if [[ "$TEAM_ID" == "AAAAAAAAAA" || "$TEAM_ID" == "0000000000" || "$TEAM_ID" == "TEAMIDHERE" ]]; then
    fail "teamID looks like a placeholder ($TEAM_ID)"
else
    pass "teamID is not a placeholder string"
fi

# Forbidden values: signingStyle=automatic would let xcodebuild pick
# whatever cert is registered, including ones that aren't valid for
# Mac-outside-MAS distribution. Block at the plist-validation level.
if [[ "$SIGN_STYLE" == "automatic" ]]; then
    fail "signingStyle is 'automatic' — must be 'manual' for Developer ID dist"
else
    pass "signingStyle != automatic"
fi

# Forbidden methods: anything that's not developer-id implies Mac App
# Store / enterprise / dev profile distribution paths we don't ship.
case "$METHOD" in
    developer-id)
        : # ok
        ;;
    app-store|enterprise|development|ad-hoc)
        fail "method '$METHOD' is wrong for Blackbird's Mac-outside-MAS distribution"
        ;;
    *)
        fail "method '$METHOD' is unknown — review xcodebuild -exportArchive docs"
        ;;
esac

# F-S8-014 RECOMMENDATIONS — these are not strict failures because the
# review marked them low-severity hardening, but we surface them so the
# test author downstream can decide. We DO assert (loudly) that if a
# `provisioningProfiles` key exists it's a dict (not a string typo).
if plutil -extract provisioningProfiles raw "$PLIST" >/dev/null 2>&1; then
    # Key exists — must be a dict (xml-format).
    if plutil -type provisioningProfiles "$PLIST" 2>/dev/null | grep -q "dictionary"; then
        pass "provisioningProfiles, if present, is a dictionary"
    else
        fail "provisioningProfiles is present but not a dictionary"
    fi
else
    # Absent is acceptable — Developer ID distribution doesn't need a
    # provisioning profile.
    echo "    info: provisioningProfiles absent (acceptable for Developer ID)"
fi

# `destination=export` is recommended (F-S8-014) to pin local export
# rather than relying on xcodebuild defaults that have shifted across
# Xcode versions. Currently absent — record as advisory, not a failure.
DEST="$(extract_key destination 2>/dev/null || echo "<missing>")"
if [[ "$DEST" == "<missing>" ]]; then
    echo "    advisory (F-S8-014): consider adding <key>destination</key><string>export</string>"
else
    assert_eq "$DEST" "export" "destination key, if present, is 'export'"
fi

test_end
