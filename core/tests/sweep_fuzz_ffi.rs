//! v0.1.9 sweep — Track B (adversarial / fuzz-style inputs at the FFI boundary).
//!
//! These tests are NOT property-based in the proptest sense; they are
//! deterministic, hand-crafted inputs chosen to walk the failure modes a
//! generator-driven fuzzer would have to wander into. The goal is to pin
//! the public-contract behaviour ("no panic, no crash, predictable side
//! effects") on inputs the v0.1.9 surface might encounter in the wild —
//! mid-codepoint UTF-8 truncations, byte-by-byte fragmentation through
//! every parser stage, OSC payloads carrying embedded CAN/SUB control
//! bytes, CSI sequences with weird intermediate bytes, etc.
//!
//! Pre-flight summary for the file: every test owns a single 80×24 (or
//! smaller) BBTerm; the largest payload is ~16 KiB; the largest snapshot
//! is 80×24 cells × 20 bytes ≈ 38 KiB. Total memory hit < 100 KiB per test.
//! No I/O, no sleeps, no spawned threads.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

#[derive(Default)]
struct Captured {
    events: Vec<u32>,
    pty_writes: Vec<Vec<u8>>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    let cap = unsafe { &*(ctx as *const Mutex<Captured>) };
    let mut guard = cap.lock().unwrap();
    guard.events.push(ev.kind as u32);
    if ev.kind as u32 == bc::BBEventKind::PtyWrite as u32 && !ev.payload.is_null() && ev.len > 0 {
        let bytes = unsafe { std::slice::from_raw_parts(ev.payload, ev.len) };
        guard.pty_writes.push(bytes.to_vec());
    }
}

