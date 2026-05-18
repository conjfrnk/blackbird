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

// ---------------------------------------------------------------
// 256-color SGR path (Color::Indexed) — `\x1b[38;5;Nm`.
//
// This routes through a separate match arm in `color_to_rgb` that
// the named-SGR tests above don't reach. cargo-mutants reported
// 6 mutations in this arm (the bit-packing shift/OR) as unobserved
// before this section was added.
// ---------------------------------------------------------------

#[test]
fn indexed_color_slot_0_is_black() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;5;0m");
        assert_eq!(rgb_24(fg), 0x000000, "slot 0 in 256-color cube is Black");
    });
}

#[test]
fn indexed_color_slot_1_is_red() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;5;1m");
        assert_eq!(rgb_24(fg), 0xCC0000, "slot 1 in 256-color cube is Red");
    });
}

#[test]
fn indexed_color_slot_15_is_bright_white() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;5;15m");
        assert_eq!(
            rgb_24(fg),
            0xEEEEEC,
            "slot 15 in 256-color cube is BrightWhite"
        );
    });
}

#[test]
fn indexed_color_slot_16_is_color_cube_origin() {
    // Slot 16 in the 256-color palette is (0,0,0) — origin of the 6x6x6
    // color cube. Slot 17 is (0,0,95) — first blue step. Pin both so an
    // off-by-one in the cube math surfaces.
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;5;16m");
        assert_eq!(rgb_24(fg), 0x000000, "slot 16 = cube origin (0,0,0)");
    });
}

#[test]
fn indexed_color_slot_17_is_first_blue_step() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;5;17m");
        assert_eq!(rgb_24(fg), 0x00005F, "slot 17 = first blue step (0,0,95)");
    });
}

#[test]
fn indexed_color_slot_196_is_pure_red_cube_corner() {
    // Slot 196 in the 6x6x6 cube is (5,0,0) — pure red corner.
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;5;196m");
        assert_eq!(
            rgb_24(fg),
            0xFF0000,
            "slot 196 = cube corner (5,0,0) = pure red"
        );
    });
}

#[test]
fn indexed_color_slot_231_is_pure_white_cube_corner() {
    // Slot 231 is the opposite corner of the cube — (5,5,5) = white.
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;5;231m");
        assert_eq!(
            rgb_24(fg),
            0xFFFFFF,
            "slot 231 = cube corner (5,5,5) = pure white"
        );
    });
}

#[test]
fn indexed_color_slot_232_is_first_grayscale_step() {
    // Slots 232..=255 are 24-step grayscale, starting at 0x080808.
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;5;232m");
        assert_eq!(rgb_24(fg), 0x080808, "slot 232 = first grayscale step");
    });
}

#[test]
fn indexed_color_slot_255_is_last_grayscale_step() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;5;255m");
        assert_eq!(rgb_24(fg), 0xEEEEEE, "slot 255 = last grayscale step");
    });
}

// ---------------------------------------------------------------
// Truecolor SGR (`\x1b[38;2;R;G;Bm`) — Color::Spec arm.
//
// Pins the bit-packing math: ((r << 16) | (g << 8) | b). Per-channel
// overlap is impossible by construction (8-bit channels at disjoint
// byte positions), so `|` vs `^` is an equivalent mutant on this
// arm — but `<<` vs `>>` and shift offsets are catchable.
// ---------------------------------------------------------------

#[test]
fn truecolor_fg_red_channel_only() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;2;255;0;0m");
        assert_eq!(rgb_24(fg), 0xFF0000, "truecolor R=255 packed at bits 16-23");
    });
}

#[test]
fn truecolor_fg_green_channel_only() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;2;0;255;0m");
        assert_eq!(rgb_24(fg), 0x00FF00, "truecolor G=255 packed at bits 8-15");
    });
}

#[test]
fn truecolor_fg_blue_channel_only() {
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;2;0;0;255m");
        assert_eq!(rgb_24(fg), 0x0000FF, "truecolor B=255 packed at bits 0-7");
    });
}

#[test]
fn truecolor_fg_distinct_channels_round_trip() {
    // R=0x12, G=0x34, B=0x56 — every byte different so a shift-swap
    // mutation produces a different observable value.
    with_term(|term| unsafe {
        let (fg, _) = fg_bg_at_origin(term, b"\x1b[38;2;18;52;86m");
        assert_eq!(rgb_24(fg), 0x123456, "truecolor 0x12/0x34/0x56 round-trips");
    });
}
