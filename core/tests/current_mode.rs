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

// ---------------------------------------------------------------------------
// Mouse mode coverage — regression for rust-tests F27.
//
// Swift's event encoder consults these bits to decide which mouse
// protocol bytes to emit on click/motion. Four distinct modes and three
// protocol selectors each correspond to a TermMode bit:
//
//   ?1000 — MOUSE_REPORT_CLICK (X10: report button press/release)
//   ?1002 — MOUSE_DRAG         (button-motion: report while button held)
//   ?1003 — MOUSE_MOTION       (any-motion: report with no buttons)
//   ?1006 — SGR_MOUSE          (SGR-format protocol selector)
//
// ?1005 and ?1015 are alternate encoding selectors (UTF-8 and URXVT) —
// alacritty collapses them into the standard protocol space, so our
// FFI doesn't expose distinct bits; the F27 suggestion to "one test per
// mouse mode" applies to the bits we surface.
// ---------------------------------------------------------------------------

#[test]
fn csi_1000_toggles_mouse_report_click_bit() {
    // Regression for rust-tests F27. X10 mouse (button press/release).
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let enable = b"\x1b[?1000h";
        bb_term_input(term, enable.as_ptr(), enable.len());
        assert_ne!(
            bb_term_current_mode(term) & bb_mode::MOUSE_REPORT_CLICK,
            0,
            "1000h must set MOUSE_REPORT_CLICK"
        );
        let disable = b"\x1b[?1000l";
        bb_term_input(term, disable.as_ptr(), disable.len());
        assert_eq!(
            bb_term_current_mode(term) & bb_mode::MOUSE_REPORT_CLICK,
            0,
            "1000l must clear MOUSE_REPORT_CLICK"
        );
        bb_term_free(term);
    }
}

#[test]
fn csi_1002_toggles_mouse_drag_bit() {
    // Regression for rust-tests F27. Button-event mouse (drag reports).
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let enable = b"\x1b[?1002h";
        bb_term_input(term, enable.as_ptr(), enable.len());
        assert_ne!(
            bb_term_current_mode(term) & bb_mode::MOUSE_DRAG,
            0,
            "1002h must set MOUSE_DRAG"
        );
        let disable = b"\x1b[?1002l";
        bb_term_input(term, disable.as_ptr(), disable.len());
        assert_eq!(
            bb_term_current_mode(term) & bb_mode::MOUSE_DRAG,
            0,
            "1002l must clear MOUSE_DRAG"
        );
        bb_term_free(term);
    }
}

#[test]
fn csi_1003_toggles_mouse_motion_bit() {
    // Regression for rust-tests F27. Any-event mouse (motion without
    // button held).
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let enable = b"\x1b[?1003h";
        bb_term_input(term, enable.as_ptr(), enable.len());
        assert_ne!(
            bb_term_current_mode(term) & bb_mode::MOUSE_MOTION,
            0,
            "1003h must set MOUSE_MOTION"
        );
        let disable = b"\x1b[?1003l";
        bb_term_input(term, disable.as_ptr(), disable.len());
        assert_eq!(
            bb_term_current_mode(term) & bb_mode::MOUSE_MOTION,
            0,
            "1003l must clear MOUSE_MOTION"
        );
        bb_term_free(term);
    }
}

#[test]
fn csi_1006_toggles_sgr_mouse_bit() {
    // Regression for rust-tests F27. SGR mouse protocol selector —
    // tmux/vim/mc use this to get negotiation-free extended coords.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let enable = b"\x1b[?1006h";
        bb_term_input(term, enable.as_ptr(), enable.len());
        assert_ne!(
            bb_term_current_mode(term) & bb_mode::SGR_MOUSE,
            0,
            "1006h must set SGR_MOUSE"
        );
        let disable = b"\x1b[?1006l";
        bb_term_input(term, disable.as_ptr(), disable.len());
        assert_eq!(
            bb_term_current_mode(term) & bb_mode::SGR_MOUSE,
            0,
            "1006l must clear SGR_MOUSE"
        );
        bb_term_free(term);
    }
}

#[test]
fn mouse_protocols_are_mutually_exclusive() {
    // Regression for rust-tests F27. alacritty treats 1000/1002/1003 as
    // mutually exclusive (one "mouse protocol" slot) — enabling 1002
    // after 1000 must clear the 1000 bit. Pin that invariant; a
    // regression that stopped clearing would leave Swift's encoder
    // unsure which coordinate-format to emit.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let seq = b"\x1b[?1000h\x1b[?1002h";
        bb_term_input(term, seq.as_ptr(), seq.len());
        let mode = bb_term_current_mode(term);
        assert_eq!(
            mode & bb_mode::MOUSE_REPORT_CLICK,
            0,
            "1002h must clear the MOUSE_REPORT_CLICK bit (mutually exclusive)"
        );
        assert_ne!(mode & bb_mode::MOUSE_DRAG, 0, "1002h must set MOUSE_DRAG");
        bb_term_free(term);
    }
}

#[test]
fn sgr_mouse_is_orthogonal_to_mouse_protocol_bits() {
    // Regression for rust-tests F27. SGR_MOUSE (?1006) is an ENCODING
    // selector — callers enable it alongside one of 1000/1002/1003 to
    // switch from legacy x/y-byte encoding to CSI-parameter encoding.
    // It must be independent of the protocol-slot bits.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let seq = b"\x1b[?1002h\x1b[?1006h";
        bb_term_input(term, seq.as_ptr(), seq.len());
        let mode = bb_term_current_mode(term);
        assert_ne!(
            mode & bb_mode::MOUSE_DRAG,
            0,
            "MOUSE_DRAG must remain set after enabling SGR mouse"
        );
        assert_ne!(
            mode & bb_mode::SGR_MOUSE,
            0,
            "1006h must set SGR_MOUSE alongside the protocol bit"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Bracketed paste — regression for rust-tests F28.
//
// Bracketed paste is the Blackbird host's primary defence against
// command-injection-via-paste. The Swift side reads this bit to decide
// whether to wrap pasted text in `\x1b[200~` / `\x1b[201~`. That bit
// reaches Swift through `bb_term_current_mode` / snapshot `mode` field
// and had no direct test before this file; the coverage gap was flagged
// in the audit as F28 (medium).
// ---------------------------------------------------------------------------

#[test]
fn csi_2004_toggles_bracketed_paste_bit() {
    // Regression for rust-tests F28.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        assert_eq!(
            bb_term_current_mode(term) & bb_mode::BRACKETED_PASTE,
            0,
            "BRACKETED_PASTE starts disabled on a fresh term"
        );

        let enable = b"\x1b[?2004h";
        bb_term_input(term, enable.as_ptr(), enable.len());
        assert_ne!(
            bb_term_current_mode(term) & bb_mode::BRACKETED_PASTE,
            0,
            "2004h must set BRACKETED_PASTE"
        );

        let disable = b"\x1b[?2004l";
        bb_term_input(term, disable.as_ptr(), disable.len());
        assert_eq!(
            bb_term_current_mode(term) & bb_mode::BRACKETED_PASTE,
            0,
            "2004l must clear BRACKETED_PASTE"
        );
        bb_term_free(term);
    }
}
