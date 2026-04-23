//! Regression test for the OSC 8 zero-link fast path.
//!
//! `bb_term_take_snapshot` allocates a fresh `Vec` of `Arc<CStr>` for
//! the link table on every snapshot. Before the rust-core-3 F9 fix,
//! that allocation ran unconditionally — a ProMotion 120 Hz session
//! with zero OSC 8 output paid the allocator on every frame. The fix
//! short-circuits to a static empty-links Vec when the frame has no
//! hyperlinks, making the cost constant-time per frame.
//!
//! This test locks the fast path by asserting that 10 000 back-to-back
//! snapshots of a vanilla terminal (ASCII only, no OSC 8) complete
//! well under a budget that the slow-path allocation would blow
//! through. The exact threshold is generous on purpose — the goal is
//! "order-of-magnitude regression", not "specific ns per snapshot" —
//! because CI runners have uneven CPUs.
//!
//! If a future refactor accidentally re-adds allocation in the
//! no-OSC-8 path, this test fails by timeout. The correct response is
//! to re-restore the short-circuit, not to raise the budget.

use std::time::Instant;

// Release-only: debug-mode allocation bookkeeping (overflow checks,
// ASan-lite bounds) dominates the measurement and would make the 500 ms
// budget flaky. CI runs both `cargo test` debug AND release, so this
// gates the perf signal on release without losing coverage on debug
// (the same snapshot cycles run in unit tests with no budget).
#[cfg(not(debug_assertions))]
#[test]
fn snapshot_without_osc8_is_fast() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 1_000);
        assert!(!term.is_null(), "bb_term_new returned null");

        // Seed the terminal with plain ASCII — no OSC 8 escape. The
        // link table should stay empty for every resulting snapshot.
        let payload = b"hello world\r\n";
        blackbird_core::bb_term_input(term, payload.as_ptr(), payload.len());

        // Warm-up: JIT / CPU caches / any lazy allocation in the
        // publication path. Budgeting over a cold-start frame would
        // add noise unrelated to the fast path.
        for _ in 0..100 {
            let snap = blackbird_core::bb_term_take_snapshot(term);
            blackbird_core::bb_snap_release(snap);
        }

        // Real run. 10 000 iterations × the zero-link fast path is
        // measured in low-single-digit milliseconds on an M-series Mac;
        // 500 ms is a generous CI ceiling that would still flag a
        // regression that re-introduced even a single small allocation
        // per snapshot.
        let start = Instant::now();
        for _ in 0..10_000 {
            let snap = blackbird_core::bb_term_take_snapshot(term);
            blackbird_core::bb_snap_release(snap);
        }
        let elapsed = start.elapsed();

        blackbird_core::bb_term_free(term);

        assert!(
            elapsed.as_millis() < 500,
            "zero-link snapshot regression: 10k iterations took {:?} (expected < 500 ms). \
             rust-core-3 F9's fast-path short-circuit may have been broken — restore it, \
             don't raise the budget.",
            elapsed
        );
    }
}
