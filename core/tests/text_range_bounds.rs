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
            // An empty payload surfaces as `(*raw).bytes == NULL, len == 0`
            // (the null-ptr invariant from rust-core-4 F1 — so Swift/C
            // consumers can treat `bytes == NULL ⇔ empty` as load-bearing).
            // Rust's `slice::from_raw_parts` rejects a null pointer even
            // when `len == 0` (hardened libstd precondition, debug-panic;
            // UB in release). Branch on len so this helper tolerates the
            // documented empty shape without tripping the precondition.
            let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
                &[]
            } else {
                std::slice::from_raw_parts((*raw).bytes, (*raw).len)
            };
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
    // start_col=999 on a 10-col grid: the Rust side clamps to last_col (9).
    // Prose mode from (0,999) to (0,999) collapses to the char at col 9,
    // which is an unrendered cell (cols 5-9 were never written to — only
    // "hello" at cols 0-4). Unrendered cells surface as a single space.
    // If the clamp ever regresses to reading past the last column, this
    // assertion will change (either by trap or by reading OOB memory),
    // so a permissive `is_some()` check would hide the regression.
    let got = text_range_over_primed_grid(0, 999, 0, 999, 0);
    assert_eq!(
        got.as_deref(),
        Some(" "),
        "out-of-range col must clamp to last-col space"
    );
}

#[test]
fn text_range_max_col_does_not_trap() {
    // u16::MAX at both endpoints clamps to (0,9)..(0,9) — same result as
    // above. The point of this test is to catch arithmetic overflow or
    // panic in the clamp path. Assert the exact post-clamp content so a
    // future refactor that reads further than last_col trips the test.
    let got = text_range_over_primed_grid(0, u16::MAX, 0, u16::MAX, 0);
    assert_eq!(
        got.as_deref(),
        Some(" "),
        "u16::MAX col must clamp to last-col space without trapping"
    );
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

/// Audit M-1 (2026-05-03): a single FFI call must not allocate
/// O(rows × cols) on the request range. This test fills a deep
/// scrollback (200 000 rows of "Q\n"), then asks for the entire range
/// at once. With the cap engaged the returned text contains at most
/// `MAX_TEXT_RANGE_ROWS` lines (preserving the head, dropping the tail) —
/// truncation is the safer behaviour vs. erroring out, since every
/// realistic interactive selection fits well under the cap.
///
/// We can't directly probe RSS in a Rust unit test without bringing in
/// platform-specific syscalls, but we CAN assert the row-count bound on
/// the result, which is the proxy that catches a regression where the
/// cap is removed or set too high. The same regression would also
/// reintroduce the worst-case heap amplification.
///
/// Pre-flight: 200 000 rows × 1 col × ~32 B alacritty cell ≈ 6.4 MB grid;
/// the post-cap result is ≤ 65 536 single-char lines plus newline joins
/// ≈ 130 KB. Total < 10 MB transient on this test.
#[test]
fn text_range_caps_huge_request_at_max_rows() {
    use blackbird_core as bc;
    unsafe {
        // 4-col × 4-row visible grid + 200 000 scrollback. Feed enough
        // newline-terminated rows that the scrollback fills near-cap;
        // alacritty's grid clamps `history_size` to the configured
        // scrollback so this is the upper bound on iterable rows.
        let term = bc::bb_term_new(4, 4, 200_000);
        assert!(!term.is_null());

        // Push 70 000 rows of "Q\r\n" — comfortably above the
        // MAX_TEXT_RANGE_ROWS = 65 536 cap so the cap is the binding
        // constraint, not history size.
        let mut buf = Vec::with_capacity(70_000 * 3);
        for _ in 0..70_000 {
            buf.extend_from_slice(b"Q\r\n");
        }
        bc::bb_term_input(term, buf.as_ptr(), buf.len());

        // Ask for the entire universe of rows in a single call. The
        // i32::MIN/MAX/u16::MAX endpoints are exactly the worst-case
        // shape an out-of-bounds caller would produce.
        let raw = bc::bb_term_text_range(term, i32::MIN, 0, i32::MAX, u16::MAX, 0);
        assert!(
            !raw.is_null(),
            "huge text_range must succeed via truncation"
        );

        let bytes = if (*raw).len == 0 || (*raw).bytes.is_null() {
            &[][..]
        } else {
            std::slice::from_raw_parts((*raw).bytes, (*raw).len)
        };
        let text = std::str::from_utf8(bytes).expect("utf-8");
        // Count emitted rows. The cap is on iteration rows
        // (MAX_TEXT_RANGE_ROWS = 65 536), so the joined output contains
        // exactly `<= MAX` lines separated by '\n'.
        let line_count = text.bytes().filter(|&b| b == b'\n').count() + 1;
        assert!(
            line_count <= 65_536,
            "text_range must cap output at MAX_TEXT_RANGE_ROWS rows; \
             got {line_count} lines (cap = 65 536)"
        );
        // Lower-bound: the cap should still produce a NEAR-cap result
        // when asked for far more — otherwise a regression that capped
        // far too aggressively (e.g. at 1) would silently reduce
        // copy/paste fidelity for legitimate large selections.
        assert!(
            line_count > 1_000,
            "text_range cap must not be set so low that legitimate huge \
             selections truncate to nothing; got {line_count} lines"
        );

        bc::bb_string_release(raw);
        bc::bb_term_free(term);
    }
}

/// S5-002: when the caller's `end_line` is past the bottommost grid
/// row, the loop clamps `iter_end` to bottommost but the per-row
/// branch's `line_i == e_line` comparison uses the pre-clamp `e_line`
/// — so the final iterated row falls into the middle-row branch
/// `(0, last_col, true)` instead of the end-row branch
/// `(0, e_col, false)`. Result: the selection runs past the user's
/// `end_col` on the final visible row.
#[test]
fn text_range_e_line_past_bottommost_respects_end_col() {
    unsafe {
        let term = bc::bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        // Three rows × 10 cols. Each row's content is distinctive so
        // we can tell the per-row branching apart. \r\n returns to col 0.
        let input = b"aXXXXXXXXX\r\nbYYYYYYYYY\r\ncZZZZZZZZZ";
        bc::bb_term_input(term, input.as_ptr(), input.len());

        // Select (0,0)..(9999,2). end_line=9999 is far past the
        // bottommost (which is at most row 2 on a 3-row grid with no
        // scrollback). Expected: full row 0, full row 1, row 2 trimmed
        // to col 2 → "aXXXXXXXXX\nbYYYYYYYYY\ncZZ".
        let raw = bc::bb_term_text_range(term, 0, 0, 9999, 2, 0);
        assert!(!raw.is_null());
        let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
            &[]
        } else {
            std::slice::from_raw_parts((*raw).bytes, (*raw).len)
        };
        let got = std::str::from_utf8(bytes).unwrap_or_default().to_string();
        bc::bb_string_release(raw);
        bc::bb_term_free(term);

        assert_eq!(
            got, "aXXXXXXXXX\nbYYYYYYYYY\ncZZ",
            "out-of-grid end_line must still respect end_col on the last \
             actually-iterated row; got: {got:?}"
        );
    }
}

