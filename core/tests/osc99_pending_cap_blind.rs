//! Blind behaviour tests for the chunked kitty OSC 99 accumulator cap.
//!
//! Contract under test (written without sight of the implementation):
//!   - `OSC 99;i=<id>:d=0;<payload>` chunks accumulate per notification id
//!     and one notification fires on the final chunk (`d` absent / `d=1`),
//!     or when a chunk for a different id flushes the pending one.
//!   - Each pending field (title, body) holds at most 64 KiB (65536 bytes)
//!     of raw payload. Bytes past that are silently dropped, per field and
//!     independently of the other field. The cap counts RAW bytes, i.e.
//!     before the notification scrub (C0 / bidi / invisible scalars are
//!     removed at emit time) and before the 128 / 1024 char display caps.
//!   - Legitimate notifications (well under the cap) are unaffected.
//!   - Emitted payload stays `"<title>\u{1F}<body>"`, title <= 128 chars,
//!     body <= 1024 chars.
//!
//! How the cap is observed over the FFI: U+00AD (SOFT HYPHEN, UTF-8
//! `C2 AD`, 2 bytes) is stripped by the notification scrub, so a run of
//! them consumes accumulator room while contributing nothing visible.
//! "filler of N bytes, then TAIL" therefore yields a visible TAIL only if
//! TAIL fits inside the 65536-byte cap.
//!
//! Pre-flight cost: one 20x3 BBTerm per test, 16-line scrollback. Largest
//! test is the flood: 200 x 64 KiB = 12.5 MiB of input fed in 64 KiB
//! chunks (bounded by the vte parse rate, a second or two in debug); no
//! sleeps, no I/O, no allocation beyond the chunk Vec itself.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

const KIND_NOTIFICATION: u32 = 8;
const SEP: char = '\u{1F}';
const CAP: usize = 64 * 1024;
const SHY: &str = "\u{00AD}";

