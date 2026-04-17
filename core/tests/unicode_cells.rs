//! Pin the grid representation for Unicode edge cases: wide CJK, emoji with
//! variation selectors, combining marks, control characters, atlas overflow.
//!
//! These tests document current behavior and guard against regressions. A
//! failure here means either the VT core changed how it stores a character,
//! or our FFI stopped surfacing information the renderer needs.

use blackbird_core as bc;

fn cell_at(snap: *const bc::BBSnap, col: u16, row: u16) -> bc::BBCell {
    unsafe {
        let cols = (*snap).cols;
        let rows = (*snap).rows;
        assert!(col < cols && row < rows);
        let idx = (row as usize) * (cols as usize) + col as usize;
        *((*snap).cells.add(idx))
    }
}

fn with_term<F: FnOnce(*mut bc::BBTerm)>(cols: u16, rows: u16, f: F) {
    unsafe {
        let t = bc::bb_term_new(cols, rows, 100);
        assert!(!t.is_null());
        f(t);
        bc::bb_term_free(t);
    }
}

fn feed(term: *mut bc::BBTerm, bytes: &[u8]) {
    unsafe { bc::bb_term_input(term, bytes.as_ptr(), bytes.len()) };
}

fn snap(term: *mut bc::BBTerm) -> *const bc::BBSnap {
    unsafe { bc::bb_term_take_snapshot(term) }
}

fn release(s: *const bc::BBSnap) {
    unsafe { bc::bb_snap_release(s) };
}

// ---------------------------------------------------------------------------
// Wide CJK characters
// ---------------------------------------------------------------------------

#[test]
fn cjk_occupies_two_cells_and_marks_spacer() {
    // `日` (U+65E5) is a full-width CJK character and must take two cells.
    // Alacritty puts the glyph in cell N with WIDE_CHAR, and a spacer in
    // cell N+1 with WIDE_CHAR_SPACER. The renderer must see both so it can
    // skip drawing N+1 (otherwise a narrow space paints over the wide glyph).
    with_term(10, 2, |term| {
        feed(term, "日本語".as_bytes());
        let s = snap(term);

        // Glyph cells — ch is the CJK codepoint, WIDE_CHAR set.
        let c0 = cell_at(s, 0, 0);
        assert_eq!(c0.ch, 0x65E5, "日 should be in cell 0");
        assert!(
            c0.flags & bc::cell_flags::WIDE_CHAR != 0,
            "wide CJK glyph cell must have WIDE_CHAR flag; got 0x{:x}",
            c0.flags
        );

        let c1 = cell_at(s, 1, 0);
        assert!(
            c1.flags & bc::cell_flags::WIDE_CHAR_SPACER != 0,
            "cell right of wide glyph must have WIDE_CHAR_SPACER flag; got 0x{:x}",
            c1.flags
        );

        // Next glyph starts at col 2.
        let c2 = cell_at(s, 2, 0);
        assert_eq!(c2.ch, 0x672C, "本 should be in cell 2");

        release(s);
    });
}

#[test]
fn ascii_cell_has_no_wide_flags() {
    with_term(10, 2, |term| {
        feed(term, b"A");
        let s = snap(term);
        let c = cell_at(s, 0, 0);
        assert_eq!(c.flags & bc::cell_flags::WIDE_CHAR, 0);
        assert_eq!(c.flags & bc::cell_flags::WIDE_CHAR_SPACER, 0);
        release(s);
    });
}

// ---------------------------------------------------------------------------
// Combining marks / zero-width characters
// ---------------------------------------------------------------------------

#[test]
fn combining_acute_attaches_to_previous_glyph() {
    // `e\u{0301}` (e + combining acute). alacritty stores the base glyph in
    // the cell and keeps combining marks in a separate `zerowidth` list on
    // the cell. Cursor advances by 1, not 2.
    with_term(10, 2, |term| {
        feed(term, "e\u{0301}".as_bytes());
        let s = snap(term);

        let c0 = cell_at(s, 0, 0);
        // Base glyph stays in cell 0.
        assert_eq!(c0.ch, b'e' as u32);
        // Nothing visible in cell 1 (alacritty stores empty cells as space).
        let c1 = cell_at(s, 1, 0);
        assert_eq!(
            c1.ch, b' ' as u32,
            "combining mark must not write cell 1; expected empty space, got 0x{:x}",
            c1.ch
        );
        // Cursor advanced by one glyph only.
        assert_eq!(unsafe { (*s).cursor_col }, 1);

        release(s);
    });
}

