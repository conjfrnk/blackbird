#![no_main]

use libfuzzer_sys::fuzz_target;
use std::sync::atomic::{AtomicBool, Ordering};

// Global "saw Fatal" latch flipped by the event callback. `guard_with_term` in
// blackbird_core routes every caught panic to a `BBEventKind::Fatal` event; if
// no callback is registered, those panics go to /dev/null and the fuzzer's
// oracle is blind to them. We register a callback, observe the latch after
// each fuzz iteration, and `panic!` to fail the run so cargo-fuzz captures a
// reproducer. This turns the 67 `assert!` / `unwrap` / `debug_assert!` paths
// reachable from fuzzed input into fuzzing oracles.
static SAW_FATAL: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn on_event(ev: blackbird_core::BBEvent, _ctx: *mut std::ffi::c_void) {
    if ev.kind == blackbird_core::BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
}

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

        blackbird_core::bb_term_input(term, data.as_ptr(), data.len());

        // Exercise the query-mode toggle — the color-query-enabled flag
        // changes OSC 10/11/12 dispatching, and its own path was uncovered
        // by the existing harness.
        blackbird_core::bb_term_set_color_query_enabled(term, data[0] & 1);

        // Read current-mode bits so the getter's guard sees arbitrary post-
        // input state.
        let _ = blackbird_core::bb_term_current_mode(term);

        // Snapshot path.
        let snap = blackbird_core::bb_term_take_snapshot(term);
        if !snap.is_null() {
            // Exercise retain/release balance and the damage-rows / link-id /
            // link-url accessors so refcount + bounds paths are fuzz-covered.
            let snap2 = blackbird_core::bb_snap_retain(snap);
            let _ = blackbird_core::bb_snap_damage_is_full(snap);
            let mut buf = [0u16; 256];
            let _ = blackbird_core::bb_snap_damage_rows(snap, buf.as_mut_ptr(), buf.len());
            if data.len() >= 4 {
                // Row/col bytes sourced from fuzzed data — u16 cast is
                // the full signature. alacritty's damage iter returns
                // monotonic rows but the snapshot accessor will see
                // arbitrary input here, exercising its bounds path.
                let row = u16::from(data[0]);
                let col = u16::from(data.get(1).copied().unwrap_or(0));
                let link_id = blackbird_core::bb_snap_link_id_at(snap, row, col);
                if link_id != 0 {
                    let _ = blackbird_core::bb_snap_link_url(snap, link_id);
                }
            }
            blackbird_core::bb_snap_release(snap2);
            blackbird_core::bb_snap_release(snap);
        }

        // Exercise text_range and scroll with fuzzed parameters so the
        // parser state after arbitrary input is stress-tested against
        // those downstream APIs too. Bounds come from the data itself
        // so the fuzzer can discover interesting combinations.
        if data.len() >= 8 {
            let s_line = i32::from_le_bytes([data[0], data[1], data[2], data[3]]);
            let e_line = i32::from_le_bytes([data[4], data[5], data[6], data[7]]);
            let s_col = u16::from(data.get(8).copied().unwrap_or(0));
            let e_col = u16::from(data.get(9).copied().unwrap_or(0));
            let rect = if data.len() > 10 { data[10] & 1 } else { 0 };
            let s = blackbird_core::bb_term_text_range(term, s_line, s_col, e_line, e_col, rect);
            if !s.is_null() {
                blackbird_core::bb_string_release(s);
            }

            let delta = i32::from_le_bytes([
                data[0],
                data.get(1).copied().unwrap_or(0),
                data.get(2).copied().unwrap_or(0),
                data.get(3).copied().unwrap_or(0),
            ]);
            blackbird_core::bb_term_scroll(term, delta);
            blackbird_core::bb_term_scroll_to_bottom(term);
        }

        // Resize to something non-zero derived from the fuzzed data.
        if data.len() >= 4 {
            let cols = u16::from(data[0]).max(1);
            let rows = u16::from(data[1]).max(1);
            blackbird_core::bb_term_resize(term, cols, rows);
        }

        // Exercise palette setter with fuzzed slot indices so extreme/
        // out-of-range slots go through the FFI guard. alacritty's Colors
        // setter ignores unknown slots, but the FFI boundary has to stay a
        // no-panic zone regardless.
        if data.len() >= 4 {
            let slot = u16::from_le_bytes([data[0], data[1]]);
            let rgb =
                u32::from_le_bytes([data[0], data[1], data[2], data.get(3).copied().unwrap_or(0)]);
            blackbird_core::bb_term_set_named_color(term, slot, rgb);
        }

        // And clear_all after all the above — so the cycle "chaotic input →
        // scrollback → clear → clean state" is reachable. Any stale state
        // left by prior calls that would panic clear_all surfaces here.
        blackbird_core::bb_term_clear_all(term);

        blackbird_core::bb_term_free(term);
    }

    // Oracle: if the callback saw a Fatal during this iteration, one of the
    // guarded FFIs caught a panic. Fail the fuzz run so cargo-fuzz minimises
    // and persists the input to artifacts/.
    if SAW_FATAL.swap(false, Ordering::SeqCst) {
        panic!("blackbird_core routed a BBEventKind::Fatal — panic inside a guarded FFI");
    }
});
