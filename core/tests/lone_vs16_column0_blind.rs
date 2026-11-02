//! Blind regression tests for the "lone VS16 / U+20E3 at column 0 destroys the
//! cell under the cursor" bug.
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and the
//! documented behaviour only, never the implementation.
//!
//! Contract under test:
//!   - VS16 (U+FE0F, the emoji variation selector) and U+20E3 (combining
//!     enclosing keycap) are ZERO-WIDTH marks. As a lone scalar they take no
//!     column, never move the cursor, and never erase or replace the visible
//!     glyph of any cell. (See `unicode_cells.rs`: the marks ride on a base
//!     cell; they are "NOT surfaced through `BBCell.ch`".)
//!   - A lone mark arriving while the cursor sits at column 0 (after `CR`,
//!     `CUP`/`CUP home`, or on the continuation row of a wrapped line), with
//!     no pending wrap, therefore must leave the line exactly as it was. In
//!     particular `printf 'abcdef\r\xef\xb8\x8f'` must still show `abcdef`.
//!   - Grid invariant that selection, reflow and copy rely on (documented on
//!     `WIDE_CHAR_SPACER` in the header: "the right half of a wide glyph"):
//!     a `WIDE_CHAR_SPACER` cell at column c > 0 is always preceded by a
//!     `WIDE_CHAR` cell at c - 1, and column 0 is never a (non-leading)
//!     spacer. A lone mark over narrow ASCII has no business producing a
//!     spacer at all.
//!
//! How the bug is observed: a snapshot of the grid (`bb_term_take_snapshot`)
//! gives per-cell `ch`/`flags`; `bb_term_text_range` gives the copy-path text.
//! Unfixed, the cell under the cursor loses its glyph and becomes a
//! `WIDE_CHAR_SPACER` that is not preceded by a `WIDE_CHAR`, so the first
//! character of the line vanishes from both the snapshot and the copied text.
//!
//! Rig preconditions are asserted in every test so a vacuous pass is
//! impossible (see `assert_rig_preconditions`).
//!
//! Pre-flight cost: 10x3 grid, scrollback 16 -> a few KB per terminal. Inputs
//! are < 40 bytes. No sleeps, I/O, threads.

use blackbird_core as bc;

const COLS: u16 = 10;
const ROWS: u16 = 3;
const SCROLLBACK: u32 = 16;

const VS16: &str = "\u{FE0F}";
const KEYCAP: &str = "\u{20E3}";

/// Every flag that marks a cell as part of a wide glyph. A lone zero-width
/// mark over narrow ASCII content must set none of these anywhere.
const ANY_WIDE_FLAG: u16 = bc::cell_flags::WIDE_CHAR
    | bc::cell_flags::WIDE_CHAR_SPACER
    | bc::cell_flags::LEADING_WIDE_CHAR_SPACER;

fn new_term() -> *mut bc::BBTerm {
    let t = unsafe { bc::bb_term_new(COLS, ROWS, SCROLLBACK) };
    assert!(!t.is_null(), "bb_term_new({COLS}, {ROWS}) returned null");
    t
}

fn feed_str(term: *mut bc::BBTerm, s: &str) {
    unsafe { bc::bb_term_input(term, s.as_ptr(), s.len()) };
}

/// Owned copy of one snapshot, so no raw pointer outlives its release.
struct Grid {
    cols: u16,
    rows: u16,
    cells: Vec<bc::BBCell>,
    cursor_col: u16,
    cursor_row: u16,
    pending_wrap: u8,
}

impl Grid {
    fn take(term: *mut bc::BBTerm) -> Grid {
        unsafe {
            let snap = bc::bb_term_take_snapshot(term);
            assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
            let cols = (*snap).cols;
            let rows = (*snap).rows;
            let n = (cols as usize) * (rows as usize);
            assert_eq!(
                (*snap).cells_len,
                n,
                "snapshot cells_len must be cols*rows ({cols}x{rows})"
            );
            let cells = std::slice::from_raw_parts((*snap).cells, n).to_vec();
            let g = Grid {
                cols,
                rows,
                cells,
                cursor_col: (*snap).cursor_col,
                cursor_row: (*snap).cursor_row,
                pending_wrap: (*snap).cursor_pending_wrap,
            };
            bc::bb_snap_release(snap);
            g
        }
    }

