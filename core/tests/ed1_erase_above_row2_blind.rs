//! Blind regression tests for vt-ed1-off-by-one: `CSI 1 J` (ED 1, "Erase
//! Above") with the cursor on SCREEN ROW 2 (0-based line 1) must erase
//! row 1 as well as the head of row 2.
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and
//! the documented xterm behaviour only, never the implementation.
//!
//! Contract under test (xterm ctlseqs, "CSI Ps J  Erase in Display (ED)"):
//!   Ps = 1  ->  Erase Above: from the top of the display THROUGH the
//!               cursor, inclusive. Concretely:
//!                 * every row strictly above the cursor row is blanked,
//!                 * on the cursor row columns 0..=cursor_col are blanked,
//!                 * the rest of the cursor row and every row below are
//!                   untouched,
//!                 * the cursor does not move.
//!
//! The bug being pinned: with the cursor on screen row 2, e.g.
//! `printf '\e[2;5H\e[1J'`, the row ABOVE the cursor (row 1) kept its old
//! text. Rows 1 and 3-and-below behaved correctly.
//!
//! Observation path: a fresh snapshot (`bb_term_take_snapshot`) is read cell
//! by cell into one string per row; blank cells (`ch == 0`) are normalised
//! to `' '`. The seed text never contains a space, so "erased" and "seeded"
//! cells are unambiguous. Whole grids are compared against a tiny model of
//! the contract above, so a failure prints the measured grid next to the
//! expected one.
//!
//! Rig preconditions (asserted in EVERY test via `Rig::seeded`, so a green
//! run cannot mean "nothing was ever on screen to erase"):
//!   1. After seeding, every row reads back verbatim (the grid really holds
//!      the unique non-blank pattern that the erase is supposed to remove).
//!   2. After the CUP, the snapshot cursor sits at the requested 0-based
//!      (col, row).
//!
//! Pre-flight cost: 10x5 grid (+16-line scrollback) is a few KB; 80x24 is
//! ~250 KB. At most ~60 terminals are created over the whole file, each
//! freed immediately. No sleeps, no threads, no I/O.

use blackbird_core as bc;

const SCROLLBACK: u32 = 16;

/// 62 distinct non-blank glyphs; cell (r, c) of a `cols`-wide grid holds
/// `ALPHABET[(r * cols + c) % 62]`, so neighbouring cells differ and any
/// partial erase shows up in the compared row string.
const ALPHABET: &[u8; 62] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

fn seed_char(row: u16, col: u16, cols: u16) -> char {
    let idx = (row as usize) * (cols as usize) + (col as usize);
    ALPHABET[idx % ALPHABET.len()] as char
}

fn seed_row(row: u16, cols: u16) -> String {
    (0..cols).map(|c| seed_char(row, c, cols)).collect()
}

fn feed(term: *mut bc::BBTerm, bytes: &[u8]) {
    unsafe { bc::bb_term_input(term, bytes.as_ptr(), bytes.len()) };
}

fn feed_str(term: *mut bc::BBTerm, s: &str) {
    feed(term, s.as_bytes());
}

/// Every visible row as a `cols`-char string (blanks as `' '`), plus the
/// 0-based `(cursor_col, cursor_row)`.
fn read_grid(term: *mut bc::BBTerm, cols: u16, rows: u16) -> (Vec<String>, (u16, u16)) {
    unsafe {
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        assert_eq!((*snap).cols, cols, "snapshot cols");
        assert_eq!((*snap).rows, rows, "snapshot rows");
        let mut grid: Vec<String> = Vec::with_capacity(rows as usize);
        for r in 0..rows {
            let mut line = String::with_capacity(cols as usize);
            for c in 0..cols {
                let idx = (r as usize) * (cols as usize) + (c as usize);
                let ch = (*(*snap).cells.add(idx)).ch;
                let glyph = if ch == 0 {
                    ' '
                } else {
                    char::from_u32(ch).unwrap_or('\u{FFFD}')
                };
                line.push(glyph);
            }
            grid.push(line);
        }
        let cursor = ((*snap).cursor_col, (*snap).cursor_row);
        bc::bb_snap_release(snap);
        (grid, cursor)
    }
}

fn history_size(term: *mut bc::BBTerm) -> u32 {
    unsafe {
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        let h = (*snap).history_size;
        bc::bb_snap_release(snap);
        h
    }
}

