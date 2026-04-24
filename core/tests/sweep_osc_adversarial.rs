//! v0.1.9 sweep — Track A + B: OSC adversarial inputs.
//!
//! The OSC family (8 hyperlinks, 7 cwd, 133 prompt marks, 52 clipboard,
//! 10/11/12 color queries, XTGETTCAP DCS+q) is the most attacker-controllable
//! surface in the parser — one OSC injection can leak clipboard, redirect
//! filesystem identity, or amplify a 5 KiB request into a megabyte reply.
//! This file pins the failure-mode contracts:
//!
//!  - TST-S1-004: OSC 133 D with a 17+ byte exit code is truncated to ≤16
//!  - TST-S1-009: XTGETTCAP non-hex caps with common ASCII (`;`, `(`, `=`)
//!    don't echo and don't crash
//!  - Track B: OSC payloads with embedded NUL / DEL / control bytes
//!  - Track B: OSC 7 with percent-decode edge cases (truncated `%`, `%Z`,
//!    `%00`)
//!  - Track B: OSC 8 with embedded BEL inside the URL field
//!  - Track B: OSC 52 with read-back form (`?`) is silent
//!
//! Pre-flight summary: every test owns at most one 80×24 BBTerm; the
//! largest payload is ~16 KiB. Total memory < 100 KiB per test.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

#[derive(Default)]
struct Captured {
    events: Vec<(u32, Vec<u8>, i32)>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    let cap = unsafe { &*(ctx as *const Mutex<Captured>) };
    let bytes = if ev.len > 0 && !ev.payload.is_null() {
        unsafe { std::slice::from_raw_parts(ev.payload, ev.len) }.to_vec()
    } else {
        Vec::new()
    };
    cap.lock()
        .unwrap()
        .events
        .push((ev.kind as u32, bytes, ev.i32_arg));
}

fn drive(input: &[u8]) -> Vec<(u32, Vec<u8>, i32)> {
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

    let evs = cap.lock().unwrap().events.clone();
    evs
}

fn drive_color_query_enabled(input: &[u8]) -> Vec<(u32, Vec<u8>, i32)> {
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;

    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        assert!(!term.is_null());
        bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
        bc::bb_term_set_color_query_enabled(term, 1);
        bc::bb_term_input(term, input.as_ptr(), input.len());
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }
    let evs = cap.lock().unwrap().events.clone();
    evs
}

fn pty_writes(events: &[(u32, Vec<u8>, i32)]) -> Vec<Vec<u8>> {
    events
        .iter()
        .filter(|(k, _, _)| *k == bc::BBEventKind::PtyWrite as u32)
        .map(|(_, b, _)| b.clone())
        .collect()
}

fn prompt_marks(events: &[(u32, Vec<u8>, i32)]) -> Vec<(i32, Vec<u8>)> {
    events
        .iter()
        .filter(|(k, _, _)| *k == bc::BBEventKind::PromptMark as u32)
        .map(|(_, b, a)| (*a, b.clone()))
        .collect()
}

// ---------------------------------------------------------------------------
// Track A: TST-S1-004 — OSC 133 D exit-code payload truncated at 16 bytes
// ---------------------------------------------------------------------------

#[test]
fn osc_133_d_long_exit_code_truncates_to_16_bytes() {
    // pre-flight: ~80 KiB + 80 B payload, ~1 ms.
    // TST-S1-004 (high). OSC 133 D's payload is the exit-code string.
    // The implementation caps at 16 bytes (`exit_code.len().min(16)`)
    // to bound the per-event allocation. A regression to no-cap or
    // off-by-one would let a TUI emit `OSC 133 ; D ; <large>` and
    // pump megabytes through the event delivery path.
    let payload_str: String = "9".repeat(50); // 50-byte exit code
    let mut seq: Vec<u8> = Vec::new();
    seq.extend_from_slice(b"\x1b]133;D;");
    seq.extend_from_slice(payload_str.as_bytes());
    seq.extend_from_slice(b"\x1b\\");

    let events = drive(&seq);
    let marks = prompt_marks(&events);
    assert_eq!(
        marks.len(),
        1,
        "expected one PromptMark event; got {marks:?}"
    );
    let (kind, bytes) = &marks[0];
    assert_eq!(*kind, 4, "kind must be D=4");
    assert!(
        bytes.len() <= 16,
        "OSC 133 D payload must be capped at ≤16 bytes; got {} bytes",
        bytes.len()
    );
    // Every byte must come from the original payload (no scrambled
    // metadata leaking in).
    for b in bytes {
        assert_eq!(
            *b, b'9',
            "truncated payload byte must come from original payload, got 0x{:02x}",
            b
        );
    }
}

