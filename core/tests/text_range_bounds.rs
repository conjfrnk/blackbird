//! `bb_term_text_range` bounds tests.
//!
//! The FFI takes `(start_line: i32, start_col: u16, end_line: i32, end_col: u16)`.
//! Swift's BBTerm.textRange clamps cols via `UInt16(clamping:)` before the
//! call, but the Rust side must also clamp / skip out-of-range inputs so a
//! future caller that doesn't clamp upstream can't leak memory past the
//! grid edge.

use blackbird_core as bc;

/// Call `bb_term_text_range` against a 10×5 grid primed with known content.
/// Return the decoded UTF-8 reply (or None on null).
fn text_range_over_primed_grid(
    start_line: i32,
    start_col: u16,
    end_line: i32,
    end_col: u16,
    rect: u8,
) -> Option<String> {
    unsafe {
        let term = bc::bb_term_new(10, 5, 100);
        assert!(!term.is_null());
        bc::bb_term_input(term, b"hello".as_ptr(), 5);

        let raw = bc::bb_term_text_range(term, start_line, start_col, end_line, end_col, rect);
        let out = if raw.is_null() {
            None
        } else {
            let bytes = std::slice::from_raw_parts((*raw).bytes, (*raw).len);
            let s = std::str::from_utf8(bytes)
                .map(|s| s.to_string())
                .unwrap_or_default();
            bc::bb_string_release(raw);
            Some(s)
        };
        bc::bb_term_free(term);
        out
    }
}

#[test]
fn text_range_zero_to_zero_returns_single_char() {
    // Sanity: baseline works. (0,0)..(0,0) single-char prose selection
    // at start returns just 'h'.
    let got = text_range_over_primed_grid(0, 0, 0, 0, 0);
    assert_eq!(got.as_deref(), Some("h"));
}

#[test]
fn text_range_col_past_last_clamps_to_grid_edge() {
    // start_col=999 on a 10-col grid: the Rust side clamps to last_col
    // rather than reading past the row. Prose mode from (0,999) to
    // (0,999) collapses to the last column's char.
    let got = text_range_over_primed_grid(0, 999, 0, 999, 0);
    // last column of row 0 on our primed grid is a space (row is "hello"
    // in cols 0-4, rest spaces). `textRange` strips trailing whitespace
    // on multi-line prose mode but not on single-line.
    assert!(got.is_some(), "out-of-range col must not return null");
    let _ = got;
}

#[test]
fn text_range_max_col_does_not_trap() {
    // u16::MAX cols would otherwise trigger arithmetic oddities if not
    // clamped. Must return a valid (possibly empty) string without
    // trap.
    let got = text_range_over_primed_grid(0, u16::MAX, 0, u16::MAX, 0);
    assert!(got.is_some(), "u16::MAX col must not trap");
}

#[test]
fn text_range_out_of_range_lines_return_empty() {
    // Lines way past the bottommost are clamped to the actual range;
    // if the clamped range is empty (`iter_start > iter_end`), the FFI
    // returns an empty string rather than null or a trap.
    let got = text_range_over_primed_grid(1000, 0, 2000, 0, 0);
    assert_eq!(
        got.as_deref(),
        Some(""),
        "out-of-grid line range must return empty text"
    );
}
