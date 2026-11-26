//! Grid text-range extraction: the selection-copy and Find path.

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags as CellFlags;

use crate::{BBTerm, MAX_TEXT_RANGE_ROWS};

const FLAG_RECT: u8 = 0b01;
/// One output char per grid cell: Find reads string offsets as grid columns.
const FLAG_KEEP_TAB_FILL: u8 = 0b10;
/// Terminate every row (the last included) with `\r` if it soft-wrapped and `\n` if not.
const FLAG_SOFT_WRAP_MARKS: u8 = 0b100;

pub(crate) fn extract_text_range(
    bb: &BBTerm,
    start_line: i32,
    start_col: u16,
    end_line: i32,
    end_col: u16,
    flags: u8,
) -> Vec<u8> {
    let grid = bb.term.grid();

    let cols = grid.columns();
    if cols == 0 {
        return Vec::new();
    }
    let last_col = cols - 1;

    let (s_line, s_col, e_line, e_col) = {
        let a = (start_line, start_col as usize);
        let b = (end_line, end_col as usize);
        let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
        (lo.0, lo.1.min(last_col), hi.0, hi.1.min(last_col))
    };

    let topmost = grid.topmost_line().0;
    let bottommost = grid.bottommost_line().0;

    // Clamp to the grid before iterating: i32::MIN / i32::MAX would spin ~4 billion iterations.
    let iter_start = s_line.max(topmost);
    let mut iter_end = e_line.min(bottommost);

    let span = (iter_end as i64).saturating_sub(iter_start as i64);
    // After the cap, iter_end is a hard stop, not the user's end row: no end-column clip there.
    let cap_truncated = span >= MAX_TEXT_RANGE_ROWS as i64;
    if cap_truncated {
        iter_end = iter_start.saturating_add((MAX_TEXT_RANGE_ROWS - 1) as i32);
    }

    let mut joined = String::new();
    let mut newline_pending = false;

    let rectangular = flags & FLAG_RECT != 0;
    let keep_tab_fill = flags & FLAG_KEEP_TAB_FILL != 0;
    // Grid cells never hold a control character, so the terminator cannot collide with row text.
    let mark_wraps = flags & FLAG_SOFT_WRAP_MARKS != 0;
    // A multi-row request clamped to one row is not a single-line pick: the start-row trim
    // still applies.
    let single_line = iter_start == iter_end && s_line == e_line;

    if iter_start > iter_end {
        return Vec::new();
    }

    let mut line_i = iter_start;
    while line_i <= iter_end {
        let row = &grid[Line(line_i)];
        // The last row is trimmed only when its end column sits in the row's blank fill; an end
        // inside the text, or before more text, keeps the spaces it selected.
        let blank_after = |col: usize| {
            ((col + 1)..=last_col).all(|tc| {
                let t = &row[Column(tc)];
                (t.c == ' ' || t.c == '\0') && t.zerowidth().is_none()
            })
        };
        let (col_lo, col_hi, trim) = if rectangular {
            // Sort columns independently: a box anchored top-right + bottom-left has s_col > e_col.
            (s_col.min(e_col), s_col.max(e_col), false)
        } else if single_line {
            (s_col, e_col, blank_after(e_col))
        } else if line_i == iter_start {
            (s_col, last_col, true)
        } else if line_i == iter_end && !cap_truncated {
            (0usize, e_col, blank_after(e_col))
        } else {
            (0usize, last_col, true)
        };

        if newline_pending {
            joined.push('\n');
        }
        let row_start = joined.len();
        joined.reserve(col_hi.saturating_sub(col_lo) + 1);
        let mut c = col_lo;
        let mut tab_mode = false;
        // A span that begins on a wide glyph's trailing spacer still selects the glyph. Not
        // LEADING_WIDE_CHAR_SPACER: it pads the row's end and its glyph is on the next row.
        if c > 0 && row[Column(c)].flags.contains(CellFlags::WIDE_CHAR_SPACER) {
            c -= 1;
        }
        while c <= col_hi {
            let cell = &row[Column(c)];
            // HT stores '\t' in the first cell of its span and blanks in the rest: after a '\t',
            // skip ' ' cells up to the next tab stop. A span that starts mid-tab keeps its blanks.
            if tab_mode {
                if bb.term.is_tab_stop(Column(c)) || cell.c != ' ' {
                    tab_mode = false;
                } else {
                    c += 1;
                    continue;
                }
            }
            if cell.c == '\t' && !keep_tab_fill {
                tab_mode = true;
            }
            if cell
                .flags
                .intersects(CellFlags::WIDE_CHAR_SPACER | CellFlags::LEADING_WIDE_CHAR_SPACER)
            {
                c += 1;
                continue;
            }
            let ch = cell.c;
            let out = if ch == '\0' { ' ' } else { ch };
            joined.push(out);
            // Width-0 scalars (combining marks, VS16, ZWJ) live in `zerowidth()`, not `cell.c`.
            if let Some(zw) = cell.zerowidth() {
                for &z in zw {
                    joined.push(z);
                }
            }
            c += 1;
        }

        // WRAPLINE on the row's last cell marks a soft wrap: no newline was emitted there.
        // Rectangular selection is exempt: box copies are row-per-row.
        let soft_wrapped = row[Column(last_col)].flags.contains(CellFlags::WRAPLINE);
        let wrapped = !rectangular && soft_wrapped;

        // A wrapped row's trailing spaces are content; only unwrapped rows carry padding.
        if trim && !wrapped {
            let trimmed_len = joined[row_start..].trim_end_matches(' ').len();
            // Only a one-cell pick of a blank keeps its lone space; a wider all-blank span is "".
            let one_cell_pick = single_line && col_lo == col_hi;
            if trimmed_len > 0 || !one_cell_pick {
                joined.truncate(row_start + trimmed_len);
            }
        }

        if mark_wraps {
            joined.push(if soft_wrapped { '\r' } else { '\n' });
        } else {
            newline_pending = !wrapped;
        }
        line_i += 1;
    }

    joined.into_bytes()
}
