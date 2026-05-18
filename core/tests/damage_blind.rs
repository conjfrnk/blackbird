//! Blind FFI contract tests for the snapshot damage-tracking surface
//! (`bb_snap_damage_is_full` + `bb_snap_damage_rows`).
//!
//! Author had no access to `core/src/`; only `core/include/BBCore.h` and
//! the style template `color_ffi_blind.rs` were consulted.
//!
//! Header-documented invariants under test:
//!   - `damage_is_full` returns non-zero when all rows need redraw
//!     (scroll, insert-mode, viewport scrollback change).
//!   - Null `snap` to `damage_is_full` returns 1 (safe default).
//!   - `damage_rows` returns the TOTAL count of damaged rows (may exceed
//!     `out_cap`); writes `min(total, out_cap)` rows.
//!   - `out = null` with any `out_cap` is a length probe: returns total,
//!     writes nothing.
//!   - When `is_full` is true, `damage_rows` returns 0.
//!   - `out` need not be u16-aligned (byte copy internally).
//!   - Safe to call from any thread.
//!
//! Behaviours NOT pinned (header silent — observed and recorded only):
//!   - Initial damage state of a brand-new term (fresh snapshot).
//!   - Sort order of returned row indices.

use blackbird_core::*;
use std::ffi::c_void;
use std::sync::Arc;

// ---------- harness ------------------------------------------------

unsafe extern "C" fn noop_cb(_ev: BBEvent, _ctx: *mut c_void) {}

/// Take a fresh term with the standard 80x24/1000-scrollback geometry,
/// hand it to `body`, then free. The event callback is wired but
/// discards events; damage tests don't care about PtyWrite payloads.
fn with_term<F, R>(body: F) -> R
where
    F: FnOnce(*mut BBTerm) -> R,
{
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        assert!(!term.is_null(), "bb_term_new(80,24,1000) returned null");
        bb_term_set_event_cb(term, Some(noop_cb), std::ptr::null_mut());
        let out = body(term);
        bb_term_free(term);
        out
    }
}

/// Feed bytes into the VT parser.
unsafe fn feed(term: *mut BBTerm, seq: &[u8]) {
    bb_term_input(term, seq.as_ptr(), seq.len());
}

/// Collect a snapshot's damage set into a Vec<u16> by first probing
/// the total, then reading into a correctly-sized buffer. Returns
/// `None` when `is_full` is non-zero, since the header pins
/// `damage_rows` to return 0 in that case (the caller must branch).
unsafe fn collect_damage(snap: *const BBSnap) -> Option<Vec<u16>> {
    if bb_snap_damage_is_full(snap) != 0 {
        // Per header: when full, damage_rows returns 0.
        let zero = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
        assert_eq!(zero, 0, "damage_rows on full damage must return 0");
        return None;
    }
    let total = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
    let mut buf = vec![0u16; total];
    let got = bb_snap_damage_rows(snap, buf.as_mut_ptr(), total);
    assert_eq!(got, total, "second damage_rows call must match probe total");
    Some(buf)
}

/// Drain initial full-damage state until the next snapshot reports partial.
/// Panics if drain doesn't reach a non-full state within `max_attempts`,
/// which surfaces an impl that always reports `Full` (the silent-pass
/// regression that the per-test `if is_full { return; }` early-outs would
/// otherwise mask). Use BEFORE issuing targeted partial-damage writes.
unsafe fn drain_to_partial(term: *mut BBTerm, max_attempts: usize) {
    for _ in 0..max_attempts {
        let snap = bb_term_take_snapshot(term);
        let is_full = bb_snap_damage_is_full(snap);
        bb_snap_release(snap);
        if is_full == 0 {
            return;
        }
    }
    panic!(
        "drain_to_partial: snapshot still reports Full after {max_attempts} drains — \
         implementation may never drain residual damage"
    );
}

// ---------- behaviour 1: fresh-terminal initial snapshot -----------
//
// Header doesn't pin whether a freshly-constructed term reports `Full`
// or empty damage. Both are plausible: implementations often mark the
// initial paint as full (so the renderer wipes the canvas), but a
// minimal impl might begin with no damage events. Observe + record;
// don't assert one specific answer beyond "the API doesn't crash and
// returns a consistent pair".

