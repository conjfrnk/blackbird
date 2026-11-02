//! Blind regression tests for ffi-3: a guest program's palette RESET
//! (OSC 104 / OSC 110 / OSC 111) must not wipe the theme the host app
//! pushed with `bb_term_set_named_color`.
//!
//! Author had no access to the implementation; the contract consulted
//! was `core/include/BBCore.h`, the sibling blind suites
//! (`default_palette_blind.rs`, `color_ffi_blind.rs`, `color_query.rs`)
//! and the xterm control-sequence conventions.
//!
//! Contract under test
//! -------------------
//! The host (the Swift `PaletteApplier`) pushes the user's theme into the
//! core by writing slots through `bb_term_set_named_color`: 0..=15 are the
//! ANSI colors, 256 = default foreground, 257 = default background. That
//! pushed theme is, from the point of view of every program running in the
//! terminal, "the terminal's default colors".
//!
//! xterm defines the reset sequences relative to the terminal's configured
//! defaults:
//!   * OSC 110 — reset the dynamic text-foreground color to its default
//!   * OSC 111 — reset the dynamic background color to its default
//!   * OSC 104 — reset the palette (all entries, or the listed indexes)
//!
//! "Its default" in Blackbird is the user's theme, NOT a hard-coded xterm
//! table. So after any of these resets:
//!   * the default fg / bg seen in snapshot cells is the theme's fg / bg,
//!   * ANSI colors resolve to the theme's ANSI colors,
//!   * OSC 10 / OSC 11 `?` color-query probes answer with the theme's
//!     colors (programs such as nvim / bat use that answer to decide
//!     light vs dark), and
//!   * a program that SET a color itself (OSC 4 / 10 / 11) and then resets
//!     it returns to the theme color — not to black / 0xEEEEEE / xterm.
//!
//! Observed bug (pre-fix): after `printf '\e]111\a'` the default background
//! becomes 0x000000, after `\e]110\a` the default foreground becomes
//! 0xEEEEEE, and `\e]104\a` reverts the ANSI palette to the xterm table.
//! A light theme turns into white-on-black for the rest of the session.
//!
//! Cost: every test uses one 80x24 terminal (1 920 cells x 20 B) and a few
//! dozen short escape sequences — microseconds, a few tens of KiB.

use blackbird_core::*;
use std::ffi::c_void;
use std::fmt::Write as _;
use std::sync::Mutex;

// ---------- the theme the "host app" pushes ------------------------

/// A light theme. Every value differs from the built-in xterm/tango
/// defaults (fg 0xEEEEEE, bg 0x000000, ANSI tango table) so that a
/// fall-back to the defaults can never be mistaken for the theme.
const THEME_FG: u32 = 0x2B3A4C;
const THEME_BG: u32 = 0xF5F0E1;
const THEME_ANSI: [u32; 16] = [
    0x101820, 0xB3261E, 0x2E7D32, 0x9A6700, 0x1F4E9C, 0x7B3F99, 0x00796B, 0xD8D2C4, 0x4A5560,
    0xD84315, 0x558B2F, 0xB28704, 0x3F7BD0, 0x9C5FB5, 0x1B9AA0, 0xFFF8E7,
];

/// A second, different theme — the "user switched theme" case.
const THEME2_FG: u32 = 0xC0CAF5;
const THEME2_BG: u32 = 0x1A1B26;
const THEME2_ANSI: [u32; 16] = [
    0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6, 0x414868,
    0xFF8FA3, 0xB0E27C, 0xF0C27A, 0x8DB4FF, 0xCCB0FF, 0x90DDFF, 0xC0CAF5,
];

// The unsurprising SGR slots we additionally probe through the *named*
// colour arms of the resolver (the indexed arm is probed for all 16).
const SGR_FG_RED: &[u8] = b"\x1b[31m"; // ANSI slot 1
const SGR_FG_BRIGHT_BLUE: &[u8] = b"\x1b[94m"; // ANSI slot 12
const SGR_BG_GREEN: &[u8] = b"\x1b[42m"; // ANSI slot 2

