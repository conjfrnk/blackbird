#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if data.is_empty() {
        return;
    }
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 1_000);
        if term.is_null() {
            return;
        }
        blackbird_core::bb_term_input(term, data.as_ptr(), data.len());

        // Snapshot path.
        let snap = blackbird_core::bb_term_take_snapshot(term);
        if !snap.is_null() {
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
});
