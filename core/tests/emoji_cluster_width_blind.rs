//! Blind regression tests for the "emoji ZWJ / skin-tone / VS16+ZWJ clusters
//! advance the cursor by the SUM of their parts" width-drift bug.
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`), the
//! documented behaviour in `unicode_cells.rs`, and the observable contract
//! only, never the implementation.
//!
//! Contract under test (the same one `unicode_cells.rs` documents for VS16
//! emoji and keycaps, extended to the other multi-scalar emoji clusters):
//!   - An emoji grapheme cluster that `string-width` / `Bun.stringWidth` (and
//!     therefore Ink and Claude Code) measure as 2 terminal columns occupies
//!     EXACTLY two cells: one `WIDE_CHAR` cell plus one `WIDE_CHAR_SPACER`
//!     cell, and the cursor advances by 2. That covers
//!       * an emoji with a skin-tone modifier      (U+1F44D U+1F3FD),
//!       * a ZWJ sequence                          (U+1F469 U+200D U+1F4BB),
//!       * ZWJ sequences with a skin tone,
//!       * ZWJ sequences containing VS16           (U+1F468 U+200D U+2695 U+FE0F,
//!                                                  U+2764 U+FE0F U+200D U+1F525),
//!       * ZWJ sequences that end in an Arrows-block symbol
//!                                                 (U+1F642 U+200D U+2194 U+FE0F),
//!       * a text-default (1-column) base with a skin-tone modifier and no VS16
//!                                                 (U+270C U+1F3FD, U+1F3CB U+1F3FD U+200D
//!                                                  U+2640 U+FE0F).
//!   - The ZWJ, the modifier and the joined components are zero-width pieces
//!     of the cluster: they never take a column of their own, never land in
//!     the next cell and never wrap onto the next row by themselves.
//!   - Consequently a program that counts columns per grapheme cluster (Ink's
//!     `eraseLines(n)` / cursor-relative redraw) and the grid agree: 78 ASCII
//!     chars + a woman technologist is exactly 80 columns on ONE row at 80
//!     columns; 39 thumbs-up-with-skin-tone are 78 columns on ONE row.
//!   - Copy (`bb_term_text_range`) over the cluster's two cells returns the
//!     whole original cluster, not a fragment of it.
//!
//! How the bug is observed: `bb_term_take_snapshot` gives per-cell
//! `ch`/`flags` plus the cursor; `bb_term_text_range` gives the copy-path
//! text. Unfixed, every extra scalar that is itself a wide emoji (the skin-tone
//! swatch, the laptop, ...) is laid out as a NEW 2-cell glyph after the base,
//! so a cluster spans 4-6 columns and a long line spills onto extra rows.
//!
//! Rig preconditions are asserted in every test (see
//! `assert_rig_preconditions`) so a vacuous pass is impossible.
//!
//! Guard tests (section 6) pin where a mark must NOT join the previous glyph:
//! after ASCII, after cursor motion, in insert mode, in the last column, and
//! once the base cell's zero-width list is full.
//!
//! Pre-flight cost: grids are at most 80x4 (320 cells, ~6 KB) with 16 lines
//! of scrollback; inputs are at most ~500 bytes; the byte-split test makes at
//! most ~50 tiny feeds. No sleeps, I/O or threads.

use blackbird_core as bc;

const SCROLLBACK: u32 = 16;

// Single clusters under test. Every one of them is 2 columns wide to
// string-width.
const THUMBS_SKIN: &str = "\u{1F44D}\u{1F3FD}"; // thumbs up + medium skin tone
const WAVE_DARK: &str = "\u{1F44B}\u{1F3FF}"; // waving hand + dark skin tone
const WOMAN_TECH: &str = "\u{1F469}\u{200D}\u{1F4BB}"; // woman technologist
const WOMAN_TECH_SKIN: &str = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"; // + skin tone
const FAMILY: &str = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"; // man woman girl
const HEALTH_WORKER: &str = "\u{1F468}\u{200D}\u{2695}\u{FE0F}"; // VS16 after the ZWJ
const HEART_ON_FIRE: &str = "\u{2764}\u{FE0F}\u{200D}\u{1F525}"; // VS16 before the ZWJ
const RAINBOW_FLAG: &str = "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"; // VS16 + ZWJ
const SHRUG_WOMAN: &str = "\u{1F937}\u{200D}\u{2640}\u{FE0F}"; // wide + ZWJ + VS16 symbol
const HANDSHAKE_TONES: &str = "\u{1F9D1}\u{1F3FB}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}\u{1F3FF}"; // 2 people, 2 tones, 2 ZWJ

const HEAD_SHAKE_H: &str = "\u{1F642}\u{200D}\u{2194}\u{FE0F}"; // Emoji 15.1, arrow U+2194
const HEAD_SHAKE_V: &str = "\u{1F642}\u{200D}\u{2195}\u{FE0F}"; // Emoji 15.1, arrow U+2195
const VICTORY_SKIN: &str = "\u{270C}\u{1F3FD}"; // text-default base + tone, no VS16
const POINT_UP_SKIN: &str = "\u{261D}\u{1F3FD}"; // text-default base + tone, no VS16
const WEIGHTLIFTER_WOMAN_SKIN: &str = "\u{1F3CB}\u{1F3FD}\u{200D}\u{2640}\u{FE0F}"; // narrow base, tone, ZWJ, VS16

const CLUSTERS: [(&str, &str); 15] = [
    ("thumbs up + skin tone", THUMBS_SKIN),
    ("waving hand + dark skin tone", WAVE_DARK),
    ("woman technologist (ZWJ)", WOMAN_TECH),
    (
        "woman technologist + skin tone (tone + ZWJ)",
        WOMAN_TECH_SKIN,
    ),
    ("family man/woman/girl (2 ZWJ)", FAMILY),
    ("man health worker (ZWJ then VS16)", HEALTH_WORKER),
    ("heart on fire (VS16 then ZWJ)", HEART_ON_FIRE),
    ("rainbow flag (VS16 then ZWJ)", RAINBOW_FLAG),
    ("woman shrugging (ZWJ then VS16 symbol)", SHRUG_WOMAN),
    (
        "handshake, two skin tones (2 ZWJ + 2 tones)",
        HANDSHAKE_TONES,
    ),
    ("head shaking horizontally (ZWJ + U+2194)", HEAD_SHAKE_H),
    ("head shaking vertically (ZWJ + U+2195)", HEAD_SHAKE_V),
    ("victory hand + skin tone (narrow base)", VICTORY_SKIN),
    ("index pointing up + skin tone (narrow base)", POINT_UP_SKIN),
    (
        "woman lifting weights + skin tone (narrow base, tone, ZWJ, VS16)",
        WEIGHTLIFTER_WOMAN_SKIN,
    ),
];

const ANY_WIDE_FLAG: u16 = bc::cell_flags::WIDE_CHAR
    | bc::cell_flags::WIDE_CHAR_SPACER
    | bc::cell_flags::LEADING_WIDE_CHAR_SPACER;

/// Owning wrapper so a failing assertion still frees the terminal.
struct Term(*mut bc::BBTerm);

impl Term {
    fn new(cols: u16, rows: u16) -> Term {
        let t = unsafe { bc::bb_term_new(cols, rows, SCROLLBACK) };
        assert!(!t.is_null(), "bb_term_new({cols}, {rows}) returned null");
        Term(t)
    }

    fn feed(&self, s: &str) {
        unsafe { bc::bb_term_input(self.0, s.as_ptr(), s.len()) };
    }

    fn feed_bytes(&self, b: &[u8]) {
        unsafe { bc::bb_term_input(self.0, b.as_ptr(), b.len()) };
    }

    fn grid(&self) -> Grid {
        Grid::take(self.0)
    }

    /// Copy-path text for `[(line, c0) .. (line, c1)]`, prose mode.
    fn text_range(&self, line: i32, c0: u16, c1: u16) -> String {
        unsafe {
            let raw = bc::bb_term_text_range(self.0, line, c0, line, c1, 0);
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
            s
        }
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        unsafe { bc::bb_term_free(self.0) };
    }
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

    fn is_blank(c: &bc::BBCell) -> bool {
        (c.ch == 0 || c.ch == b' ' as u32) && c.flags & ANY_WIDE_FLAG == 0
    }

    /// One char per cell: the cell's glyph (blank shown as a space), `#` for
    /// a `WIDE_CHAR_SPACER`, `<` for a `LEADING_WIDE_CHAR_SPACER`. A wide
    /// glyph cell shows its own base scalar.
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

    /// The cursor column the PROGRAM believes in: the grid column plus one if
    /// the cursor is parked on the last written cell with a pending wrap.
    fn logical_col(&self) -> u32 {
        self.cursor_col as u32 + self.pending_wrap as u32
    }

    /// `(row, col, flags & wide-mask)` of every cell with any wide flag.
    fn wide_flagged_cells(&self) -> Vec<(u16, u16, u16)> {
        let mut out = Vec::new();
        for row in 0..self.rows {
            for col in 0..self.cols {
                let f = self.cell(row, col).flags & ANY_WIDE_FLAG;
                if f != 0 {
                    out.push((row, col, f));
                }
            }
        }
        out
    }

    /// Rows that hold anything other than blanks.
    fn non_blank_rows(&self) -> Vec<u16> {
        (0..self.rows)
            .filter(|&r| (0..self.cols).any(|c| !Grid::is_blank(&self.cell(r, c))))
            .collect()
    }

    /// Spacer-must-follow-wide invariant (documented on `WIDE_CHAR_SPACER`).
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
                        "row {row} col {col}: WIDE_CHAR_SPACER not preceded by WIDE_CHAR"
                    ));
                }
            }
        }
        out
    }
}

