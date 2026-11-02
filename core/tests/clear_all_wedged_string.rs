//! `bb_term_clear_all` (the app's Cmd-K) and a string-introduced escape
//! function (OSC / DCS / SOS / PM / APC) the program opened and never closed.
//!
//! Companion to `clear_all_midsequence_blind.rs`, which pins that a sequence
//! merely SPLIT across a read boundary survives Cmd-K intact. This file pins
//! the other half of the contract: Cmd-K is still the user's way out of a
//! tab whose parser is stuck inside an unterminated string. Such a string
//! swallows every byte except ESC / CAN / SUB (and BEL for OSC) without
//! drawing anything, so a prompt that contains none of them never renders
//! again until the string is ended.
//!
//! Contract under test
//! -------------------
//!   - A string that was already open when the PREVIOUS chunk ended is dropped
//!     by `bb_term_clear_all`: the next output renders on the cleared screen
//!     and nothing is dispatched for the dropped string (no title built from
//!     post-clear text).
//!   - A string opened in the very last chunk before the clear cannot be told
//!     apart from a split one, so it survives that clear; a second clear, once
//!     more output has arrived inside it, drops it.
//!   - A title split across the clear still reaches the host with its full
//!     text (the blind file only checks the grid for it).
//!
//! Pre-flight cost: 40x5 grids with 100 lines of scrollback, a few KB each,
//! about a dozen terminals in total. No sleeps, no threads, no I/O.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

const COLS: u16 = 40;
const ROWS: u16 = 5;
const SCROLLBACK: u32 = 100;
const KIND_TITLE: u32 = 1;
/// `BBCell::flags` bits for WIDE_CHAR_SPACER / LEADING_WIDE_CHAR_SPACER.
const SPACER_BITS: u16 = (1 << 7) | (1 << 8);

/// Plain text and CRLF only: leaves junk on every visible row and pushes
/// lines into scrollback (12 lines through a 5-row screen).
fn prefill() -> Vec<u8> {
    let mut v = Vec::new();
    for i in 0..12 {
        v.extend_from_slice(format!("PRE-CLEAR-LINE-{i:02}\r\n").as_bytes());
    }
    v
}

#[derive(Default)]
struct Sink {
    titles: Vec<String>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    if ev.kind as u32 != KIND_TITLE {
        return;
    }
    let bytes: &[u8] = if ev.payload.is_null() || ev.len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ev.payload, ev.len)
    };
    let sink = &*(ctx as *const Mutex<Sink>);
    sink.lock()
        .unwrap()
        .titles
        .push(String::from_utf8_lossy(bytes).into_owned());
}

struct Term {
    term: *mut bc::BBTerm,
    sink: Arc<Mutex<Sink>>,
    ctx: *mut c_void,
}

