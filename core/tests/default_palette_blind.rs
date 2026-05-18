//! Blind contract tests for the DEFAULT palette resolution path.
//!
//! `bb_term_set_named_color` is the OVERRIDE path. The DEFAULT path —
//! what color is used when no override is in effect — is exercised
//! whenever the input stream sets a foreground/background via SGR
//! sequences (`\x1b[3{0..7}m`, `\x1b[9{0..7}m` for bright, etc.).
//! Those defaults flow through `named_color_rgb` internally and end
//! up in `BBCell::fg` / `BBCell::bg`.
//!
//! Why this file exists: cargo-mutants run on `named_color_rgb`
//! revealed a 10% kill rate — 26 of 29 mutations (every per-color
//! match arm) could be deleted with the rest of the suite unaffected.
//! The OSC 10/11/12 query path tested in `color_ffi_blind.rs` only
//! covers slots 256/257/258 (foreground/background/cursor); the
//! 16 ANSI + 10 dim/bright/aliased arms were unobserved. Closing
//! that gap from the public FFI requires reading `BBCell::fg` /
//! `BBCell::bg` after an SGR sequence + a printable character.
//!
//! The expected RGB values pin alacritty's standard xterm defaults
//! (the `tango`-flavored palette). Any change to those defaults is
//! a deliberate decision worth a test update.

use blackbird_core::*;
use std::ffi::c_void;

unsafe extern "C" fn noop_cb(_ev: BBEvent, _ctx: *mut c_void) {}

fn with_term<F>(body: F)
where
    F: FnOnce(*mut BBTerm),
{
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        assert!(!term.is_null());
        bb_term_set_event_cb(term, Some(noop_cb), std::ptr::null_mut());
        body(term);
        bb_term_free(term);
    }
}

/// Read the fg / bg of cell `(row=0, col=0)` after writing `seq + "A"`.
/// Returns (fg, bg) packed as the FFI exposes them. Skips the leading
/// byte sniff via the snapshot's cells pointer.
unsafe fn fg_bg_at_origin(term: *mut BBTerm, seq: &[u8]) -> (u32, u32) {
    bb_term_input(term, seq.as_ptr(), seq.len());
    let glyph = b"A";
    bb_term_input(term, glyph.as_ptr(), 1);
    let snap = bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "snapshot must succeed");
    let cells_len = (*snap).cells_len;
    assert!(cells_len > 0, "snapshot must expose cells");
    // Cell at (row=0, col=0) is the first BBCell in the flat array.
    let cell = &*(*snap).cells;
    let result = (cell.fg, cell.bg);
    bb_snap_release(snap);
    result
}

/// Extract the 24-bit RGB triplet from however the FFI packs the
/// color word. The header documents `BBCell.fg: uint32_t` without
/// pinning an explicit layout. We mask the low 24 bits and assert
/// the upper 8 bits are 0 — both the expected layout and a
/// canary against an impl that started packing alpha there.
fn rgb_24(packed: u32) -> u32 {
    assert_eq!(
        packed & 0xFF00_0000,
        0,
        "upper 8 bits of cell.fg/.bg must be zero (no alpha); got {:#010x}",
        packed
    );
    packed & 0x00FF_FFFF
}

// ---------------------------------------------------------------
// Default ANSI 16-color palette via SGR 30..=37 / 90..=97
// ---------------------------------------------------------------

#[test]
fn default_fg_black_is_xterm_tango_black() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[30m");
        assert_eq!(rgb_24(fg), 0x000000, "ANSI 30 (Black) default fg");
    });
}

#[test]
fn default_fg_red_is_xterm_tango_red() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[31m");
        assert_eq!(rgb_24(fg), 0xCC0000, "ANSI 31 (Red) default fg");
    });
}

#[test]
fn default_fg_green_is_xterm_tango_green() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[32m");
        assert_eq!(rgb_24(fg), 0x4E9A06, "ANSI 32 (Green) default fg");
    });
}

#[test]
fn default_fg_yellow_is_xterm_tango_yellow() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[33m");
        assert_eq!(rgb_24(fg), 0xC4A000, "ANSI 33 (Yellow) default fg");
    });
}

