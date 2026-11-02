//! Blind regression tests: `bb_term_clear_all` (the app's Cmd-K) must be
//! transparent to a program's escape sequence that is split across two
//! `bb_term_input` calls.
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and
//! documented terminal conventions only, never the implementation.
//!
//! Contract under test
//! -------------------
//! Cmd-K is a UI action, not bytes from the program. It wipes the visible
//! screen and the scrollback and homes the cursor; it must not change how the
//! program's byte stream is interpreted. PTY reads are chunked arbitrarily, so
//! a chunk boundary (and therefore a Cmd-K) can land anywhere inside a CSI,
//! an OSC (8 / title) or a multi-byte UTF-8 character. Whatever the split,
//! the observable result must be what a clean terminal would show for the
//! uninterrupted stream:
//!   - the tail of an interrupted sequence is NOT printed as literal text
//!     (`";196mHELLO"` on screen instead of `"HELLO"`);
//!   - the SGR colour the interrupted CSI would have set is still applied;
//!   - a partially received OSC 8 link target is not dispatched truncated, so
//!     the text that follows is linked to the FULL URL (a shortened prefix of
//!     the host/path is a wrong destination, worse than no link);
//!   - a UTF-8 character split by the clear still decodes to that character.
//!
//! The expected value in every test is measured, not assumed: a fresh
//! terminal fed the whole stream with no `bb_term_clear_all` anywhere (the
//! "control"). The terminal under test first shows junk and has scrollback,
//! gets the head of the stream, is cleared, then gets the tail. Because the
//! clear wipes everything that was there before, its grid must equal the
//! control's.
//!
//! Sequences deliberately chosen so the "right" answer does not depend on
//! WHEN a clear is applied relative to the sequence (no cursor addressing):
//! SGR, OSC 8 hyperlinks, OSC window title, UTF-8.
//!
//! Rig preconditions (asserted, so a green run cannot mean "the test saw
//! nothing"):
//!   1. `rig_controls_render_the_expected_visible_text`: each control stream
//!      renders exactly its visible text at the top-left, in the expected
//!      colour / with the expected full link URL, and the cell after a link
//!      is unlinked.
//!   2. `rig_clear_all_at_a_sequence_boundary_*`: with NO split, clear_all
//!      really wipes screen + scrollback (history > 0 beforehand, 0 after)
//!      and the stream rendered afterwards equals the control. This pins that
//!      the failures below are caused by the MID-sequence timing only.
//!   3. Every split run asserts the terminal had scrollback (`history > 0`)
//!      and visible junk before the clear, so a "no-op" clear cannot pass.
//!
//! Pre-flight cost: 40x5 grids, 100 lines of scrollback, a few KB each.
//! Roughly 100 split runs per test, each creating and freeing two terminals.
//! No sleeps, no threads, no I/O.

use blackbird_core as bc;
use std::ffi::CStr;

const COLS: u16 = 40;
const ROWS: u16 = 5;
const SCROLLBACK: u32 = 100;
/// `BBCell::flags` bits from the header: WIDE_CHAR_SPACER (1 << 7) and
/// LEADING_WIDE_CHAR_SPACER (1 << 8). Cells carrying either are not text.
const SPACER_BITS: u16 = (1 << 7) | (1 << 8);

/// Output that leaves junk on every visible row AND pushes lines into
/// scrollback (12 lines through a 5-row screen). Plain text and CRLF only: no
/// escape sequences, so it can never interact with the split sequence.
fn prefill() -> Vec<u8> {
    let mut v = Vec::new();
    for i in 0..12 {
        v.extend_from_slice(format!("PRE-CLEAR-LINE-{i:02}\r\n").as_bytes());
    }
    v
}

fn new_term() -> *mut bc::BBTerm {
    unsafe {
        let t = bc::bb_term_new(COLS, ROWS, SCROLLBACK);
        assert!(
            !t.is_null(),
            "bb_term_new({COLS}, {ROWS}, {SCROLLBACK}) returned null"
        );
        t
    }
}