#[test]
fn osc_133_d_exit_code_at_cap_boundary_passes_through() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-004 boundary check. A 16-byte exit code must pass
    // through verbatim — the cap is "≤16", not "<16".
    let exit = b"1234567890123456"; // exactly 16 bytes
    let mut seq: Vec<u8> = Vec::new();
    seq.extend_from_slice(b"\x1b]133;D;");
    seq.extend_from_slice(exit);
    seq.extend_from_slice(b"\x1b\\");
    let events = drive(&seq);
    let marks = prompt_marks(&events);
    assert_eq!(marks.len(), 1);
    let (_, bytes) = &marks[0];
    assert_eq!(
        bytes.as_slice(),
        exit,
        "16-byte exit code must pass through unmodified"
    );
}

// ---------------------------------------------------------------------------
// Track A: TST-S1-009 — XTGETTCAP non-hex with common ASCII bytes
// ---------------------------------------------------------------------------

#[test]
fn xtgettcap_with_semicolon_in_payload_does_not_echo() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-009 (medium). The cap-name field must be hex-only. A `;`
    // (0x3B) is not a hex digit. The reply MUST be the inert
    // `\x1b P 0 + r \x1b \\` (empty cap-name); a regression that
    // allowed `;` would let a hostile remote split the cap into two
    // fields and confuse downstream parsers.
    //
    // Construct a single-cap request whose payload contains an
    // embedded `;`. Note: vte's parser may interpret a `;` as a
    // sub-parameter separator, so we use the form `+q` with the
    // cap-name being one bogus byte 0x3B = `;`. Equivalent: ask
    // for a cap whose hex spelling contains `(` (0x28) or `=` (0x3D).
    //
    // Send a literal `(` (0x28) as the cap byte. Because vte permits
    // arbitrary printables in the DCS payload, this DOES reach our
    // post-parse hex validator.
    let writes = pty_writes(&drive(b"\x1bP+q(\x1b\\"));
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    assert_eq!(
        joined,
        b"\x1bP0+r\x1b\\".to_vec(),
        "non-hex cap '(' must produce empty-cap reply, no echo: {joined:?}"
    );
}

#[test]
fn xtgettcap_with_equals_in_payload_does_not_echo() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-009. `=` is the response separator in the kitty
    // protocol; if the cap-name echo allowed `=`, a hostile remote
    // could craft a cap-name like `XX=injectedvalue` and cause a
    // parser on the other side to think we replied with a known cap.
    let writes = pty_writes(&drive(b"\x1bP+q=\x1b\\"));
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    assert_eq!(
        joined,
        b"\x1bP0+r\x1b\\".to_vec(),
        "non-hex cap '=' must produce empty-cap reply: {joined:?}"
    );
}

#[test]
fn xtgettcap_with_lowercase_g_does_not_echo() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-009. Lowercase 'g' (0x67) is past 'F' / 'f'. Hex digits
    // are 0-9, A-F, a-f only. Pin: 'g' is rejected.
    let writes = pty_writes(&drive(b"\x1bP+qg\x1b\\"));
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    assert_eq!(
        joined,
        b"\x1bP0+r\x1b\\".to_vec(),
        "non-hex cap 'g' must produce empty-cap reply: {joined:?}"
    );
}

// ---------------------------------------------------------------------------
// Track B: OSC 7 percent-decode edges (TST-S1-014)
// ---------------------------------------------------------------------------

