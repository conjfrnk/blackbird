//! Blind regression tests for "bundled terminfo `acsc` advertises the ACS
//! arrows and solid block, but the core leaves them as ASCII under
//! `ESC ( 0`".
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`), the
//! bundled terminfo source, and the documented VT100/terminfo conventions only,
//! never the implementation.
//!
//! Contract under test (VT100 "special character and line drawing" set, which
//! `ESC ( 0` designates into G0 and `ESC ) 0` into G1; `smacs=\E(0` /
//! `rmacs`=`\E(B` in the bundled terminfo):
//!
//!   - The bundled `kitty.terminfo` (`TERM=xterm-kitty`, what Blackbird
//!     advertises) carries
//!     `acsc=++\,\,--..00``aaffgg...`. Each two-character pair is
//!     `<ACS name's ncurses key><VT100 char the terminal draws it with>`:
//!       `+` ACS_RARROW, `,` ACS_LARROW, `-` ACS_UARROW, `.` ACS_DARROW,
//!       `0` ACS_BLOCK.
//!     So a terminal that ships this entry promises that, with the
//!     line-drawing set active, the bytes `+ , - . 0` are drawn as a right
//!     arrow, left arrow, up arrow, down arrow and a solid block.
//!   - Standard terminal behaviour (xterm, the Linux console, kitty, ncurses'
//!     own wide-char ACS table): `+` -> U+2192 RIGHTWARDS ARROW,
//!     `,` -> U+2190 LEFTWARDS ARROW, `-` -> U+2191 UPWARDS ARROW,
//!     `.` -> U+2193 DOWNWARDS ARROW, `0` -> a solid block (the bug report
//!     names U+2588 FULL BLOCK; xterm/ncurses use U+25AE BLACK VERTICAL
//!     RECTANGLE and some tables U+25A0 BLACK SQUARE, so any of those three
//!     "solid block" scalars is accepted).
//!   - Every one of those glyphs occupies exactly ONE cell (the arrows are
//!     East-Asian-Ambiguous, which a Western-locale terminal renders narrow):
//!     no wide flag, cursor advances by one per byte.
//!   - Minimal raw form from the bug report:
//!     `printf '\e(0+,-.0\e(B'` must show `→←↑↓█`, not `+,-.0`.
//!   - Outside the line-drawing set (`ESC ( B`, or before any designation) the
//!     very same bytes are plain ASCII `+ , - . 0`. The fix must not leak the
//!     mapping into the ASCII set.
//!
//! How the bug is observed: a snapshot of the grid (`bb_term_take_snapshot`)
//! gives per-cell `ch`/`flags`; `bb_term_text_range` gives the copy-path text.
//! Unfixed, the five cells hold the ASCII scalars `+ , - . 0` unchanged.
//!
//! Rig preconditions are asserted in every test (see
//! `assert_rig_preconditions`) so a vacuous pass is impossible: the line
//! drawing designation itself demonstrably works for box-drawing letters, and
//! the snapshot reader sees both ASCII and non-ASCII scalars.
//!
//! Pre-flight cost: 16x3 grid, scrollback 16 -> a few KB per terminal. Inputs
//! are < 40 bytes. The terminfo is read once per test that needs it (~10 KB).
//! No sleeps, no threads, no network.

use std::fs;
use std::path::PathBuf;

use blackbird_core as bc;

const COLS: u16 = 16;
const ROWS: u16 = 3;
const SCROLLBACK: u32 = 16;

/// The five scalars a solid ACS_BLOCK may legitimately be drawn with.
const SOLID_BLOCKS: [char; 3] = ['\u{2588}', '\u{25AE}', '\u{25A0}'];

/// `(vt100 byte, ncurses name, expected glyph)` for the four arrows.
const ARROWS: [(char, &str, char); 4] = [
    ('+', "ACS_RARROW", '\u{2192}'),
    (',', "ACS_LARROW", '\u{2190}'),
    ('-', "ACS_UARROW", '\u{2191}'),
    ('.', "ACS_DARROW", '\u{2193}'),
];

const WIDE_FLAGS: u16 = bc::cell_flags::WIDE_CHAR
    | bc::cell_flags::WIDE_CHAR_SPACER
    | bc::cell_flags::LEADING_WIDE_CHAR_SPACER;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

fn new_term() -> *mut bc::BBTerm {
    let t = unsafe { bc::bb_term_new(COLS, ROWS, SCROLLBACK) };
    assert!(!t.is_null(), "bb_term_new({COLS}, {ROWS}) returned null");
    t
}

fn feed(term: *mut bc::BBTerm, bytes: &[u8]) {
    unsafe { bc::bb_term_input(term, bytes.as_ptr(), bytes.len()) };
}

/// Owned copy of one snapshot, so no raw pointer outlives its release.
struct Grid {
    cols: u16,
    rows: u16,
    cells: Vec<bc::BBCell>,
    cursor_col: u16,
    cursor_row: u16,
}

impl Grid {
    fn take(term: *mut bc::BBTerm) -> Grid {
        unsafe {
            let snap = bc::bb_term_take_snapshot(term);
            assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
            let cols = (*snap).cols;
            let rows = (*snap).rows;
            let n = (cols as usize) * (rows as usize);
            assert_eq!(
                (*snap).cells_len,
                n,
                "snapshot cells_len must be cols*rows ({cols}x{rows})"
            );
            let cells = std::slice::from_raw_parts((*snap).cells, n).to_vec();
            let g = Grid {
                cols,
                rows,
                cells,
                cursor_col: (*snap).cursor_col,
                cursor_row: (*snap).cursor_row,
            };
            bc::bb_snap_release(snap);
            g
        }
    }

    fn cell(&self, row: u16, col: u16) -> bc::BBCell {
        assert!(row < self.rows && col < self.cols);
        self.cells[(row as usize) * (self.cols as usize) + col as usize]
    }

    fn glyph(&self, row: u16, col: u16) -> char {
        let c = self.cell(row, col);
        if c.ch == 0 {
            ' '
        } else {
            char::from_u32(c.ch).unwrap_or('\u{FFFD}')
        }
    }

    /// The first `n` cells of `row` as a string (`ch == 0` shown as a space).
    fn prefix(&self, row: u16, n: u16) -> String {
        (0..n).map(|c| self.glyph(row, c)).collect()
    }

    /// Whole row, trailing blanks trimmed, for failure messages.
    fn row_trimmed(&self, row: u16) -> String {
        self.prefix(row, self.cols).trim_end().to_string()
    }

    fn any_wide_flag_in(&self, row: u16, n: u16) -> Vec<(u16, u16)> {
        (0..n)
            .filter_map(|c| {
                let f = self.cell(row, c).flags;
                (f & WIDE_FLAGS != 0).then_some((c, f))
            })
            .collect()
    }
}

/// Render a glyph string as `"→←" [U+2192 U+2190]` so a failure message shows
/// both the visible text and the exact scalars measured.
fn describe(s: &str) -> String {
    let scalars: Vec<String> = s.chars().map(|c| format!("U+{:04X}", c as u32)).collect();
    format!("{s:?} [{}]", scalars.join(" "))
}

/// Run `bytes` through a fresh terminal and return the resulting grid.
fn run(bytes: &[u8]) -> Grid {
    let term = new_term();
    feed(term, bytes);
    let g = Grid::take(term);
    unsafe { bc::bb_term_free(term) };
    g
}

/// Copy-path text of row 0 (prose mode), trailing blanks trimmed.
fn copy_text_row0(term: *mut bc::BBTerm) -> String {
    unsafe {
        let raw = bc::bb_term_text_range(term, 0, 0, 0, COLS - 1, 0);
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
        s.trim_end().to_string()
    }
}

/// Rig preconditions. Without these a green or red run could mean "the
/// designation sequence is ignored entirely" or "the snapshot reader cannot
/// see non-ASCII scalars" instead of the bug under test.
///
///   1. Plain ASCII `+,-.0` with no designation lands untouched at columns
///      0..5 (the reference "wrong" rendering the bug leaves behind).
///   2. `ESC ( 0` demonstrably switches to the line-drawing set: the
///      long-standing box letters `q x l k m j` become `─ │ ┌ ┐ └ ┘`, and
///      `ESC ( B` switches back so `q` is a plain `q` again.
fn assert_rig_preconditions() {
    let plain = run(b"+,-.0");
    assert_eq!(
        plain.prefix(0, 5),
        "+,-.0",
        "rig precondition: undesignated G0 is ASCII, measured {}",
        describe(&plain.prefix(0, 5))
    );
    assert_eq!(
        plain.cursor_col, 5,
        "rig precondition: 5 printable bytes advance the cursor to col 5"
    );

    let box_row = run(b"\x1b(0qxlkmj\x1b(Bq");
    assert_eq!(
        box_row.prefix(0, 7),
        "\u{2500}\u{2502}\u{250C}\u{2510}\u{2514}\u{2518}q",
        "rig precondition: ESC ( 0 maps box letters and ESC ( B restores \
         ASCII, measured {}",
        describe(&box_row.prefix(0, 7))
    );
}

/// One key under `ESC ( 0` in a fresh terminal; returns the glyph it drew at
/// column 0 plus the whole grid for diagnostics.
fn acs_glyph_of(key: char) -> (char, Grid) {
    let mut bytes: Vec<u8> = Vec::new();
    bytes.extend_from_slice(b"\x1b(0");
    let mut buf = [0u8; 4];
    bytes.extend_from_slice(key.encode_utf8(&mut buf).as_bytes());
    bytes.extend_from_slice(b"\x1b(B");
    let g = run(&bytes);
    (g.glyph(0, 0), g)
}

fn assert_arrow(key: char, name: &str, want: char) {
    assert_rig_preconditions();
    let (got, g) = acs_glyph_of(key);
    assert_eq!(
        got,
        want,
        "{name}: ESC ( 0 then {key:?} must draw {want:?} (U+{:04X}) but drew \
         {got:?} (U+{:04X}); row 0 = {}",
        want as u32,
        got as u32,
        describe(&g.row_trimmed(0))
    );
    assert_eq!(
        g.cursor_col, 1,
        "{name}: one byte must advance the cursor by exactly one cell"
    );
    assert!(
        g.any_wide_flag_in(0, 2).is_empty(),
        "{name}: glyph {want:?} must be a single-width cell, wide flags \
         (col, flags) = {:?}",
        g.any_wide_flag_in(0, 2)
    );
}

// ---------------------------------------------------------------------------
// Individual keys
// ---------------------------------------------------------------------------

#[test]
fn acs_rarrow_plus_draws_right_arrow() {
    assert_arrow(ARROWS[0].0, ARROWS[0].1, ARROWS[0].2);
}

#[test]
fn acs_larrow_comma_draws_left_arrow() {
    assert_arrow(ARROWS[1].0, ARROWS[1].1, ARROWS[1].2);
}

#[test]
fn acs_uarrow_minus_draws_up_arrow() {
    assert_arrow(ARROWS[2].0, ARROWS[2].1, ARROWS[2].2);
}

#[test]
fn acs_darrow_period_draws_down_arrow() {
    assert_arrow(ARROWS[3].0, ARROWS[3].1, ARROWS[3].2);
}

#[test]
fn acs_block_zero_draws_a_solid_block() {
    assert_rig_preconditions();
    let (got, g) = acs_glyph_of('0');
    assert!(
        SOLID_BLOCKS.contains(&got),
        "ACS_BLOCK: ESC ( 0 then '0' must draw a solid block (one of {:?}) \
         but drew {got:?} (U+{:04X}); row 0 = {}",
        SOLID_BLOCKS
            .iter()
            .map(|c| format!("U+{:04X}", *c as u32))
            .collect::<Vec<_>>(),
        got as u32,
        describe(&g.row_trimmed(0))
    );
    assert_eq!(
        g.cursor_col, 1,
        "ACS_BLOCK: one byte must advance the cursor by exactly one cell"
    );
    assert!(
        g.any_wide_flag_in(0, 2).is_empty(),
        "ACS_BLOCK: block glyph must be a single-width cell, wide flags \
         (col, flags) = {:?}",
        g.any_wide_flag_in(0, 2)
    );
}

// ---------------------------------------------------------------------------
// The minimal raw form from the bug report
// ---------------------------------------------------------------------------

#[test]
fn raw_form_esc_paren_0_plus_comma_minus_period_zero_shows_arrows_and_block() {
    assert_rig_preconditions();
    // printf '\e(0+,-.0\e(B'
    let term = new_term();
    feed(term, b"\x1b(0+,-.0\x1b(B");
    let g = Grid::take(term);
    let copied = copy_text_row0(term);
    unsafe { bc::bb_term_free(term) };

    let shown = g.prefix(0, 5);
    let arrows: String = shown.chars().take(4).collect();
    let block = shown.chars().nth(4).unwrap_or(' ');

    assert_eq!(
        arrows,
        "\u{2192}\u{2190}\u{2191}\u{2193}",
        "printf '\\e(0+,-.0\\e(B' must start with the four arrows -> <- ^ v \
         but showed {} (full row {})",
        describe(&shown),
        describe(&g.row_trimmed(0))
    );
    assert!(
        SOLID_BLOCKS.contains(&block),
        "fifth glyph of printf '\\e(0+,-.0\\e(B' must be a solid block \
         (U+2588/U+25AE/U+25A0) but was {block:?} (U+{:04X}); showed {}",
        block as u32,
        describe(&shown)
    );
    assert_eq!(
        g.glyph(0, 5),
        ' ',
        "nothing may be drawn after the five ACS cells, row = {}",
        describe(&g.row_trimmed(0))
    );
    assert_eq!(
        (g.cursor_row, g.cursor_col),
        (0, 5),
        "five ACS bytes advance the cursor to (row 0, col 5)"
    );
    assert!(
        g.any_wide_flag_in(0, 6).is_empty(),
        "all five ACS glyphs are single-width, wide flags (col, flags) = {:?}",
        g.any_wide_flag_in(0, 6)
    );
    assert_eq!(
        copied.chars().take(4).collect::<String>(),
        "\u{2192}\u{2190}\u{2191}\u{2193}",
        "the copy path (bb_term_text_range) must hand the user the arrows, \
         not '+,-.', copied text = {}",
        describe(&copied)
    );
}

// ---------------------------------------------------------------------------
// Same mapping through the G1 / Shift Out route and the ASCII boundaries
// ---------------------------------------------------------------------------

#[test]
fn g1_line_drawing_via_shift_out_also_maps_arrows_and_block() {
    assert_rig_preconditions();
    // ESC ) 0 designates line drawing into G1; SO (0x0E) shifts G1 in, SI
    // (0x0F) shifts G0 (ASCII) back. The trailing "+,-.0" after SI is plain.
    let g = run(b"\x1b)0\x0e+,-.0\x0f+,-.0");
    let line = g.prefix(0, 10);
    let drawn: String = line.chars().take(5).collect();
    let plain: String = line.chars().skip(5).collect();

    let drawn_arrows: String = drawn.chars().take(4).collect();
    let drawn_block = drawn.chars().nth(4).unwrap_or(' ');
    assert_eq!(
        drawn_arrows,
        "\u{2192}\u{2190}\u{2191}\u{2193}",
        "ESC ) 0, SO, then '+,-.' must draw the four arrows; row 0 = {}",
        describe(&line)
    );
    assert!(
        SOLID_BLOCKS.contains(&drawn_block),
        "ESC ) 0, SO, then '0' must draw a solid block, got {drawn_block:?} \
         (U+{:04X}); row 0 = {}",
        drawn_block as u32,
        describe(&line)
    );
    assert_eq!(
        plain,
        "+,-.0",
        "after SI the same bytes are plain ASCII again; row 0 = {}",
        describe(&line)
    );
}

#[test]
fn esc_paren_b_restores_ascii_for_arrow_and_block_keys() {
    assert_rig_preconditions();
    // Each key drawn once under ESC ( 0 and once after ESC ( B: the pair must
    // differ (mapping applied, then fully withdrawn) and the second must be
    // the literal ASCII byte.
    let g = run(b"\x1b(0+,-.0\x1b(B+,-.0");
    let line = g.prefix(0, 10);
    let second_half: String = line.chars().skip(5).collect();
    let first_half: String = line.chars().take(5).collect();
    assert_eq!(
        second_half,
        "+,-.0",
        "after ESC ( B the bytes + , - . 0 must be literal ASCII; row 0 = {}",
        describe(&line)
    );
    assert_ne!(
        first_half,
        second_half,
        "ACS_* keys must draw differently under ESC ( 0 than under ESC ( B; \
         both halves measured {}",
        describe(&line)
    );
}

// ---------------------------------------------------------------------------
// Terminfo parity: what the bundled terminfo promises, the core delivers
// ---------------------------------------------------------------------------

fn terminfo_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("CARGO_MANIFEST_DIR (core/) must have a parent (workspace root)")
        .join("Sources/Blackbird/Resources/Terminfo/kitty.terminfo")
}

/// Decode a terminfo-source value for the characters `acsc` can contain:
/// `\,` `\:` `\\` `\^` and `\s` escapes; everything else is literal. Panics
/// on an escape this tiny decoder does not understand rather than guessing.
fn decode_acsc_source(s: &str) -> Vec<char> {
    let mut out = Vec::new();
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some(',') => out.push(','),
            Some(':') => out.push(':'),
            Some('\\') => out.push('\\'),
            Some('^') => out.push('^'),
            Some('s') => out.push(' '),
            other => panic!("acsc decoder: unsupported escape \\{other:?} in {s:?}"),
        }
    }
    out
}

