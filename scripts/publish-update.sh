#!/usr/bin/env bash
set -euo pipefail

# Publish a Sparkle update for a released Blackbird version.
#
# Prerequisite: the GitHub release for vX.Y.Z already exists (i.e.
# scripts/cut-release.sh vX.Y.Z finished and the `Release` workflow is
# green — DMG must be attached to the release).
#
# 1. Downloads the notarized DMG from the GH release into ./dist/.
# 2. Signs it with Sparkle's sign_update (reads private EdDSA key from
#    the local login keychain).
# 3. Regenerates website/appcast.xml with the new entry.
# 4. Deploys website/ to S3 + invalidates CloudFront.
# 5. Commits the updated appcast.xml to main and pushes.
#
# The Sparkle private key never leaves this machine — that's why this
# step stays local rather than being wired into CI.
#
# Usage:
#   scripts/publish-update.sh 0.1.1
#   scripts/publish-update.sh v0.1.1
#
# Requires: curl, git, gh, aws (profile "personal"), Sparkle's sign_update.

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>" >&2
    echo "Example: $0 0.1.1" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

RAW_VERSION="$1"
VERSION="${RAW_VERSION#v}"
TAG="v${VERSION}"

# Apple Developer Team ID. Public — embedded in every signed binary
# Apple ships, visible via `codesign -dv` on any DMG. Pinning here means
# a malicious DMG signed by a *different* team (e.g. a stolen-creds
# scenario where someone notarizes under their own account) fails the
# verification chain even though `spctl --assess` would otherwise mark
# it "Notarized Developer ID". Audit SEC-003 / F-S8-004.
TEAM_ID="F2B95Q4CT8"

# Validate version arg shape before doing anything network-bound. Same
# semver pattern cut-release.sh uses; F-S8-003 regression-guard caught
# the inconsistency.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "!! version '$VERSION' is not a valid semver (X.Y.Z[-pre])" >&2
    exit 2
fi

echo "==> Verifying release $TAG exists on GitHub with an attached DMG"
if ! gh release view "$TAG" >/dev/null 2>&1; then
    echo "!! No GH release found for $TAG. Has CI finished?" >&2
    echo "   gh run list --workflow=release.yml --limit 3" >&2
    exit 1
fi
# `gh release view` passes as soon as the release object exists, but the
# DMG upload happens AFTER the release is created — a publish that races
# past the upload step would download a 404 and write a zero-byte DMG.
# Verify the asset is actually listed before proceeding. Audit
# scripts-release F4.
EXPECTED_DMG="Blackbird-${VERSION}.dmg"
if ! gh release view "$TAG" --json assets --jq '.assets[].name' | \
     grep -Fxq "$EXPECTED_DMG"; then
    echo "!! Release $TAG exists but $EXPECTED_DMG isn't attached yet." >&2
    echo "   CI may still be uploading; retry in a minute." >&2
    exit 1
fi

DMG_URL="https://github.com/conjfrnk/blackbird/releases/download/${TAG}/Blackbird-${VERSION}.dmg"
DMG_PATH="dist/Blackbird-${VERSION}.dmg"
mkdir -p dist

echo "==> Downloading $DMG_URL"
curl -fsSL -o "$DMG_PATH" "$DMG_URL"
if [[ ! -s "$DMG_PATH" ]]; then
    echo "!! Downloaded DMG is empty." >&2
    exit 1
fi
echo "    $(shasum -a 256 "$DMG_PATH" | awk '{print $1}')  $(wc -c <"$DMG_PATH") bytes"

# ---------------------------------------------------------------------------
# Trust-root verification (audit SEC-003 / F-S8-004).
#
# Before signing the DMG into the appcast (which is the moment a malicious
# replacement would propagate to every existing install via Sparkle), assert:
#   1. spctl Gatekeeper assessment passes — Apple's authoritative verdict
#      that this DMG is notarized, the embedded .app is signed, and
#      Gatekeeper would launch it.
#   2. spctl's `source=` is `Notarized Developer ID` (rules out
#      unsigned-but-locally-trusted, e.g. dev-signed DMGs that happen to
#      pass `--type install` on the developer's own machine).
#   3. The Team ID in spctl's `origin=` line matches our pinned $TEAM_ID
#      (catches a different-team-signed DMG even if Apple notarized it).
#   4. The notarization ticket is stapled (so first-launch works without
#      Apple's notary servers being reachable for the user).
#
# `codesign --verify` on the bare DMG was considered and dropped: an
# unsigned DMG passes `codesign --verify` silently (it finds no
# signature, returns 0), so it provides no defense. spctl's check
# internally validates the embedded .app's signature via the same
# machinery codesign would use, but with the actual notarization gate
# applied — strictly stronger.
#
# Each check captures stdout+stderr so failure messages are attributable.
# Any failure aborts before sign_update touches the EdDSA key.
# ---------------------------------------------------------------------------

