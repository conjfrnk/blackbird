//! Blind regression tests for VT-4: copying text that contains TABs must
//! yield the TAB alone, not the TAB followed by the blank fill the terminal
//! drew to reach the next tab stop.
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and
//! documented terminal conventions only, never the implementation.
//!
//! Contract under test (`bb_term_text_range`, header doc + the convention
//! every mainstream terminal follows for selection of HT output):
//!   - `HT` (0x09) advances the cursor to the next tab stop (default: every
//!     8 columns). The terminal marks the cell where the tab started with
//!     U+0009 (see `unicode_cells::tab_advances_cursor_without_drawing_glyph`)
//!     and the cells it skipped over are blank fill, NOT typed data.
//!   - Extracting text over that span must round-trip the program's output:
//!     feeding `a\tb` and copying the row must yield `a\tb` - one tab, no
//!     fill spaces. Spaces the program really typed (before or after a tab)
//!     are data and must be preserved verbatim.
//!   - Pasting the copied text back into a terminal must reproduce the same
//!     on-screen layout (copy -> paste is idempotent for tab-drawn output).
//!
//! The bug being pinned: the tab marker was emitted AND every fill cell up
//! to the next stop was emitted as a space as well, so on a 40-col grid
//! `a\tb` copied as `a\t      b` (six extra spaces); a tab whose target is
//! more than one column away gained 1-7 spurious spaces. Visible in copied
//! TSV (`cat data.tsv`), Makefile / Go indentation, `git` output, Services
//! and Export Scrollback.
//!
//! Rig preconditions (asserted in EVERY test via `assert_rig`, so a green
//! run cannot mean "extraction is empty" or "tabs never advanced"):
//!   1. `a\tb` lands `a` at col 0 and `b` at col 8 (default stops, so the
//!      tab really spanned 7 columns of fill).
//!   2. A single-char extraction over col 0 returns `"a"`.
//!   3. A run of seven REAL spaces between `a` and `b` is extracted verbatim
//!      (`"a       b"`), proving the extractor does not blindly squeeze
//!      blank cells.
//!
//! Pre-flight cost: 40x3 grids (a few KB each) with at most 100 lines of
//! scrollback; at most ~60 terminals over the whole file, each freed
//! immediately. No sleeps, no threads, no I/O.

use blackbird_core as bc;