fn blanks(n: usize) -> String {
    " ".repeat(n)
}

/// Rig preconditions. Without these a green run could mean "the snapshot
/// reader is blind to wide flags", "the cursor accessor is stuck at 0" or
/// "text_range never returns anything".
///
///   1. ASCII lands one cell per char and the cursor follows.
///   2. A native wide emoji (U+1F600, Emoji_Presentation) really is
///      WIDE_CHAR + WIDE_CHAR_SPACER, advances the cursor by 2, and the next
///      ASCII char lands right after it (so "cluster then marker at col 2"
///      checks in the real tests are meaningful).
///   3. A VS16 emoji (U+26A0 U+FE0F), the already-fixed sibling of this bug,
///      is 2 columns: the cluster assertions below hold for it today.
///   4. Copy over the wide emoji's two cells returns the glyph.
fn assert_rig_preconditions() {
    let t = Term::new(20, 3);
    t.feed("abc");
    let g = t.grid();
    assert_eq!(
        (g.row_glyphs(0), g.cursor_col, g.cursor_row),
        ("abc".to_string() + &blanks(17), 3, 0),
        "precondition: plain ASCII must read back verbatim with the cursor after it"
    );

    let t = Term::new(20, 3);
    t.feed("x\u{1F600}y");
    let g = t.grid();
    assert_eq!(
        g.row_glyphs(0),
        "x\u{1F600}#y".to_string() + &blanks(16),
        "precondition: native wide emoji must be glyph + spacer ('#') and 'y' right after"
    );
    assert_eq!(
        g.wide_flagged_cells(),
        vec![
            (0, 1, bc::cell_flags::WIDE_CHAR),
            (0, 2, bc::cell_flags::WIDE_CHAR_SPACER)
        ],
        "precondition: exactly one WIDE_CHAR + one WIDE_CHAR_SPACER expected (row, col, flags)"
    );
    assert_eq!(
        g.cursor_col, 4,
        "precondition: x + wide emoji + y puts the cursor at column 4"
    );
    assert_eq!(
        t.text_range(0, 1, 2),
        "\u{1F600}",
        "precondition: copy over the wide emoji's two cells must return the glyph"
    );

    let t = Term::new(20, 3);
    t.feed("\u{26A0}\u{FE0F}");
    let g = t.grid();
    assert_eq!(
        g.cursor_col, 2,
        "precondition: the VS16 emoji (already supported) must advance the cursor by 2"
    );
    assert_eq!(
        g.wide_flagged_cells().len(),
        2,
        "precondition: the VS16 emoji must be one WIDE_CHAR + one spacer; got {:?}",
        g.wide_flagged_cells()
    );
}

