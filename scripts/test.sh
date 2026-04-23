#!/usr/bin/env bash
# Local test runner that matches the CI invocation exactly. Bypasses
# code signing entirely so xcodebuild doesn't prompt the keychain for
# access to the signing key when it re-signs embedded frameworks
# (XCUIAutomation, libclang_rt.asan_osx_dynamic, etc.).
#
# "Always allow" in the keychain prompt is brittle — a new process
# spawn or a detached framework signing path can re-ask, and if the
# ACL didn't persist the user gets stuck clicking through repeatedly.
# Disabling signing for test builds avoids the codepath altogether.
# CI does exactly this (.github/workflows/ci.yml: CODE_SIGNING_ALLOWED=NO).
#
# Pass through any extra xcodebuild args: `scripts/test.sh -only-testing:BlackbirdTests/TabStripStressTests`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

exec xcodebuild test \
    -scheme Blackbird \
    -destination 'platform=macOS,arch=arm64' \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    "$@"