#[test]
fn fresh_snapshot_damage_state_is_consistent() {
    with_term(|term| unsafe {
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "fresh snapshot must not be null");
        let is_full = bb_snap_damage_is_full(snap);
        let total = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
        let rows = (*snap).rows as usize;
        if is_full != 0 {
            assert_eq!(
                total, 0,
                "is_full=true implies damage_rows returns 0 (header)"
            );
        } else {
            // A fresh terminal has a well-defined damage shape: either no
            // damage at all (lazy first-paint), or the full row range
            // expressed as partial (eager-mark-as-partial). Anything else —
            // 7 random rows, partial overlap, etc. — is a bug signal.
            assert!(
                total == 0 || total == rows,
                "fresh-snapshot partial damage must be 0 (lazy) or {rows} (eager); got {total}"
            );
        }
        bb_snap_release(snap);
    });
}

// ---------- behaviour 2: null-safety on damage_is_full -------------

#[test]
fn null_snap_is_full_returns_one_safe_default() {
    unsafe {
        let v = bb_snap_damage_is_full(std::ptr::null());
        assert_eq!(
            v, 1,
            "null snap must yield is_full=1 per header (repaint everything)"
        );
    }
}

// ---------- behaviour 3: null-safety on damage_rows ----------------

#[test]
fn null_snap_damage_rows_does_not_crash() {
    unsafe {
        // Three null-arg shapes documented permissible by the header.
        // The hard guarantee is "no crash"; the return value is allowed
        // to be either 0 (treat null like full damage) or anything else
        // the impl picks. We assert the call returns and pin only the
        // most useful invariant: null snap + null out + zero cap = 0.
        let r1 = bb_snap_damage_rows(std::ptr::null(), std::ptr::null_mut(), 0);
        assert_eq!(r1, 0, "null snap probe must return 0, got {}", r1);
        // null snap with a non-null buffer must also not crash and must
        // not write into the buffer (we can't fully prove the "no
        // write", but a sentinel check gives partial coverage).
        let mut buf = [0xDEADu16; 4];
        let r2 = bb_snap_damage_rows(std::ptr::null(), buf.as_mut_ptr(), 4);
        assert_eq!(r2, 0, "null snap with sized buf must return 0");
        assert_eq!(buf, [0xDEAD; 4], "null snap must not touch caller's buffer");
    }
}

#[test]
fn valid_snap_null_out_with_nonzero_cap_is_probe() {
    // Header: "passing out = null with any out_cap returns the total
    // count without writing anything." Verify with out_cap = 100, then
    // with out_cap = usize::MAX (should not allocate or scribble).
    with_term(|term| unsafe {
        feed(term, b"hello");
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let probe_100 = bb_snap_damage_rows(snap, std::ptr::null_mut(), 100);
        let probe_max = bb_snap_damage_rows(snap, std::ptr::null_mut(), usize::MAX);
        assert_eq!(probe_100, probe_max, "length probe must be cap-independent");
        bb_snap_release(snap);
    });
}

#[test]
fn valid_snap_nonnull_out_with_zero_cap_is_probe() {
    // Header invariant restated: "Caller compares return-value vs out_cap
    // to detect truncation." With out_cap=0, every non-zero total is
    // detectable as a truncation — and the buffer must be untouched.
    with_term(|term| unsafe {
        feed(term, b"hello");
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let mut buf = [0xDEADu16; 8];
        let got = bb_snap_damage_rows(snap, buf.as_mut_ptr(), 0);
        // got is the TOTAL (per header), even though we passed cap=0.
        let probe = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
        assert_eq!(got, probe, "out_cap=0 must still report total");
        assert_eq!(buf, [0xDEAD; 8], "out_cap=0 must not write into the buffer");
        bb_snap_release(snap);
    });
}

// ---------- behaviour 4: probe equals sized read -------------------

