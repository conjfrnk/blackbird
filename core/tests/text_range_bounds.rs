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
        assert!(!raw.is_null(), "huge text_range must succeed via truncation");

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
