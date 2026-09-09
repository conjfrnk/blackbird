//! Blind behaviour tests for `bb_term_set_osc52_write_enabled`, written from
//! the spec without sight of the implementation.
//!
//! Contract (BBCore.h):
//!   - Off at `bb_term_new`: an OSC 52 store (`52;c;<base64>`) emits no
//!     `Osc52Clipboard` (kind 4) event.
//!   - `bb_term_set_osc52_write_enabled(term, 1)`: the same store emits
//!     exactly one `Osc52Clipboard` event whose payload is the DECODED text.
//!   - `…(term, 0)`: stores are dropped again.
//!   - Reads (`52;c;?`) never produce a `PtyWrite` reply in either state.
//!   - A null `term` is a no-op (no crash).
//!
//! Pre-flight: one 10×3 BBTerm per test, 16-line scrollback, < 100 bytes
//! of input each. No sleeps, no I/O.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

const KIND_OSC52: u32 = 4;
const KIND_PTY_WRITE: u32 = 5;

/// base64("hello")
const STORE_HELLO: &[u8] = b"\x1b]52;c;aGVsbG8=\x07";
const READ_QUERY: &[u8] = b"\x1b]52;c;?\x07";

#[derive(Clone, Debug, PartialEq)]
struct Captured {
    kind: u32,
    payload: Vec<u8>,
}

#[derive(Default)]
struct Sink {
    events: Vec<Captured>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
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

    fn set_osc52_write_enabled(&self, enabled: u8) {
        unsafe { bc::bb_term_set_osc52_write_enabled(self.term, enabled) };
    }

    fn events_of(&self, kind: u32) -> Vec<Vec<u8>> {
        self.sink
            .lock()
            .unwrap()
            .events
            .iter()
            .filter(|e| e.kind == kind)
            .map(|e| e.payload.clone())
            .collect()
    }

    fn clipboard_writes(&self) -> Vec<String> {
        self.events_of(KIND_OSC52)
            .into_iter()
            .map(|p| String::from_utf8_lossy(&p).into_owned())
            .collect()
    }

    fn pty_writes(&self) -> Vec<Vec<u8>> {
        self.events_of(KIND_PTY_WRITE)
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
fn store_is_dropped_by_default() {
    let h = Harness::new();
    h.feed(STORE_HELLO);
    assert!(
        h.clipboard_writes().is_empty(),
        "OSC 52 store must be inert before the write toggle is enabled; got {:?}",
        h.clipboard_writes()
    );
}

#[test]
fn enabling_writes_delivers_exactly_one_decoded_clipboard_event() {
    let h = Harness::new();
    h.set_osc52_write_enabled(1);
    h.feed(STORE_HELLO);
    assert_eq!(
        h.clipboard_writes(),
        vec!["hello".to_string()],
        "an enabled store must reach the callback once, base64-decoded"
    );
}

#[test]
fn disabling_writes_again_stops_delivery() {
    let h = Harness::new();
    h.set_osc52_write_enabled(1);
    h.feed(STORE_HELLO);
    assert_eq!(
        h.clipboard_writes().len(),
        1,
        "precondition: enabled path works"
    );

    h.set_osc52_write_enabled(0);
    h.feed(STORE_HELLO);
    assert_eq!(
        h.clipboard_writes().len(),
        1,
        "after disabling, no further Osc52Clipboard events may be emitted; got {:?}",
        h.clipboard_writes()
    );
}

#[test]
fn toggle_survives_a_second_enable() {
    // enable → disable → enable must deliver again (the toggle is a
    // plain switch, not a one-shot).
    let h = Harness::new();
    h.set_osc52_write_enabled(1);
    h.set_osc52_write_enabled(0);
    h.set_osc52_write_enabled(1);
    h.feed(STORE_HELLO);
    assert_eq!(h.clipboard_writes(), vec!["hello".to_string()]);
}

#[test]
fn reads_never_reply_when_writes_disabled() {
    let h = Harness::new();
    h.feed(READ_QUERY);
    assert!(
        h.pty_writes().is_empty(),
        "OSC 52 read-back must never echo to the PTY (writes off); got {:?}",
        h.pty_writes()
    );
    assert!(h.clipboard_writes().is_empty());
}

#[test]
fn reads_never_reply_when_writes_enabled() {
    let h = Harness::new();
    h.set_osc52_write_enabled(1);
    h.feed(READ_QUERY);
    assert!(
        h.pty_writes().is_empty(),
        "OSC 52 read-back must never echo to the PTY (writes on); got {:?}",
        h.pty_writes()
    );
    assert!(
        h.clipboard_writes().is_empty(),
        "a read query must not be mistaken for a store"
    );
}

#[test]
fn store_never_produces_a_pty_reply() {
    let h = Harness::new();
    h.set_osc52_write_enabled(1);
    h.feed(STORE_HELLO);
    assert!(
        h.pty_writes().is_empty(),
        "an accepted store must not write anything back to the PTY; got {:?}",
        h.pty_writes()
    );
}

#[test]
fn null_term_is_a_no_op() {
    unsafe {
        bc::bb_term_set_osc52_write_enabled(std::ptr::null_mut(), 1);
        bc::bb_term_set_osc52_write_enabled(std::ptr::null_mut(), 0);
    }
    // Reaching here without a crash is the assertion.
}
