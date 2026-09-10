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
# Scope covers: YAML project config, Swift sources, bundled resources, the
# release script, CI workflows, the repo-root (for stray *.entitlements), and
# the tracked Xcode project (hand edits to pbxproj would otherwise slip past).
SEARCH_PATHS=(
  project.yml
  Sources
  Resources
  scripts/release.sh
  .github
  Blackbird.xcodeproj/project.pbxproj
)

# Repo-root *.entitlements files (tracked, not under Sources/Resources).
ROOT_ENT_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] && ROOT_ENT_FILES+=("$f")
done < <(git ls-files -- '*.entitlements' ':!:Sources/**' ':!:Resources/**' 2>/dev/null || true)

for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
  targets=("${SEARCH_PATHS[@]}")
  if (( ${#ROOT_ENT_FILES[@]} > 0 )); then
    targets+=("${ROOT_ENT_FILES[@]}")
  fi
  # Skip missing paths (e.g. no Resources/ yet) so grep doesn't error out.
  existing=()
  for t in "${targets[@]}"; do
    [[ -e "$t" ]] && existing+=("$t")
  done
  if (( ${#existing[@]} > 0 )) && grep -rnH "$pattern" "${existing[@]}" 2>/dev/null; then
    fail "forbidden entitlement present: $pattern"
  fi
done
pass "no runtime-downgrading entitlements present"

# ---------------------------------------------------------------------------
# 3. No tracked *.entitlements files anywhere in the repo (we don't ship
#    custom entitlements today; if one gets added, require it to go through
#    this review). Use `git ls-files` so any tracked path is caught,
#    regardless of whether it lives under Sources/, Resources/, or the root.
# ---------------------------------------------------------------------------
ENT_FILES="$(git ls-files -- '*.entitlements' 2>/dev/null || true)"
if [[ -n "$ENT_FILES" ]]; then
  echo "$ENT_FILES"
  fail "unexpected tracked .entitlements file(s); review and update this script's allowlist"
fi
pass "no tracked .entitlements files in the repo"

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
# 6. Sparkle ≥ 2.9.6 — 2.6.4 fixed a signed-feed bypass letting a MITM
#    swap the signed installer for alternate payload; 2.9.5/2.9.6 harden
#    the installer against symlink attacks at the delta / archive
#    destination and a root privilege escalation (sparkle-project/Sparkle
#    #2891, #2895, #2897, #2898). The package requirement in `project.yml`
#    is `from: 2.9.6`, but SPM honours Package.resolved, so read the
#    actually-resolved version and fail if it's below the cutoff.
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
   || { (( SP_MAJ == 2 )) && (( SP_MIN < 9 )); } \
   || { (( SP_MAJ == 2 )) && (( SP_MIN == 9 )) && (( SP_PATCH < 6 )); }; then
  fail "Sparkle $SPARKLE_VER is below the 2.9.6 security cutoff (installer symlink / root privilege-escalation fixes); bump the package requirement"
fi
pass "Sparkle $SPARKLE_VER ≥ 2.9.6 security cutoff"

# ---------------------------------------------------------------------------
# 7. App Sandbox must NOT be enabled. A terminal with App Sandbox on can't
#    fork arbitrary shells or open files outside its container — the entire
#    product collapses. Keep this posture explicit so a drive-by "enable
#    sandbox for security" PR gets caught here rather than at runtime.
# ---------------------------------------------------------------------------
sandbox_targets=("${SEARCH_PATHS[@]}")
if (( ${#ROOT_ENT_FILES[@]} > 0 )); then
  sandbox_targets+=("${ROOT_ENT_FILES[@]}")
fi
sandbox_existing=()
for t in "${sandbox_targets[@]}"; do
  [[ -e "$t" ]] && sandbox_existing+=("$t")
done
if (( ${#sandbox_existing[@]} > 0 )) && grep -rn "com.apple.security.app-sandbox" "${sandbox_existing[@]}" 2>/dev/null; then
  fail "com.apple.security.app-sandbox detected; Blackbird must stay un-sandboxed to fork shells"
fi
pass "no App Sandbox entitlement (intentional — terminals need arbitrary-fork capability)"

# ---------------------------------------------------------------------------
# 9. Sparkle's privileged InstallerLauncher XPC service must stay OFF.
#    The appcast (website/appcast.xml, served from blackbird-terminal.com)
#    has been live and EdDSA-signed since v0.1.0, but Blackbird installs
#    updates in-place as the logged-in user, so the root-capable
#    installer-launcher helper is never needed — leaving it registered
#    widens the attack surface for no benefit. Policy, not a
#    pre-release placeholder.
# ---------------------------------------------------------------------------
if grep -E "^[[:space:]]*SUEnableInstallerLauncherService:[[:space:]]*true[[:space:]]*$" project.yml; then
  fail "SUEnableInstallerLauncherService is true — policy is OFF (in-place user updates need no root helper)"
fi
pass "SUEnableInstallerLauncherService is off / unset"

# ---------------------------------------------------------------------------
# 8. Sparkle consistency: SUFeedURL is the live production feed
#    (https://blackbird-terminal.com/appcast.xml), so SUPublicEDKey must
#    be set alongside it. Without the EdDSA public key Sparkle accepts
#    unsigned update payloads — a trivial supply-chain compromise. The
#    empty / example.com branch below is kept so a fork or a local
#    build that blanks the feed still passes; it is not the shipping
#    state. The runtime `isUpdaterConfigured` gate (App.swift) already
#    refuses to start Sparkle when either key is missing, but we want
#    the posture pinned at build time too so a future "simplification"
#    PR can't drop the gate.
# ---------------------------------------------------------------------------
FEED_LINE="$(awk '/CFBundleExecutable/{exit} /SUFeedURL:/{print $2; exit}' project.yml || true)"
KEY_LINE="$(awk '/CFBundleExecutable/{exit} /SUPublicEDKey:/{print substr($0, index($0,$2)); exit}' project.yml || true)"
# Strip trailing comment / whitespace artefacts.
FEED_URL="$(printf '%s' "$FEED_LINE" | awk '{print $1}')"
if [[ -z "$FEED_URL" || "$FEED_URL" == *example.com* ]]; then
  # A blanked feed in THIS repository silently stops updates for every
  # user; only a fork may pass here (BB_ALLOW_BLANK_FEED=1).
  if [[ "${BB_ALLOW_BLANK_FEED:-0}" != "1" ]] && git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null | grep -q 'conjfrnk/blackbird'; then
    fail "SUFeedURL is unset/placeholder in the production repository — updates would silently stop (set BB_ALLOW_BLANK_FEED=1 for a fork)"
  fi
  pass "SUFeedURL is unset or example.com — Sparkle is gated off (fork / local build)"
else
  if [[ -z "$KEY_LINE" || "$KEY_LINE" == '""' || "$KEY_LINE" == "''" ]]; then
    fail "SUFeedURL ($FEED_URL) is real but SUPublicEDKey is empty — updates would ship unsigned"
  fi
  pass "SUFeedURL set with a non-empty SUPublicEDKey"
fi

echo "check-security-posture: all checks passed"
