#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if data.is_empty() { return; }
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 1_000);
        if term.is_null() { return; }
        blackbird_core::bb_term_input(term, data.as_ptr(), data.len());
        // Also take a snapshot + release to exercise the snapshot path
        // with whatever state the input left.
        let snap = blackbird_core::bb_term_take_snapshot(term);
        if !snap.is_null() {
            blackbird_core::bb_snap_release(snap);
        }
        blackbird_core::bb_term_free(term);
    }
});
