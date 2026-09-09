//! Blind behaviour tests for the two mode bits added in v0.8.1, written
//! from the spec without sight of the implementation:
//!
//!   - `ALTERNATE_SCROLL` (DEC 1007, bit 17): SET by default (alacritty
//!     enables 1007 out of the box), cleared by `CSI ? 1007 l`, set again
//!     by `CSI ? 1007 h`.
//!   - `UTF8_MOUSE` (DEC 1005, bit 18): clear by default, set by
//!     `CSI ? 1005 h`, cleared by `CSI ? 1005 l`.
//!
//! Both are read through `BBSnap.mode`, the field the Swift host reads,
//! and cross-checked against `bb_term_current_mode` so the two getters
//! cannot drift.
//!
//! Pre-flight: every test owns one 10×3 BBTerm with a 16-line scrollback
//! (< 50 KiB). No I/O, no sleeps, < 10 ms per test.

use blackbird_core::*;

const ALTERNATE_SCROLL_BIT: u32 = 1 << 17;
const UTF8_MOUSE_BIT: u32 = 1 << 18;

unsafe fn feed(term: *mut BBTerm, bytes: &[u8]) {
    bb_term_input(term, bytes.as_ptr(), bytes.len());
}

unsafe fn snap_mode(term: *mut BBTerm) -> u32 {
    let snap = bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
    let m = (*snap).mode;
    bb_snap_release(snap);
    m
}

unsafe fn new_term() -> *mut BBTerm {
    let term = bb_term_new(10, 3, 16);
    assert!(!term.is_null(), "bb_term_new returned null");
    term
}

#[test]
fn bb_mode_constants_pin_the_documented_bits() {
    assert_eq!(bb_mode::ALTERNATE_SCROLL, ALTERNATE_SCROLL_BIT);
    assert_eq!(bb_mode::UTF8_MOUSE, UTF8_MOUSE_BIT);
    assert_ne!(bb_mode::ALTERNATE_SCROLL, bb_mode::UTF8_MOUSE);
    // Neither collides with a documented lower bit.
    for existing in [
        bb_mode::ALT_SCREEN,
        bb_mode::MOUSE_REPORT_CLICK,
        bb_mode::MOUSE_MOTION,
        bb_mode::MOUSE_DRAG,
        bb_mode::FOCUS_IN_OUT,
    ] {
        assert_eq!(existing & ALTERNATE_SCROLL_BIT, 0);
        assert_eq!(existing & UTF8_MOUSE_BIT, 0);
    }
}

#[test]
fn alternate_scroll_is_set_on_a_fresh_terminal() {
    unsafe {
        let term = new_term();
        let m = snap_mode(term);
        assert_ne!(
            m & ALTERNATE_SCROLL_BIT,
            0,
            "DEC 1007 must be on by default; snapshot.mode = {m:#x}"
        );
        assert_ne!(bb_term_current_mode(term) & ALTERNATE_SCROLL_BIT, 0);
        bb_term_free(term);
    }
}

#[test]
fn csi_1007_l_clears_alternate_scroll() {
    unsafe {
        let term = new_term();
        feed(term, b"\x1b[?1007l");
        let m = snap_mode(term);
        assert_eq!(
            m & ALTERNATE_SCROLL_BIT,
            0,
            "CSI ? 1007 l must clear ALTERNATE_SCROLL; snapshot.mode = {m:#x}"
        );
        assert_eq!(bb_term_current_mode(term) & ALTERNATE_SCROLL_BIT, 0);
        bb_term_free(term);
    }
}

#[test]
fn csi_1007_h_sets_alternate_scroll_again() {
    unsafe {
        let term = new_term();
        feed(term, b"\x1b[?1007l");
        assert_eq!(snap_mode(term) & ALTERNATE_SCROLL_BIT, 0, "precondition");
        feed(term, b"\x1b[?1007h");
        let m = snap_mode(term);
        assert_ne!(
            m & ALTERNATE_SCROLL_BIT,
            0,
            "CSI ? 1007 h must set ALTERNATE_SCROLL; snapshot.mode = {m:#x}"
        );
        bb_term_free(term);
    }
}

