//! Blind regression tests for VT-1: `CSI Ps b` (REP, "repeat preceding
//! graphic character") applied to a zero-width scalar must not grow one
//! cell's combining-mark list without bound.
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and
//! the documented behaviour only, never the implementation.
//!
//! Contract under test:
//!   - A zero-width scalar (combining mark, ZWJ, ZWSP, VS16, ...) occupies no
//!     column of its own; it rides on the cell it is attached to. A terminal
//!     must therefore bound the per-cell amount of such "riders" - otherwise
//!     a few bytes of output turn into hundreds of MB of resident memory and
//!     of copy / export text. Ordinary content (a base glyph plus one or two
//!     combining marks, e.g. Vietnamese NFD) is untouched.
//!   - `ESC [ 65535 b` is 8 input bytes. Applied to a zero-width scalar it
//!     asks for 65,535 more riders on ONE cell. The resulting cell text
//!     (observed through `bb_term_text_range`, the same path used by
//!     Cmd-C / Export) must stay small no matter how many REPs are sent,
//!     whichever way the core chooses to enforce that (cap per cell, ignore
//!     REP of a zero-width scalar, ...).
//!   - REP of an ordinary printable glyph keeps working (rig precondition,
//!     asserted in every test so a vacuous pass is impossible).
//!
//! How the bug is observed: the whole viewport is extracted as text (prose
//! mode) and its `char` count is compared against a generous ceiling
//! (`MAX_VIEWPORT_CHARS`). A 20x3 viewport holds at most 60 cells plus two
//! newlines, so anything near the ceiling can only be riders on a cell.
//! Unfixed, ONE `ESC[65535b` yields >= 65,537 chars on one cell.
//!
//! Pre-flight cost (unfixed worst case, i.e. when the bug is present):
//!   - grid: 20x3, scrollback 16 -> a few KB.
//!   - flood: at most 16 REPs x 65,535 scalars = ~1.05 M `char`s (~4 MiB Vec,
//!     ~2.1 MiB UTF-8 extraction). No sleeps, no I/O, no threads. The
//!     4096-REP case from the bug report (~1 GiB) is deliberately NOT run.
//!   - fixed: a few hundred bytes.

use blackbird_core as bc;

const COLS: u16 = 20;
const ROWS: u16 = 3;
const SCROLLBACK: u32 = 16;

/// Ceiling for the whole-viewport extraction, in `char`s. Real content in
/// this test is < 100 chars; a sane per-cell cap on riders is tens to a few
/// hundreds. 4096 leaves ample headroom for any reasonable cap yet is 16x
/// below what a single unfixed `ESC[65535b` produces.
const MAX_VIEWPORT_CHARS: usize = 4096;

/// `ESC [ 65535 b` - the maximum-count REP from the report (8 bytes).
const REP_MAX: &[u8] = b"\x1b[65535b";

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

