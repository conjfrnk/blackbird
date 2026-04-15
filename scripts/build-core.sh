#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root regardless of where this is called from.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

CRATE=blackbird_core
PROFILE=release
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"

# Ensure both targets are installed. `rustup` may be absent on some CI images
# (e.g., Homebrew rust); don't fail hard if it's not present.
if command -v rustup >/dev/null 2>&1; then
    rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true
fi

echo "==> cargo build arm64"
cargo build -p "$CRATE" --"$PROFILE" --target aarch64-apple-darwin

echo "==> cargo build x86_64"
cargo build -p "$CRATE" --"$PROFILE" --target x86_64-apple-darwin

UNIVERSAL_DIR="$REPO_ROOT/core/target/universal/$PROFILE"
mkdir -p "$UNIVERSAL_DIR"

echo "==> lipo"
lipo -create \
    "$TARGET_DIR/aarch64-apple-darwin/$PROFILE/lib${CRATE}.a" \
    "$TARGET_DIR/x86_64-apple-darwin/$PROFILE/lib${CRATE}.a" \
    -output "$UNIVERSAL_DIR/lib${CRATE}.a"

echo "==> wrote $UNIVERSAL_DIR/lib${CRATE}.a"
lipo -info "$UNIVERSAL_DIR/lib${CRATE}.a"