// ---------- harness ------------------------------------------------

#[derive(Default)]
struct Sink {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
}

unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = &*(ctx as *const Sink);
    let bytes = if ev.len > 0 && !ev.payload.is_null() {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    sink.events.lock().unwrap().push((ev.kind as u32, bytes));
}

/// Everything the tests can observe about the terminal's *current* colors,
/// gathered only through the public FFI (snapshot cells).
#[derive(PartialEq)]
struct Look {
    /// fg of a glyph written with no SGR (the "default foreground").
    default_fg: u32,
    /// bg of a glyph written with no SGR.
    default_bg: u32,
    /// bg of a cell nothing was ever written to (what the renderer paints
    /// across the whole window for a default-background cell).
    blank_bg: u32,
    /// fg of a glyph written with `SGR 38;5;N`, N = 0..=15.
    indexed_fg: [u32; 16],
    /// fg via the *named* arm, `SGR 31` (ANSI 1).
    named_fg_red: u32,
    /// fg via the named arm, `SGR 94` (ANSI 12).
    named_fg_bright_blue: u32,
    /// bg via the named arm, `SGR 42` (ANSI 2).
    named_bg_green: u32,
}

impl Look {
    /// What the terminal must look like when `fg`/`bg`/`ansi` is the active
    /// theme.
    fn of_theme(fg: u32, bg: u32, ansi: &[u32; 16]) -> Look {
        Look {
            default_fg: fg,
            default_bg: bg,
            blank_bg: bg,
            indexed_fg: *ansi,
            named_fg_red: ansi[1],
            named_fg_bright_blue: ansi[12],
            named_bg_green: ansi[2],
        }
    }

    /// Hex, one fact per line, so `assert_eq!` on two of these prints a
    /// readable line diff instead of decimal noise.
    fn describe(&self) -> String {
        let mut s = String::new();
        let _ = writeln!(s, "default fg      = {:#08x}", self.default_fg);
        let _ = writeln!(s, "default bg      = {:#08x}", self.default_bg);
        let _ = writeln!(s, "blank-cell bg   = {:#08x}", self.blank_bg);
        for (i, c) in self.indexed_fg.iter().enumerate() {
            let _ = writeln!(s, "SGR 38;5;{i:<2}     = {c:#08x}");
        }
        let _ = writeln!(s, "SGR 31  (named) = {:#08x}", self.named_fg_red);
        let _ = writeln!(s, "SGR 94  (named) = {:#08x}", self.named_fg_bright_blue);
        let _ = writeln!(s, "SGR 42  (named) = {:#08x}", self.named_bg_green);
        s
    }
}

struct Rig {
    term: *mut BBTerm,
    // Boxed so the address handed to the C callback stays stable.
    sink: Box<Sink>,
}

impl Rig {
    /// A fresh 80x24 terminal with color-query replies enabled and the
    /// light theme pushed.
    fn with_theme() -> Rig {
        let rig = Rig::bare();
        rig.push_theme(THEME_FG, THEME_BG, &THEME_ANSI);
        rig
    }

    fn bare() -> Rig {
        let sink = Box::new(Sink::default());
        let term = unsafe { bb_term_new(80, 24, 1000) };
        assert_ne!(term as usize, 0, "bb_term_new(80,24,1000) returned null");
        unsafe {
            bb_term_set_event_cb(term, Some(cb), &*sink as *const Sink as *mut c_void);
            bb_term_set_color_query_enabled(term, 1);
        }
        Rig { term, sink }
    }

    /// Exactly what the host does when a theme is applied: ANSI 0..=15,
    /// then the default foreground (256) and background (257).
    fn push_theme(&self, fg: u32, bg: u32, ansi: &[u32; 16]) {
        for (slot, rgb) in ansi.iter().enumerate() {
            unsafe { bb_term_set_named_color(self.term, slot as u16, *rgb) };
        }
        unsafe {
            bb_term_set_named_color(self.term, 256, fg);
            bb_term_set_named_color(self.term, 257, bg);
        }
    }