/// The grid the contract says must result from `ED 1` with the cursor at
/// 0-based `(cur_col, cur_row)` over the seed pattern: everything above the
/// cursor row, plus columns `0..=cur_col` of the cursor row, is blank.
fn expected_after_ed1(cols: u16, rows: u16, cur_col: u16, cur_row: u16) -> Vec<String> {
    let mut grid: Vec<String> = Vec::with_capacity(rows as usize);
    for r in 0..rows {
        let mut line = String::with_capacity(cols as usize);
        for c in 0..cols {
            let erased = r < cur_row || (r == cur_row && c <= cur_col);
            line.push(if erased { ' ' } else { seed_char(r, c, cols) });
        }
        grid.push(line);
    }
    grid
}

/// Print a grid one quoted row per line, prefixed with the 1-based row
/// number, for assertion messages.
fn show(grid: &[String]) -> String {
    let mut out = String::new();
    for (i, line) in grid.iter().enumerate() {
        out.push_str(&format!("\n    row {}: {:?}", i + 1, line));
    }
    out
}

struct Rig {
    term: *mut bc::BBTerm,
    cols: u16,
    rows: u16,
}

impl Rig {
    /// New `cols` x `rows` terminal with the unique seed pattern written to
    /// every row. Asserts rig precondition 1 (seed reads back verbatim).
    fn seeded(cols: u16, rows: u16) -> Rig {
        let term = unsafe { bc::bb_term_new(cols, rows, SCROLLBACK) };
        assert!(!term.is_null(), "bb_term_new({cols}, {rows}) returned null");
        let rig = Rig { term, cols, rows };
        rig.reseed();
        rig
    }

    /// (Re)write the seed pattern over the whole viewport using absolute
    /// CUPs and assert it reads back. Leaves the cursor at the end of the
    /// last row (the caller repositions it).
    fn reseed(&self) {
        for r in 0..self.rows {
            feed_str(self.term, &format!("\x1b[{};1H", r + 1));
            feed_str(self.term, &seed_row(r, self.cols));
        }
        let (grid, _) = read_grid(self.term, self.cols, self.rows);
        let want: Vec<String> = (0..self.rows).map(|r| seed_row(r, self.cols)).collect();
        assert_eq!(
            grid,
            want,
            "precondition: the seed pattern must read back verbatim before any erase; \
             measured grid:{}",
            show(&grid)
        );
    }

    /// Absolute cursor placement via CUP, 1-based. Asserts rig precondition 2.
    fn cup(&self, row_1based: u16, col_1based: u16) {
        feed_str(self.term, &format!("\x1b[{row_1based};{col_1based}H"));
        let (_, cursor) = read_grid(self.term, self.cols, self.rows);
        assert_eq!(
            cursor,
            (col_1based - 1, row_1based - 1),
            "precondition: ESC[{row_1based};{col_1based}H must place the cursor at 0-based \
             (col {}, row {})",
            col_1based - 1,
            row_1based - 1
        );
    }

    /// Assert the grid equals the ED 1 contract for a cursor at 0-based
    /// `(cur_col, cur_row)`, and that the cursor did not move.
    fn assert_ed1_result(&self, cur_col: u16, cur_row: u16, what: &str) {
        let (got, cursor) = read_grid(self.term, self.cols, self.rows);
        let want = expected_after_ed1(self.cols, self.rows, cur_col, cur_row);
        assert_eq!(
            got,
            want,
            "{what}: ED 1 (erase above, cursor inclusive) with the cursor on screen row {} \
             col {} must blank every row above it and cols 1..={} of its own row.\n  \
             measured:{}\n  expected:{}",
            cur_row + 1,
            cur_col + 1,
            cur_col + 1,
            show(&got),
            show(&want)
        );
        assert_eq!(
            cursor,
            (cur_col, cur_row),
            "{what}: ED 1 must not move the cursor (expected 0-based col {cur_col}, row {cur_row})"
        );
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        unsafe { bc::bb_term_free(self.term) };
    }
}

const COLS: u16 = 10;
const ROWS: u16 = 5;