#[derive(Default)]
struct Sink {
    events: Vec<(u32, Vec<u8>)>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    let bytes: Vec<u8> = if ev.payload.is_null() || ev.len == 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    };
    let sink = &*(ctx as *const Mutex<Sink>);
    sink.lock().unwrap().events.push((ev.kind as u32, bytes));
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
        let term = unsafe { bc::bb_term_new(20, 3, 16) };
        assert!(!term.is_null(), "bb_term_new returned null");
        unsafe { bc::bb_term_set_event_cb(term, Some(capture_cb), ctx) };
        Harness { term, sink, ctx }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    /// Feed one OSC 99 sequence: `ESC ] 99 ; <meta> ; <payload> BEL`.
    fn osc99(&self, meta: &str, payload: &str) {
        let mut v = Vec::with_capacity(payload.len() + meta.len() + 8);
        v.extend_from_slice(b"\x1b]99;");
        v.extend_from_slice(meta.as_bytes());
        v.push(b';');
        v.extend_from_slice(payload.as_bytes());
        v.push(0x07);
        self.feed(&v);
    }

    /// Feed `bytes` of SHY filler (must be even) as d=0 chunks of at most
    /// 8 KiB each, for the given metadata prefix (e.g. `i=1:p=body`).
    fn filler(&self, meta_without_d: &str, bytes: usize) {
        assert_eq!(bytes % 2, 0, "SHY is 2 bytes");
        let meta = format!("{meta_without_d}:d=0");
        let mut left = bytes;
        while left > 0 {
            let n = left.min(8192);
            self.osc99(&meta, &SHY.repeat(n / 2));
            left -= n;
        }
    }

    fn pairs(&self) -> Vec<(String, String)> {
        self.sink
            .lock()
            .unwrap()
            .events
            .iter()
            .filter(|(k, _)| *k == KIND_NOTIFICATION)
            .map(|(_, p)| {
                let s = String::from_utf8(p.clone()).expect("UTF-8 notification payload");
                let (t, b) = s.split_once(SEP).expect("U+001F separator");
                (t.to_string(), b.to_string())
            })
            .collect()
    }

    fn first_row_char0(&self) -> u32 {
        unsafe {
            let snap = bc::bb_term_take_snapshot(self.term);
            assert!(!snap.is_null());
            let ch = (*(*snap).cells).ch;
            bc::bb_snap_release(snap);
            ch
        }
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

// ------------------------------------------------- behaviour that must hold

#[test]
fn chunked_notification_below_cap_concatenates_in_order() {
    let h = Harness::new();
    h.osc99("i=1:p=title:d=0", "Build ");
    h.osc99("i=1:p=title:d=0", "done");
    h.osc99("i=1:p=body:d=0", "one ");
    h.osc99("i=1:p=body:d=0", "two ");
    assert!(h.pairs().is_empty(), "no emit while d=0 chunks are pending");
    h.osc99("i=1:p=body", "three");
    assert_eq!(
        h.pairs(),
        vec![("Build done".to_string(), "one two three".to_string())]
    );
}

#[test]
fn content_that_exactly_fills_the_cap_is_kept() {
    // 65532 bytes of invisible filler + "TAIL" (4 bytes) == exactly 65536.
    let h = Harness::new();
    h.filler("i=1:p=body", CAP - 4);
    h.osc99("i=1:p=body", "TAIL");
    assert_eq!(h.pairs(), vec![(String::new(), "TAIL".to_string())]);
}

#[test]
fn flood_of_same_id_chunks_then_final_chunk_emits_one_bounded_notification() {
    // 200 x 64 KiB of visible text under ONE id, never finalised.
    let h = Harness::new();
    let chunk = "A".repeat(CAP);
    for _ in 0..200 {
        h.osc99("i=1:d=0", &chunk);
    }
    assert!(h.pairs().is_empty(), "d=0 chunks must not emit");
    h.osc99("i=1", "END");
    let pairs = h.pairs();
    assert_eq!(
        pairs.len(),
        1,
        "exactly one notification, got {}",
        pairs.len()
    );
    let (title, body) = &pairs[0];
    assert_eq!(title, "");
    assert_eq!(body.chars().count(), 1024, "body display cap still applies");
    assert!(body.chars().all(|c| c == 'A'));
}

#[test]
fn terminal_stays_usable_after_a_flood() {
    let h = Harness::new();
    let chunk = "B".repeat(CAP);
    for _ in 0..50 {
        h.osc99("i=7:d=0", &chunk);
    }
    h.osc99("i=7", "x");
    h.feed(b"Z");
    assert_eq!(h.first_row_char0(), 'Z' as u32, "grid still receives text");
    // A fresh id after the flood starts from empty pending state.
    h.osc99("i=8", "fresh");
    let pairs = h.pairs();
    assert_eq!(pairs.last().unwrap(), &(String::new(), "fresh".to_string()));
}

#[test]
fn a_different_id_starts_with_a_full_cap_of_room() {
    // id 1 saturates its body (invisible content), id 2 flushes it (nothing
    // visible -> no emit) and then has its own full headroom.
    let h = Harness::new();
    h.filler("i=1:p=body", CAP);
    h.osc99("i=2:p=body:d=0", "FRESH");
    h.osc99("i=2:p=body", "!");
    assert_eq!(h.pairs(), vec![(String::new(), "FRESH!".to_string())]);
}

// ------------------------------------- behaviour that the cap introduces

#[test]
fn body_bytes_past_the_cap_are_dropped() {
    // Exactly CAP bytes of invisible filler, then a visible tail in the
    // final chunk: the tail has no room, the body is empty after scrub and
    // nothing is emitted.
    let h = Harness::new();
    h.filler("i=1:p=body", CAP);
    h.osc99("i=1:p=body", "TAIL");
    assert!(
        h.pairs().is_empty(),
        "tail past the 64 KiB body cap must be dropped, got {:?}",
        h.pairs()
    );
}

#[test]
fn cap_boundary_is_byte_exact() {
    // 65534 filler bytes leave exactly two bytes of room: "AB" fits, "C" not.
    let h = Harness::new();
    h.filler("i=1:p=body", CAP - 2);
    h.osc99("i=1:p=body", "ABC");
    assert_eq!(h.pairs(), vec![(String::new(), "AB".to_string())]);
}

#[test]
fn cap_applies_across_many_d0_chunks_not_per_chunk() {
    // Room is consumed by earlier d=0 chunks: filler fills the cap in 8 KiB
    // pieces, a further visible d=0 chunk is dropped, the final chunk too.
    let h = Harness::new();
    h.filler("i=1:p=body", CAP);
    h.osc99("i=1:p=body:d=0", "MORE");
    h.osc99("i=1:p=body", "AND MORE");
    assert!(h.pairs().is_empty(), "got {:?}", h.pairs());
}

#[test]
fn title_and_body_caps_are_independent() {
    // Title saturates (and its extra "TLE" is dropped); body is untouched
    // by that and keeps its own full room.
    let h = Harness::new();
    h.filler("i=1:p=title", CAP - 2);
    h.osc99("i=1:p=title:d=0", "TI");
    h.osc99("i=1:p=title:d=0", "TLE");
    h.osc99("i=1:p=body", "BODY");
    assert_eq!(h.pairs(), vec![("TI".to_string(), "BODY".to_string())]);
}

#[test]
fn saturated_body_does_not_shrink_the_title_room() {
    let h = Harness::new();
    h.filler("i=1:p=body", CAP);
    h.osc99("i=1:p=body:d=0", "lost");
    h.osc99("i=1:p=title", "Kept");
    assert_eq!(h.pairs(), vec![("Kept".to_string(), String::new())]);
}

#[test]
fn multibyte_scalar_straddling_the_cap_never_leaks_past_it() {
    // 65534 filler + "A" + "é" (C3 A9): only one byte of room remains for
    // the é, so it is cut mid-scalar. The kept prefix is visible, the full
    // "é" is not, and the emit does not panic or fail.
    let h = Harness::new();
    h.filler("i=1:p=body", CAP - 2);
    h.osc99("i=1:p=body", "A\u{e9}");
    let pairs = h.pairs();
    assert_eq!(pairs.len(), 1, "got {:?}", pairs);
    assert!(pairs[0].1.starts_with('A'), "got {:?}", pairs[0].1);
    assert!(!pairs[0].1.contains('\u{e9}'), "got {:?}", pairs[0].1);
}
