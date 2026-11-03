//! Blind tests for the SOFT-WRAP-MARKS flag of `bb_term_text_range`
//! (bit 2, value 4 of the `flags` byte; bit 0 = rectangular, bit 1 = keep the
//! tab fill). The find bar passes `7` so it can rejoin soft-wrapped scrollback
//! rows while keeping a 1:1 row <-> line mapping; this file pins the flag
//! alone (`4`) and in its find-bar combination (`7`), plus the neighbours
//! (`5`, `6`) that show the other two bits still mean what they meant.
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`, the
//! `bb_term_text_range` doc) only, never the implementation.
//!
//! Contract under test (header doc):
//!   - Flag 4 set: EVERY line, the last one included, is followed by exactly
//!     one terminator: `\r` if that row soft-wrapped onto the next row, `\n`
//!     if not. (Instead of joining rows with `\n` only at hard breaks.) A row
//!     that soft-wrapped but is the last row of the requested range still gets
//!     `\r`: the terminator describes the row, not the range.
//!   - Bit 0 clear (prose): leading/trailing blanks of each line are trimmed
//!     as usual, so a soft-wrapped full-width row keeps all its cells and a
//!     short last row loses its blank tail.
//!   - Bit 0 set (rectangular): every line is clipped to `[start_col,
//!     end_col]` with no trimming, so a 40-col range yields 40 chars per row.
//!   - Bit 1 set keeps the blank fill after a tab: one output char per grid
//!     cell (so `a<TAB>b` over cols 0..=9 is `a`, `\t`, six blanks, `b`, one
//!     blank). Clear: the fill is dropped (`a\tb`).
//!   - Without bit 2 nothing changes: soft-wrapped rows join with no
//!     terminator at all.
//!
//! Rig preconditions (asserted by `assert_rig`, run first in EVERY test, so a
//! green run cannot mean "extraction returned nothing" or "nothing wrapped"):
//!   1. 50 chars on a 40-col grid really soft-wrap: with no flags the two rows
//!      extract as one 50-char string with no newline at all.
//!   2. A hard `\r\n` really ends a row: prose extraction puts a `\n` there.
//!
//! Pre-flight cost: 40x5 grids with at most 100 lines of scrollback, a handful
//! of terminals over the whole file, each freed immediately. No sleeps, no
//! threads, no I/O.

use blackbird_core as bc;

const COLS: u16 = 40;
const ROWS: u16 = 5;
const SCROLLBACK: u32 = 100;

const RECT: u8 = 1;
const KEEP_TAB_FILL: u8 = 2;
const SOFT_WRAP_MARKS: u8 = 4;

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

fn a40() -> String {
    "A".repeat(40)
}

/// Rows 0 and 1 are one soft-wrapped logical line (40 'A' + 10 'B'); row 2 is
/// a separate line after a hard break.
fn feed_wrapped_then_hard(t: *mut bc::BBTerm) {
    feed(t, &format!("{}{}\r\nxyz", a40(), "B".repeat(10)));
}

fn assert_rig() {
    with_term(|t| {
        feed_wrapped_then_hard(t);
        let joined = text_range(t, 0, 0, 1, 39, 0);
        assert_eq!(
            joined,
            format!("{}{}", a40(), "B".repeat(10)),
            "precondition: 50 chars on a 40-col grid must soft-wrap and extract as one \
             string with no newline; got {joined:?}"
        );
        let hard = text_range(t, 1, 0, 2, 39, 0);
        assert_eq!(
            hard, "BBBBBBBBBB\nxyz",
            "precondition: a hard CRLF must end the row with a '\\n'; got {hard:?}"
        );
    });
}

// ---------------------------------------------------------------------------
// Flag 4 alone (prose mode + soft-wrap marks)
// ---------------------------------------------------------------------------

/// The headline: `\r` after the row that soft-wrapped, `\n` after rows that
/// did not, including the last one. Prose trimming still applies.
#[test]
fn flag_4_alone_terminates_each_row_with_cr_if_wrapped_else_lf() {
    assert_rig();
    with_term(|t| {
        feed_wrapped_then_hard(t);
        let got = text_range(t, 0, 0, 2, 39, SOFT_WRAP_MARKS);
        let want = format!("{}\r{}\n{}\n", a40(), "B".repeat(10), "xyz");
        assert_eq!(
            got, want,
            "flag 4 over rows 0..=2: 40 A + '\\r' (wrapped), 10 B + '\\n' (end of the logical line, \
             blank tail trimmed), 'xyz' + '\\n' (last row also terminated); got {got:?}"
        );
    });
}

/// A logical line wrapped over three rows: two `\r`, then the `\n`.
#[test]
fn flag_4_alone_marks_every_wrap_of_a_three_row_line() {
    assert_rig();
    with_term(|t| {
        feed(t, &format!("{}{}{}", a40(), "B".repeat(40), "C".repeat(5)));
        let got = text_range(t, 0, 0, 2, 39, SOFT_WRAP_MARKS);
        let want = format!("{}\r{}\r{}\n", a40(), "B".repeat(40), "C".repeat(5));
        assert_eq!(
            got, want,
            "a 85-char line on 40 cols wraps twice: expected '\\r' after rows 0 and 1 and '\\n' \
             after row 2; got {got:?}"
        );
    });
}

/// The terminator describes the ROW: a soft-wrapped row that is the last row
/// of the requested range still ends in `\r`, never `\n` and never nothing.
#[test]
fn flag_4_alone_last_requested_row_that_wrapped_still_ends_in_cr() {
    assert_rig();
    with_term(|t| {
        feed_wrapped_then_hard(t);
        let got = text_range(t, 0, 0, 0, 39, SOFT_WRAP_MARKS);
        assert_eq!(
            got,
            format!("{}\r", a40()),
            "row 0 soft-wrapped onto row 1, which is outside the range: it must still end in '\\r'; got {got:?}"
        );
        let hard_only = text_range(t, 2, 0, 2, 39, SOFT_WRAP_MARKS);
        assert_eq!(
            hard_only, "xyz\n",
            "a single hard-ended row is terminated with '\\n' (the last line included); got {hard_only:?}"
        );
    });
}

/// Without bit 2 the same range has no terminators at the wrap and none at
/// the end - the flag is what adds them.
#[test]
fn without_flag_4_wrapped_rows_join_with_no_terminator() {
    assert_rig();
    with_term(|t| {
        feed_wrapped_then_hard(t);
        let got = text_range(t, 0, 0, 2, 39, 0);
        assert_eq!(
            got,
            format!("{}{}\nxyz", a40(), "B".repeat(10)),
            "flag 0 over rows 0..=2: wrapped rows joined, '\\n' only at the hard break, no trailing terminator; got {got:?}"
        );
    });
}

// ---------------------------------------------------------------------------
// Flag 7 (rectangular | keep tab fill | soft-wrap marks): the find bar's mode
// ---------------------------------------------------------------------------

/// Rectangular + marks: one line per row, each clipped to the full 40 cols
/// with NO trimming, so the 1:1 row mapping the find bar relies on holds.
#[test]
fn flag_7_yields_exactly_one_full_width_line_per_row_with_wrap_terminators() {
    assert_rig();
    with_term(|t| {
        feed_wrapped_then_hard(t);
        let got = text_range(t, 0, 0, 2, 39, RECT | KEEP_TAB_FILL | SOFT_WRAP_MARKS);
        let want = format!(
            "{}\r{}{}\n{}{}\n",
            a40(),
            "B".repeat(10),
            " ".repeat(30),
            "xyz",
            " ".repeat(37)
        );
        assert_eq!(
            got.chars().count(),
            3 * 41,
            "flag 7 over 3 rows of 40 cols must be 3 * (40 cells + 1 terminator) = 123 chars; got {} chars: {got:?}",
            got.chars().count()
        );
        assert_eq!(
            got, want,
            "flag 7: row 0 = 40 A + '\\r', row 1 = 10 B + 30 blanks + '\\n', row 2 = 'xyz' + 37 blanks + '\\n'; got {got:?}"
        );
        // The same rows as lines: split on the terminators the find bar uses.
        let lines: Vec<&str> = got.split(['\r', '\n']).collect();
        assert_eq!(
            lines.len(),
            4,
            "three terminators split the text into 3 lines plus an empty tail; got {lines:?}"
        );
        assert!(
            lines[..3].iter().all(|l| l.chars().count() == 40),
            "every line must be exactly 40 cells wide; got widths {:?}",
            lines.iter().map(|l| l.chars().count()).collect::<Vec<_>>()
        );
    });
}

/// Bit 1 inside flag 7 keeps the tab's blank fill (one char per cell); the
/// same range with bit 1 cleared (flag 5) drops it. Bit 2 terminates both.
#[test]
fn flag_7_keeps_the_tab_fill_that_flag_5_drops() {
    assert_rig();
    with_term(|t| {
        feed(t, "a\tb\r\nc");
        // Cells 0..=9 of row 0: 'a', TAB marker, six blank fill cells, 'b', one blank.
        let kept = text_range(t, 0, 0, 0, 9, RECT | KEEP_TAB_FILL | SOFT_WRAP_MARKS);
        assert_eq!(
            kept, "a\t      b \n",
            "flag 7 keeps one char per grid cell (a, TAB, 6 fill blanks, b, blank) + '\\n'; got {kept:?}"
        );
        assert_eq!(
            kept.chars().count(),
            11,
            "10 cells + 1 terminator; got {kept:?}"
        );
        let dropped = text_range(t, 0, 0, 0, 9, RECT | SOFT_WRAP_MARKS);
        assert_eq!(
            dropped, "a\tb \n",
            "flag 5 (no keep-fill) drops the six fill blanks after the TAB; got {dropped:?}"
        );
    });
}

// ---------------------------------------------------------------------------
// The remaining combinations: each bit keeps its own meaning next to bit 2
// ---------------------------------------------------------------------------

/// Flag 5 = rectangular + marks (no keep-fill): full-width, untrimmed rows
/// with the wrap terminators.
#[test]
fn flag_5_is_rectangular_plus_marks() {
    assert_rig();
    with_term(|t| {
        feed_wrapped_then_hard(t);
        let got = text_range(t, 0, 0, 1, 39, RECT | SOFT_WRAP_MARKS);
        assert_eq!(
            got,
            format!("{}\r{}{}\n", a40(), "B".repeat(10), " ".repeat(30)),
            "flag 5 over rows 0..=1: untrimmed rows, '\\r' then '\\n'; got {got:?}"
        );
    });
}

/// Flag 6 = prose + keep-fill + marks: trimmed lines (prose), the tab fill
/// kept, and the terminators.
#[test]
fn flag_6_is_prose_plus_keep_fill_plus_marks() {
    assert_rig();
    with_term(|t| {
        feed(t, "a\tb\r\nc");
        let got = text_range(t, 0, 0, 1, 39, KEEP_TAB_FILL | SOFT_WRAP_MARKS);
        assert_eq!(
            got, "a\t      b\nc\n",
            "flag 6: prose trimming (no blank tails), the six fill blanks after the TAB kept, '\\n' after each of the two rows; got {got:?}"
        );
    });
}