verify_dmg() {
    local dmg="$1"
    local out

    if ! out="$(spctl --assess --type install --verbose=2 "$dmg" 2>&1)"; then
        printf '!! spctl --assess rejected DMG %s:\n' "$dmg" >&2
        printf '%s\n' "$out" | sed 's/^/   | /' >&2
        exit 1
    fi

    # Sanity-check the spctl format before grepping for specific values.
    # Apple has reorganized spctl output across macOS releases; if the
    # `source=` / `origin=` anchors are missing entirely, something
    # deeper has changed and operator should verify manually rather
    # than trust a "Team ID mismatch" diagnostic that's actually a
    # tooling-format issue.
    if ! grep -qE '^source=' <<<"$out" || ! grep -qE '^origin=' <<<"$out"; then
        printf '!! spctl output missing source=/origin= anchors — format may have changed:\n' >&2
        printf '%s\n' "$out" | sed 's/^/   | /' >&2
        printf '!! verify the DMG manually (codesign -dv, stapler validate) before retrying.\n' >&2
        exit 1
    fi

    if ! grep -qE '^source=Notarized Developer ID' <<<"$out"; then
        printf '!! DMG is not notarized (source= line):\n' >&2
        printf '%s\n' "$out" | sed 's/^/   | /' >&2
        exit 1
    fi
    if ! grep -qE "^origin=Developer ID Application:.*\\(${TEAM_ID}\\)" <<<"$out"; then
        printf '!! Team ID mismatch (expected %s) in spctl origin:\n' "$TEAM_ID" >&2
        printf '%s\n' "$out" | sed 's/^/   | /' >&2
        exit 1
    fi

    if ! out="$(xcrun stapler validate "$dmg" 2>&1)"; then
        printf '!! stapler validate failed for %s:\n' "$dmg" >&2
        printf '%s\n' "$out" | sed 's/^/   | /' >&2
        exit 1
    fi

    echo "    DMG verified: notarized, Team ID ${TEAM_ID}, stapled."
}

echo "==> Verifying DMG signature, notarization, and Team ID"
verify_dmg "$DMG_PATH"

echo "==> Signing + regenerating website/appcast.xml"
APPCAST_BASE_URL="https://github.com/conjfrnk/blackbird/releases/download/${TAG}" \
  APPCAST_FEED_URL="https://blackbird-terminal.com/appcast.xml" \
  bash scripts/make-appcast.sh --full > website/appcast.xml

# Bump the two version-bearing strings in website/index.html so the splash
# always reads the version that was just shipped:
#   1. the download sub-line  → "Apple Silicon and Intel · v<X.Y.Z>"
#   2. the terminal mockup    → "Compiling blackbird_core v<X.Y.Z>"
# Each sed is anchored on a unique literal in the file, so neither can
# match the other or any future addition. Idempotent: re-running with the
# same $VERSION rewrites each token to itself, the diff stays empty, and
# the "skip commit if unchanged" branch below still fires on retry.
echo "==> Bumping version labels in website/index.html"
sed -i '' -E "s|(Apple Silicon and Intel · )v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|\1v${VERSION}|" website/index.html
sed -i '' -E "s|(blackbird_core )v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|\1v${VERSION}|" website/index.html
# Sanity: every "v[X.Y.Z]" semver token in the file should now be the
# new version. If any older token survived, one of the anchors regressed.
STRAY="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?' website/index.html | grep -Fv "v${VERSION}" || true)"
if [[ -n "$STRAY" ]]; then
    echo "!! website/index.html still contains older version token(s):" >&2
    echo "$STRAY" | sed 's/^/   /' >&2
    echo "!! check the anchor strings haven't changed" >&2
    exit 1
fi

# Ordering matters: commit + push FIRST, then S3 deploy. If the push fails
# (auth hiccup, someone else pushed main, hook rejection), S3 is untouched
# so the live appcast keeps matching the tracked appcast. If the S3 upload
# fails AFTER the push succeeds, a subsequent re-run of this script is
# idempotent: the appcast regenerates to the same content (same DMG bytes,
# same EdDSA signature input), `git diff --cached --quiet` will then say
# "nothing to commit" and we fall through to re-deploying S3 on retry.
echo "==> Committing appcast.xml + index.html"
git add website/appcast.xml website/index.html
if git diff --cached --quiet; then
    echo "==> nothing to commit — skipping (assuming retry after S3 failure)"
else
    git commit -m "feat(website): signed appcast + version label for ${TAG}"
fi

echo "==> Pushing to origin main (before S3 deploy — if this fails we stop)"
if ! git push origin main; then
    echo "error: git push origin main failed. S3 was NOT touched." >&2
    echo "error: resolve the push failure and re-run this script." >&2
    exit 1
fi

echo "==> Deploying website to S3 + CloudFront"
if ! ( cd website && bash deploy.sh ); then
    echo "error: S3/CloudFront deploy failed AFTER git push succeeded." >&2
    echo "error: the tracked appcast is now ahead of the live appcast." >&2
    echo "error: re-run this script; the commit step is idempotent and will re-deploy." >&2
    exit 1
fi

echo
echo "Done. $TAG is live on blackbird-terminal.com/appcast.xml."
echo "Existing Blackbird installs will pick it up on their next daily poll,"
echo "or via Sparkle → Check for Updates from the app menu."
