//! Pin that the OSC 52 read-back form (`OSC 52;c;?`) does NOT echo the
//! user's clipboard back into the PTY.
//!
//! Threat: a hostile `cat` of a crafted file, a compromised ssh server,
//! or a malicious wrapper script emits `\x1b]52;c;?\x07` to the terminal.
//! If the terminal responds to that by base64-encoding the user's
//! system clipboard and writing it back as PTY input, every clipboard
//! entry (passwords from a password manager, secrets, PII) is exposed
//! to the remote end as plaintext stdin — and it reaches the shell
//! immediately, where history, process accounting, and tee'd scripts
//! can all capture it.
//!
//! alacritty_terminal 0.26 fires `Event::ClipboardLoad(ty, formatter)`
//! on this sequence, with a formatter that would produce the leaking
//! reply. Our `RoutingListener` only forwards `ClipboardStore` — every
//! other variant goes through `_ => {}` and is dropped — so
//! `ClipboardLoad` never reaches the callback, which means no PtyWrite
//! ever gets fired. This test pins that invariant so a future change
//! to the Event match can't silently open the leak.

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
    if ev.kind as u32 == bc::BBEventKind::PtyWrite as u32
        && !ev.payload.is_null()
        && ev.len > 0
    {
        let bytes = std::slice::from_raw_parts(ev.payload, ev.len);
        guard.pty_writes.push(bytes.to_vec());
    }
}

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
fn osc52_readback_c_clipboard_does_not_echo() {
    // Canonical form: OSC 52 ; c ; ? BEL
    let (events, writes) = feed(b"\x1b]52;c;?\x07");
    assert!(
        events.is_empty(),
        "OSC 52 read-back must not produce any events; got {:?}",
        events
    );
    assert!(
        writes.is_empty(),
        "OSC 52 read-back must not echo clipboard bytes back to PTY; got {} writes: {:?}",
        writes.len(),
        writes
    );
}

#[test]
fn osc52_readback_p_primary_does_not_echo() {
    // Primary selection variant. Same rule — must not reply.
    let (events, writes) = feed(b"\x1b]52;p;?\x07");
    assert!(events.is_empty(), "expected no events, got {:?}", events);
    assert!(writes.is_empty(), "no PtyWrite allowed; got {:?}", writes);
}

#[test]
fn osc52_readback_st_terminator_does_not_echo() {
    // ESC \ terminator form — same behavior required.
    let (events, writes) = feed(b"\x1b]52;c;?\x1b\\");
    assert!(
        events.is_empty(),
        "ST-terminated OSC 52 read-back must be inert; got events {:?}",
        events
    );
    assert!(
        writes.is_empty(),
        "ST-terminated OSC 52 read-back must not reply; got {:?}",
        writes
    );
}

#[test]
fn osc52_readback_empty_selection_list_does_not_echo() {
    // Some clients send an empty selection field (`OSC 52;;?`) meaning
    // "default selection". Must behave identically — no echo.
    let (events, writes) = feed(b"\x1b]52;;?\x07");
    assert!(
        events.is_empty(),
        "empty-selection read-back must be inert; got {:?}",
        events
    );
    assert!(
        writes.is_empty(),
        "empty-selection read-back must not reply; got {:?}",
        writes
    );
}

#[test]
fn osc52_store_is_allowed_and_surfaces_as_event() {
    // Counter-check: writes ARE accepted and surface as Osc52Clipboard
    // events. This ensures we haven't over-blocked clipboard I/O: the
    // "set" direction remains functional (gated by prefs in Swift),
    // only "get" is blocked at the FFI bridge.
    // Payload "aGVsbG8=" is base64("hello").
    let (events, _writes) = feed(b"\x1b]52;c;aGVsbG8=\x07");
    assert!(
        events.contains(&(bc::BBEventKind::Osc52Clipboard as u32)),
        "write-form OSC 52 must still fire Osc52Clipboard; got {:?}",
        events
    );
}