/// The exact report: cursor on screen row 2, any column, ESC[1J.
#[test]
fn ed1_with_cursor_on_screen_row_two_erases_row_one() {
    let rig = Rig::seeded(COLS, ROWS);
    rig.cup(2, 5);
    feed_str(rig.term, "\x1b[1J");

    let (got, _) = read_grid(rig.term, COLS, ROWS);
    assert_eq!(
        got[0],
        " ".repeat(COLS as usize),
        "vt-ed1-off-by-one: `ESC[2;5H ESC[1J` must blank the row ABOVE the cursor (row 1); \
         row 1 reads {:?} (seed was {:?})",
        got[0],
        seed_row(0, COLS)
    );
    rig.assert_ed1_result(4, 1, "ESC[2;5H ESC[1J");
}

/// Same contract with the parameter written zero-padded (`ESC[01J` is Ps=1).
#[test]
fn ed1_row_two_with_leading_zero_parameter_erases_row_one() {
    let rig = Rig::seeded(COLS, ROWS);
    rig.cup(2, 3);
    feed_str(rig.term, "\x1b[01J");
    rig.assert_ed1_result(2, 1, "ESC[2;3H ESC[01J");
}

/// "any column": walk the cursor across every column of row 2.
#[test]
fn ed1_row_two_every_column_erases_row_one_and_the_row_two_prefix() {
    let mut failures: Vec<String> = Vec::new();
    for col in 1..=COLS {
        let rig = Rig::seeded(COLS, ROWS);
        rig.cup(2, col);
        feed_str(rig.term, "\x1b[1J");
        let (got, cursor) = read_grid(rig.term, COLS, ROWS);
        let want = expected_after_ed1(COLS, ROWS, col - 1, 1);
        if got != want || cursor != (col - 1, 1) {
            failures.push(format!(
                "col {col}: row1={:?} row2={:?} cursor={:?} (want row1={:?} row2={:?} cursor={:?})",
                got[0],
                got[1],
                cursor,
                want[0],
                want[1],
                (col - 1, 1)
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "vt-ed1-off-by-one: ED 1 with the cursor on screen row 2 must erase row 1 and row-2 \
         cols 1..=cursor for EVERY column; {} of {COLS} columns differed:\n  {}",
        failures.len(),
        failures.join("\n  ")
    );
}

/// Full sweep over every cursor row and a spread of columns. The report says
/// rows 1 and 3+ are fine and only row 2 is wrong; this single assertion
/// names exactly which (row, col) cells of the sweep deviate from the
/// contract, so the failure points at row 2 and nothing else.
#[test]
fn ed1_sweep_over_every_cursor_row_matches_the_contract() {
    let cols_to_try: [u16; 4] = [1, 4, 5, COLS];
    let mut failures: Vec<String> = Vec::new();
    let mut checked = 0usize;
    for row in 1..=ROWS {
        for &col in &cols_to_try {
            let rig = Rig::seeded(COLS, ROWS);
            rig.cup(row, col);
            feed_str(rig.term, "\x1b[1J");
            let (got, cursor) = read_grid(rig.term, COLS, ROWS);
            let want = expected_after_ed1(COLS, ROWS, col - 1, row - 1);
            checked += 1;
            if got != want || cursor != (col - 1, row - 1) {
                let bad_rows: Vec<usize> = (0..ROWS as usize)
                    .filter(|&i| got[i] != want[i])
                    .map(|i| i + 1)
                    .collect();
                failures.push(format!(
                    "cursor row {row} col {col}: rows differing from contract = {bad_rows:?}; \
                     row1 reads {:?}",
                    got[0]
                ));
            }
        }
    }
    assert_eq!(
        checked,
        (ROWS as usize) * cols_to_try.len(),
        "sweep must visit every (row, col) combination"
    );
    assert!(
        failures.is_empty(),
        "ED 1 sweep: {} of {checked} (cursor row, col) cases deviated from the xterm contract:\n  {}",
        failures.len(),
        failures.join("\n  ")
    );
}

/// Controls (already correct before the fix): cursor on rows 1, 3, 4 and 5.
/// Guards against an over-correcting fix that breaks the neighbours.
#[test]
fn ed1_with_cursor_on_other_rows_stays_correct() {
    for row in [1u16, 3, 4, 5] {
        let rig = Rig::seeded(COLS, ROWS);
        rig.cup(row, 5);
        feed_str(rig.term, "\x1b[1J");
        rig.assert_ed1_result(4, row - 1, &format!("control: ESC[{row};5H ESC[1J"));
    }
}

/// Guards against the opposite over-correction: with the cursor on row 2 the
/// erase must stop at the cursor. Row-2 text right of the cursor and every
/// row below must survive.
#[test]
fn ed1_with_cursor_on_row_two_keeps_the_tail_of_row_two_and_rows_below() {
    let rig = Rig::seeded(COLS, ROWS);
    rig.cup(2, 5);
    feed_str(rig.term, "\x1b[1J");
    let (got, _) = read_grid(rig.term, COLS, ROWS);

    let tail_start = 5usize; // 0-based col just right of the cursor (col 5 1-based)
    let want_row2 = format!(
        "{}{}",
        " ".repeat(tail_start),
        &seed_row(1, COLS)[tail_start..]
    );
    assert_eq!(
        got[1], want_row2,
        "ED 1 at row 2 col 5 must blank cols 1..=5 only; row 2 reads {:?}, expected {:?}",
        got[1], want_row2
    );
    for (r, line) in got.iter().enumerate().skip(2) {
        assert_eq!(
            *line,
            seed_row(r as u16, COLS),
            "ED 1 at row 2 must not touch row {} (below the cursor); it reads {:?}",
            r + 1,
            line
        );
    }
}

/// The cursor can reach row 2 by means other than CUP; the erase must not
/// depend on how it got there. LF from row 1, and VPA.
#[test]
fn ed1_row_two_reached_by_lf_or_vpa_erases_row_one() {
    // Via LF: home, then a bare line feed (cursor moves down, column kept).
    let rig = Rig::seeded(COLS, ROWS);
    feed_str(rig.term, "\x1b[1;4H"); // row 1, col 4 (1-based)
    feed_str(rig.term, "\n");
    let (_, cursor) = read_grid(rig.term, COLS, ROWS);
    assert_eq!(
        cursor,
        (3, 1),
        "precondition: ESC[1;4H then LF must leave the cursor at 0-based (col 3, row 1)"
    );
    feed_str(rig.term, "\x1b[1J");
    rig.assert_ed1_result(3, 1, "LF to row 2, then ESC[1J");

    // Via VPA (ESC[2d), column unchanged.
    let rig = Rig::seeded(COLS, ROWS);
    feed_str(rig.term, "\x1b[1;7H");
    feed_str(rig.term, "\x1b[2d");
    let (_, cursor) = read_grid(rig.term, COLS, ROWS);
    assert_eq!(
        cursor,
        (6, 1),
        "precondition: ESC[1;7H then VPA ESC[2d must leave the cursor at 0-based (col 6, row 1)"
    );
    feed_str(rig.term, "\x1b[1J");
    rig.assert_ed1_result(6, 1, "VPA to row 2, then ESC[1J");
}

/// Screen row 2 is defined relative to the viewport, not to the start of
/// history: with scrollback populated, ED 1 on viewport row 2 must still
/// erase viewport row 1.
#[test]
fn ed1_row_two_with_populated_scrollback_erases_viewport_row_one() {
    let term = unsafe { bc::bb_term_new(COLS, ROWS, SCROLLBACK) };
    assert!(!term.is_null(), "bb_term_new returned null");
    // Push well more than ROWS lines through so history is non-empty.
    for _ in 0..(ROWS as usize * 3) {
        feed_str(term, "scroll\r\n");
    }
    let hist = history_size(term);
    assert!(
        hist > 0,
        "precondition: scrollback must be populated before the erase; history_size = {hist}"
    );
    let rig = Rig {
        term,
        cols: COLS,
        rows: ROWS,
    };
    rig.reseed(); // overwrite the viewport with the unique pattern
    rig.cup(2, 5);
    feed_str(rig.term, "\x1b[1J");
    rig.assert_ed1_result(4, 1, "scrollback populated, ESC[2;5H ESC[1J");
}

/// The report's one-liner at a real terminal size (80x24):
/// `printf '\e[2;5H\e[1J'`.
#[test]
fn ed1_row_two_at_80x24_erases_row_one() {
    let rig = Rig::seeded(80, 24);
    rig.cup(2, 5);
    feed_str(rig.term, "\x1b[1J");
    let (got, _) = read_grid(rig.term, 80, 24);
    assert_eq!(
        got[0],
        " ".repeat(80),
        "vt-ed1-off-by-one: on an 80x24 grid `ESC[2;5H ESC[1J` must blank row 1; it reads {:?}",
        got[0]
    );
    rig.assert_ed1_result(4, 1, "80x24: ESC[2;5H ESC[1J");
}
