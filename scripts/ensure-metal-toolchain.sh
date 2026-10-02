#!/usr/bin/env bash
#
# Ensure the Metal compiler is usable (`xcrun -sdk macosx metal --version`
# succeeds), downloading the MetalToolchain component if needed.
#
# Why this is a script and not an inline `if ! ...; then download; fi`:
# `xcodebuild -downloadComponent MetalToolchain` returns once the asset is
# *downloaded*; the cryptexd mount that makes `metal` runnable lands a few
# seconds later. CI run 34988601743 (xcode-27 image) probed 25 ms after
# "Done downloading" and got "cannot execute tool 'metal' due to missing
# Metal Toolchain"; healthy runs on the same image took 2-3.5 s between
# "Done downloading" and a working `metal --version`. So: poll with
# backoff after the download, and retry the download itself a bounded
# number of times. The race is the best-supported hypothesis, not a proven
# mechanism (mount lag vs a stale xcrun negative lookup vs a no-op
# download), so each failed poll logs enough to tell them apart next time.
#
# No-op (one probe, no download) when metal already works.
#
# Test seams (env): BB_METAL_PROBE_CMD, BB_METAL_DOWNLOAD_CMD (word-split,
# no quoting), BB_METAL_MAX_ATTEMPTS (default 3), BB_METAL_POLL_SECS
# (default 30, per-attempt wall-clock poll budget; the
# download itself and a hung probe are bounded only by the job timeout).

set -uo pipefail

read -r -a PROBE <<<"${BB_METAL_PROBE_CMD:-xcrun -sdk macosx metal --version}"
read -r -a DOWNLOAD <<<"${BB_METAL_DOWNLOAD_CMD:-xcodebuild -downloadComponent MetalToolchain}"
MAX_ATTEMPTS="${BB_METAL_MAX_ATTEMPTS:-3}"
POLL_SECS="${BB_METAL_POLL_SECS:-30}"

if ! [[ $MAX_ATTEMPTS =~ ^[1-9][0-9]*$ && $POLL_SECS =~ ^[0-9]+$ ]]; then
    echo "::error::BB_METAL_MAX_ATTEMPTS must be a positive integer and BB_METAL_POLL_SECS a non-negative integer (got '${MAX_ATTEMPTS}' / '${POLL_SECS}')."
    exit 2
fi

# Run the probe once; on success print its output (so the version we log is
# the result we gated on, not a second, possibly different, invocation).
PROBE_OUT=""
probe() { PROBE_OUT=$("${PROBE[@]}" 2>&1); }

if probe; then
    echo "$PROBE_OUT"
    exit 0
fi

echo "Metal toolchain not usable; downloading (max ${MAX_ATTEMPTS} attempts)."

attempt=1
while ((attempt <= MAX_ATTEMPTS)); do
    echo "::group::Metal toolchain attempt ${attempt}/${MAX_ATTEMPTS}"
    # A failed download is not fatal here: the asset may already be on disk
    # and only need mounting, so fall through to the poll either way. The
    # download's own output stays visible so a no-op retry is evident.
    "${DOWNLOAD[@]}"
    dl_rc=$?
    ((dl_rc != 0)) && echo "download exited ${dl_rc} (continuing to poll)"
    dl_done=$SECONDS

    poll_start=$SECONDS
    delay=1
    while :; do
        if probe; then
            echo "::endgroup::"
            echo "metal usable after attempt ${attempt}, $((SECONDS - dl_done))s after download returned (download rc ${dl_rc})."
            echo "$PROBE_OUT"
            exit 0
        fi
        echo "[+$((SECONDS - dl_done))s] probe failed: $(echo "$PROBE_OUT" | head -n 2 | tr '\n' ' ')"
        ((SECONDS - poll_start >= POLL_SECS)) && break
        sleep "$delay"
        ((delay < 8)) && delay=$((delay * 2))
        # Drop any negative xcrun lookup cached before the mount appeared;
        # the next probe's outcome shows whether that mattered.
        xcrun --kill-cache >/dev/null 2>&1 || true
    done
    echo "metal still unusable after $((SECONDS - poll_start))s of polling."
    echo "::endgroup::"
    attempt=$((attempt + 1))
done

echo "::error::Metal toolchain unusable after ${MAX_ATTEMPTS} attempts."
echo "--- diagnostics ---"
xcodebuild -version 2>&1 || true
xcode-select -p 2>&1 || true
sw_vers 2>&1 || true
echo "xcrun --find metal:"
xcrun -sdk macosx --find metal 2>&1 || true
echo "final probe output:"
"${PROBE[@]}" 2>&1 || true
echo "AssetsV2 MetalToolchain:"
find /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain -maxdepth 1 2>&1 | head -20 || true
echo "cryptexd mounts:"
find /private/var/run/com.apple.security.cryptexd/mnt -maxdepth 1 2>&1 | head -20 || true
mount 2>&1 | grep -i -E "metal|cryptex" | head -10 || true
exit 1
