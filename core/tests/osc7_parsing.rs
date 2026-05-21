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

#[test]
fn osc7_malformed_utf8_path_dropped() {
    // Percent-encoded bytes that decode to invalid UTF-8 (bare continuation).
    let seq = b"\x1b]7;file:///%ff\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_percent_escapes_decoded() {
    let seq = b"\x1b]7;file:///Users/foo%20bar\x1b\\";
    let events = drive(seq);
    let cwd = events
        .iter()
        .find(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .expect("expected CwdChanged event");
    assert_eq!(&cwd.1, b"/Users/foo bar");
}

#[test]
fn osc7_truncated_percent_escape_rejected() {
    // "%2" at end of path — incomplete escape, whole event dropped.
    let seq = b"\x1b]7;file:///foo%2\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

// ─── Audit M13: ASCII control bytes in path ────────────────────────────

#[test]
fn osc7_path_containing_esc_byte_dropped() {
    // %1B → ESC. Symmetric with the OSC title control-char scrub —
    // any control byte (0x01..=0x1F, 0x7F) in a chrome-displayed
    // string is malicious-or-corrupt; refuse the event entirely.
    let seq = b"\x1b]7;file:///foo%1Bbar\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_path_containing_del_byte_dropped() {
    // %7F → DEL.
    let seq = b"\x1b]7;file:///foo%7Fbar\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_path_containing_tab_or_newline_dropped() {
    // %09 (TAB), %0A (LF), %0D (CR) — control bytes.
    for cp in &[b"%09", b"%0A", b"%0D"] {
        let mut seq = b"\x1b]7;file:///foo".to_vec();
        seq.extend_from_slice(*cp);
        seq.extend_from_slice(b"bar\x1b\\");
        let events = drive(&seq);
        assert!(
            events
                .iter()
                .all(|(k, _)| *k != BBEventKind::CwdChanged as u32),
            "control byte {:?} in OSC 7 path must reject event",
            std::str::from_utf8(*cp).unwrap()
        );
    }
}

// ─── Audit M2: bidi / zero-width / invisible-payload codepoints ────────

#[test]
fn osc7_path_containing_rlo_dropped() {
    // Classic RTL spoof: U+202E RIGHT-TO-LEFT OVERRIDE flips visible
    // path display while filesystem target stays whatever the shell
    // sent. UTF-8 = E2 80 AE → percent-encoded %E2%80%AE.
    let seq = b"\x1b]7;file:///Users/foo/%E2%80%AE.bashrc\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_path_containing_alm_dropped() {
    // U+061C ARABIC LETTER MARK — D8 9C UTF-8 → %D8%9C.
    let seq = b"\x1b]7;file:///Users/%D8%9Cfoo\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_path_containing_zwj_dropped() {
    // U+200D ZWJ — E2 80 8D → %E2%80%8D.
    let seq = b"\x1b]7;file:///Users/foo%E2%80%8Dbar\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_path_containing_bom_dropped() {
    // U+FEFF BOM — EF BB BF → %EF%BB%BF.
    let seq = b"\x1b]7;file:///Users%EF%BB%BFfoo\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_path_containing_tag_block_dropped() {
    // U+E0073 (tag 's') — F3 A0 81 B3 → %F3%A0%81%B3.
    let seq = b"\x1b]7;file:///Users/foo%F3%A0%81%B3\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_path_containing_variation_selector_dropped() {
    // U+FE0F VS16 (text/emoji presentation selector) — EF B8 8F.
    let seq = b"\x1b]7;file:///Users/foo%EF%B8%8Fbar\x1b\\";
    let events = drive(seq);
    assert!(events
        .iter()
        .all(|(k, _)| *k != BBEventKind::CwdChanged as u32));
}

#[test]
fn osc7_path_with_emdash_still_accepted() {
    // U+2014 EM DASH — E2 80 94 → %E2%80%94. Shares the E2 80 lead
    // with bidi codepoints but is NOT in the strip list. Must accept.
    let seq = b"\x1b]7;file:///Users/foo%E2%80%94bar\x1b\\";
    let events = drive(seq);
    let cwd = events
        .iter()
        .find(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .expect("em-dash in path must NOT block OSC 7 — only bidi/invisible chars do");
    assert_eq!(cwd.1, b"/Users/foo\xE2\x80\x94bar");
}

/// Audit fix-#08 (2026-05-21): RFC 3986 §3.1 / §3.2.2 define scheme and
/// host as case-insensitive. Prior to fix-#08 the OSC 7 ingest gate did
/// byte-exact `strip_prefix(b"file://")` / `strip_prefix(b"localhost")`,
/// silently dropping RFC-legal variants (`FILE://`, `File://Localhost/...`).
/// Post-fix: scheme + host match case-insensitively while the path stays
/// case-sensitive (POSIX paths are).
#[test]
fn osc7_scheme_uppercase_is_accepted() {
    let seq = b"\x1b]7;FILE:///Users/foo\x1b\\";
    let events = drive(seq);
    let cwd = events
        .iter()
        .find(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .expect("FILE:// must be accepted per RFC 3986 §3.1");
    assert_eq!(&cwd.1, b"/Users/foo");
}

#[test]
fn osc7_scheme_mixedcase_with_uppercase_host_is_accepted() {
    let seq = b"\x1b]7;File://LocalHost/Users/foo\x1b\\";
    let events = drive(seq);
    let cwd = events
        .iter()
        .find(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .expect("File://LocalHost/... must be accepted (scheme + host both case-insensitive)");
    assert_eq!(&cwd.1, b"/Users/foo");
}

#[test]
fn osc7_path_case_is_preserved_verbatim() {
    // Path stays case-sensitive even when scheme/host are normalised.
    let seq = b"\x1b]7;FILE://localhost/Users/Foo/Bar\x1b\\";
    let events = drive(seq);
    let cwd = events
        .iter()
        .find(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .expect("expected CwdChanged");
    assert_eq!(&cwd.1, b"/Users/Foo/Bar");
}
