//! Blind regression tests for VT-6: copying a selection whose LAST row is
//! selected out to the right margin must yield the row's content, not the
//! content plus the grid's blank padding.
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and
//! documented terminal conventions only, never the implementation.
//!
//! Contract under test (`bb_term_text_range`, header doc + the convention of
//! every mainstream terminal, including alacritty whose selection code this
//! core is built on):
//!   - Prose mode (flags bit 0 clear) trims the grid's blank fill from each
//!     emitted row so the clipboard never carries "spaces that exist only
//!     because the grid is N columns wide". The header documents the last row
//!     (or a single-line range) as trimmed only when its `end_col` sits in the
//!     row's blank tail: the last row stops at the selection end column, so a
//!     selection that ends INSIDE the text, or in a gap before more text, keeps
//!     the spaces it covers.
//!   - When the selection end sits on the right margin (`end_col` == last
//!     column, or any larger value, which the core clamps to the last column)
//!     the final row is selected "past the text", exactly like the rows above
//!     it, and must be trimmed to its content too. Typed spaces INSIDE the
//!     content and wide characters stay intact.
//!   - A span of nothing but blanks (a triple-click on an empty or
//!     whitespace-only line, a drag from a blank cell to the margin) yields
//!     "", like a blank row anywhere else in a range. Only a deliberate
//!     one-cell pick of a blank keeps its lone space.
//!   - Rectangular mode (flags bit 0 set) is exempt by design: the header
//!     says "every line is clipped to [start_col, end_col] with no trimming".
//!
//! Where the user hits this:
//!   - Triple-click a line shorter than the terminal, then Cmd-C. The Swift
//!     layer (`Selection.copyRange`, `.line` mode) asks for
//!     `(line, 0) .. (line, cols - 1)`.
//!   - Drag-select a span whose last row ends at the right margin.
//!   - Select All / Export Scrollback, which asks for
//!     `(-history, 0) .. (rows - 1, cols - 1)`.
//!
//! The bug being pinned: all of those copied "hello" as "hello" followed by
//! up to `cols - len` trailing spaces (35 on a 40-column grid), invisible in
//! the terminal but visible when pasted into editors, chat or diffs.
//!
//! Rig preconditions (asserted in EVERY test via `assert_rig`, so a green run
//! cannot mean "extraction is empty" or "the row had no blank tail"):
//!   1. A single-row extraction that stops inside the text returns it
//!      verbatim (`"hello"`), proving extraction works and the text really is
//!      where we think it is.
//!   2. The grid cell at the right margin (col 39) of that row is blank, so
//!      there IS a blank tail the copy could wrongly include.
//!   3. A two-row prose extraction returns the FIRST row without padding
//!      (the documented non-last-row trim), so the only place padding can
//!      appear is the last row.
//!   4. Rectangular mode over the whole row returns exactly 40 characters
//!      (content plus 35 blanks), proving the exempt path really sees the
//!      padding and that the grid is 40 columns wide.
//!
//! Pre-flight cost: 40x3 grids (a few KB each) with at most 100 lines of
//! scrollback; a few dozen terminals over the whole file, each freed
//! immediately. No sleeps, no threads, no I/O.

use blackbird_core as bc;

const COLS: u16 = 40;
const ROWS: u16 = 3;
const SCROLLBACK: u32 = 100;
/// Right-margin column index, as the Swift layer passes it (`cols - 1`).
const LAST: u16 = COLS - 1;

fn with_term<F: FnOnce(*mut bc::BBTerm)>(f: F) {
    unsafe {
        let t = bc::bb_term_new(COLS, ROWS, SCROLLBACK);
        assert!(!t.is_null(), "bb_term_new({COLS}, {ROWS}) returned null");
        f(t);
        bc::bb_term_free(t);
    }
}

fn feed(term: *mut bc::BBTerm, s: &str) {
    unsafe { bc::bb_term_input(term, s.as_ptr(), s.len()) };
}

/// Extract `[start, end]` and return the UTF-8 payload. A null reply fails
/// the test (the FFI only returns null for a null term or a caught panic).
fn text_range(
    term: *mut bc::BBTerm,
    start_line: i32,
    start_col: u16,
    end_line: i32,
    end_col: u16,
    flags: u8,
) -> String {
    unsafe {
        let raw = bc::bb_term_text_range(term, start_line, start_col, end_line, end_col, flags);
        assert!(
            !raw.is_null(),
            "bb_term_text_range({start_line},{start_col},{end_line},{end_col},{flags}) returned null"
        );
        let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
            &[]
        } else {
            std::slice::from_raw_parts((*raw).bytes, (*raw).len)
        };
        let out = String::from_utf8(bytes.to_vec()).expect("text_range payload must be UTF-8");
        bc::bb_string_release(raw);
        out
    }
}

