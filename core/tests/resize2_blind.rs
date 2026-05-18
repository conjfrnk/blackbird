//! Blind FFI contract tests for `bb_term_resize2`.
//!
//! The author had no access to `core/src/`. The only contract consulted is
//! `core/include/BBCore.h`. Tests verify documented invariants:
//!   - No-op call returns `{0, 0, 0}` (null term OR zero in either dim).
//!   - Clamping floor = 2, ceiling = 1000 on each axis.
//!   - `applied_cols` / `applied_rows` are the actually-applied dims.
//!   - `clamped` is non-zero exactly when request != applied.
//!   - Snapshots reflect the applied dims after resize, and immutable
//!     pre-resize snapshots keep their original dims.
//!   - Resize does NOT synthesize PtyWrite / Fatal events (no SIGWINCH at
//!     this FFI boundary — that's the caller's job).
//!
//! Memory/time budget: each test runs in <100 ms and stays well under
//! 10 MiB. Maximum grid touched is 1000x1000 cells (~20 MB worst case
//! for a single snapshot at 20B/cell — only allocated transiently in
//! the ceiling-clamp tests, and released immediately).

use blackbird_core::*;
use std::ffi::c_void;
use std::sync::Mutex;

// ---------- harness ------------------------------------------------

#[derive(Default)]
struct Sink {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
}

unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = &*(ctx as *const Sink);
    let bytes = if ev.len > 0 && !ev.payload.is_null() {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    sink.events.lock().unwrap().push((ev.kind as u32, bytes));
}

/// Run `body` against a fresh 80x24 terminal with a wired event sink.
/// Returns the collected (kind, payload) events so individual tests can
/// assert "no PtyWrite, no Fatal" as a positive post-condition.
fn with_term<F>(body: F) -> Vec<(u32, Vec<u8>)>
where
    F: FnOnce(*mut BBTerm),
{
    let sink = Sink::default();
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        assert!(!term.is_null(), "bb_term_new(80,24,1000) returned null");
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
        body(term);
        bb_term_free(term);
    }
    sink.events.into_inner().unwrap()
}

/// Variant for tests that need to choose initial dims.
fn with_term_dims<F>(cols: u16, rows: u16, body: F) -> Vec<(u32, Vec<u8>)>
where
    F: FnOnce(*mut BBTerm),
{
    let sink = Sink::default();
    unsafe {
        let term = bb_term_new(cols, rows, 1000);
        assert!(
            !term.is_null(),
            "bb_term_new({cols},{rows},1000) returned null"
        );
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
        body(term);
        bb_term_free(term);
    }
    sink.events.into_inner().unwrap()
}

/// Read the (cols, rows) currently reported by a snapshot. Releases the
/// snapshot before returning so callers can use this freely.
unsafe fn snapshot_dims(term: *mut BBTerm) -> (u16, u16) {
    let snap = bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
    let dims = ((*snap).cols, (*snap).rows);
    bb_snap_release(snap);
    dims
}

fn count_kind(events: &[(u32, Vec<u8>)], kind: BBEventKind) -> usize {
    let k = kind as u32;
    events.iter().filter(|(ek, _)| *ek == k).count()
}

// ---------- 1. null term no-op contract ----------------------------

#[test]
fn null_term_returns_all_zero_struct() {
    unsafe {
        let r = bb_term_resize2(std::ptr::null_mut(), 80, 24);
        assert_eq!(r.applied_cols, 0, "null term: applied_cols must be 0");
        assert_eq!(r.applied_rows, 0, "null term: applied_rows must be 0");
        assert_eq!(r.clamped, 0, "null term: clamped must be 0");
    }
}

#[test]
fn null_term_zero_dims_still_all_zero() {
    // Defensive: even if both axes are zero on a null term, no field may
    // sneak a non-zero value out. Header says all three are zero on
    // any no-op call.
    unsafe {
        let r = bb_term_resize2(std::ptr::null_mut(), 0, 0);
        assert_eq!(r.applied_cols, 0);
        assert_eq!(r.applied_rows, 0);
        assert_eq!(r.clamped, 0);
    }
}