fn feed(term: *mut bc::BBTerm, bytes: &[u8]) {
    if bytes.is_empty() {
        return;
    }
    unsafe { bc::bb_term_input(term, bytes.as_ptr(), bytes.len()) };
}

fn clear_all(term: *mut bc::BBTerm) {
    unsafe { bc::bb_term_clear_all(term) };
}

fn esc(bytes: &[u8]) -> String {
    bytes.escape_ascii().to_string()
}

/// Everything a test needs from one snapshot, copied out so the snapshot can
/// be released immediately.
struct Grid {
    ch: Vec<u32>,
    spacer: Vec<bool>,
    fg: Vec<u32>,
    link: Vec<Option<String>>,
    cursor_row: u16,
    cursor_col: u16,
    history: u32,
}

fn capture(term: *mut bc::BBTerm) -> Grid {
    unsafe {
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
        let cols = (*snap).cols as usize;
        let rows = (*snap).rows as usize;
        assert_eq!(cols, COLS as usize, "snapshot cols");
        assert_eq!(rows, ROWS as usize, "snapshot rows");
        assert_eq!((*snap).cells_len, cols * rows, "snapshot cells_len");
        let mut ch = Vec::with_capacity(cols * rows);
        let mut spacer = Vec::with_capacity(cols * rows);
        let mut fg = Vec::with_capacity(cols * rows);
        let mut link = Vec::with_capacity(cols * rows);
        for r in 0..rows {
            for c in 0..cols {
                let cell = &*(*snap).cells.add(r * cols + c);
                ch.push(cell.ch);
                spacer.push(cell.flags & SPACER_BITS != 0);
                fg.push(cell.fg & 0x00FF_FFFF);
                let id = bc::bb_snap_link_id_at(snap, r as u16, c as u16);
                if id == 0 {
                    link.push(None);
                } else {
                    let p = bc::bb_snap_link_url(snap, id);
                    assert!(!p.is_null(), "link id {id} at ({r},{c}) must resolve");
                    link.push(Some(
                        CStr::from_ptr(p as *const _).to_string_lossy().into_owned(),
                    ));
                }
            }
        }
        let g = Grid {
            ch,
            spacer,
            fg,
            link,
            cursor_row: (*snap).cursor_row,
            cursor_col: (*snap).cursor_col,
            history: (*snap).history_size,
        };
        bc::bb_snap_release(snap);
        g
    }
}

impl Grid {
    fn row_text(&self, row: usize) -> String {
        let s: String = (0..COLS as usize)
            .filter(|&c| !self.spacer[row * COLS as usize + c])
            .map(|c| match self.ch[row * COLS as usize + c] {
                0 => ' ',
                v => char::from_u32(v).unwrap_or('\u{FFFD}'),
            })
            .collect();
        s.trim_end().to_string()
    }

    fn screen_text(&self) -> Vec<String> {
        (0..ROWS as usize).map(|r| self.row_text(r)).collect()
    }

    fn cursor(&self) -> (u16, u16) {
        (self.cursor_row, self.cursor_col)
    }

    /// Column of the first occurrence of `needle` on `row`, by cell
    /// characters (all needles used here are narrow ASCII).
    fn find_in_row(&self, row: usize, needle: &str) -> Option<usize> {
        let text: Vec<char> = (0..COLS as usize)
            .map(|c| match self.ch[row * COLS as usize + c] {
                0 => ' ',
                v => char::from_u32(v).unwrap_or('\u{FFFD}'),
            })
            .collect();
        let n: Vec<char> = needle.chars().collect();
        (0..=text.len().saturating_sub(n.len())).find(|&i| text[i..i + n.len()] == n[..])
    }
}

/// One escape sequence (or UTF-8 character) that gets split, plus what a
/// clean terminal shows for `seq + rest`.
struct Scenario {
    name: &'static str,
    /// The bytes that are split. Splits happen strictly inside this, at every
    /// internal byte boundary.
    seq: &'static [u8],
    /// Bytes that follow in the stream (visible text, closing sequences).
    rest: &'static [u8],
    /// Text that must be on row 0 of the control (and of a correct run).
    visible: &'static str,
}

