//! Blind regression tests for "column-shrink reflow leaves the cursor on the
//! spacer of a wrapped wide glyph; the next output erases that glyph".
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and the
//! documented behaviour only, never the implementation.
//!
//! Contract under test (primary screen, reflow on):
//!   - A wide glyph (CJK, emoji, or a VS16-promoted symbol) occupies two
//!     cells: `WIDE_CHAR` (the glyph) then `WIDE_CHAR_SPACER` (its right half).
//!     The spacer is never a place the cursor legitimately rests on: it is
//!     "the right half of a wide glyph" and must not be drawn or typed over.
//!   - When a column shrink leaves a wide glyph straddling the new right
//!     margin (its first cell in the last column), the glyph cannot be split,
//!     so it wraps whole onto the next row. Text that followed it keeps its
//!     order, and the cursor, which was just past the glyph (or past text
//!     after it), must stay attached to the same content: it ends up on the
//!     cell directly right of the wrapped glyph's spacer, exactly as it does
//!     for narrow (ASCII) text, where the cursor follows the reflowed content.
//!   - Therefore output that continues after the shrink (no repositioning)
//!     lands to the right of the glyph and must leave the glyph intact: the
//!     row reads glyph + new text, in both the snapshot and the copy path
//!     (`bb_term_text_range`).
//!
//! How the bug is observed: unfixed, the cursor is one cell too far left,
//! sitting ON the `WIDE_CHAR_SPACER`. The next character overwrites the
//! spacer, which destroys the wide glyph (the row reads like `abc  XY`
//! instead of `abc中XY`), the visible symptom being a glyph that vanishes
//! after a narrowing resize plus further output.
//!
//! Scope kept deliberately to what the contract pins down: the cursor row/col
//! right after the shrink, the glyph cells, and the text after continued
//! output. It does not pin the exact marker used in the vacated margin cell
//! of the first row (only that the narrow prefix before it is untouched).
//!
//! Rig preconditions are asserted for every case (pre-shrink geometry, the
//! applied resize, wide flags really reported) plus a narrow-glyph control of
//! the same shape that must behave identically, so a vacuous pass is
//! impossible and the expectations are anchored to the narrow-text behaviour.
//!
//! Pre-flight cost: grids <= 12x4, scrollback 16 -> a few KB per terminal.
//! Inputs are < 40 bytes. No sleeps, I/O, threads.

use blackbird_core as bc;

const ROWS: u16 = 4;
const SCROLLBACK: u32 = 16;

