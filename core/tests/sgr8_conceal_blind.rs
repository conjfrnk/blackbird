//! Blind regression tests for SGR 8 ("conceal" / "invisible") reaching the
//! snapshot the renderer draws from.
//!
//! Bug (VT-8): `printf '\e[8mSECRET\e[0m ok\n'` shows SECRET in the normal
//! foreground colour. xterm, iTerm2, VTE and kitty all show blanks (the text
//! is still stored, it is just not painted). Blackbird parsed and stored the
//! attribute but the snapshot handed to the renderer carried no trace of it,
//! so concealed text was drawn in clear on screen and in scrollback, and
//! every consumer of the snapshot cells (selection copy, find) saw the
//! original glyphs.
//!
//! Author had no access to the implementation. Only the public FFI surface
//! (`bb_term_new` / `bb_term_input` / `bb_term_take_snapshot` / `bb_term_scroll`
//! / `BBCell` / `cell_flags`) and the generated header were consulted.
//!
//! ## What "concealed" means here (fix-shape tolerant)
//!
//! The snapshot ABI offers a renderer exactly four things for a cell: the
//! scalar `ch`, the resolved colours `fg` / `bg`, and `flags`. A cell is
//! "drawn in clear" when a renderer following the documented ABI paints the
//! ORIGINAL glyph in a colour distinguishable from the background:
//!
//!   * `ch` still equals the original scalar, AND
//!   * `fg != bg` (the glyph would not vanish into its own background), AND
//!   * no flag bit beyond the 14 documented ones (`cell_flags` bits 0..=13) is
//!     set. A fix that adds a new `HIDDEN`-style bit (bit 14 or 15) is a
//!     legitimate way to tell the renderer to skip the glyph, so such a bit
//!     counts as "the snapshot carries the conceal".
//!
//! Any of the three sensible fixes (blank / replace `ch`, paint the glyph in
//! the background colour, or expose a new flag bit) therefore passes, while
//! the current behaviour (`ch` = 'S', fg != bg, no extra bit) fails. Every
//! test also renders a control (the same text WITHOUT conceal) and requires
//! those cells to be drawn in clear, so the oracle cannot pass vacuously
//! (e.g. on a theme whose fg equals its bg) and a fix that hides too much is
//! caught too.
//!
//! Cost: the largest grid is 20 x 3 (60 cells x 20 B) with 100 lines of
//! scrollback; every test allocates a few KiB and finishes in microseconds.

use blackbird_core::*;

/// Flag bits documented in `cell_flags` at the time of writing (0..=13). Any
/// bit above these on a cell means the snapshot is carrying extra per-cell
/// state the old ABI could not express - for this bug, the conceal marker.
const DOCUMENTED_FLAGS: u16 = 0x3FFF;

/// Detached copy of one `BBCell`, so assertions can outlive the snapshot.
#[derive(Clone, Copy, Debug)]
struct Cell {
    ch: u32,
    fg: u32,
    bg: u32,
    flags: u16,
}

impl Cell {
    /// True if a renderer would paint exactly `original` in a visible colour.
    fn shows_glyph(&self, original: char) -> bool {
        self.ch == original as u32 && self.fg != self.bg && self.flags & !DOCUMENTED_FLAGS == 0
    }

    fn describe(&self) -> String {
        format!(
            "ch={:?}(U+{:04X}) fg=#{:06X} bg=#{:06X} flags=0x{:04X}",
            char::from_u32(self.ch).unwrap_or('?'),
            self.ch,
            self.fg,
            self.bg,
            self.flags
        )
    }
}

/// A decoded snapshot: cells copied out plus the viewport metadata the
/// scrollback test needs as preconditions.
struct Shot {
    cols: usize,
    rows: usize,
    display_offset: u32,
    history_size: u32,
    cells: Vec<Cell>,
}

impl Shot {
    fn at(&self, row: usize, col: usize) -> Cell {
        assert!(
            row < self.rows && col < self.cols,
            "cell ({row},{col}) outside {}x{} snapshot",
            self.rows,
            self.cols
        );
        self.cells[row * self.cols + col]
    }