impl Term {
    fn new() -> Self {
        let sink: Arc<Mutex<Sink>> = Arc::new(Mutex::new(Sink::default()));
        let ctx = Arc::into_raw(sink.clone()) as *mut c_void;
        let term = unsafe { bc::bb_term_new(COLS, ROWS, SCROLLBACK) };
        assert!(!term.is_null(), "bb_term_new returned null");
        unsafe { bc::bb_term_set_event_cb(term, Some(capture_cb), ctx) };
        Term { term, sink, ctx }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    fn clear_all(&self) {
        unsafe { bc::bb_term_clear_all(self.term) };
    }

    fn titles(&self) -> Vec<String> {
        self.sink.lock().unwrap().titles.clone()
    }

    /// (visible rows as trimmed text, scrollback lines, cursor row, cursor col)
    fn screen(&self) -> (Vec<String>, u32, u16, u16) {
        unsafe {
            let snap = bc::bb_term_take_snapshot(self.term);
            assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
            let cols = (*snap).cols as usize;
            let rows = (*snap).rows as usize;
            assert_eq!((cols, rows), (COLS as usize, ROWS as usize));
            let mut out = Vec::with_capacity(rows);
            for r in 0..rows {
                let mut line = String::new();
                for c in 0..cols {
                    let cell = &*(*snap).cells.add(r * cols + c);
                    if cell.flags & SPACER_BITS != 0 {
                        continue;
                    }
                    line.push(match cell.ch {
                        0 => ' ',
                        v => char::from_u32(v).unwrap_or('\u{FFFD}'),
                    });
                }
                out.push(line.trim_end().to_string());
            }
            let res = (
                out,
                (*snap).history_size,
                (*snap).cursor_row,
                (*snap).cursor_col,
            );
            bc::bb_snap_release(snap);
            res
        }
    }

    fn row0(&self) -> String {
        self.screen().0.swap_remove(0)
    }

    /// A terminal with visible junk and scrollback, as in a used session.
    fn used() -> Self {
        let t = Term::new();
        t.feed(&prefill());
        let (rows, history, _, _) = t.screen();
        assert!(history > 0, "rig: prefill must leave scrollback");
        assert!(!rows[0].is_empty(), "rig: prefill must leave junk on row 0");
        t
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        unsafe {
            bc::bb_term_set_event_cb(self.term, None, std::ptr::null_mut());
            bc::bb_term_free(self.term);
            drop(Arc::from_raw(self.ctx as *const Mutex<Sink>));
        }
    }
}

/// Openers of each string-introduced function, each ending inside the string
/// with a little payload. `DCS z` hooks on its final byte, so the payload is
/// already passthrough data.
const OPENERS: &[(&str, &[u8])] = &[
    ("OSC title", b"\x1b]0;stuck"),
    ("OSC 8 link", b"\x1b]8;;https://example.com/stuck"),
    ("DCS", b"\x1bPzstuck"),
    ("APC", b"\x1b_Gstuck"),
    ("PM", b"\x1b^stuck"),
    ("SOS", b"\x1bXstuck"),
];

/// What a shell prompt looks like: no ESC, no BEL, so it cannot end a string.
const SWALLOWED: &[u8] = b"more output\r\nuser@host % ";

#[test]
fn rig_control_text_after_a_cleared_screen_renders_on_row_0() {
    let t = Term::used();
    t.clear_all();
    t.feed(b"HELLO");
    let (rows, history, cr, cc) = t.screen();
    assert_eq!(rows[0], "HELLO");
    assert_eq!(history, 0);
    assert_eq!((cr, cc), (0, 5));
}

#[test]
fn rig_an_open_string_swallows_plain_output() {
    for (name, opener) in OPENERS {
        let t = Term::used();
        let before = t.screen();
        t.feed(opener);
        t.feed(SWALLOWED);
        t.feed(b"HELLO");
        assert_eq!(
            t.screen(),
            before,
            "[{name}] rig: plain output inside an open string must not draw"
        );
    }
}

#[test]
fn clear_all_ends_a_string_the_program_left_open_across_chunks() {
    for (name, opener) in OPENERS {
        let t = Term::used();
        t.feed(opener);
        t.feed(SWALLOWED);
        t.clear_all();
        t.feed(b"HELLO");
        let (rows, history, cr, cc) = t.screen();
        assert_eq!(
            rows,
            vec![
                "HELLO".to_string(),
                String::new(),
                String::new(),
                String::new(),
                String::new()
            ],
            "[{name}] output after clear_all must render on the cleared screen"
        );
        assert_eq!(history, 0, "[{name}] scrollback");
        assert_eq!((cr, cc), (0, 5), "[{name}] cursor after HELLO");
    }
}

#[test]
fn clear_all_ends_a_string_left_open_across_many_chunks() {
    for (name, opener) in OPENERS {
        let t = Term::used();
        t.feed(opener);
        for _ in 0..50 {
            t.feed(SWALLOWED);
        }
        t.clear_all();
        t.feed(b"HELLO");
        assert_eq!(t.row0(), "HELLO", "[{name}]");
    }
}

#[test]
fn the_dropped_string_is_never_dispatched_with_post_clear_text() {
    // Rig: the same stream, closed normally, does deliver a title.
    let rig = Term::new();
    rig.feed(b"\x1b]2;stuck");
    rig.feed(SWALLOWED);
    rig.feed(b"\x07");
    assert_eq!(
        rig.titles().len(),
        1,
        "rig: a closed OSC 2 delivers a title"
    );

    let t = Term::used();
    t.feed(b"\x1b]2;stuck");
    t.feed(SWALLOWED);
    t.clear_all();
    t.feed(b"HELLO\x1b\\after");
    assert_eq!(t.row0(), "HELLOafter");
    assert_eq!(
        t.titles(),
        Vec::<String>::new(),
        "an OSC dropped by clear_all must not be dispatched, now or at a later terminator"
    );
}

#[test]
fn a_string_opened_in_the_last_chunk_survives_one_clear_and_dies_on_the_next() {
    for (name, opener) in OPENERS {
        let t = Term::used();
        t.feed(opener);
        t.clear_all();
        // Output keeps arriving inside the still-open string.
        t.feed(SWALLOWED);
        t.clear_all();
        t.feed(b"HELLO");
        assert_eq!(
            t.row0(),
            "HELLO",
            "[{name}] the second clear_all must end a string that stayed open"
        );
    }
}

#[test]
fn a_clear_in_the_middle_of_a_string_does_not_break_the_next_one() {
    // After the wedge is dropped the parser is back to normal: a fresh,
    // properly closed title works, and so does one split over a clear.
    let t = Term::used();
    t.feed(b"\x1b]0;stuck");
    t.feed(SWALLOWED);
    t.clear_all();
    t.feed(b"\x1b]2;fresh\x07HELLO");
    assert_eq!(t.row0(), "HELLO");
    assert_eq!(t.titles(), vec!["fresh".to_string()]);
}

#[test]
fn a_title_split_across_clear_all_still_delivers_its_full_text() {
    let t = Term::used();
    t.feed(b"\x1b]2;window ti");
    t.clear_all();
    t.feed(b"tle\x07TEXT");
    assert_eq!(t.row0(), "TEXT");
    assert_eq!(t.titles(), vec!["window title".to_string()]);
}
