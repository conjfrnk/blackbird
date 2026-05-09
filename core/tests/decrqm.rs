//! Pins the bytes BBCore emits in reply to DECRQM queries — both the
//! private-mode form (`CSI ? Pn $ p`, the bulk of this file) and the
//! public-mode form (`CSI Pn $ p`, the section at the bottom). TUIs probe
//! these to learn what features the terminal supports — most notably
//! private mode 2026 (synchronized output): if the answer is "not
//! recognized" (`Ps = 0`), apps fall back to byte-streamed updates that
//! flicker. The reply format is `CSI [?] Pn ; Ps $ y` where `Ps` is one
//! of:
//!
//!   0 — mode not recognized
//!   1 — set (currently active)
//!   2 — reset (currently inactive)
//!   3 — permanently set
//!   4 — permanently reset
//!
//! Mode 2026 is a special case: vte 0.15 implements sync internally, so
//! from outside the parser we cannot tell whether sync is active mid-region.
//! The contract is to always answer `2` (reset) for 2026 — both `1` and `2`
//! signal "supported" to TUIs without claiming permanence.
//!
//! Test provenance: the private-mode tests (top of file) were written by
//! a blind subagent against the spec — they don't see the implementation.
//! The public-mode tests at the bottom (`decrqm_public_mode_*`) were added
//! by the implementer after observing that the private-mode dispatch was
//! already working in alacritty 0.26 unmodified, so they pin observed
//! behaviour rather than spec-derived behaviour. Acceptable for regression
//! pinning; not equivalent to a blind-spec assertion.
//!
//! Each test creates a fresh 80×24 terminal (~250-300 KiB, dominated by
//! the 100-line scrollback), feeds a query, and asserts the captured
//! PtyWrite payloads. Total runtime <100 ms per file.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

/// Captures every PtyWrite payload fired during a test. Anything else is
/// ignored — we only care about the bytes the terminal wants to send back
/// to the shell here. Same shape as `terminal_replies.rs`.
#[derive(Default)]
struct Captured {
    pty_writes: Vec<Vec<u8>>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    if ev.kind as u32 != bc::BBEventKind::PtyWrite as u32 {
        return;
    }
    // PtyWrite contract (lib.rs:60-66): payload non-null, len > 0. A null
    // payload here means a Rust-core bug; a zero-len means the parser
    // emitted a pointless event. Either way, assert rather than silently
    // drop — a silent drop would let a regression slip past as "no reply
    // captured" when the real failure is "broken event with no payload."
    assert!(!ev.payload.is_null(), "PtyWrite contract: null payload");
    assert!(ev.len > 0, "PtyWrite contract: zero-length payload");
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

/// Multi-feed variant: each chunk goes through a separate `bb_term_input`
/// call. Lets us prove DECRQM survives FFI-boundary fragmentation.
fn run_chunks(chunks: &[&[u8]]) -> Vec<Vec<u8>> {
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;

    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        assert!(!term.is_null());
        bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
        for chunk in chunks {
            bc::bb_term_input(term, chunk.as_ptr(), chunk.len());
        }
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }

    let guard = cap.lock().unwrap();
    guard.pty_writes.clone()
}

/// Read the visible characters of the given row from a snapshot. Used by
/// the "DECRQM bytes don't print to grid" test. Pattern lifted from
/// `sync_output.rs`.
fn read_row_chars(snap: *const bc::BBSnap, row: u16) -> String {
    unsafe {
        let s = &*snap;
        let start = (row as usize) * (s.cols as usize);
        let mut out = String::new();
        for i in 0..(s.cols as usize) {
            let cell = *s.cells.add(start + i);
            if let Some(c) = char::from_u32(cell.ch) {
                if cell.ch == 0 {
                    out.push(' ');
                } else {
                    out.push(c);
                }
            }
        }
        out
    }
}

// ---------------------------------------------------------------------------
// Mode 2026 — DEC synchronized output. ALWAYS reports `2` (supported but
// not currently active from outside the parser's perspective).
// ---------------------------------------------------------------------------