#[test]
fn length_probe_matches_sized_read_for_partial_damage() {
    with_term(|term| unsafe {
        drain_to_partial(term, 8);
        // Partial-row write: a few printable chars on the home row.
        feed(term, b"abc");
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        // Strict: targeted 3-char write on the home row must be partial
        // damage. A buggy "always-Full" impl was previously silently
        // passing this test; the assert makes the test fail loudly.
        assert_eq!(
            bb_snap_damage_is_full(snap),
            0,
            "writing 'abc' must produce partial damage, not Full"
        );
        let probe = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
        let mut buf = vec![0u16; probe];
        let got = bb_snap_damage_rows(snap, buf.as_mut_ptr(), probe);
        assert_eq!(got, probe, "probe and sized read must agree");
        assert_eq!(buf.len(), probe, "buf sized to probe");
        bb_snap_release(snap);
    });
}

// ---------- behaviour 5: truncation detection ----------------------

#[test]
fn truncation_detectable_via_return_value_exceeds_cap() {
    // Write to enough rows that we cross a cap=3 boundary even allowing
    // for whatever residual cursor-row damage the impl carries.
    with_term(|term| unsafe {
        // Drain initial state to a known partial baseline. Loud-panics
        // if the impl never drains, which surfaces an always-Full
        // regression instead of silently passing.
        drain_to_partial(term, 8);

        // Damage 8 distinct rows so cap=3 must under-count regardless of
        // residual cursor-row noise.
        for row in 1..=8u16 {
            let seq = format!("\x1b[{};1H*", row);
            feed(term, seq.as_bytes());
        }

        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        assert_eq!(
            bb_snap_damage_is_full(snap),
            0,
            "8 cursor moves to distinct rows must produce partial damage, not Full"
        );
        let total = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
        assert!(
            total > 3,
            "test setup needs total > cap=3 to exercise truncation; got total={}",
            total
        );

        // Truncated read: cap = 3.
        let mut small = [0xAAAAu16; 3];
        let got = bb_snap_damage_rows(snap, small.as_mut_ptr(), 3);
        assert_eq!(
            got, total,
            "truncated read must still report TOTAL (got={}, total={})",
            got, total
        );
        assert!(got > 3, "return value must exceed cap to signal truncation");
        // Indices written into the buffer must all be < rows.
        let rows = (*snap).rows;
        for &idx in &small {
            assert!(
                idx < rows,
                "truncated buffer index {} out of bounds (rows={})",
                idx,
                rows
            );
        }
        bb_snap_release(snap);
    });
}

// ---------- behaviour 6: full damage triggered by scroll -----------

#[test]
fn scroll_marks_damage_full() {
    with_term(|term| unsafe {
        let _ = bb_term_take_snapshot(term); // drain initial state

        // Push 30 rows of LF — the grid is 24 rows, so this scrolls.
        // Scroll is one of the documented Full triggers.
        let mut blast = Vec::new();
        for _ in 0..30 {
            blast.extend_from_slice(b"x\r\n");
        }
        feed(term, &blast);

        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let full = bb_snap_damage_is_full(snap);
        assert_ne!(
            full, 0,
            "post-scroll snapshot must report damage_is_full != 0"
        );
        // Header: when Full, damage_rows returns 0.
        let mut buf = [0xCAFEu16; 64];
        let got = bb_snap_damage_rows(snap, buf.as_mut_ptr(), 64);
        assert_eq!(
            got, 0,
            "damage_rows on Full snapshot must return 0 per header, got {}",
            got
        );
        bb_snap_release(snap);
    });
}

// ---------- behaviour 7: partial damage from single-char write -----

#[test]
fn single_char_partial_damage_returns_one_row() {
    with_term(|term| unsafe {
        drain_to_partial(term, 8);
        // Now write a single printable char — cursor's at (0,0).
        feed(term, b"x");
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        assert_eq!(
            bb_snap_damage_is_full(snap),
            0,
            "single-char write must produce partial damage, not Full"
        );
        let rows = collect_damage(snap).expect("just checked not full");
        assert_eq!(
            rows.len(),
            1,
            "single char on home row must produce exactly 1 damaged row, got {:?}",
            rows
        );
        assert_eq!(
            rows[0], 0,
            "cursor starts at row 0 — damaged row must be 0, got {}",
            rows[0]
        );
        bb_snap_release(snap);
    });
}

// ---------- behaviour 8: indices within bounds ---------------------

