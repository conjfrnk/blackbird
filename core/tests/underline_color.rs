//! Pins CSI 58 colored-underline extraction. alacritty 0.26 parses
//! `\x1b[58:2::R:G:B m` into its cell's `Option<Color>` extra; our FFI
//! flattens it to a u32 with `UNDERLINE_COLOR_UNSET` sentinel for the
//! None case.

use blackbird_core::*;

unsafe fn feed_one(seq: &[u8]) -> (u16, u32) {
    let term = bb_term_new(10, 1, 100);
    bb_term_input(term, seq.as_ptr(), seq.len());
    let snap = bb_term_take_snapshot(term);
    let cell = *(*snap).cells;
    bb_snap_release(snap);
    bb_term_free(term);
    (cell.flags, cell.underline_color)
}

#[test]
fn absent_underline_color_is_unset_sentinel() {
    // Plain underline with no CSI 58 → shader must fall back to fg, which
    // we signal via the sentinel. Catches a regression where the field is
    // populated with stale cursor-template state.
    let (flags, color) = unsafe { feed_one(b"\x1b[4mX") };
    assert_ne!(flags & cell_flags::UNDERLINE, 0);
    assert_eq!(color, UNDERLINE_COLOR_UNSET);
}

#[test]
fn csi_58_2_sets_rgb_underline_color() {
    // `\x1b[58:2::R:G:B m` — the colon-subparam form. alacritty parses
    // `58` with sub-params `[2, _, R, G, B]` as direct-RGB underline.
    let (flags, color) = unsafe { feed_one(b"\x1b[4m\x1b[58:2::255:128:64mX") };
    assert_ne!(flags & cell_flags::UNDERLINE, 0);
    assert_eq!(color & 0x00FF_FFFF, 0x00FF_8040);
}

#[test]
fn csi_59_clears_underline_color() {
    // `\x1b[59m` resets back to default. Subsequent cells should report
    // the unset sentinel again.
    let (flags, color) = unsafe { feed_one(b"\x1b[4m\x1b[58:2::255:0:0m\x1b[59mX") };
    assert_ne!(flags & cell_flags::UNDERLINE, 0);
    assert_eq!(color, UNDERLINE_COLOR_UNSET);
}

#[test]
fn csi_58_5_indexed_color_resolves_through_palette() {
    // `\x1b[58:5:Nm` — indexed 256-color form. alacritty resolves the
    // index against its palette; we translate via `color_to_rgb`. Index
    // 196 = bright red in the default xterm palette.
    let (flags, color) = unsafe { feed_one(b"\x1b[4m\x1b[58:5:196mX") };
    assert_ne!(flags & cell_flags::UNDERLINE, 0);
    // Default palette 196 is 0xFF0000 per xterm 256-color cube math
    // (idx 196 = base 16 + 36*5 + 6*0 + 0 = (5,0,0) → (255,0,0)).
    assert_eq!(color & 0x00FF_FFFF, 0x00FF_0000);
}

#[test]
fn underline_color_independent_of_fg() {
    // The headline use case: LSP squigglies that are red/yellow while the
    // surrounding text stays fg-colored. A regression where fg bled into
    // underline_color would be silently wrong (red text with red squiggles
    // looks fine in isolation) — pin that they're distinct.
    let (_flags, color) = unsafe { feed_one(b"\x1b[32m\x1b[4:3m\x1b[58:2::255:0:0mA") };
    // fg is green (set by [32m); underline is explicitly red. Underline
    // field must carry red, NOT green.
    assert_eq!(color & 0x00FF_FFFF, 0x00FF_0000);
}