#[test]
fn null_term_out_of_range_dims_still_all_zero() {
    // Even with values that WOULD be clamped on a live term, the null
    // path must return {0,0,0} — the no-op short-circuit beats the
    // clamp logic. A bug that ran the clamp first and only then checked
    // null would yield (1000, 1000, 1) here.
    unsafe {
        let r = bb_term_resize2(std::ptr::null_mut(), 2000, 2000);
        assert_eq!(
            r.applied_cols, 0,
            "null term must short-circuit before clamp"
        );
        assert_eq!(r.applied_rows, 0);
        assert_eq!(r.clamped, 0);
    }
}

// ---------- 2. zero-axis no-op contract ----------------------------

#[test]
fn zero_cols_is_noop_dims_unchanged() {
    let events = with_term(|term| unsafe {
        let (pre_cols, pre_rows) = snapshot_dims(term);
        assert_eq!((pre_cols, pre_rows), (80, 24));

        let r = bb_term_resize2(term, 0, 24);
        assert_eq!(r.applied_cols, 0, "zero-cols: applied_cols must be 0");
        assert_eq!(r.applied_rows, 0, "zero-cols: applied_rows must be 0");
        assert_eq!(r.clamped, 0, "zero-cols: clamped must be 0");

        let (post_cols, post_rows) = snapshot_dims(term);
        assert_eq!(
            (post_cols, post_rows),
            (pre_cols, pre_rows),
            "zero-cols no-op must NOT mutate internal dims"
        );
    });
    assert_eq!(
        count_kind(&events, BBEventKind::Fatal),
        0,
        "no Fatal on zero-cols no-op"
    );
}

#[test]
fn zero_rows_is_noop_dims_unchanged() {
    let events = with_term(|term| unsafe {
        let (pre_cols, pre_rows) = snapshot_dims(term);
        let r = bb_term_resize2(term, 80, 0);
        assert_eq!(r.applied_cols, 0);
        assert_eq!(r.applied_rows, 0);
        assert_eq!(r.clamped, 0);

        let (post_cols, post_rows) = snapshot_dims(term);
        assert_eq!(
            (post_cols, post_rows),
            (pre_cols, pre_rows),
            "zero-rows no-op must NOT mutate internal dims"
        );
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

#[test]
fn both_zero_is_noop_dims_unchanged() {
    let events = with_term(|term| unsafe {
        let (pre_cols, pre_rows) = snapshot_dims(term);
        let r = bb_term_resize2(term, 0, 0);
        assert_eq!(r.applied_cols, 0);
        assert_eq!(r.applied_rows, 0);
        assert_eq!(r.clamped, 0);

        let (post_cols, post_rows) = snapshot_dims(term);
        assert_eq!((post_cols, post_rows), (pre_cols, pre_rows));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

// ---------- 3. plain in-range resize -------------------------------

#[test]
fn in_range_resize_reports_no_clamp_and_applies() {
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 132, 40);
        assert_eq!(
            r.applied_cols, 132,
            "no-clamp: applied_cols must echo request"
        );
        assert_eq!(
            r.applied_rows, 40,
            "no-clamp: applied_rows must echo request"
        );
        assert_eq!(
            r.clamped, 0,
            "no-clamp request inside [2,1000] must NOT set the clamp flag"
        );

        let (cols, rows) = snapshot_dims(term);
        assert_eq!(
            (cols, rows),
            (132, 40),
            "snapshot must reflect the post-resize dims"
        );
    });
    assert_eq!(
        count_kind(&events, BBEventKind::Fatal),
        0,
        "in-range resize must not synthesize a Fatal event"
    );
    assert_eq!(
        count_kind(&events, BBEventKind::PtyWrite),
        0,
        "resize itself must not emit PtyWrite (no SIGWINCH at this layer)"
    );
}

// ---------- 4. floor clamp on each axis ----------------------------

#[test]
fn cols_below_floor_clamps_to_two() {
    let events = with_term(|term| unsafe {
        // Rows = 24 is inside [2,1000] and matches the existing rows; the
        // cols axis is the sole clamp source.
        let r = bb_term_resize2(term, 1, 24);
        assert_eq!(r.applied_cols, 2, "cols=1 must clamp up to floor=2");
        assert_eq!(r.applied_rows, 24, "rows=24 passes through untouched");
        assert_ne!(r.clamped, 0, "clamp flag must fire when cols was rewritten");

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (2, 24));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

#[test]
fn rows_below_floor_clamps_to_two() {
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 80, 1);
        assert_eq!(r.applied_cols, 80);
        assert_eq!(r.applied_rows, 2, "rows=1 must clamp up to floor=2");
        assert_ne!(r.clamped, 0);

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (80, 2));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

#[test]
fn both_below_floor_clamps_each_to_two() {
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 1, 1);
        assert_eq!(r.applied_cols, 2);
        assert_eq!(r.applied_rows, 2);
        assert_ne!(r.clamped, 0);

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (2, 2));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

// ---------- 5. ceiling clamp on each axis --------------------------

#[test]
fn cols_above_ceiling_clamps_to_thousand() {
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 1001, 24);
        assert_eq!(
            r.applied_cols, 1000,
            "cols=1001 must clamp down to ceiling=1000"
        );
        assert_eq!(r.applied_rows, 24);
        assert_ne!(r.clamped, 0);

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (1000, 24));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

#[test]
fn rows_above_ceiling_clamps_to_thousand() {
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 80, 1001);
        assert_eq!(r.applied_cols, 80);
        assert_eq!(r.applied_rows, 1000, "rows=1001 must clamp down to 1000");
        assert_ne!(r.clamped, 0);

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (80, 1000));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

#[test]
fn both_above_ceiling_clamps_each_to_thousand() {
    // 1000x1000 cells * 20B/cell = ~20 MiB transient — released as soon
    // as the snapshot drops at the end of `with_term`.
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 2000, 2000);
        assert_eq!(r.applied_cols, 1000);
        assert_eq!(r.applied_rows, 1000);
        assert_ne!(r.clamped, 0);

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (1000, 1000));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