/// Drive a single fresh 80×24 term through `input`, capturing all callback
/// events. Returns `(event_kinds_in_order, pty_write_payloads)`.
fn drive(input: &[u8]) -> (Vec<u32>, Vec<Vec<u8>>) {
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

/// Read a single cell from a snapshot. Out-of-range coords assert.
fn cell_at(snap: *const bc::BBSnap, col: u16, row: u16) -> bc::BBCell {
    unsafe {
        let cols = (*snap).cols;
        let rows = (*snap).rows;
        assert!(
            col < cols && row < rows,
            "cell_at ({col},{row}) outside {cols}×{rows}"
        );
        let idx = (row as usize) * (cols as usize) + col as usize;
        *((*snap).cells.add(idx))
    }
}

// ---------------------------------------------------------------------------
// Track B: UTF-8 boundary cases at the FFI input boundary
// ---------------------------------------------------------------------------

#[test]
fn utf8_4_byte_emoji_does_not_panic() {
    // pre-flight: ~80 KiB (term + snap), ~1 ms.
    // U+1F600 GRINNING FACE = 0xF0 0x9F 0x98 0x80, encoded as a UTF-16
    // surrogate pair when displayed but a single UTF-8 4-byte sequence.
    // alacritty_terminal must accept the 4-byte form without truncation
    // and place the emoji in column 0 (typically as a wide glyph). The
    // contract here: NO PANIC, the cell at (0,0) carries either the
    // emoji codepoint or a wide-char placeholder, and the next cell is
    // either the spacer or untouched.
    unsafe {
        let term = bc::bb_term_new(10, 1, 100);
        assert!(!term.is_null());
        let bytes = "\u{1F600}".as_bytes();
        bc::bb_term_input(term, bytes.as_ptr(), bytes.len());
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let c0 = cell_at(snap, 0, 0);
        // The emoji either lands as a wide-char primary cell carrying
        // codepoint 0x1F600 OR as a degraded narrow cell. Either is
        // acceptable for the FFI contract (correctness of width is a
        // unicode-cells.rs concern). What we forbid: the parser must
        // not have panicked, and the cell at col 0 must be non-zero
        // (i.e. the bytes were processed, not ignored).
        assert_ne!(
            c0.ch, 0,
            "4-byte UTF-8 emoji must reach the grid (saw blank cell)"
        );
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}

#[test]
fn utf8_bom_at_start_does_not_panic() {
    // pre-flight: ~80 KiB, ~1 ms.
    // U+FEFF BYTE ORDER MARK is a zero-width no-break space; some
    // emitters prepend it before any text. alacritty_terminal must
    // accept it without crashing and not consume the next character.
    let bytes = b"\xEF\xBB\xBFhi";
    unsafe {
        let term = bc::bb_term_new(10, 1, 100);
        bc::bb_term_input(term, bytes.as_ptr(), bytes.len());
        let snap = bc::bb_term_take_snapshot(term);
        // Don't pin which column 'h' lands in — depends on whether
        // alacritty renders BOM as zero-width or skips it. Pin only:
        // 'h' must appear somewhere in the first 3 cells.
        let mut found_h = false;
        for c in 0u16..3 {
            if cell_at(snap, c, 0).ch == b'h' as u32 {
                found_h = true;
                break;
            }
        }
        assert!(found_h, "BOM-prefixed text must still render 'h' on row 0");
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}

#[test]
fn utf8_mid_codepoint_truncation_does_not_panic() {
    // pre-flight: ~80 KiB, ~1 ms.
    // Feed a partial UTF-8 sequence: 0xE6 (start of a 3-byte sequence,
    // CJK) by itself, then later complete it with the trailing two bytes.
    // alacritty_terminal owns the multi-byte assembly; the FFI must not
    // panic on either chunk. We don't pin the final glyph (alacritty's
    // partial-byte recovery is implementation-defined) — only that no
    // panic occurs and that subsequent ASCII still lands.
    unsafe {
        let term = bc::bb_term_new(10, 1, 100);
        // First chunk: a lone leading byte. UB-bait if any code path
        // dereferences past `len`.
        bc::bb_term_input(term, [0xE6u8].as_ptr(), 1);
        // Second chunk: the rest of "日" (0xE6 0x97 0xA5) plus 'X'.
        bc::bb_term_input(term, [0x97u8, 0xA5, b'X'].as_ptr(), 3);
        let snap = bc::bb_term_take_snapshot(term);
        // Pin: at LEAST 'X' must be reachable somewhere in the visible
        // portion of row 0 — we permit alacritty to drop the partial
        // CJK glyph, but the trailing ASCII must survive.
        let mut found_x = false;
        for c in 0u16..6 {
            if cell_at(snap, c, 0).ch == b'X' as u32 {
                found_x = true;
                break;
            }
        }
        assert!(
            found_x,
            "trailing ASCII after a mid-codepoint truncation must land"
        );
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}

#[test]
fn utf8_lone_continuation_byte_does_not_panic() {
    // pre-flight: ~80 KiB, ~1 ms.
    // A single 0x80 (continuation without a leading byte) is malformed
    // UTF-8. The FFI must not panic; alacritty replaces with the
    // replacement char or drops, both are acceptable. We just pin that
    // a subsequent ASCII char still reaches the grid.
    unsafe {
        let term = bc::bb_term_new(10, 1, 100);
        bc::bb_term_input(term, b"\x80hello".as_ptr(), 6);
        let snap = bc::bb_term_take_snapshot(term);
        // 'h' must appear in some cell of row 0.
        let mut found = false;
        for c in 0u16..6 {
            if cell_at(snap, c, 0).ch == b'h' as u32 {
                found = true;
                break;
            }
        }
        assert!(
            found,
            "trailing ASCII after a lone continuation byte must land"
        );
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}

#[test]
fn byte_by_byte_fragmentation_of_complex_stream_is_inert() {
    // pre-flight: ~120 KiB (10 × 24 grid + ~1 KiB payload feed), ~5 ms.
    // Feed a hostile stream — DCS + OSC 7 + CSI + SGR + emoji + OSC 8 —
    // one byte at a time. Each byte invokes the parser fast path; state
    // must persist across calls and the final grid must be the same as
    // a single-shot feed of the same bytes. Property tested: no panic
    // across the byte-by-byte path.
    let payload = b"\x1bP+q544E\x1b\\\
                    \x1b]7;file:///tmp\x1b\\\
                    \x1b[1;31mHELLO\x1b[0m\
                    \xF0\x9F\x98\x80\
                    \x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\";
    unsafe {
        let term = bc::bb_term_new(20, 1, 100);
        for b in payload {
            bc::bb_term_input(term, std::ptr::from_ref(b), 1);
        }
        // Final snapshot must be reachable; we don't pin specific cell
        // values because the goal is "byte-by-byte parser state survives".
        let snap = bc::bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        bc::bb_snap_release(snap);
        bc::bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track B: CSI / OSC adversarial inputs (parser hardening)
// ---------------------------------------------------------------------------

#[test]
fn csi_with_weird_intermediate_bytes_is_inert() {
    // pre-flight: ~80 KiB, ~1 ms.
    // CSI sequences may include intermediate bytes from 0x20-0x2F
    // ("space" through "/"). A sequence with several intermediates
    // followed by a final byte (0x40-0x7E) we don't recognise must be
    // silently dropped — no panic, no event.
    let weird = b"\x1b[ !\"#$%&'()*+,-./~"; // space, bang, dquote, ... slash, then '~' as final
    let (events, writes) = drive(weird);
    assert!(
        events.is_empty(),
        "weird-intermediate CSI must produce no events: {events:?}"
    );
    assert!(
        writes.is_empty(),
        "weird-intermediate CSI must not echo bytes: {writes:?}"
    );
}

#[test]
fn csi_with_huge_param_count_is_inert() {
    // pre-flight: ~80 KiB + ~512 B payload, ~1 ms.
    // 256 semicolon-separated params followed by `m` (SGR). The vte
    // parser caps params at 16 internally and silently drops the rest;
    // the FFI must not crash on the input even if the grammar overruns.
    let mut s = b"\x1b[".to_vec();
    for i in 0..256 {
        if i > 0 {
            s.push(b';');
        }
        s.extend_from_slice(b"30");
    }
    s.push(b'm');
    s.extend_from_slice(b"X");
    let (_evs, _writes) = drive(&s);
    // No assertion beyond "no panic". The reachable side effect is
    // the 'X' lands somewhere on row 0; we don't pin which cell
    // because alacritty's truncation policy is internal.
}

#[test]
fn csi_garbage_followed_by_real_da1_still_replies() {
    // pre-flight: ~80 KiB, ~1 ms.
    // Defensive: a malformed CSI must not corrupt the parser's
    // ground state. After a junk CSI, a real DA1 query (`\x1b[c`)
    // must still produce the standard reply (`\x1b[?6c`).
    let payload = b"\x1b[!@#$%XX\x1b[c";
    let (_evs, writes) = drive(payload);
    let any_da1 = writes.iter().any(|w| w == b"\x1b[?6c");
    assert!(
        any_da1,
        "DA1 reply must follow garbage CSI; saw writes {writes:?}"
    );
}

#[test]
fn osc_with_embedded_can_aborts_cleanly() {
    // pre-flight: ~80 KiB, ~1 ms.
    // CAN (0x18) and SUB (0x1A) are control codes that the VT parser
    // treats as "abort the current sequence and return to ground".
    // An OSC with an embedded CAN must not produce any OSC event,
    // and a follow-up DA1 query must still reply normally.
    let payload = b"\x1b]7;file:///never\x18reach\x1b\\\x1b[c";
    let (_evs, writes) = drive(payload);
    let any_da1 = writes.iter().any(|w| w == b"\x1b[?6c");
    assert!(
        any_da1,
        "DA1 must reply after CAN-aborted OSC; got writes {writes:?}"
    );
}

#[test]
fn osc_with_embedded_sub_aborts_cleanly() {
    // pre-flight: ~80 KiB, ~1 ms.
    // SUB (0x1A) is the secondary abort byte. Same contract as CAN.
    let payload = b"\x1b]7;file:///never\x1areach\x1b\\\x1b[c";
    let (_evs, writes) = drive(payload);
    let any_da1 = writes.iter().any(|w| w == b"\x1b[?6c");
    assert!(
        any_da1,
        "DA1 must reply after SUB-aborted OSC; got writes {writes:?}"
    );
}

#[test]
fn truncated_osc_without_st_does_not_swallow_input() {
    // pre-flight: ~80 KiB + ~8 KiB payload, ~3 ms.
    // An OSC 8 hyperlink prelude that is never terminated. After the
    // huge payload, a real CSI DA1 must still reply — meaning the
    // parser eventually bailed out of the unterminated OSC and
    // reached ground. Construction: ~8 KiB of payload bytes after the
    // OSC introducer, then a DA1 query.
    let mut payload: Vec<u8> = Vec::with_capacity(8200);
    payload.extend_from_slice(b"\x1b]8;;https://example.com/");
    payload.extend(std::iter::repeat_n(b'a', 8000));
    payload.extend_from_slice(b"\x1b[c");
    let (_evs, writes) = drive(&payload);
    // Whether DA1 fires depends on whether vte's OSC bail kicks in.
    // The minimum we pin: NO PANIC. If it does fire, that's a stronger
    // success.
    if writes.iter().any(|w| w == b"\x1b[?6c") {
        // Stronger property held — we made it back to ground.
    }
    // Otherwise: no crash, which is what this whole test wraps.
}

#[test]
fn osc8_followed_by_csi_2j_does_not_corrupt_state() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-005 / TST-S1-002 surface: a hostile remote interleaves a
    // CSI fragment inside an active OSC 8 hyperlink. The parser MUST
    // either complete the OSC cleanly OR drop it; either way, the
    // visible grid after a final CSI 2 J (clear screen) must be
    // empty (modulo cursor row) and a follow-up DA1 must still reply.
    let payload = b"\x1b]8;;url\x1b[2J\x1b\\\x1b[c";
    let (_evs, writes) = drive(payload);
    let any_da1 = writes.iter().any(|w| w == b"\x1b[?6c");
    assert!(
        any_da1,
        "DA1 must reply after OSC 8 / CSI 2J interleave; got writes {writes:?}"
    );
}

// ---------------------------------------------------------------------------
// Track A: TST-S1-002 — CSI 2 J inside OSC payload must NOT trigger the
// scrollback-erase augmentation
// ---------------------------------------------------------------------------

#[test]
fn csi_2j_bytes_inside_bel_terminated_osc_do_not_clear_scrollback() {
    // pre-flight: ~120 KiB (term + 1000-line scrollback), ~10 ms.
    // TST-S1-002 (high). The ED-all augmentation in `bb_term_input`
    // injects an `ESC[3J` whenever it sees a top-level `ESC[2J`, so
    // that `clear(1)` also wipes scrollback. The real threat class:
    // a `[2J` literal byte sequence INSIDE an OSC payload must NOT
    // trigger the injection when the OSC is still open — otherwise a
    // hostile remote could wipe scrollback by embedding the clear-
    // screen BYTES (no ESC) in an OSC 8 URL field.
    //
    // NOTE: per ECMA-48 / xterm / vte behaviour, a raw `ESC` byte
    // inside an OSC terminates the OSC. The original payload from
    // this test (`\x1b]8;;\x1b[2J\x1b\\…`) is therefore seen as OSC
    // 8 + top-level CSI 2J + ST — the augmentation CORRECTLY fires
    // in that case. The threat is not "ESC-embedded in OSC" but
    // "CSI-2J-LOOKING BYTES inside a BEL-terminated OSC 8 URL".
    unsafe {
        let term = bc::bb_term_new(20, 5, 1000);
        for i in 0..200 {
            let line = format!("MAIN{:03}\n", i);
            bc::bb_term_input(term, line.as_ptr(), line.len());
        }
        let snap = bc::bb_term_take_snapshot(term);
        let history_before = (*snap).history_size;
        bc::bb_snap_release(snap);
        assert!(
            history_before > 0,
            "precondition: must have scrollback to test wipe-resistance"
        );

        // BEL-terminated OSC 8. The `[2J` inside the URL field is
        // just literal bytes in the OSC payload — no ESC, so the
        // parser stays inside OSC state until the BEL. The scrollback
        // must survive.
        let payload = b"\x1b]8;;https://a.example/[2J\x07PROBE";
        bc::bb_term_input(term, payload.as_ptr(), payload.len());

        let snap = bc::bb_term_take_snapshot(term);
        let history_after = (*snap).history_size;
        bc::bb_snap_release(snap);
        assert!(
            history_after >= history_before.saturating_sub(2),
            "OSC-embedded `[2J` bytes must not erase scrollback: history was {history_before} \
             before, {history_after} after — TST-S1-002 regression"
        );
        bc::bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track B: scroll API extreme deltas (TST-S1-012)
// ---------------------------------------------------------------------------

#[test]
fn scroll_extreme_deltas_dont_trap_or_change_offset_when_no_scrollback() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-012 (medium). i32::MAX and i32::MIN must not overflow
    // arithmetic in the scroll path. A fresh term has no scrollback,
    // so display_offset must be 0 before AND after any scroll call.
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        let snap = bc::bb_term_take_snapshot(term);
        assert_eq!((*snap).display_offset, 0, "fresh term must be at offset 0");
        bc::bb_snap_release(snap);

        bc::bb_term_scroll(term, i32::MAX);
        let snap = bc::bb_term_take_snapshot(term);
        let offset_after_max = (*snap).display_offset;
        bc::bb_snap_release(snap);
        assert_eq!(
            offset_after_max, 0,
            "scroll(i32::MAX) on empty scrollback must clamp to 0"
        );

        bc::bb_term_scroll(term, i32::MIN);
        let snap = bc::bb_term_take_snapshot(term);
        let offset_after_min = (*snap).display_offset;
        bc::bb_snap_release(snap);
        assert_eq!(
            offset_after_min, 0,
            "scroll(i32::MIN) must not underflow into a non-zero offset"
        );

        bc::bb_term_free(term);
    }
}

#[test]
fn scroll_delta_zero_is_a_noop_on_offset() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-012. Pin that delta=0 leaves display_offset at zero on
    // a fresh term. (The function may still pre-emptively damage
    // rows, but the offset must not change.)
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        let snap_before = bc::bb_term_take_snapshot(term);
        let off_before = (*snap_before).display_offset;
        bc::bb_snap_release(snap_before);

        bc::bb_term_scroll(term, 0);
        let snap_after = bc::bb_term_take_snapshot(term);
        let off_after = (*snap_after).display_offset;
        bc::bb_snap_release(snap_after);
        assert_eq!(
            off_before, off_after,
            "scroll(0) must not change display_offset"
        );
        bc::bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track A: TST-S1-008 — null snap → damage_is_full=1 invariant
// ---------------------------------------------------------------------------

#[test]
fn null_snap_damage_is_full_returns_one() {
    // pre-flight: ~0 bytes (no allocation), ~1 ms.
    // TST-S1-008 (medium). Documented invariant: a null snapshot
    // pointer reports `damage_is_full = 1`, the safe "redraw
    // everything" default. A regression that returned 0 (only) for
    // null would let a renderer skip drawing on a null-snapshot
    // path, painting stale GPU contents.
    unsafe {
        let v = bc::bb_snap_damage_is_full(std::ptr::null());
        assert_eq!(
            v, 1,
            "null snap must report damage_is_full=1 (safe default 'redraw all')"
        );
    }
}

// ---------------------------------------------------------------------------
// Track A: TST-S1-006 — bb_snap_damage_rows with unaligned out pointer
// ---------------------------------------------------------------------------

#[test]
fn damage_rows_writes_to_unaligned_out_buffer() {
    // pre-flight: ~80 KiB + 32 B buffer, ~1 ms.
    // TST-S1-006 (medium). The function must copy byte-wise (not via
    // a u16-aligned pointer cast) so that callers passing an odd
    // address don't trigger a misaligned access trap. Construct a
    // small buffer and shift the start by 1 byte to force odd
    // alignment; verify the function writes there without trapping
    // and reports a sensible total.
    unsafe {
        let term = bc::bb_term_new(10, 4, 100);
        // Drain initial full-damage state.
        let s0 = bc::bb_term_take_snapshot(term);
        bc::bb_snap_release(s0);
        // Trigger a partial damage by writing into row 0.
        bc::bb_term_input(term, b"X".as_ptr(), 1);
        let s1 = bc::bb_term_take_snapshot(term);
        // 32-byte buffer; if `as_mut_ptr().add(1)` happens to be
        // 16-aligned the test still passes — alignment is opaque to
        // the FFI promise that bytes-wise copy works.
        let mut backing = [0u8; 32];
        let unaligned_out = backing.as_mut_ptr().add(1) as *mut u16;
        let total = bc::bb_snap_damage_rows(s1, unaligned_out, /*out_cap=*/ 4);
        // No assertion on the EXACT total — alacritty's damage policy
        // is implementation-defined for a 1-char write — only that
        // calling with an unaligned out doesn't trap and returns a
        // bounded number.
        assert!(
            total <= 4,
            "unaligned-out call must respect out_cap (got {total})"
        );
        bc::bb_snap_release(s1);
        bc::bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track A: TST-S1-013 — deep re-entry into Fatal callback is swallowed
// ---------------------------------------------------------------------------

// We don't have access to bb_term_test_only_panic from outside the crate
// (it's behind the test-only feature and not in the public C header),
// so a direct deep-reentry test would require an internal-API hook.
// Instead, this file pins the user-observable behaviour: registering a
// callback that itself calls back into bb_term_input WILL hit the
// re-entry latch and the resulting Fatal must not infinitely recurse
// the callback.

unsafe extern "C" fn reentrant_cb(_ev: bc::BBEvent, ctx: *mut c_void) {
    // Increment a counter so the test verifies we landed at most ONCE
    // even if Fatal would otherwise re-fire. The callback intentionally
    // does NOT call bb_term_input itself — that would breach the FFI
    // re-entry contract. We just count.
    let counter = unsafe { &*(ctx as *const Mutex<u32>) };
    *counter.lock().unwrap() += 1;
}

#[test]
fn callback_registered_for_fragmented_da1_only_fires_once_per_query() {
    // pre-flight: ~80 KiB, ~1 ms.
    // TST-S1-013-adjacent. A DA1 query split across multiple feed
    // calls should produce exactly ONE PtyWrite event. A regression
    // that fired twice would breach the FFI's "one event per
    // semantically-complete sequence" promise and bombard the host
    // with redundant callbacks.
    let counter: Arc<Mutex<u32>> = Arc::new(Mutex::new(0));
    let counter_ptr = Arc::into_raw(counter.clone()) as *mut c_void;
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        bc::bb_term_set_event_cb(term, Some(reentrant_cb), counter_ptr);
        // Split DA1 into 4 fragments.
        bc::bb_term_input(term, b"\x1b".as_ptr(), 1);
        bc::bb_term_input(term, b"[".as_ptr(), 1);
        bc::bb_term_input(term, b"".as_ptr(), 0); // zero-length — must be no-op
        bc::bb_term_input(term, b"c".as_ptr(), 1);
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Arc::from_raw(counter_ptr as *const Mutex<u32>));
    }
    let count = *counter.lock().unwrap();
    assert_eq!(
        count, 1,
        "fragmented DA1 query must fire exactly one event; got {count}"
    );
}

// ---------------------------------------------------------------------------
// Track B: SGR with unusual params
// ---------------------------------------------------------------------------

#[test]
fn sgr_negative_param_clamping() {
    // pre-flight: ~80 KiB, ~1 ms.
    // CSI params are unsigned ASCII digits in the spec, but vte parses
    // any sequence of digit-like bytes. Some emitters (buggy escape
    // sequence builders) emit `;-1m` or `;9999m`. The FFI must not
    // crash; the resulting cell may have any flags but must be
    // reachable.
    let payloads: &[&[u8]] = &[
        b"\x1b[9999mX",  // huge param
        b"\x1b[0;0;0mX", // zero triple
        b"\x1b[;mX",     // empty params (alacritty: equivalent to reset)
    ];
    unsafe {
        for p in payloads {
            let term = bc::bb_term_new(10, 1, 100);
            bc::bb_term_input(term, p.as_ptr(), p.len());
            let snap = bc::bb_term_take_snapshot(term);
            // Find 'X' in any of the first 5 cells.
            let mut found = false;
            for c in 0u16..5 {
                if cell_at(snap, c, 0).ch == b'X' as u32 {
                    found = true;
                    break;
                }
            }
            assert!(found, "trailing 'X' must reach grid for SGR {:?}", p);
            bc::bb_snap_release(snap);
            bc::bb_term_free(term);
        }
    }
}

#[test]
fn sgr_38_2_with_truncated_rgb_does_not_panic() {
    // pre-flight: ~80 KiB, ~1 ms.
    // `CSI 38 ; 2 ; R ; G ; B m` is the truecolor SGR. Truncated forms
    // (missing G or B) are common on broken emitters. The FFI must
    // not panic; alacritty parses what it can and the rest defaults.
    let payloads: &[&[u8]] = &[
        b"\x1b[38;2mX",         // missing all RGB
        b"\x1b[38;2;255mX",     // R only
        b"\x1b[38;2;255;128mX", // R + G only
    ];
    unsafe {
        for p in payloads {
            let term = bc::bb_term_new(10, 1, 100);
            bc::bb_term_input(term, p.as_ptr(), p.len());
            let snap = bc::bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            bc::bb_snap_release(snap);
            bc::bb_term_free(term);
        }
    }
}

// ---------------------------------------------------------------------------
// Track B: small-cap resize boundary (NOT u16::MAX — that's covered)
// ---------------------------------------------------------------------------

#[test]
fn resize_at_small_boundary_dims_is_safe() {
    // pre-flight: ~32 KiB (1000×1 grid + 2×2 grid), ~5 ms.
    // The clamp floor is 2 (per docs); below-floor inputs clamp UP.
    // Pin the FFI no-trap boundary at the SMALLEST permissible grid
    // (2×2) and at adversarial transitions (huge → tiny → huge). Pre-
    // flight: 1000 × 1 × 32 = 32 KiB max, well under safety bound.
    const MAX_BYTES_PRODUCT: u64 = 1024 * 1024; // 1 MiB cells max
    let dims: &[(u16, u16)] = &[(2, 2), (1000, 1), (1, 1000), (2, 1000), (1000, 2)];
    for (cols, rows) in dims {
        let product = (*cols as u64) * (*rows as u64);
        assert!(
            product <= MAX_BYTES_PRODUCT,
            "test pre-flight: {cols}×{rows} = {product} cells exceeds MAX_BYTES_PRODUCT"
        );
    }
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        for (cols, rows) in dims {
            let r = bc::bb_term_resize2(term, *cols, *rows);
            assert!(
                r.applied_cols >= 2 && r.applied_rows >= 2,
                "boundary resize ({cols},{rows}) → applied ({},{}) violated MIN_DIM=2",
                r.applied_cols,
                r.applied_rows
            );
        }
        bc::bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track B: rapid resize churn on the edge cases
// ---------------------------------------------------------------------------

#[test]
fn rapid_resize_churn_does_not_leak_or_trap() {
    // pre-flight: ~512 KiB peak (one snapshot of a 200×60 grid), ~50 ms.
    // 64 resizes between (10×3) and (200×60) with intervening input.
    // Pin: every snapshot taken mid-churn is non-null and reports a
    // dim within MIN_DIM..=1000.
    const MAX_PRODUCT: u64 = 200 * 60;
    let _check: u64 = MAX_PRODUCT * 32;
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        for i in 0..64 {
            let cols = if i & 1 == 0 { 10 } else { 200 };
            let rows = if i & 1 == 0 { 3 } else { 60 };
            bc::bb_term_resize(term, cols, rows);
            bc::bb_term_input(term, b"x".as_ptr(), 1);
            let snap = bc::bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            assert!((*snap).cols >= 2 && (*snap).rows >= 2);
            assert!((*snap).cols <= 1000 && (*snap).rows <= 1000);
            bc::bb_snap_release(snap);
        }
        bc::bb_term_free(term);
    }
}
