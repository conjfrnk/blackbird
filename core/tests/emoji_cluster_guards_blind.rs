//! Blind regression tests for the guards of the emoji-cluster width rule
//! (ZWJ sequences and skin-tone modifiers advance the cursor by the width of
//! the WHOLE cluster, as `string-width` measures it).
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`), the
//! documented behaviour (`KNOWN_ISSUES.md` "Color emoji - ZWJ sequences",
//! `unicode_cells.rs`, `emoji_cluster_width_blind.rs`), the repo's vendoring
//! convention (`vendor_markers_blind.rs`) and the declarations / doc comments
//! of the vendored crate; never against implementation bodies.
//!
//! STATUS OF EACH CLAIM ON THE CURRENT BASE (measured):
//!
//!   * Claim 1, saturated cell swallows later pictographs: DOES NOT REPRODUCE
//!     through the FFI. A black-box sweep (base emoji + 0..40 ZWJ + 1..3
//!     pictographs, interleaved ZWJ/pictograph chains, combining-mark floods,
//!     and 30 000 random mixes of pictographs, ZWJ runs, swatches, VS16,
//!     marks, ASCII and CJK on a grid wide enough that nothing wraps) never
//!     lost a visible pictograph. The vendored `joins_emoji_cluster` documents
//!     the guard ("a base whose zero-width list is full joins nothing") and it
//!     holds. The saturation tests below therefore pass today; they are
//!     regression coverage that the (4) refactor must keep green, and the
//!     premise (the cell really is saturated and ends in a ZWJ) is asserted
//!     through the copy path in each of them so they cannot pass vacuously.
//!   * Claim 2, the guards of the join rule: each has a discriminating case
//!     (below); they pass today for the same reason. The cases were chosen so
//!     that deleting the single guard they name changes the output; this was
//!     reasoned from the documented rule, NOT proven by a mutation run (the
//!     blind author may not edit production code).
//!   * Claim 3, the re-apply marker: RED today. See "marker wording" below.
//!   * Claim 4, one helper instead of repeated previous-cell lookups: RED
//!     today, as a static source test (`the_previous_cell_lookup_lives_in_
//!     one_function`); it is the only way to pin a refactor that must not
//!     change behaviour.
//!
//! What this file pins:
//!
//!   1. SATURATION. A cell keeps a bounded number of zero-width scalars. When
//!      it is full and its last stored scalar is a ZWJ, a following pictograph
//!      has nowhere to be stored. It must be drawn as its own glyph in the
//!      next cell: it must not be dropped (no cell, no cursor advance), and
//!      because a dropped pictograph leaves the cell exactly as it was, every
//!      pictograph after it must not be dropped either. Text, skin-tone
//!      swatches, narrow pictographs and fresh clusters after the cluster all
//!      print normally. Several ways of reaching the saturated state are
//!      covered (pure ZWJ run, ZWJ after combining marks, a real joined chain
//!      with a skin tone, a one-column base, and a list full of combining
//!      marks whose last scalar is NOT a ZWJ), always with the saturation
//!      itself asserted through the copy path. One test types the pictographs
//!      one FFI call at a time and compares the whole per-step trace
//!      (`row 0`, cursor column), so a failure names the exact step at which
//!      output stopped. One test pins the exact boundary: with the cap
//!      measured through the copy path, a pictograph after (cap - 1) ZWJs
//!      still joins and a pictograph after `cap` ZWJs does not.
//!   2. EACH GUARD of the join rule, with a case that goes wrong when that
//!      guard alone is removed:
//!        * cursor motion between the ZWJ and the next emoji breaks the
//!          cluster (including the discriminating case where the cell left
//!          of the cursor really does end in a ZWJ),
//!        * ASCII and CJK bases never absorb a ZWJ-joined pictograph or a
//!          skin-tone modifier,
//!        * only a pictograph joins after a ZWJ,
//!        * INSERT mode loses no existing text to a cluster,
//!        * a narrow text-default base followed by a skin tone: the
//!          documented behaviour (widened in place; residual in the last
//!          column; `U+2764 ZWJ U+1F525` without VS16 is the per-scalar sum),
//!        * wrap at the last column, with and without a saturated cell.
//!   3. MAINTAINER CONTRACT. Every `fn`/`const` in the vendored
//!      `term/mod.rs` whose name is about the emoji-cluster fix (so
//!      `is_emoji_modifier` and whatever helpers the join logic is split
//!      into) carries the LITERAL marker `Blackbird fix (re-apply on bump)`
//!      in a comment and is listed in `vendor_markers_blind.rs`; so does the
//!      cluster branch in `Handler::input`. A vendor bump greps for the
//!      marker; an unmarked piece of the width fix is silently dropped.
//!   4. ONE LOOKUP. At most one function in the production half of
//!      `term/mod.rs` computes "the cell before the cursor" (reads the
//!      pending-wrap flag and steps a column back). The join decision and the
//!      cell the joined scalar is pushed onto must come from that one place,
//!      so they cannot disagree (a disagreement is how a scalar is judged
//!      "joined" against one cell and then dropped against another).
//!
//! MARKER WORDING (decision, per the task text and review feedback). The
//! task names the marker as `Blackbird fix (re-apply on bump)`, and that is
//! what is enforced here, literally, case-sensitive, in a `//` comment line.
//! `vendor_markers_blind.rs` is deliberately lenient (it also accepts
//! `Blackbird addition (re-apply on bump)` and `Blackbird fork change ...`),
//! which is exactly why it cannot notice a wording drift on a piece of this
//! fix. `is_emoji_modifier` is marked `Blackbird addition (re-apply on bump)`
//! today; the sibling pieces of the same fix say `Blackbird fix`. The fix for
//! this bug is to give `is_emoji_modifier` the same literal marker as its
//! siblings.
//!
//! Rig preconditions are asserted in every behavioural test
//! (`assert_rig_preconditions`) and the static scanners are unit-tested on
//! synthetic source text, so a vacuous pass is impossible.
//!
//! Pre-flight cost: grids are at most 80x4 (320 cells, ~6 KB) with 16 lines
//! of scrollback; the largest input is ~150 bytes (fed up to one scalar per
//! FFI call, ~100 calls); about 200 tiny terminals are created in total. No
//! sleeps, threads or allocation proportional to anything but those sizes;
//! the only I/O is reading `term/mod.rs` (~120 KB) and
//! `vendor_markers_blind.rs` as text.

use blackbird_core as bc;
use std::fs;
use std::path::{Path, PathBuf};

const SCROLLBACK: u32 = 16;
const ZWJ: char = '\u{200D}';

const ANY_WIDE_FLAG: u16 = bc::cell_flags::WIDE_CHAR
    | bc::cell_flags::WIDE_CHAR_SPACER
    | bc::cell_flags::LEADING_WIDE_CHAR_SPACER;

// ---------------------------------------------------------------------------
// Rig
// ---------------------------------------------------------------------------

/// Owning wrapper so a failing assertion still frees the terminal.
struct Term(*mut bc::BBTerm);

impl Term {
    fn new(cols: u16, rows: u16) -> Term {
        let t = unsafe { bc::bb_term_new(cols, rows, SCROLLBACK) };
        assert!(!t.is_null(), "bb_term_new({cols}, {rows}) returned null");
        Term(t)
    }

    fn feed(&self, s: &str) {
        unsafe { bc::bb_term_input(self.0, s.as_ptr(), s.len()) };
    }

    fn grid(&self) -> Grid {
        Grid::take(self.0)
    }

