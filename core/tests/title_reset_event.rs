//! Blind behaviour tests for title events, written from the v0.8.1 spec
//! without sight of the implementation.
//!
//! Contract:
//!   - `OSC 2 ; hello BEL` delivers a `Title` event (kind 1) whose payload
//!     is "hello".
//!   - XTWINOPS push (`CSI 22 ; 0 t`) then pop (`CSI 23 ; 0 t`) on a
//!     terminal whose title was never set delivers a `Title` event with an
//!     EMPTY payload (len 0 / null pointer per the header contract). This
//!     is alacritty's `ResetTitle`, previously dropped on the floor — a
//!     TUI that exits with the pair used to leave its title stuck.
//!   - Set "nvim", push, set "other", pop → the last `Title` payload is
//!     "nvim" (a normal restore, not the reset).
//!
//! Pre-flight: one 10×3 BBTerm per test, 16-line scrollback (< 50 KiB).
//! Title events are rate-capped at 32/s (audit S1-002); nothing here
//! comes near that. No I/O, no sleeps, < 10 ms per test.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

/// One captured event: its kind and a copy of the payload bytes.
#[derive(Clone, Debug, PartialEq)]
struct Captured {
    kind: u32,
    payload: Vec<u8>,
}

#[derive(Default)]
struct Sink {
    events: Vec<Captured>,
}

const KIND_TITLE: u32 = 1;

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    // Header contract: `payload == NULL <=> len == 0`. Honour both halves
    // so `from_raw_parts` never sees a null pointer — an empty title is
    // exactly what this file exists to observe.
    if ev.payload.is_null() {
        assert_eq!(ev.len, 0, "BBEvent contract: null payload must have len 0");
    } else {
        assert!(
            ev.len > 0,
            "BBEvent contract: non-null payload must have len > 0"
        );
    }
    let bytes: Vec<u8> = if ev.payload.is_null() || ev.len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    };
    let sink = &*(ctx as *const Mutex<Sink>);
    sink.lock().unwrap().events.push(Captured {
        kind: ev.kind as u32,
        payload: bytes,
    });
}

struct Harness {
    term: *mut bc::BBTerm,
    sink: Arc<Mutex<Sink>>,
    ctx: *mut c_void,
}

impl Harness {
    fn new() -> Self {
        let sink: Arc<Mutex<Sink>> = Arc::new(Mutex::new(Sink::default()));
        let ctx = Arc::into_raw(sink.clone()) as *mut c_void;
        let term = unsafe { bc::bb_term_new(10, 3, 16) };
        assert!(!term.is_null(), "bb_term_new returned null");
        unsafe { bc::bb_term_set_event_cb(term, Some(capture_cb), ctx) };
        Harness { term, sink, ctx }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    /// Every Title payload delivered so far, in order, decoded lossily.
    fn titles(&self) -> Vec<String> {
        self.sink
            .lock()
            .unwrap()
            .events
            .iter()
            .filter(|e| e.kind == KIND_TITLE)
            .map(|e| String::from_utf8_lossy(&e.payload).into_owned())
            .collect()
    }

    /// Raw payload lengths of every Title event, in order.
    fn title_lens(&self) -> Vec<usize> {
        self.sink
            .lock()
            .unwrap()
            .events
            .iter()
            .filter(|e| e.kind == KIND_TITLE)
            .map(|e| e.payload.len())
            .collect()
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        unsafe {
            bc::bb_term_set_event_cb(self.term, None, std::ptr::null_mut());
            bc::bb_term_free(self.term);
            drop(Arc::from_raw(self.ctx as *const Mutex<Sink>));
        }
    }
}

#[test]
fn osc2_delivers_title_event_with_payload() {
    let h = Harness::new();
    h.feed(b"\x1b]2;hello\x07");
    assert_eq!(h.titles(), vec!["hello".to_string()]);
}

#[test]
fn title_event_kind_is_one() {
    // Pin the numeric kind the Swift side switches on.
    assert_eq!(bc::BBEventKind::Title as u32, KIND_TITLE);
    let h = Harness::new();
    h.feed(b"\x1b]2;hello\x07");
    let kinds: Vec<u32> = h
        .sink
        .lock()
        .unwrap()
        .events
        .iter()
        .map(|e| e.kind)
        .collect();
    assert!(
        kinds.contains(&KIND_TITLE),
        "no kind-1 event delivered: {kinds:?}"
    );
}

#[test]
fn push_then_pop_on_never_set_title_delivers_empty_title() {
    let h = Harness::new();
    h.feed(b"\x1b[22;0t");
    h.feed(b"\x1b[23;0t");
    let lens = h.title_lens();
    assert!(
        !lens.is_empty(),
        "XTPOPTITLE of a never-set title must deliver a Title event (ResetTitle); none was delivered"
    );
    assert_eq!(
        *lens.last().unwrap(),
        0,
        "the delivered Title event must carry an EMPTY payload; got lens {lens:?} titles {:?}",
        h.titles()
    );
    assert!(
        h.titles().iter().all(|t| t.is_empty()),
        "no non-empty title may appear on a terminal whose title was never set: {:?}",
        h.titles()
    );
}

#[test]
fn push_then_pop_in_one_input_call_delivers_empty_title() {
    // Same as above but both sequences in one bb_term_input call, the way
    // a TUI's exit handler emits them.
    let h = Harness::new();
    h.feed(b"\x1b[22;0t\x1b[23;0t");
    let lens = h.title_lens();
    assert_eq!(
        lens.last(),
        Some(&0),
        "expected a trailing empty Title event; got {lens:?}"
    );
}

#[test]
fn pop_after_a_set_title_is_pushed_restores_it_not_empty() {
    let h = Harness::new();
    h.feed(b"\x1b]2;nvim\x07");
    h.feed(b"\x1b[22;0t");
    h.feed(b"\x1b]2;other\x07");
    h.feed(b"\x1b[23;0t");
    let titles = h.titles();
    assert_eq!(
        titles.last().map(String::as_str),
        Some("nvim"),
        "XTPOPTITLE must restore the pushed title, not reset it; got {titles:?}"
    );
    assert_eq!(
        titles,
        vec!["nvim".to_string(), "other".to_string(), "nvim".to_string()],
        "set, overwrite, restore — three Title events in order"
    );
}

#[test]
fn reset_after_a_title_was_set_then_cleared_by_pop_of_empty_push() {
    // Title set AFTER the push: the pushed entry is the never-set title,
    // so the pop resets to empty even though a title is currently live.
    let h = Harness::new();
    h.feed(b"\x1b[22;0t");
    h.feed(b"\x1b]2;transient\x07");
    h.feed(b"\x1b[23;0t");
    let titles = h.titles();
    assert_eq!(
        titles.first().map(String::as_str),
        Some("transient"),
        "the live set must be delivered first; got {titles:?}"
    );
    assert_eq!(
        titles.last().map(String::as_str),
        Some(""),
        "popping the never-set entry must reset the title to empty; got {titles:?}"
    );
}

#[test]
fn osc0_also_delivers_title() {
    // OSC 0 sets icon + window title; the window title half must arrive.
    let h = Harness::new();
    h.feed(b"\x1b]0;both\x07");
    assert_eq!(h.titles(), vec!["both".to_string()]);
}
