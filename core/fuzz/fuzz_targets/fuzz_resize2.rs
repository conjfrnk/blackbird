#![no_main]
//! Interleaves `bb_term_resize2` with mid-OSC, mid-DCS, mid-CSI, mid-OSC8 and alt-screen fragments.

use libfuzzer_sys::fuzz_target;
use std::sync::atomic::{AtomicBool, Ordering};

static SAW_FATAL: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn on_event(ev: blackbird_core::BBEvent, _ctx: *mut std::ffi::c_void) {
    if ev.kind == blackbird_core::BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
}

/// Each leaves the VT parser (or alt-screen state machine) in a partial state for the resize.
/// Index meaning is stable for the corpus: a new fragment must append, never reorder.
static FRAGMENTS: &[&[u8]] = &[
    b"\x1b]0;hostnam",
    b"\x1bP+q",
    b"\x1b[1;2;3",
    b"\x1b]8;;https://exa",
    b"\x1b[?1049h",
    b"\x1b[?1049l",
    b"the quick brown fox jumps over a lazy dog ",
    b"\x1b]7;file:///Users/conn",
    b"\x1b[1;31m",
];

fuzz_target!(|data: &[u8]| {
    if data.is_empty() {
        return;
    }
    SAW_FATAL.store(false, Ordering::SeqCst);

    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 1_000);
        if term.is_null() {
            return;
        }
        blackbird_core::bb_term_set_event_cb(term, Some(on_event), std::ptr::null_mut());

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

        let max_cycles = (data[0] as usize).min(32);

        // Per cycle, from offset 1: fragment index (1 byte), cols (u16 LE), rows (u16 LE).
        const CYCLE_BYTES: usize = 5;
        let mut off: usize = 1;

        for _ in 0..max_cycles {
            if off + CYCLE_BYTES > data.len() {
                break;
            }
            let frag_idx = data[off] as usize;
            let cols = u16::from_le_bytes([data[off + 1], data[off + 2]]);
            let rows = u16::from_le_bytes([data[off + 3], data[off + 4]]);
            off += CYCLE_BYTES;

            let frag = FRAGMENTS[frag_idx % FRAGMENTS.len()];
            blackbird_core::bb_term_input(term, frag.as_ptr(), frag.len());

            // The clamp is the contract under test: pass cols/rows verbatim, including 0 and
            // dims well over MAX_DIM.
            let _ = blackbird_core::bb_term_resize2(term, cols, rows);

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