const URL: &str = "https://example.com/a/b";

const SGR_256: Scenario = Scenario {
    name: "sgr-256 (CSI 38;5;196 m)",
    seq: b"\x1b[38;5;196m",
    rest: b"HELLO",
    visible: "HELLO",
};
const SGR_TRUECOLOR: Scenario = Scenario {
    name: "sgr-truecolor (CSI 38;2;12;34;56 m)",
    seq: b"\x1b[38;2;12;34;56m",
    rest: b"HELLO",
    visible: "HELLO",
};
const OSC8_ST: Scenario = Scenario {
    name: "osc8 (ST-terminated)",
    seq: b"\x1b]8;;https://example.com/a/b\x1b\\",
    rest: b"LINK\x1b]8;;\x1b\\",
    visible: "LINK",
};
const OSC8_BEL: Scenario = Scenario {
    name: "osc8 (BEL-terminated)",
    seq: b"\x1b]8;;https://example.com/a/b\x07",
    rest: b"LINK\x1b]8;;\x07",
    visible: "LINK",
};
const OSC_TITLE: Scenario = Scenario {
    name: "osc2 window title",
    seq: b"\x1b]2;window title\x07",
    rest: b"TEXT",
    visible: "TEXT",
};
const UTF8_2: Scenario = Scenario {
    name: "utf8 2-byte (U+00E9)",
    seq: "\u{e9}".as_bytes(),
    rest: b"|",
    visible: "\u{e9}|",
};
const UTF8_3: Scenario = Scenario {
    name: "utf8 3-byte (U+20AC)",
    seq: "\u{20ac}".as_bytes(),
    rest: b"|",
    visible: "\u{20ac}|",
};
const UTF8_4: Scenario = Scenario {
    name: "utf8 4-byte (U+1F600, wide)",
    seq: "\u{1F600}".as_bytes(),
    rest: b"|",
    visible: "\u{1F600}|",
};

const ESCAPE_SCENARIOS: &[&Scenario] = &[&SGR_256, &SGR_TRUECOLOR, &OSC8_ST, &OSC8_BEL, &OSC_TITLE];
const UTF8_SCENARIOS: &[&Scenario] = &[&UTF8_2, &UTF8_3, &UTF8_4];
const SGR_SCENARIOS: &[&Scenario] = &[&SGR_256, &SGR_TRUECOLOR];
const OSC8_SCENARIOS: &[&Scenario] = &[&OSC8_ST, &OSC8_BEL];

impl Scenario {
    fn stream(&self) -> Vec<u8> {
        let mut v = self.seq.to_vec();
        v.extend_from_slice(self.rest);
        v
    }

    /// Fresh terminal, whole stream, no clear anywhere.
    fn control(&self) -> Grid {
        let t = new_term();
        feed(t, &self.stream());
        let g = capture(t);
        unsafe { bc::bb_term_free(t) };
        g
    }

    /// Terminal with junk + scrollback, head fed, clear_all, tail fed. `k` is
    /// the split index into the stream (1 ..= seq.len() - 1 for a mid-sequence
    /// split).
    fn split_run(&self, k: usize) -> Grid {
        let stream = self.stream();
        let t = new_term();
        feed(t, &prefill());
        let before = capture(t);
        assert!(
            before.history > 0,
            "[{}] rig: prefill must leave scrollback, history={}",
            self.name,
            before.history
        );
        assert!(
            !before.row_text(0).is_empty(),
            "[{}] rig: prefill must leave visible junk on row 0",
            self.name
        );
        feed(t, &stream[..k]);
        clear_all(t);
        feed(t, &stream[k..]);
        let g = capture(t);
        unsafe { bc::bb_term_free(t) };
        g
    }

