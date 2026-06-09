#!/usr/bin/env bash
set -euo pipefail

# Generate a Sparkle appcast <item> snippet (or with --full, a complete
# feed) for one DMG: either the one pinned via APPCAST_DMG (the
# production path — publish-update.sh always pins the artifact it just
# verified) or, for hand-runs only, the freshest GA DMG in ./dist.
#
# Usage:
#   scripts/make-appcast.sh [--full]
#   APPCAST_DMG=/abs/path/Blackbird-X.Y.Z[-pre].dmg scripts/make-appcast.sh [--full]
#
# Required env:
#   APPCAST_BASE_URL   — URL prefix where the DMG will be hosted, e.g.
#                        https://dl.example.com/blackbird/
#
# Optional env:
#   APPCAST_FEED_URL   — self-URL of the appcast feed. Used as the
#                        <atom:link rel="self"> reference and defaults to
#                        "${APPCAST_BASE_URL}/appcast.xml". Set this when
#                        the feed lives on a different host than the
#                        binaries (e.g. binaries on GitHub Releases but
#                        the feed served from blackbird-terminal.com).
#   APPCAST_SITE_URL   — project homepage URL, used as the RSS
#                        <channel>/<link>. Defaults to
#                        "https://blackbird-terminal.com/". The RSS spec
#                        says <channel>/<link> should be the human-
#                        readable homepage of the feed, not the feed URL.
#   SIGN_UPDATE        — path to Sparkle's sign_update binary. If unset,
#                        the script looks in PATH first, then in the
#                        Xcode DerivedData SPM artifact tree.
#   APPCAST_DMG        — explicit path to the DMG to sign and reference.
#                        When set, the dist/ auto-pick below is skipped
#                        entirely. publish-update.sh ALWAYS sets this to
#                        the exact DMG it just trust-root-verified, so
#                        the signed/advertised artifact can never diverge
#                        from the verified one (audit S2-009/S4-001: a
#                        stale newer DMG left in dist/ used to win the
#                        auto-pick and get signed unverified). Prerelease
#                        names (Blackbird-X.Y.Z-rc.N.dmg) are accepted on
#                        this path — the GA-only restriction below exists
#                        to protect the *auto-pick* ordering, which an
#                        explicit selection doesn't need.
#
# The script PRINTS the snippet on stdout — it does not modify any file.
# Redirect to append to a hosted appcast.xml, or paste into one by hand.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Resolve a relative APPCAST_DMG against the CALLER's cwd BEFORE the cd
# below switches to the repo root. Otherwise a hand-run from outside the
# repo would silently re-anchor the path under the repo's dist/ — which
# is gitignored, never cleaned, and shared with release.sh local builds,
# so a same-named stale DMG there would be signed instead of the file
# the operator pointed at, with no diagnostic (the -f and name checks
# both pass). Review follow-up to audit S2-009/S4-001.
if [[ -n "${APPCAST_DMG:-}" && "$APPCAST_DMG" != /* ]]; then
    APPCAST_DMG="$PWD/$APPCAST_DMG"
fi
cd "$REPO_ROOT"

: "${APPCAST_BASE_URL:?APPCAST_BASE_URL must be set (e.g. https://dl.example.com/blackbird/)}"
FEED_URL="${APPCAST_FEED_URL:-${APPCAST_BASE_URL%/}/appcast.xml}"
SITE_URL="${APPCAST_SITE_URL:-https://blackbird-terminal.com/}"

# Audit S4-013: validate the three URL inputs against a safe-charset
# regex BEFORE interpolating into the appcast XML. Without this gate,
# an operator running `APPCAST_BASE_URL='https://x" garbage="' ...`
# would emit malformed XML: the `"` terminates the `<enclosure url=`
# attribute mid-stream and the rest of the value parses as bogus
# attributes. publish-update.sh hard-codes the URL from the validated
# semver tag, so the production pipeline never reaches this gate,
# but a hand-run invocation could. Fail loudly rather than emit a
# broken appcast.
#
# Pattern: scheme http(s) + RFC 3986 unreserved/reserved characters,
# excluding `"`, `<`, `>`, backtick, space. Permissive enough for any
# legitimate appcast hosting URL (incl. ports, paths, query); strict
# enough to refuse XML-attribute-breaking metacharacters.
validate_url_for_xml() {
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^https?://[A-Za-z0-9._~:/?#@!\$\&\'\(\)\*\+,\;=%\-]+$ ]]; then
        echo "!! $name='$value' contains characters unsafe for XML attribute interpolation." >&2
        echo "   Allowed: https?:// followed by RFC 3986 reserved/unreserved chars." >&2
        echo "   Rejected chars include: \" < > backtick space, and others outside the set." >&2
        exit 1
    fi
}
validate_url_for_xml APPCAST_BASE_URL "$APPCAST_BASE_URL"
validate_url_for_xml APPCAST_FEED_URL "$FEED_URL"
validate_url_for_xml APPCAST_SITE_URL "$SITE_URL"

FULL=0
if [[ "${1:-}" == "--full" ]]; then
    FULL=1
fi

DMG=""
# Set-but-empty is rejected rather than treated as unset: the header
# promises "when set, the auto-pick is skipped entirely", and a caller
# whose path computation produced "" (or a stale `export APPCAST_DMG=`)
# must not silently degrade to the unverified auto-pick mode this
# variable exists to bypass. Review follow-up to audit S2-009/S4-001.
if [[ -n "${APPCAST_DMG+x}" && -z "${APPCAST_DMG}" ]]; then
    echo "!! APPCAST_DMG is set but empty — refusing to fall back to the dist/ auto-pick." >&2
    echo "   Unset it for auto-pick, or point it at the DMG to publish." >&2
    exit 1
fi
if [[ -n "${APPCAST_DMG:-}" ]]; then
    # Explicit selection (publish-update.sh path). The name must still
    # carry a semver so the VERSION extraction below stays well-formed;
    # prerelease suffixes are allowed here — only the auto-pick needs
    # the GA-only restriction (see below).
    APPCAST_DMG_BASE="$(basename "$APPCAST_DMG")"
    if [[ ! "$APPCAST_DMG_BASE" =~ ^Blackbird-([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)\.dmg$ ]]; then
        echo "!! APPCAST_DMG='$APPCAST_DMG' doesn't match Blackbird-<semver>.dmg" >&2
        exit 1
    fi
    if [[ ! -f "$APPCAST_DMG" ]]; then
        echo "!! APPCAST_DMG='$APPCAST_DMG' does not exist." >&2
        exit 1
    fi
    DMG="$APPCAST_DMG"
else
    # Auto-pick: the version-newest DMG, NOT the mtime-newest. A
    # stale-dated rebuild of an OLDER version sitting next to the
    # freshly-cut newer one would otherwise shadow the real release.
    # Sort on the version segment using `sort -V` (GNU/BSD versionsort),
    # which correctly orders "0.10.0" after "0.9.0" — plain `sort`
    # would not. Audit F-S8-008 / SFH-027.
    #
    # NOTE (audit S2-009/S4-001): this auto-pick is inherently unsafe
    # for publishing because dist/ accumulates DMGs across releases —
    # it can select a DMG the caller never verified. It remains only
    # as a convenience for hand-run snippet generation; the production
    # pipeline (publish-update.sh) always pins APPCAST_DMG above.
    #
    # `sort -V` inverts semver for prereleases: it places "0.2.0" BEFORE
    # "0.2.0-rc.1" because the hyphen sorts after end-of-string in
    # version bytes, but semver §11 says "0.2.0-rc.1 < 0.2.0". Restrict
    # the regex to GA versions (no hyphen suffix) so a leftover
    # prerelease DMG can't shadow the real release. Prereleases are
    # published via APPCAST_DMG, which bypasses this ordering problem
    # entirely (audit S4-003: the old "use a dist/ containing only the
    # prerelease DMG" advice never worked — this regex excluded the
    # prerelease from enumeration altogether, not just from sorting).
    #
    # Audit L18: enumerate via shell glob into an array rather than
    # `for x in $(ls ...)`. The previous shape was vulnerable to word-
    # splitting on filenames with spaces / globs and could pick up
    # unintended paths if dist/ was a shared workspace; glob expansion
    # is whitespace-safe by construction, and the regex below still
    # rejects any candidate whose name doesn't match the strict
    # `Blackbird-N.N.N.dmg` GA-only shape.
    shopt -s nullglob
    DMG_CANDIDATES=( dist/Blackbird-*.dmg )
    shopt -u nullglob
    DMG_VERSIONS=()
    # Empty-array guard: under `set -u` (set at the top of this script),
    # `"${DMG_CANDIDATES[@]}"` traps as unbound-variable when the glob
    # matched nothing. The `+` alt-expansion form returns nothing if the
    # array is unset/empty so the for-loop iterates zero times instead.
    for candidate in ${DMG_CANDIDATES[@]+"${DMG_CANDIDATES[@]}"}; do
        base="$(basename "$candidate")"
        if [[ "$base" =~ ^Blackbird-([0-9]+\.[0-9]+\.[0-9]+)\.dmg$ ]]; then
            DMG_VERSIONS+=( "${BASH_REMATCH[1]}" )
        fi
    done
    if [[ ${#DMG_VERSIONS[@]} -gt 0 ]]; then
        # Sort the versions numerically and take the highest; mirrors
        # the prior `sort -V | tail -n1` behavior without going through
        # a subshell pipeline that would lose DMG on assignment.
        PICKED="$(printf '%s\n' "${DMG_VERSIONS[@]}" | sort -V | tail -n1)"
        DMG="dist/Blackbird-${PICKED}.dmg"
    fi
fi
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
    echo "!! No DMG found in dist/. Run scripts/release.sh first, or pass" >&2
    echo "   APPCAST_DMG=/path/to/Blackbird-X.Y.Z[-pre].dmg explicitly" >&2
    echo "   (required for prerelease versions — the auto-pick is GA-only)." >&2
    exit 1
fi

DMG_NAME="$(basename "$DMG")"
VERSION="$(echo "$DMG_NAME" | sed -E 's/^Blackbird-(.*)\.dmg$/\1/')"
# Selection breadcrumb on stderr (stdout carries the XML): which file is
# about to be signed and advertised. Makes a wrong-selection incident
# diagnosable from the operator's scrollback.
echo "==> Appcast DMG: $DMG (version $VERSION)" >&2

# Extract CFBundleVersion from the built app's Info.plist. This is what
# Sparkle compares against the installed CFBundleVersion to decide if an
# update is available; using the display version here (e.g. "0.1.2")
# breaks that comparison against older installs whose build number is a
# plain integer like "1" — Sparkle's component-wise comparator sees
# [0,1,2] < [1] and hides the update. Mount the DMG read-only, read the
# plist, detach. Requires nothing beyond built-in macOS tools.
MOUNT_POINT="$(mktemp -d -t blackbird-dmg)"
# Install cleanup before attach so a PlistBuddy or `set -e` abort still
# detaches the DMG (otherwise an interrupted run leaves stale mounts in
# /Volumes that block subsequent attaches with "resource busy"). Both
# operations are idempotent; the success-path tail re-runs them.
trap 'hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true; rmdir "$MOUNT_POINT" 2>/dev/null || true' EXIT
# `-owners off` avoids a root-owner warning on read-only mounts; `-nobrowse`
# hides the volume from Finder so this doesn't spam the sidebar.
hdiutil attach "$DMG" -nobrowse -noverify -noautoopen -readonly -owners off \
    -mountpoint "$MOUNT_POINT" >/dev/null
# Both PlistBuddy reads capture-with-status so a missing key/file can't
# kill the script at the assignment under set -e with the tool's error
# swallowed by the substitution (the S2-008/S2-010 dead-diagnostic
# class). The EXIT trap detaches the DMG on the abort paths.
PB_STATUS=0
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$MOUNT_POINT/Blackbird.app/Contents/Info.plist" 2>&1)" || PB_STATUS=$?
if [[ $PB_STATUS -ne 0 ]]; then
    echo "!! PlistBuddy could not read CFBundleVersion from the mounted DMG:" >&2
    echo "   $BUILD" >&2
    exit 1
fi
# Content-level identity check: the app INSIDE the DMG must carry the
# version the filename claims. The trust-root chain (notarization, Team
# ID, staple) only proves the artifact is ours — a CI mishap that
# archives the wrong commit under the right asset name passes all of it,
# and the feed would then advertise this filename's version with the
# wrong app's build number. If that build number is ≤ installed builds,
# Sparkle silently shows "no update" to every client — the exact
# comparator failure class that shipped broken in v0.1.1. Review
# follow-up to audit S2-009/S4-001.
PB_STATUS=0
APP_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$MOUNT_POINT/Blackbird.app/Contents/Info.plist" 2>&1)" || PB_STATUS=$?
if [[ $PB_STATUS -ne 0 ]]; then
    echo "!! PlistBuddy could not read CFBundleShortVersionString from the mounted DMG:" >&2
    echo "   $APP_SHORT" >&2
    exit 1
fi
hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT" 2>/dev/null || true

if [[ "$APP_SHORT" != "$VERSION" ]]; then
    echo "!! DMG filename says $VERSION but the app inside reports CFBundleShortVersionString=$APP_SHORT." >&2
    echo "   Refusing to advertise a version the artifact does not carry." >&2
    exit 1
fi

if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "!! CFBundleVersion in the shipped app is '$BUILD', not a monotonic integer." >&2
    echo "   Sparkle's comparator requires this to be a strictly-increasing integer" >&2
    echo "   so installs on older builds recognise the update as newer." >&2
    exit 1
fi

# Locate sign_update. Homebrew installs it as `sign_update`; SPM checkout
# puts it under DerivedData.
SIGN_UPDATE_PATH="${SIGN_UPDATE:-}"
if [[ -z "$SIGN_UPDATE_PATH" ]]; then
    if command -v sign_update >/dev/null 2>&1; then
        SIGN_UPDATE_PATH="$(command -v sign_update)"
    else
        CANDIDATE=$(ls -d ~/Library/Developer/Xcode/DerivedData/Blackbird-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update 2>/dev/null | head -1 || true)
        if [[ -n "$CANDIDATE" ]]; then
            SIGN_UPDATE_PATH="$CANDIDATE"
        fi
    fi
fi
if [[ -z "$SIGN_UPDATE_PATH" || ! -x "$SIGN_UPDATE_PATH" ]]; then
    echo "!! sign_update not found. Install with 'brew install sparkle'" >&2
    echo "   or pass SIGN_UPDATE=/path/to/sign_update" >&2
    exit 1
fi

# sign_update emits a line like:
#   sparkle:edSignature="abc…" length="123456"
# Quote SIGN_UPDATE_PATH so a path containing spaces (e.g. a macOS
# developer whose home dir has spaces) still resolves to the executable
# rather than splitting into argv. Audit scripts-release F8.
SIG_LINE="$("$SIGN_UPDATE_PATH" "$DMG")"

# PubDate in RFC 822 format, as Sparkle expects. Honor APPCAST_PUB_DATE
# from the environment so callers (publish-update.sh) can derive a stable
# value from the tag's commit timestamp; without that, two re-runs of the
# same vX.Y.Z would emit different appcast bytes and break the
# "re-run is idempotent" contract publish-update.sh relies on for
# post-S3-failure recovery.
PUB_DATE="${APPCAST_PUB_DATE:-$(date -u +"%a, %d %b %Y %H:%M:%S +0000")}"

URL="${APPCAST_BASE_URL%/}/$DMG_NAME"

ITEM=$(cat <<XML
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${URL}"
                 type="application/x-apple-diskimage"
                 ${SIG_LINE} />
    </item>
XML
)

if [[ "$FULL" == "1" ]]; then
    cat <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     xmlns:atom="http://www.w3.org/2005/Atom"
     version="2.0">
  <channel>
    <title>Blackbird</title>
    <link>${SITE_URL}</link>
    <atom:link href="${FEED_URL}" rel="self" type="application/rss+xml" />
    <description>Release feed for Blackbird.</description>
    <language>en</language>
${ITEM}
  </channel>
</rss>
XML
else
    echo "$ITEM"
fi
