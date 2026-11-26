#![no_main]

use libfuzzer_sys::fuzz_target;
use std::sync::atomic::{AtomicBool, Ordering};

// Focused target for `bb_term_text_range`: a stable corpus is pre-fed once and the
// fuzzer-controlled bytes drive ONLY the coord space.

static SAW_FATAL: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn on_event(ev: blackbird_core::BBEvent, _ctx: *mut std::ffi::c_void) {
    if ev.kind == blackbird_core::BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
}

const PREFED_BLOCK: &[u8] = concat!(
    "\x1b[1;31mhello \x1b[32mworld \x1b[0m",
    "\x1b]8;id=1;https://example.com\x1b\\link-text\x1b]8;;\x1b\\",
    "\x1b]8;id=2;https://blackbird-terminal.com/docs/text-range\x1b\\docs\x1b]8;;\x1b\\",
    "中文测试 ",
    "👨‍💻🚀 ",
    "\x1b[?1049hON-ALT\r\n\x1b[?1049l",
    "\r\nA\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH\r\nI\r\nJ\r\n",
)
.as_bytes();

const MAX_TEXT_RANGE_CALLS_PER_ITER: usize = 64;

/// Tuple: s_line (i32 LE), e_line (i32 LE), s_col (u16 LE), e_col (u16 LE), rect (low bit only).
const TUPLE_STRIDE: usize = 13;

fuzz_target!(|data: &[u8]| {
    if data.is_empty() {
        return;
    }
    if data.len() < TUPLE_STRIDE {
        return;
    }

    SAW_FATAL.store(false, Ordering::SeqCst);
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 1_000);
        if term.is_null() {
            return;
        }
        // Register the Fatal oracle BEFORE feeding so a panic during pre-feed gets latched.
        blackbird_core::bb_term_set_event_cb(term, Some(on_event), std::ptr::null_mut());

        let mut prefed: Vec<u8> = Vec::with_capacity(4096);
        while prefed.len() + PREFED_BLOCK.len() <= 4096 {
            prefed.extend_from_slice(PREFED_BLOCK);
        }
        if prefed.len() < 4096 {
            let remaining = 4096 - prefed.len();
            prefed.extend_from_slice(&PREFED_BLOCK[..remaining.min(PREFED_BLOCK.len())]);
        }
        blackbird_core::bb_term_input(term, prefed.as_ptr(), prefed.len());

        let snap0 = blackbird_core::bb_term_take_snapshot(term);
        if !snap0.is_null() {
            blackbird_core::bb_snap_release(snap0);
        }

        let tuple_count = (data.len() / TUPLE_STRIDE).min(MAX_TEXT_RANGE_CALLS_PER_ITER);

        for i in 0..tuple_count {
            let off = i * TUPLE_STRIDE;
            let s_line = i32::from_le_bytes([
                data[off],
                data[off + 1],
                data[off + 2],
                data[off + 3],
            ]);
            let e_line = i32::from_le_bytes([
                data[off + 4],
                data[off + 5],
                data[off + 6],
                data[off + 7],
            ]);
            let s_col = u16::from_le_bytes([data[off + 8], data[off + 9]]);
            let e_col = u16::from_le_bytes([data[off + 10], data[off + 11]]);
            let rect = data[off + 12] & 1;

            // Every 8th iter, resize with dims from the NEXT tuple's bytes: coupling them to the
            // current tuple would tie coord coverage to resize coverage.
            if i % 8 == 7 {
                let next_off = off + TUPLE_STRIDE;
                if data.len() >= next_off + 4 {
                    let rcols =
                        u16::from_le_bytes([data[next_off], data[next_off + 1]]);
                    let rrows = u16::from_le_bytes([
                        data[next_off + 2],
                        data[next_off + 3],
                    ]);
                    blackbird_core::bb_term_resize(term, rcols, rrows);
                }
            }

            let s = blackbird_core::bb_term_text_range(term, s_line, s_col, e_line, e_col, rect);
            if !s.is_null() {
                blackbird_core::bb_string_release(s);
            }

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