/// S5-003: symmetric to S5-002. When `start_line` is past the topmost
/// grid row (more negative than the deepest scrollback row), the loop
/// clamps `iter_start` up to topmost but the per-row branch's
/// `line_i == s_line` comparison uses pre-clamp `s_line` — so the
/// first iterated row falls into the middle-row branch
/// `(0, last_col, true)` instead of the start-row branch
/// `(s_col, last_col, true)`. Result: the user's start_col cue is
/// dropped on the topmost rendered row.
#[test]
fn text_range_s_line_below_topmost_respects_start_col() {
    unsafe {
        let term = bc::bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        let input = b"aXXXXXXXXX\r\nbYYYYYYYYY\r\ncZZZZZZZZZ";
        bc::bb_term_input(term, input.as_ptr(), input.len());

        // Select (-9999, 3)..(0, 9). start_line=-9999 is far below
        // any reachable scrollback row (the grid has no scrollback
        // here). topmost is 0. Expected: starts at row 0 col 3,
        // trimmed-tail to col 9 → "XXXXXXX" (cols 3..=9 of row 0).
        let raw = bc::bb_term_text_range(term, -9999, 3, 0, 9, 0);
        assert!(!raw.is_null());
        let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
            &[]
        } else {
            std::slice::from_raw_parts((*raw).bytes, (*raw).len)
        };
        let got = std::str::from_utf8(bytes).unwrap_or_default().to_string();
        bc::bb_string_release(raw);
        bc::bb_term_free(term);

        assert_eq!(
            got, "XXXXXXX",
            "out-of-grid start_line must still respect start_col on the \
             first actually-iterated row; got: {got:?}"
        );
    }
}