#[test]
fn mixed_floor_and_ceiling_clamp_both_axes() {
    let events = with_term(|term| unsafe {
        // cols clamps UP, rows clamps DOWN — both axes touched.
        let r = bb_term_resize2(term, 1, 1500);
        assert_eq!(r.applied_cols, 2, "cols=1 → floor 2");
        assert_eq!(r.applied_rows, 1000, "rows=1500 → ceiling 1000");
        assert_ne!(r.clamped, 0, "mixed clamp on both axes must set the flag");

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (2, 1000));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

// ---------- 6. exact-boundary acceptance ---------------------------

#[test]
fn exact_floor_request_two_two_is_not_a_clamp() {
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 2, 2);
        assert_eq!(r.applied_cols, 2);
        assert_eq!(r.applied_rows, 2);
        assert_eq!(
            r.clamped, 0,
            "request matching the floor exactly is NOT a clamp event"
        );

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (2, 2));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

#[test]
fn exact_ceiling_request_thousand_thousand_is_not_a_clamp() {
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 1000, 1000);
        assert_eq!(r.applied_cols, 1000);
        assert_eq!(r.applied_rows, 1000);
        assert_eq!(
            r.clamped, 0,
            "request matching the ceiling exactly is NOT a clamp event"
        );

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (1000, 1000));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

// ---------- 7. clamp-flag asymmetry --------------------------------

#[test]
fn clamp_flag_fires_when_only_one_axis_is_rewritten() {
    // cols=1 clamps to 2; rows=24 passes through. The flag must still
    // fire because the request as a whole differs from the applied dims.
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 1, 24);
        assert_eq!(r.applied_cols, 2);
        assert_eq!(r.applied_rows, 24);
        assert_ne!(
            r.clamped, 0,
            "any axis being rewritten must set the clamp flag"
        );
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

