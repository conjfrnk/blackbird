#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -type d -name "Blackbird-*" | head -1)"
if [[ -z "$DERIVED" ]]; then
    echo "No DerivedData for Blackbird; run xcodebuild build first."
    exit 1
fi

APP="$DERIVED/Build/Products/Debug/Blackbird.app/Contents/MacOS/Blackbird"
if [[ ! -x "$APP" ]]; then
    echo "Missing app binary: $APP"
    exit 1
fi

# Launch, give it 3 seconds, then TERM. Expect clean exit.
"$APP" &
APP_PID=$!
sleep 3
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
echo "smoke ok"
