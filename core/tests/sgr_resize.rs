//! Regression for rust-tests F26. Before this file, no test exercised
//! SGR attribute survival across `bb_term_resize`. alacritty's reflow
//! implementation has had SGR-loss regressions in previous major
//! versions; catching a recurrence requires a test that writes colored,
//! bold, underlined cells, resizes, and verifies the attributes are
//! still present on the same character's cell.

use blackbird_core as bc;

fn cell_at(snap: *const bc::BBSnap, col: u16, row: u16) -> bc::BBCell {
    unsafe {
        let cols = (*snap).cols;
        let rows = (*snap).rows;
        assert!(
            col < cols && row < rows,
            "cell_at ({col},{row}) out of {cols}x{rows}"
        );
        let idx = (row as usize) * (cols as usize) + col as usize;
        *((*snap).cells.add(idx))
    }
}

#[test]
fn resize_preserves_sgr_attributes() {
    // Regression for rust-tests F26. Feed `"\x1b[1;31mABC"` then resize
    // to different dims. Cell 0 must still carry BOLD and its fg must
    // still be the ANSI "red" colour.
    //
    // Alacritty's palette default for color 1 (red) is `0x00CC0000`
    // (approx); the exact RGB varies by alacritty version, so we pin
    // the weaker invariant: fg is non-default AND it's reddish (R dominant).
    unsafe {
        let term = bc::bb_term_new(20, 5, 100);
        assert!(!term.is_null());

        let input = b"\x1b[1;31mABC\x1b[0m";
        bc::bb_term_input(term, input.as_ptr(), input.len());

        // Baseline: verify the pre-resize cell has BOLD and red-ish fg.
        let snap = bc::bb_term_take_snapshot(term);
        let c0_before = cell_at(snap, 0, 0);
        assert_eq!(c0_before.ch, b'A' as u32);
        assert_ne!(
            c0_before.flags & bc::cell_flags::BOLD,
            0,
            "pre-resize: cell 0 must have BOLD flag; flags=0x{:x}",
            c0_before.flags
        );
        let r_before = (c0_before.fg >> 16) & 0xFF;
        let g_before = (c0_before.fg >> 8) & 0xFF;
        let b_before = c0_before.fg & 0xFF;
        assert!(
            r_before > g_before && r_before > b_before,
            "pre-resize: red fg must have R dominant; got fg=0x{:06x} (R={r_before} G={g_before} B={b_before})",
            c0_before.fg
        );
        bc::bb_snap_release(snap);

        // Resize — grow.
        bc::bb_term_resize(term, 40, 10);
        let snap = bc::bb_term_take_snapshot(term);
        let c0_grow = cell_at(snap, 0, 0);
        assert_eq!(c0_grow.ch, b'A' as u32, "grow: 'A' must still be in cell 0");
        assert_ne!(
            c0_grow.flags & bc::cell_flags::BOLD,
            0,
            "grow: BOLD must survive resize; flags=0x{:x}",
            c0_grow.flags
        );
        assert_eq!(
            c0_grow.fg, c0_before.fg,
            "grow: fg rgb must survive resize; before=0x{:06x} after=0x{:06x}",
            c0_before.fg, c0_grow.fg
        );
        bc::bb_snap_release(snap);

        // Resize — shrink back smaller.
        bc::bb_term_resize(term, 10, 4);
        let snap = bc::bb_term_take_snapshot(term);
        let c0_shrink = cell_at(snap, 0, 0);
        assert_eq!(
            c0_shrink.ch, b'A' as u32,
            "shrink: 'A' must still be in cell 0"
        );
        assert_ne!(
            c0_shrink.flags & bc::cell_flags::BOLD,
            0,
            "shrink: BOLD must survive resize; flags=0x{:x}",
            c0_shrink.flags
        );
        assert_eq!(
            c0_shrink.fg, c0_before.fg,
            "shrink: fg rgb must survive resize; before=0x{:06x} after=0x{:06x}",
            c0_before.fg, c0_shrink.fg
        );
        bc::bb_snap_release(snap);

        bc::bb_term_free(term);
    }
}

#[test]
fn resize_preserves_underline_and_reverse_flags() {
    // Regression for rust-tests F26. Underline and reverse are
    // independent bits; alacritty stores them separately from colour.
    // A reflow that preserved colour but dropped "extra" flag bits
    // would pass the colour test above while still regressing
    // SGR 4 / SGR 7. Pin those bits too.
    unsafe {
        let term = bc::bb_term_new(10, 5, 100);
        // Underline + reverse, then write 'X'.
        let input = b"\x1b[4;7mX\x1b[0m";
        bc::bb_term_input(term, input.as_ptr(), input.len());

        let snap = bc::bb_term_take_snapshot(term);
        let c_before = cell_at(snap, 0, 0);
        assert_eq!(c_before.ch, b'X' as u32);
        assert_ne!(
            c_before.flags & bc::cell_flags::UNDERLINE,
            0,
            "pre-resize: UNDERLINE flag must be set; flags=0x{:x}",
            c_before.flags
        );
        assert_ne!(
            c_before.flags & bc::cell_flags::REVERSE,
            0,
            "pre-resize: REVERSE flag must be set; flags=0x{:x}",
            c_before.flags
        );
        bc::bb_snap_release(snap);

        // Resize (grow + shrink pair).
        bc::bb_term_resize(term, 30, 8);
        bc::bb_term_resize(term, 8, 4);

        let snap = bc::bb_term_take_snapshot(term);
        let c_after = cell_at(snap, 0, 0);
        assert_eq!(c_after.ch, b'X' as u32);
        assert_ne!(
            c_after.flags & bc::cell_flags::UNDERLINE,
            0,
            "post-resize: UNDERLINE flag must survive; flags=0x{:x}",
            c_after.flags
        );
        assert_ne!(
            c_after.flags & bc::cell_flags::REVERSE,
            0,
            "post-resize: REVERSE flag must survive; flags=0x{:x}",
            c_after.flags
        );
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}