/// Extract `(start_line, start_col)..=(end_line, end_col)` as UTF-8 text via
/// `bb_term_text_range`. Panics on a null reply (none of these scenarios
/// should produce one). Tolerates the documented `bytes == NULL <=> len == 0`
/// empty shape.
fn extract(
    term: *mut bc::BBTerm,
    start_line: i32,
    start_col: u16,
    end_line: i32,
    end_col: u16,
) -> String {
    unsafe {
        let raw = bc::bb_term_text_range(term, start_line, start_col, end_line, end_col, 0);
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

/// Whole visible viewport as text.
fn viewport_text(term: *mut bc::BBTerm) -> String {
    extract(term, 0, 0, (ROWS - 1) as i32, COLS - 1)
}

/// Char (not byte) count of the viewport text - the quantity a user pastes
/// after Cmd-C and the one that scales with the cell's rider list.
fn viewport_chars(term: *mut bc::BBTerm) -> usize {
    viewport_text(term).chars().count()
}

/// The `ch` of the cell at `(col, row)` in a fresh snapshot.
fn cell_ch(term: *mut bc::BBTerm, col: u16, row: u16) -> u32 {
    unsafe {
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        assert!(col < (*snap).cols && row < (*snap).rows);
        let idx = (row as usize) * ((*snap).cols as usize) + col as usize;
        let ch = (*(*snap).cells.add(idx)).ch;
        bc::bb_snap_release(snap);
        ch
    }
}

/// Rig preconditions. Without these a green run could mean "REP is not
/// implemented at all" or "text_range drops combining marks", i.e. the
/// bound assertions would pass vacuously.
///
///   1. REP of an ordinary glyph repeats it: `x ESC[3b` -> `xxxx`.
///   2. Combining marks are surfaced by text extraction, so the char count
///      really measures the cell's rider list: `a U+0301` -> `a\u{301}`.
///   3. Ordinary stacked marks (Vietnamese NFD: e + U+0323 + U+0302) are
///      kept verbatim, so the bound cannot be satisfied by dropping every
///      rider.
fn assert_rig_preconditions() {
    unsafe {
        let t = new_term();
        feed_str(t, "x\x1b[3b");
        let got = extract(t, 0, 0, 0, COLS - 1);
        assert_eq!(
            got.trim_end(),
            "xxxx",
            "precondition: REP of an ordinary glyph must repeat it; got {got:?}"
        );
        bc::bb_term_free(t);

        let t = new_term();
        feed_str(t, "a\u{0301}");
        let got = extract(t, 0, 0, 0, COLS - 1);
        assert_eq!(
            got.trim_end(),
            "a\u{0301}",
            "precondition: text extraction must surface the combining mark; got {got:?}"
        );
        bc::bb_term_free(t);

        let t = new_term();
        feed_str(t, "e\u{0323}\u{0302}");
        let got = extract(t, 0, 0, 0, COLS - 1);
        assert_eq!(
            got.trim_end(),
            "e\u{0323}\u{0302}",
            "precondition: a normal 2-mark stack must survive verbatim; got {got:?}"
        );
        bc::bb_term_free(t);
    }
}

#[test]
fn single_rep_of_combining_mark_keeps_cell_text_bounded() {
    assert_rig_preconditions();
    unsafe {
        let t = new_term();
        // 'a', COMBINING ACUTE ACCENT, then one 8-byte REP asking for
        // 65,535 more acutes on the same cell, then a plain 'Z'.
        feed_str(t, "a\u{0301}");
        feed(t, REP_MAX);
        feed_str(t, "Z");

        let text = viewport_text(t);
        let chars = text.chars().count();
        assert!(
            chars <= MAX_VIEWPORT_CHARS,
            "VT-1: one `ESC[65535b` after `a U+0301` left {chars} chars in the \
             {COLS}x{ROWS} viewport text ({} UTF-8 bytes); expected <= {MAX_VIEWPORT_CHARS} \
             (zero-width riders on one cell must be bounded)",
            text.len()
        );

        // Collateral: the combining mark does not occupy a column, so the
        // base glyph stays in col 0 and the following 'Z' lands in col 1 -
        // the REP flood must not have shifted, wrapped or overwritten cells.
        assert_eq!(
            cell_ch(t, 0, 0),
            b'a' as u32,
            "base glyph in col 0 must survive the REP"
        );
        assert_eq!(
            cell_ch(t, 1, 0),
            b'Z' as u32,
            "'Z' typed after the REP must land in col 1 (zero-width scalars take no column)"
        );
        bc::bb_term_free(t);
    }
}

#[test]
fn single_rep_of_bare_combining_mark_at_column_zero_is_bounded() {
    assert_rig_preconditions();
    unsafe {
        let t = new_term();
        // Fresh terminal, cursor at (0,0), nothing printed: a BARE zero-width
        // scalar, then one maximum REP.
        feed_str(t, "\u{0301}");
        feed(t, REP_MAX);

        let text = viewport_text(t);
        let chars = text.chars().count();
        assert!(
            chars <= MAX_VIEWPORT_CHARS,
            "VT-1: one `ESC[65535b` after a bare U+0301 at column 0 left {chars} chars in the \
             {COLS}x{ROWS} viewport text ({} UTF-8 bytes); expected <= {MAX_VIEWPORT_CHARS}",
            text.len()
        );
        bc::bb_term_free(t);
    }
}

#[test]
fn many_reps_do_not_accumulate_on_one_cell() {
    assert_rig_preconditions();
    const REPS: usize = 16;
    unsafe {
        let t = new_term();
        feed_str(t, "a\u{0301}");

        // Size after the first REP is the steady state: whatever the core's
        // bounding policy is (cap, or ignore REP of zero-width), it must
        // already be in effect, and 15 more REPs must add nothing.
        feed(t, REP_MAX);
        let after_one = viewport_chars(t);
        for _ in 1..REPS {
            feed(t, REP_MAX);
        }
        let after_many = viewport_chars(t);

        assert!(
            after_many <= MAX_VIEWPORT_CHARS,
            "VT-1: {REPS} x `ESC[65535b` ({} input bytes) left {after_many} chars in the \
             {COLS}x{ROWS} viewport text (after the first REP: {after_one}); expected <= \
             {MAX_VIEWPORT_CHARS} - output must not scale with input",
            REPS * REP_MAX.len()
        );
        assert_eq!(
            after_many, after_one,
            "VT-1: viewport text kept growing with repeated REPs of a zero-width scalar \
             ({after_one} chars after 1 REP -> {after_many} after {REPS}); the per-cell \
             bound must hold, not merely slow the growth"
        );
        bc::bb_term_free(t);
    }
}

#[test]
fn rep_of_other_zero_width_scalars_is_bounded() {
    assert_rig_preconditions();
    // Distinct zero-width classes: combining mark, ZWJ, ZWSP, VS16.
    let scalars: [(&str, char); 4] = [
        ("COMBINING ACUTE U+0301", '\u{0301}'),
        ("ZERO WIDTH JOINER U+200D", '\u{200D}'),
        ("ZERO WIDTH SPACE U+200B", '\u{200B}'),
        ("VARIATION SELECTOR-16 U+FE0F", '\u{FE0F}'),
    ];
    let mut offenders: Vec<String> = Vec::new();
    let mut table: Vec<String> = Vec::new();
    for (name, ch) in scalars {
        unsafe {
            let t = new_term();
            let mut s = String::from("a");
            s.push(ch);
            feed_str(t, &s);
            feed(t, REP_MAX);
            let chars = viewport_chars(t);
            table.push(format!("{name}: {chars} chars"));
            if chars > MAX_VIEWPORT_CHARS {
                offenders.push(format!("{name}: {chars} chars"));
            }
            bc::bb_term_free(t);
        }
    }
    assert_eq!(
        offenders,
        Vec::<String>::new(),
        "VT-1: `a <zero-width> ESC[65535b` must leave <= {MAX_VIEWPORT_CHARS} chars in the \
         viewport for every zero-width class; measured [{}]",
        table.join("; ")
    );
}