/// Raw `ch` value of the cell at (`row`, `col`) of the visible viewport.
fn cell_ch(term: *mut bc::BBTerm, row: u16, col: u16) -> u32 {
    unsafe {
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        assert_eq!((*snap).cols, COLS, "snapshot cols");
        assert!(row < (*snap).rows, "row {row} out of range");
        let idx = (row as usize) * (COLS as usize) + col as usize;
        let ch = (*(*snap).cells.add(idx)).ch;
        bc::bb_snap_release(snap);
        ch
    }
}

/// Number of trailing ASCII spaces, for readable failure messages.
fn trailing_spaces(s: &str) -> usize {
    s.len() - s.trim_end_matches(' ').len()
}

/// Preconditions shared by every test. See the file header.
fn assert_rig() {
    with_term(|t| {
        feed(t, "hello\r\nworld");
        // 1: extraction works and the text is where we think it is.
        assert_eq!(
            text_range(t, 0, 0, 0, 4, 0),
            "hello",
            "precondition: extraction over cols 0..=4 of row 0 must return \"hello\""
        );
        // 2: there really is a blank tail on the row.
        let tail = cell_ch(t, 0, LAST);
        assert!(
            tail == 0 || tail == ' ' as u32,
            "precondition: the right-margin cell of row 0 must be blank; got ch={tail:#x}"
        );
        // 3: non-last rows are already trimmed (documented), so the only
        // possible padding is on the last row.
        assert_eq!(
            text_range(t, 0, 0, 1, 0, 0),
            "hello\nw",
            "precondition: a two-row prose extraction must trim the first row's blank fill"
        );
        // 4: rectangular mode sees the full 40-cell width (no trimming).
        let rect = text_range(t, 0, 0, 0, LAST, 1);
        assert_eq!(
            rect,
            format!("{:<width$}", "hello", width = COLS as usize),
            "precondition: rectangular copy of the whole row must be \"hello\" + 35 blanks \
             ({} chars expected, got {})",
            COLS,
            rect.chars().count()
        );
    });
}

// ---------------------------------------------------------------------------
// The exact trigger from the bug report: triple-click a short line, Cmd-C
// ---------------------------------------------------------------------------

