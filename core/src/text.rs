//! Grid text-range extraction — the ⌘C / selection-copy path. Walks a linear
//! or rectangular span of cells into UTF-8 bytes, preserving zero-width scalars
//! (combining marks, VS16, ZWJ) and soft-wrap semantics, with an allocation
//! cap. Pure logic over `&BBTerm`, directly unit-testable. Extracted from the
//! body of bb_term_text_range (REFACTOR.md Part IV).

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags as CellFlags;

use crate::{BBTerm, MAX_TEXT_RANGE_ROWS};

/// Extract the text in the (possibly rectangular) cell span as UTF-8 bytes.
/// Returns empty for a degenerate/empty range. The caller wraps the bytes in a
/// `BBString`.
pub(crate) fn extract_text_range(
    bb: &BBTerm,
    start_line: i32,
    start_col: u16,
    end_line: i32,
    end_col: u16,
    rect: u8,
) -> Vec<u8> {
    let grid = bb.term.grid();

    let cols = grid.columns();
    if cols == 0 {
        // No columns to read from; return an empty string for C-side
        // convenience (single allocation pair, len == 0).
        return Vec::new();
    }
    let last_col = cols - 1;

    // Normalize so (start_line, start_col) <= (end_line, end_col).
    let (s_line, s_col, e_line, e_col) = {
        let a = (start_line, start_col as usize);
        let b = (end_line, end_col as usize);
        let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
        (lo.0, lo.1.min(last_col), hi.0, hi.1.min(last_col))
    };

    let topmost = grid.topmost_line().0;
    let bottommost = grid.bottommost_line().0;

    // Clamp to what actually exists in the grid before iterating. A
    // caller that passes i32::MIN / i32::MAX (or the fuzzer in
    // core/fuzz) would otherwise spin ~4 billion loop iterations that
    // each do nothing but bounds-check and increment.
    let iter_start = s_line.max(topmost);
    let mut iter_end = e_line.min(bottommost);

    // Audit M-1 (2026-05-03): bound the per-call allocation so a
    // single FFI request can't drive an O(rows × cols) heap
    // amplification. Without the cap a 200 000-row scrollback ×
    // 1000-col grid yields ~200 MB transient on one call. Truncate
    // (preserve the head of the requested range, drop the tail)
    // rather than fail outright — every realistic selection fits
    // well under the cap, and truncation keeps user-visible behaviour
    // stable instead of returning null on legitimate huge selections.
    // i64 arithmetic side-steps the i32::MIN/MAX overflow case the
    // post-clamp range can still expose if the grid spans the full
    // i32 range.
    let span = (iter_end as i64).saturating_sub(iter_start as i64);
    // Track cap-truncation separately from grid-clamp. iter_end after
    // the cap is a hard-stop, NOT the user's intended end row —
    // applying the end-row column-respect branch to the cap row would
    // silently crop a mid-selection row to e_col (which was intended
    // for the user's unreached final row). Audit S4-001.
    let cap_truncated = span >= MAX_TEXT_RANGE_ROWS as i64;
    if cap_truncated {
        iter_end = iter_start.saturating_add((MAX_TEXT_RANGE_ROWS - 1) as i32);
    }

    // Build straight into one accumulator, inserting '\n' only at hard
    // line breaks. This used to stage every row in its own String, collect
    // those into a Vec, then copy the lot into a second String — which the
    // find bar pays once per scrollback row per keystroke (FindController
    // falls through to `textRange` for every row outside the viewport, up
    // to the 100k-line default scrollback, synchronously on the main
    // thread). Two surplus allocations and a full redundant copy per row.
    //
    // The newline is DEFERRED rather than appended: `newline_pending`
    // records that the previous emitted row ended without a soft wrap, and
    // the '\n' is written just before the next row's text. That reproduces
    // the old two-pass join exactly, including the "no trailing newline
    // after the last row" property (the flag is simply never consumed).
    let mut joined = String::new();
    let mut newline_pending = false;

    let rectangular = rect != 0;
    // The per-row branches compare line_i against iter_start /
    // iter_end (the clamped iteration bounds) so callers whose raw
    // s_line/e_line sat outside the grid still get column-respect on
    // the clamped extremity rows (audit S5-002 / S5-003).
    // But the iter-collapse case (iter_start == iter_end after a
    // multi-row request was clamped to one row) must NOT be treated
    // as a single-line pick — the user explicitly asked for multiple
    // rows, so the start-row trim semantic still applies. Require
    // both iteration collapse AND user-endpoint identity. Audit
    // S1-002.
    let single_line = iter_start == iter_end && s_line == e_line;

    if iter_start > iter_end {
        return Vec::new();
    }

    let mut line_i = iter_start;
    while line_i <= iter_end {
        let (col_lo, col_hi, trim) = if rectangular {
            // Rectangular mode clips every row to the column span of
            // the bounding box. Tuple-normalisation above only orders
            // (line, col) as a pair, so a rectangle anchored at
            // top-right+bottom-left would land here with s_col > e_col
            // and the inner `while c <= col_hi` loop would skip the
            // row entirely. Sort columns independently so the box's
            // geometry is always extracted.
            (s_col.min(e_col), s_col.max(e_col), false)
        } else if single_line {
            (s_col, e_col, false)
        } else if line_i == iter_start {
            (s_col, last_col, true)
        } else if line_i == iter_end && !cap_truncated {
            (0usize, e_col, false)
        } else {
            (0usize, last_col, true)
        };

        if newline_pending {
            joined.push('\n');
        }
        // Byte offset where THIS row's text starts, so the trailing-space
        // trim below stays scoped to this row rather than eating the
        // previous one's. Always a char boundary: only whole chars are
        // pushed.
        let row_start = joined.len();
        joined.reserve(col_hi.saturating_sub(col_lo) + 1);
        let row = &grid[Line(line_i)];
        let mut c = col_lo;
        while c <= col_hi {
            let cell = &row[Column(c)];
            // Skip wide-char spacer cells entirely. alacritty stores a
            // wide char (CJK, emoji) in the primary cell and a '\0'
            // sentinel in the continuation cell to its right; naively
            // emitting ' ' for every '\0' produces "中 文 " instead of
            // "中文" and breaks paste round-trip. The leading spacer is
            // the analogous cell at the end of a line just before a wide
            // glyph wraps — same skip rule applies.
            if cell
                .flags
                .intersects(CellFlags::WIDE_CHAR_SPACER | CellFlags::LEADING_WIDE_CHAR_SPACER)
            {
                c += 1;
                continue;
            }
            let ch = cell.c;
            // alacritty uses '\0' for unrendered/empty cells; surface as
            // a plain space so callers can concatenate without seeing
            // embedded NULs in their UTF-8.
            let out = if ch == '\0' { ' ' } else { ch };
            joined.push(out);
            // Audit S5-001: width-0 scalars do NOT live in `cell.c` —
            // alacritty stores combining accents (U+0301 …), variation
            // selectors (VS16 U+FE0F), ZWJ, and every other zero-width
            // scalar in the cell's `zerowidth()` extra list (see
            // `Term::input`'s width==0 branch → `push_zerowidth`).
            // Upstream's own `line_to_string` re-emits them; dropping
            // them here meant ⌘C of an NFD filename pasted "cafe" for
            // "café" and ⚠️ (U+26A0 U+FE0F) pasted as bare U+26A0 —
            // silent copy-fidelity loss on a core terminal operation.
            if let Some(zw) = cell.zerowidth() {
                for &z in zw {
                    joined.push(z);
                }
            }
            c += 1;
        }

        // Audit S5-002: a row whose LAST cell carries WRAPLINE is a
        // soft-wrapped continuation of the same logical line — the
        // shell never emitted a newline there, the text merely ran out
        // of columns. Upstream alacritty's `line_to_string` appends
        // '\n' only when the row's last cell lacks WRAPLINE; joining
        // unconditionally injected hard newlines into copied text, so
        // pasting a wrapped command back executed its leading fragment.
        // The flag lives on the row's actual last cell regardless of
        // the selection's column span. Rectangular (box) selection is
        // exempt by design: box copies are row-per-row.
        let wrapped = !rectangular && row[Column(last_col)].flags.contains(CellFlags::WRAPLINE);

        // S5-002 second half: a wrapped row is full-width content —
        // its trailing spaces are real characters interior to the
        // logical line (upstream treats WRAPLINE rows as full-width
        // in `line_length`). Only unwrapped rows carry '\0'-padding
        // that the trim is meant to drop.
        if trim && !wrapped {
            let trimmed_len = joined[row_start..].trim_end_matches(' ').len();
            joined.truncate(row_start + trimmed_len);
        }

        // A '\n' is owed before the NEXT row iff this one wasn't soft-
        // wrapped. Never consumed after the final row, so the result has no
        // trailing newline — matching the previous join.
        newline_pending = !wrapped;
        line_i += 1;
    }

    joined.into_bytes()
}
