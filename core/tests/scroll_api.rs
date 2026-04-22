//! Regression for rust-tests F25: `bb_term_scroll` and
//! `bb_term_scroll_to_bottom` had no integration test coverage. Both are
//! part of the viewport control surface the Swift host uses to navigate
//! scrollback on wheel scrolls / keystrokes. Without these tests, a
//! regression that silently failed to apply a scroll delta or failed to
//! snap back to the live grid would surface only as a UX bug in the
//! shipped app.
//!
//! Coverage pinned below:
//!   - scroll(-N) with N lines of scrollback moves the viewport up
//!   - scroll_to_bottom after scroll-up returns the viewport to the
//!     live grid (display_offset == 0)
//!   - scroll(0) is a no-op
//!   - scroll(i32::MIN) and scroll(i32::MAX) clamp gracefully (no trap)
//!   - scroll on a brand-new term (no scrollback) is a no-op

use blackbird_core as bc;

/// Set up a term with `rows` visible rows and enough scrollback to hold
/// `scrollback_lines` lines.  Feed `seed_lines` distinct lines (ASCII)
/// so we can distinguish live-grid content from scrollback content.
unsafe fn new_seeded_term(
    cols: u16,
    rows: u16,
    scrollback_lines: u32,
    seed_lines: usize,
) -> *mut bc::BBTerm {
    let term = bc::bb_term_new(cols, rows, scrollback_lines);
    assert!(!term.is_null());
    for i in 0..seed_lines {
        // Write a distinct line. We use 4-char prefix so row R looks
        // like `R000\n`, `R001\n`, ..., and we can check content.
        let line = format!("R{:03}\n", i);
        bc::bb_term_input(term, line.as_ptr(), line.len());
    }
    term
}

fn display_offset(term: *mut bc::BBTerm) -> u16 {
    unsafe {
        let snap = bc::bb_term_take_snapshot(term);
        let off = (*snap).display_offset;
        bc::bb_snap_release(snap);
        off
    }
}

#[test]
fn scroll_up_moves_viewport_into_scrollback() {
    // Regression for rust-tests F25. Seed 30 lines into a 10-row grid
    // with ample scrollback. After scrolling up by 5 lines (positive delta
    // means "show older content" per the FFI doc), `display_offset` must
    // reflect the scroll — i.e. > 0.
    unsafe {
        let term = new_seeded_term(20, 10, 1_000, 30);
        assert_eq!(display_offset(term), 0, "fresh term starts at the bottom");
        bc::bb_term_scroll(term, 5);
        let off = display_offset(term);
        assert!(
            off >= 1,
            "scroll(5) must move viewport into scrollback (display_offset > 0); got {off}"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn scroll_to_bottom_pins_viewport_to_live_grid() {
    // Regression for rust-tests F25. Seed content, scroll up, then call
    // scroll_to_bottom: display_offset must return to 0.
    unsafe {
        let term = new_seeded_term(20, 10, 1_000, 30);
        bc::bb_term_scroll(term, 10);
        let off_after_scroll = display_offset(term);
        assert!(
            off_after_scroll > 0,
            "precondition: scroll must have moved the viewport up; got {off_after_scroll}"
        );
        bc::bb_term_scroll_to_bottom(term);
        let off_after_bottom = display_offset(term);
        assert_eq!(
            off_after_bottom, 0,
            "scroll_to_bottom must pin display_offset=0; got {off_after_bottom}"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn scroll_zero_delta_is_noop() {
    // Regression for rust-tests F25. scroll(0) on any state must not
    // change display_offset.
    unsafe {
        let term = new_seeded_term(20, 10, 1_000, 30);
        bc::bb_term_scroll(term, 3);
        let before = display_offset(term);
        bc::bb_term_scroll(term, 0);
        let after = display_offset(term);
        assert_eq!(
            before, after,
            "scroll(0) must be a no-op; before={before} after={after}"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn scroll_on_fresh_term_is_safe_noop() {
    // Regression for rust-tests F25. A new term has no scrollback; any
    // scroll(+N) call must not crash and must leave display_offset at 0
    // (alacritty clamps scroll deltas against available scrollback).
    unsafe {
        let term = bc::bb_term_new(20, 10, 1_000);
        assert!(!term.is_null());
        bc::bb_term_scroll(term, 100);
        let off = display_offset(term);
        assert_eq!(
            off, 0,
            "scroll on empty scrollback must leave display_offset=0; got {off}"
        );
        bc::bb_term_scroll_to_bottom(term);
        assert_eq!(display_offset(term), 0);
        bc::bb_term_free(term);
    }
}

#[test]
fn scroll_extreme_deltas_clamp_and_do_not_trap() {
    // Regression for rust-tests F25. i32::MIN and i32::MAX are the
    // documented extremes; Swift's CGEventScroll can deliver absurd
    // deltas if the input device misbehaves. The FFI contract is "no
    // trap, no crash" — alacritty's Scroll::Delta handling clamps the
    // viewport to [0, history_size].
    unsafe {
        let term = new_seeded_term(20, 10, 1_000, 30);

        // i32::MAX: scroll as far up (into scrollback) as possible. Must
        // NOT trap; display_offset is capped by the available history.
        bc::bb_term_scroll(term, i32::MAX);
        let off_max = display_offset(term);
        // The cap depends on how much scrollback the seed loop produced;
        // it must be bounded by u16 range by construction.
        let _ = off_max;

        // i32::MIN: scroll as far down (past live bottom). Must clamp to 0.
        bc::bb_term_scroll(term, i32::MIN);
        let off_min = display_offset(term);
        assert_eq!(
            off_min, 0,
            "scroll(i32::MIN) must clamp to the bottom (display_offset=0); got {off_min}"
        );

        bc::bb_term_free(term);
    }
}

#[test]
fn scroll_with_null_term_is_safe() {
    // Null safety — same contract as every other guarded FFI.
    unsafe {
        bc::bb_term_scroll(std::ptr::null_mut(), -1);
        bc::bb_term_scroll(std::ptr::null_mut(), 0);
        bc::bb_term_scroll(std::ptr::null_mut(), i32::MAX);
        bc::bb_term_scroll_to_bottom(std::ptr::null_mut());
    }
}
