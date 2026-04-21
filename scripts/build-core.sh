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
    rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
fi

echo "==> cargo build arm64"
cargo build -p "$CRATE" --release --target aarch64-apple-darwin

echo "==> cargo build x86_64"
cargo build -p "$CRATE" --release --target x86_64-apple-darwin

# Universal output is always written to core/target/universal/release/ regardless of
# CARGO_TARGET_DIR. This location is hardcoded to match Xcode's LIBRARY_SEARCH_PATHS.
UNIVERSAL_DIR="$REPO_ROOT/core/target/universal/release"
if [ "$TARGET_DIR" != "$REPO_ROOT/target" ]; then
    echo "==> NOTE: per-arch artifacts in $TARGET_DIR; universal .a always written to $UNIVERSAL_DIR"
fi
mkdir -p "$UNIVERSAL_DIR"

echo "==> lipo"
lipo -create \
    "$TARGET_DIR/aarch64-apple-darwin/$PROFILE/lib${CRATE}.a" \
    "$TARGET_DIR/x86_64-apple-darwin/$PROFILE/lib${CRATE}.a" \
    -output "$UNIVERSAL_DIR/lib${CRATE}.a"

echo "==> wrote $UNIVERSAL_DIR/lib${CRATE}.a"
lipo -info "$UNIVERSAL_DIR/lib${CRATE}.a"

# Drift gate for the committed cbindgen header. build.rs regenerates
# core/include/BBCore.h as a side effect of the cargo builds above;
# if what just got written differs from the committed copy, the
# developer's working tree is out of sync and needs either a
# deliberate commit or a rebase before pushing. Default is STRICT:
# fail on drift so CI catches forgotten-header commits. Locally pass
# BB_ALLOW_HEADER_DRIFT=1 while iterating to keep the check as a
# warning instead of an error. Audit rust-build F1.
if [ -d "$REPO_ROOT/.git" ] && command -v git >/dev/null 2>&1; then
    if ! git -C "$REPO_ROOT" diff --quiet -- core/include/BBCore.h; then
        if [ "${BB_ALLOW_HEADER_DRIFT:-0}" = "1" ]; then
            echo "warning: core/include/BBCore.h has uncommitted cbindgen changes" >&2
        else
            echo "error: core/include/BBCore.h drifted from the committed copy —" >&2
            echo "       cbindgen produced different output than what's on disk." >&2
            echo "       Commit the regenerated header, or set BB_ALLOW_HEADER_DRIFT=1" >&2
            echo "       for a local iteration." >&2
            git -C "$REPO_ROOT" --no-pager diff -- core/include/BBCore.h >&2
            exit 1
        fi
    fi
fi
