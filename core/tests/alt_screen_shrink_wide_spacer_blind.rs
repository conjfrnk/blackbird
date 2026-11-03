//! Blind regression tests for "alt-screen column shrink leaves a WIDE_CHAR cell
//! in the last column with no spacer".
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and the
//! documented behaviour only, never the implementation.
//!
//! Contract under test:
//!   - A wide glyph (CJK, emoji) is two cells: a `WIDE_CHAR` head and a
//!     `WIDE_CHAR_SPACER` directly to its right (BBCore.h: "the renderer draws
//!     the glyph from this cell occupying two cell widths" / "the wide one in
//!     the preceding cell already covers it"). A head with no spacer cell
//!     after it cannot exist: the renderer would draw a two-cell glyph from
//!     the last column and let it overhang the grid edge, and copy / find
//!     would see a glyph that is only half on screen.
//!   - The alternate screen (DECSET 1049) does not reflow on a column resize,
//!     it just narrows each row. When the new right edge falls BETWEEN a
//!     glyph's head and its spacer (an odd cut through double-width text) the
//!     glyph no longer fits. Terminals erase such a half glyph rather than
//!     keep a head the grid has no room for. So after the shrink:
//!       * no `WIDE_CHAR` cell may be the last cell of a row (or otherwise
//!         lack a `WIDE_CHAR_SPACER` directly right of it);
//!       * every glyph that still fits whole, to the left of the cut, is left
//!         exactly as it was (head + spacer);
//!       * the copy path (`bb_term_text_range`) yields only the whole
//!         glyphs, never the cut one.
//!   - A cut that falls on a glyph boundary is harmless: nothing is lost.
//!
//! The report: `\e[?1049h\e[H中中中中中` on a 10-column terminal fills the row
//! with five glyphs (heads at columns 0, 2, 4, 6, 8; spacers at 1, 3, 5, 7,
//! 9). `bb_term_resize2(9, 4)` then cuts between the head at column 8 and its
//! spacer at column 9, and the unfixed core leaves the head at column 8 with
//! no spacer.
//!
//! Scope kept deliberately to the shrink: it does not pin what blank the cut
//! cell turns into, the cursor position, or anything about widening.
//!
//! Rig preconditions are asserted for every case (alt screen really active,
//! the pre-shrink glyph layout, the applied resize, the post-shrink dims),
//! plus controls (boundary cuts on the alt screen, odd cuts on the primary
//! screen) that must hold on both unfixed and fixed code, so a vacuous pass
//! is impossible and a fix that over-clears is caught.
//!
//! Pre-flight cost: grids <= 12x4, scrollback 16 -> a few KB per terminal.
//! Inputs are < 100 bytes. No sleeps, I/O, threads.

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
    mode: u32,
    cells: Vec<bc::BBCell>,
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
                mode: (*snap).mode,
                cells,
            };
            bc::bb_snap_release(snap);
            g
        }
    }

    fn cell(&self, row: u16, col: u16) -> bc::BBCell {
        assert!(row < self.rows && col < self.cols);
        self.cells[(row as usize) * (self.cols as usize) + col as usize]
    }

    fn alt_screen(&self) -> bool {
        self.mode & bc::bb_mode::ALT_SCREEN != 0
    }

    /// One char per cell: the cell's glyph (`ch == 0` shown as a space), `#`
    /// for a `WIDE_CHAR_SPACER`, `<` for a `LEADING_WIDE_CHAR_SPACER`. Wide
    /// head cells show their own scalar.
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

    /// Violations of the documented head/spacer invariant over the WHOLE
    /// grid: a `WIDE_CHAR` head must have a `WIDE_CHAR_SPACER` directly right
    /// of it in the same row (so never in the last column), and a
    /// `WIDE_CHAR_SPACER` must sit directly right of a `WIDE_CHAR` head.
    fn wide_pair_violations(&self) -> Vec<String> {
        let mut out = Vec::new();
        for row in 0..self.rows {
            for col in 0..self.cols {
                let c = self.cell(row, col);
                if c.flags & bc::cell_flags::WIDE_CHAR != 0 {
                    let has_spacer = col + 1 < self.cols
                        && self.cell(row, col + 1).flags & bc::cell_flags::WIDE_CHAR_SPACER != 0;
                    if !has_spacer {
                        out.push(format!(
                            "row {row} col {col} (last col is {}): WIDE_CHAR U+{:04X} with no \
                             WIDE_CHAR_SPACER right of it (flags 0x{:x}, row glyphs {:?})",
                            self.cols - 1,
                            c.ch,
                            c.flags,
                            self.row_glyphs(row)
                        ));
                    }
                }
                if c.flags & bc::cell_flags::WIDE_CHAR_SPACER != 0 {
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
        }
        out
    }
}

/// `row` extracted through the copy path (`bb_term_text_range`, prose mode),
/// columns `0..cols`, trailing blanks trimmed.
fn row_text(term: *mut bc::BBTerm, row: u16, cols: u16) -> String {
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
        s.trim_end().to_string()
    }
}