#[test]
fn decrqm_2026_responds_with_supported_state_2() {
    // The whole reason this gap exists: TUIs (kitty, foot, wezterm consumers)
    // probe ?2026 to decide whether to emit sync brackets. A "not recognized"
    // (Ps=0) answer makes them fall back to byte-streamed updates that
    // flicker. We must answer Ps=2 — "supported, not currently active".
    // Reporting Ps=3/4 would imply permanence, which is wrong (sync IS
    // toggleable by ?2026h/l from inside the parser).
    let writes = run(b"\x1b[?2026$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?2026;2$y".to_vec()],
        "DECRQM ?2026 must reply '2' (supported, inactive); got {:?}",
        writes
    );
}

// ---------------------------------------------------------------------------
// Defaults — modes that alacritty enables on a fresh term must report `1`,
// modes that start disabled must report `2`.
// ---------------------------------------------------------------------------

#[test]
fn decrqm_25_show_cursor_default_on_responds_set() {
    // SHOW_CURSOR is set on a fresh alacritty term (DECTCEM defaults on).
    // Pin it: any future change that flipped the default would silently
    // break TUI cursor visibility probes.
    let writes = run(b"\x1b[?25$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?25;1$y".to_vec()],
        "DECRQM ?25 (DECTCEM) on a fresh term must reply '1' (set); got {:?}",
        writes
    );
}

#[test]
fn decrqm_7_line_wrap_default_on_responds_set() {
    // DECAWM (autowrap) is on by default in alacritty. Pin it.
    let writes = run(b"\x1b[?7$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?7;1$y".to_vec()],
        "DECRQM ?7 (DECAWM) on a fresh term must reply '1' (set); got {:?}",
        writes
    );
}

#[test]
fn decrqm_1004_focus_default_off_responds_reset() {
    // FOCUS_IN_OUT starts disabled — the Swift host only emits focus
    // escapes when a TUI enables 1004. Probing it on a fresh term must
    // answer '2' (reset).
    let writes = run(b"\x1b[?1004$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?1004;2$y".to_vec()],
        "DECRQM ?1004 on a fresh term must reply '2' (reset); got {:?}",
        writes
    );
}

// ---------------------------------------------------------------------------
// Round-trip — enable a mode then query it. Must report `1` (set).
// ---------------------------------------------------------------------------

#[test]
fn decrqm_1004_focus_after_enable_responds_set() {
    // Enable focus events, then ask. Must report `1`. DECSET ?1004h is
    // silent (no PTY reply), so the captured writes must be exactly the
    // one DECRQM reply — strict equality catches a regression where the
    // enable starts emitting an unexpected side-effect write.
    let writes = run(b"\x1b[?1004h\x1b[?1004$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?1004;1$y".to_vec()],
        "expected exactly one reply '\\x1b[?1004;1$y' after enabling 1004; got {:?}",
        writes
    );
}

#[test]
fn decrqm_2004_bracketed_paste_after_enable_responds_set() {
    // Bracketed paste — Swift's paste path checks BRACKETED_PASTE before
    // wrapping pasted bytes in 200~/201~. TUIs that opt in want to hear
    // back '1' on a query. Strict equality (DECSET ?2004h is silent).
    let writes = run(b"\x1b[?2004h\x1b[?2004$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?2004;1$y".to_vec()],
        "expected exactly one reply '\\x1b[?2004;1$y' after enabling 2004; got {:?}",
        writes
    );
}

#[test]
fn decrqm_1049_alt_screen_after_enable_responds_set() {
    // Alt screen — vim/less/htop enter alt screen on startup, then probe
    // 1049 to confirm. Must answer '1'. Strict equality (DECSET ?1049h is
    // silent at the PTY level — the screen swap is internal).
    let writes = run(b"\x1b[?1049h\x1b[?1049$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?1049;1$y".to_vec()],
        "expected exactly one reply '\\x1b[?1049;1$y' after enabling 1049; got {:?}",
        writes
    );
}

// ---------------------------------------------------------------------------
// Round-trip enable→disable→query — pins that the `l` form actually clears
// the TermMode bit. A regression where the unset path was silently a no-op
// would leave TUIs thinking a mode is permanent (e.g., bracketed paste
// stuck on after a copy operation that disabled it).
// ---------------------------------------------------------------------------

#[test]
fn decrqm_1004_after_enable_then_disable_responds_reset() {
    let writes = run(b"\x1b[?1004h\x1b[?1004l\x1b[?1004$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?1004;2$y".to_vec()],
        "after enable+disable, 1004 must report '2' (reset); got {:?}",
        writes
    );
}