// ---------------------------------------------------------------------------
// Emoji with variation selectors
// ---------------------------------------------------------------------------

#[test]
fn heart_with_vs16_stays_in_one_cell() {
    // U+2764 HEAVY BLACK HEART + VS16 (U+FE0F) selects the emoji/colour
    // presentation. VS selectors are zero-width; grid advance is still one.
    with_term(10, 2, |term| {
        feed(term, "\u{2764}\u{FE0F}".as_bytes());
        let s = snap(term);

        let c0 = cell_at(s, 0, 0);
        assert_eq!(c0.ch, 0x2764);
        // VS-16 must not consume a second cell (empty cells read as space).
        let c1 = cell_at(s, 1, 0);
        assert_eq!(
            c1.ch, b' ' as u32,
            "VS-16 must not write cell 1; expected empty space, got 0x{:x}",
            c1.ch
        );

        release(s);
    });
}

// ---------------------------------------------------------------------------
// Control characters
// ---------------------------------------------------------------------------

#[test]
fn bel_does_not_produce_glyph() {
    with_term(10, 2, |term| {
        feed(term, b"A\x07B");
        let s = snap(term);
        assert_eq!(cell_at(s, 0, 0).ch, b'A' as u32);
        // BEL emits an event but must not advance cursor nor write a cell.
        assert_eq!(cell_at(s, 1, 0).ch, b'B' as u32);
        release(s);
    });
}

#[test]
fn tab_advances_cursor_without_drawing_glyph() {
    with_term(20, 2, |term| {
        feed(term, b"A\tB");
        let s = snap(term);
        assert_eq!(cell_at(s, 0, 0).ch, b'A' as u32);
        // Tab stops default every 8 cols. B lands at col 8.
        assert_eq!(cell_at(s, 8, 0).ch, b'B' as u32);
        // alacritty stores U+0009 as a marker in the cell where tab started
        // so selection re-emits a tab, but the renderer must not draw a
        // glyph for it — the skipped cells look blank on screen. Cells 2-7
        // are real spaces. None should ever contain a printable character.
        for c in 1..8 {
            let ch = cell_at(s, c, 0).ch;
            assert!(
                ch == b' ' as u32 || ch == 0x09,
                "cell {c} was inked with printable glyph 0x{:x} by tab",
                ch
            );
        }
        release(s);
    });
}

#[test]
fn zwsp_does_not_occupy_its_own_cell() {
    // ZERO WIDTH SPACE (U+200B) is zero-advance, so B must land in cell 1,
    // not cell 2. Whether alacritty stashes the ZWSP as a combining mark on
    // A's cell or discards it is an implementation detail — what matters for
    // rendering is that B renders at col 1.
    with_term(10, 2, |term| {
        feed(term, "A\u{200B}B".as_bytes());
        let s = snap(term);
        assert_eq!(cell_at(s, 0, 0).ch, b'A' as u32);
        assert_eq!(cell_at(s, 1, 0).ch, b'B' as u32);
        release(s);
    });
}

// ---------------------------------------------------------------------------
// CJK at the right edge of a narrow terminal
// ---------------------------------------------------------------------------

#[test]
fn cjk_wraps_when_only_one_column_remains() {
    // 5-wide terminal. Write "ABCD日": D fills col 3, one col remains (col 4)
    // but a wide glyph needs two. Alacritty wraps to the next row rather than
    // splitting the glyph. The single leftover col gets LEADING_WIDE_CHAR_SPACER.
    with_term(5, 3, |term| {
        feed(term, "ABCD日".as_bytes());
        let s = snap(term);
        assert_eq!(cell_at(s, 0, 0).ch, b'A' as u32);
        assert_eq!(cell_at(s, 3, 0).ch, b'D' as u32);
        // The wide glyph wraps to the next row.
        let wrapped = cell_at(s, 0, 1);
        assert_eq!(wrapped.ch, 0x65E5, "wide glyph wrapped to next row");
        assert!(
            wrapped.flags & bc::cell_flags::WIDE_CHAR != 0,
            "wrapped CJK cell must carry WIDE_CHAR flag"
        );
        release(s);
    });
}
