//! Pins the bytes we generate in reply to DSR / DA / CPR / DECSCUSR queries.
//!
//! Many TUIs (vim, nvim, tmux, less, htop, readline) probe the terminal at
//! startup with these queries and block waiting for a reply. If the reply
//! never arrives they either hang (waiting on `read`) or fall back to a less
//! capable mode. Golden-ing the exact reply bytes means a future refactor of
//! our event plumbing — or an alacritty upgrade that changes one of these
//! strings — fails a test rather than silently breaking shell integration.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

/// Captures every PtyWrite payload fired during a test. Anything else is
/// ignored — we only care about the bytes the terminal wants to send back to
/// the shell here.
#[derive(Default)]
struct Captured {
    pty_writes: Vec<Vec<u8>>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    if ev.kind as u32 != bc::BBEventKind::PtyWrite as u32 {
        return;
    }
    if ev.payload.is_null() || ev.len == 0 {
        return;
    }
    let cap = &*(ctx as *const Mutex<Captured>);
    let bytes = std::slice::from_raw_parts(ev.payload, ev.len);
    cap.lock().unwrap().pty_writes.push(bytes.to_vec());
}

/// Spin up a terminal, register the capture callback, feed `input`, return
/// the collected PtyWrite payloads in order.
fn run(input: &[u8]) -> Vec<Vec<u8>> {
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;

    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        assert!(!term.is_null());
        bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
        bc::bb_term_input(term, input.as_ptr(), input.len());
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        // Reclaim the Arc we leaked above so the Drop runs.
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }

    let guard = cap.lock().unwrap();
    guard.pty_writes.clone()
}

// ---------------------------------------------------------------------------
// DSR — Device Status Report
// ---------------------------------------------------------------------------

#[test]
fn dsr_status_report_replies_ok() {
    // ESC[5n asks "are you OK?"; reply is ESC[0n ("ready, no malfunction").
    let writes = run(b"\x1b[5n");
    assert_eq!(writes, vec![b"\x1b[0n".to_vec()]);
}

#[test]
fn dsr_cursor_position_report_1_indexed() {
    // Cursor starts at (1,1). ESC[6n replies with CPR: ESC[row;colR, 1-indexed.
    let writes = run(b"\x1b[6n");
    assert_eq!(writes, vec![b"\x1b[1;1R".to_vec()]);
}

#[test]
fn dsr_cursor_position_report_after_move() {
    // Move cursor to row 5, col 12, then query.
    let writes = run(b"\x1b[5;12Habc\x1b[6n");
    // Cursor moved 3 cells right by "abc" so col should be 15.
    assert_eq!(writes, vec![b"\x1b[5;15R".to_vec()]);
}

// ---------------------------------------------------------------------------
// DA — Device Attributes
// ---------------------------------------------------------------------------

#[test]
fn da1_primary_device_attributes() {
    // ESC[c and ESC[0c are equivalent DA1 queries. alacritty identifies as
    // VT102 (`ESC[?6c`) — inherit that. If this assertion ever changes, a
    // shell somewhere is likely to start behaving differently.
    let writes = run(b"\x1b[c");
    assert_eq!(writes, vec![b"\x1b[?6c".to_vec()]);

    let writes = run(b"\x1b[0c");
    assert_eq!(writes, vec![b"\x1b[?6c".to_vec()]);
}

#[test]
fn da2_secondary_device_attributes() {
    // ESC[>c → ESC[>0;<alacritty version number>;1c
    // We can't assert the exact version number (it changes with crate bumps)
    // but we can assert the prefix and suffix stay stable.
    let writes = run(b"\x1b[>c");
    assert_eq!(writes.len(), 1);
    let reply = &writes[0];
    assert!(
        reply.starts_with(b"\x1b[>0;"),
        "DA2 reply prefix wrong: {:?}",
        reply
    );
    assert!(
        reply.ends_with(b";1c"),
        "DA2 reply suffix wrong: {:?}",
        reply
    );
}

// ---------------------------------------------------------------------------
// Kitty keyboard — report active mode
// ---------------------------------------------------------------------------

#[test]
fn kitty_report_active_mode_initial_is_zero() {
    // ESC[?u asks for the active kitty keyboard mode; should be zero before
    // anything has been pushed.
    let writes = run(b"\x1b[?u");
    assert_eq!(writes, vec![b"\x1b[?0u".to_vec()]);
}

#[test]
fn kitty_report_active_mode_after_push() {
    // Push flag 1 (DISAMBIGUATE_ESC_CODES), then query — must round-trip.
    let writes = run(b"\x1b[>1u\x1b[?u");
    assert_eq!(writes, vec![b"\x1b[?1u".to_vec()]);
}

// ---------------------------------------------------------------------------
// Ordering — a query stream produces replies in order
// ---------------------------------------------------------------------------

#[test]
fn multiple_queries_reply_in_order() {
    // A startup probe stream: DA1, DSR 5, DSR 6 — each in sequence.
    let writes = run(b"\x1b[c\x1b[5n\x1b[6n");
    assert_eq!(
        writes,
        vec![
            b"\x1b[?6c".to_vec(),
            b"\x1b[0n".to_vec(),
            b"\x1b[1;1R".to_vec(),
        ]
    );
}
