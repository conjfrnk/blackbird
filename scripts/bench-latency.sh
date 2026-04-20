#!/usr/bin/env bash
# Run the latency harness test and enforce p50/p99 thresholds.
#
# Usage:
#   ./scripts/bench-latency.sh
#
# Thresholds can be overridden via env:
#   LATENCY_P50_MS=6.0 LATENCY_P99_MS=20.0 ./scripts/bench-latency.sh
#
# The test drives 50 synthetic markKeystroke→markPresented pairs under
# BB_LATENCY_PROBE=1, forces a flush, and the probe logs:
#   latency n=50 p50=<x>ms p99=<y>ms
# to the unified log (subsystem com.conjfrnk.blackbird, category latency).
# This script parses that line and asserts thresholds.
set -euo pipefail

P50_THRESHOLD_MS="${LATENCY_P50_MS:-3.0}"
P99_THRESHOLD_MS="${LATENCY_P99_MS:-10.0}"

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

LOG="$TMPDIR_WORK/xcodebuild.log"

# Run only the latency harness test with BB_LATENCY_PROBE=1 so the probe's
# singleton sees the env var (the _forceEnableForTests hook is belt-and-suspenders;
# having the env var set also lets the shared singleton initialize enabled).
BB_LATENCY_PROBE=1 xcodebuild test \
  -project Blackbird.xcodeproj \
  -scheme Blackbird \
  -destination "platform=macOS,arch=arm64" \
  -only-testing:BlackbirdTests/LatencyHarnessTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  2>&1 | tee "$LOG"

# The probe emits via os.Logger (unified log). xcodebuild stdout does not carry
# unified log entries. We wait briefly for the log daemon to flush, then use
# `log show` to retrieve recent entries for our subsystem+category.
sleep 2
LOG_OUT="$TMPDIR_WORK/log_show.txt"
log show \
  --last 60s \
  --predicate 'subsystem == "com.conjfrnk.blackbird" && category == "latency"' \
  --info > "$LOG_OUT" 2>/dev/null || true

echo "--- unified log entries (latency category, last 60s) ---"
cat "$LOG_OUT" || true
echo "---"

# Parse the most recent p50 and p99 values from the log line:
#   latency n=50 p50=0.00ms p99=0.00ms
p50="$(grep -Eo 'p50=[0-9.]+ms' "$LOG_OUT" | tail -1 | sed 's/p50=//;s/ms//' || true)"
p99="$(grep -Eo 'p99=[0-9.]+ms' "$LOG_OUT" | tail -1 | sed 's/p99=//;s/ms//' || true)"

if [[ -z "$p50" || -z "$p99" ]]; then
  echo "latency gate: no probe samples found in unified log" >&2
  echo "  (log_show output was $(wc -l < "$LOG_OUT") lines)" >&2
  exit 2
fi

awk -v p50="$p50" -v p99="$p99" \
    -v p50t="$P50_THRESHOLD_MS" -v p99t="$P99_THRESHOLD_MS" \
    'BEGIN {
       fail = 0
       if (p50+0 > p50t+0) { printf "FAIL p50=%s ms > threshold %s ms\n", p50, p50t; fail=1 }
       if (p99+0 > p99t+0) { printf "FAIL p99=%s ms > threshold %s ms\n", p99, p99t; fail=1 }
       if (!fail) printf "OK p50=%s ms  p99=%s ms\n", p50, p99
       exit fail
     }'
