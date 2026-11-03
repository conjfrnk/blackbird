//! Blind regression tests for "an erase / delete / insert that starts on the
//! RIGHT half (the spacer) of a wide glyph leaves the left half behind as a
//! lone `WIDE_CHAR`, and a later column reflow splits the logical line".
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and the
//! documented terminal conventions only, never the implementation.
//!
//! Contract under test (primary screen, reflow on):
//!   - A wide glyph is two cells: `WIDE_CHAR` (the glyph) immediately followed
//!     by `WIDE_CHAR_SPACER` (its right half). The renderer draws a
//!     `WIDE_CHAR` cell two cells wide, so a `WIDE_CHAR` whose right
//!     neighbour is NOT a spacer is a lie about the grid (the glyph claims a
//!     cell that holds something else). Header: the spacer "overpaints"
//!     when filled, and a wide glyph in the last column is expressed with a
//!     `LEADING_WIDE_CHAR_SPACER` on the previous row, never as a bare
//!     `WIDE_CHAR` in the last column.
//!   - xterm and tmux erase the WHOLE pair when an erase starts on the
//!     spacer half. Keeping the left half but dropping its wide flag (it
//!     then draws one cell wide) is the other defensible outcome. What may
//!     NOT survive is the orphan flag. These tests accept either outcome:
//!     the left cell must be blank, or still the same glyph WITHOUT
//!     `WIDE_CHAR`.
//!   - Copy and Find read logical lines: a hard line break is only where the
//!     program ended the line. A narrow-then-widen resize cycle must hand
//!     back the same single logical line (soft wraps rejoin), so the text
//!     must never gain a hard `\n` in the middle of a run of glyphs.
//!
//! How the bug is observed:
//!   1. Print a CJK run that ends exactly on the last two columns of a 10
//!      column grid (cursor in pending-wrap on the final spacer), send
//!      `CSI X` (ECH) and a CRLF. The spacer is blanked, glyph 5 stays a
//!      lone `WIDE_CHAR` in column 8.
//!   2. Narrow to 3 (or 5) columns: the lone `WIDE_CHAR` is the last glyph of
//!      its logical line and lands exactly in the LAST column of its row.
//!   3. Widen to 20 columns: instead of one logical line, copy and find see
//!      the first four glyphs, a hard newline, then the fifth glyph.
//!   4. The same happens without pending-wrap: `ab中中`, CUP onto the last
//!      spacer, `CSI K`, narrow to 3, widen.
//!
//! Rig preconditions (asserted, never assumed): the erase really starts on a
//! `WIDE_CHAR_SPACER` whose left neighbour is a `WIDE_CHAR` (and the cursor
//! really is in the stated pending-wrap state), both resizes apply unclamped,
//! the extraction covers every row, and untouched controls (the same cycle
//! without any erase) must round-trip into exactly one logical line. The
//! controls pass on the unfixed code; only the erase cases fail.
//!
//! Pre-flight cost: grids are at most 80x50 cells (4000 cells * ~16 B =
//! 64 KB) with 100 lines of scrollback, a few dozen terminals over the whole
//! file, each freed immediately. Inputs are < 300 bytes. No sleeps, I/O or
//! threads.

use blackbird_core as bc;

const SCROLLBACK: u32 = 100;
const SMALL_ROWS: u16 = 10;

/// `bb_term_text_range` flags: the find bar's combination (rectangular, keep
/// the tab fill, report soft wraps: `\r` after a soft-wrapped row, `\n`
/// otherwise).
const FIND_FLAGS: u8 = 7;
/// Prose mode, the Copy path.
const COPY_FLAGS: u8 = 0;

fn new_term(cols: u16, rows: u16) -> *mut bc::BBTerm {
    let t = unsafe { bc::bb_term_new(cols, rows, SCROLLBACK) };
    assert!(!t.is_null(), "bb_term_new({cols}, {rows}) returned null");
    t
}

fn feed_str(term: *mut bc::BBTerm, s: &str) {
    unsafe { bc::bb_term_input(term, s.as_ptr(), s.len()) };
}

