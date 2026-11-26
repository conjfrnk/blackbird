#![no_main]

use libfuzzer_sys::fuzz_target;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

// A caught panic in `guard_with_term` only surfaces as a `BBEventKind::Fatal` event: without a
// registered callback the fuzzer's oracle is blind to it.
static SAW_FATAL: AtomicBool = AtomicBool::new(false);

static PTY_WRITE_BYTES: AtomicUsize = AtomicUsize::new(0);

unsafe extern "C" fn on_event(ev: blackbird_core::BBEvent, _ctx: *mut std::ffi::c_void) {
    if ev.kind == blackbird_core::BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
    if ev.kind == blackbird_core::BBEventKind::PtyWrite && ev.len > 0 && !ev.payload.is_null() {
        PTY_WRITE_BYTES.fetch_add(ev.len, Ordering::Relaxed);
    }
}

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
    b"\x1bP+q5858\x1b\\",       // XTGETTCAP — "XX" cap, unknown branch
    b"\x1b[?9001$p",            // DECRQM private mode 9001
    b"\x1b[8t",                 // XTWINOPS sub-op 8
];

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
    if data.is_empty() {
        return;
    }
    SAW_FATAL.store(false, Ordering::SeqCst);
    PTY_WRITE_BYTES.store(0, Ordering::Relaxed);

    // Byte 0: number of replies to send (0..=64). Byte 1 LSB: initial color-query-enabled state.
    // Pair stream starts at byte 2.
    let reply_count = (data[0] % 65) as usize;

    let initial_color_flag: u8 = if data.len() >= 2 { data[1] & 1 } else { 0 };

    let pairs: &[u8] = if data.len() > 2 { &data[2..] } else { &[] };

    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 1_000);
        if term.is_null() {
            return;
        }
        blackbird_core::bb_term_set_event_cb(term, Some(on_event), std::ptr::null_mut());
        blackbird_core::bb_term_set_color_query_enabled(term, initial_color_flag);

        blackbird_core::bb_term_input(term, PREFEED_SEED.as_ptr(), PREFEED_SEED.len());

        let mut color_flag: u8 = initial_color_flag;

        // Pair byte: bit 7 toggles color_query_enabled, the low 7 bits pick the fragment.
        for i in 0..reply_count {
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

            if i.is_multiple_of(8) {
                let s = blackbird_core::bb_term_take_snapshot(term);
                if !s.is_null() {
                    blackbird_core::bb_snap_release(s);
                }
            }
        }

        let s = blackbird_core::bb_term_take_snapshot(term);
        if !s.is_null() {
            blackbird_core::bb_snap_release(s);
        }

        blackbird_core::bb_term_free(term);
    }

    // Read back so the accumulating fetch_add in the callback can't be dead-code-eliminated.
    let _drained = PTY_WRITE_BYTES.load(Ordering::Relaxed);

    if SAW_FATAL.swap(false, Ordering::SeqCst) {
        panic!("blackbird_core routed a BBEventKind::Fatal — panic inside a guarded FFI");
    }
});