#[test]
fn decrqm_1049_alt_screen_after_enter_then_leave_responds_reset() {
    // Vim's exit path: enter alt screen, do work, leave, then probe.
    let writes = run(b"\x1b[?1049h\x1b[?1049l\x1b[?1049$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?1049;2$y".to_vec()],
        "after enter+leave alt screen, 1049 must report '2' (reset); got {:?}",
        writes
    );
}

#[test]
fn decrqm_2004_bracketed_paste_after_enable_then_disable_responds_reset() {
    let writes = run(b"\x1b[?2004h\x1b[?2004l\x1b[?2004$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?2004;2$y".to_vec()],
        "after enable+disable, 2004 must report '2' (reset); got {:?}",
        writes
    );
}

// ---------------------------------------------------------------------------
// Unknown modes — must report `0` (not recognized), not silently drop.
// ---------------------------------------------------------------------------

#[test]
fn decrqm_unknown_mode_9999_responds_not_recognized() {
    // 9999 is not a defined private mode anywhere in the standards. The
    // correct behaviour is to reply with Ps=0 — TUIs can then know to
    // not rely on it, rather than timing out waiting for a reply.
    let writes = run(b"\x1b[?9999$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?9999;0$y".to_vec()],
        "DECRQM ?9999 must reply '0' (not recognized); got {:?}",
        writes
    );
}

#[test]
fn decrqm_unknown_mode_zero_responds_not_recognized() {
    // Mode 0 is reserved; reply Ps=0.
    let writes = run(b"\x1b[?0$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?0;0$y".to_vec()],
        "DECRQM ?0 must reply '0' (not recognized); got {:?}",
        writes
    );
}

// ---------------------------------------------------------------------------
// Fragmentation — DECRQM queries must survive being split across multiple
// `bb_term_input` calls (the FFI boundary).
// ---------------------------------------------------------------------------

#[test]
fn decrqm_query_split_across_two_bb_term_input_calls() {
    // Reads from the PTY arrive in arbitrary chunks; the parser keeps
    // partial-CSI state between calls. Splitting the 2026 query right
    // before the final terminator must still produce the reply.
    let writes = run_chunks(&[b"\x1b[?2026", b"$p"]);
    assert_eq!(
        writes,
        vec![b"\x1b[?2026;2$y".to_vec()],
        "DECRQM split across two feeds must still reply correctly; got {:?}",
        writes
    );
}

#[test]
fn decrqm_query_split_at_every_internal_byte() {
    // Exhaustively split the 8-byte query at every internal boundary.
    // Each split must produce exactly one correct reply. This is the
    // strongest fragmentation pin: a regression that broke any specific
    // boundary (e.g., losing the `?` sigil across calls) would fail
    // here even when the all-in-one and end-split forms still pass.
    //
    // Pre-flight memory: ≤1 fresh term live at a time (each iteration drops
    // its term before the next) at ~250-300 KiB. Sequential, not parallel.
    // peak (terms are dropped between iterations). Well under budget.
    let input = b"\x1b[?2026$p";
    let expected = b"\x1b[?2026;2$y".to_vec();
    for split in 1..input.len() {
        let writes = run_chunks(&[&input[..split], &input[split..]]);
        assert_eq!(
            writes,
            vec![expected.clone()],
            "split at byte {} failed; expected exactly one '\\x1b[?2026;2$y' reply, got {:?}",
            split,
            writes
        );
    }
}

// ---------------------------------------------------------------------------
// Side-effect isolation — the DECRQM bytes must NOT print to the grid as
// printable characters.
// ---------------------------------------------------------------------------