/// `acsc` of the bundled terminfo as `(ncurses key, vt100 char)` pairs.
fn bundled_acsc_pairs() -> Vec<(char, char)> {
    let path = terminfo_path();
    let src = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read bundled terminfo {}: {e}", path.display()));
    let value = src
        .lines()
        .map(str::trim)
        .find_map(|l| l.strip_prefix("acsc="))
        .unwrap_or_else(|| panic!("no `acsc=` capability in {}", path.display()));
    // A capability line ends with an unescaped trailing comma.
    let value = value
        .strip_suffix(',')
        .unwrap_or_else(|| panic!("acsc line does not end with ',': {value:?}"));
    let chars = decode_acsc_source(value);
    assert_eq!(
        chars.len() % 2,
        0,
        "acsc must be an even number of characters (key/char pairs), decoded \
         {} chars from {value:?}",
        chars.len()
    );
    chars.chunks(2).map(|p| (p[0], p[1])).collect()
}

#[test]
fn every_arrow_and_block_pair_in_bundled_acsc_is_drawn_non_ascii_by_the_core() {
    assert_rig_preconditions();
    let pairs = bundled_acsc_pairs();

    // Harness self-check: the parser really found the advertised table
    // (line-drawing staples included), and the five keys under test are in it
    // as identity pairs ("<key><same VT100 char>"), which is why the contract
    // applies to them at all.
    for staple in ['q', 'x', 'l', 'k', 'm', 'j'] {
        assert!(
            pairs.contains(&(staple, staple)),
            "acsc parser self-check: ({staple:?},{staple:?}) missing from \
             parsed pairs {pairs:?}"
        );
    }
    let advertised: Vec<char> = ['+', ',', '-', '.', '0']
        .into_iter()
        .filter(|k| pairs.contains(&(*k, *k)))
        .collect();
    assert_eq!(
        advertised,
        vec!['+', ',', '-', '.', '0'],
        "the bundled kitty.terminfo acsc must advertise ACS_RARROW(+), \
         ACS_LARROW(,), ACS_UARROW(-), ACS_DARROW(.), ACS_BLOCK(0); parsed \
         pairs = {pairs:?}"
    );

    // The promise: every one of those keys, with the line-drawing set active,
    // is a non-ASCII glyph (an ASCII result means ncurses' ACS_* would print
    // the VT100 byte itself, e.g. a literal '+' where a right arrow belongs).
    let mut still_ascii: Vec<String> = Vec::new();
    for key in &advertised {
        let (got, _) = acs_glyph_of(*key);
        if (got as u32) < 0x80 {
            still_ascii.push(format!("{key:?} -> {got:?} (U+{:04X})", got as u32));
        }
    }
    assert!(
        still_ascii.is_empty(),
        "bundled terminfo advertises these acsc keys but the core draws them \
         as ASCII under ESC ( 0: {still_ascii:?}"
    );
}
