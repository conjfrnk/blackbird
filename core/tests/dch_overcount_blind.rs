//! Blind regression tests for VT-5: `CSI Ps P` (DCH, "delete characters")
//! with `Ps` larger than the number of cells at and to the right of the
//! cursor must NOT touch any cell to the LEFT of the cursor.
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and
//! the documented xterm / VT behaviour only, never the implementation.
//!
//! Contract under test (xterm ctlseqs, "CSI Ps P  Delete Ps Character(s)",
//! DEC VT220 DCH):
//!   - DCH deletes `Ps` cells starting AT the cursor and going RIGHT. The
//!     cells to the right of the deleted span shift left; blanks enter at
//!     the right margin. The cursor does not move.
//!   - If `Ps` exceeds the cells available (cursor column .. right margin),
//!     the deletion is clamped at the right margin: everything from the
//!     cursor to the end of the line is erased, and nothing else.
//!   - Cells left of the cursor column, and every other row, are never
//!     modified by DCH.
//!
//! The bug being pinned: with `Ps > (cols - cursor_col)` text to the left of
//! the cursor disappeared, e.g. on 10 columns
//! `abcdefghij ESC[1;5H ESC[7P` left a blank row instead of `abcd` followed
//! by six blanks, and `ESC[999P` / `ESC[9999P` anywhere on a row blanked the
//! whole line rather than only the part from the cursor to the right.
//!
//! Observation path: a fresh snapshot (`bb_term_take_snapshot`) is read cell
//! by cell; blank cells (`ch == 0` or `ch == ' '`) are normalised to `' '`
//! so the assertion compares whole rows as strings and prints the measured
//! row on failure.
//!
//! Rig preconditions (asserted in EVERY test via `assert_rig_preconditions`,
//! so a green run cannot mean "DCH is not implemented at all" or "CUP does
//! not place the cursor"):
//!   1. Printing `abcdefghij` on a 10-column grid reads back verbatim.
//!   2. `ESC[1;5H` puts the cursor at 0-based (col 4, row 0).
//!   3. A NORMAL in-range DCH (`ESC[2P` at col 4) shifts the tail left:
//!      `abcdghij  `.
//!
//! Pre-flight cost: 10x3 grid with a 16-line scrollback = a few KB per
//! terminal; at most ~60 terminals created over the whole file, each freed
//! immediately. No sleeps, no threads, no I/O.

use blackbird_core as bc;

const COLS: u16 = 10;
const ROWS: u16 = 3;
const SCROLLBACK: u32 = 16;

fn new_term() -> *mut bc::BBTerm {
    let t = unsafe { bc::bb_term_new(COLS, ROWS, SCROLLBACK) };
    assert!(!t.is_null(), "bb_term_new({COLS}, {ROWS}) returned null");
    t
}

fn feed(term: *mut bc::BBTerm, bytes: &[u8]) {
    unsafe { bc::bb_term_input(term, bytes.as_ptr(), bytes.len()) };
}

fn feed_str(term: *mut bc::BBTerm, s: &str) {
    feed(term, s.as_bytes());
}

/// Row `row` of the visible grid as a `COLS`-char string, blanks as `' '`.
fn row_string(term: *mut bc::BBTerm, row: u16) -> String {
    unsafe {
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        assert_eq!((*snap).cols, COLS, "snapshot cols");
        assert_eq!((*snap).rows, ROWS, "snapshot rows");
        assert!(row < (*snap).rows);
        let mut out = String::with_capacity(COLS as usize);
        for col in 0..COLS {
            let idx = (row as usize) * (COLS as usize) + col as usize;
            let ch = (*(*snap).cells.add(idx)).ch;
            let c = if ch == 0 {
                ' '
            } else {
                char::from_u32(ch).unwrap_or('\u{FFFD}')
            };
            out.push(c);
        }
        bc::bb_snap_release(snap);
        out
    }
}

/// `(cursor_col, cursor_row)`, 0-based, from a fresh snapshot.
fn cursor(term: *mut bc::BBTerm) -> (u16, u16) {
    unsafe {
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        let pos = ((*snap).cursor_col, (*snap).cursor_row);
        bc::bb_snap_release(snap);
        pos
    }
}

/// Print `abcdefghij` on row 0 (fills the 10-col row exactly), then move the
/// cursor to the given 1-based CUP `(row, col)` and feed one DCH with `n`.
/// Returns the terminal (caller frees it).
fn row_with_dch(cup_col_1based: u16, n: u32) -> *mut bc::BBTerm {
    let t = new_term();
    feed_str(t, "abcdefghij");
    feed_str(t, &format!("\x1b[1;{cup_col_1based}H"));
    feed_str(t, &format!("\x1b[{n}P"));
    t
}

fn assert_rig_preconditions() {
    unsafe {
        // 1 + 2: printed content reads back, CUP places the cursor.
        let t = new_term();
        feed_str(t, "abcdefghij");
        assert_eq!(
            row_string(t, 0),
            "abcdefghij",
            "precondition: printed row must read back verbatim"
        );
        feed_str(t, "\x1b[1;5H");
        assert_eq!(
            cursor(t),
            (4, 0),
            "precondition: ESC[1;5H must place the cursor at 0-based (col 4, row 0)"
        );
        bc::bb_term_free(t);

        // 3: an ordinary in-range DCH works and shifts the tail left.
        let t = row_with_dch(5, 2);
        assert_eq!(
            row_string(t, 0),
            "abcdghij  ",
            "precondition: in-range DCH (ESC[2P at col 5 of `abcdefghij`) must \
             delete `ef` and shift `ghij` left"
        );
        bc::bb_term_free(t);
    }
}