    fn cell(&self, row: u16, col: u16) -> bc::BBCell {
        assert!(row < self.rows && col < self.cols);
        self.cells[(row as usize) * (self.cols as usize) + col as usize]
    }

    /// One char per cell: the cell's glyph (`ch == 0` shown as a space), `#`
    /// for a `WIDE_CHAR_SPACER`, `<` for a `LEADING_WIDE_CHAR_SPACER`. Wide
    /// glyph cells show their own scalar.
    fn row_glyphs(&self, row: u16) -> String {
        (0..self.cols)
            .map(|col| {
                let c = self.cell(row, col);
                if c.flags & bc::cell_flags::WIDE_CHAR_SPACER != 0 {
                    '#'
                } else if c.flags & bc::cell_flags::LEADING_WIDE_CHAR_SPACER != 0 {
                    '<'
                } else if c.ch == 0 {
                    ' '
                } else {
                    char::from_u32(c.ch).unwrap_or('\u{FFFD}')
                }
            })
            .collect()
    }

    /// `(row, col, flags)` of every cell carrying any wide-glyph flag.
    fn wide_flagged_cells(&self) -> Vec<(u16, u16, u16)> {
        let mut out = Vec::new();
        for row in 0..self.rows {
            for col in 0..self.cols {
                let f = self.cell(row, col).flags;
                if f & ANY_WIDE_FLAG != 0 {
                    out.push((row, col, f));
                }
            }
        }
        out
    }

    /// Violations of the documented spacer invariant: a `WIDE_CHAR_SPACER`
    /// must sit directly right of a `WIDE_CHAR` cell (so never in column 0).
    fn orphan_spacers(&self) -> Vec<String> {
        let mut out = Vec::new();
        for row in 0..self.rows {
            for col in 0..self.cols {
                let c = self.cell(row, col);
                if c.flags & bc::cell_flags::WIDE_CHAR_SPACER == 0 {
                    continue;
                }
                let preceded =
                    col > 0 && self.cell(row, col - 1).flags & bc::cell_flags::WIDE_CHAR != 0;
                if !preceded {
                    out.push(format!(
                        "row {row} col {col}: WIDE_CHAR_SPACER not preceded by WIDE_CHAR \
                         (flags 0x{:x}, row glyphs {:?})",
                        c.flags,
                        self.row_glyphs(row)
                    ));
                }
            }
        }
        out
    }

    fn count_spacers(&self) -> usize {
        self.cells
            .iter()
            .filter(|c| c.flags & bc::cell_flags::WIDE_CHAR_SPACER != 0)
            .count()
    }
}

/// `row` extracted through the copy path (`bb_term_text_range`, prose mode),
/// with the zero-width marks under test removed and trailing blanks trimmed:
/// it does not matter whether a correct core keeps the mark riding on the
/// base cell or drops it, only that every visible glyph survives.
fn row_text_without_marks(term: *mut bc::BBTerm, row: u16) -> String {
    unsafe {
        let raw = bc::bb_term_text_range(term, row as i32, 0, row as i32, COLS - 1, 0);
        assert!(!raw.is_null(), "bb_term_text_range returned null");
        let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
            &[]
        } else {
            std::slice::from_raw_parts((*raw).bytes, (*raw).len)
        };
        let s = std::str::from_utf8(bytes)
            .expect("text_range reply must be valid UTF-8")
            .to_string();
        bc::bb_string_release(raw);
        s.chars()
            .filter(|c| *c != '\u{FE0F}' && *c != '\u{20E3}')
            .collect::<String>()
            .trim_end()
            .to_string()
    }
}

