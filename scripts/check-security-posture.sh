#!/usr/bin/env bash
# Pins the hardened runtime / entitlements posture of Blackbird.
#
# A terminal emulator's attack surface is shell bytes + user keystrokes.
# With no config files, plugins, or scripting, the only way to downgrade
# the runtime is via Xcode build settings or entitlements. This script
# makes sure those haven't drifted.
#
# Run: ./scripts/check-security-posture.sh
# Exit 0 on pass; non-zero on failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail() {
  echo "check-security-posture: FAIL — $*" >&2
  exit 1
}

pass() {
  echo "check-security-posture: pass — $*"
}

# ---------------------------------------------------------------------------
# 1. Hardened runtime must be enabled.
# ---------------------------------------------------------------------------
if grep -q "^    ENABLE_HARDENED_RUNTIME: YES$" project.yml; then
  pass "ENABLE_HARDENED_RUNTIME: YES in project.yml"
else
  fail "ENABLE_HARDENED_RUNTIME: YES missing from project.yml settings.base"
fi

# ---------------------------------------------------------------------------
# 2. No entitlements that weaken hardened runtime.
#    * com.apple.security.cs.allow-jit      — disables JIT protection
#    * com.apple.security.cs.allow-unsigned-executable-memory
#    * com.apple.security.cs.disable-library-validation
#    * com.apple.security.cs.disable-executable-page-protection
#    * com.apple.security.cs.allow-dyld-environment-variables
#
# Blackbird has no reason to need any of these — it's not a host for foreign
# code, doesn't JIT, doesn't load unsigned plugins. If one appears, surface
# it for human review rather than silently shipping with it.
# ---------------------------------------------------------------------------
FORBIDDEN_PATTERNS=(
  "com.apple.security.cs.allow-jit"
  "com.apple.security.cs.allow-unsigned-executable-memory"
  "com.apple.security.cs.disable-library-validation"
  "com.apple.security.cs.disable-executable-page-protection"
  "com.apple.security.cs.allow-dyld-environment-variables"
)

# Search the tree but exclude generated/derived output and cached deps.
SEARCH_PATHS=(project.yml Sources scripts/release.sh .github)

for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
  if grep -rnH "$pattern" "${SEARCH_PATHS[@]}" 2>/dev/null; then
    fail "forbidden entitlement present: $pattern"
  fi
done
pass "no runtime-downgrading entitlements present"

# ---------------------------------------------------------------------------
# 3. No *.entitlements files in Sources/ (we don't ship custom entitlements
#    today; if one gets added, require it to go through this review).
# ---------------------------------------------------------------------------
ENT_FILES=$(find Sources -name "*.entitlements" -type f 2>/dev/null || true)
if [[ -n "$ENT_FILES" ]]; then
  echo "$ENT_FILES"
  fail "unexpected .entitlements file(s) in Sources/; review and update this script's allowlist"
fi
pass "no .entitlements files in Sources/"

# ---------------------------------------------------------------------------
# 4. Release signing identity is Developer ID, not adhoc.
# ---------------------------------------------------------------------------
if grep -q "Developer ID Application" scripts/release.sh; then
  pass "release.sh targets Developer ID Application"
else
  fail "release.sh does not reference Developer ID Application signing"
fi

# ---------------------------------------------------------------------------
# 5. Notarization step present.
# ---------------------------------------------------------------------------
if grep -q "notarytool\|xcrun notarytool" scripts/release.sh; then
  pass "release.sh runs notarytool"
else
  fail "release.sh missing notarytool step"
fi

# ---------------------------------------------------------------------------
# 6. Sparkle ≥ 2.6.4 — the release that fixed a signed-feed bypass letting
#    a MITM swap the signed installer for alternate payload. The package
#    requirement in `project.yml` is `from: 2.6.0`, which lets SPM resolve
#    any 2.x including vulnerable 2.6.{0..3}. Read the actually-resolved
#    version from Package.resolved and fail if it's below cutoff.
# ---------------------------------------------------------------------------
PKG_RESOLVED="$(
  find . -name 'Package.resolved' \
    -not -path '*/.build/*' -not -path '*/DerivedData/*' -not -path '*/.swiftpm/*' \
    2>/dev/null | head -1
)"
if [[ -z "$PKG_RESOLVED" ]]; then
  fail "no Package.resolved found — run 'xcodebuild -resolvePackageDependencies' and rerun"