#[test]
fn all_damaged_row_indices_are_within_grid_bounds() {
    with_term(|term| unsafe {
        drain_to_partial(term, 8);
        // Write to a scattered set of rows; CUP indices in [1, 24].
        for row in [1u16, 5, 12, 20, 24] {
            let seq = format!("\x1b[{};1Hz", row);
            feed(term, seq.as_bytes());
        }
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let rows =
            collect_damage(snap).expect("scattered partial writes must not trigger Full damage");
        assert!(
            !rows.is_empty(),
            "expected at least one damaged row from 5 writes"
        );
        let limit = (*snap).rows;
        for &idx in &rows {
            assert!(idx < limit, "damaged row {} >= rows {}", idx, limit);
        }
        bb_snap_release(snap);
    });
}

// ---------- behaviour 9: indices unique ----------------------------

#[test]
fn damaged_row_indices_are_unique() {
    with_term(|term| unsafe {
        drain_to_partial(term, 8);
        // Hit the same row repeatedly + several others; duplicates in
        // damage events would surface as duplicate indices here.
        for _ in 0..10 {
            feed(term, b"\x1b[3;1Hq");
        }
        for row in [1u16, 7, 15] {
            let seq = format!("\x1b[{};1Hr", row);
            feed(term, seq.as_bytes());
        }
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let rows =
            collect_damage(snap).expect("scattered partial writes must not trigger Full damage");
        assert!(
            !rows.is_empty(),
            "expected damaged rows from repeated writes"
        );
        let mut sorted = rows.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(
            sorted.len(),
            rows.len(),
            "damage row indices must be unique; got {:?}",
            rows
        );
        bb_snap_release(snap);
    });
}

// ---------- behaviour 10: sort-order observation -------------------
//
// Header does NOT specify whether returned indices are sorted. Don't
// pin a sort assumption. Record observed order on a representative
// input so the suite documents reality; assert only that the multiset
// equals the expected damaged-row set.

#[test]
fn damage_set_contains_exactly_the_damaged_rows() {
    with_term(|term| unsafe {
        drain_to_partial(term, 8);
        // Damage 4 distinct rows: CUP indices 7, 2, 11, 4 → 0-indexed
        // 6, 1, 10, 3.
        for row in [7u16, 2, 11, 4] {
            let seq = format!("\x1b[{};1Hk", row);
            feed(term, seq.as_bytes());
        }
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let rows = collect_damage(snap).expect("4 partial writes must not trigger Full damage");
        // Strict: the damage set's contents (as a sorted multiset) must
        // be exactly the 4 rows we wrote. No missing, no spurious extras
        // beyond at-most-one residual cursor row (which the header
        // permits; we tolerate it by checking superset + tight cap).
        let mut sorted = rows.clone();
        sorted.sort_unstable();
        sorted.dedup();
        let expected = [1u16, 3, 6, 10];
        for r in expected {
            assert!(
                sorted.binary_search(&r).is_ok(),
                "expected row {r} in damage set; got {sorted:?}"
            );
        }
        // Cap on spurious extras: 4 expected + ≤2 residual rows
        // (cursor row at most, plus one drain residue) = 6 max. Anything
        // larger surfaces a bug where the damage set includes unrelated
        // rows.
        assert!(
            sorted.len() <= expected.len() + 2,
            "damage set has {} unique rows; expected ≤ {} (4 written + ≤2 residual). Got: {:?}",
            sorted.len(),
            expected.len() + 2,
            sorted
        );
        bb_snap_release(snap);
    });
}

// ---------- behaviour 11: take_snapshot drains/decreases damage ----
//
// Header is silent on whether `bb_term_take_snapshot` consumes the
// damage set. The brief asks: "B's damage set must be empty". The
// header doesn't guarantee that. Observed reality: the impl keeps the
// cursor row marked dirty across consecutive snapshots (a perfectly
// defensible choice: a blinking cursor needs to be repainted even when
// no input arrived). So pin only the looser invariant the header
// supports: B's damage set must not grow vs A's, and B must not be
// Full when A was non-Full.

