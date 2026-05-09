#![no_main]

use libfuzzer_sys::fuzz_target;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

// Global "saw Fatal" latch — same oracle pattern as `fuzz_term_input.rs`.
// Every caught panic in `guard_with_term` routes to a `BBEventKind::Fatal`
// event; without a registered callback, those panics are silent and the
// fuzzer's oracle is blind. We register a callback, observe the latch
// after each fuzz iteration, and `panic!` to fail the run so cargo-fuzz
// captures a reproducer.
static SAW_FATAL: AtomicBool = AtomicBool::new(false);

// Counts bytes drained off the `BBEventKind::PtyWrite` channel during
// this iteration. The PtyWrite path is the whole point of this fuzz
// target — DA / DSR / OSC 10/11/12 / OSC 4 / OSC 52 / XTGETTCAP /
// DECRQM / XTWINOPS replies all surface as `PtyWrite` events that
// `core/src/lib.rs:135`'s `pty_write_rate` cap gates. We accumulate
// length so the channel can't fill unbounded inside the callback (the
// rate cap silently drops excess; we still want to read the bytes the
// cap *did* let through to flush the path through the C boundary).
//
// Reset per-iter; never read except by the callback. The accumulator
// guarantees the optimiser can't elide the FFI work.
static PTY_WRITE_BYTES: AtomicUsize = AtomicUsize::new(0);

unsafe extern "C" fn on_event(ev: blackbird_core::BBEvent, _ctx: *mut std::ffi::c_void) {
    if ev.kind == blackbird_core::BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
    // Drain the PTY-bound bytes by counting them. The `payload` pointer
    // is borrowed for the duration of the callback only (per
    // `BBEvent::payload` doc on lib.rs:87-88) — we never store it; we
    // just accumulate the length so the optimiser keeps the path live.
    if ev.kind == blackbird_core::BBEventKind::PtyWrite && ev.len > 0 && !ev.payload.is_null() {
        PTY_WRITE_BYTES.fetch_add(ev.len, Ordering::Relaxed);
    }
}

/// Library of reply-eliciting input fragments. Each one drives a
/// distinct PtyWrite-emitting code path inside blackbird_core:
///
/// - DA1 / DA2 — `Event::PtyWrite` from alacritty's CSI dispatch
///   (`core/src/lib.rs:597-613`).
/// - DSR (status / cursor) — same alacritty PtyWrite path.
/// - OSC 4 ; N ; ? — `Event::ColorRequest` deferred via
///   `ColorRequestQueue`, drained by `drain_color_requests`
///   (`core/src/lib.rs:1980`), gated by `color_query_enabled`.
/// - OSC 10 / 11 / 12 ; ? — same deferred ColorRequest path; the
///   `set_color_query_enabled` flag flipping mid-storm is the
///   whole point.
/// - OSC 52 ; c ; ? — clipboard read; should NEVER reply (pinned by
///   `tests/osc52_readback.rs`). Including it here verifies the
///   "no-reply" path stays sound under storm.
/// - XTGETTCAP `5463` ("Tc" — not in `XTGETTCAP_TABLE`) — exercises
///   the unknown-cap reply branch in `build_xtgettcap_reply`
///   (`core/src/lib.rs:939-946`); also threads the
///   `dispatch_xtgettcap` direct-fire site through `pty_write_rate`.
/// - DECRQM private mode 9001 — `CSI ? 9001 $ p`; alacritty replies
///   "not recognized" via the standard PtyWrite path.
/// - XTWINOPS `\x1b[8t` — incomplete window-op (the `8` = "resize text
///   area in chars" sub-op needs args); alacritty either replies or
///   drops, exercising the dispatch table either way.
const FRAGMENTS: &[&[u8]] = &[
    b"\x1b[c",                  // DA1 (Primary Device Attributes)
    b"\x1b[6n",                 // DSR (cursor position)
    b"\x1b]4;1;?\x07",          // OSC 4 palette query (slot 1)
    b"\x1b]10;?\x07",           // OSC 10 fg color query
    b"\x1b]11;?\x07",           // OSC 11 bg color query
    b"\x1b]12;?\x07",           // OSC 12 cursor color query
    b"\x1b]52;c;?\x07",         // OSC 52 clipboard read (should NOT reply)
    b"\x1b[>c",                 // DA2 (Secondary Device Attributes)
    b"\x1b[5n",                 // DSR status report
    b"\x1bP+q5463\x1b\\",       // XTGETTCAP — "Tc" cap, unknown branch
    b"\x1b[?9001$p",            // DECRQM private mode 9001
    b"\x1b[8t",                 // XTWINOPS sub-op 8
];

/// Tiny ASCII seed pre-fed before the storm so the term is in a
/// populated, non-pristine state when the queries land. Mixes a few
/// printable chars, a CR, an LF, and a couple of common SGR resets so
/// the cursor isn't at (1,1) when DSR-CPR fires. Kept under 256 bytes
/// per the requirements.
const PREFEED_SEED: &[u8] =
    b"hello \x1b[31mworld\x1b[0m\r\n\
      lorem \x1b[1mipsum\x1b[0m\r\n\
      dolor \x1b[4msit\x1b[0m amet\r\n\
      consectetur adipiscing\r\n\
      elit sed do eiusmod\r\n\
      tempor incididunt ut\r\n\
      labore et dolore magna\r\n\
      aliqua ut enim ad minim";

