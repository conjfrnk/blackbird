#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP="$(find ~/Library/Developer/Xcode/DerivedData -type d -name 'Blackbird.app' | head -1)"
if [[ -z "$APP" ]]; then
    echo "No Blackbird.app in DerivedData; build first via xcodebuild build."
    exit 1
fi

echo "Benchmark workflow (manual):"
echo ""
echo "1. Launch Blackbird and make its window the key window."
echo "2. In its shell, run one of:"
echo ""
echo "     # Throughput — expect >50 MB/s visible scroll on Apple Silicon."
echo "     yes 'The quick brown fox jumps over the lazy dog.' | pv > /dev/null"
echo ""
echo "     # Burst output — should not stall the window."
echo "     for i in \$(seq 1 200); do seq 1 100; done"
echo ""
echo "     # vim fullscreen scroll — dd j j j j should be buttery on ProMotion."
echo "     echo 'line' > /tmp/bench.txt; for i in \$(seq 1 200); do cat /tmp/bench.txt >> /tmp/bench.txt; done"
echo "     vim /tmp/bench.txt"
echo ""
echo "Open Activity Monitor -> Blackbird process -> Energy tab to verify"
echo "Blackbird's CPU% stays in single digits while running these."
