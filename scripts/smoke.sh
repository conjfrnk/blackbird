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

# Launch, give it 3 seconds, then TERM. Expect SIGTERM exit (128+15=143)
# or clean exit (0) if the app raced ahead of the kill. Anything else —
# crash on launch, dyld reject, signal != 15 — is a smoke failure.
APP_STDERR="$(mktemp -t bb-smoke-stderr.XXXXXX)"
trap 'rm -f "$APP_STDERR"' EXIT

"$APP" 2>"$APP_STDERR" &
APP_PID=$!
sleep 3
kill "$APP_PID" 2>/dev/null || true
wait_rc=0
wait "$APP_PID" 2>/dev/null || wait_rc=$?
case "$wait_rc" in
    0|143)
        echo "smoke ok (exit $wait_rc)"
        ;;
    *)
        echo "!! smoke FAILED: app exited $wait_rc (expected 0 or 143 SIGTERM)" >&2
        if [[ -s "$APP_STDERR" ]]; then
            echo "!! captured stderr (last 20 lines):" >&2
            tail -20 "$APP_STDERR" >&2
        fi
        exit 1
        ;;
esac
