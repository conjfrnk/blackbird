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
#      that this DMG would be accepted at mount time.
#   2. spctl's `source=` is `Notarized Developer ID` (rules out
#      dev-signed-but-locally-trusted DMGs that pass `--type install` on
#      the developer's own machine).
#   3. The Team ID extracted via `codesign --display` matches our pinned
#      $TEAM_ID (catches a different-team-signed DMG even if Apple
#      notarized it). spctl emits `origin=<Team ID>` for `--type execute`
#      on .apps but not for `--type install` on DMGs; codesign reads the
#      TeamIdentifier directly from the DMG's CodeDirectory regardless.
#   4. The notarization ticket is stapled (so first-launch works without
#      Apple's notary servers being reachable for the user).
#
# `codesign --verify` on the bare DMG was considered and dropped: an
# unsigned DMG passes `codesign --verify` silently. We use `codesign
# --display` instead, which prints `TeamIdentifier=<id>` only when a
# valid signature is present — absence is itself a fail signal.
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
    # `source=` anchor is missing, something deeper has changed and the
    # operator should verify manually rather than trust a "not notarized"
    # diagnostic that's actually a tooling-format issue.
    if ! grep -qE '^source=' <<<"$out"; then
        printf '!! spctl output missing source= anchor — format may have changed:\n' >&2
        printf '%s\n' "$out" | sed 's/^/   | /' >&2
        printf '!! verify the DMG manually (codesign -dv, stapler validate) before retrying.\n' >&2
        exit 1
    fi

    if ! grep -qE '^source=Notarized Developer ID' <<<"$out"; then
        printf '!! DMG is not notarized (source= line):\n' >&2
        printf '%s\n' "$out" | sed 's/^/   | /' >&2
        exit 1
    fi

    if ! out="$(codesign --display --verbose=2 "$dmg" 2>&1)"; then
        printf '!! codesign --display failed for %s:\n' "$dmg" >&2
        printf '%s\n' "$out" | sed 's/^/   | /' >&2
        exit 1
    fi
    if ! grep -qE "^TeamIdentifier=${TEAM_ID}\$" <<<"$out"; then
        printf '!! Team ID mismatch (expected %s) in codesign output:\n' "$TEAM_ID" >&2
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
# Atomic-write contract: a `> website/appcast.xml` redirect truncates the
# target file the moment the shell opens the FD, BEFORE make-appcast.sh
# emits its first byte. If make-appcast.sh (or sign_update inside it)
# crashes mid-stream, the live tracked appcast is left truncated — every
# Sparkle client polling between the crash and a fix would see malformed
# XML and stop checking for updates. Stage to a tempfile + atomic rename
# so the on-disk appcast is always either the previous valid file or a
# complete new one. Audit L-13 / F-S8-025.
TMP_APPCAST="$(mktemp -t blackbird-appcast.XXXXXX)"
# The trap catches `set -e` aborts mid-pipeline (sign_update failure,
# hdiutil failure inside make-appcast, OOM, SIGINT). On the success path
# the `mv` consumes the tempfile so the trap's `rm` is a no-op.
trap 'rm -f "$TMP_APPCAST"' EXIT
# Derive pubDate from the tag's committer timestamp so two runs of the
# same vX.Y.Z produce byte-identical appcast XML. Without this, the
# "idempotent retry after S3 failure" contract below is a lie: a
# wall-clock pubDate forces a new git diff every re-run. Use the Unix
# timestamp + `date -u` to get the same zero-padded UTC RFC 822 shape
# Sparkle's parser expects ("EEE, dd MMM yyyy HH:mm:ss +0000") and that
# the existing committed appcast already uses.
# `|| true` keeps the diagnostic below reachable: `git log <missing-tag>`
# exits 128, and under `set -e` a bare command-substitution assignment
# aborts the script at this line with only git's raw "fatal: ambiguous
# argument" — the friendly message was dead code. Reachable when the
# local clone hasn't fetched the tag (release cut elsewhere / stale
# clone) even though the GH release exists. Same class as audit S2-010.
TAG_COMMIT_TS="$(git log -1 --format=%ct "$TAG" 2>/dev/null || true)"
if [[ -z "$TAG_COMMIT_TS" ]]; then
    echo "!! could not read commit timestamp for tag $TAG" >&2
    echo "   (is the tag fetched locally? try: git fetch origin --tags)" >&2
    exit 1