fn resize(term: *mut bc::BBTerm, cols: u16, rows: u16, label: &str) {
    let r = unsafe { bc::bb_term_resize2(term, cols, rows) };
    assert_eq!(
        (r.applied_cols, r.applied_rows, r.clamped),
        (cols, rows, 0),
        "{label}: precondition: resize2 must apply {cols}x{rows} unclamped \
         (applied_cols, applied_rows, clamped)"
    );
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
    /// for a `WIDE_CHAR_SPACER`, `<` for a `LEADING_WIDE_CHAR_SPACER`, and a
    /// trailing `~` appended after the row when its last cell carries
    /// `WRAPLINE`.
    fn row_glyphs(&self, row: u16) -> String {
        let mut s: String = (0..self.cols)
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
            .collect();
        if self.cell(row, self.cols - 1).flags & bc::cell_flags::WRAPLINE != 0 {
            s.push('~');
        }
        s
    }

    /// Every non-blank row, rendered with `row_glyphs`, for failure messages.
    fn dump(&self) -> Vec<String> {
        (0..self.rows)
            .map(|r| (r, self.row_glyphs(r)))
            .filter(|(_, s)| !s.trim_end_matches([' ', '~']).is_empty())
            .map(|(r, s)| format!("r{r}:{s:?}"))
            .collect()
    }

    /// `WIDE_CHAR` cells whose right neighbour is not a `WIDE_CHAR_SPACER`
    /// (or that have no right neighbour at all: a wide glyph in the last
    /// column). These are the lone, lying wide glyphs.
    fn lone_wide_chars(&self) -> Vec<String> {
        let mut out = Vec::new();
        for row in 0..self.rows {
            for col in 0..self.cols {
                let c = self.cell(row, col);
                if c.flags & bc::cell_flags::WIDE_CHAR == 0 {
                    continue;
                }
                let spacer_follows = col + 1 < self.cols
                    && self.cell(row, col + 1).flags & bc::cell_flags::WIDE_CHAR_SPACER != 0;
                if !spacer_follows {
                    let right = if col + 1 < self.cols {
                        format!("0x{:x}", self.cell(row, col + 1).flags)
                    } else {
                        "none (last column)".to_string()
                    };
                    out.push(format!(
                        "row {row} col {col}: WIDE_CHAR U+{:04X} not followed by a \
                         WIDE_CHAR_SPACER (right neighbour flags {right}); row {:?}",
                        c.ch,
                        self.row_glyphs(row)
                    ));
                }
            }
        }
        out
    }
}

/// Raw `bb_term_text_range` reply.
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
            "bb_term_text_range({start_line},{start_col},{end_line},{end_col},{flags}) \
             returned null"
        );
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

/// The Find path: every visible row through flags 7, rows rejoined at their
/// soft wraps (`\r`) into logical lines (hard `\n` ends a line). Blank
/// logical lines are dropped. Also asserts the rig covered every row: one
/// terminator per row.
fn find_logical_lines(term: *mut bc::BBTerm, rows: u16, cols: u16, label: &str) -> Vec<String> {
    let raw = text_range(term, 0, 0, rows as i32 - 1, cols - 1, FIND_FLAGS);
    let terminators = raw.chars().filter(|c| *c == '\r' || *c == '\n').count();
    assert_eq!(
        terminators, rows as usize,
        "{label}: precondition: flags-7 extraction over {rows} rows must emit exactly one \
         terminator per row; got {terminators} in {raw:?}"
    );
    let mut lines: Vec<String> = Vec::new();
    let mut cur_row = String::new();
    let mut cur_line = String::new();
    for ch in raw.chars() {
        match ch {
            '\r' => {
                cur_line.push_str(&cur_row);
                cur_row.clear();
            }
            '\n' => {
                cur_line.push_str(&cur_row);
                cur_row.clear();
                let t = cur_line.trim_end().to_string();
                if !t.is_empty() {
                    lines.push(t);
                }
                cur_line.clear();
            }
            other => cur_row.push(other),
        }
    }
    lines
}

/// The Copy path: the whole visible screen as prose (hard breaks only), with
/// the blank rows above and below the content dropped.
fn copy_text(term: *mut bc::BBTerm, rows: u16, cols: u16) -> String {
    text_range(term, 0, 0, rows as i32 - 1, cols - 1, COPY_FLAGS)
        .trim_start_matches('\n')
        .trim_end()
        .to_string()
}

// ---------------------------------------------------------------------------
// Part 1: the erase itself must not leave a lone WIDE_CHAR (merged finding).
// ---------------------------------------------------------------------------

