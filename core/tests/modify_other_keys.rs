//! Parser-level pin for xterm `modifyOtherKeys` (`CSI > 4 ; N m`).
//!
//! alacritty_terminal 0.26.0 doesn't parse this sequence — Blackbird's
//! parallel `OscScanner` catches it in `csi_dispatch` and writes the
//! level into `BBTerm.modify_other_keys`. The mode flows out through
//! `bb_term_current_mode` as `bb_mode::MODIFY_OTHER_KEYS` (bit 16) when
//! any non-zero level is active.
//!
//! Covered by these tests:
//!   1. `CSI > 4 ; 2 m` turns the bit on (level 2 — what Emacs asks for).
//!   2. `CSI > 4 ; 1 m` also turns the bit on (we don't expose levels —
//!      the Swift encoder treats both the same).
//!   3. `CSI > 4 ; 0 m` turns the bit off.
//!   4. `CSI > 4 m` (no second param, xterm "reset" form) turns the
//!      bit off.
//!   5. An unrelated `CSI m` (plain SGR reset) doesn't touch the bit.
//!   6. Split-chunk delivery (`\x1b[>4` + `;2m`) still lights the bit.

use std::ffi::c_void;

unsafe fn feed(term: *mut blackbird_core::BBTerm, bytes: &[u8]) {
    blackbird_core::bb_term_input(term, bytes.as_ptr(), bytes.len());
}

unsafe fn current_mode(term: *mut blackbird_core::BBTerm) -> u32 {
    blackbird_core::bb_term_current_mode(term)
}

const MODIFY_OTHER_KEYS: u32 = 1 << 16;

#[test]
fn level_2_sets_the_bit() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 100);
        assert!(!term.is_null());
        assert_eq!(current_mode(term) & MODIFY_OTHER_KEYS, 0, "off by default");
        feed(term, b"\x1b[>4;2m");
        assert_ne!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "CSI > 4 ; 2 m must set MODIFY_OTHER_KEYS"
        );
        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn level_1_also_sets_the_bit() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 100);
        feed(term, b"\x1b[>4;1m");
        assert_ne!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "CSI > 4 ; 1 m must set MODIFY_OTHER_KEYS (levels collapse in the mode bit)"
        );
        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn level_0_clears_the_bit() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 100);
        feed(term, b"\x1b[>4;2m");
        assert_ne!(current_mode(term) & MODIFY_OTHER_KEYS, 0);
        feed(term, b"\x1b[>4;0m");
        assert_eq!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "CSI > 4 ; 0 m must clear MODIFY_OTHER_KEYS"
        );
        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn reset_form_without_second_param_clears_the_bit() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 100);
        feed(term, b"\x1b[>4;2m");
        assert_ne!(current_mode(term) & MODIFY_OTHER_KEYS, 0);
        // xterm manpage: `CSI > 4 m` (no second param) is the reset form.
        feed(term, b"\x1b[>4m");
        assert_eq!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "CSI > 4 m (no second param) must clear MODIFY_OTHER_KEYS"
        );
        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn plain_sgr_reset_does_not_touch_modify_other_keys() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 100);
        feed(term, b"\x1b[>4;2m");
        assert_ne!(current_mode(term) & MODIFY_OTHER_KEYS, 0);
        // `CSI m` with empty intermediates is SGR reset — nothing to do with
        // modifyOtherKeys, must not clear the bit.
        feed(term, b"\x1b[m");
        assert_ne!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "plain CSI m must NOT clear MODIFY_OTHER_KEYS (that's SGR reset, \
             not a modifyOtherKeys reset)"
        );
        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn split_chunk_delivery_still_sets_the_bit() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 100);
        // Emacs pushes the query one PTY read; the reply one at a time.
        // Parser state must survive the chunk boundary.
        feed(term, b"\x1b[>4");
        assert_eq!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "partial sequence shouldn't light the bit"
        );
        feed(term, b";2m");
        assert_ne!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "second half of split CSI > 4 ; 2 m must complete the parse"
        );
        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn modify_other_keys_cleared_by_ris() {
    // Cost: one 20x4 term + a handful of bytes — well under 1 MiB, <10 ms.
    unsafe {
        let term = blackbird_core::bb_term_new(20, 4, 100);
        assert!(!term.is_null());
        feed(term, b"\x1b[>4;2m");
        assert_ne!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "precondition: CSI > 4 ; 2 m must set MODIFY_OTHER_KEYS"
        );
        // RIS (ESC c) is a full terminal reset — it must clear modifyOtherKeys
        // back to 0, exactly like every other mode (xterm semantics).
        feed(term, b"\x1bc");
        assert_eq!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "RIS (ESC c) must clear MODIFY_OTHER_KEYS"
        );
        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn modify_other_keys_level1_cleared_by_ris() {
    // Cost: one 20x4 term + a handful of bytes — well under 1 MiB, <10 ms.
    unsafe {
        let term = blackbird_core::bb_term_new(20, 4, 100);
        assert!(!term.is_null());
        feed(term, b"\x1b[>4;1m");
        assert_ne!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "precondition: CSI > 4 ; 1 m must set MODIFY_OTHER_KEYS"
        );
        // RIS (ESC c) must clear modifyOtherKeys regardless of which level
        // (1 or 2) was active — the mode bit collapses levels.
        feed(term, b"\x1bc");
        assert_eq!(
            current_mode(term) & MODIFY_OTHER_KEYS,
            0,
            "RIS (ESC c) must clear MODIFY_OTHER_KEYS (level 1)"
        );
        blackbird_core::bb_term_free(term);
    }
}

// Silence dead_code on the c_void import — the type isn't referenced
// directly, but kept for parity with other test files that link
// through the same FFI surface.
#[allow(dead_code)]
fn _keep_c_void_in_scope(_: *mut c_void) {}
