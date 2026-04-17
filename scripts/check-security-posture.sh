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

echo "check-security-posture: all checks passed"