/// One erase-starting-on-the-spacer scenario.
struct EraseCase {
    label: &'static str,
    cols: u16,
    /// Fed first; leaves the cursor on a `WIDE_CHAR_SPACER`.
    setup: String,
    /// Expected `(cursor_col, cursor_row, pending_wrap)` after `setup`.
    cursor: (u16, u16, u8),
    /// The erase / edit sequence under test, fed with the cursor on the spacer.
    seq: &'static str,
    /// When true, every cell from the spacer column to the end of the row
    /// must be blank afterwards (the erase/delete does its job).
    blanks_right_of_glyph: bool,
}

fn build_on_spacer(c: &EraseCase) -> (*mut bc::BBTerm, u16) {
    let t = new_term(c.cols, 4);
    feed_str(t, &c.setup);
    let g = Grid::take(t);
    let cursor = (g.cursor_col, g.cursor_row, g.pending_wrap);
    assert_eq!(
        cursor,
        c.cursor,
        "{}: precondition: cursor (col, row, pending_wrap) after setup {:?}; row {:?}",
        c.label,
        c.setup,
        g.row_glyphs(0)
    );
    let spacer_col = g.cursor_col;
    let on_spacer = g.cell(g.cursor_row, spacer_col).flags & bc::cell_flags::WIDE_CHAR_SPACER != 0;
    let left_wide = spacer_col > 0
        && g.cell(g.cursor_row, spacer_col - 1).flags & bc::cell_flags::WIDE_CHAR != 0;
    assert!(
        on_spacer && left_wide,
        "{}: precondition: the cursor (row {}, col {}) must sit on a WIDE_CHAR_SPACER whose left \
         neighbour is a WIDE_CHAR; row {:?}",
        c.label,
        g.cursor_row,
        spacer_col,
        g.row_glyphs(g.cursor_row)
    );
    assert!(
        g.lone_wide_chars().is_empty(),
        "{}: precondition: setup must not itself contain a lone WIDE_CHAR: {:?}",
        c.label,
        g.lone_wide_chars()
    );
    (t, spacer_col)
}

/// Violations after `c.seq` ran with the cursor on the spacer half.
fn erase_violations(c: &EraseCase) -> Vec<String> {
    let (t, spacer_col) = build_on_spacer(c);
    feed_str(t, c.seq);
    let g = Grid::take(t);
    let mut out = Vec::new();
    for lone in g.lone_wide_chars() {
        out.push(format!(
            "{} ({:?}): lone WIDE_CHAR survived the edit: {lone}",
            c.label, c.seq
        ));
    }
    if c.blanks_right_of_glyph {
        for col in spacer_col..g.cols {
            let cell = g.cell(0, col);
            let blank = cell.ch == 0 || cell.ch == b' ' as u32;
            let wide_flags = cell.flags
                & (bc::cell_flags::WIDE_CHAR
                    | bc::cell_flags::WIDE_CHAR_SPACER
                    | bc::cell_flags::LEADING_WIDE_CHAR_SPACER);
            if !blank || wide_flags != 0 {
                out.push(format!(
                    "{} ({:?}): col {col} must be a plain blank after the edit; ch U+{:04X} \
                     flags 0x{:x}; row {:?}",
                    c.label,
                    c.seq,
                    cell.ch,
                    cell.flags,
                    g.row_glyphs(0)
                ));
            }
        }
    }
    unsafe { bc::bb_term_free(t) };
    out
}

/// The five-glyph row on 10 columns: the cursor is in pending-wrap on the
/// last spacer.
fn pending_wrap_case(label: &'static str, seq: &'static str, blanks: bool) -> EraseCase {
    EraseCase {
        label,
        cols: 10,
        setup: "中中中中中".to_string(),
        cursor: (9, 0, 1),
        seq,
        blanks_right_of_glyph: blanks,
    }
}

/// `ab中中`, cursor moved (CUP) onto the last glyph's spacer, no pending-wrap.
fn mid_row_case(label: &'static str, seq: &'static str, blanks: bool) -> EraseCase {
    EraseCase {
        label,
        cols: 10,
        setup: "ab中中\x1b[1;6H".to_string(),
        cursor: (5, 0, 0),
        seq,
        blanks_right_of_glyph: blanks,
    }
}

/// The reported trigger: ECH with the cursor in pending-wrap on the last
/// spacer leaves glyph 5 as a lone WIDE_CHAR in column 8.
#[test]
fn ech_in_pending_wrap_on_the_last_spacer_leaves_no_lone_wide_char() {
    let failures = erase_violations(&pending_wrap_case("pending-wrap ECH", "\x1b[X", true));
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "ECH (CSI X) with the cursor in pending-wrap on the spacer of the last wide glyph must \
         erase the pair or drop the left half's wide flag, never leave a lone WIDE_CHAR"
    );
}