/// Rig preconditions. Without these a green run could mean "the snapshot
/// reader is blind to wide flags" or "text_range never returns anything".
///
///   1. Plain ASCII lands where expected, with no wide flags anywhere, and
///      `\r` returns the cursor to column 0 with no pending wrap.
///   2. A legitimate emoji-presentation sequence (`U+26A0 U+FE0F`) really is
///      reported as WIDE_CHAR + WIDE_CHAR_SPACER, the invariant checker
///      accepts it (it sees exactly one spacer), and the cursor advances by 2.
///      So "no spacer anywhere" in the real tests is a meaningful claim and
///      the orphan-spacer check cannot be satisfied by never reporting
///      spacers.
///   3. Text extraction returns the row's glyphs.
fn assert_rig_preconditions() {
    unsafe {
        let t = new_term();
        feed_str(t, "abcdef\r");
        let g = Grid::take(t);
        assert_eq!(
            g.row_glyphs(0),
            "abcdef    ",
            "precondition: plain ASCII row must read back verbatim"
        );
        assert_eq!(
            g.wide_flagged_cells(),
            Vec::<(u16, u16, u16)>::new(),
            "precondition: plain ASCII must carry no wide flags"
        );
        assert_eq!(
            (g.cursor_col, g.cursor_row, g.pending_wrap),
            (0, 0, 0),
            "precondition: CR must park the cursor at column 0 with no pending wrap"
        );
        assert_eq!(
            row_text_without_marks(t, 0),
            "abcdef",
            "precondition: text_range must return the row's glyphs"
        );
        bc::bb_term_free(t);

        let t = new_term();
        feed_str(t, "\u{26A0}\u{FE0F}");
        let g = Grid::take(t);
        assert!(
            g.cell(0, 0).flags & bc::cell_flags::WIDE_CHAR != 0
                && g.cell(0, 1).flags & bc::cell_flags::WIDE_CHAR_SPACER != 0,
            "precondition: U+26A0 U+FE0F must be WIDE_CHAR + WIDE_CHAR_SPACER; got flags \
             0x{:x} / 0x{:x}",
            g.cell(0, 0).flags,
            g.cell(0, 1).flags
        );
        assert_eq!(
            g.count_spacers(),
            1,
            "precondition: exactly one spacer for one promoted emoji"
        );
        assert_eq!(
            g.orphan_spacers(),
            Vec::<String>::new(),
            "precondition: a legitimate wide glyph must satisfy the spacer invariant"
        );
        assert_eq!(
            g.cursor_col, 2,
            "precondition: emoji-presentation sequence advances the cursor by 2"
        );
        bc::bb_term_free(t);
    }
}

/// Run `setup` then the lone `mark`, then check that the whole grid is exactly
/// what `setup` alone produced (same glyphs, same flags, no spacers), that the
/// cursor is at `(cursor_col, cursor_row)` with no pending wrap, and that the
/// copy path still returns every visible glyph. `expected_rows` is the
/// full-width glyph string for each row (blank-padded to `COLS`).
fn assert_lone_mark_is_harmless(
    label: &str,
    setup: &str,
    mark: &str,
    expected_rows: [&str; ROWS as usize],
    expected_cursor: (u16, u16),
) {
    unsafe {
        // Baseline: the grid right after `setup` must already match the
        // expectation (guards against a wrong expectation in this file).
        let base = new_term();
        feed_str(base, setup);
        let gb = Grid::take(base);
        for (row, want) in expected_rows.iter().enumerate() {
            assert_eq!(
                gb.row_glyphs(row as u16),
                *want,
                "{label}: rig baseline row {row} before the mark"
            );
        }
        assert_eq!(
            (gb.cursor_col, gb.cursor_row, gb.pending_wrap),
            (expected_cursor.0, expected_cursor.1, 0),
            "{label}: rig baseline cursor before the mark"
        );
        bc::bb_term_free(base);

        let t = new_term();
        feed_str(t, setup);
        feed_str(t, mark);
        let g = Grid::take(t);

        for (row, want) in expected_rows.iter().enumerate() {
            assert_eq!(
                g.row_glyphs(row as u16),
                *want,
                "{label}: row {row} glyphs changed by a lone {mark:?} at column 0 \
                 ('#' = WIDE_CHAR_SPACER cell); the mark is zero-width and must not \
                 erase or replace any cell"
            );
        }
        assert_eq!(
            g.wide_flagged_cells(),
            Vec::<(u16, u16, u16)>::new(),
            "{label}: a lone {mark:?} over narrow ASCII must not create any wide / \
             spacer cell; (row, col, flags) of offenders"
        );
        assert_eq!(
            g.orphan_spacers(),
            Vec::<String>::new(),
            "{label}: spacer-preceded-by-wide invariant violated after lone {mark:?}"
        );
        assert_eq!(
            (g.cursor_col, g.cursor_row, g.pending_wrap),
            (expected_cursor.0, expected_cursor.1, 0),
            "{label}: a zero-width mark must not move the cursor or arm a pending wrap \
             (col, row, pending)"
        );
        for (row, want) in expected_rows.iter().enumerate() {
            let want_text: String = want.trim_end().to_string();
            assert_eq!(
                row_text_without_marks(t, row as u16),
                want_text,
                "{label}: copy-path text of row {row} lost glyphs after lone {mark:?}"
            );
        }
        bc::bb_term_free(t);
    }
}