#[test]
fn dch_larger_than_cells_to_the_right_preserves_text_left_of_cursor() {
    assert_rig_preconditions();
    unsafe {
        // The exact example from the report: 10 cols, cursor at col 5
        // (1-based) leaves 6 cells at/right of the cursor, DCH count is 7.
        let t = row_with_dch(5, 7);
        let got = row_string(t, 0);
        assert_eq!(
            got, "abcd      ",
            "VT-5: `abcdefghij ESC[1;5H ESC[7P` must erase only cursor..end-of-line and keep \
             `abcd` left of the cursor; row 0 reads {got:?}"
        );
        bc::bb_term_free(t);
    }
}

#[test]
fn dch_count_sweep_never_erases_left_of_cursor() {
    assert_rig_preconditions();
    // Counts strictly above the 6 available cells (cursor at 1-based col 5),
    // through the "999" from the report, 9999, and the 16-bit maximum.
    let counts: [u32; 8] = [7, 8, 9, 10, 100, 999, 9999, 65535];
    unsafe {
        let mut failures: Vec<String> = Vec::new();
        for n in counts {
            let t = row_with_dch(5, n);
            let got = row_string(t, 0);
            if got != "abcd      " {
                failures.push(format!("ESC[{n}P -> {got:?}"));
            }
            bc::bb_term_free(t);
        }
        assert!(
            failures.is_empty(),
            "VT-5: over-count DCH at 1-based col 5 of `abcdefghij` must leave `abcd      ` \
             (clamp at the right margin); {} of {} counts differed: {failures:?}",
            failures.len(),
            counts.len()
        );
    }
}

#[test]
fn dch_999_with_cursor_mid_row_does_not_blank_the_whole_line() {
    assert_rig_preconditions();
    unsafe {
        // `printf 'hello\e[999P'`: the cursor sits at col 5 right after the
        // text; everything to its right is already blank. DCH must be a
        // no-op for the visible text, not blank `hello`.
        let t = new_term();
        feed_str(t, "hello");
        assert_eq!(
            cursor(t),
            (5, 0),
            "precondition: cursor must sit right after `hello`"
        );
        feed_str(t, "\x1b[999P");
        let got = row_string(t, 0);
        assert_eq!(
            got, "hello     ",
            "VT-5: ESC[999P with the cursor mid-row must not blank text left of the cursor; \
             row 0 reads {got:?}"
        );
        bc::bb_term_free(t);
    }
}

#[test]
fn dch_at_last_column_with_count_two_keeps_the_rest_of_the_row() {
    assert_rig_preconditions();
    unsafe {
        // Cursor on the last column: exactly 1 cell available, count 2.
        let t = row_with_dch(10, 2);
        let got = row_string(t, 0);
        assert_eq!(
            got, "abcdefghi ",
            "VT-5: ESC[2P on the LAST column must delete only that one cell; row 0 reads {got:?}"
        );
        bc::bb_term_free(t);
    }
}

#[test]
fn dch_exact_fit_and_one_past_agree() {
    assert_rig_preconditions();
    unsafe {
        // n == cells available (6) and n == cells available + 1 (7) must give
        // the same, correct row: the cursor-to-margin span cleared and
        // nothing else. (n == 6 is the boundary that already behaved.)
        let exact = row_with_dch(5, 6);
        let one_past = row_with_dch(5, 7);
        let got_exact = row_string(exact, 0);
        let got_past = row_string(one_past, 0);
        assert_eq!(
            got_exact, "abcd      ",
            "exact-fit DCH (ESC[6P at col 5) row 0 reads {got_exact:?}"
        );
        assert_eq!(
            got_past, got_exact,
            "VT-5: DCH one past the available cells (ESC[7P) must match the exact-fit result \
             (ESC[6P): exact={got_exact:?} one_past={got_past:?}"
        );
        bc::bb_term_free(exact);
        bc::bb_term_free(one_past);
    }
}

#[test]
fn over_count_dch_leaves_other_rows_and_cursor_untouched() {
    assert_rig_preconditions();
    unsafe {
        let t = new_term();
        feed_str(t, "abcdefghij");
        feed_str(t, "\x1b[2;1HKLMNOPQRST");
        feed_str(t, "\x1b[3;1Hxyz");
        // Back to row 0, col 5 (1-based), then an over-count DCH.
        feed_str(t, "\x1b[1;5H");
        assert_eq!(cursor(t), (4, 0), "precondition: cursor placed at (4, 0)");
        feed_str(t, "\x1b[9999P");

        let r0 = row_string(t, 0);
        let r1 = row_string(t, 1);
        let r2 = row_string(t, 2);
        assert_eq!(
            r0, "abcd      ",
            "VT-5: row 0 after ESC[9999P at col 5 reads {r0:?}"
        );
        assert_eq!(
            r1, "KLMNOPQRST",
            "DCH on row 0 must not touch row 1; row 1 reads {r1:?}"
        );
        assert_eq!(
            r2, "xyz       ",
            "DCH on row 0 must not touch row 2; row 2 reads {r2:?}"
        );
        assert_eq!(
            cursor(t),
            (4, 0),
            "DCH must not move the cursor (expected (col 4, row 0))"
        );
        bc::bb_term_free(t);
    }
}

#[test]
fn over_count_dch_at_column_zero_still_clears_the_whole_row() {
    assert_rig_preconditions();
    unsafe {
        // Guard against over-correcting: with the cursor at col 0 the span
        // cursor..margin IS the whole row, so a huge count blanks it all.
        let t = row_with_dch(1, 9999);
        let got = row_string(t, 0);
        assert_eq!(
            got, "          ",
            "ESC[9999P at column 1 must clear the whole row (cursor..margin is the whole row); \
             row 0 reads {got:?}"
        );
        assert_eq!(cursor(t), (0, 0), "cursor must stay at column 0");
        bc::bb_term_free(t);
    }
}