/// ED 0 in the same pending-wrap position (EL 0 leaves the grid untouched
/// while a wrap is pending in this core, so it is outside this contract).
#[test]
fn ed_in_pending_wrap_on_the_last_spacer_leaves_no_lone_wide_char() {
    let failures = erase_violations(&pending_wrap_case("pending-wrap ED0", "\x1b[J", true));
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "ED 0 starting on the spacer half of the last wide glyph must not leave a lone WIDE_CHAR"
    );
}

/// The merged finding: ESC[K / ESC[J / ESC[2X / DCH with the cursor on the
/// spacer half (no pending-wrap), erase the pair or drop the flag.
#[test]
fn erase_and_delete_on_the_spacer_half_leave_no_lone_wide_char() {
    let mut failures: Vec<String> = Vec::new();
    for c in [
        mid_row_case("mid-row EL0", "\x1b[K", true),
        mid_row_case("mid-row ED0", "\x1b[J", true),
        mid_row_case("mid-row ECH 1", "\x1b[X", true),
        mid_row_case("mid-row ECH 2", "\x1b[2X", true),
        mid_row_case("mid-row DCH 1", "\x1b[P", true),
        mid_row_case("mid-row DCH 2", "\x1b[2P", true),
    ] {
        failures.extend(erase_violations(&c));
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "EL / ED / ECH / DCH with the cursor on the spacer half of a wide glyph must not leave \
         the left half flagged WIDE_CHAR next to a non-spacer cell"
    );
}

/// ICH on the spacer half pushes the spacer one cell right; the left half
/// must not keep claiming two cells over the inserted blank.
#[test]
fn insert_chars_on_the_spacer_half_leaves_no_lone_wide_char() {
    let mut failures: Vec<String> = Vec::new();
    for c in [
        mid_row_case("mid-row ICH 1", "\x1b[@", false),
        mid_row_case("mid-row ICH 2", "\x1b[2@", false),
    ] {
        failures.extend(erase_violations(&c));
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "ICH with the cursor on the spacer half of a wide glyph must not leave the left half \
         flagged WIDE_CHAR next to a non-spacer cell"
    );
}

/// Control (passes on the unfixed code): the same edits starting on the LEFT
/// half of the glyph are not part of this bug and must leave no lone wide
/// glyph. Proves the lone-wide detector does not fire on healthy grids and
/// that the rig really produces wide glyphs.
#[test]
fn control_intact_wide_glyphs_have_no_lone_wide_char() {
    let t = new_term(10, 4);
    feed_str(t, "ab中中\x1b[1;5H\x1b[K");
    let g = Grid::take(t);
    assert_eq!(
        g.count_flag(bc::cell_flags::WIDE_CHAR),
        1,
        "precondition: exactly the first glyph survives an EL 0 that starts on the second \
         glyph's LEFT half; row {:?}",
        g.row_glyphs(0)
    );
    assert_eq!(
        g.lone_wide_chars(),
        Vec::<String>::new(),
        "an erase starting on the left half of a wide glyph leaves no lone WIDE_CHAR; row {:?}",
        g.row_glyphs(0)
    );
    unsafe { bc::bb_term_free(t) };
}

impl Grid {
    fn count_flag(&self, flag: u16) -> usize {
        self.cells.iter().filter(|c| c.flags & flag != 0).count()
    }
}

// ---------------------------------------------------------------------------
// Part 2: narrow-then-widen after the erase must not split the logical line.
// ---------------------------------------------------------------------------

/// Blank lines fed before the content so the cursor sits low enough that the
/// reflowed run (one row per glyph at 3 columns) stays entirely on screen: a
/// shrink keeps the cursor row fixed and pushes the extra rows UP, into
/// history when there is no room.
const LINES_ABOVE: u16 = 6;
/// Same, for the 80 column / 40 glyph case (40 reflowed rows at 3 columns).
const LINES_ABOVE_WIDE_TERM: u16 = 42;