const COLS: u16 = 40;
const ROWS: u16 = 3;
const SCROLLBACK: u32 = 100;

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
    rect: u8,
) -> String {
    unsafe {
        let raw = bc::bb_term_text_range(term, start_line, start_col, end_line, end_col, rect);
        assert!(
            !raw.is_null(),
            "bb_term_text_range({start_line},{start_col},{end_line},{end_col},{rect}) returned null"
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

/// Raw `ch` values of visible row `row`, straight from a fresh snapshot.
fn row_chars(term: *mut bc::BBTerm, row: u16) -> Vec<u32> {
    unsafe {
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        assert_eq!((*snap).cols, COLS, "snapshot cols");
        assert!(row < (*snap).rows, "row {row} out of range");
        let mut out = Vec::with_capacity(COLS as usize);
        for col in 0..COLS {
            let idx = (row as usize) * (COLS as usize) + col as usize;
            out.push((*(*snap).cells.add(idx)).ch);
        }
        bc::bb_snap_release(snap);
        out
    }
}

/// Visible row as a printable string: unrendered cells become spaces and the
/// tab marker is shown as `\t`, so assertion messages are readable.
fn row_display(term: *mut bc::BBTerm, row: u16) -> String {
    row_chars(term, row)
        .into_iter()
        .map(|ch| match ch {
            0 => ' ',
            c => char::from_u32(c).unwrap_or('\u{FFFD}'),
        })
        .collect::<String>()
        .replace('\t', "\\t")
}

/// Preconditions shared by every test. See the file header.
fn assert_rig() {
    // 1 + 2: a tab really spans 7 fill columns and single-char extraction works.
    with_term(|t| {
        feed(t, "a\tb");
        let row = row_chars(t, 0);
        assert_eq!(
            (row[0], row[8]),
            ('a' as u32, 'b' as u32),
            "precondition: `a\\tb` must put 'a' at col 0 and 'b' at col 8 \
             (default 8-col tab stops); row = {:?}",
            row_display(t, 0)
        );
        assert_eq!(
            text_range(t, 0, 0, 0, 0, 0),
            "a",
            "precondition: extraction over col 0 must return \"a\""
        );
    });
    // 3: real typed spaces are data and must survive extraction.
    with_term(|t| {
        feed(t, "a       b"); // 7 real spaces
        assert_eq!(
            text_range(t, 0, 0, 0, 8, 0),
            "a       b",
            "precondition: seven REAL spaces between a and b must be extracted verbatim"
        );
    });
}

// ---------------------------------------------------------------------------
// The exact trigger from the bug report
// ---------------------------------------------------------------------------

/// `a\tb` selected exactly from `a` to `b` copies as `a\tb`, nothing between.
#[test]
fn tab_between_two_words_copies_as_a_single_tab() {
    assert_rig();
    with_term(|t| {
        feed(t, "a\tb");
        let got = text_range(t, 0, 0, 0, 8, 0);
        assert_eq!(
            got,
            "a\tb",
            "copying `a<TAB>b` must yield one tab and no fill spaces; \
             got {got:?} for grid row {:?}",
            row_display(t, 0)
        );
    });
}

/// The literal trigger: select the whole 40-col row `(0,0)..(0,39)`. The
/// last line of a prose selection is not trimmed (header doc), so blanks
/// after `b` are allowed - but NOTHING between the `a`, the tab and the `b`,
/// and nothing but blanks after `b`.
#[test]
fn whole_row_copy_starts_with_a_tab_b_then_only_blank_fill() {
    assert_rig();
    with_term(|t| {
        feed(t, "a\tb");
        let got = text_range(t, 0, 0, 0, COLS - 1, 0);
        assert!(
            got.starts_with("a\tb"),
            "whole-row copy of `a<TAB>b` must begin with exactly \"a\\tb\"; got {got:?}"
        );
        let tail = &got["a\tb".len()..];
        assert_eq!(
            tail.chars().filter(|&c| c != ' ').collect::<String>(),
            "",
            "after `b` only blank fill may follow; got tail {tail:?} (full {got:?})"
        );
        assert_eq!(
            got.matches('\t').count(),
            1,
            "exactly one tab expected in the copy; got {got:?}"
        );
    });
}

// ---------------------------------------------------------------------------
// Every tab distance 1..=8 columns
// ---------------------------------------------------------------------------

/// For a prefix of L = 1..=16 letters, the following HT travels
/// d = 8 - (L % 8) in 1..=8 columns. The copy of `prefix<TAB>Z` must be the
/// text as typed for every distance (the report: 1 column is fine, 2..8 gain
/// d-1 spurious spaces).
#[test]
fn tab_copies_as_one_tab_for_every_distance_from_one_to_eight_columns() {
    assert_rig();
    let letters = "abcdefghijklmnop";
    let mut failures: Vec<String> = Vec::new();
    for l in 1..=16usize {
        let prefix = &letters[..l];
        let z_col = ((l / 8 + 1) * 8) as u16;
        let typed = format!("{prefix}\tZ");
        with_term(|t| {
            feed(t, &typed);
            let row = row_chars(t, 0);
            assert_eq!(
                row[z_col as usize],
                'Z' as u32,
                "precondition (L={l}): Z must land on col {z_col}; row = {:?}",
                row_display(t, 0)
            );
            let got = text_range(t, 0, 0, 0, z_col, 0);
            if got != typed {
                failures.push(format!(
                    "L={l} (tab travels {} cols): typed {typed:?} copied {got:?}",
                    8 - (l % 8)
                ));
            }
        });
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "copy must reproduce the typed text for every tab distance"
    );
}

// ---------------------------------------------------------------------------
// Realistic outputs: TSV, indentation
// ---------------------------------------------------------------------------

/// `cat data.tsv`: three rows, two tabs each, copied across the line breaks.
#[test]
fn tsv_rows_copy_with_one_tab_per_field_separator() {
    assert_rig();
    with_term(|t| {
        feed(t, "id\tname\tcity\r\n1\tbob\tparis\r\n22\talice\tnyc");
        // Row 2 is "22" + tab -> col 8, "alice" 8..12, tab -> col 16, "nyc" 16..18.
        let got = text_range(t, 0, 0, 2, 18, 0);
        assert_eq!(
            got, "id\tname\tcity\n1\tbob\tparis\n22\talice\tnyc",
            "TSV copy must keep exactly one tab per separator; got {got:?}"
        );
    });
}

/// Makefile / Go style leading-tab indentation, including a double indent.
#[test]
fn leading_tab_indentation_copies_as_tabs() {
    assert_rig();
    with_term(|t| {
        feed(t, "func main() {\r\n\tif x {\r\n\t\treturn\r\n\t}\r\n}");
        // Five lines on a 3-row viewport: the first two are in history
        // (buffer lines -2 and -1), the viewport holds lines 0..=2. The last
        // line is "}" at col 0, so end_col = 0.
        assert_eq!(
            text_range(t, -2, 0, -2, 12, 0),
            "func main() {",
            "precondition: buffer line -2 must be the first (tab-free) source line"
        );
        let got = text_range(t, -2, 0, 2, 0, 0);
        assert_eq!(
            got, "func main() {\n\tif x {\n\t\treturn\n\t}\n}",
            "Go-style indentation must copy as tabs, not tab + fill; got {got:?}"
        );
    });
}

/// A copy that starts at column 0 of a tab-indented line and ends mid-line
/// (the common drag-select) must also be exact.
#[test]
fn double_leading_tab_then_word_copies_exactly() {
    assert_rig();
    with_term(|t| {
        feed(t, "\t\tfoo");
        // Two tabs: cols 0 -> 8 -> 16; "foo" occupies cols 16..=18.
        let got = text_range(t, 0, 0, 0, 18, 0);
        assert_eq!(
            got,
            "\t\tfoo",
            "two leading tabs must copy as exactly two tabs; got {got:?} for row {:?}",
            row_display(t, 0)
        );
    });
}

// ---------------------------------------------------------------------------
// Real spaces next to a tab are data, not fill
// ---------------------------------------------------------------------------

/// Spaces the program TYPED after a tab (at/after the tab stop) are data:
/// `a<TAB>  b` must not lose them while the fill before the stop goes.
#[test]
fn real_spaces_typed_after_a_tab_are_preserved() {
    assert_rig();
    with_term(|t| {
        feed(t, "a\t  b");
        // a@0, tab -> col 8, two typed spaces @8,9, b@10.
        let row = row_chars(t, 0);
        assert_eq!(
            row[10],
            'b' as u32,
            "precondition: b must land on col 10; row = {:?}",
            row_display(t, 0)
        );
        let got = text_range(t, 0, 0, 0, 10, 0);
        assert_eq!(
            got,
            "a\t  b",
            "the two typed spaces after the tab must survive while the fill is dropped; got {got:?}"
        );
    });
}

/// Spaces typed BEFORE a tab are data too: `a  <TAB>b`.
#[test]
fn real_spaces_typed_before_a_tab_are_preserved() {
    assert_rig();
    with_term(|t| {
        feed(t, "a  \tb");
        // a@0, spaces @1,2, tab @3 -> col 8, b@8.
        let row = row_chars(t, 0);
        assert_eq!(
            row[8],
            'b' as u32,
            "precondition: b must land on col 8; row = {:?}",
            row_display(t, 0)
        );
        let got = text_range(t, 0, 0, 0, 8, 0);
        assert_eq!(
            got, "a  \tb",
            "typed spaces before the tab must survive and the fill after it go; got {got:?}"
        );
    });
}

// ---------------------------------------------------------------------------
// Other extraction paths: scrollback export and rectangular selection
// ---------------------------------------------------------------------------

/// Export Scrollback / Select All path: a tab row that has scrolled into
/// history must come back as `a\tb` at the head of the whole-buffer copy.
#[test]
fn tab_row_in_scrollback_exports_as_a_single_tab() {
    assert_rig();
    with_term(|t| {
        // 3 visible rows; after 5 more lines the tab row is in history.
        feed(t, "a\tb\r\nl1\r\nl2\r\nl3\r\nl4\r\n");
        let visible = text_range(t, 0, 0, ROWS as i32 - 1, COLS - 1, 0);
        assert!(
            !visible.contains('\t'),
            "precondition: the tab row must have scrolled out of the viewport; visible = {visible:?}"
        );
        let got = text_range(t, i32::MIN, 0, i32::MAX, u16::MAX, 0);
        assert!(
            got.starts_with("a\tb\nl1\nl2\n"),
            "whole-buffer export must begin \"a\\tb\\nl1\\nl2\\n\"; got {got:?}"
        );
    });
}

/// Rectangular mode over a span that contains the whole tab: same text.
#[test]
fn rectangular_selection_over_a_whole_tab_span_copies_one_tab() {
    assert_rig();
    with_term(|t| {
        feed(t, "a\tb");
        let got = text_range(t, 0, 0, 0, 8, 1);
        assert_eq!(
            got, "a\tb",
            "rectangular copy of cols 0..=8 over `a<TAB>b` must be \"a\\tb\"; got {got:?}"
        );
    });
}

// ---------------------------------------------------------------------------
// Copy -> paste idempotence
// ---------------------------------------------------------------------------

/// Copy a tabbed row and paste (feed) it into a fresh terminal: the layout
/// must be identical to the original. With the bug, each tab picked up extra
/// fill spaces on paste so every later field shifted right by 1-7 columns.
#[test]
fn copy_then_paste_into_fresh_terminal_reproduces_the_same_layout() {
    assert_rig();
    let typed = "a\tb\tc";
    with_term(|origin| {
        feed(origin, typed);
        // a@0, tab->8, b@8, tab->16, c@16.
        let origin_row = row_chars(origin, 0);
        assert_eq!(
            (origin_row[0], origin_row[8], origin_row[16]),
            ('a' as u32, 'b' as u32, 'c' as u32),
            "precondition: original layout a@0 b@8 c@16; row = {:?}",
            row_display(origin, 0)
        );
        let copied = text_range(origin, 0, 0, 0, 16, 0);

        with_term(|pasted| {
            feed(pasted, &copied);
            assert_eq!(
                row_display(pasted, 0),
                row_display(origin, 0),
                "pasting the copy {copied:?} of {typed:?} must rebuild the identical row layout"
            );
            assert_eq!(
                copied, typed,
                "the copy of tab-drawn output must equal what the program wrote"
            );
        });
    });
}