#[test]
fn default_fg_blue_is_xterm_tango_blue() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[34m");
        assert_eq!(rgb_24(fg), 0x3465A4, "ANSI 34 (Blue) default fg");
    });
}

#[test]
fn default_fg_magenta_is_xterm_tango_magenta() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[35m");
        assert_eq!(rgb_24(fg), 0x75507B, "ANSI 35 (Magenta) default fg");
    });
}

#[test]
fn default_fg_cyan_is_xterm_tango_cyan() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[36m");
        assert_eq!(rgb_24(fg), 0x06989A, "ANSI 36 (Cyan) default fg");
    });
}

#[test]
fn default_fg_white_is_xterm_tango_white() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[37m");
        assert_eq!(rgb_24(fg), 0xD3D7CF, "ANSI 37 (White) default fg");
    });
}

#[test]
fn default_fg_bright_black_is_xterm_tango_bright_black() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[90m");
        assert_eq!(rgb_24(fg), 0x555753, "ANSI 90 (BrightBlack) default fg");
    });
}

#[test]
fn default_fg_bright_red_is_xterm_tango_bright_red() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[91m");
        assert_eq!(rgb_24(fg), 0xEF2929, "ANSI 91 (BrightRed) default fg");
    });
}

#[test]
fn default_fg_bright_green_is_xterm_tango_bright_green() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[92m");
        assert_eq!(rgb_24(fg), 0x8AE234, "ANSI 92 (BrightGreen) default fg");
    });
}

#[test]
fn default_fg_bright_yellow_is_xterm_tango_bright_yellow() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[93m");
        assert_eq!(rgb_24(fg), 0xFCE94F, "ANSI 93 (BrightYellow) default fg");
    });
}

#[test]
fn default_fg_bright_blue_is_xterm_tango_bright_blue() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[94m");
        assert_eq!(rgb_24(fg), 0x729FCF, "ANSI 94 (BrightBlue) default fg");
    });
}

#[test]
fn default_fg_bright_magenta_is_xterm_tango_bright_magenta() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[95m");
        assert_eq!(rgb_24(fg), 0xAD7FA8, "ANSI 95 (BrightMagenta) default fg");
    });
}

#[test]
fn default_fg_bright_cyan_is_xterm_tango_bright_cyan() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[96m");
        assert_eq!(rgb_24(fg), 0x34E2E2, "ANSI 96 (BrightCyan) default fg");
    });
}

#[test]
fn default_fg_bright_white_is_xterm_tango_bright_white() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[97m");
        assert_eq!(rgb_24(fg), 0xEEEEEC, "ANSI 97 (BrightWhite) default fg");
    });
}

// ---------------------------------------------------------------
// Default backgrounds — SGR 40..=47 / 100..=107
// ---------------------------------------------------------------

#[test]
fn default_bg_red_is_xterm_tango_red() {
    with_term(|term| unsafe {
        let (_, bg) = fg_bg_at_origin(term, b"\x1b[41m");
        assert_eq!(rgb_24(bg), 0xCC0000, "ANSI 41 (Red bg) default");
    });
}

#[test]
fn default_bg_bright_white_is_xterm_tango_bright_white() {
    with_term(|term| unsafe {
        let (_, bg) = fg_bg_at_origin(term, b"\x1b[107m");
        assert_eq!(rgb_24(bg), 0xEEEEEC, "ANSI 107 (BrightWhite bg) default");
    });
}

// ---------------------------------------------------------------
// Sanity: fresh terminal has the documented default fg / bg
// (Foreground = light grey 0xEEEEEE; Background = black 0x000000).
// ---------------------------------------------------------------

#[test]
fn fresh_terminal_default_fg_bg_at_origin() {
    with_term(|term| unsafe {
        // No SGR — just write a char.
        let (fg, bg) = fg_bg_at_origin(term, b"");
        assert_eq!(rgb_24(fg), 0xEEEEEE, "fresh-term default fg = light grey");
        assert_eq!(rgb_24(bg), 0x000000, "fresh-term default bg = black");
    });
}