    /// Every strictly-internal split index of `seq`.
    fn splits(&self) -> std::ops::Range<usize> {
        1..self.seq.len()
    }

    fn describe_split(&self, k: usize) -> String {
        let stream = self.stream();
        format!(
            "[{}] split {}/{}: head=\"{}\" | clear_all | tail=\"{}\"",
            self.name,
            k,
            self.seq.len(),
            esc(&stream[..k]),
            esc(&stream[k..])
        )
    }
}

fn report(failures: Vec<String>, total: usize, what: &str) {
    assert_eq!(
        failures.len(),
        0,
        "{} of {} (scenario, split) runs {}:\n{}",
        failures.len(),
        total,
        what,
        failures.join("\n")
    );
}

/// For every split, the terminal under test must show exactly what the
/// control shows: same text on every row, same cursor, no scrollback.
fn check_text_matches_control(scenarios: &[&Scenario], what: &str) {
    let mut failures = Vec::new();
    let mut total = 0;
    for sc in scenarios {
        let control = sc.control();
        // Rig: the control is the clean rendering of the stream.
        assert_eq!(
            control.row_text(0),
            sc.visible,
            "[{}] rig: control row 0 must be the visible text",
            sc.name
        );
        for k in sc.splits() {
            total += 1;
            let got = sc.split_run(k);
            let mut problems = Vec::new();
            if got.screen_text() != control.screen_text() {
                problems.push(format!(
                    "screen={:?} expected={:?}",
                    got.screen_text(),
                    control.screen_text()
                ));
            }
            if got.cursor() != control.cursor() {
                problems.push(format!(
                    "cursor(row,col)={:?} expected={:?}",
                    got.cursor(),
                    control.cursor()
                ));
            }
            if got.history != 0 {
                problems.push(format!("history={} expected 0", got.history));
            }
            if !problems.is_empty() {
                failures.push(format!(
                    "{} -> {}",
                    sc.describe_split(k),
                    problems.join("; ")
                ));
            }
        }
    }
    report(failures, total, what);
}

// ---------------------------------------------------------------------------
// Rig preconditions
// ---------------------------------------------------------------------------

#[test]
fn rig_controls_render_the_expected_visible_text() {
    let default_fg = {
        let t = new_term();
        feed(t, b"HELLO");
        let g = capture(t);
        unsafe { bc::bb_term_free(t) };
        g.fg[0]
    };

    for sc in ESCAPE_SCENARIOS.iter().chain(UTF8_SCENARIOS.iter()) {
        let g = sc.control();
        assert_eq!(g.row_text(0), sc.visible, "[{}] control row 0", sc.name);
        for r in 1..ROWS as usize {
            assert_eq!(
                g.row_text(r),
                "",
                "[{}] control row {r} must be blank",
                sc.name
            );
        }
        assert_eq!(g.history, 0, "[{}] control history", sc.name);
    }

    // Colours: 38;5;196 is the cube's pure red, 38;2;12;34;56 is literal.
    let red = SGR_256.control();
    assert_eq!(
        red.fg[0], 0xFF0000,
        "control fg of 'H' for 38;5;196, got {:#08x}",
        red.fg[0]
    );
    assert_ne!(
        red.fg[0], default_fg,
        "SGR colour must differ from the default fg {default_fg:#08x}"
    );
    let tc = SGR_TRUECOLOR.control();
    assert_eq!(
        tc.fg[0], 0x0C2238,
        "control fg of 'H' for 38;2;12;34;56, got {:#08x}",
        tc.fg[0]
    );
    for c in 0..5 {
        assert_eq!(red.fg[c], 0xFF0000, "red control fg at col {c}");
        assert_eq!(tc.fg[c], 0x0C2238, "truecolor control fg at col {c}");
    }

    // Links: LINK cells carry the full URL, the next cell is unlinked.
    for sc in OSC8_SCENARIOS {
        let g = sc.control();
        for c in 0..4 {
            assert_eq!(
                g.link[c].as_deref(),
                Some(URL),
                "[{}] control link at col {c}",
                sc.name
            );
        }
        assert_eq!(
            g.link[4], None,
            "[{}] control: cell after LINK must be unlinked",
            sc.name
        );
    }
}

