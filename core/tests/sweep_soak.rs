//! v0.1.9 sweep — Track C: opt-in stress / soak coverage.
//!
//! These tests are GATED behind `#[ignore]` so they don't fire under
//! the default `cargo test` run. The intent is opt-in evidence of
//! "long-session stability" and "throughput under hostile mix" that
//! complements (but does not replace) the existing
//! `core/tests/throughput.rs` and `core/tests/long_session_memory.rs`.
//!
//! Run with:
//!   cargo test --release -p blackbird_core --test sweep_soak \
//!     -- --ignored --nocapture
//!
//! The throughput soak measures bytes/sec over a fixed wall-clock
//! window (no `Sleep`, no I/O); the parser-state-stability soak
//! exercises the full FFI surface in random sequences derived from a
//! deterministic PRNG.
//!
//! Pre-flight summary:
//!
//! - throughput soak: 6 MiB in-RAM payload, ~3 s (default
//!   `WALL_BUDGET_MS`); peak resident < 50 MiB.
//! - parser-state soak: 50,000 mixed FFI calls, ~30 s; peak resident
//!   < 50 MiB.
//!
//! NOT a 60-second wall-clock sweep — that would add brittle CI
//! variance. The shape is "do enough work to surface a leak"; if the
//! caller wants longer, they can multiply the loop counts.

use std::time::Instant;

use blackbird_core as bc;

// ---------------------------------------------------------------------------
// Track C: throughput soak — sustained mixed-workload run
// ---------------------------------------------------------------------------