fi
SPARKLE_VER="$(
  awk '
    /"identity" : "sparkle"/ { found = 1; next }
    found && /"version" : / { gsub(/[",]/, "", $NF); print $NF; exit }
  ' "$PKG_RESOLVED"
)"
if [[ -z "$SPARKLE_VER" ]]; then
  fail "could not parse Sparkle version from $PKG_RESOLVED"
fi
IFS='.' read -r SP_MAJ SP_MIN SP_PATCH <<<"$SPARKLE_VER"
if (( SP_MAJ < 2 )) \
   || { (( SP_MAJ == 2 )) && (( SP_MIN < 6 )); } \
   || { (( SP_MAJ == 2 )) && (( SP_MIN == 6 )) && (( SP_PATCH < 4 )); }; then
  fail "Sparkle $SPARKLE_VER is below the 2.6.4 security cutoff (signed-feed bypass); bump the package requirement"
fi
pass "Sparkle $SPARKLE_VER ≥ 2.6.4 security cutoff"

# ---------------------------------------------------------------------------
# 7. App Sandbox must NOT be enabled. A terminal with App Sandbox on can't
#    fork arbitrary shells or open files outside its container — the entire
#    product collapses. Keep this posture explicit so a drive-by "enable
#    sandbox for security" PR gets caught here rather than at runtime.
# ---------------------------------------------------------------------------
if grep -rn "com.apple.security.app-sandbox" "${SEARCH_PATHS[@]}" 2>/dev/null; then
  fail "com.apple.security.app-sandbox detected; Blackbird must stay un-sandboxed to fork shells"
fi
pass "no App Sandbox entitlement (intentional — terminals need arbitrary-fork capability)"

# ---------------------------------------------------------------------------
# 9. Sparkle's privileged InstallerLauncher XPC service must be OFF until
#    a real signed appcast ships. With a placeholder feed the updater
#    can't run anyway, and leaving a root-capable XPC helper registered
#    widens the attack surface for no benefit.
# ---------------------------------------------------------------------------
if grep -E "^[[:space:]]*SUEnableInstallerLauncherService:[[:space:]]*true[[:space:]]*$" project.yml; then
  fail "SUEnableInstallerLauncherService is true with a placeholder appcast — turn off until first real release"
fi
pass "SUEnableInstallerLauncherService is off / unset"

# ---------------------------------------------------------------------------
# 8. Sparkle consistency: if SUFeedURL is a real URL (not empty, not the
#    example.com placeholder) then SUPublicEDKey must also be set. Without
#    the EdDSA public key Sparkle accepts unsigned update payloads — a
#    trivial supply-chain compromise if the feed URL ever becomes real.
#    The runtime `isUpdaterConfigured` gate (App.swift) already refuses
#    to start Sparkle in that case, but we want the posture pinned at
#    build time too so a future "simplification" PR can't drop the gate.
# ---------------------------------------------------------------------------
FEED_LINE="$(awk '/CFBundleExecutable/{exit} /SUFeedURL:/{print $2; exit}' project.yml || true)"
KEY_LINE="$(awk '/CFBundleExecutable/{exit} /SUPublicEDKey:/{print substr($0, index($0,$2)); exit}' project.yml || true)"
# Strip trailing comment / whitespace artefacts.
FEED_URL="$(printf '%s' "$FEED_LINE" | awk '{print $1}')"
if [[ -z "$FEED_URL" || "$FEED_URL" == *example.com* ]]; then
  pass "SUFeedURL is unset or placeholder — Sparkle is correctly gated off"
else
  if [[ -z "$KEY_LINE" || "$KEY_LINE" == '""' || "$KEY_LINE" == "''" ]]; then
    fail "SUFeedURL ($FEED_URL) is real but SUPublicEDKey is empty — updates would ship unsigned"
  fi
  pass "SUFeedURL set with a non-empty SUPublicEDKey"
fi

echo "check-security-posture: all checks passed"