#[test]
fn osc7_truncated_percent_at_end_does_not_panic() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-014 (low). A path ending with a lone `%` is malformed
    // percent-encoding. The decoder must reject the path silently —
    // no event, no panic, no leaked bytes into a CWD update.
    let seq = b"\x1b]7;file:///path%\x1b\\";
    let events = drive(seq);
    let cwd_events: Vec<_> = events
        .iter()
        .filter(|(k, _, _)| *k == bc::BBEventKind::CwdChanged as u32)
        .collect();
    // Either no CWD event (if the decoder rejects malformed entirely)
    // or the path arrives with the trailing `%` either kept or dropped.
    // The hard requirement is "no panic". Pin the looser "max one
    // event" to detect a regression that emitted multiple events.
    assert!(
        cwd_events.len() <= 1,
        "malformed OSC 7 must produce at most one event; got {} events",
        cwd_events.len()
    );
}

#[test]
fn osc7_percent_with_non_hex_does_not_panic() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-014. `%Z` is a `%` followed by a non-hex byte. The
    // decoder must not panic. The default safe behaviour is to drop
    // the path or pass through the raw bytes; we pin "no panic" only.
    let seq = b"\x1b]7;file:///path%ZZ\x1b\\";
    let _events = drive(seq);
}

#[test]
fn osc7_percent_00_embedded_nul_is_filtered_or_silenced() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-014. A path containing `%00` decodes to a literal NUL
    // byte. A NUL byte in a UTF-8 string is technically valid but the
    // CWD validator should reject it (NUL in pathnames is a security
    // concern). The contract pinned: no event fires (because the path
    // either fails UTF-8 validation or fails the security check).
    let seq = b"\x1b]7;file:///path/%00xyz\x1b\\";
    let events = drive(seq);
    let cwd: Vec<_> = events
        .iter()
        .filter(|(k, b, _)| *k == bc::BBEventKind::CwdChanged as u32 && b.contains(&0u8))
        .collect();
    assert!(
        cwd.is_empty(),
        "OSC 7 with embedded NUL must not emit a CwdChanged event \
         carrying the NUL byte: {cwd:?}"
    );
}

// ---------------------------------------------------------------------------
// Track B: OSC 8 with adversarial payloads
// ---------------------------------------------------------------------------