#[test]
fn lone_vs16_after_cr_keeps_first_glyph() {
    assert_rig_preconditions();
    // The exact report: printf 'abcdef\r\xef\xb8\x8f'
    assert_lone_mark_is_harmless(
        "CR + VS16",
        "abcdef\r",
        VS16,
        ["abcdef    ", "          ", "          "],
        (0, 0),
    );
}

#[test]
fn lone_keycap_mark_after_cr_keeps_first_glyph() {
    assert_rig_preconditions();
    // The U+20E3 variant: printf 'abcdef\r\xe2\x83\xa3'
    assert_lone_mark_is_harmless(
        "CR + U+20E3",
        "abcdef\r",
        KEYCAP,
        ["abcdef    ", "          ", "          "],
        (0, 0),
    );
}

#[test]
fn lone_vs16_then_keycap_after_cr_keeps_first_glyph() {
    assert_rig_preconditions();
    // The two marks of a keycap sequence with its base missing.
    let both = format!("{VS16}{KEYCAP}");
    assert_lone_mark_is_harmless(
        "CR + VS16 + U+20E3",
        "abcdef\r",
        &both,
        ["abcdef    ", "          ", "          "],
        (0, 0),
    );
}

#[test]
fn lone_vs16_after_cup_home_keeps_first_glyph() {
    assert_rig_preconditions();
    // CUP 1;1 instead of CR, and a different first character.
    assert_lone_mark_is_harmless(
        "CUP 1;1 + VS16",
        "xyz123\x1b[1;1H",
        VS16,
        ["xyz123    ", "          ", "          "],
        (0, 0),
    );
    assert_lone_mark_is_harmless(
        "CUP 1;1 + U+20E3",
        "xyz123\x1b[1;1H",
        KEYCAP,
        ["xyz123    ", "          ", "          "],
        (0, 0),
    );
}

#[test]
fn lone_vs16_on_lower_row_keeps_that_rows_first_glyph() {
    assert_rig_preconditions();
    // Column 0 of row 1 (reached with CUP 2;1), over 'u'. Row 0 must be
    // untouched as well.
    assert_lone_mark_is_harmless(
        "row 1: CUP 2;1 + VS16",
        "abcdef\r\nuvwxyz\x1b[2;1H",
        VS16,
        ["abcdef    ", "uvwxyz    ", "          "],
        (0, 1),
    );
    assert_lone_mark_is_harmless(
        "row 1: CUP 2;1 + U+20E3",
        "abcdef\r\nuvwxyz\x1b[2;1H",
        KEYCAP,
        ["abcdef    ", "uvwxyz    ", "          "],
        (0, 1),
    );
}

#[test]
fn lone_vs16_on_wrapped_continuation_row_keeps_first_glyph() {
    assert_rig_preconditions();
    // 13 chars in a 10-column terminal wrap onto row 1 ("ABC"); CR returns to
    // column 0 of that continuation row, over 'A', with the wrap resolved.
    assert_lone_mark_is_harmless(
        "wrapped row 1: CR + VS16",
        "0123456789ABC\r",
        VS16,
        ["0123456789", "ABC       ", "          "],
        (0, 1),
    );
    assert_lone_mark_is_harmless(
        "wrapped row 1: CR + U+20E3",
        "0123456789ABC\r",
        KEYCAP,
        ["0123456789", "ABC       ", "          "],
        (0, 1),
    );
}

