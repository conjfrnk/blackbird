//! Blind behaviour tests for `bb_term_is_poisoned` and the post-Fatal
//! quarantine.
//!
//! Once a panic has been caught inside the FFI boundary the terminal's
//! internal state may be torn; the core delivers ONE Fatal event, marks the
//! handle poisoned, and from then on every input is dropped — no further
//! events, no grid mutation — until the host tears the tab down.
//!
//! Provoking the panic: `bb_term_input` with `len > isize::MAX` panics on
//! its length check before touching the pointer (audit L-11), which the
//! guard converts into a Fatal. That is deterministic and needs no test-only
//! feature. A second variant behind `feature = "test-only"` uses
//! `bb_term_test_only_panic` for the same assertions.
//!
//! Cost: one 20×5 terminal per test, a few bytes of input, two snapshots.
//! The oversized `len` is never dereferenced — nothing near it is allocated.

use std::ffi::c_void;
use std::sync::Mutex;

use blackbird_core::*;

struct Sink {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
}

impl Sink {
    fn new() -> Self {
        Sink {
            events: Mutex::new(Vec::new()),
        }
    }
    fn kinds(&self) -> Vec<u32> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .map(|(k, _)| *k)
            .collect()
    }
    fn count(&self, kind: BBEventKind) -> usize {
        self.kinds().iter().filter(|&&k| k == kind as u32).count()
    }
}

extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = unsafe { &*(ctx as *const Sink) };
    let bytes = if ev.len == 0 || ev.payload.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ev.payload, ev.len).to_vec() }
    };
    sink.events.lock().unwrap().push((ev.kind as u32, bytes));
}

unsafe fn make_term(sink: &Sink) -> *mut BBTerm {
    let term = bb_term_new(20, 5, 100);
    assert!(!term.is_null());
    bb_term_set_event_cb(term, Some(cb), sink as *const Sink as *mut c_void);
    term
}

unsafe fn feed(term: *mut BBTerm, bytes: &[u8]) {
    bb_term_input(term, bytes.as_ptr(), bytes.len());
}

unsafe fn first_row(term: *mut BBTerm) -> Vec<u32> {
    let snap = bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "snapshot must be available");
    let cols = (*snap).cols as usize;
    let row: Vec<u32> = (0..cols).map(|i| (*(*snap).cells.add(i)).ch).collect();
    bb_snap_release(snap);
    row
}

unsafe fn provoke_fatal_via_oversized_len(term: *mut BBTerm) {
    let dummy = [0u8; 4];
    let bad_len = (isize::MAX as usize).wrapping_add(1);
    bb_term_input(term, dummy.as_ptr(), bad_len);
}

#[test]
fn fresh_terminal_is_not_poisoned() {
    unsafe {
        let term = bb_term_new(20, 5, 100);
        assert!(!term.is_null());
        assert_eq!(bb_term_is_poisoned(term), 0);
        feed(term, b"hello\x07");
        assert_eq!(bb_term_is_poisoned(term), 0, "ordinary input never poisons");
        bb_term_free(term);
    }
}

#[test]
fn null_terminal_reports_not_poisoned() {
    unsafe {
        assert_eq!(bb_term_is_poisoned(std::ptr::null()), 0);
    }
}

/// Shared body for the two panic provocations.
unsafe fn assert_quarantine_after(provoke: unsafe fn(*mut BBTerm)) {
    let sink = Sink::new();
    let term = make_term(&sink);

    feed(term, b"abc");
    let before = first_row(term);
    assert_eq!(&before[..3], &[b'a' as u32, b'b' as u32, b'c' as u32]);
    assert_eq!(bb_term_is_poisoned(term), 0, "precondition");

    provoke(term);

    assert_eq!(
        sink.count(BBEventKind::Fatal),
        1,
        "exactly one Fatal must be delivered; events: {:?}",
        sink.kinds()
    );
    assert_eq!(
        bb_term_is_poisoned(term),
        1,
        "handle must be poisoned after a Fatal"
    );

    let events_after_fatal = sink.kinds().len();

    // Input that would normally produce a Title event AND mutate row 0.
    feed(term, b"hello\x1b]2;newtitle\x07");

    assert_eq!(
        sink.kinds().len(),
        events_after_fatal,
        "a poisoned terminal must deliver NO further events (no second Fatal, no Title); got {:?}",
        sink.kinds()
    );
    assert_eq!(sink.count(BBEventKind::Fatal), 1, "no second Fatal");
    assert_eq!(
        sink.count(BBEventKind::Title),
        0,
        "no Title from dropped input"
    );
    assert_eq!(bb_term_is_poisoned(term), 1, "poison is sticky");

    let after = first_row(term);
    assert_eq!(
        after, before,
        "row 0 must be unchanged after input to a poisoned terminal"
    );

    bb_term_set_event_cb(term, None, std::ptr::null_mut());
    bb_term_free(term);
}

#[test]
fn fatal_from_oversized_len_poisons_and_quarantines() {
    unsafe {
        assert_quarantine_after(provoke_fatal_via_oversized_len);
    }
}

#[test]
fn poisoned_terminal_does_not_reply_to_queries() {
    // DSR replies are events too; the quarantine must silence them.
    let sink = Sink::new();
    unsafe {
        let term = make_term(&sink);
        provoke_fatal_via_oversized_len(term);
        assert_eq!(bb_term_is_poisoned(term), 1);
        feed(term, b"\x1b[6n\x1b[c");
        bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bb_term_free(term);
    }
    assert_eq!(
        sink.count(BBEventKind::PtyWrite),
        0,
        "no PtyWrite after poison"
    );
    assert_eq!(sink.count(BBEventKind::Fatal), 1);
}

#[cfg(feature = "test-only")]
#[test]
fn fatal_from_test_only_panic_poisons_and_quarantines() {
    unsafe fn provoke(term: *mut BBTerm) {
        bb_term_test_only_panic(term);
    }
    unsafe {
        assert_quarantine_after(provoke);
    }
}