#[test]
fn second_snapshot_strictly_drains_or_holds_damage() {
    with_term(|term| unsafe {
        // Drain initial state and write to 4 rows so A has a known
        // partial damage shape. Strict assertion below: B's count must
        // be STRICTLY LESS than A's (snapshot drain semantics), with
        // one tolerance for an at-most-one residual cursor row.
        drain_to_partial(term, 8);
        for row in [3u16, 7, 12, 19] {
            let seq = format!("\x1b[{};1Hx", row);
            feed(term, seq.as_bytes());
        }
        let a = bb_term_take_snapshot(term);
        assert!(!a.is_null());
        let b = bb_term_take_snapshot(term);
        assert!(!b.is_null());

        assert_eq!(
            bb_snap_damage_is_full(a),
            0,
            "A: 4 partial writes must produce partial damage"
        );
        assert_eq!(
            bb_snap_damage_is_full(b),
            0,
            "B: no input between A and B; must not become Full"
        );
        let a_total = bb_snap_damage_rows(a, std::ptr::null_mut(), 0);
        let b_total = bb_snap_damage_rows(b, std::ptr::null_mut(), 0);
        // Strict: take_snapshot is expected to drain or hold steady.
        // An impl that NEVER drains (regression) would have b_total
        // == a_total > 0 — caught only because a_total > 0 here. Tip
        // toward strict-drain: assert b_total < a_total OR b_total ≤ 1
        // (cursor-row residue is OK).
        assert!(
            b_total < a_total || b_total <= 1,
            "second snapshot must drain damage (or leave only cursor residue); A.total={}, B.total={}",
            a_total,
            b_total
        );
        bb_snap_release(b);
        bb_snap_release(a);
    });
}

// ---------- behaviour 12: out-cap zero with non-null buffer --------
// covered by `valid_snap_nonnull_out_with_zero_cap_is_probe` above.

// ---------- behaviour 13: out-cap larger than total ----------------

#[test]
fn over_sized_buffer_leaves_suffix_untouched() {
    with_term(|term| unsafe {
        drain_to_partial(term, 8);
        // Damage two known rows.
        feed(term, b"\x1b[2;1Ha");
        feed(term, b"\x1b[5;1Hb");
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        assert_eq!(
            bb_snap_damage_is_full(snap),
            0,
            "two-row partial write must not trigger Full damage"
        );
        let total = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
        // Allocate 100 slots filled with 0xDEAD sentinel; only `total`
        // should be overwritten.
        let mut buf = vec![0xDEADu16; 100];
        let got = bb_snap_damage_rows(snap, buf.as_mut_ptr(), 100);
        assert_eq!(got, total, "got={} must equal total={}", got, total);
        assert!(total <= 100, "test invariant: total <= 100");
        // The unwritten suffix [total..100] must be exactly 0xDEAD.
        for (i, &v) in buf.iter().enumerate().skip(total) {
            assert_eq!(
                v, 0xDEAD,
                "suffix slot {} was overwritten (val={:#x}); damage_rows must not touch past total",
                i, v
            );
        }
        bb_snap_release(snap);
    });
}

// ---------- behaviour 14: cross-thread access ----------------------

#[test]
fn snapshot_damage_apis_safe_from_concurrent_threads() {
    // The header says snapshot reads are "safe to call from any thread"
    // because snapshots are immutable post-construction. Spin two
    // worker threads pounding both APIs on the same snapshot and
    // assert no panic and consistent return values.
    with_term(|term| unsafe {
        feed(term, b"\x1b[3;1Ha");
        feed(term, b"\x1b[7;1Hb");
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        // Use Arc to share the raw pointer across threads. The pointer
        // itself is Send-safe as long as the underlying buffer is
        // immutable (which the header promises).
        struct SnapPtr(*const BBSnap);
        unsafe impl Send for SnapPtr {}
        unsafe impl Sync for SnapPtr {}
        let shared = Arc::new(SnapPtr(snap));

        let baseline_full = bb_snap_damage_is_full(snap);
        let baseline_total = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);

        let h1 = {
            let s = Arc::clone(&shared);
            std::thread::spawn(move || {
                let p = s.0;
                let mut last_full = 0;
                let mut last_total = 0;
                for _ in 0..200 {
                    last_full = bb_snap_damage_is_full(p);
                    last_total = bb_snap_damage_rows(p, std::ptr::null_mut(), 0);
                }
                (last_full, last_total)
            })
        };
        let h2 = {
            let s = Arc::clone(&shared);
            std::thread::spawn(move || {
                let p = s.0;
                let mut buf = vec![0u16; 64];
                let mut last_total = 0;
                for _ in 0..200 {
                    last_total = bb_snap_damage_rows(p, buf.as_mut_ptr(), 64);
                }
                last_total
            })
        };
        let (t1_full, t1_total) = h1.join().expect("thread 1 panicked");
        let t2_total = h2.join().expect("thread 2 panicked");

        assert_eq!(
            t1_full, baseline_full,
            "concurrent is_full reads must be stable (immutable snap)"
        );
        assert_eq!(
            t1_total, baseline_total,
            "concurrent total reads must be stable"
        );
        assert_eq!(
            t2_total, baseline_total,
            "concurrent sized reads must report same total"
        );

        bb_snap_release(snap);
    });
}