#[test]
fn rig_clear_all_at_a_sequence_boundary_wipes_everything_and_stream_resumes() {
    for sc in ESCAPE_SCENARIOS.iter().chain(UTF8_SCENARIOS.iter()) {
        let control = sc.control();
        let t = new_term();
        feed(t, &prefill());
        let before = capture(t);
        assert!(
            before.history > 0,
            "[{}] prefill must create scrollback",
            sc.name
        );
        assert!(
            !before.row_text(0).is_empty(),
            "[{}] prefill must leave junk",
            sc.name
        );

        clear_all(t);
        let cleared = capture(t);
        assert_eq!(
            cleared.history, 0,
            "[{}] clear_all must drop scrollback",
            sc.name
        );
        assert_eq!(
            cleared.screen_text(),
            vec![String::new(); ROWS as usize],
            "[{}] clear_all must blank every visible row",
            sc.name
        );
        assert_eq!(
            (cleared.cursor_row, cleared.cursor_col),
            (0, 0),
            "[{}] cursor homed",
            sc.name
        );

        // Parser is at a sequence boundary: the whole stream afterwards must
        // render exactly like the control.
        feed(t, &sc.stream());
        let after = capture(t);
        unsafe { bc::bb_term_free(t) };
        assert_eq!(
            after.screen_text(),
            control.screen_text(),
            "[{}] text after clear+stream",
            sc.name
        );
        assert_eq!(
            after.cursor(),
            control.cursor(),
            "[{}] cursor after clear+stream",
            sc.name
        );
        assert_eq!(after.fg, control.fg, "[{}] fg after clear+stream", sc.name);
        assert_eq!(
            after.link, control.link,
            "[{}] links after clear+stream",
            sc.name
        );
    }
}

// ---------------------------------------------------------------------------
// The bug
// ---------------------------------------------------------------------------

/// The reported trigger, verbatim: "\x1b[38;5" | clear_all | ";196mHELLO".
/// Row 0 must read "HELLO", not ";196mHELLO".
#[test]
fn reported_trigger_split_csi_tail_is_not_printed_after_clear_all() {
    let t = new_term();
    feed(t, &prefill());
    assert!(
        capture(t).history > 0,
        "rig: prefill must create scrollback"
    );
    feed(t, b"\x1b[38;5");
    clear_all(t);
    feed(t, b";196mHELLO");
    let g = capture(t);
    unsafe { bc::bb_term_free(t) };

    assert_eq!(
        g.row_text(0),
        "HELLO",
        "row 0 after the split CSI; the tail of the interrupted sequence must not be printed as text"
    );
    assert_eq!(g.history, 0, "clear_all must leave no scrollback");
    assert_eq!(
        (g.cursor_row, g.cursor_col),
        (0, 5),
        "cursor after HELLO on the cleared screen, got (row,col)={:?}",
        g.cursor()
    );
    assert_eq!(
        g.fg[..5].to_vec(),
        vec![0xFF0000; 5],
        "HELLO must be drawn in the colour (indexed 196 = 0xFF0000) the split CSI set"
    );
}

/// No split of an SGR / OSC 8 / OSC title may print any of its tail as text,
/// move the cursor, or leave scrollback.
#[test]
fn split_escape_sequence_tail_never_prints_as_text_after_clear_all() {
    check_text_matches_control(
        ESCAPE_SCENARIOS,
        "differ from an uninterrupted stream (interrupted sequence's tail leaked onto the screen)",
    );
}