    /// Copy-path text for `[(line, c0) .. (line, c1)]`, prose mode.
    fn text_range(&self, line: i32, c0: u16, c1: u16) -> String {
        unsafe {
            let raw = bc::bb_term_text_range(self.0, line, c0, line, c1, 0);
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
}

impl Drop for Term {
    fn drop(&mut self) {
        unsafe { bc::bb_term_free(self.0) };
    }
}

/// Owned copy of one snapshot, so no raw pointer outlives its release.
struct Grid {
    cols: u16,
    rows: u16,
    cells: Vec<bc::BBCell>,
    cursor_col: u16,
    cursor_row: u16,
    pending_wrap: u8,
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
                pending_wrap: (*snap).cursor_pending_wrap,
            };
            bc::bb_snap_release(snap);
            g
        }
    }

    fn cell(&self, row: u16, col: u16) -> bc::BBCell {
        assert!(row < self.rows && col < self.cols);
        self.cells[(row as usize) * (self.cols as usize) + col as usize]
    }

    /// One char per cell: the cell's glyph (blank shown as a space), `#` for
    /// a `WIDE_CHAR_SPACER`, `<` for a `LEADING_WIDE_CHAR_SPACER`. A wide
    /// glyph cell shows its own base scalar. Trailing blanks are kept.
    fn row_glyphs(&self, row: u16) -> String {
        (0..self.cols)
            .map(|col| {
                let c = self.cell(row, col);
                if c.flags & bc::cell_flags::WIDE_CHAR_SPACER != 0 {
                    '#'
                } else if c.flags & bc::cell_flags::LEADING_WIDE_CHAR_SPACER != 0 {
                    '<'
                } else if c.ch == 0 {
                    ' '
                } else {
                    char::from_u32(c.ch).unwrap_or('\u{FFFD}')
                }
            })
            .collect()
    }

    /// Row glyphs with trailing blanks trimmed (readable failure output).
    fn row(&self, row: u16) -> String {
        self.row_glyphs(row).trim_end().to_string()
    }

    /// Rows that hold any visible cell.
    fn inked_rows(&self) -> Vec<u16> {
        (0..self.rows)
            .filter(|&r| {
                (0..self.cols).any(|c| {
                    let cell = self.cell(r, c);
                    !((cell.ch == 0 || cell.ch == b' ' as u32) && cell.flags & ANY_WIDE_FLAG == 0)
                })
            })
            .collect()
    }

    /// Spacer-must-follow-wide invariant (documented on `WIDE_CHAR_SPACER`).
    fn orphan_spacers(&self) -> Vec<String> {
        let mut out = Vec::new();
        for row in 0..self.rows {
            for col in 0..self.cols {
                let c = self.cell(row, col);
                if c.flags & bc::cell_flags::WIDE_CHAR_SPACER == 0 {
                    continue;
                }
                let preceded =
                    col > 0 && self.cell(row, col - 1).flags & bc::cell_flags::WIDE_CHAR != 0;
                if !preceded {
                    out.push(format!(
                        "row {row} col {col}: WIDE_CHAR_SPACER not preceded by WIDE_CHAR"
                    ));
                }
            }
        }
        out
    }

    /// The cursor column the PROGRAM believes in: the grid column plus one if
    /// the cursor is parked on the last written cell with a pending wrap.
    fn logical_col(&self) -> u32 {
        self.cursor_col as u32 + self.pending_wrap as u32
    }
}

fn blanks(n: usize) -> String {
    " ".repeat(n)
}

fn zwjs(n: usize) -> String {
    ZWJ.to_string().repeat(n)
}

/// Rig preconditions. Without these a green run could mean "the snapshot is
/// blind to wide flags", "nothing ever joins, so every guard test passes
/// trivially" or "the copy path never returns zero-width scalars".
///
///   1. A native wide emoji is glyph + spacer, the cursor moves by 2.
///   2. A legal ZWJ cluster (woman + ZWJ + laptop) IS one 2-column glyph, so
///      "does not join" assertions below are not satisfied by a core that
///      never joins anything.
///   3. A skin-tone modifier after a wide base IS joined (2 columns total).
///   4. The narrow pictographs used below (U+270C, U+2194, U+2764) are really
///      one column wide on their own.
///   5. Copy over the cluster's two cells returns the ZWJ-joined scalars, so
///      the saturation checks that read them back are meaningful.
fn assert_rig_preconditions() {
    let t = Term::new(20, 3);
    t.feed("x\u{1F600}y");
    let g = t.grid();
    assert_eq!(
        (g.row(0), g.cursor_col),
        ("x\u{1F600}#y".to_string(), 4),
        "precondition: a native wide emoji is glyph + spacer ('#') with 'y' right after"
    );

    let t = Term::new(20, 3);
    t.feed("\u{1F469}\u{200D}\u{1F4BB}|");
    let g = t.grid();
    assert_eq!(
        (g.row(0), g.cursor_col),
        ("\u{1F469}#|".to_string(), 3),
        "precondition: woman + ZWJ + laptop must be ONE 2-column glyph (a core that never \
         joins would make every guard test vacuous)"
    );
    assert_eq!(
        t.text_range(0, 0, 1),
        "\u{1F469}\u{200D}\u{1F4BB}",
        "precondition: copy over the cluster's two cells returns the whole ZWJ sequence"
    );

    let t = Term::new(20, 3);
    t.feed("\u{1F44D}\u{1F3FD}|");
    let g = t.grid();
    assert_eq!(
        (g.row(0), g.cursor_col),
        ("\u{1F44D}#|".to_string(), 3),
        "precondition: thumbs-up + skin tone must be ONE 2-column glyph"
    );

    for narrow in ['\u{270C}', '\u{2194}', '\u{2764}'] {
        let t = Term::new(20, 3);
        t.feed(&narrow.to_string());
        let g = t.grid();
        assert_eq!(
            (g.cursor_col, g.row(0)),
            (1, narrow.to_string()),
            "precondition: U+{:04X} alone must be a single narrow cell",
            narrow as u32
        );
    }
}

// ---------------------------------------------------------------------------
// 1. Saturated zero-width list
// ---------------------------------------------------------------------------

/// The zero-width scalars the copy path reports for the cluster whose base is
/// in cells 0-1 of a fresh terminal after `prefix` was typed.
fn stored_marks(prefix: &str) -> Vec<char> {
    let t = Term::new(24, 3);
    t.feed(prefix);
    t.text_range(0, 0, 1).chars().skip(1).collect()
}

/// Ways to reach a cell whose zero-width list is full and whose LAST stored
/// scalar is a ZWJ. Every prefix feeds strictly more zero-width scalars than
/// any plausible cap (the cap itself is not assumed: truncation is asserted
/// through the copy path). `fed` is the number of zero-width scalars fed.
struct SaturatedPrefix {
    label: &'static str,
    prefix: String,
    fed: usize,
    base: char,
}

fn saturated_prefixes() -> Vec<SaturatedPrefix> {
    vec![
        SaturatedPrefix {
            label: "slightly-smiling face + 40 ZWJ",
            prefix: format!("\u{1F642}{}", zwjs(40)),
            fed: 40,
            base: '\u{1F642}',
        },
        SaturatedPrefix {
            label: "face + 31 combining marks + ZWJ + 4 more combining marks",
            prefix: format!(
                "\u{1F642}{}{}{}",
                "\u{0301}".repeat(31),
                ZWJ,
                "\u{0301}".repeat(4)
            ),
            fed: 36,
            base: '\u{1F642}',
        },
        SaturatedPrefix {
            label: "woman + skin tone + 15 x (ZWJ, woman) + 4 ZWJ (a real chain that fills up)",
            prefix: format!(
                "\u{1F469}\u{1F3FD}{}{}",
                format!("{ZWJ}\u{1F469}").repeat(15),
                zwjs(4)
            ),
            fed: 1 + 30 + 4,
            base: '\u{1F469}',
        },
    ]
}

