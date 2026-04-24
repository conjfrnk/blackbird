#!/usr/bin/env bash
# Launch Blackbird (Debug) with BB_LATENCY_PROBE=1 and stream the filtered
# unified-log output to the terminal until Ctrl-C. Kills any prior Blackbird
# instance first and kills the spawned one on exit so you don't leak
# processes.
#
# Usage:
#   scripts/run-with-probe.sh           # default: 60 Hz / latency / errors
#   scripts/run-with-probe.sh all       # include every subsystem log line
#
# While it runs:
#   - Type continuously in Blackbird for ~60s to fill the 500-sample
#     latency ring → `latency n=500 p50=X p99=Y` line appears in the stream.
#   - fps lines report every second with min/mean/max frame interval and
#     which screen is rendering (ProMotion vs fixed-60 Hz).
#   - Crash / assert / Fatal lines are caught regardless of the filter.
#
# Ctrl-C ends the log stream, cleans up the Blackbird process, and exits.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

mode="${1:-filtered}"

# ---------------------------------------------------------------------------
# Locate (and if missing, build) the Debug binary.
# ---------------------------------------------------------------------------
find_debug_app() {
  find "$HOME/Library/Developer/Xcode/DerivedData" \
    -type d -path '*Debug*Blackbird.app' 2>/dev/null | head -1
}

APP="$(find_debug_app)"
if [[ -z "$APP" || ! -x "$APP/Contents/MacOS/Blackbird" ]]; then
  echo "==> No Debug build found — running xcodegen + build-core + xcodebuild…" >&2
  xcodegen generate >/dev/null
  scripts/build-core.sh >/dev/null
  xcodebuild build \
    -project Blackbird.xcodeproj \
    -scheme Blackbird \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" >/dev/null
  APP="$(find_debug_app)"
  if [[ -z "$APP" ]]; then
    echo "Build appeared to succeed but no Debug Blackbird.app found. Aborting." >&2
    exit 1
  fi
fi
BIN="$APP/Contents/MacOS/Blackbird"
echo "==> Binary: $BIN"

# ---------------------------------------------------------------------------
# Re-sign the ad-hoc DerivedData bundle with an Apple Development identity.
#
# Project memory: hardened-runtime + ad-hoc app + ad-hoc Sparkle = dyld
# rejects the bundle on launch (this was the v0.1.0 DerivedData crash). The
# build above uses CODE_SIGNING_ALLOWED=NO which produces an ad-hoc bundle,
# so re-sign with a real Apple Development cert before launch.
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
  echo "==> Re-signing $APP with: $RESIGN_IDENTITY"
  codesign --force --sign "$RESIGN_IDENTITY" "$APP" >/dev/null
fi

# ---------------------------------------------------------------------------
# Kill any prior Blackbird so we don't end up with two instances.
# ---------------------------------------------------------------------------
if pgrep -x Blackbird >/dev/null 2>&1; then
  echo "==> Killing prior Blackbird process(es)…"
  pkill -x Blackbird || true
  sleep 0.5
fi

# ---------------------------------------------------------------------------
# Launch Blackbird with the probe enabled. Stdout/stderr go to a log file
# so the terminal shows only the filtered unified-log stream below.
# ---------------------------------------------------------------------------
STDOUT_LOG="/tmp/bb-stdout.log"
: > "$STDOUT_LOG"
BB_LATENCY_PROBE=1 "$BIN" > "$STDOUT_LOG" 2>&1 &
APP_PID=$!
echo "==> Launched Blackbird (pid $APP_PID, BB_LATENCY_PROBE=1)"
echo "==> App stdout/stderr → $STDOUT_LOG"

# Clean up on any exit path — including Ctrl-C inside the log-stream pipe.
cleanup() {
  trap - EXIT INT TERM
  echo ""
  echo "==> Stopping Blackbird (pid $APP_PID)…"
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    # Give AppKit a moment to tear down cleanly.
    for _ in 1 2 3 4 5 6; do
      if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
      sleep 0.2
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
      kill -9 "$APP_PID" 2>/dev/null || true
    fi
  fi
  echo "==> Done. App stdout left at $STDOUT_LOG."
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Stream the unified log. /usr/bin/log disambiguates from zsh's builtin,
# which takes a different argument shape.
# ---------------------------------------------------------------------------
PREDICATE='subsystem == "dev.conjfrnk.blackbird"'
echo "==> Streaming filtered unified log. Ctrl-C to stop."
echo "---------------------------------------------------------------"

# `exec /usr/bin/log stream …` replaces the shell image, which throws
# away the `trap cleanup EXIT INT TERM` set above — Ctrl-C then tears
# down log stream without killing Blackbird, leaving the launched app
# orphaned. Drop the `exec` so the shell stays live and the trap fires.
# Audit scripts-release F19.
if [[ "$mode" == "all" ]]; then
  # Unfiltered — every log line from the app's subsystems. Verbose.
  /usr/bin/log stream --predicate "$PREDICATE" --info --debug --style syslog
else
  # Curated: fps heartbeat (confirms renderer alive), latency flush
  # (probe p50/p99 once ring fills), and any crash signatures.
  /usr/bin/log stream --predicate "$PREDICATE" --info --debug --style syslog \
    | grep --line-buffered -E 'fps\]|latency\]|ERROR|Fatal|assert|crash|SIGABRT|EXC_'
fi
