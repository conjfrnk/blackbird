//! Pins the SGR 4:N underline-style plumbing from alacritty through our
//! `cell_flags` to the BBCell the renderer reads.
//!
//! Alacritty 0.26 parses all five CSI 4:N values into distinct bits on
//! `term::cell::Flags`; our job is to mirror them onto the stable
//! `cell_flags` constants so Swift callers don't have to know which
//! alacritty version is underneath.

use blackbird_core::*;

/// Feeds `seq` into a fresh 10x1 terminal + "X" and returns the first cell's
/// flag bitset. One-cell harness keeps the test allocation trivial (10 × 1 ×
/// BBCell ≈ 160 bytes).
unsafe fn feed_one(seq: &[u8]) -> u16 {
    let term = bb_term_new(10, 1, 100);
    assert!(!term.is_null());
    bb_term_input(term, seq.as_ptr(), seq.len());
    let snap = bb_term_take_snapshot(term);
    assert!(!snap.is_null());
    let flags = (*(*snap).cells).flags;
    bb_snap_release(snap);
    bb_term_free(term);
    flags
}

#[test]
fn csi_4_sets_plain_underline() {
    // `\x1b[4m` = single underline. Already covered elsewhere but repeated
    // here so a future refactor of cell_flags that drops UNDERLINE fails in
    // the same file as the rest of the underline style tests.
    let flags = unsafe { feed_one(b"\x1b[4mX") };
    assert_ne!(flags & cell_flags::UNDERLINE, 0);
    assert_eq!(flags & cell_flags::UNDERLINE_DOUBLE, 0);
    assert_eq!(flags & cell_flags::UNDERCURL, 0);
}

#[test]
fn csi_4_colon_2_sets_double_underline() {
    // Modern double-underline is `\x1b[4:2m` (sub-parameter on CSI 4). The
    // legacy `\x1b[21m` is interpreted by vte / alacritty as "cancel bold",
    // NOT double-underline — matching xterm's 2010s ECMA-48 reading. If a
    // future alacritty bump flips the mapping, this test reminds us.
    let flags = unsafe { feed_one(b"\x1b[4:2mX") };
    assert_ne!(flags & cell_flags::UNDERLINE_DOUBLE, 0);
}

#[test]
fn csi_4_colon_3_sets_undercurl() {
    // `\x1b[4:3m` — the modern CSI parameter-sub-argument syntax for
    // undercurl. Neovim LSP diagnostics rely on this for squigglies.
    let flags = unsafe { feed_one(b"\x1b[4:3mX") };
    assert_ne!(flags & cell_flags::UNDERCURL, 0);
}

#[test]
fn csi_4_colon_4_sets_dotted_underline() {
    let flags = unsafe { feed_one(b"\x1b[4:4mX") };
    assert_ne!(flags & cell_flags::UNDERLINE_DOTTED, 0);
}

#[test]
fn csi_4_colon_5_sets_dashed_underline() {
    let flags = unsafe { feed_one(b"\x1b[4:5mX") };
    assert_ne!(flags & cell_flags::UNDERLINE_DASHED, 0);
}

#[test]
fn csi_24_clears_all_underlines() {
    // `\x1b[24m` resets every underline variant in one shot. Pinned so a
    // future refactor that forgets to clear one of the four bits fails
    // audibly.
    let mask = cell_flags::UNDERLINE
        | cell_flags::UNDERLINE_DOUBLE
        | cell_flags::UNDERCURL
        | cell_flags::UNDERLINE_DOTTED
        | cell_flags::UNDERLINE_DASHED;
    // First set undercurl, then clear via CSI 24.
    let flags = unsafe { feed_one(b"\x1b[4:3m\x1b[24mX") };
    assert_eq!(flags & mask, 0);
}

#[test]
fn styles_are_mutually_exclusive_within_one_cell() {
    // Applying a new underline style overrides the previous one — alacritty
    // treats them as a single style dimension (they share `ALL_UNDERLINES`).
    // Pin that only the most-recent style survives, never two at once on the
    // same glyph.
    let flags = unsafe { feed_one(b"\x1b[4m\x1b[4:3mX") };
    assert_ne!(flags & cell_flags::UNDERCURL, 0);
    assert_eq!(flags & cell_flags::UNDERLINE, 0);
    assert_eq!(flags & cell_flags::UNDERLINE_DOUBLE, 0);
    assert_eq!(flags & cell_flags::UNDERLINE_DOTTED, 0);
    assert_eq!(flags & cell_flags::UNDERLINE_DASHED, 0);
}
