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

/// Derive an index into `data` that wraps modulo `data.len()`. Returns a
/// usize so callers can index directly. Requires `!data.is_empty()`.
#[inline]
fn idx_at(data: &[u8], at: usize) -> u8 {
    data[at % data.len()]
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

        // Rust-fuzz F4 fix: fragment the input across multiple
        // `bb_term_input` calls instead of one monolithic call, and
        // take a snapshot MID-FEED (not only after all bytes have been
        // consumed). This reaches the cross-call latches
        // (`osc_possibly_pending`, `in_xtgettcap`) that a single feed
        // never exercises. The chunk sizing is driven by fuzzer bytes
        // so libFuzzer's coverage feedback can discover interesting
        // splits (ESC / OSC boundary mid-chunk, XTGETTCAP payload
        // fragmented, etc.).
        //
        // Byte budget: we spend the first byte on chunk-size policy
        // and the last two on resize dims; the middle bytes are the
        // parser payload. Sub-feed count is capped at 8 so libFuzzer's
        // per-iter work stays bounded.
        let chunk_policy = data[0];
        let payload_end = data.len().saturating_sub(16);
        let payload = &data[1..payload_end.max(1)];
        // Number of chunks derived from the policy byte, 1..=8.
        let sub_chunks = ((chunk_policy % 8) + 1) as usize;
        let chunk_len = payload.len().div_ceil(sub_chunks).max(1);

        // Snapshot mid-feed — specifically between the first and second
        // fragment. Pins the "snapshot during parser state carry-over"
        // path that single-feed harnesses never reach.
        let mid_snap_at_chunk = if sub_chunks > 1 {
            (chunk_policy as usize) % sub_chunks
        } else {
            usize::MAX // sentinel — no mid snapshot
        };

        for (i, chunk) in payload.chunks(chunk_len).enumerate() {
            if !chunk.is_empty() {
                blackbird_core::bb_term_input(term, chunk.as_ptr(), chunk.len());
            }
            if i == mid_snap_at_chunk {
                // Mid-feed snapshot — do not release links/damage paths
                // here, just acquire+release to pin the lifetime under
                // parser carry-over (F4 + F3 combination).
                let s = blackbird_core::bb_term_take_snapshot(term);
                if !s.is_null() {
                    blackbird_core::bb_snap_release(s);
                }
            }
        }

        // Rust-fuzz F2: toggle the query-mode flag from an INDEPENDENT
        // derivation (last byte of payload) rather than data[0] which
        // already drives chunking. Gives libFuzzer a distinct knob.
        let color_query_byte = data[data.len() - 1];
        blackbird_core::bb_term_set_color_query_enabled(term, color_query_byte & 1);

        // Read current-mode bits so the getter's guard sees arbitrary post-
        // input state.
        let _ = blackbird_core::bb_term_current_mode(term);

        // Snapshot + per-snapshot FFI coverage (rust-fuzz F3).
        let snap = blackbird_core::bb_term_take_snapshot(term);
        if !snap.is_null() {
            // Retain/release refcount balance — retain N times, release
            // N+1 times so rc arithmetic gets pushed through non-trivial
            // counts. N capped at 8 to keep per-iter work bounded.
            let retain_count = (idx_at(data, 2) & 0x07) as usize;
            let mut retained: [*const blackbird_core::BBSnap; 8] =
                [std::ptr::null(); 8];
            for entry in retained.iter_mut().take(retain_count) {
                *entry = blackbird_core::bb_snap_retain(snap);
            }

            let _ = blackbird_core::bb_snap_damage_is_full(snap);
            let mut dbuf = [0u16; 256];
            let _ = blackbird_core::bb_snap_damage_rows(snap, dbuf.as_mut_ptr(), dbuf.len());
            // Also exercise the length-probe path (null out buffer).
            let _ = blackbird_core::bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);

            // Link accessors with coordinates derived from dedicated
            // bytes (rows/cols at indices 3 and 4 now, not the same
            // bytes that drive resize/color/scroll).
            let row = u16::from_le_bytes([idx_at(data, 3), idx_at(data, 4)]);
            let col = u16::from_le_bytes([idx_at(data, 5), idx_at(data, 6)]);
            let link_id = blackbird_core::bb_snap_link_id_at(snap, row, col);
            let _ = blackbird_core::bb_snap_link_url(snap, link_id);
            // Also probe a FAKE link_id (even if not in the snapshot) to
            // push the bounds-check path in bb_snap_link_url.
            let fake_id = u32::from_le_bytes([
                idx_at(data, 7),
                idx_at(data, 8),
                idx_at(data, 9),
                idx_at(data, 10),
            ]);
            let _ = blackbird_core::bb_snap_link_url(snap, fake_id);

            // Release the retained snapshots first, then the original.
            for entry in retained.iter().take(retain_count) {
                if !entry.is_null() {
                    blackbird_core::bb_snap_release(*entry);
                }
            }
            blackbird_core::bb_snap_release(snap);
        }

        // Exercise text_range with INDEPENDENT derivation — bytes 11..=22
        // (different from the parser payload / chunking policy / resize
        // dims). Avoids the F4 "every downstream call keys off the same
        // 4-byte prefix" collision.
        if data.len() >= 24 {
            let s_line = i32::from_le_bytes([
                idx_at(data, 11),
                idx_at(data, 12),
                idx_at(data, 13),
                idx_at(data, 14),
            ]);
            let e_line = i32::from_le_bytes([
                idx_at(data, 15),
                idx_at(data, 16),
                idx_at(data, 17),
                idx_at(data, 18),
            ]);
            let s_col = u16::from_le_bytes([idx_at(data, 19), idx_at(data, 20)]);
            let e_col = u16::from_le_bytes([idx_at(data, 21), idx_at(data, 22)]);
            let rect = idx_at(data, 23) & 1;
            let s = blackbird_core::bb_term_text_range(term, s_line, s_col, e_line, e_col, rect);
            if !s.is_null() {
                blackbird_core::bb_string_release(s);
            }
        }

        // Scroll with its OWN dedicated bytes — again distinct from all
        // the above.
        let delta = i32::from_le_bytes([
            idx_at(data, 24),
            idx_at(data, 25),
            idx_at(data, 26),
            idx_at(data, 27),
        ]);
        blackbird_core::bb_term_scroll(term, delta);
        blackbird_core::bb_term_scroll_to_bottom(term);

        // Resize — F9 fix: read cols/rows as FULL u16 (2 bytes each) so
        // the fuzzer can reach MAX_DIM=1000 and zero-dim early-return
        // paths. Not .max(1) — let the clamp do its job; zero is the
        // documented no-op that the clamp path explicitly handles.
        let cols = u16::from_le_bytes([idx_at(data, 28), idx_at(data, 29)]);
        let rows = u16::from_le_bytes([idx_at(data, 30), idx_at(data, 31)]);
        blackbird_core::bb_term_resize(term, cols, rows);

        // Palette setter — slot/rgb from DIFFERENT bytes so libFuzzer
        // isn't forced to co-discover them with the parser payload.
        let slot = u16::from_le_bytes([idx_at(data, 32), idx_at(data, 33)]);
        let rgb = u32::from_le_bytes([
            idx_at(data, 34),
            idx_at(data, 35),
            idx_at(data, 36),
            idx_at(data, 37),
        ]);
        blackbird_core::bb_term_set_named_color(term, slot, rgb);

        // And clear_all after all the above.
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
