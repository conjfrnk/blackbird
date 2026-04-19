//! Pins `bb_term_current_mode` — the lightweight mode getter used by the
//! Swift host to decide whether to emit focus-event escape sequences on
//! window focus changes. The host only writes `\x1b[I` / `\x1b[O` when
//! mode 1004 is active; otherwise those bytes would parse as `HPA` and
//! move the cursor instead.

use blackbird_core::*;

#[test]
fn focus_in_out_mode_starts_disabled() {
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let mode = bb_term_current_mode(term);
        assert_eq!(mode & bb_mode::FOCUS_IN_OUT, 0);
        bb_term_free(term);
    }
}

#[test]
fn csi_1004_h_enables_focus_in_out() {
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let enable = b"\x1b[?1004h";
        bb_term_input(term, enable.as_ptr(), enable.len());
        let mode = bb_term_current_mode(term);
        assert_ne!(mode & bb_mode::FOCUS_IN_OUT, 0);
        bb_term_free(term);
    }
}

#[test]
fn csi_1004_l_disables_focus_in_out() {
    unsafe {
        let term = bb_term_new(10, 1, 100);
        // Enable then disable.
        let seq = b"\x1b[?1004h\x1b[?1004l";
        bb_term_input(term, seq.as_ptr(), seq.len());
        let mode = bb_term_current_mode(term);
        assert_eq!(mode & bb_mode::FOCUS_IN_OUT, 0);
        bb_term_free(term);
    }
}

#[test]
fn null_term_returns_zero() {
    // Zero is "no modes active" — the correct safe default for callers
    // that would otherwise emit escape bytes blindly.
    unsafe {
        let mode = bb_term_current_mode(std::ptr::null_mut());
        assert_eq!(mode, 0);
    }
}

#[test]
fn other_modes_reported_independently() {
    // FOCUS_IN_OUT is a specific bit within the mode bitfield; pinning
    // the orthogonality prevents a future extract_mode refactor from
    // silently conflating two modes.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let seq = b"\x1b[?1004h\x1b[?1000h"; // focus + X10 mouse
        bb_term_input(term, seq.as_ptr(), seq.len());
        let mode = bb_term_current_mode(term);
        assert_ne!(mode & bb_mode::FOCUS_IN_OUT, 0);
        assert_ne!(mode & bb_mode::MOUSE_REPORT_CLICK, 0);
        bb_term_free(term);
    }
}
