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

// ─── Audit S3-001: UTF-8-encoded C1 controls (U+0080..U+009F) ─────────

#[test]
fn osc7_path_containing_utf8_c1_control_dropped() {
    // C1 controls U+0080..U+009F encode in UTF-8 as 0xC2 0x80..0xC2 0x9F.
    // The pre-fix gate did a byte-wise `b < 0x20 || b == 0x7F` sweep
    // which misses both bytes of the UTF-8 form: 0xC2 = 194 and 0x85 =
    // 133 are both >= 0x20. A hostile shell could emit
    // `\x1b]7;file:///%C2%85tmp/\x1b\\` and the C1 byte would reach the
    // CwdChanged payload. Audit S3-001 (companion to title-path C1
    // codepoint filter at scrub_title_controls).
    for hex in &[b"%C2%85", b"%C2%80", b"%C2%9F", b"%C2%9B"] {
        let mut seq = b"\x1b]7;file:///foo".to_vec();
        seq.extend_from_slice(*hex);
        seq.extend_from_slice(b"bar\x1b\\");
        let events = drive(&seq);
        assert!(
            events
                .iter()
                .all(|(k, _)| *k != BBEventKind::CwdChanged as u32),
            "C1 control {:?} in OSC 7 path must reject event",
            std::str::from_utf8(*hex).unwrap()
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

// ─── Audit S4-001: validation-failing floods must not starve legit cwd ──
//
// OSC 7 ingest has a per-terminal sliding-window rate gate
// (`OSC7_INGEST_PER_SECOND = 32` events / 1 s). The audit-S4-001 bug:
// the gate runs BEFORE the deep validation chain (bidi/invisible
// codepoints, `..` path traversal), so a payload that passes the
// `file://` scheme + authority check but then FAILS deeper validation
// still CONSUMES a rate-limit slot. A hostile remote can flood ~32 such
// well-formed-but-rejected OSC 7s in under a second to exhaust the
// window, after which a subsequent LEGITIMATE `cd`-driven OSC 7 from the
// user's own shell is silently dropped — breaking prompt-cwd, "Open in
// Finder", and new-tab cwd inheritance.
//
// Post-fix contract: only OSC 7s that will actually emit a CwdChanged
// consume budget. These tests encode that contract and so FAIL on the
// pre-fix code (the legit cwd is starved → 0 events). All bytes for a
// single `drive()` call are fed in one synchronous `bb_term_input`, so
// they land in the same 1-second window.

#[test]
fn osc7_bidi_tainted_flood_does_not_starve_legit_cwd() {
    // 32 copies of a bidi-tainted payload: U+202E RIGHT-TO-LEFT OVERRIDE
    // percent-encoded as %E2%80%AE. It passes the file:// scheme +
    // authority check but is rejected by the bidi gate (see
    // osc7_path_containing_rlo_dropped). Pre-fix each copy still burns a
    // rate slot, exhausting the 32-event window before the legit cwd.
    let mut seq = Vec::new();
    for _ in 0..32 {
        seq.extend_from_slice(b"\x1b]7;file:///%E2%80%AE\x07");
    }
    // One legitimate OSC 7 from the user's own `cd`.
    seq.extend_from_slice(b"\x1b]7;file:///tmp/proj\x07");

    let events = drive(&seq);
    let cwds: Vec<_> = events
        .iter()
        .filter(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .collect();
    assert!(
        !cwds.is_empty(),
        "legitimate OSC 7 must fire CwdChanged — a bidi-tainted flood that \
         fails validation must NOT consume rate budget (audit S4-001)"
    );
    assert_eq!(
        &cwds.last().unwrap().1,
        b"/tmp/proj",
        "last CwdChanged must be the legitimate /tmp/proj cwd"
    );
}

#[test]
fn osc7_traversal_flood_does_not_starve_legit_cwd() {
    // 32 copies of a path-traversal payload: percent-encoded `..` →
    // file:///%2e%2e/x decodes to "/../x". Passes file:// scheme +
    // authority but is rejected by the `..` traversal gate (audit
    // synthesis #13). Pre-fix each burns a rate slot.
    let mut seq = Vec::new();
    for _ in 0..32 {
        seq.extend_from_slice(b"\x1b]7;file:///%2e%2e/x\x07");
    }
    // One legitimate OSC 7 from the user's own `cd`.
    seq.extend_from_slice(b"\x1b]7;file:///tmp/proj\x07");

    let events = drive(&seq);
    let cwds: Vec<_> = events
        .iter()
        .filter(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .collect();
    assert!(
        !cwds.is_empty(),
        "legitimate OSC 7 must fire CwdChanged — a percent-encoded `..` \
         traversal flood that fails validation must NOT consume rate \
         budget (audit S4-001)"
    );
    assert_eq!(
        &cwds.last().unwrap().1,
        b"/tmp/proj",
        "last CwdChanged must be the legitimate /tmp/proj cwd"
    );
}

#[test]
fn osc7_valid_flood_is_still_rate_limited() {
    // Guard against over-correction: moving the rate gate after
    // validation must NOT disable rate-limiting (audit M-7 stays
    // enforced). Feed 40 DISTINCT *valid* cwd updates in one window —
    // each passes the full validation chain and so consumes one slot.
    // The number of CwdChanged events must be capped at
    // OSC7_INGEST_PER_SECOND (32), not 40. This passes on both pre-fix
    // and post-fix code so the cap can't be silently removed.
    const OSC7_INGEST_PER_SECOND: usize = 32;
    const VALID_FLOOD: usize = 40;

    let mut seq = Vec::new();
    for n in 0..VALID_FLOOD {
        seq.extend_from_slice(format!("\x1b]7;file:///tmp/d{n}\x07").as_bytes());
    }

    let events = drive(&seq);
    let cwd_count = events
        .iter()
        .filter(|(k, _)| *k == BBEventKind::CwdChanged as u32)
        .count();
    assert!(
        cwd_count <= OSC7_INGEST_PER_SECOND,
        "OSC 7 ingest must stay rate-limited: {VALID_FLOOD} distinct valid \
         cwd updates in one window fired {cwd_count} CwdChanged events, \
         expected at most {OSC7_INGEST_PER_SECOND} (audit M-7)"
    );
}