fuzz_target!(|data: &[u8]| {
    // Empty input — early return; nothing to drive.
    if data.is_empty() {
        return;
    }
    // Need at least the two header bytes (count + initial flag) before
    // we can read pair bytes. A single-byte input is still valid: the
    // count would be derived but no pairs follow, so the storm loop
    // runs zero iterations.
    SAW_FATAL.store(false, Ordering::SeqCst);
    PTY_WRITE_BYTES.store(0, Ordering::Relaxed);

    // Header byte 0: number of replies to send, 0..=64. Per the task
    // spec, this caps per-iter work so libFuzzer stays bounded.
    let reply_count = (data[0] % 65) as usize;

    // Header byte 1: initial color-query-enabled state. Use the LSB so
    // libFuzzer's bit-flip mutators flip it cheaply. Falls back to 0
    // when input is exactly 1 byte long (data[1] doesn't exist) — that
    // matches the security default (`set_color_query_enabled` defaults
    // off; the tests in `color_query.rs` opt in explicitly).
    let initial_color_flag: u8 = if data.len() >= 2 { data[1] & 1 } else { 0 };

    // Pair stream starts at byte 2.
    let pairs: &[u8] = if data.len() > 2 { &data[2..] } else { &[] };

    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 1_000);
        if term.is_null() {
            return;
        }
        blackbird_core::bb_term_set_event_cb(term, Some(on_event), std::ptr::null_mut());
        // Set initial flag BEFORE pre-feed so any incidental queries in
        // PREFEED_SEED (there are none today, but defensively) follow
        // the post-init policy.
        blackbird_core::bb_term_set_color_query_enabled(term, initial_color_flag);

        // Pre-feed a populated state. PREFEED_SEED is a const so a
        // mistake here is a compile-time error; runtime-bounded by the
        // const's static len.
        blackbird_core::bb_term_input(term, PREFEED_SEED.as_ptr(), PREFEED_SEED.len());

        // Track the live flag so the toggle bit can flip it without
        // needing to read it back from the term (no FFI getter exists,
        // and one isn't required for fuzzing — we just need the value
        // we're flipping toward).
        let mut color_flag: u8 = initial_color_flag;

        // Storm loop. Each iteration:
        //   1. derive (fragment_idx, toggle_flag) from one pair byte
        //      (with wrap-around; pair stream may be shorter than
        //      reply_count, so cycle).
        //   2. feed the chosen fragment via `bb_term_input`.
        //   3. if toggle bit set, flip color_query_enabled.
        //   4. every 8th reply, snapshot+release to exercise the reply
        //      queue under snapshot churn.
        //
        // FRAGMENTS.len() is a const < 128 so `low7 % len(FRAGMENTS)`
        // is well-defined for any `low7` in 0..128.
        for i in 0..reply_count {
            // Pair byte derivation. When `pairs` is empty, fall back to
            // header-byte-derived index so the storm still does work
            // (the input is at least 1 byte; 0 replies if data[0] % 65
            // == 0 means we never enter the loop anyway).
            let pair = if !pairs.is_empty() {
                pairs[i % pairs.len()]
            } else {
                data[0]
            };
            let toggle = (pair & 0x80) != 0;
            let frag_idx = (pair & 0x7F) as usize % FRAGMENTS.len();
            let frag = FRAGMENTS[frag_idx];
            blackbird_core::bb_term_input(term, frag.as_ptr(), frag.len());

            if toggle {
                color_flag ^= 1;
                blackbird_core::bb_term_set_color_query_enabled(term, color_flag);
            }

            // Snapshot churn every 8 replies. Take + release immediately —
            // we don't probe per-snapshot accessors here (that's
            // `fuzz_term_input.rs`'s job); the goal is to keep the
            // term's snapshot lifetime moving while the reply queue is
            // active.
            if i.is_multiple_of(8) {
                let s = blackbird_core::bb_term_take_snapshot(term);
                if !s.is_null() {
                    blackbird_core::bb_snap_release(s);
                }
            }
        }

        // Final snapshot to flush any deferred work in the reply queue
        // (drains happen inside `bb_term_input`, but the take_snapshot
        // path also walks term state and is a useful additional probe
        // surface).
        let s = blackbird_core::bb_term_take_snapshot(term);
        if !s.is_null() {
            blackbird_core::bb_snap_release(s);
        }

        // Tear down. `bb_term_free` releases the callback cell and the
        // ColorRequestQueue's Arc, balancing the `bb_term_new` alloc.
        blackbird_core::bb_term_free(term);
    }

    // Sanity: keep the optimiser honest about PTY_WRITE_BYTES — read
    // it back so the accumulating fetch_add in the callback can't be
    // dead-code-eliminated. We don't assert anything about its value
    // (the rate cap is non-deterministic w.r.t. input order under the
    // sliding window) — just that the load is observed.
    let _drained = PTY_WRITE_BYTES.load(Ordering::Relaxed);

    // Oracle: identical to `fuzz_term_input.rs`. Any caught panic in a
    // guarded FFI routes to `BBEventKind::Fatal`; surface it as a fuzz
    // failure so cargo-fuzz minimises and persists the input to
    // artifacts/.
    if SAW_FATAL.swap(false, Ordering::SeqCst) {
        panic!("blackbird_core routed a BBEventKind::Fatal — panic inside a guarded FFI");
    }
});