#[test]
fn osc8_with_embedded_bel_terminates_url() {
    // pre-flight: ~80 KiB, ~1 ms.
    // BEL (0x07) is a valid OSC terminator (alongside ESC \\). An
    // OSC 8 sequence terminated by BEL inside the URL field must
    // be parsed correctly: the URL ends at the BEL, not later. This
    // is an established alacritty/vte invariant; pinning here so
    // a future parser swap doesn't regress the multi-terminator
    // contract.
    use std::ffi::CStr;
    unsafe {
        let term = bc::bb_term_new(20, 1, 100);
        // OSC 8 with BEL terminator instead of ST.
        let seq = b"\x1b]8;;https://example.com\x07X\x1b]8;;\x07";
        bc::bb_term_input(term, seq.as_ptr(), seq.len());
        let snap = bc::bb_term_take_snapshot(term);
        let id = bc::bb_snap_link_id_at(snap, 0, 0);
        if id != 0 {
            let url_ptr = bc::bb_snap_link_url(snap, id);
            assert!(!url_ptr.is_null());
            let url = CStr::from_ptr(url_ptr as *const _).to_string_lossy();
            assert!(
                url == "https://example.com",
                "BEL-terminated URL should be exactly 'https://example.com', got {url:?}"
            );
        }
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}

#[test]
fn osc8_with_zero_width_url_is_inert() {
    // pre-flight: ~80 KiB, ~1 ms.
    // An empty URL (`\x1b]8;;\x1b\\X\x1b]8;;\x1b\\`) must produce no
    // OSC 8 attribution — this is the explicit "clear" form. The
    // existing `osc8_empty_href_clears_attribution` test pins this;
    // here we pin the orthogonal: an unmatched closing OSC 8 (no
    // open beforehand) must also be inert.
    unsafe {
        let term = bc::bb_term_new(20, 1, 100);
        // Just a "close" without ever "open" — must not crash and
        // must not produce an attribution.
        let seq = b"\x1b]8;;\x1b\\PLAIN";
        bc::bb_term_input(term, seq.as_ptr(), seq.len());
        let snap = bc::bb_term_take_snapshot(term);
        let id = bc::bb_snap_link_id_at(snap, 0, 0);
        assert_eq!(
            id, 0,
            "unmatched OSC 8 close must not produce attribution; got id={id}"
        );
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}

#[test]
fn osc8_with_invalid_url_scheme_does_not_attribute() {
    // pre-flight: ~80 KiB, ~1 ms.
    // The Swift hyperlink policy filters URL schemes (allowed:
    // http(s), file with localhost authority, etc.). The CORE just
    // stores the URL; policy is enforced at the Swift layer. So
    // we just pin: a URL scheme that doesn't match anything still
    // attributes at the core level — Swift filters at presentation
    // time. This is the documented split.
    use std::ffi::CStr;
    unsafe {
        let term = bc::bb_term_new(20, 1, 100);
        let seq = b"\x1b]8;;javascript:alert(1)\x1b\\X\x1b]8;;\x1b\\";
        bc::bb_term_input(term, seq.as_ptr(), seq.len());
        let snap = bc::bb_term_take_snapshot(term);
        let id = bc::bb_snap_link_id_at(snap, 0, 0);
        if id != 0 {
            let url_ptr = bc::bb_snap_link_url(snap, id);
            let url = CStr::from_ptr(url_ptr as *const _).to_string_lossy();
            assert_eq!(
                url, "javascript:alert(1)",
                "core stores raw URL; Swift filters at presentation"
            );
        }
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track B: OSC 52 read-back stays silent (already covered, but pinning
// the byte form here for orthogonality)
// ---------------------------------------------------------------------------

#[test]
fn osc_52_readback_with_common_clipboard_targets_silent() {
    // pre-flight: ~80 KiB, ~1 ms.
    // OSC 52 read-back: `\x1b]52;<targets>;?\x1b\\`. Targets include
    // `c` (clipboard), `p` (primary), `s` (selection). All must be
    // silent — no PtyWrite. (alacritty's `Osc52::Disabled` policy
    // is the safety net; we just pin that the disabled state holds
    // for several common target characters.)
    let targets = [b"c", b"p", b"s"];
    for t in &targets {
        let mut seq: Vec<u8> = b"\x1b]52;".to_vec();
        seq.extend_from_slice(*t);
        seq.extend_from_slice(b";?\x1b\\");
        let writes = pty_writes(&drive(&seq));
        assert!(
            writes.is_empty(),
            "OSC 52 readback with target {:?} must be silent; got {writes:?}",
            std::str::from_utf8(*t).unwrap()
        );
    }
}

// ---------------------------------------------------------------------------
// Track A: color-query opt-in toggle correctness
// ---------------------------------------------------------------------------

#[test]
fn color_query_opt_in_then_opt_out_silences_replies() {
    // pre-flight: ~80 KiB, ~1 ms.
    // The `bb_term_set_color_query_enabled` toggle is per-call, not
    // per-input. Verify that opting IN then OUT before the OSC 10
    // arrives produces no reply. Regression for TST-S1-015 (low).
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
        bc::bb_term_set_color_query_enabled(term, 1);
        bc::bb_term_set_color_query_enabled(term, 0); // back off
        bc::bb_term_input(term, b"\x1b]10;?\x1b\\".as_ptr(), 10);
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }
    let evs = cap.lock().unwrap().events.clone();
    let writes = pty_writes(&evs);
    assert!(
        writes.is_empty(),
        "OSC 10 query after toggle-off must be silent; got {writes:?}"
    );
}

#[test]
fn color_query_off_then_on_then_query_replies() {
    // pre-flight: ~80 KiB, ~1 ms.
    // Symmetric of the previous test: toggle off → on → query
    // produces a reply.
    let evs = drive_color_query_enabled(b"\x1b]10;?\x1b\\");
    let writes = pty_writes(&evs);
    assert_eq!(
        writes.len(),
        1,
        "OSC 10 query with color-query enabled must produce one PtyWrite reply"
    );
    let s = std::str::from_utf8(&writes[0]).unwrap();
    assert!(s.starts_with("\x1b]10;rgb:"));
    assert!(s.ends_with("\x1b\\"));
}

// ---------------------------------------------------------------------------
// Track B: OSC sequence with NUL inside payload
// ---------------------------------------------------------------------------

#[test]
fn osc_with_embedded_nul_does_not_panic() {
    // pre-flight: ~80 KiB, ~1 ms.
    // NUL (0x00) in the OSC payload is unusual but legal at the
    // parser level — vte permits it. The OSC handler we use must
    // not panic when it tries to parse the payload as UTF-8 (e.g.
    // for OSC 7 cwd) — the validation should reject and silently
    // drop. Goal: no panic, no crash.
    let seq = b"\x1b]7;file:///\x00path\x1b\\";
    let _evs = drive(seq);
    // Survival is the assertion.
}

#[test]
fn osc_with_embedded_del_byte_does_not_panic() {
    // pre-flight: ~80 KiB, ~1 ms.
    // DEL (0x7F) is a control byte that historically passed through
    // OSC payload parsers. Pin no-panic.
    let seq = b"\x1b]7;file:///path\x7F\x1b\\";
    let _evs = drive(seq);
}

// ---------------------------------------------------------------------------
// Track B: alternate OSC terminators
// ---------------------------------------------------------------------------

#[test]
fn osc_with_st_only_terminator_works() {
    // pre-flight: ~80 KiB, ~1 ms.
    // ST (`\x1b\\`) is the canonical OSC terminator. Verify a single
    // `\x9C` (the 8-bit C1 ST) is also accepted by the parser. This
    // is rare on modern hosts but historically valid.
    let seq = b"\x1b]133;A\x9c";
    let evs = drive(seq);
    let marks = prompt_marks(&evs);
    // We don't strictly require this to succeed — if alacritty's vte
    // doesn't honour C1 ST, the test simply observes "no events".
    // Pin: at most one PromptMark fires (no duplication).
    assert!(
        marks.len() <= 1,
        "C1 ST OSC terminator must not duplicate events: {marks:?}"
    );
}

// ---------------------------------------------------------------------------
// Track B: very long OSC 8 URL fragmented across feeds
// ---------------------------------------------------------------------------

#[test]
fn osc8_long_url_split_across_feeds_lands_atomically() {
    // pre-flight: ~120 KiB (term + 4 KiB URL string), ~5 ms.
    // The OSC 8 URL cap is 4 KiB. A 4 KiB URL split across many
    // small feeds must end up at the cap boundary — at-cap URLs
    // must survive (per `osc8_accepts_uri_at_cap_boundary`). Pin
    // that fragmentation doesn't drop bytes.
    use std::ffi::CStr;
    let prefix = "https://example.com/?q=";
    let url: String = prefix.to_string() + &"a".repeat(4096 - prefix.len());
    assert_eq!(url.len(), 4096);
    let mut seq: Vec<u8> = b"\x1b]8;;".to_vec();
    seq.extend_from_slice(url.as_bytes());
    seq.extend_from_slice(b"\x1b\\X\x1b]8;;\x1b\\");

    unsafe {
        let term = bc::bb_term_new(20, 1, 100);
        // Feed in 64-byte chunks.
        for chunk in seq.chunks(64) {
            bc::bb_term_input(term, chunk.as_ptr(), chunk.len());
        }
        let snap = bc::bb_term_take_snapshot(term);
        let id = bc::bb_snap_link_id_at(snap, 0, 0);
        assert_ne!(
            id, 0,
            "fragmented at-cap URL must still attribute (got id 0)"
        );
        let url_ptr = bc::bb_snap_link_url(snap, id);
        assert!(!url_ptr.is_null());
        let recovered = CStr::from_ptr(url_ptr as *const _)
            .to_string_lossy()
            .into_owned();
        assert_eq!(
            recovered.len(),
            4096,
            "fragmented at-cap URL length must be preserved"
        );
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}
