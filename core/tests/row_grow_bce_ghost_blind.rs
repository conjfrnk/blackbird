//! Blind regression tests for "widening a terminal after a background-colour
//! fill leaves ghost coloured cells that survive RIS, ED and row recycling".
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and
//! documented xterm behaviour only, never the implementation.
//!
//! Contract under test (xterm ctlseqs):
//!   * RIS (`ESC c`) resets the terminal to its power-on state: every
//!     visible cell is blank with the DEFAULT background, and the terminal
//!     is indistinguishable from a freshly created one of the same size.
//!   * ED (`CSI Ps J`) and scrolling use BCE ("background colour erase"):
//!     erased / newly exposed cells take the CURRENT SGR background. With
//!     SGR 0 active that background is the default one, so after
//!     `ESC[0m ESC[J` or `ESC[0m ESC[2J` no cell of the cleared region may
//!     still carry an earlier SGR 44 (blue) background.
//!   * `CSI ? 1049 h` switches to a CLEARED alternate screen.
//!   * Widening the window must not change any of the above: the old
//!     columns keep their old content, the new columns are blank, and
//!     later clears / scrolls with the default background must produce
//!     blank default-background cells in ALL columns, old and new.
//!
//! The bug being pinned: after a BCE fill (`ESC[44m ESC[2J`) the old
//! columns hold blue cells; widening appends default cells at the right.
//! A later clear with the default background (RIS, ED, or the reset of a
//! recycled scrollback row) then wrongly leaves the old blue columns in
//! place: every row reads `blue x10 + default x10` instead of all default.
//!
//! Oracle strategy: every "must be blank" claim is checked against a FRESH
//! terminal of the final size that received the same trailing input, so the
//! test does not hard-code the default colours or the blank-cell encoding.
//! Each failing assertion prints the measured grid as a picture
//! (`B` = blue bg, `.` = default bg, `?` = anything else), one line per row.
//!
//! Rig preconditions (asserted, so a green run cannot mean "nothing was
//! ever coloured"):
//!   1. SGR 44 yields a background different from the default background.
//!   2. After the BCE fill every visible cell of the original grid reads
//!      back with the blue background (the fill really happened).
//!   3. After the widen, resize2 reports exactly the requested size, the
//!      old columns still read blue (content survives a widen).
//!
//! Pre-flight cost: the biggest grid is 20x4 (80 cells x 20 B) + <=100
//! scrollback lines; each test creates at most three terminals and frees
//! them immediately. No sleeps, no threads, no I/O.

use blackbird_core as bc;

const OLD_COLS: u16 = 10;
const NEW_COLS: u16 = 20;
const ROWS: u16 = 4;
const SCROLLBACK: u32 = 100;

/// One snapshot cell, every field the FFI exposes, so "looks blank but is
/// not" differences (bg, fg, flags, link, underline colour) all count.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Px {
    ch: u32,
    fg: u32,
    bg: u32,
    flags: u16,
    link_id: u16,
    underline_color: u32,
}

struct Shot {
    cols: u16,
    rows: u16,
    history: u32,
    cells: Vec<Px>,
}

impl Shot {
    fn at(&self, row: u16, col: u16) -> Px {
        self.cells[(row as usize) * (self.cols as usize) + col as usize]
    }
}

/// RAII terminal so a failed assertion still frees the handle.
struct Rig {
    term: *mut bc::BBTerm,
}