#[test]
fn decrqm_followed_by_text_does_not_print_query_to_grid() {
    // Regression guard: a sloppy implementation that fell through to
    // printing after answering the query would leave "?2026$p" or
    // similar fragments in row 0 alongside HELLO. The grid must show
    // only HELLO at column 0.
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;

    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        assert!(!term.is_null());
        bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
        let input = b"\x1b[?2026$pHELLO";
        bc::bb_term_input(term, input.as_ptr(), input.len());
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "snapshot must succeed");
        let row0 = read_row_chars(snap, 0);
        assert!(
            row0.starts_with("HELLO"),
            "row 0 must start with HELLO, no leaked query bytes; got {:?}",
            row0
        );
        // Belt-and-suspenders: explicitly forbid the literal query text
        // from appearing anywhere on row 0.
        assert!(
            !row0.contains("2026"),
            "DECRQM query bytes leaked into the grid: row 0 = {:?}",
            row0
        );
        // Belt-and-suspenders: the captured PtyWrites must contain
        // exactly the one DECRQM reply. A regression where the parser
        // ate the DECRQM bytes silently (no reply, no print) would pass
        // the grid check above but fail here.
        let writes = cap.lock().unwrap().pty_writes.clone();
        assert_eq!(
            writes,
            vec![b"\x1b[?2026;2$y".to_vec()],
            "DECRQM in mixed input must still produce exactly one reply; got {:?}",
            writes
        );
        bc::bb_snap_release(snap);
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }
}

// ---------------------------------------------------------------------------
// Multiple queries in one input — each must produce a reply, in order.
// ---------------------------------------------------------------------------

#[test]
fn multiple_decrqm_queries_in_one_input_each_get_response() {
    // Mirrors the `multiple_queries_reply_in_order` test in terminal_replies.rs:
    // a single bb_term_input that contains several DECRQM queries must
    // emit one reply per query, in stream order.
    let writes = run(b"\x1b[?25$p\x1b[?1004$p");
    assert_eq!(
        writes,
        vec![
            b"\x1b[?25;1$y".to_vec(),
            b"\x1b[?1004;2$y".to_vec(),
        ],
        "two DECRQM queries must produce two replies in order; got {:?}",
        writes
    );
}

// ---------------------------------------------------------------------------
// Empty parameter — vte's `next_param_or(0)` defaults missing params to 0,
// which here means "ask about mode 0" → reply Ps=0.
// ---------------------------------------------------------------------------

#[test]
fn decrqm_with_no_param_treated_as_mode_zero() {
    // `\x1b[?$p` has no numeric parameter. vte fills in 0; we reply
    // Ps=0 (mode 0 isn't recognized as a valid private mode).
    let writes = run(b"\x1b[?$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?0;0$y".to_vec()],
        "DECRQM with empty param must default to mode 0 / not recognized; got {:?}",
        writes
    );
}

// ---------------------------------------------------------------------------
// Public-mode DECRQM (no `?` prefix) — sister of private-mode DECRQM. Per
// ECMA-48: `CSI Pn $ p` queries public modes (Insert=4, LineFeedNewLine=20),
// reply is `CSI Pn ; Ps $ y`. alacritty handles two named public modes;
// every other Pn (including the empty-param default of 0) must reply Ps=0
// "not recognized" per spec. These tests pin that behaviour so a future
// alacritty bump can't silently regress public-mode DECRQM.
// ---------------------------------------------------------------------------

#[test]
fn decrqm_public_mode_4_insert_default_off_responds_reset() {
    // Insert mode (DECIM, mode 4) is off on a fresh term. Spec reply: 2.
    let writes = run(b"\x1b[4$p");
    assert_eq!(
        writes,
        vec![b"\x1b[4;2$y".to_vec()],
        "DECRQM 4 (Insert) on a fresh term must reply '2' (reset); got {:?}",
        writes
    );
}

#[test]
fn decrqm_public_mode_4_insert_after_enable_responds_set() {
    // Enable Insert via ESC[4h, then query — must read '1' (set). DECSET
    // 4h is silent; strict equality catches a regression that adds
    // unexpected side-effect writes on the enable.
    let writes = run(b"\x1b[4h\x1b[4$p");
    assert_eq!(
        writes,
        vec![b"\x1b[4;1$y".to_vec()],
        "expected exactly one reply '\\x1b[4;1$y' after enabling Insert (4h); got {:?}",
        writes
    );
}

#[test]
fn decrqm_public_mode_4_insert_after_enable_then_disable_responds_reset() {
    // Round-trip the unset path — pins that ESC[4l actually clears the
    // INSERT bit. A regression where the unset is silently dropped would
    // leave Insert mode stuck on.
    let writes = run(b"\x1b[4h\x1b[4l\x1b[4$p");
    assert_eq!(
        writes,
        vec![b"\x1b[4;2$y".to_vec()],
        "after enable+disable, Insert (4) must report '2' (reset); got {:?}",
        writes
    );
}