#[test]
fn typing_after_lone_vs16_at_column_0_overwrites_normally() {
    assert_rig_preconditions();
    // After the lone mark the terminal must still behave: typing 'Z' replaces
    // the old first glyph, the cursor advances to column 1, and the rest of the
    // line is intact. Zero-width marks are stripped from the copy-path text, so
    // the expectation does not depend on how a correct core treats the mark.
    for mark in [VS16, KEYCAP] {
        unsafe {
            let with_mark = new_term();
            feed_str(with_mark, "abcdef\r");
            feed_str(with_mark, mark);
            feed_str(with_mark, "Z");
            let g = Grid::take(with_mark);

            assert_eq!(
                g.row_glyphs(0),
                "Zbcdef    ",
                "typing 'Z' after a lone {mark:?} at column 0 must replace 'a' and leave \
                 'bcdef' intact ('#' = WIDE_CHAR_SPACER cell)"
            );
            assert_eq!(
                g.orphan_spacers(),
                Vec::<String>::new(),
                "spacer invariant violated after lone {mark:?} then 'Z'"
            );
            assert_eq!(
                g.wide_flagged_cells(),
                Vec::<(u16, u16, u16)>::new(),
                "no wide / spacer cells expected after lone {mark:?} then 'Z'"
            );
            assert_eq!(
                (g.cursor_col, g.cursor_row),
                (1, 0),
                "cursor must be at column 1 after typing one narrow glyph (col, row)"
            );
            assert_eq!(
                row_text_without_marks(with_mark, 0),
                "Zbcdef",
                "copy-path text after lone {mark:?} then 'Z'"
            );
            bc::bb_term_free(with_mark);
        }
    }
}

#[test]
fn lone_vs16_at_column_0_does_not_disturb_a_wide_glyph_there() {
    assert_rig_preconditions();
    // Guard for the neighbouring case: a WIDE glyph in columns 0-1 with the
    // cursor homed onto it. Whatever a correct core does with the stray mark,
    // the wide glyph and its spacer must be exactly as before.
    for mark in [VS16, KEYCAP] {
        unsafe {
            let t = new_term();
            feed_str(t, "\u{65E5}bcd\r");
            feed_str(t, mark);
            let g = Grid::take(t);

            assert_eq!(
                g.cell(0, 0).ch,
                0x65E5,
                "wide glyph U+65E5 must survive a lone {mark:?} at column 0; row glyphs {:?}",
                g.row_glyphs(0)
            );
            assert!(
                g.cell(0, 0).flags & bc::cell_flags::WIDE_CHAR != 0,
                "wide glyph keeps WIDE_CHAR after lone {mark:?}; flags 0x{:x}",
                g.cell(0, 0).flags
            );
            assert!(
                g.cell(0, 1).flags & bc::cell_flags::WIDE_CHAR_SPACER != 0,
                "wide glyph keeps its spacer after lone {mark:?}; flags 0x{:x}",
                g.cell(0, 1).flags
            );
            assert_eq!(
                g.row_glyphs(0),
                "\u{65E5}#bcd     ",
                "row after lone {mark:?} over a wide glyph"
            );
            assert_eq!(
                g.orphan_spacers(),
                Vec::<String>::new(),
                "spacer invariant violated after lone {mark:?} over a wide glyph"
            );
            assert_eq!(
                (g.cursor_col, g.cursor_row, g.pending_wrap),
                (0, 0, 0),
                "cursor must stay at column 0 (col, row, pending)"
            );
            bc::bb_term_free(t);
        }
    }
}

// ---------------------------------------------------------------------------
// Same contract, cursor repositioned to a column > 0 (not only column 0).
//
// A lone mark must leave the grid untouched wherever the cursor was moved to,
// not just at column 0: only a mark that directly follows a freshly printed
// glyph may widen it. Each case parks the cursor beside non-blank narrow
// content with a cursor-movement sequence other than printing, then sends the
// lone mark; the whole row must read back exactly as before.
// ---------------------------------------------------------------------------

#[test]
fn lone_mark_after_cursor_forward_keeps_text() {
    assert_rig_preconditions();
    // printf 'abcdef\r\033[C' + mark: CUF leaves the cursor at column 1.
    for (label, mark) in [("VS16", VS16), ("U+20E3", KEYCAP)] {
        assert_lone_mark_is_harmless(
            &format!("CR, CUF 1 + {label}"),
            "abcdef\r\x1b[C",
            mark,
            ["abcdef    ", "          ", "          "],
            (1, 0),
        );
    }
}