/// One reflow-cycle scenario.
struct CycleCase {
    label: &'static str,
    cols: u16,
    rows: u16,
    /// Rows the content is pushed down by (cursor row after `setup`).
    lines_above: u16,
    /// Content fed after the blank lines; leaves the cursor on a spacer (or
    /// anywhere, for controls).
    setup: String,
    /// Expected `(cursor_col, pending_wrap)` after `setup`; the row is
    /// `lines_above`.
    cursor: (u16, u8),
    /// Erase sequence fed with the cursor on the spacer; `""` for controls.
    seq: &'static str,
    narrow_to: u16,
    widen_to: u16,
    /// The single logical line the cycle must hand back, one entry per
    /// defensible outcome (pair erased / left half kept without the flag).
    accepted: Vec<String>,
}

fn glyphs(n: usize) -> String {
    "中".repeat(n)
}

/// `bb_term_grid_state().history_size`: how many rows have left the screen.
fn history_size(term: *mut bc::BBTerm) -> u32 {
    unsafe { bc::bb_term_grid_state(term).history_size }
}

/// Precondition: whatever a resize pushed into history is blank, so the whole
/// glyph run is still on screen and the screen-based assertions see all of it.
/// A shrink keeps the cursor row fixed and pushes the surplus rows up; with the
/// blank lines above the content those are the rows that leave.
fn assert_history_is_blank(term: *mut bc::BBTerm, cols: u16, when: &str, label: &str) {
    let h = history_size(term);
    if h == 0 {
        return;
    }
    let text = text_range(term, -(h as i32), 0, -1, cols - 1, COPY_FLAGS);
    assert_eq!(
        text.trim(),
        "",
        "{label}: precondition: the {h} history rows {when} must be blank, otherwise part of \
         the glyph run scrolled out of the screen-based checks (raise lines_above)"
    );
}

/// Run the blank lines, `setup`, `seq`, a CRLF, the narrow step and the widen
/// step. Returns the violations (empty = the logical line survived).
fn cycle_violations(c: &CycleCase) -> Vec<String> {
    let t = new_term(c.cols, c.rows);
    feed_str(t, &"\r\n".repeat(c.lines_above as usize));
    feed_str(t, &c.setup);

    let g = Grid::take(t);
    assert_eq!(
        (g.cursor_col, g.cursor_row, g.pending_wrap),
        (c.cursor.0, c.lines_above, c.cursor.1),
        "{}: precondition: cursor (col, row, pending_wrap) after setup; rows {:?}",
        c.label,
        g.dump()
    );
    if !c.seq.is_empty() {
        let on_spacer =
            g.cell(g.cursor_row, g.cursor_col).flags & bc::cell_flags::WIDE_CHAR_SPACER != 0;
        let left_wide = g.cursor_col > 0
            && g.cell(g.cursor_row, g.cursor_col - 1).flags & bc::cell_flags::WIDE_CHAR != 0;
        assert!(
            on_spacer && left_wide,
            "{}: precondition: the erase must start on a WIDE_CHAR_SPACER whose left neighbour \
             is a WIDE_CHAR; cursor row {} col {}; rows {:?}",
            c.label,
            g.cursor_row,
            g.cursor_col,
            g.dump()
        );
        feed_str(t, c.seq);
    }
    feed_str(t, "\r\n");
    assert_eq!(
        history_size(t),
        0,
        "{}: precondition: nothing may have scrolled off before the resizes",
        c.label
    );

    let mut out = Vec::new();

    resize(t, c.narrow_to, c.rows, c.label);
    assert_history_is_blank(t, c.narrow_to, "after the narrow step", c.label);
    let narrow = Grid::take(t);
    assert_eq!(
        (narrow.cols, narrow.rows),
        (c.narrow_to, c.rows),
        "{}: snapshot dims after the narrow step",
        c.label
    );
    // A wide glyph can never occupy the last column: a glyph that does not
    // fit wraps whole behind a LEADING_WIDE_CHAR_SPACER.
    for lone in narrow.lone_wide_chars() {
        out.push(format!(
            "{}: after narrowing to {} cols a lone WIDE_CHAR remains: {lone}",
            c.label, c.narrow_to
        ));
    }
    let narrow_dump = narrow.dump();

    resize(t, c.widen_to, c.rows, c.label);
    assert_history_is_blank(t, c.widen_to, "after the widen step", c.label);
    let wide = Grid::take(t);
    assert_eq!(
        (wide.cols, wide.rows),
        (c.widen_to, c.rows),
        "{}: snapshot dims after the widen step",
        c.label
    );
    let find = find_logical_lines(t, c.rows, c.widen_to, c.label);
    let copy = copy_text(t, c.rows, c.widen_to);

    let want_find: Vec<Vec<String>> = c.accepted.iter().map(|a| vec![a.clone()]).collect();
    if !want_find.contains(&find) {
        out.push(format!(
            "{}: FIND path after {}->{}->{} cols: want ONE logical line equal to one of {:?}, \
             got {:?}; narrow rows {:?}; widened rows {:?}",
            c.label,
            c.cols,
            c.narrow_to,
            c.widen_to,
            c.accepted,
            find,
            narrow_dump,
            wide.dump()
        ));
    }
    if !c.accepted.contains(&copy) {
        out.push(format!(
            "{}: COPY path after {}->{}->{} cols: want one of {:?} (no hard newline inside the \
             run), got {:?}",
            c.label, c.cols, c.narrow_to, c.widen_to, c.accepted, copy
        ));
    }
    for lone in wide.lone_wide_chars() {
        out.push(format!(
            "{}: after widening to {} cols a lone WIDE_CHAR remains: {lone}",
            c.label, c.widen_to
        ));
    }
    unsafe { bc::bb_term_free(t) };
    out
}