    /// Cells of `word` laid out left to right starting at `(row, col0)` that
    /// are drawn in clear. Empty means the whole word is concealed.
    fn leaked(&self, row: usize, col0: usize, word: &str) -> Vec<String> {
        word.chars()
            .enumerate()
            .filter_map(|(i, ch)| {
                let cell = self.at(row, col0 + i);
                if cell.shows_glyph(ch) {
                    Some(format!("({row},{}) {}", col0 + i, cell.describe()))
                } else {
                    None
                }
            })
            .collect()
    }

    /// Cells of `word` at `(row, col0)` that are NOT drawn in clear. Empty
    /// means the whole word is legible (used for controls).
    fn hidden(&self, row: usize, col0: usize, word: &str) -> Vec<String> {
        word.chars()
            .enumerate()
            .filter_map(|(i, ch)| {
                let cell = self.at(row, col0 + i);
                if cell.shows_glyph(ch) {
                    None
                } else {
                    Some(format!("({row},{}) {}", col0 + i, cell.describe()))
                }
            })
            .collect()
    }
}

/// Take a snapshot of `term` and copy it out. Releases the snapshot.
unsafe fn shot(term: *mut BBTerm) -> Shot {
    let snap = bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
    let cols = (*snap).cols as usize;
    let rows = (*snap).rows as usize;
    let len = (*snap).cells_len;
    assert_eq!(
        len,
        cols * rows,
        "snapshot cells_len ({len}) must equal cols*rows ({cols}x{rows}); \
         the rig would otherwise read the wrong cells"
    );
    let mut cells = Vec::with_capacity(len);
    for i in 0..len {
        let c = *(*snap).cells.add(i);
        cells.push(Cell {
            ch: c.ch,
            fg: c.fg,
            bg: c.bg,
            flags: c.flags,
        });
    }
    let out = Shot {
        cols,
        rows,
        display_offset: (*snap).display_offset,
        history_size: (*snap).history_size,
        cells,
    };
    bb_snap_release(snap);
    out
}

/// Fresh `cols x rows` terminal with 100 lines of scrollback, fed `input`,
/// snapshotted, freed.
fn render(cols: u16, rows: u16, input: &[u8]) -> Shot {
    unsafe {
        let term = bb_term_new(cols, rows, 100);
        assert!(
            !term.is_null(),
            "bb_term_new({cols},{rows},100) returned null"
        );
        bb_term_input(term, input.as_ptr(), input.len());
        let s = shot(term);
        bb_term_free(term);
        s
    }
}

#[test]
fn sgr8_concealed_text_is_not_drawn_in_clear() {
    // The exact trigger from the bug report: SECRET at cols 0..=5, a plain
    // space at col 6, "ok" at cols 7..=8.
    let concealed = render(20, 3, b"\x1b[8mSECRET\x1b[0m ok");
    // Control: identical text and layout, no SGR 8. Must be legible, which
    // proves the oracle can tell clear text from concealed text on this
    // rig/theme.
    let control = render(20, 3, b"SECRET ok");

    assert_eq!(
        control.hidden(0, 0, "SECRET"),
        Vec::<String>::new(),
        "precondition: without SGR 8 every glyph of 'SECRET' must be drawn \
         in clear (original ch, fg != bg, no extra flag bit)"
    );
    assert_eq!(
        control.hidden(0, 7, "ok"),
        Vec::<String>::new(),
        "precondition: without SGR 8 the glyphs of 'ok' must be drawn in \
         clear (original ch, fg != bg, no extra flag bit)"
    );
    assert_eq!(
        concealed.hidden(0, 7, "ok"),
        Vec::<String>::new(),
        "text AFTER \\e[0m ('ok') must stay drawn in clear; a fix must not \
         hide more than the concealed run"
    );
    assert_eq!(
        concealed.leaked(0, 0, "SECRET"),
        Vec::<String>::new(),
        "SGR 8 text 'SECRET' is drawn in clear: each listed cell still holds \
         its original glyph with fg != bg and no conceal marker, so the \
         renderer paints the secret"
    );
}

