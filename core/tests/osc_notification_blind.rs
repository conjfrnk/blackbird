//! Blind behaviour tests for program-originated desktop notifications
//! (OSC 9 / OSC 777 / OSC 99), written from the spec without sight of the
//! handler implementation.
//!
//! Contract under test (see `BBEventKind::Notification` in BBCore.h):
//!   - Kind 8, `i32_arg` 0, payload UTF-8 `"<title>\u{1F}<body>"`.
//!   - OSC 9 `;<body>` (iTerm2 form) — title empty. The ConEmu progress
//!     form `9;4;…` is NOT a notification.
//!   - OSC 777 `;notify;<title>;<body>` — any other 777 verb is ignored.
//!   - OSC 99 kitty: `p=body` / `p=title` metadata selects the half; an
//!     empty metadata field means body.
//!   - Both halves are scrubbed of C0 controls and bidi-override scalars,
//!     title capped at 128 chars, body at 1024 chars; if both halves are
//!     empty after scrubbing nothing is emitted.
//!   - Rate-capped to `NOTIFICATION_EVENT_PER_SECOND` = 4 per tumbling
//!     window; `bb_term_clear_all` resets the limiter.
//!   - No Title / Bell / PtyWrite side effects, no visible-grid mutation.
//!
//! Pre-flight cost: one 20×3 BBTerm per test, 16-line scrollback; the
//! largest input is ~2 KiB (the truncation cases). No sleeps, no I/O.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

const KIND_NOTIFICATION: u32 = 8;
const NOTIFICATION_EVENT_PER_SECOND: usize = 4;
const SEP: char = '\u{1F}';

#[derive(Clone, Debug, PartialEq)]
struct Captured {
    kind: u32,
    payload: Vec<u8>,
    i32_arg: i32,
}

