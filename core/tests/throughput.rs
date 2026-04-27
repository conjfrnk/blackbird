//! Parser throughput regression gate.
//!
//! Spec § 9 aspires to >200 MB/s. These tests measure three representative
//! workloads and fail the build if any falls below a conservative floor —
//! their job is to catch *regressions*, not to prove the aspirational number.
//! Floors are ~50% of the numbers measured on a dev M-series Mac so CI
//! hardware variance (GitHub macOS runners) doesn't flake the build.
//!
//! Run with: `cargo test -p blackbird_core --test throughput --release -- --nocapture`

use std::time::Instant;

/// 64 MiB per workload is enough to dwarf one-shot FFI / setup overhead
/// without ballooning CI wall time.
const PAYLOAD_BYTES: usize = 64 * 1024 * 1024;
/// 64 KiB matches TerminalSession's PTY read batch size — so the throughput
/// we measure here reflects what the real hot path sees.
const CHUNK_BYTES: usize = 64 * 1024;

unsafe fn feed_and_time(bytes: &[u8]) -> f64 {
    let term = blackbird_core::bb_term_new(200, 60, 10_000);
    assert!(!term.is_null());

    let start = Instant::now();
    for chunk in bytes.chunks(CHUNK_BYTES) {
        blackbird_core::bb_term_input(term, chunk.as_ptr(), chunk.len());
    }
    // Snapshot once at the end — the renderer pulls once per frame, not per
    // chunk, so this is the realistic workload.
    let snap = blackbird_core::bb_term_take_snapshot(term);
    assert!(!snap.is_null());
    blackbird_core::bb_snap_release(snap);
    let elapsed = start.elapsed();

    blackbird_core::bb_term_free(term);

    bytes.len() as f64 / elapsed.as_secs_f64()
}

fn mib(bytes_per_sec: f64) -> f64 {
    bytes_per_sec / (1024.0 * 1024.0)
}

fn assert_floor(bps: f64, floor_mib: f64, label: &str) {
    eprintln!("{label} throughput: {:.1} MiB/s", mib(bps));
    let floor = floor_mib * 1024.0 * 1024.0;
    assert!(
        bps >= floor,
        "{label} throughput {:.1} MiB/s below floor {:.1} MiB/s",
        mib(bps),
        floor_mib
    );
}

// ---------------------------------------------------------------------------
// Workload 1 — plain text (`yes`, `cat` a log file, tail -f).
// Most common real workload: newline-separated UTF-8 with no control sequences.
// Measured ~95 MiB/s on M2 Pro release build. macos-14 hosted runners observed
// 40–60 MiB/s across back-to-back runs (noisy-neighbor variance on the Azure
// VM), so floor sits at 25 MiB/s — well below CI worst case but still catches
// any 2–3× regression in the parser fast path.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "throughput gate; run explicitly with: cargo test --release --test throughput -- --ignored --nocapture"]
fn throughput_plain_text() {
    let line = b"The quick brown fox jumps over the lazy dog.\n";
    let mut payload = Vec::with_capacity(PAYLOAD_BYTES);
    while payload.len() < PAYLOAD_BYTES {
        payload.extend_from_slice(line);
    }
    payload.truncate(PAYLOAD_BYTES);

    let bps = unsafe { feed_and_time(&payload) };
    assert_floor(bps, 25.0, "plain_text");
}

// ---------------------------------------------------------------------------
// Workload 2 — binary/garbage stream (`cat /dev/urandom`, `hexdump`).
// Exercises the parser's bail paths: most bytes look like the *start* of a
// control sequence but aren't. Deterministic PRNG so CI runs are reproducible.
// Measured ~40 MiB/s on M2 Pro → floor 15 MiB/s.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "throughput gate; run explicitly with: cargo test --release --test throughput -- --ignored --nocapture"]
fn throughput_binary_garbage() {
    let mut payload = Vec::with_capacity(PAYLOAD_BYTES);
    let mut state: u32 = 0x9E3779B9;
    while payload.len() < PAYLOAD_BYTES {
        state = state.wrapping_mul(0x85EBCA77).wrapping_add(0x1B873593);
        payload.push(((state >> 16) & 0xFF) as u8);
    }

    let bps = unsafe { feed_and_time(&payload) };
    assert_floor(bps, 15.0, "binary_garbage");
}

// ---------------------------------------------------------------------------
// Workload 3 — realistic ANSI output (a colored build log).
// SGR foreground/background + reset per line, no full-screen redraws. This is
// what `cargo build`, `grc tail`, and most TUI logs generate. Measured
// ~70 MiB/s on M2 Pro → floor 30 MiB/s.
//
// NOT benchmarked here: pathological full-screen clear spam. ESC[2J on its
// own is cheap (alacritty just walks the visible grid), so a synthetic test
// clearing at multi-MHz would measure the parser overhead rather than any
// realistic workload.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "throughput gate; run explicitly with: cargo test --release --test throughput -- --ignored --nocapture"]
fn throughput_ansi_log() {
    let frame: &[u8] = b"\
        \x1b[38;5;244m[2026-04-17T10:22:11Z]\x1b[39m \
        \x1b[1;32mINFO\x1b[0m  handler accepted request id=42 user=connor\n\
        \x1b[38;5;244m[2026-04-17T10:22:11Z]\x1b[39m \
        \x1b[1;33mWARN\x1b[0m  retrying upstream after \x1b[31m503\x1b[0m (attempt 2/5)\n\
        \x1b[38;5;244m[2026-04-17T10:22:11Z]\x1b[39m \
        \x1b[1;31mERROR\x1b[0m handler failed: \x1b[3mconnection refused\x1b[0m\n";
    let mut payload = Vec::with_capacity(PAYLOAD_BYTES);
    while payload.len() < PAYLOAD_BYTES {
        payload.extend_from_slice(frame);
    }
    payload.truncate(PAYLOAD_BYTES);

    let bps = unsafe { feed_and_time(&payload) };
    assert_floor(bps, 30.0, "ansi_log");
}
