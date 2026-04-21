#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name "Blackbird-*" | head -1)"
if [[ -z "$DERIVED" ]]; then
    echo "No DerivedData for Blackbird; run xcodebuild build first."
    exit 1
fi

APP_BUNDLE="$DERIVED/Build/Products/Debug/Blackbird.app"
APP="$APP_BUNDLE/Contents/MacOS/Blackbird"
if [[ ! -x "$APP" ]]; then
    echo "Missing app binary: $APP"
    exit 1
fi

# ---------------------------------------------------------------------------
# Re-sign the ad-hoc DerivedData bundle with an Apple Development identity.
#
# Project memory: hardened-runtime + ad-hoc app + ad-hoc Sparkle = dyld
# rejects the bundle on launch. xcodebuild's Debug config here is often
# CODE_SIGNING_ALLOWED=NO (matching run-with-probe.sh), so the bundle is
# ad-hoc-signed by default. Re-sign before launching to avoid launch crash.
#
# CI doesn't have a signing identity; set BB_SKIP_RESIGN=1 there.
# ---------------------------------------------------------------------------
if [[ "${BB_SKIP_RESIGN:-0}" == "1" ]]; then
    echo "==> BB_SKIP_RESIGN=1 — skipping re-sign (CI mode)"
else
    RESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ { print $2; exit }')"
    if [[ -z "$RESIGN_IDENTITY" ]]; then
        echo "error: no 'Apple Development' identity in the codesigning keychain." >&2
        echo "error: set BB_SKIP_RESIGN=1 to skip (CI), or add an Apple Development cert." >&2
        exit 1
    fi
    echo "==> Re-signing $APP_BUNDLE with: $RESIGN_IDENTITY"
    codesign --force --sign "$RESIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
fi

# Launch, give it 3 seconds, then TERM. Expect clean exit.
"$APP" &
APP_PID=$!
sleep 3
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
echo "smoke ok"