/// A five-glyph row on 10 columns (pending-wrap on the last spacer), erased by
/// `seq`, then narrow/widen.
fn pending_cycle(
    label: &'static str,
    seq: &'static str,
    narrow_to: u16,
    widen_to: u16,
) -> CycleCase {
    CycleCase {
        label,
        cols: 10,
        rows: SMALL_ROWS,
        lines_above: LINES_ABOVE,
        setup: glyphs(5),
        cursor: (9, 1),
        seq,
        narrow_to,
        widen_to,
        accepted: vec![glyphs(4), glyphs(5)],
    }
}

/// `ab中中` on 10 columns, cursor CUP'd onto the last spacer, then narrow/widen.
fn mid_row_cycle(
    label: &'static str,
    seq: &'static str,
    narrow_to: u16,
    widen_to: u16,
) -> CycleCase {
    mid_row_cycle_with(label, seq, narrow_to, widen_to, vec!["ab中", "ab中中"])
}

fn mid_row_cycle_with(
    label: &'static str,
    seq: &'static str,
    narrow_to: u16,
    widen_to: u16,
    accepted: Vec<&str>,
) -> CycleCase {
    CycleCase {
        label,
        cols: 10,
        rows: SMALL_ROWS,
        lines_above: LINES_ABOVE,
        // CUP is 1-based: row LINES_ABOVE + 1, column 6 = the second glyph's spacer.
        setup: format!("ab中中\x1b[{};6H", LINES_ABOVE + 1),
        cursor: (5, 0),
        seq,
        narrow_to,
        widen_to,
        accepted: accepted.into_iter().map(str::to_string).collect(),
    }
}

/// Controls: the same rows and the same resize cycle with NO erase. They
/// establish that the cycle rejoins into exactly one logical line when nothing
/// is orphaned (and pass on the unfixed code).
fn control_cycles() -> Vec<CycleCase> {
    let mut v = vec![
        pending_cycle("control 5 glyphs 10->3->20", "", 3, 20),
        pending_cycle("control 5 glyphs 10->5->20", "", 5, 20),
        mid_row_cycle_with("control ab+2 glyphs 10->3->20", "", 3, 20, vec!["ab中中"]),
    ];
    for c in v.iter_mut().take(2) {
        c.accepted = vec![glyphs(5)];
    }
    // What a correct "erase the whole pair" leaves behind, built without any
    // erase: four glyphs and a blank pair of columns (cursor not pending).
    for narrow_to in [3, 5] {
        v.push(CycleCase {
            label: if narrow_to == 3 {
                "control pair-erased 4 glyphs 10->3->20"
            } else {
                "control pair-erased 4 glyphs 10->5->20"
            },
            cols: 10,
            rows: SMALL_ROWS,
            lines_above: LINES_ABOVE,
            setup: glyphs(4),
            cursor: (8, 0),
            seq: "",
            narrow_to,
            widen_to: 20,
            accepted: vec![glyphs(4)],
        });
    }
    v
}

