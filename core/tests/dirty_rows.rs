//! Pins the damage-tracking FFI. alacritty accumulates per-row damage as
//! input is processed; `bb_term_take_snapshot` drains and exposes it, so
//! the renderer can short-circuit full buildInstances iteration when only
//! a handful of rows actually changed.

use blackbird_core::*;

unsafe fn new_term(cols: u16, rows: u16) -> *mut BBTerm {
    bb_term_new(cols, rows, 100)
}

#[test]
fn first_snapshot_after_new_is_full_damage() {
    // A freshly-created term has never been drawn; every row is dirty
    // from the renderer's perspective. Full damage is the safe default
    // so we don't leak whatever the GPU drawable carried in from its
    // previous owner.
    unsafe {
        let term = new_term(10, 3);
        let snap = bb_term_take_snapshot(term);
        assert_eq!(bb_snap_damage_is_full(snap), 1);
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn second_snapshot_with_no_input_has_empty_damage() {
    // Regression for rust-tests F4. Take two snapshots back-to-back with no
    // input between. The first consumes+resets damage; the second should
    // report nothing damaged. We tolerate the cursor row being re-reported
    // (alacritty damages the cursor cell on every damage() call to cover
    // an implicit cursor move), but any *other* row being flagged indicates
    // the per-row damage reset missed a row — exactly the bug this test
    // exists to catch.
    unsafe {
        let term = new_term(10, 3);
        let s1 = bb_term_take_snapshot(term);
        bb_snap_release(s1);
        let s2 = bb_term_take_snapshot(term);
        // After reset, damage is partial-but-empty (not "full").
        let full = bb_snap_damage_is_full(s2);
        assert_eq!(
            full, 0,
            "second snapshot with no input must NOT report full damage"
        );
        let mut buf = [0u16; 16];
        let n = bb_snap_damage_rows(s2, buf.as_mut_ptr(), buf.len());
        // At most the cursor row is damaged; enforce that shape explicitly.
        assert!(n <= 1, "expected ≤1 damaged row after reset, got {n}");
        if n == 1 {
            // Pin the tolerance: the sole damaged row must be the cursor
            // row. A stuck damage flag for some non-cursor row now trips
            // this assertion instead of passing silently.
            let cursor_row = (*s2).cursor_row;
            assert_eq!(
                buf[0], cursor_row,
                "only the cursor row may be damaged post-reset; got row {} but cursor is at {}",
                buf[0], cursor_row
            );
        }
        bb_snap_release(s2);
        bb_term_free(term);
    }
}

#[test]
fn writing_to_row_zero_damages_row_zero() {
    // Regression for rust-tests F5. A 2-char write into row 0 must damage
    // exactly row 0 (plus at most the cursor row). A regression that flooded
    // damage to every row would still satisfy an `n >= 1` lower bound, so
    // pin the upper bound too: at most 2 distinct rows (row 0 + cursor) can
    // be flagged for a single 2-char write into a freshly-drained grid.
    unsafe {
        let term = new_term(10, 4);
        // Drain the initial full-damage state first.
        let s0 = bb_term_take_snapshot(term);
        bb_snap_release(s0);
        // Now write only to row 0.
        bb_term_input(term, b"HI".as_ptr(), 2);
        let s1 = bb_term_take_snapshot(term);
        assert_eq!(
            bb_snap_damage_is_full(s1),
            0,
            "a 2-char write should not produce full damage"
        );
        let mut buf = [0u16; 16];
        let n = bb_snap_damage_rows(s1, buf.as_mut_ptr(), buf.len());
        assert!(n >= 1, "expected at least 1 damaged row, got {n}");
        // Upper bound: row 0 + cursor row (same row after a 2-char write,
        // but alacritty may report them independently). Anything beyond 2
        // means a regression spread damage to unrelated rows.
        assert!(
            n <= 2,
            "expected ≤2 damaged rows for a 2-char write, got {n}: {:?}",
            &buf[..n]
        );
        assert!(
            (0..n).any(|i| buf[i] == 0),
            "expected row 0 in damage set, got {:?}",
            &buf[..n]
        );
        // Every reported row must be either row 0 (the write target) or the
        // cursor row (alacritty's damage-cursor-cell policy). No other rows.
        let cursor_row = (*s1).cursor_row;
        for i in 0..n {
            let r = buf[i];
            assert!(
                r == 0 || r == cursor_row,
                "unexpected row {r} in damage set (cursor row {cursor_row}); \
                 only row 0 and the cursor row may be damaged: {:?}",
                &buf[..n]
            );
        }
        bb_snap_release(s1);
        bb_term_free(term);
    }
}

#[test]
fn scroll_reports_full_damage() {
    unsafe {
        let term = new_term(10, 2);
        // Drain initial damage.
        let s0 = bb_term_take_snapshot(term);
        bb_snap_release(s0);
        // Scrolling (cursor at last line + newline) triggers full damage
        // in alacritty's model because every visible row shifts content.
        bb_term_input(term, b"A\r\nB\r\nC\r\nD".as_ptr(), 10);
        let s1 = bb_term_take_snapshot(term);
        assert_eq!(
            bb_snap_damage_is_full(s1),
            1,
            "scroll that shifts every row should report full damage"
        );
        bb_snap_release(s1);
        bb_term_free(term);
    }
}

#[test]
fn null_inputs_are_safe() {
    unsafe {
        let mut buf = [0u16; 4];
        // Null snap returns 0 rows, full=1 (redraw-everything default).
        assert_eq!(
            bb_snap_damage_rows(std::ptr::null(), buf.as_mut_ptr(), 4),
            0
        );
        assert_eq!(bb_snap_damage_is_full(std::ptr::null()), 1);
    }
}

#[test]
fn null_out_buffer_acts_as_length_probe() {
    // New contract (rust-core-4 F2): `out = null` is a length probe. The
    // first snapshot of a fresh term reports damage_full = true, so the
    // total damaged-rows count is 0 regardless. Take a second snapshot
    // after a tiny write to exercise the partial-damage probe path.
    unsafe {
        let term = new_term(10, 3);
        let s0 = bb_term_take_snapshot(term);
        // damage_full; probe returns 0.
        assert_eq!(bb_snap_damage_rows(s0, std::ptr::null_mut(), 16), 0);
        bb_snap_release(s0);

        bb_term_input(term, b"X".as_ptr(), 1);
        let s1 = bb_term_take_snapshot(term);
        if bb_snap_damage_is_full(s1) == 0 {
            // Probe via null out — returns total damaged row count.
            let probed = bb_snap_damage_rows(s1, std::ptr::null_mut(), 16);
            // Sanity-size an actual write and compare.
            let mut buf = [0u16; 16];
            let written = bb_snap_damage_rows(s1, buf.as_mut_ptr(), buf.len());
            assert_eq!(probed, written);
        }
        bb_snap_release(s1);
        bb_term_free(term);
    }
}

#[test]
fn zero_cap_returns_total_as_length_probe() {
    // New contract: `out_cap = 0` with a non-null `out` still probes total.
    unsafe {
        let term = new_term(10, 3);
        // Force partial damage with a write + drain.
        let s0 = bb_term_take_snapshot(term);
        bb_snap_release(s0);
        bb_term_input(term, b"X".as_ptr(), 1);
        let s1 = bb_term_take_snapshot(term);
        let mut buf = [0u16; 4];
        let total_probe = bb_snap_damage_rows(s1, buf.as_mut_ptr(), 0);
        if bb_snap_damage_is_full(s1) == 0 {
            // buf untouched; return value is the total damaged-rows count.
            let written = bb_snap_damage_rows(s1, buf.as_mut_ptr(), buf.len());
            assert_eq!(total_probe, written);
        }
        bb_snap_release(s1);
        bb_term_free(term);
    }
}

#[test]
fn damage_resets_between_snapshots_with_separate_writes() {
    // Regression for rust-tests F16. The core renderer invariant is that
    // damage *resets* per snapshot rather than accumulating. Without this
    // test a regression where row N's damage persisted past the snapshot
    // that drained it would silently spread stale "dirty" flags forward,
    // and the `writing_to_row_zero` pair above half-implies the reset but
    // never exercises the post-reset-then-write case across two rows.
    //
    // Shape: drain → write row 0 → snap (drains row 0's damage) → write
    // row 3 → snap. The second snapshot's damage must contain row 3 (the
    // new write target) and must NOT contain row 1 (an untouched row
    // between the two writes). Row 0 is tolerated because alacritty damages
    // the row the cursor was on when it left — not an accumulation bug, a
    // cursor-move damage policy. The key accumulation-detecting assertion
    // is the "untouched middle rows not damaged" check.
    unsafe {
        let term = new_term(10, 5);
        // Drain the initial full-damage state.
        let s0 = bb_term_take_snapshot(term);
        bb_snap_release(s0);

        // Write a char into row 0 and snapshot to drain row 0's damage.
        bb_term_input(term, b"A".as_ptr(), 1);
        let s1 = bb_term_take_snapshot(term);
        bb_snap_release(s1);

        // Position cursor to row 3, col 0 (CSI 4;1H — 1-indexed) and write
        // another char. Rows 1 and 2 are untouched between the drains: if
        // damage from row 0's write leaked forward to any of them, the
        // assertion below trips.
        bb_term_input(term, b"\x1b[4;1HB".as_ptr(), 7);
        let s2 = bb_term_take_snapshot(term);
        assert_eq!(
            bb_snap_damage_is_full(s2),
            0,
            "cursor-move + 1-char write must not trigger full damage"
        );
        let mut buf = [0u16; 16];
        let n = bb_snap_damage_rows(s2, buf.as_mut_ptr(), buf.len());
        assert!(
            n >= 1,
            "row 3 write must produce at least 1 damaged row, got {n}"
        );
        let rows = &buf[..n];
        assert!(
            rows.contains(&3),
            "row 3 (the post-drain write target) must be in damage set; got {rows:?}"
        );
        // Rows 1 and 2 were never touched in either phase. If damage is
        // accumulating, either will appear here.
        assert!(
            !rows.contains(&1),
            "row 1 was untouched — damage must not leak from prior writes. Got {rows:?}"
        );
        assert!(
            !rows.contains(&2),
            "row 2 was untouched — damage must not leak from prior writes. Got {rows:?}"
        );
        // Row 4 was also never written; pin it too.
        assert!(
            !rows.contains(&4),
            "row 4 was untouched — damage must not leak from prior writes. Got {rows:?}"
        );
        bb_snap_release(s2);
        bb_term_free(term);
    }
}