// ---------------------------------------------------------------------------
// 1. Each cluster is exactly two columns.
// ---------------------------------------------------------------------------

#[test]
fn every_two_column_emoji_cluster_advances_cursor_by_exactly_two() {
    assert_rig_preconditions();

    // One failure line per cluster, so a red run lists every offender once.
    let mut failures: Vec<String> = Vec::new();
    for (label, cluster) in CLUSTERS {
        let base = cluster.chars().next().unwrap();

        // (a) The cluster alone: cursor +2, one wide glyph + one spacer, the
        //     base scalar in cell (0,0), no other ink anywhere.
        let t = Term::new(20, 3);
        t.feed(cluster);
        let g = t.grid();
        let want_wide = vec![
            (0u16, 0u16, bc::cell_flags::WIDE_CHAR),
            (0, 1, bc::cell_flags::WIDE_CHAR_SPACER),
        ];
        let want_row0 = format!("{base}#{}", blanks(18));
        let alone_ok = (g.cursor_col, g.cursor_row, g.pending_wrap) == (2, 0, 0)
            && g.wide_flagged_cells() == want_wide
            && g.row_glyphs(0) == want_row0
            && g.non_blank_rows() == vec![0u16]
            && g.orphan_spacers().is_empty();

        // (b) A marker typed right after the cluster lands in column 2.
        let t = Term::new(20, 3);
        t.feed(cluster);
        t.feed("|");
        let g2 = t.grid();
        let want_marked = format!("{base}#|{}", blanks(17));
        let marked_ok = g2.row_glyphs(0) == want_marked && g2.cursor_col == 3;

        if !(alone_ok && marked_ok) {
            failures.push(format!(
                "{label}: alone -> cursor (col {}, row {}, pending {}) want (2, 0, 0), \
                 wide cells {} want 2, row 0 {:?}; with '|' -> row 0 {:?}, cursor col {} want 3",
                g.cursor_col,
                g.cursor_row,
                g.pending_wrap,
                g.wide_flagged_cells().len(),
                g.row_glyphs(0),
                g2.row_glyphs(0),
                g2.cursor_col
            ));
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "every 2-column (string-width) emoji cluster must take exactly 1 wide cell + 1 spacer \
         ('#' = spacer in the row dumps)"
    );
}

// ---------------------------------------------------------------------------
// 2. The exact end-user scenarios: line width and wrapping at 80 columns.
// ---------------------------------------------------------------------------

#[test]
fn ascii_plus_woman_technologist_is_exactly_80_columns_on_one_row() {
    assert_rig_preconditions();
    // 78 'x' + woman technologist = 80 columns to Ink / string-width.
    let t = Term::new(80, 4);
    t.feed(&"x".repeat(78));
    t.feed(WOMAN_TECH);
    let g = t.grid();

    assert_eq!(
        g.row_glyphs(0),
        format!("{}\u{1F469}#", "x".repeat(78)),
        "row 0 must be 78 x + the woman technologist (glyph + spacer)"
    );
    assert_eq!(
        g.row_glyphs(1),
        blanks(80),
        "the laptop of the ZWJ sequence must NOT spill onto row 1 (row 1 glyphs)"
    );
    assert_eq!(
        g.non_blank_rows(),
        vec![0u16],
        "only row 0 may hold ink after 78 x + woman technologist"
    );
    assert_eq!(
        (g.cursor_row, g.logical_col()),
        (0, 80),
        "the program counted 80 columns on one row; grid cursor is (row {}, col {}, pending {})",
        g.cursor_row,
        g.cursor_col,
        g.pending_wrap
    );
    assert_eq!(
        t.text_range(0, 0, 79),
        format!("{}{}", "x".repeat(78), WOMAN_TECH),
        "copy of row 0 must return the 78 x and the whole woman technologist"
    );
}

#[test]
fn thirty_nine_thumbs_up_with_skin_tone_are_78_columns_on_one_row() {
    assert_rig_preconditions();
    // 39 clusters * 2 columns = 78 columns: one row at 80 columns.
    let t = Term::new(80, 4);
    t.feed(&THUMBS_SKIN.repeat(39));
    let g = t.grid();

    let want_row0 = format!("{}{}", "\u{1F44D}#".repeat(39), blanks(2));
    assert_eq!(
        g.row_glyphs(0),
        want_row0,
        "row 0 must hold 39 thumbs-up glyph+spacer pairs and 2 blank cells"
    );
    assert_eq!(
        g.non_blank_rows(),
        vec![0u16],
        "39 thumbs-up + skin tone are 78 columns: ink must stay on row 0 (rows with ink)"
    );
    assert_eq!(
        (g.cursor_row, g.cursor_col, g.pending_wrap),
        (0, 78, 0),
        "cursor after 78 columns of output (row, col, pending)"
    );
    let wide_count = g
        .wide_flagged_cells()
        .iter()
        .filter(|(_, _, f)| f & bc::cell_flags::WIDE_CHAR != 0)
        .count();
    assert_eq!(
        wide_count, 39,
        "exactly one WIDE_CHAR cell per cluster (39 clusters)"
    );
}

#[test]
fn clusters_fill_a_row_exactly_then_wrap_at_cluster_granularity() {
    assert_rig_preconditions();
    // 40 clusters = 80 columns: row full, pending wrap, still row 0.
    let t = Term::new(80, 4);
    t.feed(&THUMBS_SKIN.repeat(40));
    let g = t.grid();
    assert_eq!(
        (g.non_blank_rows(), g.cursor_row, g.logical_col()),
        (vec![0u16], 0, 80),
        "40 clusters fill row 0 exactly; ink rows / cursor row / logical column; \
         row 1 = {:?}",
        g.row_glyphs(1)
    );

    // The 41st cluster wraps as a unit: row 1 holds exactly that one cluster.
    t.feed(THUMBS_SKIN);
    let g = t.grid();
    assert_eq!(
        g.row_glyphs(1),
        format!("\u{1F44D}#{}", blanks(78)),
        "the 41st cluster must occupy columns 0-1 of row 1 and nothing more"
    );
    assert_eq!(
        (g.cursor_row, g.cursor_col),
        (1, 2),
        "cursor after the wrapped 41st cluster (row, col)"
    );
    assert_eq!(
        g.non_blank_rows(),
        vec![0u16, 1],
        "ink on exactly rows 0 and 1"
    );
}

#[test]
fn cluster_that_does_not_fit_the_last_column_wraps_whole() {
    assert_rig_preconditions();
    // 79 'x' leaves ONE column: a 2-column cluster cannot fit and must move to
    // row 1 as a unit (standard wide-glyph wrap). Its modifier / joined
    // component must not trail behind on a third row position.
    for (label, cluster) in [
        ("thumbs up + skin tone", THUMBS_SKIN),
        ("woman technologist", WOMAN_TECH),
    ] {
        let base = cluster.chars().next().unwrap();
        let t = Term::new(80, 4);
        t.feed(&"x".repeat(79));
        t.feed(cluster);
        let g = t.grid();
        assert_eq!(
            g.row_glyphs(1),
            format!("{base}#{}", blanks(78)),
            "{label}: wrapped cluster must take columns 0-1 of row 1 only"
        );
        assert_eq!(
            (g.cursor_row, g.cursor_col, g.pending_wrap),
            (1, 2, 0),
            "{label}: cursor after the wrapped cluster (row, col, pending)"
        );
        assert_eq!(
            g.non_blank_rows(),
            vec![0u16, 1],
            "{label}: ink must be on rows 0 and 1 only"
        );
    }
}

// ---------------------------------------------------------------------------
// 3. Cursor-relative redraw (Ink eraseLines / CR + overwrite).
// ---------------------------------------------------------------------------

#[test]
fn redraw_that_blanks_the_string_width_columns_erases_the_whole_line() {
    assert_rig_preconditions();
    // A grapheme-aware program that drew 39 clusters believes the line is 78
    // columns. To redraw it, it returns to column 0 (CR) and writes 78 spaces.
    // That must leave the grid completely blank. When the grid used more than
    // 78 columns (the bug: 156 columns over two rows) glyphs remain on row 1.
    let t = Term::new(80, 4);
    t.feed(&THUMBS_SKIN.repeat(39));
    t.feed("\r");
    t.feed(&" ".repeat(78));
    let g = t.grid();
    assert_eq!(
        g.non_blank_rows(),
        Vec::<u16>::new(),
        "after CR + 78 spaces nothing may remain; leftover glyphs: row 0 = {:?}, row 1 = {:?}",
        g.row_glyphs(0),
        g.row_glyphs(1)
    );
    assert_eq!(
        g.wide_flagged_cells(),
        Vec::<(u16, u16, u16)>::new(),
        "no wide / spacer cell may survive the blanking pass (row, col, flags)"
    );
    assert_eq!(
        (g.cursor_row, g.cursor_col),
        (0, 78),
        "cursor after the redraw (row, col)"
    );

    // Same for the woman-technologist line from the bug report: 78 x + 2.
    let t = Term::new(80, 4);
    t.feed(&"x".repeat(78));
    t.feed(WOMAN_TECH);
    t.feed("\r");
    t.feed(&" ".repeat(80));
    let g = t.grid();
    assert_eq!(
        g.non_blank_rows(),
        Vec::<u16>::new(),
        "after CR + 80 spaces nothing may remain; leftover glyphs: row 0 = {:?}, row 1 = {:?}",
        g.row_glyphs(0),
        g.row_glyphs(1)
    );
}

#[test]
fn overwriting_a_cluster_with_two_narrow_chars_leaves_no_remnant() {
    assert_rig_preconditions();
    // Cluster occupies columns 0-1. CR + "ab" must replace exactly those two
    // cells; any remnant to the right means the cluster was wider than 2.
    for (label, cluster) in CLUSTERS {
        let t = Term::new(20, 3);
        t.feed(cluster);
        t.feed("\rab");
        let g = t.grid();
        assert_eq!(
            g.row_glyphs(0),
            format!("ab{}", blanks(18)),
            "{label}: CR + 'ab' over a 2-column cluster must leave only 'ab' \
             (a remnant means the cluster was wider than 2 columns)"
        );
        assert_eq!(
            g.wide_flagged_cells(),
            Vec::<(u16, u16, u16)>::new(),
            "{label}: no wide / spacer cell may survive the overwrite (row, col, flags)"
        );
    }
}

// ---------------------------------------------------------------------------
// 4. PTY chunking: the cluster arrives in arbitrary pieces.
// ---------------------------------------------------------------------------

#[test]
fn cluster_is_two_columns_wherever_the_byte_stream_is_split() {
    assert_rig_preconditions();
    // Split the UTF-8 byte stream in two at EVERY byte offset (so the split
    // lands between scalars AND inside a scalar). Cost: ~45 splits of <= 15
    // bytes in 20x3 grids.
    let mut failures: Vec<String> = Vec::new();
    for (label, cluster) in [
        ("thumbs up + skin tone", THUMBS_SKIN),
        ("woman technologist", WOMAN_TECH),
        ("woman technologist + skin tone", WOMAN_TECH_SKIN),
        ("heart on fire", HEART_ON_FIRE),
        ("victory hand + skin tone (narrow base)", VICTORY_SKIN),
        ("head shaking horizontally", HEAD_SHAKE_H),
    ] {
        let bytes = cluster.as_bytes();
        let base = cluster.chars().next().unwrap();
        let want = format!("{base}#|{}", blanks(17));
        let mut bad_cuts: Vec<usize> = Vec::new();
        let mut example = String::new();
        for cut in 1..bytes.len() {
            let t = Term::new(20, 3);
            t.feed_bytes(&bytes[..cut]);
            t.feed_bytes(&bytes[cut..]);
            t.feed("|");
            let g = t.grid();
            if g.row_glyphs(0) != want || g.cursor_col != 3 {
                if bad_cuts.is_empty() {
                    example = format!("row 0 {:?}, cursor col {}", g.row_glyphs(0), g.cursor_col);
                }
                bad_cuts.push(cut);
            }
        }
        if !bad_cuts.is_empty() {
            failures.push(format!(
                "{label} ({} bytes): split offsets {:?} are wrong; first: {example}; want row 0 \
                 {:?}, cursor col 3",
                bytes.len(),
                bad_cuts,
                want
            ));
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "a 2-column cluster must stay 2 columns however the PTY chunks its bytes"
    );
}

// ---------------------------------------------------------------------------
// 5. Copy fidelity.
// ---------------------------------------------------------------------------

/// Drop the emoji variation selector: whether a correct core keeps VS16 riding
/// on a base cell or drops it is not part of this contract (the sibling
/// `lone_vs16_column0_blind.rs` makes the same allowance). ZWJs, modifiers and
/// joined components, by contrast, must survive a copy.
fn without_vs16(s: &str) -> String {
    s.chars().filter(|c| *c != '\u{FE0F}').collect()
}

#[test]
fn copying_the_cluster_cells_returns_the_whole_cluster() {
    assert_rig_preconditions();
    // Selecting the cluster's two cells (what a double-click / drag over the
    // visible emoji yields) must copy the entire original sequence, with the
    // ZWJs, modifiers and joined components intact; and the surrounding text
    // must be unaffected.
    let mut failures: Vec<String> = Vec::new();
    for (label, cluster) in CLUSTERS {
        let t = Term::new(20, 3);
        t.feed("a");
        t.feed(cluster);
        t.feed("b");
        let g = t.grid();
        let got_cells = without_vs16(&t.text_range(0, 1, 2));
        let got_row = without_vs16(t.text_range(0, 0, 19).trim_end());
        let want_cells = without_vs16(cluster);
        let want_row = format!("a{want_cells}b");
        if got_cells != want_cells || got_row != want_row {
            failures.push(format!(
                "{label}: copy of cells 1-2 is {got_cells:?} want {want_cells:?}; copy of row 0 \
                 is {got_row:?} want {want_row:?}; row 0 = {:?}",
                g.row_glyphs(0)
            ));
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "copy over a 2-cell emoji cluster must return the full cluster text"
    );
}

// ---------------------------------------------------------------------------
// 6. Guards: marks that must NOT join the previous glyph.
// ---------------------------------------------------------------------------

#[test]
fn modifier_after_ascii_stays_a_standalone_wide_glyph() {
    assert_rig_preconditions();
    // string-width: 'x' is 1 column and a lone skin-tone swatch is 2.
    let t = Term::new(20, 3);
    t.feed("x\u{1F3FD}|");
    let g = t.grid();
    assert_eq!(
        g.row_glyphs(0),
        format!("x\u{1F3FD}#|{}", blanks(16)),
        "a modifier after ASCII is its own 2-column glyph (glyph + spacer '#')"
    );
    assert_eq!(g.cursor_col, 4, "cursor after x + swatch + marker");
}

#[test]
fn modifier_after_cursor_motion_does_not_glue_onto_the_neighbour() {
    assert_rig_preconditions();
    // The cursor is no longer where the last glyph ended, so the modifier
    // belongs to nothing it sits beside: it is a standalone glyph there.
    for (label, base_glyph, base_cells) in [
        ("wide base", "\u{1F44D}", "\u{1F44D}#"),
        ("narrow base", "\u{270C}", "\u{270C}"),
    ] {
        // CUP to row 2, column 5 (1-based): cursor at (row 1, col 4).
        let t = Term::new(20, 3);
        t.feed(base_glyph);
        t.feed("\x1b[2;5H\u{1F3FD}");
        let g = t.grid();
        assert_eq!(
            g.row_glyphs(0),
            format!("{base_cells}{}", blanks(20 - base_cells.chars().count())),
            "{label}: the base on row 0 must be left untouched by the far-away modifier"
        );
        assert_eq!(
            g.row_glyphs(1),
            format!("{}\u{1F3FD}#{}", blanks(4), blanks(14)),
            "{label}: the modifier is a standalone glyph at row 1, columns 4-5"
        );
        assert_eq!(
            (g.cursor_row, g.cursor_col),
            (1, 6),
            "{label}: cursor after the standalone modifier (row, col)"
        );
    }

    // Cursor moved back next to an EARLIER glyph (not the one just written):
    // two bases typed, then CUP onto the second one's first column. The first
    // base is directly left of the cursor but is not where the last glyph
    // ended, so the modifier overwrites the second base instead of joining it.
    // (label, base, 1-based column of the second base, expected row 0)
    for (label, base_glyph, second_col, want_row) in [
        (
            "wide base",
            "\u{1F44D}",
            3,
            format!("\u{1F44D}#\u{1F3FD}#{}", blanks(16)),
        ),
        (
            "narrow base",
            "\u{270C}",
            2,
            format!("\u{270C}\u{1F3FD}#{}", blanks(17)),
        ),
    ] {
        let t = Term::new(20, 3);
        t.feed(base_glyph);
        t.feed(base_glyph);
        t.feed(&format!("\x1b[1;{second_col}H\u{1F3FD}"));
        let g = t.grid();
        assert_eq!(
            g.row_glyphs(0),
            want_row,
            "{label}: a modifier typed after cursor motion onto the second base must overwrite \
             it, not join the first"
        );
    }

    // CR back over the base: the modifier overwrites columns 0-1 on its own.
    let t = Term::new(20, 3);
    t.feed("\u{1F44D}\r\u{1F3FD}");
    let g = t.grid();
    assert_eq!(
        g.row_glyphs(0),
        format!("\u{1F3FD}#{}", blanks(18)),
        "CR then a modifier overwrites the emoji rather than joining it"
    );
    assert_eq!(g.cursor_col, 2, "cursor after the overwriting modifier");
}

#[test]
fn insert_mode_never_loses_existing_text_to_a_cluster() {
    assert_rig_preconditions();
    // IRM (CSI 4 h) shifts the row right as glyphs are typed. A narrow base
    // plus modifier must shift "abcdef" right by the glyphs' real widths and
    // not overwrite any of it.
    let t = Term::new(20, 3);
    t.feed("abcdef\x1b[H\x1b[4h\u{270C}\u{1F3FD}");
    let g = t.grid();
    assert_eq!(
        g.row_glyphs(0),
        format!("\u{270C}\u{1F3FD}#abcdef{}", blanks(11)),
        "insert mode: every pre-existing character must survive, shifted right"
    );
}

#[test]
fn modifier_after_a_narrow_base_in_the_last_column_wraps_as_a_standalone_glyph() {
    assert_rig_preconditions();
    // Documented residual (KNOWN_ISSUES): the narrow base is already in the
    // last column, so there is no room to widen it in place without moving it
    // across the wrap. The modifier wraps as its own glyph. If this is ever
    // fixed, this test is the one to update.
    let t = Term::new(80, 4);
    t.feed(&"x".repeat(79));
    t.feed("\u{270C}\u{1F3FD}");
    let g = t.grid();
    assert_eq!(
        g.row_glyphs(0),
        format!("{}\u{270C}", "x".repeat(79)),
        "row 0 holds 79 x and the narrow base"
    );
    assert_eq!(
        g.row_glyphs(1),
        format!("\u{1F3FD}#{}", blanks(78)),
        "the modifier wraps to row 1 as its own glyph + spacer"
    );
}

#[test]
fn a_full_zero_width_list_never_swallows_the_next_emoji() {
    assert_rig_preconditions();
    // A cell keeps a bounded number of zero-width scalars, so a hostile run of
    // ZWJs leaves the base's list full with a ZWJ last. The emoji typed next
    // would be dropped silently (no cell, no cursor advance) if it were
    // treated as a continuation of that cluster. It must be drawn.
    let t = Term::new(20, 3);
    t.feed("\u{1F642}");
    t.feed(&"\u{200D}".repeat(40));
    t.feed("\u{1F600}|");
    let g = t.grid();
    assert_eq!(
        g.row_glyphs(0),
        format!("\u{1F642}#\u{1F600}#|{}", blanks(15)),
        "the emoji after a saturated ZWJ run must still be drawn as its own glyph"
    );
    assert_eq!(g.cursor_col, 5, "cursor after two emoji and the marker");
}
