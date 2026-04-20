//! Kitty XTGETTCAP (DCS + q ... ST) capability queries. Blackbird sets
//! TERM=xterm-kitty so TUIs (kitty, wezterm-shipped tooling, nvim) probe
//! these caps to decide whether to emit undercurl / colored underlines.
//!
//! Protocol:
//!   Request: `DCS + q <caps-hex> [ ; <caps-hex> ... ] ST`  (ST = ESC \ or BEL)
//!   Match:   `DCS 1 + r <caps-hex>=<value-hex> ST`
//!   Unknown: `DCS 0 + r <caps-hex> ST`
//! Hex is uppercase ASCII. Cap names are terminfo capability names,
//! hex-encoded.
//!
//! The expected hex strings below are computed by hand from the ASCII
//! table — `cargo test` pins them so a typo in `XTGETTCAP_TABLE` cannot
//! slip in unnoticed.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

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
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }
    let guard = cap.lock().unwrap();
    guard.pty_writes.clone()
}

// ---------------------------------------------------------------------------
// Cap-name / cap-value hex strings, pre-computed from the ASCII table
// ---------------------------------------------------------------------------
//
// Cap names (each is literal ASCII, hex-encoded):
//   TN     = "TN"     → T=54 N=4E                        → 544E
//   Co     = "Co"     → C=43 o=6F                        → 436F
//   RGB    = "RGB"    → R=52 G=47 B=42                   → 524742
//   Smulx  = "Smulx"  → S=53 m=6D u=75 l=6C x=78         → 536D756C78
//   Setulc = "Setulc" → S=53 e=65 t=74 u=75 l=6C c=63    → 536574756C63
//
// Cap values (terminfo-compiled — `\E` == ESC == 0x1B):
//   TN value  = "xterm-kitty"
//     x=78 t=74 e=65 r=72 m=6D -=2D k=6B i=69 t=74 t=74 y=79
//     → 787465726D2D6B69747479
//   Co value  = "256"                → 2=32 5=35 6=36            → 323536
//   RGB value = "8"                  → 8=38                      → 38