#[test]
fn decrqm_public_mode_unknown_responds_not_recognized() {
    // 99 is not a defined public mode → spec reply Ps=0.
    let writes = run(b"\x1b[99$p");
    assert_eq!(
        writes,
        vec![b"\x1b[99;0$y".to_vec()],
        "DECRQM 99 (unknown public) must reply '0' (not recognized); got {:?}",
        writes
    );
}

#[test]
fn decrqm_public_mode_empty_param_treated_as_mode_zero() {
    // `\x1b[$p` (no Pn) defaults to mode 0 per vte's `next_param_or(0)`.
    // Mode 0 is reserved → spec reply Ps=0. This pins the behaviour: a
    // bare CSI $p is the public-mode DECRQM variant (NOT REP — REP is
    // `CSI Pn b`, a different final byte). The reply is the spec-mandated
    // "not recognized" answer for an undefined Pn.
    let writes = run(b"\x1b[$p");
    assert_eq!(
        writes,
        vec![b"\x1b[0;0$y".to_vec()],
        "bare CSI $p (public-mode DECRQM, no param) must reply '\\x1b[0;0$y' \
         per spec for unknown mode 0; got {:?}",
        writes
    );
}

// ---------------------------------------------------------------------------
// Coverage sweep — every named private mode in vte 0.15 must reply with
// either '1' (set), '2' (reset), or in the documented exceptions case '0'
// (NotSupported). A vte-side enum rename or alacritty-side dispatch
// removal would fail this single test before slipping into a release.
// ---------------------------------------------------------------------------