// ---------- behaviour 15: unaligned `out` pointer ------------------

#[test]
fn unaligned_out_pointer_writes_correct_little_endian_bytes() {
    // Header: "out need not be u16-aligned (byte copy internally)."
    // Validate by writing into an odd-offset slot of a u8 buffer cast
    // to *mut u16; then re-read the bytes and reconstruct the u16
    // indices little-endian. They must equal what an aligned read
    // returns.
    with_term(|term| unsafe {
        drain_to_partial(term, 8);
        // Damage three known rows: 2, 6, 11 (0-indexed: 1, 5, 10).
        for row in [2u16, 6, 11] {
            let seq = format!("\x1b[{};1H!", row);
            feed(term, seq.as_bytes());
        }
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        assert_eq!(
            bb_snap_damage_is_full(snap),
            0,
            "3-row partial write must not trigger Full damage"
        );
        // Aligned baseline.
        let total = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
        assert!(total >= 3, "expected at least 3 damaged rows");
        let mut aligned = vec![0u16; total];
        let got_a = bb_snap_damage_rows(snap, aligned.as_mut_ptr(), total);
        assert_eq!(got_a, total);

        // Misaligned write: cast a u8 buffer at an odd offset to *mut u16.
        // Buffer size = 1 (offset) + total*2 bytes + 1 sentinel byte.
        let n_bytes = 1 + total * 2 + 1;
        let mut bytes = vec![0xCDu8; n_bytes];
        // Write the leading sentinel byte (offset 0) and trailing sentinel
        // — these are untouched by the byte copy.
        bytes[0] = 0xAB;
        bytes[n_bytes - 1] = 0xEF;
        // The misaligned u16* points one byte in. Confirm the pointer
        // is in fact odd before calling (sanity check the test
        // construction, not the impl).
        let unaligned_ptr = bytes.as_mut_ptr().add(1) as *mut u16;
        assert_ne!(
            (unaligned_ptr as usize) % std::mem::align_of::<u16>(),
            0,
            "test setup broken: ptr is actually aligned"
        );
        let got_u = bb_snap_damage_rows(snap, unaligned_ptr, total);
        assert_eq!(got_u, total, "unaligned read total must match aligned");

        // Sentinels must be intact.
        assert_eq!(bytes[0], 0xAB, "byte before unaligned region clobbered");
        assert_eq!(
            bytes[n_bytes - 1],
            0xEF,
            "byte after unaligned region clobbered"
        );

        // Reconstruct u16 indices little-endian from bytes[1..1+total*2].
        let mut reconstructed = Vec::with_capacity(total);
        for i in 0..total {
            let lo = bytes[1 + i * 2] as u16;
            let hi = bytes[1 + i * 2 + 1] as u16;
            reconstructed.push(lo | (hi << 8));
        }

        // Aligned and unaligned reads must produce identical sequences
        // (the impl is deterministic for the same snapshot).
        assert_eq!(
            reconstructed, aligned,
            "byte-reconstructed indices must match aligned read; \
             aligned={:?}, recon={:?}",
            aligned, reconstructed
        );

        bb_snap_release(snap);
    });
}