#[test]
fn xtgettcap_tn_returns_xterm_kitty() {
    // DCS + q 544E ST  →  DCS 1 + r 544E=<xterm-kitty hex> ST
    let writes = run(b"\x1bP+q544E\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let expected = b"\x1bP1+r544E=787465726D2D6B69747479\x1b\\".to_vec();
    assert_eq!(joined, expected, "TN cap should reply xterm-kitty");
}

#[test]
fn xtgettcap_co_returns_256() {
    let writes = run(b"\x1bP+q436F\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let expected = b"\x1bP1+r436F=323536\x1b\\".to_vec();
    assert_eq!(joined, expected);
}

#[test]
fn xtgettcap_rgb_returns_8() {
    let writes = run(b"\x1bP+q524742\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let expected = b"\x1bP1+r524742=38\x1b\\".to_vec();
    assert_eq!(joined, expected);
}

#[test]
fn xtgettcap_unknown_returns_status_0() {
    // "XX" == 5858 is not in our table — reply with status 0 and no value.
    let writes = run(b"\x1bP+q5858\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let expected = b"\x1bP0+r5858\x1b\\".to_vec();
    assert_eq!(joined, expected);
}

#[test]
fn xtgettcap_multiple_caps_split_by_semicolon() {
    // Two caps in one request: TN and Co. Kitty's own format: each cap
    // gets its own DCS reply, not coalesced.
    let writes = run(b"\x1bP+q544E;436F\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let mut expected = b"\x1bP1+r544E=787465726D2D6B69747479\x1b\\".to_vec();
    expected.extend_from_slice(b"\x1bP1+r436F=323536\x1b\\");
    assert_eq!(joined, expected);
}

#[test]
fn xtgettcap_mixed_known_and_unknown_in_same_request() {
    // RGB (known) + "XX" (unknown) + Co (known). Reply order preserved.
    let writes = run(b"\x1bP+q524742;5858;436F\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let mut expected = b"\x1bP1+r524742=38\x1b\\".to_vec();
    expected.extend_from_slice(b"\x1bP0+r5858\x1b\\");
    expected.extend_from_slice(b"\x1bP1+r436F=323536\x1b\\");
    assert_eq!(joined, expected);
}

#[test]
fn xtgettcap_fragmented_across_inputs() {
    // Split the DCS across two bb_term_input calls. Our osc_parser is
    // stateful; the reply must still be correct.
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
        // First chunk: "ESC P + q 5 4" (6 bytes — ESC counts as 1).
        bc::bb_term_input(term, b"\x1bP+q54".as_ptr(), 6);
        // Second chunk: "4 E ESC \\" (4 bytes).
        bc::bb_term_input(term, b"4E\x1b\\".as_ptr(), 4);
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }
    let writes = cap.lock().unwrap().pty_writes.clone();
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let expected = b"\x1bP1+r544E=787465726D2D6B69747479\x1b\\".to_vec();
    assert_eq!(joined, expected);
}

#[test]
fn xtgettcap_lowercase_cap_hex_still_matches() {
    // Canonical is uppercase, but some tooling lowercases. Reply with the
    // request's exact casing so the TUI doesn't get confused.
    let writes = run(b"\x1bP+q544e\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let expected = b"\x1bP1+r544e=787465726D2D6B69747479\x1b\\".to_vec();
    assert_eq!(joined, expected);
}

#[test]
fn xtgettcap_smulx_returns_expected_hex() {
    // Smulx terminfo value: "\x1B[4:%p1%dm" — enables colored undercurl.
    // Byte-by-byte (10 bytes total):
    //   \x1B = 1B
    //   [    = 5B
    //   4    = 34
    //   :    = 3A
    //   %    = 25
    //   p    = 70
    //   1    = 31
    //   %    = 25
    //   d    = 64
    //   m    = 6D
    // Concatenated: 1B5B343A25703125646D
    let writes = run(b"\x1bP+q536D756C78\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let expected = b"\x1bP1+r536D756C78=1B5B343A25703125646D\x1b\\".to_vec();
    assert_eq!(joined, expected, "Smulx value hex must be pinned");
}

#[test]
fn xtgettcap_setulc_returns_expected_hex() {
    // Setulc terminfo value: "\x1B[58:2::%p1%{65536}%/%d:%p2%{256}%/%d:%p3%d%;m"
    // Byte-by-byte (46 bytes total):
    //   \x1B = 1B     [  = 5B     5  = 35     8  = 38     :  = 3A
    //   2    = 32     :  = 3A     :  = 3A     %  = 25     p  = 70
    //   1    = 31     %  = 25     {  = 7B     6  = 36     5  = 35
    //   5    = 35     3  = 33     6  = 36     }  = 7D     %  = 25
    //   /    = 2F     %  = 25     d  = 64     :  = 3A     %  = 25
    //   p    = 70     2  = 32     %  = 25     {  = 7B     2  = 32
    //   5    = 35     6  = 36     }  = 7D     %  = 25     /  = 2F
    //   %    = 25     d  = 64     :  = 3A     %  = 25     p  = 70
    //   3    = 33     %  = 25     d  = 64     %  = 25     ;  = 3B
    //   m    = 6D
    // Concatenated (92 hex chars):
    //   1B5B35383A323A3A257031257B36353533367D252F25643A257032257B3235367D252F25643A2570332564253B6D
    let writes = run(b"\x1bP+q536574756C63\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let expected_hex =
        b"1B5B35383A323A3A257031257B36353533367D252F25643A257032257B3235367D252F25643A2570332564253B6D";
    let mut expected = b"\x1bP1+r536574756C63=".to_vec();
    expected.extend_from_slice(expected_hex);
    expected.extend_from_slice(b"\x1b\\");
    assert_eq!(joined, expected, "Setulc value hex must be pinned");
}

#[test]
fn xtgettcap_empty_payload_between_semicolons_is_skipped() {
    // `;;` — two empty caps sandwiched — should produce no reply for the
    // empty bits. A naive `split` + `continue if empty` handles this;
    // this test pins that behavior so a refactor can't silently regress.
    let writes = run(b"\x1bP+q;544E;\x1b\\");
    let joined: Vec<u8> = writes.into_iter().flatten().collect();
    let expected = b"\x1bP1+r544E=787465726D2D6B69747479\x1b\\".to_vec();
    assert_eq!(joined, expected);
}

#[test]
fn xtgettcap_no_intermediates_no_reply() {
    // `DCS q ... ST` without the `+` intermediate is sixel-adjacent and
    // must stay inert. This is the regression seatbelt for
    // dcs_rejection::sixel_dcs_is_inert_not_dangerous — proved here
    // directly against the XTGETTCAP code path too.
    let writes = run(b"\x1bPq544E\x1b\\");
    assert!(
        writes.is_empty(),
        "DCS without `+q` intermediate+final must not reply: {writes:?}"
    );
}

#[test]
fn xtgettcap_wrong_action_byte_no_reply() {
    // `DCS + r` is not XTGETTCAP (we only match `+q`). Must be inert —
    // our hook's action guard should bail before latching `in_xtgettcap`.
    let writes = run(b"\x1bP+r544E\x1b\\");
    assert!(writes.is_empty(), "DCS +r must not reply: {writes:?}");
}

#[test]
fn xtgettcap_empty_payload_produces_no_reply() {
    // `ESC P + q ESC \\` — hook fires, no put bytes arrive, unhook sees
    // an empty buffer. `split(b';')` on an empty slice yields one empty
    // slice which we filter out → zero PtyWrite events.
    let writes = run(b"\x1bP+q\x1b\\");
    assert!(
        writes.is_empty(),
        "empty XTGETTCAP payload must not reply: {writes:?}"
    );
}

#[test]
fn xtgettcap_oversized_payload_is_gracefully_truncated() {
    // 5000 bytes of garbage ASCII between `DCS +q` and ST. `put()` caps
    // the buffer at < 4096 so we silently drop the tail. The resulting
    // "cap" won't match our table → at most a status-0 reply. The only
    // contract this test pins is "no crash, terminal stays live" —
    // specifically that the 4 KiB cap in `put` holds under DoS input.
    let mut input = b"\x1bP+q".to_vec();
    input.extend(std::iter::repeat_n(b'A', 5000));
    input.extend_from_slice(b"\x1b\\");
    let _ = run(&input); // just must not panic
}