#[test]
fn alternate_scroll_survives_alt_screen_entry_and_exit() {
    unsafe {
        let term = new_term();
        feed(term, b"\x1b[?1049h");
        let m = snap_mode(term);
        assert_ne!(m & bb_mode::ALT_SCREEN, 0, "precondition: alt screen on");
        assert_ne!(
            m & ALTERNATE_SCROLL_BIT,
            0,
            "entering the alt screen must not touch 1007"
        );
        feed(term, b"\x1b[?1049l");
        let m = snap_mode(term);
        assert_eq!(m & bb_mode::ALT_SCREEN, 0, "precondition: alt screen off");
        assert_ne!(
            m & ALTERNATE_SCROLL_BIT,
            0,
            "leaving the alt screen must not touch 1007"
        );
        bb_term_free(term);
    }
}

#[test]
fn alternate_scroll_off_is_independent_of_alt_screen() {
    // A TUI that opts out of 1007 and then enters the alt screen must
    // observe 1007 still off — the two bits are orthogonal.
    unsafe {
        let term = new_term();
        feed(term, b"\x1b[?1007l\x1b[?1049h");
        let m = snap_mode(term);
        assert_ne!(m & bb_mode::ALT_SCREEN, 0);
        assert_eq!(m & ALTERNATE_SCROLL_BIT, 0);
        bb_term_free(term);
    }
}

#[test]
fn utf8_mouse_is_clear_on_a_fresh_terminal() {
    unsafe {
        let term = new_term();
        let m = snap_mode(term);
        assert_eq!(
            m & UTF8_MOUSE_BIT,
            0,
            "DEC 1005 must be off by default; snapshot.mode = {m:#x}"
        );
        assert_eq!(bb_term_current_mode(term) & UTF8_MOUSE_BIT, 0);
        bb_term_free(term);
    }
}

#[test]
fn csi_1005_h_sets_utf8_mouse() {
    unsafe {
        let term = new_term();
        feed(term, b"\x1b[?1005h");
        let m = snap_mode(term);
        assert_ne!(
            m & UTF8_MOUSE_BIT,
            0,
            "CSI ? 1005 h must set UTF8_MOUSE; snapshot.mode = {m:#x}"
        );
        assert_ne!(bb_term_current_mode(term) & UTF8_MOUSE_BIT, 0);
        bb_term_free(term);
    }
}

#[test]
fn csi_1005_l_clears_utf8_mouse() {
    unsafe {
        let term = new_term();
        feed(term, b"\x1b[?1005h\x1b[?1005l");
        let m = snap_mode(term);
        assert_eq!(
            m & UTF8_MOUSE_BIT,
            0,
            "CSI ? 1005 l must clear UTF8_MOUSE; snapshot.mode = {m:#x}"
        );
        bb_term_free(term);
    }
}

#[test]
fn utf8_mouse_and_alternate_scroll_are_orthogonal() {
    unsafe {
        let term = new_term();
        // 1005 on, 1007 off: exactly one of the two bits set.
        feed(term, b"\x1b[?1005h\x1b[?1007l");
        let m = snap_mode(term);
        assert_ne!(m & UTF8_MOUSE_BIT, 0);
        assert_eq!(m & ALTERNATE_SCROLL_BIT, 0);
        // Flip both.
        feed(term, b"\x1b[?1005l\x1b[?1007h");
        let m = snap_mode(term);
        assert_eq!(m & UTF8_MOUSE_BIT, 0);
        assert_ne!(m & ALTERNATE_SCROLL_BIT, 0);
        bb_term_free(term);
    }
}

#[test]
fn mode_bits_survive_ffi_fragmentation() {
    // The DECSET sequence split byte-by-byte across bb_term_input calls
    // must still toggle the bits.
    unsafe {
        let term = new_term();
        for b in b"\x1b[?1007l\x1b[?1005h" {
            feed(term, std::slice::from_ref(b));
        }
        let m = snap_mode(term);
        assert_eq!(m & ALTERNATE_SCROLL_BIT, 0);
        assert_ne!(m & UTF8_MOUSE_BIT, 0);
        bb_term_free(term);
    }
}