/// `(label, text typed after the cluster, expected cells that follow the
/// cluster's two cells)`. A cell string uses the row-dump alphabet: a wide
/// glyph is its scalar followed by `#`.
fn followers() -> Vec<(&'static str, &'static str, &'static str)> {
    vec![
        ("one wide emoji", "\u{1F600}", "\u{1F600}#"),
        (
            "three wide emoji in a row",
            "\u{1F600}\u{1F600}\u{1F600}",
            "\u{1F600}#\u{1F600}#\u{1F600}#",
        ),
        (
            "text, emoji, text, emoji",
            "abc\u{1F600}d\u{1F600}",
            "abc\u{1F600}#d\u{1F600}#",
        ),
        ("narrow pictograph U+270C", "\u{270C}", "\u{270C}"),
        ("narrow arrow U+2194", "\u{2194}", "\u{2194}"),
        ("narrow heart U+2764", "\u{2764}", "\u{2764}"),
        ("lone skin-tone swatch", "\u{1F3FD}", "\u{1F3FD}#"),
        (
            "a fresh ZWJ cluster (woman technologist)",
            "\u{1F469}\u{200D}\u{1F4BB}",
            "\u{1F469}#",
        ),
        (
            "mixed text, wide emoji, swatch, narrow pictograph",
            "ok \u{1F600}x\u{1F3FD}\u{270C}\u{1F600}\u{1F600}end",
            "ok \u{1F600}#x\u{1F3FD}#\u{270C}\u{1F600}#\u{1F600}#end",
        ),
    ]
}