/// Triple-click -> `(line, 0)..(line, cols - 1)` on `hello world`.
#[test]
fn triple_click_on_a_short_line_copies_only_the_line() {
    assert_rig();
    with_term(|t| {
        feed(t, "hello world");
        let got = text_range(t, 0, 0, 0, LAST, 0);
        assert_eq!(
            got,
            "hello world",
            "triple-click copy of a short line must be the line alone; got {got:?} \
             ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

/// Same selection, but the end column is larger than the grid (the core
/// clamps it to the right margin): identical result.
#[test]
fn end_column_past_the_right_margin_is_trimmed_like_the_margin_itself() {
    assert_rig();
    with_term(|t| {
        feed(t, "hello world");
        let got = text_range(t, 0, 0, 0, u16::MAX, 0);
        assert_eq!(
            got,
            "hello world",
            "end_col = u16::MAX clamps to the right margin and must trim the blank tail; \
             got {got:?} ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

/// Triple-click on the MIDDLE row of three: the selection's last row is not
/// the grid's last row, so this is purely about "last row of the selection".
#[test]
fn triple_click_on_a_middle_row_copies_only_that_row() {
    assert_rig();
    with_term(|t| {
        feed(t, "one\r\ntwo\r\nthree");
        let got = text_range(t, 1, 0, 1, LAST, 0);
        assert_eq!(
            got,
            "two",
            "triple-click copy of row 1 must be \"two\" alone; got {got:?} \
             ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

/// Triple-click + drag over two lines: every whole line between the anchor
/// and the pointer, the last one without padding.
#[test]
fn line_drag_over_two_rows_trims_the_last_row_too() {
    assert_rig();
    with_term(|t| {
        feed(t, "first line\r\nsecond");
        let got = text_range(t, 0, 0, 1, LAST, 0);
        assert_eq!(
            got,
            "first line\nsecond",
            "two whole short lines must copy as \"first line\\nsecond\"; got {got:?} \
             ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

// ---------------------------------------------------------------------------
// Drag-select ending at the right margin
// ---------------------------------------------------------------------------

/// Drag from the middle of row 0 to the right margin of row 1.
#[test]
fn drag_select_ending_at_the_right_margin_trims_the_last_row() {
    assert_rig();
    with_term(|t| {
        feed(t, "hello world\r\nsecond");
        // Start on 'w' (col 6).
        let got = text_range(t, 0, 6, 1, LAST, 0);
        assert_eq!(
            got,
            "world\nsecond",
            "drag from (0,6) to the right margin of row 1 must be \"world\\nsecond\"; \
             got {got:?} ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

// ---------------------------------------------------------------------------
// Select All / Export Scrollback
// ---------------------------------------------------------------------------

/// Select All over a screen whose final rows are blank: the content, with
/// nothing but (optionally) line breaks after it and no blank padding
/// anywhere. Either "alpha\nbeta" or "alpha\nbeta\n" is acceptable; 40 spaces
/// after it are not.
#[test]
fn select_all_with_blank_trailing_rows_has_no_blank_padding() {
    assert_rig();
    with_term(|t| {
        feed(t, "alpha\r\nbeta");
        let got = text_range(t, 0, 0, ROWS as i32 - 1, LAST, 0);
        assert_eq!(
            got.trim_end_matches('\n'),
            "alpha\nbeta",
            "select-all must yield the two content rows; got {got:?}"
        );
        assert_eq!(
            got.matches(' ').count(),
            0,
            "select-all of a screen with no typed spaces must contain no spaces at all; \
             got {got:?} ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

/// Export Scrollback: history plus viewport, last row holds the final text.
#[test]
fn export_scrollback_ends_with_the_last_line_not_its_padding() {
    assert_rig();
    with_term(|t| {
        // Six lines on a 3-row grid: l1..l3 end up in history, the viewport
        // is l4, l5, last; the cursor stays on the last row.
        feed(t, "l1\r\nl2\r\nl3\r\nl4\r\nl5\r\nlast");
        assert_eq!(
            text_range(t, -3, 0, -3, 1, 0),
            "l1",
            "precondition: buffer line -3 must be the oldest line, \"l1\""
        );
        let got = text_range(t, -3, 0, ROWS as i32 - 1, LAST, 0);
        assert_eq!(
            got,
            "l1\nl2\nl3\nl4\nl5\nlast",
            "export of history + viewport must end with \"last\", no padding; got {got:?} \
             ({} trailing spaces)",
            trailing_spaces(&got)
        );
        // The clamped "everything" form used by the other callers.
        let all = text_range(t, i32::MIN, 0, i32::MAX, u16::MAX, 0);
        assert_eq!(
            all,
            "l1\nl2\nl3\nl4\nl5\nlast",
            "whole-buffer extraction must end with \"last\", no padding; got {all:?} \
             ({} trailing spaces)",
            trailing_spaces(&all)
        );
    });
}

// ---------------------------------------------------------------------------
// Content that must survive the trim
// ---------------------------------------------------------------------------

/// Typed spaces INSIDE the content are data; only the blank tail goes.
#[test]
fn spaces_inside_the_content_survive_while_the_tail_is_trimmed() {
    assert_rig();
    with_term(|t| {
        feed(t, "a   b  c");
        let got = text_range(t, 0, 0, 0, LAST, 0);
        assert_eq!(
            got,
            "a   b  c",
            "interior spaces must be kept and the tail trimmed; got {got:?} \
             ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

/// Wide (double-width) characters at the end of the content: copied intact,
/// padding gone.
#[test]
fn wide_characters_on_the_last_row_copy_without_padding() {
    assert_rig();
    with_term(|t| {
        feed(t, "\u{4e2d}\u{6587}"); // two wide glyphs, cols 0..=3
        assert_eq!(
            text_range(t, 0, 0, 0, 3, 0),
            "\u{4e2d}\u{6587}",
            "precondition: extraction over the four wide cells must return both glyphs"
        );
        let got = text_range(t, 0, 0, 0, LAST, 0);
        assert_eq!(
            got,
            "\u{4e2d}\u{6587}",
            "wide glyphs must copy without padding; got {got:?} ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

/// A logical line soft-wrapped across two rows: selecting through the right
/// margin of the second row must end at the last `x`, not at the padding.
/// (Whether the join between the wrapped rows carries a line break is not
/// what this pins, so line breaks are ignored when comparing.)
#[test]
fn soft_wrapped_line_ends_at_its_last_character() {
    assert_rig();
    with_term(|t| {
        let line = "x".repeat(COLS as usize + 10); // 40 on row 0, 10 on row 1
        feed(t, &line);
        assert_eq!(
            text_range(t, 1, 0, 1, 9, 0),
            "x".repeat(10),
            "precondition: row 1 must hold the 10 wrapped characters"
        );
        let got = text_range(t, 0, 0, 1, LAST, 0);
        assert_eq!(
            got.replace('\n', ""),
            line,
            "soft-wrapped line must copy as its 50 characters with no padding; got {got:?} \
             ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

// ---------------------------------------------------------------------------
// Blank-only spans and where the trim stops
// ---------------------------------------------------------------------------

/// Triple-click on an empty line: nothing to copy, not `cols` spaces.
#[test]
fn triple_click_on_an_empty_line_copies_nothing() {
    assert_rig();
    with_term(|t| {
        feed(t, "one\r\n\r\nthree");
        let got = text_range(t, 1, 0, 1, LAST, 0);
        assert_eq!(
            got,
            "",
            "triple-click copy of an empty line must be empty; got {got:?} ({} spaces)",
            trailing_spaces(&got)
        );
    });
}

/// Triple-click on a line holding only typed spaces: same, empty.
#[test]
fn triple_click_on_a_whitespace_only_line_copies_nothing() {
    assert_rig();
    with_term(|t| {
        feed(t, "one\r\n   \r\nthree");
        let got = text_range(t, 1, 0, 1, LAST, 0);
        assert_eq!(
            got,
            "",
            "triple-click copy of a whitespace-only line must be empty; got {got:?} ({} spaces)",
            trailing_spaces(&got)
        );
    });
}

/// Drag from a blank cell right of the text out to the margin: no text was
/// selected, so nothing is copied.
#[test]
fn drag_from_a_blank_cell_to_the_right_margin_copies_nothing() {
    assert_rig();
    with_term(|t| {
        feed(t, "hello");
        let got = text_range(t, 0, 10, 0, LAST, 0);
        assert_eq!(
            got,
            "",
            "a blank-only span to the margin must be empty; got {got:?} ({} spaces)",
            trailing_spaces(&got)
        );
    });
}

/// A deliberate one-cell pick of a blank keeps its lone space.
#[test]
fn one_cell_pick_of_a_blank_keeps_its_space() {
    assert_rig();
    with_term(|t| {
        feed(t, "hello");
        assert_eq!(
            text_range(t, 0, 10, 0, 10, 0),
            " ",
            "a one-cell pick of a blank must copy that single space"
        );
    });
}

/// The end column sits in the blank tail but short of the margin: the cells
/// beyond the text are still padding and go.
#[test]
fn selection_ending_in_the_blank_tail_short_of_the_margin_is_trimmed() {
    assert_rig();
    with_term(|t| {
        feed(t, "hello");
        let got = text_range(t, 0, 0, 0, 20, 0);
        assert_eq!(
            got,
            "hello",
            "a span ending in the blank tail must copy the text alone; got {got:?} \
             ({} trailing spaces)",
            trailing_spaces(&got)
        );
    });
}

/// The end column falls in a gap with more text after it: those spaces are
/// content the user selected, so they stay.
#[test]
fn selection_ending_in_a_gap_before_more_text_keeps_the_spaces() {
    assert_rig();
    with_term(|t| {
        feed(t, "ab   cd"); // a b _ _ _ c d: cols 0..=6
        assert_eq!(
            text_range(t, 0, 0, 0, 3, 0),
            "ab  ",
            "single-row span ending in a gap before more text must keep its spaces"
        );
    });
}

/// Same, as the last row of a multi-row range.
#[test]
fn last_row_ending_in_a_gap_before_more_text_keeps_the_spaces() {
    assert_rig();
    with_term(|t| {
        feed(t, "x\r\nab   cd");
        assert_eq!(
            text_range(t, 0, 0, 1, 3, 0),
            "x\nab  ",
            "last row ending in a gap before more text must keep its spaces"
        );
    });
}

// ---------------------------------------------------------------------------
// Behaviour that must NOT change
// ---------------------------------------------------------------------------

/// A prose selection that ends inside the text is not affected by the fix:
/// the last row stops at the selection end column.
#[test]
fn selection_ending_inside_the_text_is_unchanged() {
    assert_rig();
    with_term(|t| {
        feed(t, "hello world");
        assert_eq!(
            text_range(t, 0, 0, 0, 4, 0),
            "hello",
            "selection ending at col 4 must copy exactly \"hello\""
        );
        assert_eq!(
            text_range(t, 0, 0, 0, 10, 0),
            "hello world",
            "selection ending on the last character must copy exactly \"hello world\""
        );
        assert_eq!(
            text_range(t, 0, 6, 0, 8, 0),
            "wor",
            "mid-row selection must copy exactly \"wor\""
        );
    });
}

/// Rectangular mode is exempt by design: a block selection is a geometric
/// region, so its blank cells are part of the block.
#[test]
fn rectangular_selection_keeps_its_blank_cells() {
    assert_rig();
    with_term(|t| {
        feed(t, "hello\r\nworld");
        let got = text_range(t, 0, 0, 1, LAST, 1);
        let pad = " ".repeat(COLS as usize - 5);
        assert_eq!(
            got,
            format!("hello{pad}\nworld{pad}"),
            "rectangular copy of the full-width block must keep every cell \
             (2 x {COLS} chars + newline); got {got:?}"
        );
    });
}