/// S1-002: when the caller's `end_line` is past the bottommost row AND
/// the clamped iteration collapses to a single row (`iter_start ==
/// iter_end`), the prose-mode branch must still apply the start-row
/// trim. At TAG `single_line` was tied to the caller's raw `s_line ==
/// e_line`, so the collapsed over-bottom case fell into the start-row
/// branch `(s_col, last_col, trim=true)` and trailing blanks were
/// stripped. At HEAD `single_line = (iter_start == iter_end)` matches,
/// dropping the row into the single-line branch
/// `(s_col, e_col, trim=false)` and the trailing blanks leak through.
///
/// Repro: 3×3 grid, row 2 = "a  ". Selecting (2,0)..(99,2) must trim
/// the two trailing spaces and return just "a".
#[test]
fn text_range_over_bottom_collapse_preserves_trim() {
    unsafe {
        let term = bc::bb_term_new(3, 3, 0);
        assert!(!term.is_null());
        // Row 0 = "r0r", row 1 = "r1r", row 2 = "a" (cols 1-2 unwritten,
        // surface as blanks).
        let input = b"r0r\r\nr1r\r\na";
        bc::bb_term_input(term, input.as_ptr(), input.len());

        // end_line=99 is past bottommost(=2). After clamping,
        // iter_start = iter_end = 2 — the loop iterates exactly one row.
        let raw = bc::bb_term_text_range(term, 2, 0, 99, 2, 0);
        assert!(!raw.is_null());
        let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
            &[]
        } else {
            std::slice::from_raw_parts((*raw).bytes, (*raw).len)
        };
        let got = std::str::from_utf8(bytes).unwrap_or_default().to_string();
        bc::bb_string_release(raw);
        bc::bb_term_free(term);

        assert_eq!(
            got, "a",
            "S1-002: over-bottom request that collapses to one row after \
             clamping must keep the start-row trim and strip trailing blanks; \
             got: {got:?}"
        );
    }
}

/// S4-001: when MAX_TEXT_RANGE_ROWS engages and `iter_end` is moved to
/// `iter_start + MAX - 1` (the cap row), the per-row branch's comparison
/// must NOT treat the cap row as the end-row. At TAG the comparison
/// used the caller's raw `e_line` — the cap row didn't match
/// `line_i == e_line`, so it fell into the middle-row branch
/// `(0, last_col, trim=true)` and the row was emitted in full. At HEAD
/// the comparison uses `line_i == iter_end`, which DOES match the cap
/// row, treating it as the end-row `(0, e_col, false)` and cropping to
/// `e_col` — a column the user intended for the original (uncapped)
/// final row, not for this arbitrary cap row.
///
/// Repro: 10-col × 4-row grid + 200 000 scrollback, 70 000 rows of
/// `"AAAAAAAAAA"`. Select (i32::MIN, 0)..(i32::MAX, 2). The post-cap
/// final row should still be a full "AAAAAAAAAA", not the 3-char "AAA"
/// crop.
#[test]
fn text_range_row_cap_does_not_crop_capped_row_to_end_col() {
    unsafe {
        let term = bc::bb_term_new(10, 4, 200_000);
        assert!(!term.is_null());

        // 70 000 rows × 12 bytes = ~840 KB feed, comfortably above the
        // MAX_TEXT_RANGE_ROWS = 65 536 cap so the cap is the binding
        // constraint.
        let mut buf = Vec::with_capacity(70_000 * 12);
        for _ in 0..70_000 {
            buf.extend_from_slice(b"AAAAAAAAAA\r\n");
        }
        bc::bb_term_input(term, buf.as_ptr(), buf.len());

        // Worst-case caller shape: full i32 span with a small e_col.
        let raw = bc::bb_term_text_range(term, i32::MIN, 0, i32::MAX, 2, 0);
        assert!(
            !raw.is_null(),
            "huge text_range must succeed via truncation"
        );
        let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
            &[]
        } else {
            std::slice::from_raw_parts((*raw).bytes, (*raw).len)
        };
        let text = std::str::from_utf8(bytes).unwrap_or_default().to_string();
        bc::bb_string_release(raw);
        bc::bb_term_free(term);

        // The cap row is the LAST emitted line. It should be a full
        // 10-character row of A's, not cropped to e_col=2.
        let last_line = text.rsplit('\n').next().unwrap_or("");
        assert_eq!(
            last_line, "AAAAAAAAAA",
            "S4-001: when the MAX_TEXT_RANGE_ROWS cap fires, the cap row \
             must keep middle-row (full-row) treatment instead of being \
             cropped to the caller's end_col; got last line {last_line:?}"
        );
    }
}
