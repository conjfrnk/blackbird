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
    // Take two snapshots back-to-back with no input between. The first
    // consumes+resets damage; the second should report nothing damaged.
    unsafe {
        let term = new_term(10, 3);
        let s1 = bb_term_take_snapshot(term);
        bb_snap_release(s1);
        let s2 = bb_term_take_snapshot(term);
        // After reset, damage is partial-but-empty (not "full"). Also
        // tolerate cursor-damage on s2 being non-zero — alacritty damages
        // the cursor cell on every damage() call to cover the cursor
        // move that might have happened.
        let full = bb_snap_damage_is_full(s2);
        if full == 0 {
            let mut buf = [0u16; 16];
            let n = bb_snap_damage_rows(s2, buf.as_mut_ptr(), buf.len());
            // At most the cursor row is damaged post-reset; no other rows.
            assert!(n <= 1, "expected ≤1 damaged row after reset, got {n}");
        }
        bb_snap_release(s2);
        bb_term_free(term);
    }
}

#[test]
fn writing_to_row_zero_damages_row_zero() {
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
        assert!(
            (0..n).any(|i| buf[i] == 0),
            "expected row 0 in damage set, got {:?}",
            &buf[..n]
        );
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
