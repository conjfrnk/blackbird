//! OSC 7 current-working-directory reporting.
//!
//! Covers: happy-path `file:///path` ⇒ CwdChanged event; malformed
//! payloads (non-file scheme, bad UTF-8, missing terminator) are silently
//! dropped with no event and no panic.

use std::ffi::c_void;
use std::sync::Mutex;

use blackbird_core::*;

struct Sink {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
}

extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = unsafe { &*(ctx as *const Sink) };
    let bytes = if ev.len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ev.payload, ev.len).to_vec() }
    };
    sink.events.lock().unwrap().push((ev.kind as u32, bytes));
}

fn drive(bytes: &[u8]) -> Vec<(u32, Vec<u8>)> {
    let sink = Sink {
        events: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
        bb_term_input(term, bytes.as_ptr(), bytes.len());
        bb_term_free(term);
    }
    sink.events.into_inner().unwrap()
}

#[test]
fn osc7_well_formed_emits_cwd_changed() {
    let seq = b"\x1b]7;file:///Users/foo/bar\x1b\\";
    let events = drive(seq);
    let cwd = events
        .iter()
        .find(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .expect("expected CwdChanged event");
    assert_eq!(&cwd.1, b"/Users/foo/bar");
}

#[test]
fn osc7_localhost_authority_accepted() {
    let seq = b"\x1b]7;file://localhost/Users/foo\x1b\\";
    let events = drive(seq);
    let cwd = events
        .iter()
        .find(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .expect("expected CwdChanged event");
    assert_eq!(&cwd.1, b"/Users/foo");
}

#[test]
fn osc7_non_file_scheme_ignored() {
    let seq = b"\x1b]7;https://example.com/path\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_malformed_does_not_panic() {
    let seq = b"\x1b]7;not a url at all\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_survives_byte_fragmented_input() {
    let seq = b"\x1b]7;file:///Users/foo/bar\x1b\\";
    let sink = Sink {
        events: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
        for &byte in seq {
            bb_term_input(term, &byte, 1);
        }
        bb_term_free(term);
    }
    let events = sink.events.into_inner().unwrap();
    let matches: Vec<_> = events
        .iter()
        .filter(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .collect();
    assert_eq!(
        matches.len(),
        1,
        "expected exactly one CwdChanged across fragmented input"
    );
    assert_eq!(&matches[0].1, b"/Users/foo/bar");
}
