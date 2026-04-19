//! Pin that arbitrary DCS (Device Control String) sequences we don't
//! implement are inert: no BBEvent fires and no PtyWrite is echoed back
//! to the shell. Motivated by iTerm2 CVE-2026-41253, where a
//! `DCS 2000p ... ST` "conductor protocol" handshake from local content
//! (`cat readme.txt`) was treated as active control input and led to
//! code execution. We don't handle DCS at all in our FFI bridge — this
//! test locks that in so a future `Event::` variant addition can't
//! accidentally open a surface without a deliberate matching arm.
//!
//! The general principle: alacritty_terminal's VTE parser routes DCS
//! dispatches internally. Our `RoutingListener` only forwards Bell,
//! Title, ClipboardStore, PtyWrite, CwdChanged — every other Event
//! variant is explicitly dropped (`_ => {}`). A DCS handshake therefore
//! must not surface as any event kind, must not echo bytes back, and
//! must not corrupt the visible grid.

use std::ffi::CStr;
use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

#[derive(Default)]
struct Captured {
    events: Vec<u32>,
    pty_writes: Vec<Vec<u8>>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    let cap = &*(ctx as *const Mutex<Captured>);
    let mut guard = cap.lock().unwrap();
    guard.events.push(ev.kind as u32);
    if ev.kind as u32 == bc::BBEventKind::PtyWrite as u32 && !ev.payload.is_null() && ev.len > 0 {
        let bytes = std::slice::from_raw_parts(ev.payload, ev.len);
        guard.pty_writes.push(bytes.to_vec());
    }
}

/// Feed `input` into a fresh 80×24 terminal and return (all event kinds,
/// PtyWrite payloads).
fn feed(input: &[u8]) -> (Vec<u32>, Vec<Vec<u8>>) {
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;

    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        assert!(!term.is_null());
        bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
        bc::bb_term_input(term, input.as_ptr(), input.len());
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }

    let guard = cap.lock().unwrap();
    (guard.events.clone(), guard.pty_writes.clone())
}

#[test]
fn fake_iterm2_conductor_dcs_is_inert() {
    // Reproduce the iTerm2 CVE-2026-41253 payload shape: `DCS 2000p`
    // opens a "conductor protocol" session in iTerm2; we must NOT
    // interpret anything about that — no events, no PTY reply.
    // Follow with arbitrary payload bytes and an ST terminator.
    let input = b"\x1bP2000p\x1b]135;somepayload\x07\x1b\\";
    let (events, writes) = feed(input);
    assert!(
        events.is_empty(),
        "DCS conductor-style handshake must produce zero events, got: {:?}",
        events
    );
    assert!(
        writes.is_empty(),
        "DCS conductor handshake must not echo bytes back to PTY"
    );
}

#[test]
fn sixel_dcs_is_inert_not_dangerous() {
    // Sixel (`DCS q ... ST`) is a graphics sequence we don't implement.
    // It must be silently discarded — no callback events, no PTY echo,
    // no trap.
    let input = b"\x1bPq#0;2;0;0;0#1;2;100;100;100~~~\x1b\\";
    let (events, writes) = feed(input);
    assert!(
        events.is_empty(),
        "Sixel DCS must not surface any event: {:?}",
        events
    );
    assert!(writes.is_empty(), "Sixel DCS must not trigger PtyWrite");
}

#[test]
fn dcs_followed_by_real_input_still_processes_real_input() {
    // Defensive: the DCS parser must terminate cleanly on `ST` and
    // return to ground state so subsequent printable bytes land in
    // the grid as normal. A test here is how we'd catch a regression
    // where a DCS parser gets stuck consuming every byte after.
    let input = b"\x1bPqignore\x1b\\hello";
    let _ = feed(input);
    // The reliable check: a subsequent DA1 query after the DCS returns
    // the standard reply (\x1b[?6c), which means the state machine is
    // no longer stuck inside DCS.
    let probe = b"\x1bPqgarbage\x1b\\\x1b[c";
    let (_events, writes) = feed(probe);
    assert!(
        writes.iter().any(|w| w == b"\x1b[?6c"),
        "after DCS+ST the parser must return to ground and reply to DA1, got writes: {:?}",
        writes
    );
}

#[test]
fn truncated_dcs_without_st_does_not_swallow_forever() {
    // A DCS introduced but never ST-terminated should eventually fail
    // closed. We don't pin "how" (alacritty's VTE has its own limits);
    // we only pin "no crash, no event, no echo" for a reasonably long
    // unterminated stream. Construction: ~8 KiB of payload bytes
    // after `DCS q`.
    let mut input: Vec<u8> = Vec::with_capacity(8200);
    input.extend_from_slice(b"\x1bPq");
    input.extend(std::iter::repeat_n(b'~', 8000));
    let (events, writes) = feed(&input);
    assert!(
        events.is_empty(),
        "unterminated DCS must not surface events: {:?}",
        events
    );
    assert!(writes.is_empty(), "unterminated DCS must not echo bytes");
}

/// Sanity reference: after a DCS block the grid still contains only the
/// trailing printable bytes — the DCS payload itself never reaches the
/// grid. We use `bb_term_text_range` to inspect row 0.
#[test]
fn dcs_payload_does_not_reach_grid() {
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        assert!(!term.is_null());
        let input = b"\x1bPq#0;2;0;0;0~~~~~~~~\x1b\\HELLO";
        bc::bb_term_input(term, input.as_ptr(), input.len());
        let raw = bc::bb_term_text_range(term, 0, 0, 0, 79, 0);
        assert!(!raw.is_null(), "text_range must not be null");
        let slice = std::slice::from_raw_parts((*raw).bytes, (*raw).len);
        let text = std::str::from_utf8(slice).unwrap_or("");
        // `HELLO` should appear on row 0; the `~` tildes must not.
        assert!(
            text.contains("HELLO"),
            "trailing plaintext after DCS should reach grid, got: {:?}",
            &text[..text.len().min(200)]
        );
        assert!(
            !text.contains("~~~~~"),
            "DCS sixel payload must not bleed into grid text, got: {:?}",
            &text[..text.len().min(200)]
        );
        bc::bb_string_release(raw);
        bc::bb_term_free(term);
    }
}

// Silence the "unused" warning on CStr in case a future test needs
// C string conversion. Keep the import for discoverability.
#[allow(dead_code)]
fn _keep_cstr_imported(p: *const std::os::raw::c_char) -> &'static CStr {
    unsafe { CStr::from_ptr(p) }
}
