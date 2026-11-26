#![no_main]

use libfuzzer_sys::fuzz_target;
use std::sync::atomic::{AtomicBool, Ordering};

// `guard_with_term` routes every caught panic to a `BBEventKind::Fatal` event: without a
// registered callback the fuzzer's oracle is blind to them.
static SAW_FATAL: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn on_event(ev: blackbird_core::BBEvent, _ctx: *mut std::ffi::c_void) {
    if ev.kind == blackbird_core::BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
}

/// Wraps modulo `data.len()`. Requires `!data.is_empty()`.
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

        // Byte 0 sets the chunk count (1..=8): fragmenting the feed reaches the cross-call
        // latches (`osc_possibly_pending`, `in_xtgettcap`) that a single feed never exercises.
        let chunk_policy = data[0];
        let payload_end = data.len().saturating_sub(16);
        let payload = &data[1..payload_end.max(1)];
        let sub_chunks = ((chunk_policy % 8) + 1) as usize;
        let chunk_len = payload.len().div_ceil(sub_chunks).max(1);

        let mid_snap_at_chunk = if sub_chunks > 1 {
            (chunk_policy as usize) % sub_chunks
        } else {
            usize::MAX
        };

        for (i, chunk) in payload.chunks(chunk_len).enumerate() {
            if !chunk.is_empty() {
                blackbird_core::bb_term_input(term, chunk.as_ptr(), chunk.len());
            }
            if i == mid_snap_at_chunk {
                let s = blackbird_core::bb_term_take_snapshot(term);
                if !s.is_null() {
                    blackbird_core::bb_snap_release(s);
                }
            }
        }

        let color_query_byte = data[data.len() - 1];
        blackbird_core::bb_term_set_color_query_enabled(term, color_query_byte & 1);

        let _ = blackbird_core::bb_term_current_mode(term);

        let snap = blackbird_core::bb_term_take_snapshot(term);
        if !snap.is_null() {
            let retain_count = (idx_at(data, 2) & 0x07) as usize;
            let mut retained: [*const blackbird_core::BBSnap; 8] =
                [std::ptr::null(); 8];
            for entry in retained.iter_mut().take(retain_count) {
                *entry = blackbird_core::bb_snap_retain(snap);
            }

            let _ = blackbird_core::bb_snap_damage_is_full(snap);
            let mut dbuf = [0u16; 256];
            let _ = blackbird_core::bb_snap_damage_rows(snap, dbuf.as_mut_ptr(), dbuf.len());
            let _ = blackbird_core::bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);

            let row = u16::from_le_bytes([idx_at(data, 3), idx_at(data, 4)]);
            let col = u16::from_le_bytes([idx_at(data, 5), idx_at(data, 6)]);
            let link_id = blackbird_core::bb_snap_link_id_at(snap, row, col);
            let _ = blackbird_core::bb_snap_link_url(snap, link_id);
            let fake_id = u32::from_le_bytes([
                idx_at(data, 7),
                idx_at(data, 8),
                idx_at(data, 9),
                idx_at(data, 10),
            ]);
            let _ = blackbird_core::bb_snap_link_url(snap, fake_id);

            for entry in retained.iter().take(retain_count) {
                if !entry.is_null() {
                    blackbird_core::bb_snap_release(*entry);
                }
            }
            blackbird_core::bb_snap_release(snap);
        }

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

        let delta = i32::from_le_bytes([
            idx_at(data, 24),
            idx_at(data, 25),
            idx_at(data, 26),
            idx_at(data, 27),
        ]);
        blackbird_core::bb_term_scroll(term, delta);
        blackbird_core::bb_term_scroll_to_bottom(term);

        // Full u16 dims, not `.max(1)`: zero is the documented no-op the clamp path handles.
        let cols = u16::from_le_bytes([idx_at(data, 28), idx_at(data, 29)]);
        let rows = u16::from_le_bytes([idx_at(data, 30), idx_at(data, 31)]);
        blackbird_core::bb_term_resize(term, cols, rows);

        let slot = u16::from_le_bytes([idx_at(data, 32), idx_at(data, 33)]);
        let rgb = u32::from_le_bytes([
            idx_at(data, 34),
            idx_at(data, 35),
            idx_at(data, 36),
            idx_at(data, 37),
        ]);
        blackbird_core::bb_term_set_named_color(term, slot, rgb);

        blackbird_core::bb_term_clear_all(term);

        blackbird_core::bb_term_free(term);
    }

    if SAW_FATAL.swap(false, Ordering::SeqCst) {
        panic!("blackbird_core routed a BBEventKind::Fatal — panic inside a guarded FFI");
    }
});