#[test]
fn clamp_flag_fires_when_only_rows_rewritten() {
    let events = with_term(|term| unsafe {
        let r = bb_term_resize2(term, 80, 2000);
        assert_eq!(r.applied_cols, 80);
        assert_eq!(r.applied_rows, 1000);
        assert_ne!(r.clamped, 0);
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

// ---------- 8. idempotent repeat -----------------------------------

#[test]
fn repeated_identical_resize_is_idempotent_and_unclamped() {
    let events = with_term(|term| unsafe {
        let r1 = bb_term_resize2(term, 100, 40);
        assert_eq!(r1.applied_cols, 100);
        assert_eq!(r1.applied_rows, 40);
        assert_eq!(r1.clamped, 0);

        let r2 = bb_term_resize2(term, 100, 40);
        assert_eq!(r2.applied_cols, 100, "second resize echoes request");
        assert_eq!(r2.applied_rows, 40);
        assert_eq!(r2.clamped, 0, "a no-change resize is NOT a clamp event");

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (100, 40));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}

// ---------- 9. snapshot immutability across resize -----------------

#[test]
fn pre_resize_snapshot_keeps_original_dims_post_resize() {
    // The snapshot contract is immutable: dims captured before the
    // resize must not retroactively shift to the post-resize values.
    let events = with_term(|term| unsafe {
        let s_before = bb_term_take_snapshot(term);
        assert!(!s_before.is_null());
        assert_eq!((*s_before).cols, 80);
        assert_eq!((*s_before).rows, 24);
        let pre_cells_len = (*s_before).cells_len;
        assert_eq!(pre_cells_len, 80 * 24);

        let r = bb_term_resize2(term, 132, 40);
        assert_eq!(r.applied_cols, 132);
        assert_eq!(r.applied_rows, 40);
        assert_eq!(r.clamped, 0);

        // OLD snapshot still reports 80x24 — it's frozen at acquire time.
        assert_eq!(
            (*s_before).cols,
            80,
            "pre-resize snapshot cols must remain 80 post-resize"
        );
        assert_eq!(
            (*s_before).rows,
            24,
            "pre-resize snapshot rows must remain 24 post-resize"
        );
        assert_eq!(
            (*s_before).cells_len,
            pre_cells_len,
            "pre-resize snapshot cells_len must not shift"
        );

        // NEW snapshot reflects the new dims.
        let s_after = bb_term_take_snapshot(term);
        assert!(!s_after.is_null());
        assert_eq!((*s_after).cols, 132);
        assert_eq!((*s_after).rows, 40);
        assert_eq!((*s_after).cells_len, 132 * 40);

        bb_snap_release(s_after);
        bb_snap_release(s_before);
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
    assert_eq!(
        count_kind(&events, BBEventKind::PtyWrite),
        0,
        "resize must not emit PtyWrite"
    );
}

// ---------- 10. quiet event channel --------------------------------

#[test]
fn many_resizes_emit_no_pty_writes_or_fatals() {
    // Cycle through a handful of in-range and clamped resizes. The header
    // says resize doesn't talk back to the PTY (that's the caller's job
    // via TIOCSWINSZ) and the only resize-time event would be a Fatal
    // from a caught panic — neither should ever fire on these inputs.
    let events = with_term(|term| unsafe {
        for (cols, rows) in [
            (80u16, 24u16),
            (132, 40),
            (1, 1),       // floor clamp
            (1001, 1001), // ceiling clamp
            (40, 12),
            (200, 60),
            (2, 1000), // boundary mix
            (1000, 2),
        ] {
            let _ = bb_term_resize2(term, cols, rows);
        }
    });
    assert_eq!(
        count_kind(&events, BBEventKind::PtyWrite),
        0,
        "resize must not synthesize PtyWrite"
    );
    assert_eq!(
        count_kind(&events, BBEventKind::Fatal),
        0,
        "resize must not synthesize Fatal on any documented input"
    );
}

// ---------- 11. starting from a non-default dim --------------------

#[test]
fn resize_down_to_floor_from_larger_initial_dims() {
    // Confirms the clamp logic isn't comparing against the initial
    // (cols, rows) baked into bb_term_new — it's against the universal
    // [2, 1000] envelope.
    let events = with_term_dims(120, 36, |term| unsafe {
        let (pre_cols, pre_rows) = snapshot_dims(term);
        assert_eq!((pre_cols, pre_rows), (120, 36));

        let r = bb_term_resize2(term, 1, 1);
        assert_eq!(r.applied_cols, 2);
        assert_eq!(r.applied_rows, 2);
        assert_ne!(r.clamped, 0);

        let (cols, rows) = snapshot_dims(term);
        assert_eq!((cols, rows), (2, 2));
    });
    assert_eq!(count_kind(&events, BBEventKind::Fatal), 0);
}
