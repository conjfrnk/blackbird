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
// Window-query blackout — never echo title / icon / size back to the PTY
// ---------------------------------------------------------------------------
//
// CSI 20t / 21t / 14t / 18t are window-query variants. Responding to any of
// them feeds shell-controlled bytes back to the shell: an attacker can set
// the title via OSC 2 to a command, then use CSI 21t to read it back *as
// if the user typed it*. This is the HD Moore 2003 attack (recent
// reincarnations: CVE-2022-46387 / CVE-2023-39150 ConEmu, dgl.cx 2024
// Ghostty title-bell variant). The correct posture is not to implement
// the reply at all — which is what alacritty_terminal 0.26 does and
// what our RoutingListener preserves (we ignore ColorRequest and
// TextAreaSizeRequest). Pin that with explicit tests so a future alacritty
// upgrade or a misconfigured EventListener refactor can't silently
// re-enable the attack.

#[test]
fn csi_21t_report_window_title_is_silent() {
    // Set a title via OSC 2, then query it via CSI 21t. The terminal must
    // not emit any PtyWrite — otherwise "ESC]2;$(rm -rf ~)BEL" followed
    // by CSI 21t would round-trip the payload back into the shell line.
    let writes = run(b"\x1b]2;totally-benign-title\x07\x1b[21t");
    assert!(
        writes.is_empty(),
        "CSI 21t must never produce a reply; got {:?}",
        writes
    );
}

#[test]
fn csi_20t_report_icon_label_is_silent() {
    // Icon label reporting is the same attack surface via OSC 1.
    let writes = run(b"\x1b]1;icon-label\x07\x1b[20t");
    assert!(
        writes.is_empty(),
        "CSI 20t must not reply; got {:?}",
        writes
    );
}

#[test]
fn csi_18t_reports_text_area_in_cells() {
    // Text-area size in rows × cols is the ONE window-query where the
    // reply is a useful TUI probe and the payload is numeric-only — no
    // shell-controllable content. vim / tmux / ncurses use this when
    // COLUMNS / LINES are unavailable. Pin the exact form.
    //
    // Reply: ESC[8;{rows};{cols}t for the 80×24 default in run().
    let writes = run(b"\x1b[18t");
    assert_eq!(writes, vec![b"\x1b[8;24;80t".to_vec()]);
}

#[test]
fn decrqss_request_does_not_echo_arbitrary_payload() {
    // DECRQSS = `ESC P $ q <selector> ESC \` — "report settings".
    // Historic concern: some terminals echo the request selector
    // verbatim in the reply, letting a remote inject shell-visible
    // bytes via a crafted selector. alacritty_terminal's reply is
    // either an empty "invalid" response (`ESC P 0 $ r ESC \`) or a
    // valid-settings echo for known selectors — it must *never*
    // round-trip an attacker-controlled selector back as-is.
    let attacker_selector = b"malicious-$(rm -rf ~)";
    let mut input = b"\x1bP$q".to_vec();
    input.extend_from_slice(attacker_selector);
    input.extend_from_slice(b"\x1b\\");
    let writes = run(&input);
    let flattened: Vec<u8> = writes.iter().flatten().copied().collect();
    assert!(
        !flattened
            .windows(attacker_selector.len())
            .any(|w| w == attacker_selector),
        "DECRQSS reply echoed attacker-controlled selector bytes; got {:?}",
        flattened
    );
}

#[test]
fn osc_10_11_color_queries_are_silent() {
    // OSC 10 / 11 `?` is the "query fg / bg colour" form. Responding would
    // leak the configured palette back into the PTY; older terminals were
    // exploited to round-trip the colour as commands via zsh vi-mode.
    // RoutingListener drops ColorRequest so the reply never ships.
    let writes = run(b"\x1b]10;?\x07\x1b]11;?\x07");
    assert!(
        writes.is_empty(),
        "OSC 10 / 11 colour queries must not reply; got {:?}",
        writes
    );
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

// ─── Audit M1: PtyWrite reply rate-limit ─────────────────────────────

#[test]
fn pty_write_reply_capped_under_burst() {
    // Pre-fix: a hostile shell streaming `ESC[6n` in a tight loop
    // produced one PtyWrite reply per query, unbounded. Cap at 32/sec
    // matches the OSC color-query gate. Fire 1000 cursor-position
    // queries in a single bb_term_input call — must observe ≤ 32
    // replies, not 1000. Audit M1.
    let mut burst = Vec::with_capacity(4096);
    for _ in 0..1000 {
        burst.extend_from_slice(b"\x1b[6n");
    }
    let writes = run(&burst);
    assert!(
        writes.len() <= 32,
        "expected ≤ 32 replies under PTY_WRITE_REPLY_PER_SECOND cap; got {}",
        writes.len()
    );
    // Must produce at LEAST one reply — the cap is a ceiling, not
    // a floor; legitimate single-query callers must still get an
    // answer.
    assert!(
        !writes.is_empty(),
        "rate limiter must not block all replies"
    );
}

#[test]
fn pty_write_reply_cap_applies_across_query_kinds() {
    // The cap is total across DSR + DA + CPR, not per-kind. Mix
    // ESC[6n (CPR), ESC[5n (status), ESC[c (DA1), ESC[>c (DA2) and
    // verify the total stays ≤ 32 even though each kind alone would
    // be well under 32 individually.
    let mut burst = Vec::with_capacity(8192);
    for _ in 0..200 {
        burst.extend_from_slice(b"\x1b[6n\x1b[5n\x1b[c\x1b[>c");
    }
    let writes = run(&burst);
    assert!(
        writes.len() <= 32,
        "mixed-kind burst must respect the same total cap; got {}",
        writes.len()
    );
}

#[test]
fn pty_write_reply_first_32_succeed() {
    // The cap is not "drop everything past N" but "allow N then drop"
    // — the first 32 replies in any 1-second window must succeed.
    // Sanity-check the lower bound.
    let mut burst = Vec::with_capacity(4096);
    for _ in 0..100 {
        burst.extend_from_slice(b"\x1b[6n");
    }
    let writes = run(&burst);
    assert!(
        writes.len() >= 32 || writes.len() == 100,
        "first 32 queries in a fresh window must succeed; saw {}",
        writes.len()
    );
}