/// The SGR colour of an interrupted CSI is applied to the text that follows.
#[test]
fn split_sgr_colour_is_not_lost_across_clear_all() {
    let mut failures = Vec::new();
    let mut total = 0;
    for sc in SGR_SCENARIOS {
        let control = sc.control();
        let want = control.fg[0];
        assert_ne!(
            want, 0,
            "[{}] rig: control colour must be non-black",
            sc.name
        );
        for k in sc.splits() {
            total += 1;
            let got = sc.split_run(k);
            match got.find_in_row(0, sc.visible) {
                None => failures.push(format!(
                    "{} -> {:?} not found on row 0, row 0 = {:?}",
                    sc.describe_split(k),
                    sc.visible,
                    got.row_text(0)
                )),
                Some(col) => {
                    let fgs: Vec<String> = (0..sc.visible.len())
                        .map(|i| format!("{:#08x}", got.fg[col + i]))
                        .collect();
                    if fgs.iter().any(|f| *f != format!("{want:#08x}")) {
                        failures.push(format!(
                            "{} -> fg of {:?} (cols {}..) = {:?}, expected all {:#08x}",
                            sc.describe_split(k),
                            sc.visible,
                            col,
                            fgs,
                            want
                        ));
                    }
                }
            }
        }
    }
    report(
        failures,
        total,
        "lost the SGR colour set by the interrupted CSI",
    );
}

/// The text after a split OSC 8 is linked to the complete URL, never to a
/// truncated prefix, and the program's closing OSC 8 still closes the link.
#[test]
fn split_osc8_url_is_not_truncated_by_clear_all() {
    let mut failures = Vec::new();
    let mut total = 0;
    for sc in OSC8_SCENARIOS {
        for k in sc.splits() {
            total += 1;
            let got = sc.split_run(k);
            match got.find_in_row(0, "LINK") {
                None => failures.push(format!(
                    "{} -> \"LINK\" not found on row 0, row 0 = {:?}",
                    sc.describe_split(k),
                    got.row_text(0)
                )),
                Some(col) => {
                    let links: Vec<Option<&str>> =
                        (0..4).map(|i| got.link[col + i].as_deref()).collect();
                    let after = got.link.get(col + 4).cloned().flatten();
                    if links.iter().any(|l| *l != Some(URL))
                        || !after.as_deref().unwrap_or("").is_empty()
                    {
                        failures.push(format!(
                            "{} -> links on LINK = {:?} (expected all Some({:?})); cell after LINK = {:?} (expected None)",
                            sc.describe_split(k),
                            links,
                            URL,
                            after
                        ));
                    }
                }
            }
        }
    }
    report(
        failures,
        total,
        "linked the text to a truncated / missing URL",
    );
}

/// A multi-byte UTF-8 character cut by the clear never turns into U+FFFD
/// junk, and the byte after it is parsed normally.
///
/// Its last bytes arrive after the clear, so the result is the character
/// itself at the top-left, exactly like the control. (An implementation that
/// held the clear back until the character completed would wipe the character
/// with the screen and show only the following "|"; the core does not do
/// that, so that outcome is no longer accepted: it would silently drop a
/// character the program sent after the clear.)
#[test]
fn split_utf8_character_never_turns_into_replacement_junk_after_clear_all() {
    let mut failures = Vec::new();
    let mut total = 0;
    for sc in UTF8_SCENARIOS {
        let control = sc.control();
        assert_eq!(
            control.row_text(0),
            sc.visible,
            "[{}] rig: control row 0 must be the visible text",
            sc.name
        );
        for k in sc.splits() {
            total += 1;
            let got = sc.split_run(k);
            let screen = got.screen_text();
            let as_control = screen == control.screen_text() && got.cursor() == control.cursor();
            if !as_control || got.history != 0 {
                failures.push(format!(
                    "{} -> screen={:?} cursor(row,col)={:?} history={}; expected screen={:?} cursor={:?}, history 0",
                    sc.describe_split(k),
                    screen,
                    got.cursor(),
                    got.history,
                    control.screen_text(),
                    control.cursor()
                ));
            }
        }
    }
    report(
        failures,
        total,
        "left replacement junk / lost the following byte for a UTF-8 character split by the clear",
    );
}