#[test]
fn decrqm_every_named_private_mode_replies_with_known_state() {
    // Pin every NamedPrivateMode in vte 0.15 (`vte ansi.rs:898+`) so a
    // future bump that adds/removes a name fails here. The state byte
    // must be one of '1' / '2' / '0' — never '3' or '4' (no permanence
    // claim is currently returned by alacritty 0.26).
    //
    // ColumnMode (mode 3 / DECCOLM) is intentionally `NotSupported` in
    // alacritty (it would resize the grid, which Blackbird drives via
    // TIOCSWINSZ instead). Pin that exception explicitly so a future
    // alacritty change implementing DECCOLM doesn't pass silently.
    let modes: &[(u16, &str)] = &[
        (1, "CursorKeys"),
        (3, "ColumnMode"),
        (6, "Origin"),
        (7, "LineWrap"),
        (12, "BlinkingCursor"),
        (25, "ShowCursor"),
        (1000, "ReportMouseClicks"),
        (1002, "ReportCellMouseMotion"),
        (1003, "ReportAllMouseMotion"),
        (1004, "ReportFocusInOut"),
        (1005, "Utf8Mouse"),
        (1006, "SgrMouse"),
        (1007, "AlternateScroll"),
        (1042, "UrgencyHints"),
        (1049, "SwapScreenAndSetRestoreCursor"),
        (2004, "BracketedPaste"),
        (2026, "SyncUpdate"),
    ];
    for &(mode, label) in modes {
        let writes = run(format!("\x1b[?{mode}$p").as_bytes());
        assert_eq!(
            writes.len(), 1,
            "{label} (?{mode}) must produce exactly one reply; got {writes:?}"
        );
        let reply = &writes[0];
        let expected_prefix = format!("\x1b[?{mode};");
        assert!(
            reply.starts_with(expected_prefix.as_bytes()),
            "{label} reply prefix wrong: {:?}",
            String::from_utf8_lossy(reply)
        );
        assert!(
            reply.ends_with(b"$y"),
            "{label} reply suffix wrong: {:?}",
            String::from_utf8_lossy(reply)
        );
        // State byte is the last byte before "$y".
        let state_byte = reply[reply.len() - 3];
        if mode == 3 {
            assert_eq!(
                state_byte, b'0',
                "ColumnMode (?3) is intentionally NotSupported in alacritty; \
                 a change here means DECCOLM was implemented and must be reviewed"
            );
        } else {
            assert!(
                matches!(state_byte, b'1' | b'2'),
                "{label} (?{mode}) must reply 1 or 2, not 0/3/4; got {:?}",
                String::from_utf8_lossy(reply)
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Abuse / edge-case pins — defense-in-depth against vte parser changes.
// ---------------------------------------------------------------------------

#[test]
fn decrqm_replies_respect_pty_write_rate_cap() {
    // BBCore caps PtyWrite emissions at 32/sec/term (`lib.rs` audit M1) to
    // defend against a hostile shell that spams queries to wedge the host
    // PTY. DECRQM replies share that cap. `terminal_replies.rs` pins this
    // for DSR; pin it for DECRQM too. A 1000-deep burst must produce ≤32
    // replies, not 1000.
    let mut burst = Vec::with_capacity(8 * 1000);
    for _ in 0..1000 {
        burst.extend_from_slice(b"\x1b[?2026$p");
    }
    let writes = run(&burst);
    assert!(
        writes.len() <= 32,
        "DECRQM-flood replies must respect the 32/sec cap; got {} replies",
        writes.len()
    );
    assert!(
        !writes.is_empty(),
        "rate cap must let at least 1 DECRQM reply through (otherwise the \
         feature is unusable, not just rate-limited)"
    );
    // Each reply we did emit must still be well-formed.
    for w in &writes {
        assert_eq!(w, b"\x1b[?2026;2$y", "rate-capped reply byte mismatch");
    }
}

#[test]
fn decrqm_query_inside_sync_region_replies_without_buffering() {
    // BSU → DECRQM → ESU. The reply must fire (else TUIs that probe during
    // a sync region — vim startup, some Ink sync paths — would hang on
    // their read). Pin current behaviour: the PtyWrite event is dispatched
    // immediately even though the bytes between BSU and ESU are buffered
    // in vte's sync state.
    let writes = run(b"\x1b[?2026h\x1b[?25$p\x1b[?2026l");
    assert_eq!(
        writes,
        vec![b"\x1b[?25;1$y".to_vec()],
        "DECRQM inside sync region must still reply; got {:?}",
        writes
    );
}

#[test]
fn decrqm_with_param_overflow_saturates_to_u16_max() {
    // vte uses saturating arithmetic on CSI params; 99999999 saturates to
    // u16::MAX = 65535. Mode 65535 is unknown → reply Ps=0. Pin the
    // saturation semantics so a vte change to wrapping arithmetic (which
    // would interpret 99999999 as 99999999 % 65536 = 57919) fails here.
    let writes = run(b"\x1b[?99999999$p");
    assert_eq!(
        writes,
        vec![b"\x1b[?65535;0$y".to_vec()],
        "param must saturate to u16::MAX; got {:?}",
        writes
    );
}

#[test]
fn decrqm_with_double_question_mark_is_dropped() {
    // vte: in CsiParam state, a second 0x3C..=0x3F byte transitions to
    // CsiIgnore and the dispatch is dropped. Pin that `\x1b[??2026$p`
    // produces NO reply — a vte change that started accepting double-?
    // would round-trip a reply here and the test fails.
    let writes = run(b"\x1b[??2026$p");
    assert!(
        writes.is_empty(),
        "double-? (`\\x1b[??2026$p`) must be dropped; got {:?}",
        writes
    );
}

#[test]
fn decrqm_without_terminator_holds_state_until_terminator_arrives() {
    // `\x1b[?2026` alone is incomplete CSI; vte holds parser state across
    // FFI calls (the existing fragmentation tests rely on this). Mid-state
    // must produce no reply; only completing the sequence with `$p` fires
    // the reply. Pins the FFI fragmentation contract for the most common
    // shell-read-half-the-bytes case.
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        assert!(!term.is_null(), "bb_term_new must succeed");
        bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
        bc::bb_term_input(term, b"\x1b[?2026".as_ptr(), 7);
        // Mid-state — no reply yet.
        assert!(
            cap.lock().unwrap().pty_writes.is_empty(),
            "incomplete DECRQM must not emit a reply"
        );
        bc::bb_term_input(term, b"$p".as_ptr(), 2);
        // Now the reply fires.
        let writes = cap.lock().unwrap().pty_writes.clone();
        assert_eq!(
            writes,
            vec![b"\x1b[?2026;2$y".to_vec()],
            "completing DECRQM must fire exactly one reply; got {:?}",
            writes
        );
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    }
}