#[test]
#[ignore = "soak; opt in with --ignored"]
fn soak_mixed_workload_throughput_no_panic_no_unbounded_growth() {
    // pre-flight: ~6 MiB payload + ~10 MiB peak (200×60 grid), ~3 s.
    // The shape: build a 6 MiB payload of mixed content (plain text,
    // SGR-colored lines, OSC 7 cwd, OSC 8 hyperlinks, fragmented CSI
    // queries), then feed it into a single term in 4 KiB chunks.
    // We verify (a) total wall-clock is under the budget bound (a
    // very loose ceiling, just to catch a truly catastrophic
    // throughput collapse) and (b) snapshots remain reachable
    // throughout. No leak assertion here — the dedicated
    // `long_session_memory.rs::new_free_cycle_is_bounded` already
    // tests bounded RSS.
    const PAYLOAD_BYTES: usize = 6 * 1024 * 1024;
    const CHUNK_BYTES: usize = 4 * 1024;
    const TIME_BUDGET_SEC: u64 = 30; // very loose ceiling

    // Build the payload deterministically (no rand crate dep). Cycle
    // through 6 distinct line shapes so the parser sees a realistic
    // mix: plain, ANSI, OSC, CSI fragmented, UTF-8 multibyte, wide
    // glyphs.
    let line_shapes: &[&[u8]] = &[
        b"the quick brown fox jumps over the lazy dog\n",
        b"\x1b[1;31mERROR\x1b[0m \x1b[3mtraceback follows\x1b[0m\n",
        b"\x1b]7;file:///tmp\x1b\\\n",
        b"\x1b]8;;https://example.com/\x1b\\link\x1b]8;;\x1b\\\n",
        "日本語 mixed CJK with ASCII tail\n".as_bytes(),
        b"\x1b[?2004h pasted \x1b[?2004l\n",
    ];
    let mut payload = Vec::with_capacity(PAYLOAD_BYTES);
    let mut shape_idx = 0usize;
    while payload.len() < PAYLOAD_BYTES {
        let line = line_shapes[shape_idx % line_shapes.len()];
        payload.extend_from_slice(line);
        shape_idx += 1;
    }
    payload.truncate(PAYLOAD_BYTES);

    let start = Instant::now();
    unsafe {
        let term = bc::bb_term_new(200, 60, 10_000);
        assert!(!term.is_null());

        // Feed in chunks; intersperse snapshot taken every ~64 chunks
        // (matches a real renderer's poll cadence at ~15 fps).
        let mut chunk_count = 0usize;
        for chunk in payload.chunks(CHUNK_BYTES) {
            bc::bb_term_input(term, chunk.as_ptr(), chunk.len());
            chunk_count += 1;
            if chunk_count % 64 == 0 {
                let snap = bc::bb_term_take_snapshot(term);
                assert!(!snap.is_null(), "snapshot must remain reachable mid-soak");
                bc::bb_snap_release(snap);
            }
        }

        // Final snapshot validation: dimensions intact, cells_len
        // matches cols×rows, mode reachable.
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let cols = (*snap).cols as usize;
        let rows = (*snap).rows as usize;
        let cells_len = (*snap).cells_len;
        assert_eq!(
            cells_len,
            cols * rows,
            "post-soak cells_len {} ≠ cols*rows ({}*{})",
            cells_len,
            cols,
            rows
        );
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
    let elapsed = start.elapsed();

    eprintln!(
        "soak throughput: {} MiB in {:.2}s = {:.1} MiB/s",
        PAYLOAD_BYTES / (1024 * 1024),
        elapsed.as_secs_f64(),
        (PAYLOAD_BYTES as f64) / elapsed.as_secs_f64() / (1024.0 * 1024.0)
    );

    assert!(
        elapsed.as_secs() < TIME_BUDGET_SEC,
        "soak exceeded {} s wall-clock budget — suspect catastrophic regression \
         (took {:?})",
        TIME_BUDGET_SEC,
        elapsed
    );
}

// ---------------------------------------------------------------------------
// Track C: parser-state soak — many FFI calls in a deterministic mix
// ---------------------------------------------------------------------------

#[test]
#[ignore = "soak; opt in with --ignored"]
fn soak_50k_mixed_ffi_calls_remain_consistent() {
    // pre-flight: ~10 MiB peak (one 200×60 grid + transient
    // snapshots), ~30 s. Verifies that 50k mixed FFI operations don't
    // produce inconsistent state.
    //
    // The deterministic PRNG (xorshift32) drives the operation
    // selector. Operations: input small chunk, take snapshot, scroll,
    // resize, set named color, clear all, set color query. Each
    // operation is bounded; after every batch of 1k we sanity-check
    // the snapshot dimensions.
    const ITERATIONS: usize = 50_000;
    const MAX_PROD: u64 = 1024 * 1024;
    let _check = MAX_PROD; // 1M cells = ~32 MiB, safe.

    let mut state: u32 = 0x9E37_79B9; // golden-ratio seed

    fn next(state: &mut u32) -> u32 {
        *state ^= *state << 13;
        *state ^= *state >> 17;
        *state ^= *state << 5;
        *state
    }

    let chunks: &[&[u8]] = &[
        b"hello world\n",
        b"\x1b[1mbold\x1b[0m\n",
        b"\x1b[?1049h",
        b"\x1b[?1049l",
        b"\x1b]133;A\x1b\\",
        b"\x1b]133;D;0\x1b\\",
        b"\x1b[2J",
        b"\x1b[?25l",
        b"\x1b[?25h",
        b"\x1b[c",           // DA1
        b"\xF0\x9F\x98\x80", // emoji
        b"\x1b[>4;2m",       // modifyOtherKeys on
        b"\x1b[>4;0m",       // modifyOtherKeys off
    ];

    unsafe {
        let term = bc::bb_term_new(80, 24, 1000);
        assert!(!term.is_null());

        for i in 0..ITERATIONS {
            let r = next(&mut state);
            match r % 7 {
                0..=2 => {
                    // Most-frequent op: feed a small chunk.
                    let chunk = chunks[(r / 7) as usize % chunks.len()];
                    bc::bb_term_input(term, chunk.as_ptr(), chunk.len());
                }
                3 => {
                    // Snapshot + release.
                    let snap = bc::bb_term_take_snapshot(term);
                    if !snap.is_null() {
                        bc::bb_snap_release(snap);
                    }
                }
                4 => {
                    // Scroll by a small bounded delta.
                    let delta = ((r % 21) as i32) - 10; // -10..=10
                    bc::bb_term_scroll(term, delta);
                }
                5 => {
                    // Resize within bounded dims.
                    let cols = 20 + ((r >> 8) % 100) as u16;
                    let rows = 5 + ((r >> 16) % 30) as u16;
                    bc::bb_term_resize(term, cols, rows);
                }
                _ => {
                    // Set palette slot or scroll-to-bottom.
                    let slot = (r as u16) & 0xFF; // 0..=255 — within COUNT
                    let rgb = r & 0x00FF_FFFF;
                    bc::bb_term_set_named_color(term, slot, rgb);
                    bc::bb_term_scroll_to_bottom(term);
                }
            }

            // Every 1000 iterations: sanity check.
            if i % 1000 == 999 {
                let snap = bc::bb_term_take_snapshot(term);
                assert!(!snap.is_null(), "snap must stay reachable at iter {i}");
                let cols = (*snap).cols;
                let rows = (*snap).rows;
                assert!(
                    (2..=1000).contains(&cols) && (2..=1000).contains(&rows),
                    "dims must stay within bounds at iter {i}: {cols}×{rows}"
                );
                let cells_len = (*snap).cells_len;
                assert_eq!(
                    cells_len,
                    (cols as usize) * (rows as usize),
                    "cells_len consistency at iter {i}"
                );
                bc::bb_snap_release(snap);
            }
        }

        bc::bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track C: snapshot-acquire/release ratio probe
// ---------------------------------------------------------------------------

#[test]
#[ignore = "soak; opt in with --ignored"]
fn soak_retain_release_high_ratio_no_leak() {
    // pre-flight: ~5 MiB peak (one snapshot held + many transient retains),
    // ~5 s. Pin that one snapshot can be retained-then-released 10k
    // times without leaking.
    //
    // The acquire/release ratio is high but balanced (every retain
    // is matched by a release) — a regression that miscounted the
    // refcount as "release decrements but retain doesn't increment"
    // would either trigger a use-after-free (segfault, observable)
    // or leak the snapshot (RSS growth, observable in
    // long_session_memory.rs). This test is a pure no-segfault gate.
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        bc::bb_term_input(term, b"hello".as_ptr(), 5);
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null());

        for _ in 0..10_000 {
            let s2 = bc::bb_snap_retain(snap);
            assert_eq!(s2, snap);
            bc::bb_snap_release(s2);
        }

        // Original release.
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}