/// One line of a case: `text` is painted on grid row `index` (CUP, so nothing
/// scrolls), `before` is the expected full-width glyph string right after
/// painting (see `Grid::row_glyphs`, `#` = spacer) and `survivors` the glyph
/// string of the leading cells that must come through the shrink untouched
/// (everything left of the cut). All cells of the row at or right of
/// `survivors.chars().count()` must not be a `WIDE_CHAR` head.
struct Line {
    text: &'static str,
    before: &'static str,
    survivors: &'static str,
}

struct Case {
    label: &'static str,
    old_cols: u16,
    new_cols: u16,
    lines: &'static [Line],
}

impl Case {
    fn survivor_cells(line: &Line) -> u16 {
        line.survivors.chars().count() as u16
    }
}

/// Build the pre-shrink screen, on the alternate screen (`alt`) or the
/// primary one, and assert the rig is what we think it is.
fn build_pre_shrink(c: &Case, alt: bool) -> *mut bc::BBTerm {
    assert!(
        c.lines.len() as u16 <= ROWS,
        "{}: bad case: more lines than rows",
        c.label
    );
    let t = new_term(c.old_cols);
    if alt {
        feed_str(t, "\x1b[?1049h");
    }
    for (i, line) in c.lines.iter().enumerate() {
        feed_str(t, &format!("\x1b[{};1H{}", i + 1, line.text));
    }
    let g = Grid::take(t);
    assert_eq!(
        (g.cols, g.rows),
        (c.old_cols, ROWS),
        "{}: precondition: pre-shrink snapshot dims",
        c.label
    );
    assert_eq!(
        g.alt_screen(),
        alt,
        "{}: precondition: ALT_SCREEN mode bit (mode 0x{:x}) must be {alt}",
        c.label,
        g.mode
    );
    for (i, line) in c.lines.iter().enumerate() {
        assert_eq!(
            line.before.chars().count() as u16,
            c.old_cols,
            "{}: bad case: `before` must be old_cols glyphs wide",
            c.label
        );
        assert_eq!(
            g.row_glyphs(i as u16),
            line.before,
            "{}: precondition: row {i} glyph layout before the shrink ('#' = WIDE_CHAR_SPACER)",
            c.label
        );
    }
    assert_eq!(
        g.wide_pair_violations(),
        Vec::<String>::new(),
        "{}: precondition: every head has its spacer before the shrink",
        c.label
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

/// Alt-screen cases whose new right edge falls BETWEEN a glyph's head and its
/// spacer. The glyph straddling the edge no longer fits.
fn odd_cut_cases() -> Vec<Case> {
    vec![
        // The report: five CJK glyphs, 10 -> 9, head at col 8 loses its spacer.
        Case {
            label: "cjk x5, 10->9 (the report)",
            old_cols: 10,
            new_cols: 9,
            lines: &[Line {
                text: "中中中中中",
                before: "中#中#中#中#中#",
                survivors: "中#中#中#中#",
            }],
        },
        // A bigger odd shrink: the edge now cuts the glyph at cols 6-7.
        Case {
            label: "cjk x5, 10->7",
            old_cols: 10,
            new_cols: 7,
            lines: &[Line {
                text: "中中中中中",
                before: "中#中#中#中#中#",
                survivors: "中#中#中#",
            }],
        },
        // Cut through the very first glyph.
        Case {
            label: "cjk x5, 10->3",
            old_cols: 10,
            new_cols: 3,
            lines: &[Line {
                text: "中中中中中",
                before: "中#中#中#中#中#",
                survivors: "中#",
            }],
        },
        // Narrow text, then one wide glyph whose head is at W-2.
        Case {
            label: "narrow prefix + cjk, 10->9",
            old_cols: 10,
            new_cols: 9,
            lines: &[Line {
                text: "abcdefgh中",
                before: "abcdefgh中#",
                survivors: "abcdefgh",
            }],
        },
        // Emoji (East-Asian-Wide by default).
        Case {
            label: "emoji x5, 10->9",
            old_cols: 10,
            new_cols: 9,
            lines: &[Line {
                text: "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}",
                before: "\u{1F600}#\u{1F600}#\u{1F600}#\u{1F600}#\u{1F600}#",
                survivors: "\u{1F600}#\u{1F600}#\u{1F600}#\u{1F600}#",
            }],
        },
        // Wider grid, old width 12.
        Case {
            label: "cjk x6, 12->11",
            old_cols: 12,
            new_cols: 11,
            lines: &[Line {
                text: "中中中中中中",
                before: "中#中#中#中#中#中#",
                survivors: "中#中#中#中#中#",
            }],
        },
        // Odd old width, glyph heads on odd columns.
        Case {
            label: "narrow + cjk x5 (heads on odd cols), 11->10",
            old_cols: 11,
            new_cols: 10,
            lines: &[Line {
                text: "a中中中中中",
                before: "a中#中#中#中#中#",
                survivors: "a中#中#中#中#",
            }],
        },
        // Several rows cut at once, mixed glyph kinds.
        Case {
            label: "three rows, 10->9",
            old_cols: 10,
            new_cols: 9,
            lines: &[
                Line {
                    text: "中中中中中",
                    before: "中#中#中#中#中#",
                    survivors: "中#中#中#中#",
                },
                Line {
                    text: "\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}",
                    before: "\u{1F600}#\u{1F600}#\u{1F600}#\u{1F600}#\u{1F600}#",
                    survivors: "\u{1F600}#\u{1F600}#\u{1F600}#\u{1F600}#",
                },
                Line {
                    text: "abcdefgh中",
                    before: "abcdefgh中#",
                    survivors: "abcdefgh",
                },
            ],
        },
    ]
}

/// Alt-screen cases whose new right edge falls on a glyph boundary: nothing
/// is cut, every glyph must come through whole.
fn boundary_cut_cases() -> Vec<Case> {
    vec![
        Case {
            label: "cjk x5, 10->8 (boundary)",
            old_cols: 10,
            new_cols: 8,
            lines: &[Line {
                text: "中中中中中",
                before: "中#中#中#中#中#",
                survivors: "中#中#中#中#",
            }],
        },
        Case {
            label: "cjk x5, 10->6 (boundary)",
            old_cols: 10,
            new_cols: 6,
            lines: &[Line {
                text: "中中中中中",
                before: "中#中#中#中#中#",
                survivors: "中#中#中#",
            }],
        },
        Case {
            label: "narrow + cjk x5 (heads on odd cols), 11->9 (boundary)",
            old_cols: 11,
            new_cols: 9,
            lines: &[Line {
                text: "a中中中中中",
                before: "a中#中#中#中#中#",
                survivors: "a中#中#中#中#",
            }],
        },
    ]
}

/// Rig sanity, and the guard against a fix that over-clears: for every case
/// the pre-shrink layout is what the contract says, the resize really
/// applied, the alt screen is still active, and every glyph left of the cut
/// is still intact (head + spacer) afterwards. Passes unfixed.
#[test]
fn rig_preconditions_hold_and_whole_glyphs_left_of_the_cut_survive() {
    let mut cases = odd_cut_cases();
    cases.extend(boundary_cut_cases());
    for c in &cases {
        let t = build_pre_shrink(c, true);
        shrink(t, c);
        let g = Grid::take(t);
        assert_eq!(
            (g.cols, g.rows),
            (c.new_cols, ROWS),
            "{}: snapshot dims after the shrink",
            c.label
        );
        assert!(
            g.alt_screen(),
            "{}: precondition: still on the alt screen after the shrink (mode 0x{:x})",
            c.label,
            g.mode
        );
        for (i, line) in c.lines.iter().enumerate() {
            let n = Case::survivor_cells(line) as usize;
            let got: String = g.row_glyphs(i as u16).chars().take(n).collect();
            assert_eq!(
                got, line.survivors,
                "{}: row {i}: the glyphs left of the cut must be untouched by the shrink",
                c.label
            );
        }
        unsafe { bc::bb_term_free(t) };
    }
}

/// The exact trigger from the report, with the bytes spelled out: the head of
/// the fifth glyph is at column 8, so after narrowing 10 -> 9 column 8 is the
/// last column and must not remain a `WIDE_CHAR` head.
#[test]
fn reported_trigger_does_not_leave_a_wide_char_in_the_last_column() {
    let t = new_term(10);
    feed_str(t, "\x1b[?1049h\x1b[H中中中中中");
    let before = Grid::take(t);
    assert!(
        before.alt_screen(),
        "precondition: alt screen active (mode 0x{:x})",
        before.mode
    );
    assert_eq!(
        before.row_glyphs(0),
        "中#中#中#中#中#",
        "precondition: five glyphs fill row 0 of the 10-column alt screen ('#' = WIDE_CHAR_SPACER)"
    );
    assert_ne!(
        before.cell(0, 8).flags & bc::cell_flags::WIDE_CHAR,
        0,
        "precondition: the fifth glyph's head is the WIDE_CHAR at col 8 before the shrink"
    );

    let r = unsafe { bc::bb_term_resize2(t, 9, ROWS) };
    assert_eq!(
        (r.applied_cols, r.applied_rows, r.clamped),
        (9, ROWS, 0),
        "precondition: resize2 must apply 9x{ROWS} unclamped"
    );

    let after = Grid::take(t);
    assert_eq!(
        (after.cols, after.rows),
        (9, ROWS),
        "snapshot dims after the shrink"
    );
    let last = after.cell(0, 8);
    assert_eq!(
        last.flags & bc::cell_flags::WIDE_CHAR,
        0,
        "col 8 is now the LAST column of row 0: it cannot hold a double-width head (its spacer \
         was cut off), but cell flags are 0x{:x}, ch U+{:04X}; row 0 glyphs {:?}",
        last.flags,
        last.ch,
        after.row_glyphs(0)
    );
    unsafe { bc::bb_term_free(t) };
}

/// The invariant over many shapes: after an odd alt-screen shrink no row may
/// hold a `WIDE_CHAR` head without a `WIDE_CHAR_SPACER` right of it, and no
/// cell right of the surviving glyphs may be a head.
#[test]
fn odd_alt_screen_shrink_leaves_no_wide_char_head_without_its_spacer() {
    let mut failures: Vec<String> = Vec::new();
    for c in &odd_cut_cases() {
        let t = build_pre_shrink(c, true);
        shrink(t, c);
        let g = Grid::take(t);
        for v in g.wide_pair_violations() {
            failures.push(format!("{}: {v}", c.label));
        }
        for (i, line) in c.lines.iter().enumerate() {
            let row = i as u16;
            for col in Case::survivor_cells(line)..g.cols {
                let cell = g.cell(row, col);
                if cell.flags & bc::cell_flags::WIDE_CHAR != 0 {
                    failures.push(format!(
                        "{}: row {row} col {col} is right of the cut but still a WIDE_CHAR head \
                         (ch U+{:04X}); row glyphs {:?}",
                        c.label,
                        cell.ch,
                        g.row_glyphs(row)
                    ));
                }
            }
        }
        unsafe { bc::bb_term_free(t) };
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "narrowing the alt screen so the new edge falls between a glyph's head and spacer must \
         not leave a WIDE_CHAR head without its spacer"
    );
}

/// Copy path: the glyph that no longer fits must not be copied (it is not on
/// screen any more); only the whole glyphs left of the cut are.
#[test]
fn odd_alt_screen_shrink_copy_path_yields_only_whole_glyphs() {
    let mut failures: Vec<String> = Vec::new();
    for c in &odd_cut_cases() {
        let t = build_pre_shrink(c, true);
        shrink(t, c);
        let g = Grid::take(t);
        for (i, line) in c.lines.iter().enumerate() {
            let row = i as u16;
            let want = line.survivors.replace('#', "").trim_end().to_string();
            let got = row_text(t, row, g.cols);
            if got != want {
                failures.push(format!(
                    "{}: copy-path text of row {row}: want {:?}, got {:?}; row glyphs {:?}",
                    c.label,
                    want,
                    got,
                    g.row_glyphs(row)
                ));
            }
        }
        unsafe { bc::bb_term_free(t) };
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "after an odd alt-screen shrink, copy must see only the glyphs that still fit whole"
    );
}

/// Control: a cut on a glyph boundary loses nothing and leaves no half glyph.
/// Passes unfixed; guards a fix that clears too much.
#[test]
fn boundary_alt_screen_shrink_keeps_every_whole_glyph_and_copies_it() {
    let mut failures: Vec<String> = Vec::new();
    for c in &boundary_cut_cases() {
        let t = build_pre_shrink(c, true);
        shrink(t, c);
        let g = Grid::take(t);
        for v in g.wide_pair_violations() {
            failures.push(format!("{}: {v}", c.label));
        }
        for (i, line) in c.lines.iter().enumerate() {
            let row = i as u16;
            let want_glyphs = line.survivors;
            if g.row_glyphs(row) != want_glyphs {
                failures.push(format!(
                    "{}: row {row} glyphs: want {:?}, got {:?}",
                    c.label,
                    want_glyphs,
                    g.row_glyphs(row)
                ));
            }
            let want_text = want_glyphs.replace('#', "").trim_end().to_string();
            let got_text = row_text(t, row, g.cols);
            if got_text != want_text {
                failures.push(format!(
                    "{}: copy-path text of row {row}: want {:?}, got {:?}",
                    c.label, want_text, got_text
                ));
            }
        }
        unsafe { bc::bb_term_free(t) };
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "a shrink whose edge lies on a glyph boundary must keep every glyph"
    );
}

/// Control: the same shapes on the PRIMARY screen reflow, so the glyph that
/// no longer fits wraps whole; there is never a head without a spacer.
/// Passes unfixed; pins that the invariant checker agrees with a correct path.
#[test]
fn primary_screen_odd_shrink_control_keeps_head_spacer_pairs() {
    let mut failures: Vec<String> = Vec::new();
    for c in &odd_cut_cases() {
        let t = build_pre_shrink(c, false);
        shrink(t, c);
        let g = Grid::take(t);
        assert!(
            !g.alt_screen(),
            "{}: precondition: primary screen stays primary",
            c.label
        );
        for v in g.wide_pair_violations() {
            failures.push(format!("{}: {v}", c.label));
        }
        unsafe { bc::bb_term_free(t) };
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "primary-screen reflow must never leave a WIDE_CHAR head without its spacer"
    );
}