#[derive(Default)]
struct Sink {
    events: Vec<Captured>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    if ev.payload.is_null() {
        assert_eq!(ev.len, 0, "BBEvent contract: null payload must have len 0");
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
        i32_arg: ev.i32_arg,
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
        let term = unsafe { bc::bb_term_new(20, 3, 16) };
        assert!(!term.is_null(), "bb_term_new returned null");
        unsafe { bc::bb_term_set_event_cb(term, Some(capture_cb), ctx) };
        Harness { term, sink, ctx }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    fn clear_all(&self) {
        unsafe { bc::bb_term_clear_all(self.term) };
    }

    fn all_events(&self) -> Vec<Captured> {
        self.sink.lock().unwrap().events.clone()
    }

    fn notifications(&self) -> Vec<Captured> {
        self.all_events()
            .into_iter()
            .filter(|e| e.kind == KIND_NOTIFICATION)
            .collect()
    }

    /// Decoded `(title, body)` of every Notification event, in order.
    fn notification_pairs(&self) -> Vec<(String, String)> {
        self.notifications()
            .iter()
            .map(|e| {
                let s = String::from_utf8(e.payload.clone())
                    .expect("notification payload must be valid UTF-8");
                let mut halves = s.splitn(2, SEP);
                let title = halves.next().unwrap_or("").to_string();
                let body = halves
                    .next()
                    .unwrap_or_else(|| panic!("payload {s:?} lacks the U+001F separator"))
                    .to_string();
                (title, body)
            })
            .collect()
    }

    /// Kinds of every event that is NOT a Notification.
    fn other_kinds(&self) -> Vec<u32> {
        self.all_events()
            .iter()
            .filter(|e| e.kind != KIND_NOTIFICATION)
            .map(|e| e.kind)
            .collect()
    }

    fn first_row(&self) -> Vec<u32> {
        unsafe {
            let snap = bc::bb_term_take_snapshot(self.term);
            assert!(!snap.is_null(), "snapshot must be available");
            let cols = (*snap).cols as usize;
            let row: Vec<u32> = (0..cols).map(|i| (*(*snap).cells.add(i)).ch).collect();
            bc::bb_snap_release(snap);
            row
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

/// Assert exactly one Notification event was emitted and that it decodes
/// to `expected` (`"title\u{1F}body"`), with `i32_arg == 0`.
fn assert_single(h: &Harness, expected: &str) {
    let events = h.notifications();
    assert_eq!(
        events.len(),
        1,
        "expected exactly one Notification event, got {:?}",
        events
    );
    let payload = String::from_utf8(events[0].payload.clone()).expect("UTF-8 payload");
    assert_eq!(payload, expected, "payload mismatch");
    assert_eq!(events[0].i32_arg, 0, "Notification i32_arg must be 0");
}

// ---------------------------------------------------------------- OSC 9

#[test]
fn osc9_bel_terminated_emits_body_only_notification() {
    let h = Harness::new();
    h.feed(b"\x1b]9;Build finished\x07");
    assert_single(&h, "\u{1F}Build finished");
}

#[test]
fn osc9_st_terminated_keeps_semicolons_inside_body() {
    let h = Harness::new();
    h.feed(b"\x1b]9;hello;world\x1b\\");
    assert_single(&h, "\u{1F}hello;world");
}

#[test]
fn osc9_conemu_progress_form_is_not_a_notification() {
    let h = Harness::new();
    h.feed(b"\x1b]9;4;1;50\x07");
    assert!(
        h.notifications().is_empty(),
        "OSC 9;4;… (ConEmu / Windows Terminal progress) must not notify; got {:?}",
        h.notification_pairs()
    );
}

// -------------------------------------------------------------- OSC 777

#[test]
fn osc777_notify_carries_title_and_body() {
    let h = Harness::new();
    h.feed(b"\x1b]777;notify;Deploy;done in 3s\x07");
    assert_single(&h, "Deploy\u{1F}done in 3s");
}

#[test]
fn osc777_unknown_verb_emits_nothing() {
    let h = Harness::new();
    h.feed(b"\x1b]777;something-else;x;y\x07");
    assert!(
        h.notifications().is_empty(),
        "OSC 777 with a non-`notify` verb must be ignored; got {:?}",
        h.notification_pairs()
    );
}

// --------------------------------------------------------------- OSC 99

#[test]
fn osc99_p_body_metadata_fills_body() {
    let h = Harness::new();
    h.feed(b"\x1b]99;i=1:p=body;Tests passed\x07");
    assert_single(&h, "\u{1F}Tests passed");
}

#[test]
fn osc99_p_title_metadata_fills_title() {
    let h = Harness::new();
    h.feed(b"\x1b]99;i=1:p=title;Title Only\x07");
    assert_single(&h, "Title Only\u{1F}");
}

#[test]
fn osc99_empty_metadata_defaults_to_body() {
    let h = Harness::new();
    h.feed(b"\x1b]99;;plain\x07");
    assert_single(&h, "\u{1F}plain");
}

// ------------------------------------------------------------ scrubbing

#[test]
fn scrub_removes_c0_and_bidi_override_scalars() {
    let h = Harness::new();
    let mut input: Vec<u8> = Vec::new();
    input.extend_from_slice(b"\x1b]9;a\x01b");
    input.extend_from_slice("\u{202E}".as_bytes());
    input.extend_from_slice(b"c\x07");
    h.feed(&input);
    assert_single(&h, "\u{1F}abc");
}

#[test]
fn title_is_truncated_to_128_chars() {
    let h = Harness::new();
    let long_title = "t".repeat(200);
    let mut input: Vec<u8> = Vec::new();
    input.extend_from_slice(b"\x1b]777;notify;");
    input.extend_from_slice(long_title.as_bytes());
    input.extend_from_slice(b";body\x07");
    h.feed(&input);

    let pairs = h.notification_pairs();
    assert_eq!(pairs.len(), 1, "expected one notification, got {:?}", pairs);
    let (title, body) = &pairs[0];
    assert_eq!(
        title.chars().count(),
        128,
        "title must be capped at 128 chars (got {})",
        title.chars().count()
    );
    assert!(
        title.chars().all(|c| c == 't'),
        "truncation must keep the leading chars intact"
    );
    assert_eq!(body, "body", "body must be unaffected by the title cap");
}

#[test]
fn body_is_truncated_to_1024_chars() {
    let h = Harness::new();
    let long_body = "b".repeat(2000);
    let mut input: Vec<u8> = Vec::new();
    input.extend_from_slice(b"\x1b]9;");
    input.extend_from_slice(long_body.as_bytes());
    input.extend_from_slice(b"\x07");
    h.feed(&input);

    let pairs = h.notification_pairs();
    assert_eq!(pairs.len(), 1, "expected one notification, got {:?}", pairs);
    let (title, body) = &pairs[0];
    assert_eq!(title, "", "OSC 9 title must be empty");
    assert_eq!(
        body.chars().count(),
        1024,
        "body must be capped at 1024 chars (got {})",
        body.chars().count()
    );
    assert!(body.chars().all(|c| c == 'b'));
}

#[test]
fn both_halves_empty_emits_nothing() {
    let h = Harness::new();
    h.feed(b"\x1b]9;\x07");
    assert!(
        h.notifications().is_empty(),
        "empty title + empty body must not notify; got {:?}",
        h.notification_pairs()
    );
}

#[test]
fn halves_that_scrub_to_empty_emit_nothing() {
    let h = Harness::new();
    // Title and body are made only of scrubbed scalars.
    let mut input: Vec<u8> = Vec::new();
    input.extend_from_slice(b"\x1b]777;notify;\x01\x02;");
    input.extend_from_slice("\u{202E}\u{202D}".as_bytes());
    input.extend_from_slice(b"\x07");
    h.feed(&input);
    assert!(
        h.notifications().is_empty(),
        "halves that are empty AFTER scrubbing must not notify; got {:?}",
        h.notification_pairs()
    );
}

// ------------------------------------------------------------- rate cap

#[test]
fn burst_of_20_is_capped_at_4_per_window() {
    let h = Harness::new();
    let burst: Vec<u8> = (0..20)
        .flat_map(|n| format!("\x1b]9;{n}\x07").into_bytes())
        .collect();
    h.feed(&burst);

    let pairs = h.notification_pairs();
    assert_eq!(
        pairs.len(),
        NOTIFICATION_EVENT_PER_SECOND,
        "a 20-notification burst must yield exactly {} events, got {:?}",
        NOTIFICATION_EVENT_PER_SECOND,
        pairs
    );
    // The first four in the burst are the ones that get through.
    let bodies: Vec<&str> = pairs.iter().map(|(_, b)| b.as_str()).collect();
    assert_eq!(bodies, ["0", "1", "2", "3"]);
}

#[test]
fn clear_all_resets_the_rate_window() {
    let h = Harness::new();
    let burst: Vec<u8> = (0..20)
        .flat_map(|n| format!("\x1b]9;{n}\x07").into_bytes())
        .collect();
    h.feed(&burst);
    assert_eq!(h.notifications().len(), NOTIFICATION_EVENT_PER_SECOND);

    h.clear_all();
    h.feed(&burst);
    assert_eq!(
        h.notifications().len(),
        2 * NOTIFICATION_EVENT_PER_SECOND,
        "after bb_term_clear_all a fresh burst must again yield {} events",
        NOTIFICATION_EVENT_PER_SECOND
    );
}

// -------------------------------------------------------- side effects

#[test]
fn notification_sequences_emit_no_other_events_and_leave_the_grid_alone() {
    let h = Harness::new();
    let blank_row = h.first_row();

    h.feed(b"\x1b]9;Build finished\x07");
    h.feed(b"\x1b]777;notify;Deploy;done in 3s\x07");
    h.feed(b"\x1b]99;i=1:p=body;Tests passed\x07");
    h.feed(b"\x1b]9;4;1;50\x07");
    h.feed(b"\x1b]777;something-else;x;y\x07");

    assert_eq!(
        h.notifications().len(),
        3,
        "three real notifications expected"
    );
    assert!(
        h.other_kinds().is_empty(),
        "no Title / Bell / PtyWrite / other event may leak from a notification \
         sequence; got kinds {:?}",
        h.other_kinds()
    );
    assert_eq!(
        h.first_row(),
        blank_row,
        "notification sequences must not write anything to the visible grid"
    );
}
