#![no_main]
//! `fuzz_resize2` — interleave `bb_term_resize2` calls with mid-OSC,
//! mid-DCS, mid-CSI, mid-OSC8, and alt-screen toggle byte fragments.
//!
//! ## Why this target exists
//!
//! `bb_term_resize2` is the explicit, return-value-bearing form of
//! `bb_term_resize` (the void form delegates to it; see
//! `core/src/lib.rs:2329`). Today `bb_term_resize2` is hit only by a small
//! deterministic dim sweep in `core/tests/sweep_fuzz_ffi.rs`
//! (`resize_at_small_boundary_dims_is_safe`, ~5 dim pairs). That leaves a
//! real coverage gap: resize-DURING-mid-parser-state — the case that
//! actually happens in the wild every time a SwiftUI window animation,
//! Stage Manager swap, or ⌘+/⌘− rapid key-repeat lands a TIOCSWINSZ while
//! the shell is mid-OSC (CWD report), mid-DCS (XTGETTCAP query), or
//! mid-1049 alt-screen swap (vim/less paging in/out).
//!
//! ## Observed `bb_term_resize2` signature (from `core/src/lib.rs:2364`)
//!
//! ```ignore
//! pub unsafe extern "C" fn bb_term_resize2(
//!     term: *mut BBTerm,
//!     cols: u16,
//!     rows: u16,
//! ) -> BBResizeResult;
//! ```
//!
//! That's 3 parameters — there is NO `cell_px_w` / `cell_px_h` / metric
//! argument; pixel metrics are not part of the core's resize contract
//! (the renderer side owns them). The return value `BBResizeResult` is
//! `#[repr(C)] { applied_cols: u16, applied_rows: u16, clamped: u8,
//! _pad: [u8;3] }` — we ignore it on the fuzz path (the contract under
//! test is "no panic / no UB"; the `applied_*` shape is pinned by
//! `sweep_fuzz_ffi.rs`).
//!
//! ## resize2 vs resize divergence
//!
//! `bb_term_resize` (line 2329) is a one-line shim: `let _ =
//! bb_term_resize2(term, cols, rows);` — they share the entire clamp /
//! reflow body. In strict-coverage terms, resize2-targeted fuzzing
//! covers the same code as resize-targeted fuzzing. The reason this
//! target still pulls its weight: the existing `fuzz_term_input` driver
//! couples resize timing to parser payload (one resize after the entire
//! feed). Here resize is interleaved BETWEEN fragments, so libFuzzer
//! sees a different temporal product — the same clamp body executed
//! across a different parser-state landscape.
//!
//! ## Byte layout (driven by libFuzzer-supplied `data: &[u8]`)
//!
//! ```text
//! data[0]                  = number of cycles (raw byte; clamped to 0..=32)
//! per cycle (5 bytes each, starting at offset 1):
//!   +0                     = fragment index (mod FRAGMENTS.len())
//!   +1..=2                 = cols (u16 LE; passed verbatim — the [2,1000] clamp at
//!                            lib.rs:2385 is the contract under test)
//!   +3..=4                 = rows (u16 LE; same contract)
//! ```
//!
//! Cycles whose 5-byte slice would read past `data.len()` are skipped
//! (no padding, no wrap — keep the temporal pattern faithful to the
//! corpus byte). The loop hard-caps at 32 cycles regardless of input,
//! matching the per-iter wall-time budget below.
//!
//! ## Per-iter budget
//!
//! - 1 KiB seed feed (plaintext + SGR) — pre-loop, runs once.
//! - 32 cycles × (≤256-byte fragment input + 1 resize2 + 1 take/release) ≈
//!   sub-millisecond on a warm cache, well under the 50ms target even
//!   if every cycle hits MAX_DIM=1000 (the resize is O(rows × cols)
//!   only on the dim-changing branch; the clamp short-circuits once
//!   reached). Fragments are static `&'static [u8]` slices — no
//!   per-cycle allocation.
//!
//! ## Allocation balance
//!
//! Every `bb_term_take_snapshot` is paired with `bb_snap_release`. The
//! single `bb_term_new` is paired with `bb_term_free`. No retained
//! refcounts (those are exercised by `fuzz_term_input`).
//!
//! ## Fatal oracle (mirrors `fuzz_term_input.rs`)
//!
//! `guard_with_term` in `blackbird_core` routes every caught panic to a
//! `BBEventKind::Fatal` event. Without a callback, those panics are
//! swallowed and the fuzzer's oracle is blind. We register a callback,
//! flip a static latch on Fatal, and `panic!` post-iteration to fail
//! the run so cargo-fuzz captures a reproducer.

use libfuzzer_sys::fuzz_target;
use std::sync::atomic::{AtomicBool, Ordering};

/// Latch flipped by the event callback when `guard_with_term` dispatches
/// a `BBEventKind::Fatal`. Cleared at the start of every fuzz iteration.
static SAW_FATAL: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn on_event(ev: blackbird_core::BBEvent, _ctx: *mut std::ffi::c_void) {
    if ev.kind == blackbird_core::BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
}