#[test]
fn lone_mark_after_cursor_back_keeps_text() {
    assert_rig_preconditions();
    // CUB 2 from column 6 parks the cursor at column 4 over 'e'.
    for (label, mark) in [("VS16", VS16), ("U+20E3", KEYCAP)] {
        assert_lone_mark_is_harmless(
            &format!("CUB 2 + {label}"),
            "abcdef\x1b[2D",
            mark,
            ["abcdef    ", "          ", "          "],
            (4, 0),
        );
    }
}

#[test]
fn lone_mark_after_cup_to_inner_column_keeps_text() {
    assert_rig_preconditions();
    // CUP 1;4 parks the cursor at column 3 over 'd'.
    for (label, mark) in [("VS16", VS16), ("U+20E3", KEYCAP)] {
        assert_lone_mark_is_harmless(
            &format!("CUP 1;4 + {label}"),
            "abcdef\x1b[1;4H",
            mark,
            ["abcdef    ", "          ", "          "],
            (3, 0),
        );
    }
}

#[test]
fn lone_mark_after_backspace_keeps_text() {
    assert_rig_preconditions();
    // BS from column 6 parks the cursor at column 5 over 'f'.
    for (label, mark) in [("VS16", VS16), ("U+20E3", KEYCAP)] {
        assert_lone_mark_is_harmless(
            &format!("BS + {label}"),
            "abcdef\x08",
            mark,
            ["abcdef    ", "          ", "          "],
            (5, 0),
        );
    }
}

#[test]
fn lone_mark_after_tab_keeps_text() {
    assert_rig_preconditions();
    // A full 10-column row, CR, then HT to the tab stop at column 8: the cell
    // left of the cursor ('h') and the cell under it ('i') are both non-blank.
    for (label, mark) in [("VS16", VS16), ("U+20E3", KEYCAP)] {
        assert_lone_mark_is_harmless(
            &format!("HT + {label}"),
            "abcdefghij\r\t",
            mark,
            ["abcdefghij", "          ", "          "],
            (8, 0),
        );
    }
}

#[test]
fn lone_mark_after_scroll_up_keeps_text() {
    assert_rig_preconditions();
    // Print on row 0, then SU 1: row 1's text ("uvwxyz") moves up under the
    // parked cursor at (column 3, row 0), so the cell left of the cursor is
    // non-blank but was not just printed.
    for (label, mark) in [("VS16", VS16), ("U+20E3", KEYCAP)] {
        assert_lone_mark_is_harmless(
            &format!("SU 1 + {label}"),
            "\x1b[2;1Huvwxyz\x1b[1;1Habc\x1b[S",
            mark,
            ["uvwxyz    ", "          ", "          "],
            (3, 0),
        );
    }
}

#[test]
fn mark_straight_after_printed_base_still_widens_it() {
    assert_rig_preconditions();
    // Positive control: the latch must not disable the legitimate sequence, even
    // with an SGR between the base and the mark, or after an unrelated cursor
    // excursion that is followed by fresh printing.
    for (label, setup, mark, cursor_col) in [
        ("base + VS16", "ab\u{26A0}", VS16, 4u16),
        ("base + SGR + VS16", "ab\u{26A0}\x1b[1m", VS16, 4),
        ("move away, print, VS16", "abcdef\r\x1b[2C\u{2764}", VS16, 4),
        ("keycap base + U+20E3", "a#", KEYCAP, 3),
    ] {
        unsafe {
            let t = new_term();
            feed_str(t, setup);
            feed_str(t, mark);
            let g = Grid::take(t);
            assert_eq!(
                g.orphan_spacers(),
                Vec::<String>::new(),
                "{label}: spacer invariant"
            );
            assert_eq!(
                g.count_spacers(),
                1,
                "{label}: exactly one promoted wide glyph expected; row {:?}",
                g.row_glyphs(0)
            );
            assert_eq!(
                g.cursor_col,
                cursor_col,
                "{label}: cursor must sit past the widened glyph; row {:?}",
                g.row_glyphs(0)
            );
            bc::bb_term_free(t);
        }
    }
}
