//! Position stamp on OSC 133;A prompt marks, including marks that
//! arrive inside a DEC 2026 synchronized update.
//!
//! ## Contract under test
//!
//! A kind-A `PromptMark` event carries `lines_scrolled` and `cursor_row`: the
//! two snapshot fields of the same names as they stood the instant the mark
//! was parsed, i.e. with every byte before the mark applied and none after.
//! `lines_scrolled + cursor_row` is then the prompt's absolute line (every
//! line feed moves it by one, scrolling or not), whatever the PTY read
//! boundaries and whatever else the same chunk carries.
//!
//! The synchronized-update cases are the reason this file exists: between BSU
//! (`CSI ? 2026 h`) and ESU (`CSI ? 2026 l`) the grid parser only buffers, so
//! the grid is still where it was before the update while the mark is being
//! parsed. A mark stamped from that grid lands on the wrong row (the one the
//! update began on), and a run of prompts replayed in one update collapses
//! onto it. The stamp must be the prompt's own line instead.
//!
//! ## Oracle
//!
//! Hand arithmetic over the input, never the implementation: the grid starts
//! at absolute line 0 and each `\r\n` the test writes before a mark adds
//! exactly one. Each test also pins the arithmetic against a snapshot of the
//! cursor once the whole stream has been fed (`cursor_abs`), so a wrong
//! hand count fails loudly instead of agreeing with a wrong stamp.
//!
//! ## Pre-flight cost (CLAUDE.md test-authoring rule)
//!
//! One 20 x 4 grid with 100 lines of scrollback per test (80 live cells),
//! well under 100 bytes of input. The dominant cost is vte's 2 MiB sync
//! buffer per `BBTerm`, paid once per test thread.

use std::ffi::c_void;
use std::sync::Mutex;

use blackbird_core::*;

const COLS: u16 = 20;
const ROWS: u16 = 4;
const SCROLLBACK: u32 = 100;

const BSU: &[u8] = b"\x1b[?2026h";
const ESU: &[u8] = b"\x1b[?2026l";
const MARK_A: &[u8] = b"\x1b]133;A\x07";
const MARK_B: &[u8] = b"\x1b]133;B\x07";
const MARK_C: &[u8] = b"\x1b]133;C\x07";
const MARK_D: &[u8] = b"\x1b]133;D;0\x07";

/// `(kind 1..=4, lines_scrolled, cursor_row)` per PromptMark event, in fire
/// order.
#[derive(Default)]
struct Sink {
    marks: Mutex<Vec<(i32, u64, u16)>>,
}

impl Sink {
    fn marks(&self) -> Vec<(i32, u64, u16)> {
        self.marks.lock().unwrap().clone()
    }

    /// Absolute line of every kind-A mark, in fire order.
    fn prompt_lines(&self) -> Vec<u64> {
        self.marks()
            .iter()
            .filter(|(kind, _, _)| *kind == 1)
            .map(|(_, scrolled, row)| scrolled + u64::from(*row))
            .collect()
    }

    fn kinds(&self) -> Vec<i32> {
        self.marks().iter().map(|(kind, _, _)| *kind).collect()
    }
}

unsafe extern "C" fn capture(ev: BBEvent, ctx: *mut c_void) {
    if ev.kind as u32 != BBEventKind::PromptMark as u32 {
        return;
    }
    let sink = &*(ctx as *const Sink);
    sink.marks
        .lock()
        .unwrap()
        .push((ev.i32_arg, ev.lines_scrolled, ev.cursor_row));
}

struct Rig {
    term: *mut BBTerm,
    sink: Box<Sink>,
}

impl Rig {
    fn new() -> Rig {
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            assert!(!term.is_null(), "bb_term_new returned null");
            let sink = Box::<Sink>::default();
            bb_term_set_event_cb(term, Some(capture), &*sink as *const Sink as *mut c_void);
            Rig { term, sink }
        }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    /// Absolute line the cursor is on right now.
    fn cursor_abs(&self) -> u64 {
        unsafe {
            let snap = bb_term_take_snapshot(self.term);
            assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
            let abs = (*snap).lines_scrolled + u64::from((*snap).cursor_row);
            bb_snap_release(snap);
            abs
        }
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        unsafe { bb_term_free(self.term) };
    }
}

/// `count` one-character lines: the cursor's absolute line moves by `count`.
fn lines(count: usize) -> Vec<u8> {
    b"x\r\n".repeat(count)
}

fn concat(parts: &[&[u8]]) -> Vec<u8> {
    parts.concat()
}

// ---------------------------------------------------------------------------
// Control: no synchronized update
// ---------------------------------------------------------------------------

#[test]
fn prompts_parsed_in_one_chunk_are_each_stamped_at_their_own_line() {
    let rig = Rig::new();
    // Prompt i is on absolute line 2 * i; 6 lines in all, so the 4-row grid
    // scrolls and the stamps cross `lines_scrolled` values.
    let chunk = concat(&[
        MARK_A,
        b"$ \r\nout\r\n",
        MARK_A,
        b"$ \r\nout\r\n",
        MARK_A,
        b"$ \r\nout\r\n",
    ]);
    rig.feed(&chunk);
    assert_eq!(rig.cursor_abs(), 6, "precondition: six line feeds");
    assert_eq!(rig.sink.prompt_lines(), vec![0, 2, 4]);
}

#[test]
fn mark_completed_by_an_esc_free_chunk_is_stamped_before_that_chunks_text() {
    let rig = Rig::new();
    rig.feed(b"x\r\n");
    // The read boundary cuts the mark; the second chunk has no ESC at all.
    rig.feed(b"\x1b]13");
    rig.feed(b"3;A\x07abc\r\ndef\r\nghi\r\n");
    assert_eq!(rig.cursor_abs(), 4, "precondition: one + three line feeds");
    assert_eq!(
        rig.sink.prompt_lines(),
        vec![1],
        "the mark was parsed with the cursor on line 1, before the chunk's text moved it"
    );
}

