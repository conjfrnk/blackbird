//! Blind behaviour tests for the PTY-write reply rate limiter.
//!
//! Terminal-identification queries (DSR / DA / CPR …) make the core write
//! bytes BACK to the shell. A hostile stream can spam those queries; the
//! core caps replies with a token bucket: a burst capacity of 128 replies,
//! refilled at 32 replies per second. Replies past the cap are dropped
//! silently — no Fatal, no reply. `bb_term_clear_all` (⌘K) resets the bucket.
//!
//! The previous limiter was a tumbling window that let a 200-query burst
//! through as 32 replies once the window rolled; these tests pin the bucket
//! semantics so that regression cannot return.
//!
//! Cost: the sleep test is the only one that waits — one 250 ms
//! `thread::sleep`, total wall < 1 s. Every other test is a few hundred
//! bytes of input against an 80×24 grid (< 1 MB).

use std::ffi::c_void;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use blackbird_core::*;

const BURST: usize = 128;
const REFILL_PER_SEC: f64 = 32.0;

struct Sink {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
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

fn dsr_burst(n: usize) -> Vec<u8> {
    b"\x1b[6n".repeat(n)
}

fn count(sink: &Sink, kind: BBEventKind) -> usize {
    sink.events
        .lock()
        .unwrap()
        .iter()
        .filter(|(k, _)| *k == kind as u32)
        .count()
}

fn pty_writes(sink: &Sink) -> Vec<Vec<u8>> {
    sink.events
        .lock()
        .unwrap()
        .iter()
        .filter(|(k, _)| *k == BBEventKind::PtyWrite as u32)
        .map(|(_, p)| p.clone())
        .collect()
}

unsafe fn make_term(sink: &Sink) -> *mut BBTerm {
    let term = bb_term_new(80, 24, 1000);
    assert!(!term.is_null());
    bb_term_set_event_cb(term, Some(cb), sink as *const Sink as *mut c_void);
    term
}

unsafe fn feed(term: *mut BBTerm, bytes: &[u8]) {
    bb_term_input(term, bytes.as_ptr(), bytes.len());
}

#[test]
fn burst_of_128_replies_to_every_query() {
    let sink = Sink {
        events: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = make_term(&sink);
        feed(term, &dsr_burst(BURST));
        bb_term_free(term);
    }
    assert_eq!(count(&sink, BBEventKind::PtyWrite), BURST);
    assert_eq!(count(&sink, BBEventKind::Fatal), 0);
    for reply in pty_writes(&sink) {
        assert_eq!(
            reply,
            b"\x1b[1;1R".to_vec(),
            "every reply is a CPR for (1,1)"
        );
    }
}

#[test]
fn burst_of_200_caps_at_128_and_drops_the_rest_silently() {
    let sink = Sink {
        events: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = make_term(&sink);
        feed(term, &dsr_burst(200));
        bb_term_free(term);
    }
    assert_eq!(
        count(&sink, BBEventKind::PtyWrite),
        BURST,
        "a 200-query burst must yield exactly the bucket capacity (128) — \
         not 32 (the old tumbling window) and not 200"
    );
    assert_eq!(
        count(&sink, BBEventKind::Fatal),
        0,
        "dropped replies are silent — never a Fatal"
    );
}

#[test]
fn queries_past_the_cap_in_later_calls_are_still_dropped() {
    // Exhaust the bucket, then keep asking in separate bb_term_input calls
    // within the same instant: nothing meaningful can have refilled, so at
    // most a token or two of jitter may leak — never a fresh burst.
    let sink = Sink {
        events: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = make_term(&sink);
        feed(term, &dsr_burst(BURST));
        assert_eq!(count(&sink, BBEventKind::PtyWrite), BURST);
        for _ in 0..4 {
            feed(term, &dsr_burst(50));
        }
        bb_term_free(term);
    }
    let extra = count(&sink, BBEventKind::PtyWrite) - BURST;
    assert!(
        extra <= 2,
        "after exhausting the bucket, 200 more queries in the same instant \
         must be dropped (got {extra} extra replies)"
    );
    assert_eq!(count(&sink, BBEventKind::Fatal), 0);
}

#[test]
fn clear_all_resets_the_bucket() {
    let sink = Sink {
        events: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = make_term(&sink);
        feed(term, &dsr_burst(200));
        assert_eq!(
            count(&sink, BBEventKind::PtyWrite),
            BURST,
            "precondition: bucket drained"
        );

        bb_term_clear_all(term);

        feed(term, &dsr_burst(BURST));
        bb_term_free(term);
    }
    assert_eq!(
        count(&sink, BBEventKind::PtyWrite),
        2 * BURST,
        "⌘K must hand the user a fresh bucket: a second 128 burst after \
         bb_term_clear_all replies in full"
    );
    assert_eq!(count(&sink, BBEventKind::Fatal), 0);
}

/// Sustained refill is 32 replies per second. Cost: one 250 ms sleep;
/// total wall time for this test is well under 1 s.
#[test]
fn sustained_refill_is_32_per_second() {
    let sink = Sink {
        events: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = make_term(&sink);
        feed(term, &dsr_burst(130));
        assert_eq!(
            count(&sink, BBEventKind::PtyWrite),
            BURST,
            "precondition: bucket drained"
        );
        let drained_at = Instant::now();

        std::thread::sleep(Duration::from_millis(250));

        feed(term, &dsr_burst(20));
        let elapsed = drained_at.elapsed();
        bb_term_free(term);

        let extra = count(&sink, BBEventKind::PtyWrite) - BURST;
        let expected = elapsed.as_secs_f64() * REFILL_PER_SEC;
        assert!(
            (6..=10).contains(&extra),
            "expected ~8 refilled replies after 250 ms at 32/s (≈{expected:.1} for the \
             measured {elapsed:?}); got {extra}"
        );
    }
    assert_eq!(count(&sink, BBEventKind::Fatal), 0);
}