    fn feed(&self, seq: &[u8]) {
        unsafe { bb_term_input(self.term, seq.as_ptr(), seq.len()) };
    }

    /// (fg, bg) of cell (row, col) in a fresh snapshot, upper byte checked.
    fn cell(&self, row: usize, col: usize) -> (u32, u32) {
        unsafe {
            let snap = bb_term_take_snapshot(self.term);
            assert_ne!(snap as usize, 0, "snapshot must succeed");
            let cols = (*snap).cols as usize;
            let rows = (*snap).rows as usize;
            assert!(
                row < rows && col < cols,
                "cell ({row},{col}) outside {rows}x{cols} snapshot"
            );
            assert_eq!((*snap).cells_len, rows * cols, "cells_len != rows*cols");
            let c = &*(*snap).cells.add(row * cols + col);
            let out = (c.fg, c.bg);
            bb_snap_release(snap);
            assert_eq!(
                (out.0 | out.1) & 0xFF00_0000,
                0,
                "cell colors must be 0x00RRGGBB, got fg={:#010x} bg={:#010x}",
                out.0,
                out.1
            );
            out
        }
    }

    /// Home the cursor, write `A` under `sgr`, restore SGR, return the
    /// (fg, bg) of that glyph's cell.
    fn glyph(&self, sgr: &[u8]) -> (u32, u32) {
        let mut seq = b"\x1b[H".to_vec();
        seq.extend_from_slice(sgr);
        seq.push(b'A');
        seq.extend_from_slice(b"\x1b[0m");
        self.feed(&seq);
        self.cell(0, 0)
    }

    fn look(&self) -> Look {
        let (default_fg, default_bg) = self.glyph(b"");
        // Row 12, col 60 is never written by any test.
        let blank_bg = self.cell(12, 60).1;
        let mut indexed_fg = [0u32; 16];
        for (n, slot) in indexed_fg.iter_mut().enumerate() {
            *slot = self.glyph(format!("\x1b[38;5;{n}m").as_bytes()).0;
        }
        Look {
            default_fg,
            default_bg,
            blank_bg,
            indexed_fg,
            named_fg_red: self.glyph(SGR_FG_RED).0,
            named_fg_bright_blue: self.glyph(SGR_FG_BRIGHT_BLUE).0,
            named_bg_green: self.glyph(SGR_BG_GREEN).1,
        }
    }

    /// Answer to an OSC `id` (10 = fg, 11 = bg) `?` probe, as 8-bit
    /// channels. Replies are `ESC ] id ; rgb:RRRR/GGGG/BBBB ST`.
    fn query_rgb(&self, id: u32) -> u32 {
        self.sink.events.lock().unwrap().clear();
        self.feed(format!("\x1b]{id};?\x1b\\").as_bytes());
        let writes: Vec<Vec<u8>> = self
            .sink
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|(k, _)| *k == BBEventKind::PtyWrite as u32)
            .map(|(_, v)| v.clone())
            .collect();
        assert_eq!(
            writes.len(),
            1,
            "OSC {id} ? with queries enabled must produce exactly one reply, got {writes:?}"
        );
        let s = std::str::from_utf8(&writes[0]).expect("reply must be UTF-8");
        let prefix = format!("\x1b]{id};rgb:");
        let body = s
            .strip_prefix(prefix.as_str())
            .unwrap_or_else(|| panic!("reply {s:?} lacks prefix {prefix:?}"));
        let body = body
            .strip_suffix("\x1b\\")
            .or_else(|| body.strip_suffix('\x07'))
            .unwrap_or_else(|| panic!("reply {s:?} lacks a terminator"));
        let ch: Vec<u16> = body
            .split('/')
            .map(|h| u16::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex {h:?}")))
            .collect();
        assert_eq!(ch.len(), 3, "expected 3 channels in {s:?}");
        // 8-bit -> 16-bit replication ("ab" -> "abab"): take the high byte.
        let (r, g, b) = (
            (ch[0] >> 8) as u32,
            (ch[1] >> 8) as u32,
            (ch[2] >> 8) as u32,
        );
        (r << 16) | (g << 8) | b
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        unsafe { bb_term_free(self.term) };
    }
}