/// Mid-state byte fragments. Each leaves the VT parser (or alt-screen
/// state machine) in a partial state when a `bb_term_resize2` call lands
/// on the next line. All capped well under 256 bytes.
///
/// Index meaning is stable so libFuzzer can learn "byte 0x00 = mid-OSC"
/// from coverage feedback. Adding a new fragment must append, never
/// reorder.
static FRAGMENTS: &[&[u8]] = &[
    // 0: Mid-OSC — OSC 0 (set window title) with payload truncated mid-string.
    //    Parser is in OSC payload state, awaiting BEL or ST.
    b"\x1b]0;hostnam",
    // 1: Mid-DCS — XTGETTCAP request with intro + final but no terminator.
    //    Parser is in DCS pass-through state.
    b"\x1bP+q",
    // 2: Mid-CSI — CSI with 3 numeric params, no final byte.
    //    Parser is in CSI parameter state.
    b"\x1b[1;2;3",
    // 3: Mid-OSC 8 — hyperlink prelude with a truncated URI.
    //    Parser is mid-payload of an OSC 8 link.
    b"\x1b]8;;https://exa",
    // 4: Alt-screen ENTER complete (CSI ? 1049 h) — cursor save + alt
    //    grid swap. Parser returns to ground but term state is on alt.
    b"\x1b[?1049h",
    // 5: Alt-screen EXIT complete (CSI ? 1049 l) — restore primary grid.
    //    Pairs naturally with index 4 across cycles.
    b"\x1b[?1049l",
    // 6: Plain ASCII row — ~half a row of printable bytes at common
    //    widths (~40 cols, fits 80×24 default and exercises wrap on
    //    smaller resizes).
    b"the quick brown fox jumps over a lazy dog ",
    // 7: Mid-OSC 7 — CWD report with file:// URI cut mid-path.
    b"\x1b]7;file:///Users/conn",
    // 8: SGR mid-set — sets bold red foreground but leaves no printable
    //    char so the next fragment paints into the active style.
    b"\x1b[1;31m",
];

fuzz_target!(|data: &[u8]| {
    if data.is_empty() {
        return;
    }
    SAW_FATAL.store(false, Ordering::SeqCst);

    unsafe {
        // Start at a common 80×24 with 1000-line scrollback — same baseline
        // as `fuzz_term_input` so corpus dimensions stay comparable.
        let term = blackbird_core::bb_term_new(80, 24, 1_000);
        if term.is_null() {
            return;
        }
        blackbird_core::bb_term_set_event_cb(term, Some(on_event), std::ptr::null_mut());

        // Pre-feed a populated grid so resize2 lands on a non-empty term
        // (reflow paths differ on empty vs populated). 1 KiB of plaintext
        // sprinkled with SGR — small enough to keep per-iter budget tight,
        // large enough to fill several rows on the default 80×24.
        const SEED: &[u8] =
            b"\x1b[1;32mblackbird seed line one\x1b[0m\n\
              second line of seed text for resize reflow coverage\n\
              \x1b[33;44mthird line with bg color for visual diff\x1b[0m\n\
              fourth line plain ascii to fill out the populated grid\n\
              fifth line so the scrollback has at least one banked row\n\
              \x1b[7minverse video sixth line to vary cell flags\x1b[0m\n\
              seventh line of ordinary text continuing the pattern\n\
              eighth line completes the seed and tops the visible viewport\n";
        blackbird_core::bb_term_input(term, SEED.as_ptr(), SEED.len());

        // Cycle count: capped at 32 to bound per-iter wall time.
        let max_cycles = (data[0] as usize).min(32);

        // Each cycle reads 5 bytes starting at offset 1.
        const CYCLE_BYTES: usize = 5;
        let mut off: usize = 1;

        for _ in 0..max_cycles {
            // Skip cycle if its 5-byte slot would run past data.
            if off + CYCLE_BYTES > data.len() {
                break;
            }
            let frag_idx = data[off] as usize;
            let cols = u16::from_le_bytes([data[off + 1], data[off + 2]]);
            let rows = u16::from_le_bytes([data[off + 3], data[off + 4]]);
            off += CYCLE_BYTES;

            let frag = FRAGMENTS[frag_idx % FRAGMENTS.len()];
            // Each FRAGMENTS entry is a `&'static [u8]` of ≤256 bytes by
            // construction. The cap is enforced at the source, not here.
            blackbird_core::bb_term_input(term, frag.as_ptr(), frag.len());

            // The clamp at lib.rs:2385 is the contract under test —
            // pass cols/rows verbatim, including 0 (early return at
            // 2376) and dims well over MAX_DIM=1000.
            let _ = blackbird_core::bb_term_resize2(term, cols, rows);

            // Snapshot during mid-parser-state + just-resized term. This
            // is the path the harness exists for: the resize must NOT
            // leave snapshot accessors observing torn state.
            let snap = blackbird_core::bb_term_take_snapshot(term);
            if !snap.is_null() {
                blackbird_core::bb_snap_release(snap);
            }
        }

        blackbird_core::bb_term_free(term);
    }

    if SAW_FATAL.swap(false, Ordering::SeqCst) {
        panic!("blackbird_core routed a BBEventKind::Fatal — panic inside a guarded FFI");
    }
});