// ---------------------------------------------------------------------------
// Inside a synchronized update
// ---------------------------------------------------------------------------

#[test]
fn prompt_inside_a_sync_update_is_stamped_at_its_own_line() {
    let rig = Rig::new();
    let chunk = concat(&[BSU, &lines(6), MARK_A, b"$ ", ESU]);
    rig.feed(&chunk);
    assert_eq!(
        rig.cursor_abs(),
        6,
        "precondition: update replayed, six line feeds"
    );
    assert_eq!(rig.sink.prompt_lines(), vec![6]);
}

#[test]
fn prompt_inside_a_sync_update_split_across_chunks_is_stamped_at_its_own_line() {
    let rig = Rig::new();
    rig.feed(&concat(&[BSU, &lines(6)]));
    rig.feed(&concat(&[MARK_A, b"$ "]));
    rig.feed(ESU);
    assert_eq!(
        rig.cursor_abs(),
        6,
        "precondition: update replayed, six line feeds"
    );
    assert_eq!(rig.sink.prompt_lines(), vec![6]);
}

#[test]
fn prompt_inside_a_sync_update_closed_by_a_forced_flush_is_stamped_at_its_own_line() {
    let rig = Rig::new();
    // The producer died after the prompt: no ESU ever arrives, the embedder's
    // timeout path ends the update.
    rig.feed(&concat(&[BSU, &lines(6), MARK_A, b"$ "]));
    unsafe {
        assert_eq!(
            bb_term_flush_sync_update(rig.term, 1),
            1,
            "precondition: an update was open"
        );
    }
    assert_eq!(
        rig.cursor_abs(),
        6,
        "precondition: flush replayed six line feeds"
    );
    assert_eq!(rig.sink.prompt_lines(), vec![6]);
}

#[test]
fn prompt_before_a_sync_update_is_stamped_before_the_update_moves_the_cursor() {
    let rig = Rig::new();
    let chunk = concat(&[&lines(1), MARK_A, b"$ ", BSU, &lines(3), ESU]);
    rig.feed(&chunk);
    assert_eq!(rig.cursor_abs(), 4, "precondition: four line feeds");
    assert_eq!(rig.sink.prompt_lines(), vec![1]);
}

#[test]
fn marks_inside_a_sync_update_keep_their_order_around_marks_outside_it() {
    let rig = Rig::new();
    let chunk = concat(&[
        BSU,
        &lines(5),
        MARK_A,
        b"$ ",
        MARK_B,
        MARK_C,
        MARK_D,
        ESU,
        b"\r\n",
        MARK_A,
        b"$ ",
    ]);
    rig.feed(&chunk);
    assert_eq!(rig.cursor_abs(), 6, "precondition: six line feeds");
    assert_eq!(rig.sink.kinds(), vec![1, 2, 3, 4, 1]);
    assert_eq!(rig.sink.prompt_lines(), vec![5, 6]);
}

#[test]
fn consecutive_sync_updates_in_one_chunk_stamp_each_prompt_at_its_own_line() {
    let rig = Rig::new();
    // ESU immediately followed by the next BSU, all in one read: the first
    // update's replay must release the first prompt even though the second
    // update is already open.
    let chunk = concat(&[
        BSU,
        &lines(2),
        MARK_A,
        b"$ ",
        ESU,
        BSU,
        b"\r\n",
        &lines(2),
        MARK_A,
        b"$ ",
        ESU,
    ]);
    rig.feed(&chunk);
    assert_eq!(rig.cursor_abs(), 5, "precondition: five line feeds");
    assert_eq!(rig.sink.prompt_lines(), vec![2, 5]);
}

#[test]
fn esu_split_across_feeds_and_followed_by_another_bsu_releases_the_first_prompt() {
    let rig = Rig::new();
    // The first update's ESU is cut by the read boundary and its completion is
    // glued to the next update's BSU, so no whole ESU is visible in either
    // feed, yet the first prompt must be positioned from the replay it caused,
    // not from the end of the second update.
    rig.feed(&concat(&[BSU, &lines(2), MARK_A, b"$ ", b"\x1b[?202"]));
    rig.feed(&concat(&[
        b"6l",
        BSU,
        b"\r\n",
        &lines(2),
        MARK_A,
        b"$ ",
        ESU,
    ]));
    assert_eq!(rig.cursor_abs(), 5, "precondition: five line feeds");
    assert_eq!(rig.sink.prompt_lines(), vec![2, 5]);
}

#[test]
fn prompts_in_separate_sync_updates_are_each_stamped_at_their_own_line() {
    let rig = Rig::new();
    for _ in 0..3 {
        // Each update draws two lines, then the prompt on the third; the line
        // feed that follows the prompt comes after the update closes.
        rig.feed(&concat(&[BSU, &lines(2), MARK_A, b"$ ", ESU, b"\r\n"]));
    }
    assert_eq!(rig.cursor_abs(), 9, "precondition: nine line feeds");
    assert_eq!(rig.sink.prompt_lines(), vec![2, 5, 8]);
}

#[test]
fn output_after_the_closing_esu_in_the_same_chunk_does_not_move_the_stamp() {
    let rig = Rig::new();
    // The prompt, the end of its update and the next command's output arrive
    // in one read, as they do when a recorded session is replayed.
    let chunk = concat(&[BSU, &lines(2), MARK_A, b"$ ", ESU, &lines(5)]);
    rig.feed(&chunk);
    assert_eq!(rig.cursor_abs(), 7, "precondition: seven line feeds");
    assert_eq!(rig.sink.prompt_lines(), vec![2]);
}