/// Rec. 709 relative luminance of 0xRRGGBB in [0, 1] (gamma-encoded values;
/// good enough to separate "light" from "dark" for a probe).
fn luma(rgb: u32) -> f64 {
    let r = ((rgb >> 16) & 0xFF) as f64 / 255.0;
    let g = ((rgb >> 8) & 0xFF) as f64 / 255.0;
    let b = (rgb & 0xFF) as f64 / 255.0;
    0.2126 * r + 0.7152 * g + 0.0722 * b
}

#[track_caller]
fn assert_look(rig: &Rig, expected: &Look, what: &str) {
    let got = rig.look();
    assert!(
        got == *expected,
        "{what}\n--- expected (pushed theme) ---\n{}--- got ---\n{}",
        expected.describe(),
        got.describe()
    );
}

// ---------- control: the harness observes the pushed theme ---------

#[test]
fn control_pushed_theme_is_observable_before_any_reset() {
    // Not the bug: proves that every probe the other tests use sees the
    // pushed theme when no reset has happened, so a later mismatch is
    // attributable to the reset and not to a blind harness.
    let rig = Rig::with_theme();
    assert_look(
        &rig,
        &Look::of_theme(THEME_FG, THEME_BG, &THEME_ANSI),
        "pushed light theme must be visible through snapshot cells",
    );
    assert_eq!(
        rig.query_rgb(10),
        THEME_FG,
        "OSC 10 ? must answer with the pushed foreground"
    );
    assert_eq!(
        rig.query_rgb(11),
        THEME_BG,
        "OSC 11 ? must answer with the pushed background"
    );
}

#[test]
fn control_program_set_colors_are_observable() {
    // Not the bug: proves OSC 10 / 11 / 4 SET is live, so the
    // "set then reset" tests below cannot pass vacuously by the set having
    // been ignored.
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]11;#102030\x07\x1b]10;#304050\x07\x1b]4;1;#aabbcc\x07");
    let look = rig.look();
    assert_eq!(look.default_bg, 0x102030, "OSC 11 set must change bg");
    assert_eq!(look.blank_bg, 0x102030, "OSC 11 set must change blank bg");
    assert_eq!(look.default_fg, 0x304050, "OSC 10 set must change fg");
    assert_eq!(
        look.indexed_fg[1], 0xAABBCC,
        "OSC 4;1 set must change ANSI 1"
    );
    assert_eq!(
        look.named_fg_red, 0xAABBCC,
        "OSC 4;1 set must change SGR 31"
    );
    assert_eq!(
        rig.query_rgb(11),
        0x102030,
        "OSC 11 ? must follow OSC 11 set"
    );
    assert_eq!(
        rig.query_rgb(10),
        0x304050,
        "OSC 10 ? must follow OSC 10 set"
    );
}

// ---------- the bug: bare resets on an untouched themed terminal ---

#[test]
fn osc_111_bel_keeps_theme_background() {
    // printf '\e]111\a' — the headline repro: bg went to 0x000000.
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]111\x07");
    assert_look(
        &rig,
        &Look::of_theme(THEME_FG, THEME_BG, &THEME_ANSI),
        "OSC 111 (BEL) must leave the host-pushed theme intact",
    );
}

#[test]
fn osc_111_st_keeps_theme_background() {
    // Same reset, ESC \ (ST) terminator.
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]111\x1b\\");
    assert_look(
        &rig,
        &Look::of_theme(THEME_FG, THEME_BG, &THEME_ANSI),
        "OSC 111 (ST) must leave the host-pushed theme intact",
    );
}