impl Rig {
    fn new(cols: u16, rows: u16, scrollback: u32) -> Rig {
        let term = unsafe { bc::bb_term_new(cols, rows, scrollback) };
        assert!(
            !term.is_null(),
            "bb_term_new({cols},{rows},{scrollback}) returned null"
        );
        Rig { term }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    fn feed_repeated(&self, unit: &[u8], times: usize) {
        for _ in 0..times {
            self.feed(unit);
        }
    }

    fn resize(&self, cols: u16, rows: u16) {
        let r = unsafe { bc::bb_term_resize2(self.term, cols, rows) };
        assert_eq!(
            (r.applied_cols, r.applied_rows, r.clamped),
            (cols, rows, 0),
            "bb_term_resize2({cols},{rows}) must apply the request verbatim"
        );
    }

    fn shot(&self) -> Shot {
        unsafe {
            let snap = bc::bb_term_take_snapshot(self.term);
            assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
            let cols = (*snap).cols;
            let rows = (*snap).rows;
            let n = (*snap).cells_len;
            assert_eq!(
                n,
                (cols as usize) * (rows as usize),
                "snapshot cells_len must equal cols*rows"
            );
            let raw: &[bc::BBCell] = std::slice::from_raw_parts((*snap).cells, n);
            let cells: Vec<Px> = raw
                .iter()
                .map(|c: &bc::BBCell| Px {
                    ch: c.ch,
                    fg: c.fg,
                    bg: c.bg,
                    flags: c.flags,
                    link_id: c.link_id,
                    underline_color: c.underline_color,
                })
                .collect();
            let shot = Shot {
                cols,
                rows,
                history: (*snap).history_size,
                cells,
            };
            bc::bb_snap_release(snap);
            shot
        }
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        unsafe { bc::bb_term_free(self.term) };
    }
}

/// Default-background colour as the snapshot reports it, measured from a
/// fresh terminal rather than hard-coded.
fn default_bg() -> u32 {
    let fresh = Rig::new(OLD_COLS, ROWS, SCROLLBACK);
    fresh.shot().at(0, 0).bg
}

/// The background SGR 44 produces, measured from a one-cell paint.
fn blue_bg() -> u32 {
    let t = Rig::new(OLD_COLS, ROWS, SCROLLBACK);
    t.feed(b"\x1b[44m \x1b[0m");
    t.shot().at(0, 0).bg
}

/// Picture of the background layer: `B` blue, `.` default, `?` other.
fn picture(shot: &Shot, blue: u32, default: u32) -> String {
    let mut out = String::new();
    for r in 0..shot.rows {
        out.push_str(&format!("  row {r}: "));
        for c in 0..shot.cols {
            let bg = shot.at(r, c).bg;
            out.push(if bg == blue {
                'B'
            } else if bg == default {
                '.'
            } else {
                '?'
            });
        }
        out.push('\n');
    }
    out
}

/// Number of cells (and the first few coordinates) where `actual` differs
/// from the `expected` oracle in any field.
fn diff(actual: &Shot, expected: &Shot) -> (usize, Vec<String>) {
    assert_eq!(
        (actual.cols, actual.rows),
        (expected.cols, expected.rows),
        "oracle and actual snapshots must have the same dimensions"
    );
    let mut n = 0usize;
    let mut first: Vec<String> = Vec::new();
    for r in 0..actual.rows {
        for c in 0..actual.cols {
            let a = actual.at(r, c);
            let e = expected.at(r, c);
            if a != e {
                n += 1;
                if first.len() < 6 {
                    first.push(format!("({r},{c}) got {a:?} want {e:?}"));
                }
            }
        }
    }
    (n, first)
}

/// Assert `actual` is cell-for-cell identical to the fresh-terminal oracle.
fn assert_matches_fresh(label: &str, actual: &Shot, fresh: &Shot, blue: u32, default: u32) {
    let (n, first) = diff(actual, fresh);
    assert_eq!(
        n,
        0,
        "{label}: {n} of {} cells differ from a fresh {}x{} terminal.\n\
         measured background layer (B=blue .=default ?=other):\n{}\
         first mismatches: {first:#?}",
        actual.cols as usize * actual.rows as usize,
        actual.cols,
        actual.rows,
        picture(actual, blue, default),
    );
}

/// Shared rig preconditions. Fills the OLD_COLS x ROWS primary grid with a
/// blue BCE fill, widens to NEW_COLS, and proves the fill is visible
/// before and after the widen. Returns (rig, blue, default).
fn filled_then_widened() -> (Rig, u32, u32) {
    let default = default_bg();
    let blue = blue_bg();
    assert_ne!(
        blue, default,
        "precondition: SGR 44 bg 0x{blue:06x} must differ from default bg 0x{default:06x}"
    );

    let t = Rig::new(OLD_COLS, ROWS, SCROLLBACK);
    t.feed(b"\x1b[44m\x1b[2J\x1b[0m");

    let before = t.shot();
    let blue_before = before.cells.iter().filter(|p| p.bg == blue).count();
    assert_eq!(
        blue_before,
        OLD_COLS as usize * ROWS as usize,
        "precondition: after ESC[44m ESC[2J every cell of the {OLD_COLS}x{ROWS} grid must be blue.\n{}",
        picture(&before, blue, default)
    );

    t.resize(NEW_COLS, ROWS);
    let after = t.shot();
    assert_eq!((after.cols, after.rows), (NEW_COLS, ROWS));
    for r in 0..ROWS {
        for c in 0..OLD_COLS {
            assert_eq!(
                after.at(r, c).bg,
                blue,
                "precondition: old column ({r},{c}) must still be blue right after the widen.\n{}",
                picture(&after, blue, default)
            );
        }
    }
    (t, blue, default)
}

fn fresh_after(cols: u16, rows: u16, input: &[u8]) -> Shot {
    let f = Rig::new(cols, rows, SCROLLBACK);
    f.feed(input);
    f.shot()
}

// ---------- 1. the exact trigger: RIS after fill + widen -----------------

#[test]
fn ris_after_bce_fill_and_widen_leaves_no_blue_cells() {
    let (t, blue, default) = filled_then_widened();
    t.feed(b"\x1bc");
    let got = t.shot();
    let fresh = fresh_after(NEW_COLS, ROWS, b"");
    assert_matches_fresh("RIS after BCE fill + widen", &got, &fresh, blue, default);
}

// ---------- 2. ED 0 from home with the default background ----------------

#[test]
fn ed0_from_home_after_bce_fill_and_widen_clears_every_row() {
    let (t, blue, default) = filled_then_widened();
    t.feed(b"\x1b[H\x1b[J");
    let got = t.shot();
    let fresh = fresh_after(NEW_COLS, ROWS, b"\x1b[H\x1b[J");
    assert_matches_fresh(
        "ESC[H ESC[J (SGR 0) after BCE fill + widen",
        &got,
        &fresh,
        blue,
        default,
    );
}

// ---------- 3. ED 2 on the primary screen (guard) -------------------------
//
// Passes before the fix as well: on the primary screen ESC[2J first scrolls
// the old rows into history and only then blanks the viewport, which does
// not go through the stale-row reset. Kept as a guard so a fix that
// over-corrects (or changes ED 2 semantics) is caught.

#[test]
fn guard_ed2_after_bce_fill_and_widen_leaves_a_blank_viewport() {
    let (t, blue, default) = filled_then_widened();
    t.feed(b"\x1b[2J");
    let got = t.shot();
    let fresh = fresh_after(NEW_COLS, ROWS, b"\x1b[2J");
    assert_matches_fresh(
        "ESC[2J (SGR 0) after BCE fill + widen",
        &got,
        &fresh,
        blue,
        default,
    );
}

// ---------- 4. RIS then ED 2 must not push blank rows into history -------

#[test]
fn ris_then_ed2_after_bce_fill_and_widen_matches_a_fresh_terminal() {
    let (t, blue, default) = filled_then_widened();
    t.feed(b"\x1bc\x1b[2J");
    let got = t.shot();
    let fresh = fresh_after(NEW_COLS, ROWS, b"\x1bc\x1b[2J");
    assert_eq!(
        got.history, fresh.history,
        "after RIS + ESC[2J on a terminal that only held blank rows, scrollback history \
         must match a fresh terminal's ({}), measured {}; ghost-coloured 'blank' rows \
         were pushed into history",
        fresh.history, got.history
    );
    assert_matches_fresh(
        "RIS + ESC[2J after BCE fill + widen",
        &got,
        &fresh,
        blue,
        default,
    );
}

// ---------- 5. alternate screen: fill, exit, widen, re-enter -------------

/// An alt-screen app paints a BCE fill and exits; the window is widened.
/// Returns the rig sitting on the PRIMARY screen with the alt grid parked.
fn alt_filled_exited_widened() -> (Rig, u32, u32) {
    let default = default_bg();
    let blue = blue_bg();
    assert_ne!(
        blue, default,
        "precondition: blue bg must differ from default"
    );

    let t = Rig::new(OLD_COLS, ROWS, SCROLLBACK);
    t.feed(b"\x1b[?1049h\x1b[44m\x1b[2J\x1b[0m");
    let on_alt = t.shot();
    let blue_cells = on_alt.cells.iter().filter(|p| p.bg == blue).count();
    assert_eq!(
        blue_cells,
        OLD_COLS as usize * ROWS as usize,
        "precondition: the alt-screen BCE fill must colour every cell blue.\n{}",
        picture(&on_alt, blue, default)
    );
    t.feed(b"\x1b[?1049l");
    t.resize(NEW_COLS, ROWS);
    (t, blue, default)
}

#[test]
fn alt_screen_entry_after_bce_fill_exit_and_widen_is_blank() {
    let (t, blue, default) = alt_filled_exited_widened();
    t.feed(b"\x1b[?1049h");
    let got = t.shot();
    let fresh = fresh_after(NEW_COLS, ROWS, b"\x1b[?1049h");
    assert_matches_fresh(
        "ESC[?1049h (cleared alt screen) after BCE fill + exit + widen",
        &got,
        &fresh,
        blue,
        default,
    );
}

#[test]
fn alt_screen_ed2_after_bce_fill_exit_and_widen_clears_every_cell() {
    let (t, blue, default) = alt_filled_exited_widened();
    t.feed(b"\x1b[?1049h\x1b[0m\x1b[2J");
    let got = t.shot();
    let fresh = fresh_after(NEW_COLS, ROWS, b"\x1b[?1049h\x1b[0m\x1b[2J");
    assert_matches_fresh(
        "default-bg alt-screen app's ESC[2J after BCE fill + exit + widen",
        &got,
        &fresh,
        blue,
        default,
    );
}

// ---------- 6. row recycling: scrolling in a full scrollback -------------

#[test]
fn scrolling_in_a_full_scrollback_after_bce_fill_and_widen_exposes_blank_rows() {
    // Tiny scrollback so the ring saturates quickly: 4 visible + 3 history
    // rows. 30 line feeds with the cursor on the bottom row recycle every
    // ring row several times.
    const SB: u32 = 3;
    const LFS: usize = 30;

    let default = default_bg();
    let blue = blue_bg();
    assert_ne!(
        blue, default,
        "precondition: blue bg must differ from default"
    );

    let t = Rig::new(OLD_COLS, ROWS, SB);
    // BCE on scroll: with SGR 44 active, every newly exposed bottom row is
    // blue. After 30 LFs the whole visible grid (and the whole history
    // ring) is blue.
    t.feed(b"\x1b[44m");
    t.feed_repeated(b"\n", LFS);
    let before = t.shot();
    let blue_cells = before.cells.iter().filter(|p| p.bg == blue).count();
    assert_eq!(
        blue_cells,
        OLD_COLS as usize * ROWS as usize,
        "precondition: scrolling with SGR 44 active must expose blue rows (BCE).\n{}",
        picture(&before, blue, default)
    );
    assert_eq!(
        before.history, SB,
        "precondition: the scrollback ring must be full ({SB} lines), measured {}",
        before.history
    );

    t.resize(NEW_COLS, ROWS);
    let widened = t.shot();
    for r in 0..ROWS {
        for c in 0..OLD_COLS {
            assert_eq!(
                widened.at(r, c).bg,
                blue,
                "precondition: old column ({r},{c}) must still be blue after the widen.\n{}",
                picture(&widened, blue, default)
            );
        }
    }

    // Back to the default background and scroll the whole ring again: every
    // newly exposed row must be blank with the default background.
    t.feed(b"\x1b[0m");
    t.feed_repeated(b"\n", LFS);
    let got = t.shot();

    let fresh = Rig::new(NEW_COLS, ROWS, SB);
    fresh.feed_repeated(b"\n", LFS);
    let expected = fresh.shot();

    assert_matches_fresh(
        "rows recycled with SGR 0 after BCE fill + widen",
        &got,
        &expected,
        blue,
        default,
    );
}

// ---------- 7. controls: same fill, no widen => everything is fine -------

#[test]
fn control_ris_after_bce_fill_without_widen_is_clean() {
    let default = default_bg();
    let blue = blue_bg();
    assert_ne!(
        blue, default,
        "precondition: blue bg must differ from default"
    );

    let t = Rig::new(OLD_COLS, ROWS, SCROLLBACK);
    t.feed(b"\x1b[44m\x1b[2J\x1b[0m");
    let filled = t.shot();
    assert_eq!(
        filled.cells.iter().filter(|p| p.bg == blue).count(),
        OLD_COLS as usize * ROWS as usize,
        "precondition: control fill must be fully blue.\n{}",
        picture(&filled, blue, default)
    );
    t.feed(b"\x1bc");
    let got = t.shot();
    let fresh = fresh_after(OLD_COLS, ROWS, b"");
    assert_matches_fresh(
        "control: RIS after BCE fill, no widen",
        &got,
        &fresh,
        blue,
        default,
    );
}

#[test]
fn control_widen_without_bce_fill_then_ris_is_clean() {
    let default = default_bg();
    let blue = blue_bg();
    assert_ne!(
        blue, default,
        "precondition: blue bg must differ from default"
    );

    let t = Rig::new(OLD_COLS, ROWS, SCROLLBACK);
    t.feed(b"\x1b[2J");
    t.resize(NEW_COLS, ROWS);
    t.feed(b"\x1bc");
    let got = t.shot();
    let fresh = fresh_after(NEW_COLS, ROWS, b"");
    assert_matches_fresh(
        "control: widen + RIS with no colour fill",
        &got,
        &fresh,
        blue,
        default,
    );
}