fn new_term(cols: u16) -> *mut bc::BBTerm {
    let t = unsafe { bc::bb_term_new(cols, ROWS, SCROLLBACK) };
    assert!(!t.is_null(), "bb_term_new({cols}, {ROWS}) returned null");
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

    fn count_with_flag(&self, flag: u16) -> usize {
        self.cells.iter().filter(|c| c.flags & flag != 0).count()
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
}

/// `row` extracted through the copy path (`bb_term_text_range`, prose mode),
/// columns `0..cols`, with the zero-width VS16 / keycap marks removed and
/// trailing blanks trimmed: it does not matter whether a correct core keeps
/// the mark riding on the base cell or drops it, only that every visible
/// glyph survives.
fn row_text_without_marks(term: *mut bc::BBTerm, row: u16, cols: u16) -> String {
    unsafe {
        let raw = bc::bb_term_text_range(term, row as i32, 0, row as i32, cols - 1, 0);
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

/// One shrink scenario. The content line is
/// `lines_above` blank lines down, then `prefix` + `glyph` + `after_glyph`,
/// typed on a `old_cols`-wide grid. `prefix` is `new_cols - 1` narrow cells,
/// so a wide `glyph` has its first cell in the LAST column of the new, narrower
/// grid and straddles the new right margin; the cursor (just past
/// `after_glyph`) is then beyond that margin.
struct Case {
    label: &'static str,
    old_cols: u16,
    new_cols: u16,
    lines_above: u16,
    prefix: &'static str,
    glyph: &'static str,
    /// Whether `glyph` is a 2-cell wide glyph (false for the narrow control).
    wide: bool,
    after_glyph: &'static str,
    /// Output fed after the shrink, with no cursor repositioning.
    tail: &'static str,
    /// Expected column of the cursor right after the shrink; its row is
    /// `wrapped_row()` (the cursor row is unchanged by the reflow).
    cursor_col_after_shrink: u16,
    /// Expected full-width glyph strings (see `Grid::row_glyphs`, `#` = spacer)
    /// of the rows starting at the row that holds the glyph's continuation
    /// line, after `tail` was fed.
    rows_after_tail: &'static [&'static str],
}

impl Case {
    fn glyph_width(&self) -> u16 {
        if self.wide {
            2
        } else {
            1
        }
    }

    /// Row holding the whole line (prefix + glyph) before the shrink. The
    /// cursor is on this row too.
    fn pre_row(&self) -> u16 {
        self.lines_above
    }

    /// Row the wrapped remainder (glyph first) lands on after the shrink: the
    /// cursor row does not move, and the wrapped-off head of the line (the
    /// narrow prefix) goes on the row above it.
    fn wrapped_row(&self) -> u16 {
        self.lines_above
    }

    /// Row holding the narrow prefix after the shrink.
    fn prefix_row(&self) -> u16 {
        self.lines_above - 1
    }
}

/// Build the pre-shrink screen and assert the rig is what we think it is.
fn build_pre_shrink(c: &Case) -> *mut bc::BBTerm {
    assert_eq!(
        c.prefix.chars().count() as u16 + 1,
        c.new_cols,
        "{}: bad case: prefix must be new_cols-1 narrow cells so the glyph starts in the last \
         new column",
        c.label
    );
    assert!(
        c.lines_above >= 1 && c.wrapped_row() + c.rows_after_tail.len() as u16 <= ROWS,
        "{}: bad case: need a visible prefix row above and room below for the tail rows",
        c.label
    );
    let t = new_term(c.old_cols);
    for _ in 0..c.lines_above {
        feed_str(t, "\r\n");
    }
    feed_str(t, c.prefix);
    feed_str(t, c.glyph);
    feed_str(t, c.after_glyph);

    let g = Grid::take(t);
    let row = c.pre_row();
    let gcol = c.prefix.chars().count() as u16;
    let flags = g.cell(row, gcol).flags;
    if c.wide {
        assert!(
            flags & bc::cell_flags::WIDE_CHAR != 0
                && g.cell(row, gcol + 1).flags & bc::cell_flags::WIDE_CHAR_SPACER != 0,
            "{}: precondition: {:?} must be WIDE_CHAR + WIDE_CHAR_SPACER at row {row} col {gcol}; \
             got flags 0x{:x} / 0x{:x} (row {:?})",
            c.label,
            c.glyph,
            flags,
            g.cell(row, gcol + 1).flags,
            g.row_glyphs(row)
        );
        assert_eq!(
            g.count_with_flag(bc::cell_flags::WIDE_CHAR_SPACER),
            1,
            "{}: precondition: exactly one spacer before the shrink",
            c.label
        );
    } else {
        assert_eq!(
            g.count_with_flag(
                bc::cell_flags::WIDE_CHAR
                    | bc::cell_flags::WIDE_CHAR_SPACER
                    | bc::cell_flags::LEADING_WIDE_CHAR_SPACER
            ),
            0,
            "{}: precondition: narrow control must carry no wide flags",
            c.label
        );
    }
    let want_col = gcol + c.glyph_width() + c.after_glyph.chars().count() as u16;
    assert_eq!(
        (g.cursor_col, g.cursor_row, g.pending_wrap),
        (want_col, row, 0),
        "{}: precondition: cursor (col, row, pending) before the shrink",
        c.label
    );
    assert!(
        g.cursor_col >= c.new_cols,
        "{}: precondition: cursor col {} must be at/beyond the new margin {}",
        c.label,
        g.cursor_col,
        c.new_cols
    );
    t
}

/// Shrink to `c.new_cols` x `ROWS` and assert the resize really applied.
fn shrink(t: *mut bc::BBTerm, c: &Case) {
    let r = unsafe { bc::bb_term_resize2(t, c.new_cols, ROWS) };
    assert_eq!(
        (r.applied_cols, r.applied_rows, r.clamped),
        (c.new_cols, ROWS, 0),
        "{}: precondition: resize2 must apply {}x{} unclamped (applied_cols, applied_rows, \
         clamped)",
        c.label,
        c.new_cols,
        ROWS
    );
}

/// The cases. All are primary-screen, `prefix` = new_cols-1 narrow cells.
fn wide_cases() -> Vec<Case> {
    vec![
        // The reported example: 'abc中' on 8 cols, cursor at col 5, shrink to 4.
        Case {
            label: "cjk 8->4",
            old_cols: 8,
            new_cols: 4,
            lines_above: 2,
            prefix: "abc",
            glyph: "中",
            wide: true,
            after_glyph: "",
            tail: "XY",
            cursor_col_after_shrink: 2,
            rows_after_tail: &["中#XY"],
        },
        // Emoji (East-Asian-Wide by default).
        Case {
            label: "emoji 8->4",
            old_cols: 8,
            new_cols: 4,
            lines_above: 2,
            prefix: "abc",
            glyph: "\u{1F600}",
            wide: true,
            after_glyph: "",
            tail: "XY",
            cursor_col_after_shrink: 2,
            rows_after_tail: &["\u{1F600}#XY"],
        },
        // VS16-promoted symbol: U+26A0 + U+FE0F is promoted to 2 cells.
        Case {
            label: "vs16-promoted 8->4",
            old_cols: 8,
            new_cols: 4,
            lines_above: 2,
            prefix: "abc",
            glyph: "\u{26A0}\u{FE0F}",
            wide: true,
            after_glyph: "",
            tail: "XY",
            cursor_col_after_shrink: 2,
            rows_after_tail: &["\u{26A0}#XY"],
        },
        // Narrower still: margin of 3, so the tail itself wraps again.
        Case {
            label: "cjk 8->3",
            old_cols: 8,
            new_cols: 3,
            lines_above: 2,
            prefix: "ab",
            glyph: "中",
            wide: true,
            after_glyph: "",
            tail: "XY",
            cursor_col_after_shrink: 2,
            rows_after_tail: &["中#X", "Y  "],
        },
        // Wider grid, bigger shrink.
        Case {
            label: "cjk 12->6",
            old_cols: 12,
            new_cols: 6,
            lines_above: 2,
            prefix: "abcde",
            glyph: "中",
            wide: true,
            after_glyph: "",
            tail: "XY",
            cursor_col_after_shrink: 2,
            rows_after_tail: &["中#XY  "],
        },
        // The content line is not the top row.
        Case {
            label: "cjk 8->4 on row 1",
            old_cols: 8,
            new_cols: 4,
            lines_above: 1,
            prefix: "abc",
            glyph: "中",
            wide: true,
            after_glyph: "",
            tail: "XY",
            cursor_col_after_shrink: 2,
            rows_after_tail: &["中#XY"],
        },
    ]
}

/// Same trigger, but narrow text follows the wide glyph before the shrink, so
/// the cursor is past that text instead of directly past the spacer. A
/// correct reflow keeps the cursor attached to the end of that text too.
fn text_after_glyph_cases() -> Vec<Case> {
    vec![Case {
        label: "cjk + 'd' 8->4",
        old_cols: 8,
        new_cols: 4,
        lines_above: 2,
        prefix: "abc",
        glyph: "中",
        wide: true,
        after_glyph: "d",
        tail: "XY",
        cursor_col_after_shrink: 3,
        rows_after_tail: &["中#dX", "Y   "],
    }]
}

/// Narrow-glyph control of the same shape: the cursor ends up beyond the new
/// margin and the line reflows with a plain ASCII 'D' in the last column.
fn ascii_control() -> Case {
    Case {
        label: "ascii control 8->4",
        old_cols: 8,
        new_cols: 4,
        lines_above: 2,
        prefix: "abc",
        glyph: "D",
        wide: false,
        after_glyph: "E",
        tail: "XY",
        cursor_col_after_shrink: 1,
        rows_after_tail: &["EXY "],
    }
}

/// Everything about the screen right after the shrink that does not depend on
/// the cursor: prefix intact, glyph (or its narrow stand-in) wrapped to the
/// start of the next row. Returns human-readable violations.
fn shrunk_screen_violations(g: &Grid, c: &Case) -> Vec<String> {
    let mut out = Vec::new();
    let prefix_row: String = g
        .row_glyphs(c.prefix_row())
        .chars()
        .take(c.prefix.len())
        .collect();
    if prefix_row != c.prefix {
        out.push(format!(
            "{}: narrow prefix on row {} changed: want {:?}, got {:?}",
            c.label,
            c.prefix_row(),
            c.prefix,
            prefix_row
        ));
    }
    // Wide: the glyph itself wraps whole to column 0 of the next row.
    // Narrow control: the glyph still fits in the last column, so it is the
    // text after it that starts the next row.
    let wrapped = g.cell(c.wrapped_row(), 0);
    let first_wrapped = if c.wide { c.glyph } else { c.after_glyph };
    let want_primary = first_wrapped.chars().next().unwrap() as u32;
    if wrapped.ch != want_primary {
        out.push(format!(
            "{}: {:?} did not start row {} at col 0: cell 0 has ch U+{:04X}, row {:?}",
            c.label,
            first_wrapped,
            c.wrapped_row(),
            wrapped.ch,
            g.row_glyphs(c.wrapped_row())
        ));
    }
    if c.wide {
        let has_wide = wrapped.flags & bc::cell_flags::WIDE_CHAR != 0;
        let has_spacer = g.cell(c.wrapped_row(), 1).flags & bc::cell_flags::WIDE_CHAR_SPACER != 0;
        if !(has_wide && has_spacer) {
            out.push(format!(
                "{}: wrapped glyph must be WIDE_CHAR + WIDE_CHAR_SPACER at row {} cols 0-1; \
                 flags 0x{:x} / 0x{:x}, row {:?}",
                c.label,
                c.wrapped_row(),
                wrapped.flags,
                g.cell(c.wrapped_row(), 1).flags,
                g.row_glyphs(c.wrapped_row())
            ));
        }
    }
    out
}

/// Rig sanity: the pre-shrink builder and the narrow control behave as the
/// contract says, and a wide case really is reported with wide flags, so the
/// real tests below cannot pass by the reader being blind to spacers.
#[test]
fn rig_preconditions_hold_for_every_case() {
    let mut cases = wide_cases();
    cases.extend(text_after_glyph_cases());
    cases.push(ascii_control());
    for c in &cases {
        let t = build_pre_shrink(c);
        shrink(t, c);
        let g = Grid::take(t);
        assert_eq!(
            (g.cols, g.rows),
            (c.new_cols, ROWS),
            "{}: snapshot dims after the shrink",
            c.label
        );
        assert_eq!(
            shrunk_screen_violations(&g, c),
            Vec::<String>::new(),
            "{}: reflowed screen (before any new output) violations",
            c.label
        );
        unsafe { bc::bb_term_free(t) };
    }
}

/// Narrow-text control: for plain ASCII the cursor follows the reflowed
/// content and continued output is appended after it, with nothing lost.
/// This pins the expected shape for the wide cases (and must pass unfixed:
/// the bug does not affect ASCII).
#[test]
fn ascii_control_cursor_follows_reflowed_text_and_output_appends() {
    let c = ascii_control();
    let t = build_pre_shrink(&c);
    shrink(t, &c);
    let g = Grid::take(t);
    assert_eq!(
        (g.cursor_col, g.cursor_row, g.pending_wrap),
        (c.cursor_col_after_shrink, c.wrapped_row(), 0),
        "{}: cursor (col, row, pending) right after the shrink; wrapped row glyphs {:?}",
        c.label,
        g.row_glyphs(c.wrapped_row())
    );
    feed_str(t, c.tail);
    let g = Grid::take(t);
    for (i, want) in c.rows_after_tail.iter().enumerate() {
        let row = c.wrapped_row() + i as u16;
        assert_eq!(
            g.row_glyphs(row),
            *want,
            "{}: row {row} after continued output {:?}",
            c.label,
            c.tail
        );
    }
    unsafe { bc::bb_term_free(t) };
}

/// Cursor check shared by the tests: after the shrink the cursor must be on
/// the cell directly past the content it followed (same as for narrow text),
/// on the wrapped row. Returns one message per violating case.
fn cursor_failures(cases: &[Case]) -> Vec<String> {
    let mut failures: Vec<String> = Vec::new();
    for c in cases {
        let t = build_pre_shrink(c);
        shrink(t, c);
        let g = Grid::take(t);
        assert_eq!(
            shrunk_screen_violations(&g, c),
            Vec::<String>::new(),
            "{}: precondition: reflowed screen must hold the prefix and the wrapped glyph before \
             the cursor is judged",
            c.label
        );
        let got = (g.cursor_col, g.cursor_row, g.pending_wrap);
        let want = (c.cursor_col_after_shrink, c.wrapped_row(), 0);
        if got != want {
            let on_spacer =
                g.cell(g.cursor_row, g.cursor_col).flags & bc::cell_flags::WIDE_CHAR_SPACER != 0;
            failures.push(format!(
                "{}: cursor (col, row, pending) after shrink: want {:?}, got {:?} \
                 (cursor cell is a WIDE_CHAR_SPACER: {on_spacer}); wrapped row {:?}",
                c.label,
                want,
                got,
                g.row_glyphs(c.wrapped_row())
            ));
        }
        unsafe { bc::bb_term_free(t) };
    }
    failures
}

/// Data-loss check shared by the tests: after the shrink, ordinary output
/// continues from the cursor. The wide glyph must still be there, followed by
/// the new text, in the snapshot and in the copy path. Returns one message per
/// violation.
fn continued_output_failures(cases: &[Case]) -> Vec<String> {
    let mut failures: Vec<String> = Vec::new();
    for c in cases {
        let t = build_pre_shrink(c);
        shrink(t, c);
        feed_str(t, c.tail);
        let g = Grid::take(t);

        for (i, want) in c.rows_after_tail.iter().enumerate() {
            let row = c.wrapped_row() + i as u16;
            let got = g.row_glyphs(row);
            if got != *want {
                failures.push(format!(
                    "{}: row {row} glyphs after continued output {:?}: want {:?}, got {:?} \
                     ('#' = WIDE_CHAR_SPACER, '<' = LEADING_WIDE_CHAR_SPACER)",
                    c.label, c.tail, want, got
                ));
            }
            let want_text = want.replace('#', "").trim_end().to_string();
            let got_text = row_text_without_marks(t, row, g.cols);
            if got_text != want_text {
                failures.push(format!(
                    "{}: copy-path text of row {row} after continued output {:?}: want {:?}, \
                     got {:?}",
                    c.label, c.tail, want_text, got_text
                ));
            }
        }
        let wide_count = g.count_with_flag(bc::cell_flags::WIDE_CHAR);
        if wide_count != 1 {
            failures.push(format!(
                "{}: exactly one WIDE_CHAR cell must survive the shrink + output, found \
                 {wide_count}; rows {:?} / {:?}",
                c.label,
                g.row_glyphs(c.prefix_row()),
                g.row_glyphs(c.wrapped_row())
            ));
        }
        let orphans = g.orphan_spacers();
        if !orphans.is_empty() {
            failures.push(format!("{}: orphan spacers: {orphans:?}", c.label));
        }
        unsafe { bc::bb_term_free(t) };
    }
    failures
}

/// The cursor must follow the content: directly right of the wrapped glyph's
/// spacer, never ON the spacer (the bug parks it one cell to the left).
#[test]
fn cursor_after_shrink_is_past_the_wrapped_wide_glyph_not_on_its_spacer() {
    assert_eq!(
        cursor_failures(&wide_cases()),
        Vec::<String>::new(),
        "after a column shrink that wraps a wide glyph, the cursor must sit just past the glyph \
         (same as for narrow text), not on its spacer"
    );
}

/// The user-visible data loss: continued output after the shrink must leave
/// the wrapped wide glyph intact and append the new text to its right.
#[test]
fn continued_output_after_shrink_keeps_the_wide_glyph() {
    assert_eq!(
        continued_output_failures(&wide_cases()),
        Vec::<String>::new(),
        "continuing to print after a column shrink must keep the wrapped wide glyph and append \
         the new text to its right"
    );
}

/// Same trigger with narrow text between the glyph and the cursor: the cursor
/// stays attached to the end of that text (it is drawn one cell left of where
/// the program believes it is otherwise), and continued output appends to it.
#[test]
fn cursor_past_text_following_the_wrapped_wide_glyph_stays_attached_to_it() {
    let cases = text_after_glyph_cases();
    let mut failures = cursor_failures(&cases);
    failures.extend(continued_output_failures(&cases));
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "a cursor past text that follows a wrapped wide glyph must keep its position relative to \
         that text"
    );
}