#[test]
fn osc_110_keeps_theme_foreground() {
    // printf '\e]110\a' — fg went to 0xEEEEEE.
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]110\x07");
    assert_look(
        &rig,
        &Look::of_theme(THEME_FG, THEME_BG, &THEME_ANSI),
        "OSC 110 must leave the host-pushed theme intact",
    );
}

#[test]
fn osc_104_without_args_keeps_theme_ansi_palette() {
    // printf '\e]104\a' — ANSI/256 palette reverted to xterm.
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]104\x07");
    assert_look(
        &rig,
        &Look::of_theme(THEME_FG, THEME_BG, &THEME_ANSI),
        "OSC 104 (no args) must leave the host-pushed theme intact",
    );
}

#[test]
fn osc_104_with_indexes_keeps_theme_ansi_slots() {
    // Targeted form: reset ANSI 1 and 12 only.
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]104;1;12\x07");
    assert_look(
        &rig,
        &Look::of_theme(THEME_FG, THEME_BG, &THEME_ANSI),
        "OSC 104;1;12 must leave the host-pushed theme intact",
    );
}

#[test]
fn all_three_resets_together_keep_theme() {
    // A script that "cleans up after itself" typically emits all three.
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]104\x07\x1b]110\x07\x1b]111\x07");
    assert_look(
        &rig,
        &Look::of_theme(THEME_FG, THEME_BG, &THEME_ANSI),
        "OSC 104 + 110 + 111 must leave the host-pushed theme intact",
    );
}

// ---------- the bug: set-then-reset returns to the THEME -----------

#[test]
fn osc_111_after_program_set_returns_to_theme_background() {
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]11;#102030\x07");
    assert_eq!(
        rig.look().default_bg,
        0x102030,
        "precondition: OSC 11 set must take effect"
    );
    rig.feed(b"\x1b]111\x07");
    let look = rig.look();
    assert_eq!(
        look.default_bg, THEME_BG,
        "OSC 111 after OSC 11 set: written-cell bg must be the theme bg, got {:#08x}",
        look.default_bg
    );
    assert_eq!(
        look.blank_bg, THEME_BG,
        "OSC 111 after OSC 11 set: blank-cell bg must be the theme bg, got {:#08x}",
        look.blank_bg
    );
}

#[test]
fn osc_110_after_program_set_returns_to_theme_foreground() {
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]10;#304050\x07");
    assert_eq!(
        rig.look().default_fg,
        0x304050,
        "precondition: OSC 10 set must take effect"
    );
    rig.feed(b"\x1b]110\x07");
    let look = rig.look();
    assert_eq!(
        look.default_fg, THEME_FG,
        "OSC 110 after OSC 10 set: fg must be the theme fg, got {:#08x}",
        look.default_fg
    );
}

#[test]
fn osc_104_after_program_set_returns_to_theme_ansi() {
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]4;1;#aabbcc;12;#ddeeff\x07");
    let before = rig.look();
    assert_eq!(
        (before.indexed_fg[1], before.indexed_fg[12]),
        (0xAABBCC, 0xDDEEFF),
        "precondition: OSC 4 set must take effect"
    );
    rig.feed(b"\x1b]104\x07");
    assert_look(
        &rig,
        &Look::of_theme(THEME_FG, THEME_BG, &THEME_ANSI),
        "OSC 104 after OSC 4 set must return ANSI colors to the theme",
    );
}