fi
TAG_PUB_DATE="$(date -u -r "$TAG_COMMIT_TS" +"%a, %d %b %Y %H:%M:%S +0000")"
# Pin the DMG make-appcast.sh signs to the exact file verify_dmg just
# checked. Without APPCAST_DMG, make-appcast.sh auto-picks the version-
# highest DMG in dist/ — and dist/ is gitignored, never cleaned, and
# shared with release.sh local builds, so publishing an older tag while
# a newer (or merely unverified) DMG sat there used to sign and
# advertise an artifact that bypassed the trust-root gate, with an
# enclosure URL that 404s under the older tag's release path. Audit
# S2-009 / S4-001.
APPCAST_DMG="$DMG_PATH" \
  APPCAST_BASE_URL="https://github.com/conjfrnk/blackbird/releases/download/${TAG}" \
  APPCAST_FEED_URL="https://blackbird-terminal.com/appcast.xml" \
  APPCAST_PUB_DATE="$TAG_PUB_DATE" \
  bash scripts/make-appcast.sh --full > "$TMP_APPCAST"

# Belt-and-braces cross-check before the generated appcast can replace
# the live one: the enclosure must reference exactly the URL we
# downloaded and verified, and the advertised short version must be the
# version being published. Either mismatch means make-appcast.sh signed
# something other than the verified artifact — abort with the staged
# tempfile discarded (EXIT trap) and the tracked appcast untouched.
if ! grep -qF "url=\"${DMG_URL}\"" "$TMP_APPCAST"; then
    echo "!! Generated appcast does not reference the verified DMG URL:" >&2
    echo "   expected enclosure url=\"${DMG_URL}\"" >&2
    grep -o 'url="[^"]*"' "$TMP_APPCAST" | sed 's/^/   got: /' >&2
    exit 1
fi
if ! grep -qF "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$TMP_APPCAST"; then
    echo "!! Generated appcast advertises a different version than ${VERSION}:" >&2
    grep -o '<sparkle:shortVersionString>[^<]*</sparkle:shortVersionString>' "$TMP_APPCAST" | sed 's/^/   got: /' >&2
    exit 1
fi
mv -f "$TMP_APPCAST" website/appcast.xml

# Bump the three version-bearing strings in website/index.html so the
# splash always reads the version that was just shipped:
#   1. the download sub-line     → "Apple Silicon and Intel · v<X.Y.Z>"
#   2. the terminal mockup       → "Compiling blackbird_core v<X.Y.Z>"
#   3. the JSON-LD SoftwareApp   → "softwareVersion": "<X.Y.Z>"
# Each sed is anchored on a unique literal in the file, so none can match
# another or any future addition. Idempotent: re-running with the same
# $VERSION rewrites each token to itself, the diff stays empty, and the
# "skip commit if unchanged" branch below still fires on retry.
#
# The JSON-LD slot was silently stale every release through v0.1.15 — the
# original pre-2026-04-29 STRAY check matched only `v[X.Y.Z]` tokens, so
# unprefixed semver in JSON-LD survived. Audit M-21 (MS-5).
echo "==> Bumping version labels in website/index.html"
sed -i '' -E "s|(Apple Silicon and Intel · )v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|\1v${VERSION}|" website/index.html
sed -i '' -E "s|(blackbird_core )v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|\1v${VERSION}|" website/index.html
sed -i '' -E "s|(\"softwareVersion\": \")[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\")|\1${VERSION}\3|" website/index.html
# Sanity: every "v[X.Y.Z]" semver token in the file should now be the
# new version. If any older token survived, one of the anchors regressed.
# Use `grep -Fxv` (whole-line match) on each extracted token, since
# extraction guarantees one token per line. Plain `grep -Fv "v${VERSION}"`
# is a substring filter — with VERSION=0.2.0 it would strip both "v0.2.0"
# AND "v0.2.0-rc.1" (the latter contains the former) and silently miss
# the stale prerelease residue.
STRAY="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?' website/index.html | grep -Fxv "v${VERSION}" || true)"
if [[ -n "$STRAY" ]]; then
    echo "!! website/index.html still contains older v-prefixed version token(s):" >&2
    echo "$STRAY" | sed 's/^/   /' >&2
    echo "!! check the anchor strings haven't changed" >&2
    exit 1
fi
# Separate scan for the unprefixed JSON-LD `softwareVersion` slot. Plain
# `\b[0-9]+\.[0-9]+\.[0-9]+` would also match macOS minimum-version
# strings ("macOS 14.0", "minimumSystemVersion": "14.0"), so anchor on
# the JSON-LD field name to avoid false-positive bait. The third sed
# above is the only writer; this is the matching guard.
STRAY_SOFTWARE_VERSION="$(grep -oE '"softwareVersion": "[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?"' website/index.html | grep -Fxv "\"softwareVersion\": \"${VERSION}\"" || true)"
if [[ -n "$STRAY_SOFTWARE_VERSION" ]]; then
    echo "!! website/index.html JSON-LD softwareVersion slot is stale:" >&2
    echo "$STRAY_SOFTWARE_VERSION" | sed 's/^/   /' >&2
    echo "!! the third sed above didn't match — anchor or field name may have changed" >&2
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