#[test]
fn a_saturated_zwj_cell_never_swallows_what_follows() {
    assert_rig_preconditions();

    // Premise of the whole test, per prefix: the cell really is saturated
    // (the copy holds fewer zero-width scalars than were fed) and its last
    // stored scalar really is the ZWJ.
    let mut premise_failures: Vec<String> = Vec::new();
    for p in saturated_prefixes() {
        let marks = stored_marks(&p.prefix);
        let tail = marks.last().copied();
        if !(marks.len() >= 8 && marks.len() < p.fed && tail == Some(ZWJ)) {
            premise_failures.push(format!(
                "{}: copy holds {} zero-width scalars (fed {}), last = {:?}; expected a \
                 truncated list ending in ZWJ",
                p.label,
                marks.len(),
                p.fed,
                tail
            ));
        }
    }
    assert_eq!(
        premise_failures,
        Vec::<String>::new(),
        "precondition: each prefix must leave a saturated base cell whose last stored scalar \
         is a ZWJ"
    );

    let mut failures: Vec<String> = Vec::new();
    for p in saturated_prefixes() {
        for (flabel, typed, cells) in followers() {
            let t = Term::new(24, 3);
            t.feed(&p.prefix);
            t.feed(typed);
            t.feed("|");
            let g = t.grid();
            let used = 2 + cells.chars().count() + 1;
            let want_row = format!("{}#{}|{}", p.base, cells, blanks(24 - used));
            let ok = g.row_glyphs(0) == want_row
                && g.cursor_row == 0
                && g.cursor_col as usize == used
                && g.pending_wrap == 0
                && g.inked_rows() == vec![0u16]
                && g.orphan_spacers().is_empty();
            if !ok {
                failures.push(format!(
                    "{} then {flabel}: row 0 = {:?} want {:?}; cursor (row {}, col {}, pending {}) \
                     want (0, {used}, 0)",
                    p.label,
                    g.row(0),
                    want_row.trim_end(),
                    g.cursor_row,
                    g.cursor_col,
                    g.pending_wrap
                ));
            }
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "after a saturated cluster everything that follows must be drawn in the following cells \
         ('#' = wide spacer); a pictograph must never be silently dropped because the previous \
         cell's last stored scalar is a ZWJ"
    );
}

/// One FFI call per scalar, so no state can hide inside a single `feed`.
fn feed_scalar_by_scalar(t: &Term, s: &str) {
    for ch in s.chars() {
        let mut buf = [0u8; 4];
        t.feed(ch.encode_utf8(&mut buf));
    }
}

#[test]
fn a_saturated_cell_stops_accepting_joins_pictograph_by_pictograph() {
    assert_rig_preconditions();
    // Per-scalar trace. After the saturating run, each pictograph is typed on
    // its own and the whole screen state is checked before the next one: if
    // the saturated cell kept treating "my last stored scalar is a ZWJ" as an
    // open join, the FIRST pictograph vanishes and the cursor does not move,
    // and every one after it would vanish the same way (the cell never
    // changes, so the answer never changes). The trace of
    // `(step, row 0, cursor col)` is asserted as a whole so a failure shows
    // the exact scalar at which output stopped.
    // (what is typed, name, what its cells look like, columns it takes)
    let steps: [(&str, &str, &str, u16); 7] = [
        ("\u{1F600}", "grinning face", "\u{1F600}#", 2),
        ("\u{1F601}", "beaming face", "\u{1F601}#", 2),
        ("\u{270C}", "victory hand (narrow)", "\u{270C}", 1),
        ("\u{1F602}", "face with tears of joy", "\u{1F602}#", 2),
        ("x", "letter x", "x", 1),
        ("\u{1F60E}", "face with sunglasses", "\u{1F60E}#", 2),
        ("\u{1F680}", "rocket", "\u{1F680}#", 2),
    ];

    for p in saturated_prefixes() {
        // Prefix fed scalar by scalar: the saturating run must behave like the
        // one-shot feed.
        let t = Term::new(40, 3);
        feed_scalar_by_scalar(&t, &p.prefix);
        let premise: Vec<char> = t.text_range(0, 0, 1).chars().skip(1).collect();
        assert!(
            premise.len() >= 8 && premise.len() < p.fed && premise.last() == Some(&ZWJ),
            "precondition ({}): copy over the base's two cells holds {} zero-width scalars \
             (fed {}), last = {:?}; expected a truncated list ending in ZWJ",
            p.label,
            premise.len(),
            p.fed,
            premise.last()
        );

        let mut want_trace: Vec<String> = Vec::new();
        let mut got_trace: Vec<String> = Vec::new();
        let mut want_row = format!("{}#", p.base);
        let mut want_col: u16 = 2;
        for (i, (scalar, name, cells, cols)) in steps.iter().enumerate() {
            t.feed(scalar);
            want_row.push_str(cells);
            want_col += cols;
            want_trace.push(format!(
                "step {} ({name}): row 0 = {want_row:?}, cursor col {want_col}",
                i + 1
            ));
            let g = t.grid();
            got_trace.push(format!(
                "step {} ({name}): row 0 = {:?}, cursor col {}",
                i + 1,
                g.row(0),
                g.cursor_col
            ));
        }
        assert_eq!(
            got_trace, want_trace,
            "{}: every pictograph typed after a saturated ZWJ cluster must be drawn in the next \
             cells and advance the cursor; the first missing step is where the saturated cell \
             swallowed it ('#' = wide spacer)",
            p.label
        );
    }
}

#[test]
fn a_saturated_narrow_base_does_not_swallow_what_follows_mid_row() {
    assert_rig_preconditions();
    // The same state for a one-column base (the earlier saturation tests use
    // wide bases, or the last column only): U+2764 / U+270C are narrow
    // text-default pictographs. 40 ZWJ saturate the cell; the row has plenty of
    // room, so nothing here involves wrapping.
    let mut failures: Vec<String> = Vec::new();
    for (label, base) in [("heart", '\u{2764}'), ("victory hand", '\u{270C}')] {
        for (flabel, typed, cells) in [
            ("one wide emoji", "\u{1F600}", "\u{1F600}#"),
            (
                "two wide emoji in a row",
                "\u{1F600}\u{1F601}",
                "\u{1F600}#\u{1F601}#",
            ),
            ("text after", "abc", "abc"),
            ("narrow arrow", "\u{2194}", "\u{2194}"),
            (
                "fresh ZWJ cluster",
                "\u{1F469}\u{200D}\u{1F4BB}",
                "\u{1F469}#",
            ),
        ] {
            for chunked in [false, true] {
                let t = Term::new(24, 3);
                t.feed(&base.to_string());
                if chunked {
                    feed_scalar_by_scalar(&t, &zwjs(40));
                    feed_scalar_by_scalar(&t, typed);
                } else {
                    t.feed(&zwjs(40));
                    t.feed(typed);
                }
                t.feed("|");
                let marks: Vec<char> = stored_marks(&format!("{base}{}", zwjs(40)));
                let g = t.grid();
                let used = 1 + cells.chars().count() + 1;
                let want_row = format!("{base}{cells}|{}", blanks(24 - used));
                if marks.len() >= 40
                    || marks.len() < 8
                    || marks.last() != Some(&ZWJ)
                    || g.row_glyphs(0) != want_row
                    || g.cursor_col as usize != used
                    || g.cursor_row != 0
                {
                    failures.push(format!(
                        "{label} + 40 ZWJ then {flabel} (chunked={chunked}): row 0 = {:?} want \
                         {:?}; cursor (row {}, col {}) want (0, {used}); stored zero-width \
                         scalars {} (must be a truncated list ending in ZWJ)",
                        g.row(0),
                        want_row.trim_end(),
                        g.cursor_row,
                        g.cursor_col,
                        marks.len()
                    ));
                }
            }
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "a narrow pictograph base whose zero-width list is full of ZWJs must not swallow the \
         pictographs and text typed after it"
    );
}

#[test]
fn a_cell_saturated_with_combining_marks_does_not_swallow_a_pictograph_or_swatch() {
    assert_rig_preconditions();
    // The list is full but its last stored scalar is NOT a ZWJ: the full-list
    // guard has to stand on its own (a check that only looks at "last scalar is
    // ZWJ" never sees this state). After a ZWJ that was itself dropped for lack
    // of room, the pictograph also has nowhere to go.
    let mut failures: Vec<String> = Vec::new();
    let full_of_marks = "\u{0301}".repeat(40);
    for (plabel, prefix) in [
        (
            "face + 40 combining acutes",
            format!("\u{1F642}{full_of_marks}"),
        ),
        (
            "face + 40 combining acutes + ZWJ (the ZWJ itself is dropped)",
            format!("\u{1F642}{full_of_marks}{ZWJ}"),
        ),
    ] {
        let stored: Vec<char> = stored_marks(&prefix);
        if stored.len() >= 40 || stored.len() < 8 {
            failures.push(format!(
                "{plabel}: precondition, copy holds {} zero-width scalars (fed 40+)",
                stored.len()
            ));
            continue;
        }
        for (flabel, typed, cells) in [
            ("wide emoji", "\u{1F600}", "\u{1F600}#"),
            ("skin-tone swatch", "\u{1F3FD}", "\u{1F3FD}#"),
            ("ZWJ + wide emoji", "\u{200D}\u{1F600}", "\u{1F600}#"),
            ("narrow pictograph", "\u{270C}", "\u{270C}"),
        ] {
            let t = Term::new(24, 3);
            t.feed(&prefix);
            t.feed(typed);
            t.feed("|");
            let g = t.grid();
            let used = 2 + cells.chars().count() + 1;
            let want_row = format!("\u{1F642}#{cells}|{}", blanks(24 - used));
            if g.row_glyphs(0) != want_row || g.cursor_col as usize != used || g.cursor_row != 0 {
                failures.push(format!(
                    "{plabel} then {flabel}: row 0 = {:?} want {:?}; cursor (row {}, col {}) want \
                     (0, {used})",
                    g.row(0),
                    want_row.trim_end(),
                    g.cursor_row,
                    g.cursor_col
                ));
            }
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "a visible pictograph or swatch that cannot be stored on a full cell must be drawn in \
         the next cells, never dropped"
    );
}

#[test]
fn the_join_boundary_is_exactly_the_zero_width_capacity_of_the_cell() {
    assert_rig_preconditions();
    // The capacity is not assumed: it is the number of ZWJs the copy path
    // reports after far more than any plausible cap were fed. A pictograph
    // after (cap - 1) ZWJs still has one free slot and must join (it is the
    // cell's last scalar, copy returns it, the cursor does not move); after
    // `cap` ZWJs the list is full and ends in a ZWJ, so the pictograph must
    // be its own glyph. An off-by-one in either direction shows up as one of
    // the two cases flipping.
    let cap = stored_marks(&format!("\u{1F642}{}", zwjs(100))).len();
    assert!(
        (8..100).contains(&cap),
        "precondition: 100 ZWJ must overflow the cell's zero-width list; the copy path returned \
         {cap} stored scalars"
    );

    let base = '\u{1F642}';
    let face = '\u{1F600}';
    // (label, ZWJs after the base, typed after the ZWJs, expected cursor col,
    // expected row 0 trimmed)
    let rows: Vec<(String, String, String, u16, String)> = vec![
        (
            format!(
                "{} ZWJ (one free slot) then a pictograph: it joins",
                cap - 1
            ),
            zwjs(cap - 1),
            format!("{face}|"),
            3,
            format!("{base}#|"),
        ),
        (
            format!("{cap} ZWJ (list full, last = ZWJ) then a pictograph: it is its own glyph"),
            zwjs(cap),
            format!("{face}|"),
            5,
            format!("{base}#{face}#|"),
        ),
        (
            format!(
                "{} ZWJ (far past the cap) then a pictograph: it is its own glyph",
                cap + 7
            ),
            zwjs(cap + 7),
            format!("{face}|"),
            5,
            format!("{base}#{face}#|"),
        ),
        (
            format!(
                "{} ZWJ, a joined pictograph fills the list, a second one is standalone",
                cap - 1
            ),
            zwjs(cap - 1),
            format!("{face}{face}|"),
            5,
            format!("{base}#{face}#|"),
        ),
        (
            format!(
                "{} ZWJ, joined pictograph, then ZWJ + pictograph: the list is full again",
                cap - 1
            ),
            zwjs(cap - 1),
            format!("{face}{ZWJ}{face}|"),
            5,
            format!("{base}#{face}#|"),
        ),
    ];

    let mut failures: Vec<String> = Vec::new();
    for (label, lead, typed, want_col, want_row) in rows {
        let t = Term::new(24, 3);
        t.feed(&format!("{base}{lead}"));
        t.feed(&typed);
        let g = t.grid();
        let used_ok = g.cursor_col == want_col && g.cursor_row == 0;
        if g.row(0) != want_row || !used_ok {
            failures.push(format!(
                "{label}: row 0 = {:?} want {:?}; cursor (row {}, col {}) want (0, {want_col})",
                g.row(0),
                want_row,
                g.cursor_row,
                g.cursor_col
            ));
        }
    }

    // The joined case also has to be a real join (the pictograph rides on the
    // base cell), not a coincidence of the row dump.
    let t = Term::new(24, 3);
    t.feed(&format!("{base}{}{face}", zwjs(cap - 1)));
    let copied = t.text_range(0, 0, 1);
    let want_copy = format!("{base}{}{face}", zwjs(cap - 1));
    if copied != want_copy {
        failures.push(format!(
            "{} ZWJ then a pictograph: copy over the base's two cells returned {} scalar(s), want \
             the base, {} ZWJ and the pictograph ({} scalars)",
            cap - 1,
            copied.chars().count(),
            cap - 1,
            cap + 1
        ));
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "the pictograph after a ZWJ joins the cluster exactly while the base cell still has a \
         free zero-width slot (cap measured as {cap}); with a full list it must be drawn in the \
         next cells, never dropped ('#' = wide spacer)"
    );
}

#[test]
fn a_saturated_cell_does_not_eat_the_pictograph_that_arrives_after_the_wrap() {
    assert_rig_preconditions();
    // Same state in the last two columns: the ZWJ run leaves the cursor
    // parked in the pending-wrap state; the next pictograph must wrap to the
    // next row and be drawn there, not vanish.
    for (label, filler, base, base_width) in [
        ("wide base in columns 78-79", 78usize, '\u{1F642}', 2usize),
        ("narrow base in column 79", 79usize, '\u{270C}', 1usize),
    ] {
        let t = Term::new(80, 4);
        t.feed(&"x".repeat(filler));
        t.feed(&base.to_string());
        t.feed(&zwjs(40));
        let g = t.grid();
        assert_eq!(
            (g.cursor_row, g.logical_col(), g.inked_rows()),
            (0, 80, vec![0u16]),
            "{label}: precondition, the ZWJ run keeps the cursor at the end of row 0 \
             (row, logical col, inked rows); grid cursor col {} pending {}",
            g.cursor_col,
            g.pending_wrap
        );

        t.feed("\u{1F600}\u{1F600}|");
        let g = t.grid();
        let glyph = if base_width == 2 {
            format!("{base}#")
        } else {
            base.to_string()
        };
        assert_eq!(
            g.row(0),
            format!("{}{}", "x".repeat(filler), glyph),
            "{label}: row 0 must be untouched by the pictographs that come after the saturated cell"
        );
        assert_eq!(
            g.row(1),
            "\u{1F600}#\u{1F600}#|",
            "{label}: both pictographs after the saturated cell must be drawn on row 1"
        );
        assert_eq!(
            (g.cursor_row, g.cursor_col),
            (1, 5),
            "{label}: cursor after two emoji and the marker on row 1 (row, col)"
        );
    }
}

// ---------------------------------------------------------------------------
// 2. The guards of the join rule
// ---------------------------------------------------------------------------

#[test]
fn only_a_pictograph_joins_after_a_zwj() {
    assert_rig_preconditions();
    // (label, input, expected row 0 trimmed, expected cursor col)
    let cases: [(&str, String, String, u16); 5] = [
        (
            "ZWJ then ASCII",
            format!("\u{1F600}{ZWJ}a|"),
            "\u{1F600}#a|".to_string(),
            4,
        ),
        (
            "ZWJ then CJK",
            format!("\u{1F600}{ZWJ}\u{4E2D}|"),
            "\u{1F600}#\u{4E2D}#|".to_string(),
            5,
        ),
        (
            "ZWJ then space then emoji",
            format!("\u{1F600}{ZWJ} \u{1F600}|"),
            "\u{1F600}# \u{1F600}#|".to_string(),
            6,
        ),
        (
            "two adjacent emoji with no ZWJ",
            "\u{1F600}\u{1F600}|".to_string(),
            "\u{1F600}#\u{1F600}#|".to_string(),
            5,
        ),
        (
            "ZWJ at the start of a row, then emoji",
            format!("{ZWJ}\u{1F600}|"),
            "\u{1F600}#|".to_string(),
            3,
        ),
    ];
    let mut failures: Vec<String> = Vec::new();
    for (label, input, want_row, want_col) in cases {
        let t = Term::new(20, 3);
        t.feed(&input);
        let g = t.grid();
        if g.row(0) != want_row || g.cursor_col != want_col || g.cursor_row != 0 {
            failures.push(format!(
                "{label}: row 0 = {:?} want {:?}; cursor (row {}, col {}) want (0, {want_col})",
                g.row(0),
                want_row,
                g.cursor_row,
                g.cursor_col
            ));
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "a ZWJ binds only to a pictograph on its immediate right"
    );
}

#[test]
fn ascii_and_cjk_bases_never_absorb_a_zwj_joined_pictograph_or_a_skin_tone() {
    assert_rig_preconditions();
    // string-width: an ASCII letter / digit / CJK ideograph is not an
    // Extended_Pictographic base, so the emoji after ZWJ or the swatch is its
    // own 2-column grapheme next to it.
    // (label, base, cells the base takes, row dump of the base)
    let bases: [(&str, &str, usize, &str); 5] = [
        ("ASCII letter", "a", 1, "a"),
        ("ASCII digit", "7", 1, "7"),
        ("CJK ideograph", "\u{4E2D}", 2, "\u{4E2D}#"),
        ("Hangul syllable", "\u{D55C}", 2, "\u{D55C}#"),
        ("fullwidth Latin", "\u{FF21}", 2, "\u{FF21}#"),
    ];
    let mut failures: Vec<String> = Vec::new();
    for (label, base, width, dump) in bases {
        for (tail_label, tail, tail_dump) in [
            ("ZWJ + wide emoji", format!("{ZWJ}\u{1F600}"), "\u{1F600}#"),
            ("skin-tone swatch", "\u{1F3FD}".to_string(), "\u{1F3FD}#"),
            (
                "ZWJ + skin-tone swatch",
                format!("{ZWJ}\u{1F3FD}"),
                "\u{1F3FD}#",
            ),
        ] {
            let t = Term::new(20, 3);
            t.feed(base);
            t.feed(&tail);
            t.feed("|");
            let g = t.grid();
            let used = width + 2 + 1;
            let want = format!("{dump}{tail_dump}|{}", blanks(20 - used));
            if g.row_glyphs(0) != want || g.cursor_col as usize != used || g.cursor_row != 0 {
                failures.push(format!(
                    "{label} + {tail_label}: row 0 = {:?} want {:?}; cursor col {} want {used}",
                    g.row(0),
                    want.trim_end(),
                    g.cursor_col
                ));
            }
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "ASCII and CJK bases must stay standalone: the emoji / swatch after them is its own \
         wide glyph and advances the cursor by 2 ('#' = wide spacer)"
    );
}

#[test]
fn cursor_motion_between_the_zwj_and_the_emoji_breaks_the_cluster() {
    assert_rig_preconditions();

    // (a) Cursor jumped far away: the emoji lands there, standalone.
    let t = Term::new(20, 3);
    t.feed("\u{1F600}\u{200D}\x1b[1;10H\u{1F600}|");
    let g = t.grid();
    assert_eq!(
        g.row_glyphs(0),
        format!("\u{1F600}#{}\u{1F600}#|{}", blanks(7), blanks(8)),
        "CUP away after the ZWJ: the emoji is its own glyph at columns 9-10"
    );
    assert_eq!(
        g.cursor_col, 12,
        "cursor after the far emoji and the marker"
    );

    // (b) Cursor moved right by a few columns.
    let t = Term::new(20, 3);
    t.feed("\u{1F600}\u{200D}\x1b[3C\u{1F600}|");
    let g = t.grid();
    assert_eq!(
        g.row_glyphs(0),
        format!("\u{1F600}#{}\u{1F600}#|{}", blanks(3), blanks(12)),
        "CUF after the ZWJ: the emoji is its own glyph at columns 5-6"
    );

    // (c) CR + LF to the next row: the emoji starts the new row.
    let t = Term::new(20, 3);
    t.feed("\u{1F600}\u{200D}\r\n\u{1F600}|");
    let g = t.grid();
    assert_eq!(
        (g.row(0), g.row(1)),
        ("\u{1F600}#".to_string(), "\u{1F600}#|".to_string()),
        "CR LF after the ZWJ: the emoji starts row 1 and does not join the glyph above"
    );

    // (d) The discriminating case. The cell directly LEFT of the cursor does
    // end in a ZWJ (glyph A), but the glyph the program wrote last is
    // elsewhere (glyph B). The emoji is not a continuation of A.
    let t = Term::new(20, 3);
    t.feed("\u{1F600}\u{200D}");
    assert_eq!(
        t.text_range(0, 0, 1),
        "\u{1F600}\u{200D}",
        "precondition: the ZWJ rides on glyph A"
    );
    t.feed("\x1b[3;1H\u{1F600}\u{200D}");
    t.feed("\x1b[1;3H\u{1F600}|");
    let g = t.grid();
    assert_eq!(
        g.row(0),
        "\u{1F600}#\u{1F600}#|",
        "cursor returned beside glyph A's ZWJ after writing glyph B elsewhere: the emoji must \
         be a standalone glyph at columns 2-3, not join A"
    );
    assert_eq!(
        g.row(2),
        "\u{1F600}#",
        "glyph B (with its own ZWJ) must be untouched"
    );
    assert_eq!(
        (g.cursor_row, g.cursor_col),
        (0, 5),
        "cursor after the standalone emoji and the marker (row, col)"
    );

    // (e) Same, with plain text typed in between (updates the last-written
    // state of the cursor neighbourhood).
    let t = Term::new(20, 3);
    t.feed("\u{1F600}\u{200D}\x1b[2;1Hx\x1b[1;3H\u{1F600}|");
    let g = t.grid();
    assert_eq!(
        (g.row(0), g.row(1)),
        ("\u{1F600}#\u{1F600}#|".to_string(), "x".to_string()),
        "ZWJ, then text elsewhere, then the cursor back beside the ZWJ: the emoji is standalone"
    );
    assert_eq!(
        g.cursor_col, 5,
        "cursor after the standalone emoji and the marker"
    );
}

#[test]
fn cursor_motion_before_a_skin_tone_modifier_after_a_zwj_tail_breaks_the_cluster() {
    assert_rig_preconditions();
    // Modifier flavour of the discriminating case: glyph A ends in a ZWJ and
    // sits left of the cursor, but glyph B was written last elsewhere.
    let t = Term::new(20, 3);
    t.feed("\u{1F600}\u{200D}\x1b[3;1H\u{1F600}\u{200D}\x1b[1;3H\u{1F3FD}|");
    let g = t.grid();
    assert_eq!(
        g.row(0),
        "\u{1F600}#\u{1F3FD}#|",
        "a swatch typed beside glyph A's ZWJ after the cursor moved is a standalone glyph"
    );
    assert_eq!(g.cursor_col, 5, "cursor after the swatch and the marker");
}

#[test]
fn insert_mode_loses_no_existing_text_to_a_cluster() {
    assert_rig_preconditions();
    // IRM (CSI 4 h): every glyph typed shifts the rest of the row right by its
    // real width. A joined component must not shift anything again.
    // (label, typed after IRM on, expected row 0 trimmed, expected cursor col)
    let cases: [(&str, String, String, u16); 4] = [
        (
            "woman + ZWJ + laptop (joined in place, shifts text by 2 once)",
            format!("\u{1F469}{ZWJ}\u{1F4BB}|"),
            "\u{1F469}#|abcdef".to_string(),
            3,
        ),
        (
            "thumbs-up + skin tone (joined in place)",
            "\u{1F44D}\u{1F3FD}|".to_string(),
            "\u{1F44D}#|abcdef".to_string(),
            3,
        ),
        (
            "saturated ZWJ cell then emoji (standalone, shifts text by its own 2)",
            format!("\u{1F642}{}\u{1F600}|", zwjs(40)),
            "\u{1F642}#\u{1F600}#|abcdef".to_string(),
            5,
        ),
        (
            "narrow base + ZWJ + emoji (documented per-scalar sum, nothing lost)",
            format!("\u{2764}{ZWJ}\u{1F525}|"),
            "\u{2764}\u{1F525}#|abcdef".to_string(),
            4,
        ),
    ];
    let mut failures: Vec<String> = Vec::new();
    for (label, typed, want_row, want_col) in cases {
        let t = Term::new(20, 3);
        t.feed("abcdef\x1b[H\x1b[4h");
        t.feed(&typed);
        let g = t.grid();
        if g.row(0) != want_row || g.cursor_col != want_col || g.cursor_row != 0 {
            failures.push(format!(
                "{label}: row 0 = {:?} want {:?}; cursor (row {}, col {}) want (0, {want_col})",
                g.row(0),
                want_row,
                g.cursor_row,
                g.cursor_col
            ));
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "insert mode must keep every pre-existing character, shifted by exactly the glyphs' \
         real widths"
    );
}

#[test]
fn narrow_text_default_base_documented_behaviour() {
    assert_rig_preconditions();
    // KNOWN_ISSUES.md ("Color emoji - ZWJ sequences"): a text-default
    // (width-1) base followed by a skin tone is widened in place, so
    // U+270C U+1F3FD is ONE 2-column glyph like string-width says; the residual
    // is a narrow base already in the LAST column (the swatch wraps as its own
    // glyph) and a narrow base + ZWJ + emoji without VS16 or a modifier, which
    // advances by the per-scalar sum. If any of these is ever fixed, this is
    // the test (and the document) to update.

    // Widened in place: base ink in column 0, spacer in column 1, '|' at 2.
    for (label, base) in [
        ("victory hand", '\u{270C}'),
        ("index pointing up", '\u{261D}'),
        ("person lifting weights", '\u{1F3CB}'),
    ] {
        let t = Term::new(20, 3);
        t.feed(&format!("{base}\u{1F3FD}|"));
        let g = t.grid();
        assert_eq!(
            (g.row(0), g.cursor_col),
            (format!("{base}#|"), 3),
            "{label} + skin tone: widened in place to one 2-column glyph (glyph + spacer '#')"
        );
        assert_eq!(
            t.text_range(0, 0, 1),
            format!("{base}\u{1F3FD}"),
            "{label} + skin tone: copy over the two cells returns base + swatch"
        );
    }

    // Residual 1: narrow base already in the last column.
    let t = Term::new(80, 4);
    t.feed(&"x".repeat(79));
    t.feed("\u{270C}\u{1F3FD}|");
    let g = t.grid();
    assert_eq!(
        (g.row(0), g.row(1)),
        (
            format!("{}\u{270C}", "x".repeat(79)),
            "\u{1F3FD}#|".to_string()
        ),
        "narrow base in column 80: the swatch wraps to row 1 as a standalone glyph"
    );
    assert_eq!(
        (g.cursor_row, g.cursor_col),
        (1, 3),
        "cursor after the wrapped swatch and the marker (row, col)"
    );

    // Residual 2: heart + ZWJ + fire, no VS16 and no modifier: 1 + 2 cells.
    let t = Term::new(20, 3);
    t.feed(&format!("\u{2764}{ZWJ}\u{1F525}|"));
    let g = t.grid();
    assert_eq!(
        (g.row(0), g.cursor_col),
        ("\u{2764}\u{1F525}#|".to_string(), 4),
        "narrow heart + ZWJ + fire without VS16: documented per-scalar sum (3 cells, then '|')"
    );
}

#[test]
fn wrap_at_the_last_column_keeps_the_cluster_whole() {
    assert_rig_preconditions();
    // A cluster that does not fit in the last column wraps as ONE unit, and
    // the pieces that arrive afterwards join it on the new row (not on the
    // old row, not on a third position).
    for (label, tail) in [
        ("ZWJ then laptop", format!("{ZWJ}\u{1F4BB}")),
        ("skin tone", "\u{1F3FD}".to_string()),
        ("skin tone, ZWJ, laptop", format!("\u{1F3FD}{ZWJ}\u{1F4BB}")),
    ] {
        let t = Term::new(80, 4);
        t.feed(&"x".repeat(79));
        t.feed("\u{1F469}");
        let g = t.grid();
        assert_eq!(
            (g.row(1), g.cursor_row, g.cursor_col),
            ("\u{1F469}#".to_string(), 1, 2),
            "{label}: precondition, the woman wrapped whole to row 1 (row 1, cursor row, col)"
        );
        t.feed(&tail);
        t.feed("|");
        let g = t.grid();
        assert_eq!(
            (g.row(1), g.cursor_row, g.cursor_col, g.inked_rows()),
            ("\u{1F469}#|".to_string(), 1, 3, vec![0u16, 1]),
            "{label}: the later pieces join the wrapped glyph in place (row 1, cursor row, col, \
             inked rows)"
        );
    }

    // A cluster that exactly fills the last two columns stays on the row and
    // a ZWJ + non-joining scalar then wraps normally.
    let t = Term::new(80, 4);
    t.feed(&"x".repeat(78));
    t.feed(&format!("\u{1F469}{ZWJ}a"));
    let g = t.grid();
    assert_eq!(
        (g.row(0), g.row(1)),
        (format!("{}\u{1F469}#", "x".repeat(78)), "a".to_string()),
        "78 x + woman + ZWJ + 'a': the ZWJ rides on the woman, 'a' wraps to row 1"
    );
}

// ---------------------------------------------------------------------------
// 3. Maintainer contract: the width fix is greppable and registered
// ---------------------------------------------------------------------------

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core/ has a parent directory (the repo root)")
        .to_path_buf()
}

fn load(rel: &str) -> Vec<String> {
    let path = repo_root().join(rel);
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read source {}: {e}", path.display()));
    let lines: Vec<String> = text.lines().map(str::to_owned).collect();
    assert!(
        lines.len() > 50,
        "{rel} has only {} lines; the file moved or was truncated",
        lines.len()
    );
    lines
}

const TERM_SRC: &str = "vendor/alacritty_terminal/src/term/mod.rs";
const MARKERS_TEST_SRC: &str = "core/tests/vendor_markers_blind.rs";

/// The marker this fix is required to carry, literally (see "MARKER WORDING"
/// in the header): case-sensitive, inside a `//` comment line.
const FIX_MARKER: &str = "Blackbird fix (re-apply on bump)";

/// A comment line carrying the literal [`FIX_MARKER`].
fn is_fix_marker(line: &str) -> bool {
    line.trim_start().starts_with("//") && line.contains(FIX_MARKER)
}

/// The looser repo convention (`vendor_markers_blind.rs`): any comment that
/// names Blackbird and then says `(re-apply on bump)`. Used only to describe
/// what a non-conforming item says instead.
fn is_any_reapply_comment(line: &str) -> bool {
    let trimmed = line.trim_start();
    if !trimmed.starts_with("//") {
        return false;
    }
    let lower = trimmed.to_ascii_lowercase();
    match (lower.find("blackbird"), lower.find("(re-apply on bump)")) {
        (Some(who), Some(phrase)) => who < phrase,
        _ => false,
    }
}

fn strip_visibility(s: &str) -> &str {
    for prefix in ["pub(crate) ", "pub(super) ", "pub "] {
        if let Some(rest) = s.strip_prefix(prefix) {
            return rest;
        }
    }
    s
}

fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start().len()
}

/// A `fn` / `const` / `static` declaration: `(kind, name)`.
fn declaration(line: &str) -> Option<(&'static str, String)> {
    let rest = strip_visibility(line.trim_start());
    for kind in ["fn", "const", "static"] {
        if let Some(after) = rest.strip_prefix(kind).and_then(|r| r.strip_prefix(' ')) {
            let name: String = after
                .chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect();
            if !name.is_empty() {
                return Some((kind, name));
            }
        }
    }
    None
}

/// Last line of the item declared at `item`: a one-line declaration (ends in
/// `;` or `}`) is its own extent, a `fn` runs to the closing brace at its own
/// indentation, a `const` to the line ending in `;`.
fn item_end(lines: &[String], item: usize, kind: &str) -> usize {
    let first = lines[item].trim_end();
    if first.ends_with(';') || first.ends_with('}') {
        item
    } else if kind == "fn" {
        let indent = " ".repeat(indent_of(&lines[item]));
        let close = format!("{indent}}}");
        (item + 1..lines.len())
            .find(|&i| lines[i] == close)
            .unwrap_or_else(|| panic!("fn at line {} never closes", item + 1))
    } else {
        (item..lines.len())
            .find(|&i| lines[i].trim_end().ends_with(';'))
            .unwrap_or_else(|| panic!("const at line {} never ends", item + 1))
    }
}

/// `[start, end]` of the attached doc/attribute block plus the item itself.
fn item_extent(lines: &[String], item: usize, kind: &str) -> (usize, usize) {
    let mut start = item;
    while start > 0 && !lines[start - 1].trim().is_empty() {
        start -= 1;
    }
    (start, item_end(lines, item, kind))
}

/// Index of the first line of the in-file test module (production code is
/// everything before it).
fn production_end(lines: &[String]) -> usize {
    lines
        .iter()
        .position(|l| l.starts_with("mod tests"))
        .unwrap_or(lines.len())
}

#[test]
fn every_piece_of_the_cluster_width_fix_is_marked_and_registered() {
    let lines = load(TERM_SRC);
    let registry = fs::read_to_string(repo_root().join(MARKERS_TEST_SRC))
        .unwrap_or_else(|e| panic!("cannot read {MARKERS_TEST_SRC}: {e}"));

    // Items whose NAME says they belong to the emoji-cluster width fix.
    const KEYWORDS: [&str; 6] = ["emoji", "zwj", "pictograph", "widen", "cluster", "skin"];
    // Scan only the production code: the in-file `#[cfg(test)] mod tests` is not part of the fix.
    let prod_end = production_end(&lines);
    assert!(
        prod_end > 1000,
        "precondition: {TERM_SRC} production code should be >1000 lines, `mod tests` found at \
         line {}",
        prod_end + 1
    );
    let mut found: Vec<(usize, &'static str, String)> = Vec::new();
    for (i, line) in lines.iter().enumerate().take(prod_end) {
        if let Some((kind, name)) = declaration(line) {
            let lower = name.to_ascii_lowercase();
            if KEYWORDS.iter().any(|k| lower.contains(k)) {
                found.push((i, kind, name));
            }
        }
    }

    // Rig preconditions: the scan saw the pieces the bug report names, and
    // nothing else is expected to be missing from the detector.
    let names: Vec<&str> = found.iter().map(|(_, _, n)| n.as_str()).collect();
    assert!(
        names.contains(&"is_emoji_modifier") && names.contains(&"is_pictographic"),
        "precondition: the scan must find `is_emoji_modifier` and `is_pictographic` in {TERM_SRC}; \
         found {names:?}"
    );
    assert!(
        found.len() >= 3,
        "precondition: expected the predicates plus at least one join/widen helper, found {names:?}"
    );

    let mut not_literal: Vec<String> = Vec::new();
    let mut unregistered: Vec<String> = Vec::new();
    for (i, kind, name) in &found {
        let (start, end) = item_extent(&lines, *i, kind);
        let span = &lines[start..=end];
        if !span.iter().any(|l| is_fix_marker(l)) {
            let said: Vec<String> = span
                .iter()
                .filter(|l| is_any_reapply_comment(l))
                .map(|l| l.trim().chars().take(48).collect::<String>())
                .collect();
            not_literal.push(format!(
                "{TERM_SRC}:{} `{kind} {name}` (lines {}-{}) says {said:?} instead",
                i + 1,
                start + 1,
                end + 1
            ));
        }
        if !registry.contains(&format!("\"{kind} {name}\"")) {
            unregistered.push(format!("{kind} {name}"));
        }
    }
    assert_eq!(
        not_literal,
        Vec::<String>::new(),
        "every emoji-cluster item in the vendored term/mod.rs must carry the literal comment \
         `{FIX_MARKER}` (the word `fix`, not `addition` or `fork change`): the sibling pieces of \
         this fix use it, and a re-vendor greps for it"
    );
    assert_eq!(
        unregistered,
        Vec::<String>::new(),
        "every emoji-cluster item must be listed as a `Site` (needle: \"fn name\") in \
         {MARKERS_TEST_SRC}, which is what keeps it from losing its marker later"
    );
}

#[test]
fn the_cluster_branch_in_handler_input_is_marked() {
    let lines = load(TERM_SRC);
    let impls: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with("impl") && l.contains("Handler for Term<"))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(
        impls.len(),
        1,
        "precondition: exactly one `impl ... Handler for Term<..>` in {TERM_SRC}, found {impls:?}"
    );
    let impl_end = (impls[0] + 1..lines.len())
        .find(|&i| lines[i] == "}")
        .expect("Handler impl closes");
    let inputs: Vec<usize> = (impls[0]..impl_end)
        .filter(|&i| declaration(&lines[i]).is_some_and(|(k, n)| k == "fn" && n == "input"))
        .collect();
    assert_eq!(
        inputs.len(),
        1,
        "precondition: exactly one `fn input` in the Handler impl, found {inputs:?}"
    );
    let end = item_end(&lines, inputs[0], "fn");

    // Each literal marker comment is followed by its continuation lines;
    // collect each such block as one lowercase string.
    let mut blocks: Vec<String> = Vec::new();
    let mut i = inputs[0];
    while i <= end {
        if is_fix_marker(&lines[i]) {
            let mut block = String::new();
            let mut j = i;
            while j <= end && lines[j].trim_start().starts_with("//") {
                block.push_str(&lines[j].to_ascii_lowercase());
                block.push(' ');
                j += 1;
            }
            blocks.push(block);
            i = j;
        } else {
            i += 1;
        }
    }

    assert!(
        !blocks.is_empty(),
        "precondition: `Handler::input` (lines {}-{}) must carry at least one literal \
         `{FIX_MARKER}` comment",
        inputs[0] + 1,
        end + 1
    );
    // The sibling VS16 / keycap promotion in the same function carries its own
    // marker, and that one already talks about "emoji" and "skin-tone" widths.
    // So the keywords must be the ones only the ZWJ / pictograph-continuation
    // branch uses, or deleting the cluster branch's marker would go unnoticed
    // behind the VS16 one.
    let about_clusters = blocks
        .iter()
        .any(|b| ["zwj", "200d", "pictograph"].iter().any(|k| b.contains(k)));
    assert!(
        about_clusters,
        "the ZWJ / pictograph cluster-continuation branch inside `Handler::input` (lines \
         {}-{}) has no literal `{FIX_MARKER}` comment of its own (one that mentions the ZWJ or \
         the pictograph that continues a cluster; the VS16 marker next to it does not count); \
         marker blocks found: {blocks:?}",
        inputs[0] + 1,
        end + 1
    );
}

// ---------------------------------------------------------------------------
// 4. One previous-cell lookup
// ---------------------------------------------------------------------------

/// A source line without its trailing `//` comment (comments may legitimately
/// talk about the pending-wrap flag; only code counts).
fn code_part(line: &str) -> &str {
    match line.find("//") {
        Some(at) => &line[..at],
        None => line,
    }
}

/// True when `code` READS the pending-wrap flag (`input_needs_wrap`): any
/// mention that is not the left-hand side of a plain assignment. Cursor
/// motion (`input_needs_wrap = false; column = column.saturating_sub(n)`)
/// writes the flag and is not a lookup of the previous cell.
fn reads_pending_wrap(code: &str) -> bool {
    const FLAG: &str = "input_needs_wrap";
    let mut rest = code;
    while let Some(at) = rest.find(FLAG) {
        let after = rest[at + FLAG.len()..].trim_start();
        let is_assignment = after.starts_with('=') && !after.starts_with("==");
        if !is_assignment {
            return true;
        }
        rest = &rest[at + FLAG.len()..];
    }
    false
}

/// `(name, 1-based declaration line)` of every `fn` in `lines[..prod_end]`
/// whose CODE both reads the pending-wrap flag (`input_needs_wrap`) and steps
/// a column back (`saturating_sub(1)`): that pair is "the cell before the
/// cursor": with a pending wrap the cursor still sits on the last written
/// cell, otherwise one column to the left of the cursor.
fn previous_cell_lookups(lines: &[String], prod_end: usize) -> Vec<(String, usize)> {
    let mut out: Vec<(String, usize)> = Vec::new();
    for i in 0..prod_end {
        let Some(("fn", name)) = declaration(&lines[i]) else {
            continue;
        };
        let end = item_end(lines, i, "fn").min(prod_end.saturating_sub(1));
        let code: Vec<&str> = lines[i..=end].iter().map(|l| code_part(l)).collect();
        let reads_wrap = code.iter().any(|l| reads_pending_wrap(l));
        let steps_back = code.iter().any(|l| l.contains("saturating_sub(1)"));
        if reads_wrap && steps_back {
            out.push((name, i + 1));
        }
    }
    out
}

#[test]
fn the_lookup_detector_counts_functions_not_mentions() {
    // Rig for the static test below: the scanner must count a function once
    // however often it repeats the idiom, ignore comments, ignore a function
    // that only has one half of the idiom, see one-line functions, and tell a
    // read of the flag (also `== false`) from a write of it.
    let src = r#"
impl Foo {
    /// Mentions input_needs_wrap and saturating_sub(1) in docs only.
    fn doc_only(&self) {
        // input_needs_wrap saturating_sub(1)
        let x = 1;
    }

    fn lookup_a(&self) -> usize {
        let mut column = self.cursor.column;
        if !self.cursor.input_needs_wrap {
            column = column.saturating_sub(1);
        }
        if self.is_spacer(column) {
            column = column.saturating_sub(1);
        }
        column
    }

    fn only_wrap(&self) -> bool {
        self.cursor.input_needs_wrap
    }

    fn only_step(&self, c: usize) -> usize {
        c.saturating_sub(1)
    }

    fn one_liner(&self) -> usize { self.cursor.input_needs_wrap as usize + 1usize.saturating_sub(1) }

    fn lookup_b(&self) -> usize {
        let wrapped = self.cursor.input_needs_wrap;
        if wrapped { 0 } else { self.column.saturating_sub(1) }
    }

    fn cursor_motion(&mut self, n: usize) {
        self.cursor.input_needs_wrap = false;
        self.cursor.column = self.cursor.column.saturating_sub(n);
    }

    fn compares_flag(&self) -> usize {
        if self.cursor.input_needs_wrap == false { self.column.saturating_sub(1) } else { 0 }
    }
}
"#;
    let lines: Vec<String> = src.lines().map(str::to_owned).collect();
    let found: Vec<(String, usize)> = previous_cell_lookups(&lines, lines.len());
    let names: Vec<&str> = found.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(
        names,
        vec!["lookup_a", "one_liner", "lookup_b", "compares_flag"],
        "detector self-check: functions that READ the flag and step a column back, in source \
         order (a function that only writes the flag, like cursor motion, is not a lookup); \
         found {found:?}"
    );

    // And a production boundary: a copy past `prod_end` does not count.
    let mut with_tests = lines.clone();
    let prod_end = with_tests.len();
    with_tests.push("mod tests {".to_string());
    with_tests.extend(lines.iter().cloned());
    with_tests.push("}".to_string());
    assert_eq!(
        previous_cell_lookups(&with_tests, prod_end).len(),
        4,
        "detector self-check: code after the production boundary must not be counted"
    );
}

#[test]
fn the_previous_cell_lookup_lives_in_one_function() {
    let lines = load(TERM_SRC);
    let prod_end = production_end(&lines);
    assert!(
        prod_end > 1000,
        "precondition: {TERM_SRC} production code should be >1000 lines, `mod tests` found at \
         line {}",
        prod_end + 1
    );
    // Rig: the scanner can see the code it is meant to police. `Handler::input`
    // is the function that applies a joined scalar; it must be in the scan and
    // it must still handle the pending wrap (the lookup is allowed to live
    // elsewhere, but `input` is where the cell is used).
    let input_lines: Vec<usize> = (0..prod_end)
        .filter(|&i| declaration(&lines[i]).is_some_and(|(k, n)| k == "fn" && n == "input"))
        .collect();
    assert_eq!(
        input_lines.len(),
        1,
        "precondition: exactly one `fn input` in the production half of {TERM_SRC}, found \
         {input_lines:?}"
    );
    let input_end = item_end(&lines, input_lines[0], "fn");
    assert!(
        lines[input_lines[0]..=input_end]
            .iter()
            .any(|l| code_part(l).contains("input_needs_wrap")),
        "precondition: `Handler::input` (lines {}-{}) reads the pending-wrap flag; the scan \
         would be looking at the wrong function otherwise",
        input_lines[0] + 1,
        input_end + 1
    );

    let lookups = previous_cell_lookups(&lines, prod_end);
    assert!(
        lookups.len() <= 1,
        "the cell before the cursor (pending-wrap flag + step one column back) is computed in \
         {} separate functions of {TERM_SRC}: {lookups:?}. The join decision and the cell the \
         joined scalar is pushed onto must come from ONE helper, otherwise they can disagree \
         (a scalar judged as joining one cell and then pushed onto, or dropped by, another)",
        lookups.len()
    );
}