#[test]
fn osc_104_with_index_after_program_set_returns_that_slot_to_theme() {
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]4;1;#aabbcc;12;#ddeeff\x07");
    rig.feed(b"\x1b]104;1\x07");
    let look = rig.look();
    assert_eq!(
        look.indexed_fg[1], THEME_ANSI[1],
        "OSC 104;1 must return ANSI 1 to the theme, got {:#08x}",
        look.indexed_fg[1]
    );
    assert_eq!(
        look.named_fg_red, THEME_ANSI[1],
        "OSC 104;1 must return SGR 31 to the theme, got {:#08x}",
        look.named_fg_red
    );
    // The slot that was NOT named in the reset keeps the program's value.
    assert_eq!(
        look.indexed_fg[12], 0xDDEEFF,
        "OSC 104;1 must not touch ANSI 12, got {:#08x}",
        look.indexed_fg[12]
    );
}

// ---------- the bug: color-query probes (light/dark detection) -----

#[test]
fn color_query_probes_answer_with_theme_after_resets() {
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]110\x07\x1b]111\x07\x1b]104\x07");
    let fg = rig.query_rgb(10);
    let bg = rig.query_rgb(11);
    assert_eq!(
        fg, THEME_FG,
        "OSC 10 ? after resets: expected theme fg {THEME_FG:#08x}, got {fg:#08x}"
    );
    assert_eq!(
        bg, THEME_BG,
        "OSC 11 ? after resets: expected theme bg {THEME_BG:#08x}, got {bg:#08x}"
    );
    assert!(
        luma(bg) > 0.5 && luma(fg) < 0.5,
        "a light theme must still probe as light after resets: \
         bg luma={:.3} (bg {bg:#08x}), fg luma={:.3} (fg {fg:#08x})",
        luma(bg),
        luma(fg)
    );
}

#[test]
fn color_query_after_program_set_and_reset_answers_with_theme() {
    let rig = Rig::with_theme();
    rig.feed(b"\x1b]11;#102030\x07\x1b]10;#304050\x07");
    assert_eq!(rig.query_rgb(11), 0x102030, "precondition: bg set visible");
    assert_eq!(rig.query_rgb(10), 0x304050, "precondition: fg set visible");
    rig.feed(b"\x1b]111\x07\x1b]110\x07");
    let bg = rig.query_rgb(11);
    let fg = rig.query_rgb(10);
    assert_eq!(
        bg, THEME_BG,
        "OSC 11 ? after set+111: expected theme bg {THEME_BG:#08x}, got {bg:#08x}"
    );
    assert_eq!(
        fg, THEME_FG,
        "OSC 10 ? after set+110: expected theme fg {THEME_FG:#08x}, got {fg:#08x}"
    );
}

// ---------- `reset(1)` ---------------------------------------------

#[test]
fn reset_command_sequence_keeps_theme() {
    // xterm-256color's reset string is RIS followed by OSC 104
    // (`\Ec\E]104\007`) — what `reset` types into the tab.
    let rig = Rig::with_theme();
    rig.feed(b"\x1bc\x1b]104\x07");
    assert_look(
        &rig,
        &Look::of_theme(THEME_FG, THEME_BG, &THEME_ANSI),
        "RIS + OSC 104 (the `reset` command) must leave the host-pushed theme intact",
    );
}

// ---------- a naive fix must not freeze the first theme ------------

#[test]
fn reset_returns_to_most_recently_pushed_theme() {
    // The user switches theme (host pushes theme 2). A later reset must
    // return to THEME 2, not to the first theme ever pushed and not to the
    // xterm defaults.
    let rig = Rig::with_theme();
    rig.push_theme(THEME2_FG, THEME2_BG, &THEME2_ANSI);
    assert_look(
        &rig,
        &Look::of_theme(THEME2_FG, THEME2_BG, &THEME2_ANSI),
        "precondition: second pushed theme must be visible immediately",
    );
    rig.feed(b"\x1b]11;#102030\x07\x1b]10;#304050\x07\x1b]4;1;#aabbcc\x07");
    rig.feed(b"\x1b]104\x07\x1b]110\x07\x1b]111\x07");
    assert_look(
        &rig,
        &Look::of_theme(THEME2_FG, THEME2_BG, &THEME2_ANSI),
        "after a theme switch, resets must return to the NEW theme",
    );
}