/// Rig check: the narrow step really produces the geometry the bug needs (one
/// glyph per 3-column row, rows soft-wrapped), the controls round-trip, and
/// the extraction helpers see the content. A green run of the erase cases
/// below therefore cannot mean "nothing was extracted" or "nothing wrapped".
#[test]
fn rig_controls_round_trip_into_one_logical_line() {
    let t = new_term(10, SMALL_ROWS);
    feed_str(t, &"\r\n".repeat(LINES_ABOVE as usize));
    feed_str(t, &glyphs(5));
    feed_str(t, "\r\n");
    resize(t, 3, SMALL_ROWS, "rig narrow");
    assert_history_is_blank(t, 3, "after the rig narrow", "rig");
    let g = Grid::take(t);
    // Five glyphs at 3 columns: one per row, ending on the row above the cursor.
    let first = g.cursor_row - 5;
    for r in first..g.cursor_row {
        assert_eq!(
            g.cell(r, 0).flags & bc::cell_flags::WIDE_CHAR,
            bc::cell_flags::WIDE_CHAR,
            "rig: after narrowing five intact glyphs to 3 cols, row {r} must start with a \
             WIDE_CHAR; rows {:?}",
            g.dump()
        );
    }
    for r in first..g.cursor_row - 1 {
        assert_eq!(
            g.cell(r, 2).flags & bc::cell_flags::WRAPLINE,
            bc::cell_flags::WRAPLINE,
            "rig: row {r} of the narrowed run must be soft-wrapped; rows {:?}",
            g.dump()
        );
    }
    unsafe { bc::bb_term_free(t) };

    let mut failures: Vec<String> = Vec::new();
    for c in control_cycles() {
        failures.extend(cycle_violations(&c));
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "controls (same cycle, no erase) must come back as exactly one logical line"
    );
}

/// The reported repro: ECH in pending-wrap on the last spacer, CRLF, narrow
/// to 3 or 5, widen to 20: still ONE logical line in Find and Copy.
#[test]
fn ech_in_pending_wrap_then_narrow_and_widen_keeps_one_logical_line() {
    let mut failures: Vec<String> = Vec::new();
    for c in [
        pending_cycle("pending-wrap ECH 10->3->20", "\x1b[X", 3, 20),
        pending_cycle("pending-wrap ECH 10->5->20", "\x1b[X", 5, 20),
    ] {
        failures.extend(cycle_violations(&c));
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "a CJK run ending on the last two columns, ECH'd on its spacer, must survive a \
         multi-column narrow + widen as ONE logical line (no hard newline before the last glyph)"
    );
}

/// The same hole through ED, plus a larger terminal (80 columns, 40 glyphs:
/// the lone glyph is still the last of its logical line and lands in the last
/// column of a 3 column row).
#[test]
fn ed_and_wide_terminal_pending_wrap_then_narrow_and_widen_keep_one_logical_line() {
    let mut failures: Vec<String> = Vec::new();
    let cases = vec![
        pending_cycle("pending-wrap ED0 10->3->20", "\x1b[J", 3, 20),
        CycleCase {
            label: "80-col pending-wrap ECH 80->3->20",
            cols: 80,
            rows: 50,
            lines_above: LINES_ABOVE_WIDE_TERM,
            setup: glyphs(40),
            cursor: (79, 1),
            seq: "\x1b[X",
            narrow_to: 3,
            widen_to: 20,
            accepted: vec![glyphs(39), glyphs(40)],
        },
    ];
    for c in &cases {
        failures.extend(cycle_violations(c));
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "ED 0 / ECH on the final spacer must not leave a glyph that a narrow + widen cycle \
         splits off into its own logical line"
    );
}

/// The non-pending-wrap variant: `ab中中`, CUP onto the last spacer, erase,
/// narrow to 3, widen: one logical line.
#[test]
fn erase_on_a_mid_row_spacer_then_narrow_and_widen_keeps_one_logical_line() {
    let mut failures: Vec<String> = Vec::new();
    for c in [
        mid_row_cycle("mid-row EL0 10->3->20", "\x1b[K", 3, 20),
        mid_row_cycle("mid-row ED0 10->3->20", "\x1b[J", 3, 20),
        mid_row_cycle("mid-row ECH 2 10->3->20", "\x1b[2X", 3, 20),
        mid_row_cycle("mid-row DCH 1 10->3->20", "\x1b[P", 3, 20),
    ] {
        failures.extend(cycle_violations(&c));
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "an erase/delete starting on the spacer of the last wide glyph must not leave a glyph \
         that a narrow-to-3 + widen cycle splits off into its own logical line"
    );
}
