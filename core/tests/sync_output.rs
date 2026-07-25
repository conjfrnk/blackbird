//! Pins DEC mode 2026 synchronized-output handling. vte 0.15 implements
//! sync natively: between `\x1b[?2026h` (BSU) and `\x1b[?2026l` (ESU), the
//! parser buffers bytes up to 2 MiB and replays them in one burst when ESU
//! arrives (or the 2 MiB cap fires).
//!
//! This file pins that the final post-ESU grid is correct and that the sync
//! mechanism survives fragmented `bb_term_input` calls. Deliberately scoped
//! to the happy path: it drives only `bb_term_input` + `bb_term_take_snapshot`,
//! both of which are byte-identical to their pre-watchdog behaviour, so these
//! tests stay immune even on a CI box that stalls past the 150 ms deadline
//! between a feed and its snapshot.
//!
//! The 150 ms deadline is NOT self-enforcing — vte only consults it when more
//! bytes arrive, so an unterminated BSU used to freeze the tab outright. The
//! FFI now DOES expose sync state (`bb_term_sync_status` /
//! `bb_term_flush_sync_update`) so the session can abort a stalled update;
//! that surface and its expiry semantics are pinned in
//! `core/tests/sync_update_timeout.rs`.

use blackbird_core::*;

unsafe fn feed_all(term: *mut BBTerm, chunks: &[&[u8]]) {
    for chunk in chunks {
        bb_term_input(term, chunk.as_ptr(), chunk.len());
    }
}

fn read_chars(snap: *const BBSnap, row: u16) -> String {
    unsafe {
        let s = &*snap;
        let start = (row as usize) * (s.cols as usize);
        let mut out = String::new();
        for i in 0..(s.cols as usize) {
            let cell = *s.cells.add(start + i);
            if let Some(c) = char::from_u32(cell.ch) {
                if cell.ch == 0 {
                    out.push(' ');
                } else {
                    out.push(c);
                }
            }
        }
        out
    }
}

#[test]
fn complete_sync_region_lands_atomically() {
    // A BSU / write / ESU all in one feed should produce the post-ESU grid
    // exactly. Historically alacritty/vte have had bugs where the first
    // byte after ESU got duplicated; pin the expected shape so any such
    // regression in a future crate bump fails here.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        let seq = b"\x1b[?2026h\x1b[2JHELLO\x1b[?2026l";
        feed_all(term, &[seq]);
        let snap = bb_term_take_snapshot(term);
        let row0 = read_chars(snap, 0);
        assert!(
            row0.starts_with("HELLO"),
            "expected HELLO prefix, got {row0:?}"
        );
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn sync_survives_fragment_across_feed_calls() {
    // BSU in one feed, content in a second, ESU in a third. The parser's
    // sync buffer persists across calls; the whole region should land
    // atomically on ESU.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        feed_all(term, &[b"\x1b[?2026h", b"ABC", b"\x1b[?2026l"]);
        let snap = bb_term_take_snapshot(term);
        let row0 = read_chars(snap, 0);
        assert!(row0.starts_with("ABC"), "expected ABC prefix, got {row0:?}");
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn sync_region_buffers_bytes_until_esu() {
    // Regression for rust-tests F6 (renamed from `snapshot_taken_mid_sync_is_stable`
    // — the original name implied a concurrency invariant, but snapshots are
    // synchronous and called from the same thread that drives input, so
    // there's no race to test against. What this test actually pins is the
    // sync buffering contract: bytes sent between BSU (`\x1b[?2026h`) and
    // ESU (`\x1b[?2026l`) must not land in the grid until ESU arrives).
    unsafe {
        let term = bb_term_new(10, 1, 100);
        // Prime the grid so we can detect a partial write.
        bb_term_input(term, b"XY".as_ptr(), 2);
        // Enter sync and buffer some content, but don't close sync.
        bb_term_input(term, b"\x1b[?2026hZZZZZ".as_ptr(), 13);
        let snap = bb_term_take_snapshot(term);
        let row0 = read_chars(snap, 0);
        // We should see "XY" (and spaces), NOT "XYZZZ" — the sync bytes
        // haven't landed yet because ESU hasn't arrived.
        assert!(row0.starts_with("XY"), "expected XY prefix, got {row0:?}");
        assert!(
            !row0.contains("ZZZZZ"),
            "sync bytes leaked pre-ESU: {row0:?}"
        );
        bb_snap_release(snap);
        bb_term_free(term);
    }
}