#[test]
fn sgr8_conceal_wins_over_explicit_colours() {
    // Conceal must hide the glyph regardless of how fg/bg were chosen: here a
    // 256-colour red on a 256-colour navy ("ABC"), then truecolour yellow on
    // truecolour blue ("XYZ"). A "paint fg == bg" style fix must still make
    // the two equal after explicit colours are applied; a flag/ch fix is
    // colour independent.
    let concealed = render(
        20,
        3,
        b"\x1b[38;5;196;48;5;17;8mABC\x1b[0m \x1b[38;2;255;255;0;48;2;0;0;200;8mXYZ\x1b[0m",
    );
    let control = render(
        20,
        3,
        b"\x1b[38;5;196;48;5;17mABC\x1b[0m \x1b[38;2;255;255;0;48;2;0;0;200mXYZ\x1b[0m",
    );

    assert_eq!(
        control.hidden(0, 0, "ABC"),
        Vec::<String>::new(),
        "precondition: coloured 'ABC' without SGR 8 must be drawn in clear"
    );
    assert_eq!(
        control.hidden(0, 4, "XYZ"),
        Vec::<String>::new(),
        "precondition: truecolour 'XYZ' without SGR 8 must be drawn in clear"
    );
    assert_eq!(
        concealed.leaked(0, 0, "ABC"),
        Vec::<String>::new(),
        "256-colour text with SGR 8 is drawn in clear"
    );
    assert_eq!(
        concealed.leaked(0, 4, "XYZ"),
        Vec::<String>::new(),
        "truecolour text with SGR 8 is drawn in clear"
    );
}

#[test]
fn sgr28_reveals_text_written_after_conceal_is_cancelled() {
    // ECMA-48 / xterm: SGR 28 cancels conceal. "AB" is written concealed,
    // "CD" after \e[28m must be legible again, and the attribute must not be
    // stuck on for the rest of the line. A fix that hides everything after
    // the first SGR 8 (or that never hides anything) fails here.
    let mixed = render(20, 3, b"\x1b[8mAB\x1b[28mCD");

    assert_eq!(
        mixed.hidden(0, 2, "CD"),
        Vec::<String>::new(),
        "text written after SGR 28 ('CD') must be drawn in clear"
    );
    assert_eq!(
        mixed.leaked(0, 0, "AB"),
        Vec::<String>::new(),
        "text written between SGR 8 and SGR 28 ('AB') is drawn in clear"
    );
}

#[test]
fn sgr8_concealed_text_is_not_drawn_in_clear_in_scrollback() {
    // 10x3 grid. 'SECRET' lands on row 0, then 'a' and 'b' push it off the
    // top into history (the trailing \r\n on 'b' scrolls once). Scrolling the
    // viewport up one line must show [SECRET, a, b].
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert!(!term.is_null(), "bb_term_new(10,3,100) returned null");
        let input: &[u8] = b"\x1b[8mSECRET\x1b[0m\r\na\r\nb\r\n";
        bb_term_input(term, input.as_ptr(), input.len());
        bb_term_scroll(term, 1);
        let s = shot(term);
        bb_term_free(term);

        // Preconditions: the rig really is showing the scrolled-back line.
        // The anchors are the plain 'a' / 'b' cells, which do not depend on
        // how conceal is represented.
        assert_eq!(
            (s.history_size, s.display_offset),
            (1, 1),
            "precondition: one line in history and viewport scrolled up by \
             one (history_size, display_offset)"
        );
        assert_eq!(
            s.hidden(1, 0, "a"),
            Vec::<String>::new(),
            "precondition: viewport row 1 must be the plain 'a' line"
        );
        assert_eq!(
            s.hidden(2, 0, "b"),
            Vec::<String>::new(),
            "precondition: viewport row 2 must be the plain 'b' line"
        );

        assert_eq!(
            s.leaked(0, 0, "SECRET"),
            Vec::<String>::new(),
            "concealed 'SECRET' scrolled into history (viewport row 0) is \
             drawn in clear"
        );
    }
}
