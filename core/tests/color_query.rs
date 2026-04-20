//! Pins OSC 10 / 11 / 12 color-query responses. Alacritty emits
//! `Event::ColorRequest(index, formatter)` when a TUI sends
//! `\x1b]10;?\x1b\\`, `\x1b]11;?\x1b\\`, or `\x1b]12;?\x1b\\`; our FFI
//! defers the event until after `processor.advance` returns (to avoid
//! re-borrowing &mut Term), then resolves the palette and emits a
//! PtyWrite with the `rgb:RRRR/GGGG/BBBB` reply the TUI expects.

use blackbird_core::*;
use std::ffi::c_void;
use std::sync::Mutex;

#[derive(Default)]
struct Sink {
    events: Mutex<Vec<(u32, Vec<u8>)>>,
}

unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = &*(ctx as *const Sink);
    let bytes = if ev.len > 0 && !ev.payload.is_null() {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    sink.events.lock().unwrap().push((ev.kind as u32, bytes));
}

fn drive(seq: &[u8]) -> Vec<Vec<u8>> {
    let sink = Sink::default();
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
        // Opt in: security default is off (preserves the zsh-vi-mode
        // mitigation pinned by `osc_10_11_color_queries_are_silent`).
        bb_term_set_color_query_enabled(term, 1);
        bb_term_input(term, seq.as_ptr(), seq.len());
        bb_term_free(term);
    }
    let events = sink.events.into_inner().unwrap();
    events
        .into_iter()
        .filter(|(k, _)| *k == BBEventKind::PtyWrite as u32)
        .map(|(_, v)| v)
        .collect()
}

#[test]
fn osc_10_query_emits_rgb_reply_for_default_foreground() {
    // `\x1b]10;?\x1b\\` — "what's your foreground?" — reply format is
    // `\x1b]10;rgb:RRRR/GGGG/BBBB\x1b\\` per xterm specification.
    let writes = drive(b"\x1b]10;?\x1b\\");
    assert_eq!(
        writes.len(),
        1,
        "expected exactly one PtyWrite, got {writes:?}"
    );
    let s = std::str::from_utf8(&writes[0]).expect("reply must be UTF-8");
    assert!(s.starts_with("\x1b]10;rgb:"), "bad prefix: {s:?}");
    assert!(s.ends_with("\x1b\\"), "missing ST terminator: {s:?}");
}

#[test]
fn osc_11_query_replies_with_background() {
    let writes = drive(b"\x1b]11;?\x1b\\");
    assert_eq!(writes.len(), 1);
    let s = std::str::from_utf8(&writes[0]).unwrap();
    assert!(s.starts_with("\x1b]11;rgb:"), "bad prefix: {s:?}");
    assert!(s.ends_with("\x1b\\"));
}

#[test]
fn osc_12_query_replies_with_cursor() {
    let writes = drive(b"\x1b]12;?\x1b\\");
    assert_eq!(writes.len(), 1);
    let s = std::str::from_utf8(&writes[0]).unwrap();
    assert!(s.starts_with("\x1b]12;rgb:"), "bad prefix: {s:?}");
}

#[test]
fn osc_10_query_reflects_set_named_color() {
    // Override foreground to bright red (#FF0000) via bb_term_set_named_color,
    // then query. Reply must carry the new color.
    let sink = Sink::default();
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
        bb_term_set_color_query_enabled(term, 1);
        // Slot 256 = NamedColor::Foreground.
        bb_term_set_named_color(term, 256, 0xFF_0000);
        bb_term_input(term, b"\x1b]10;?\x1b\\".as_ptr(), 9);
        bb_term_free(term);
    }
    let events = sink.events.into_inner().unwrap();
    let writes: Vec<_> = events
        .iter()
        .filter(|(k, _)| *k == BBEventKind::PtyWrite as u32)
        .collect();
    assert_eq!(writes.len(), 1);
    let s = std::str::from_utf8(&writes[0].1).unwrap();
    // Reply uses 4-hex-digit-per-channel format: 0xFF → "ffff", 0x00 → "0000".
    assert!(
        s.contains("rgb:ffff/0000/0000"),
        "expected red in reply, got {s:?}"
    );
}

#[test]
fn non_query_osc_10_does_not_emit_reply() {
    // OSC 10 with a non-`?` argument SETS the color; it must NOT trigger
    // a reply. (Alacritty calls `set_color` rather than
    // `dynamic_color_sequence` in that case.)
    let writes = drive(b"\x1b]10;#ff0000\x1b\\");
    assert!(
        writes.is_empty(),
        "unexpected PtyWrite on OSC 10 SET: {writes:?}"
    );
}

#[test]
fn bel_terminator_also_works_for_query() {
    // `\x1b]11;?\x07` — BEL-terminated form. Common on older shells.
    let writes = drive(b"\x1b]11;?\x07");
    assert_eq!(writes.len(), 1);
    let s = std::str::from_utf8(&writes[0]).unwrap();
    assert!(s.starts_with("\x1b]11;rgb:"));
}
