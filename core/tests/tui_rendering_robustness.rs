//! Round 2 fragmentation hunt — sister to `csi_fragmentation_repro.rs`.
//!
//! Connor reports MORE Claude Code-class rendering glitches in the wild
//! after the ED-all-injection fix landed in commit 6fdd331. This file
//! probes every parser surface a TUI typically touches under the same
//! "split the byte stream at every conceivable boundary and verify
//! state survives" methodology that surfaced the original bug.
//!
//! Surfaces covered:
//!   1. OSC 8 hyperlink fragmentation (URL split mid-byte; ST split;
//!      BEL terminator vs ST terminator).
//!   2. OSC 7 cwd payload split mid-byte.
//!   3. OSC 0 / OSC 2 title-set fragmentation (we DO surface a Title
//!      event via alacritty's EventListener — pin that fragmentation
//!      doesn't lose the event).
//!   4. DCS sequences other than XTGETTCAP (Sixel, ReGIS, iTerm2
//!      conductor) under fragmentation must stay inert.
//!   5. SGR fragmentation: `\x1b[31;1;4m` split at every byte boundary
//!      must produce a cell with FG red + BOLD + UNDERLINE bits set.
//!   6. DECSC / DECRC (`\x1b7` / `\x1b8`) save/restore split across
//!      chunks.
//!   7. Mode set/reset (`\x1b[?25l` show-cursor) split mid-digit,
//!      mid-`?`, and at the final byte.
//!   8. Bracketed paste (`\x1b[?2004h/l`) under fragmentation.
//!   9. Application keypad / cursor keys (DECCKM `\x1b[?1h/l`,
//!      DECKPAM/DECKPNM `\x1b=` / `\x1b>`).
//!  10. Scroll region (DECSTBM `\x1b[5;20r`) under fragmentation.
//!  11. CHA (Cursor Horizontal Absolute, `\x1b[<col>G`) — used heavily
//!      by ratatui spinners — under fragmentation.
//!  12. Save-cursor + ED-all-injection interaction: now that we inject
//!      `\x1b[3J` mid-chunk, does it clobber a saved cursor / SGR
//!      state set up before the 2J?
//!  13. Modify-other-keys negotiation under fragmentation (sister to
//!      the existing `modify_other_keys.rs::split_chunk_delivery`,
//!      but exhaustive).
//!
//! Pre-flight memory budget per test: at most one 80×24 BBTerm
//! (~120 KiB), one snapshot, no spawned threads, no I/O. Largest
//! exhaustive split test fans out ~30 shapes × ~120 KiB = ~3.6 MiB peak.
//! Total wallclock target: <1 s (the whole file). All tests deterministic.

use std::ffi::CStr;
use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

// ---------------------------------------------------------------------------
// Shared helpers — variants from the sister file, kept self-contained so
// this test target is independent of the rest of the suite.
// ---------------------------------------------------------------------------

#[derive(Default)]
struct Captured {
    events: Vec<u32>,
    titles: Vec<String>,
    pty_writes: Vec<Vec<u8>>,
    cwds: Vec<String>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    let cap = unsafe { &*(ctx as *const Mutex<Captured>) };
    let mut guard = cap.lock().unwrap();
    guard.events.push(ev.kind as u32);
    if !ev.payload.is_null() && ev.len > 0 {
        let bytes = unsafe { std::slice::from_raw_parts(ev.payload, ev.len) };
        match ev.kind {
            bc::BBEventKind::Title => {
                if let Ok(s) = std::str::from_utf8(bytes) {
                    guard.titles.push(s.to_string());
                }
            }
            bc::BBEventKind::PtyWrite => {
                guard.pty_writes.push(bytes.to_vec());
            }
            bc::BBEventKind::CwdChanged => {
                if let Ok(s) = std::str::from_utf8(bytes) {
                    guard.cwds.push(s.to_string());
                }
            }
            _ => {}
        }
    }
}

/// Drive a fresh 80×24 term through the chunk vector with capture.
unsafe fn drive_chunks(chunks: &[&[u8]]) -> Captured {
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;
    let term = bc::bb_term_new(80, 24, 100);
    bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
    for c in chunks {
        bc::bb_term_input(term, c.as_ptr(), c.len());
    }
    bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
    bc::bb_term_free(term);
    drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
    let g = cap.lock().unwrap();
    Captured {
        events: g.events.clone(),
        titles: g.titles.clone(),
        pty_writes: g.pty_writes.clone(),
        cwds: g.cwds.clone(),
    }
}

/// Read row 0 visible text via `bb_term_text_range` for a fresh term that
/// already had `bytes` driven through it. The term is freed before return.
unsafe fn row0_text(bytes: &[u8]) -> String {
    let term = bc::bb_term_new(80, 24, 100);
    bc::bb_term_input(term, bytes.as_ptr(), bytes.len());
    let raw = bc::bb_term_text_range(term, 0, 0, 0, 79, 0);
    let out = if raw.is_null() {
        String::new()
    } else {
        let slice = std::slice::from_raw_parts((*raw).bytes, (*raw).len);
        let s = std::str::from_utf8(slice).unwrap_or("").to_string();
        bc::bb_string_release(raw);
        s
    };
    bc::bb_term_free(term);
    out
}

/// Snapshot helper: cell at (col, row).
unsafe fn cell_at_after(chunks: &[&[u8]], col: u16, row: u16) -> bc::BBCell {
    let term = bc::bb_term_new(80, 24, 100);
    for c in chunks {
        bc::bb_term_input(term, c.as_ptr(), c.len());
    }
    let snap = bc::bb_term_take_snapshot(term);
    let cols = (*snap).cols;
    let idx = (row as usize) * (cols as usize) + col as usize;
    let cell = *((*snap).cells.add(idx));
    bc::bb_snap_release(snap);
    bc::bb_term_free(term);
    cell
}

/// Read mode bitfield after feeding `chunks`.
unsafe fn mode_after(chunks: &[&[u8]]) -> u32 {
    let term = bc::bb_term_new(80, 24, 100);
    for c in chunks {
        bc::bb_term_input(term, c.as_ptr(), c.len());
    }
    let m = bc::bb_term_current_mode(term);
    bc::bb_term_free(term);
    m
}

/// Resolve OSC 8 link URL for cell after feeding `chunks`.
unsafe fn link_url_at(chunks: &[&[u8]], col: u16, row: u16) -> Option<String> {
    let term = bc::bb_term_new(80, 24, 100);
    for c in chunks {
        bc::bb_term_input(term, c.as_ptr(), c.len());
    }
    let snap = bc::bb_term_take_snapshot(term);
    let id = bc::bb_snap_link_id_at(snap, row, col);
    let out = if id == 0 {
        None
    } else {
        let p = bc::bb_snap_link_url(snap, id);
        if p.is_null() {
            None
        } else {
            Some(CStr::from_ptr(p as *const _).to_string_lossy().into_owned())
        }
    };
    bc::bb_snap_release(snap);
    bc::bb_term_free(term);
    out
}

/// All `2..=k`-way contiguous splits of `bytes` for k as given. Returns a
/// vector of chunk-vectors. Used by the byte-by-byte exhaustion tests.
fn all_two_way_splits(bytes: &[u8]) -> Vec<Vec<&[u8]>> {
    (1..bytes.len())
        .map(|i| {
            let (a, b) = bytes.split_at(i);
            vec![a, b]
        })
        .collect()
}

// ===========================================================================
// SGR fragmentation
// ===========================================================================

#[test]
fn sgr_split_at_every_byte_yields_correct_attrs() {
    // pre-flight: ~120 KiB term × ~14 splits × ephemeral; ~50 ms.
    //
    // `\x1b[31;1;4mX` → red FG, BOLD, UNDERLINE on 'X'. We split this
    // sequence at every internal byte boundary and assert the cell at
    // (0, 0) is 'X' with the correct flags. A regression where parser
    // state didn't survive the chunk boundary would either lose attrs
    // (bare 'X') or leak the digits onto the grid.
    let payload = b"\x1b[31;1;4mX";
    for split in 1..payload.len() {
        let (a, b) = payload.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let cell = cell_at_after(&chunks, 0, 0);
            assert_eq!(
                cell.ch, b'X' as u32,
                "SGR split at {split}: cell at (0,0) must be 'X'; got ch={:#x}",
                cell.ch
            );
            assert!(
                cell.flags & bc::cell_flags::BOLD != 0,
                "SGR split at {split}: BOLD bit must be set on 'X'; flags={:#x}",
                cell.flags
            );
            assert!(
                cell.flags & bc::cell_flags::UNDERLINE != 0,
                "SGR split at {split}: UNDERLINE bit must be set on 'X'; flags={:#x}",
                cell.flags
            );
        }
    }
}

#[test]
fn sgr_byte_by_byte_has_same_state_as_single_shot() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // Compare two terminals: one fed `\x1b[31;1;4mABC` in one call,
    // the other byte-by-byte. Their final cell flags+ch must agree at
    // (0,0)…(2,0).
    let payload = b"\x1b[31;1;4mABC";
    unsafe {
        let term_a = bc::bb_term_new(80, 24, 100);
        bc::bb_term_input(term_a, payload.as_ptr(), payload.len());
        let snap_a = bc::bb_term_take_snapshot(term_a);

        let term_b = bc::bb_term_new(80, 24, 100);
        for byte in payload {
            bc::bb_term_input(term_b, std::ptr::from_ref(byte), 1);
        }
        let snap_b = bc::bb_term_take_snapshot(term_b);

        for c in 0..3u16 {
            let idx = c as usize;
            let ca = *((*snap_a).cells.add(idx));
            let cb = *((*snap_b).cells.add(idx));
            assert_eq!(
                ca.ch, cb.ch,
                "ch differs at col {c} between single-shot and byte-by-byte"
            );
            assert_eq!(
                ca.flags, cb.flags,
                "flags differ at col {c}: single={:#x} byte-by-byte={:#x}",
                ca.flags, cb.flags
            );
            assert_eq!(
                ca.fg, cb.fg,
                "fg differs at col {c}: single={:#x} byte-by-byte={:#x}",
                ca.fg, cb.fg
            );
        }

        bc::bb_snap_release(snap_a);
        bc::bb_snap_release(snap_b);
        bc::bb_term_free(term_a);
        bc::bb_term_free(term_b);
    }
}

// ===========================================================================
// OSC 8 hyperlink fragmentation
// ===========================================================================

#[test]
fn osc8_split_inside_url_keeps_attribution() {
    // pre-flight: ~120 KiB × ~30 splits, ~30 ms.
    //
    // OSC 8 `\x1b]8;;URL\x1b\\TEXT\x1b]8;;\x1b\\` split at every
    // internal byte. The visible cell at (0,0) must carry an attribution
    // resolving to URL.
    let url = "https://example.com/foo";
    let payload = format!("\x1b]8;;{}\x1b\\TEXT\x1b]8;;\x1b\\", url);
    let bytes = payload.as_bytes();
    for split in 1..bytes.len() {
        let (a, b) = bytes.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let got = link_url_at(&chunks, 0, 0);
            assert_eq!(
                got.as_deref(),
                Some(url),
                "OSC 8 split at {split}: cell (0,0) must resolve to {url:?}, got {got:?}"
            );
        }
    }
}

#[test]
fn osc8_st_split_across_chunks_does_not_eat_text() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // The ST terminator is `\x1b\\` — two bytes. If the chunk boundary
    // lands BETWEEN the ESC and the backslash, alacritty's vte parser
    // must hold the OSC open and complete on the second byte, not eat
    // the next chunk's bytes as OSC payload.
    let chunks_a: &[&[u8]] = &[b"\x1b]8;;https://a.example/\x1b", b"\\HELLO\x1b]8;;\x1b\\"];
    unsafe {
        let txt = {
            let term = bc::bb_term_new(80, 24, 100);
            for c in chunks_a {
                bc::bb_term_input(term, c.as_ptr(), c.len());
            }
            let raw = bc::bb_term_text_range(term, 0, 0, 0, 79, 0);
            let slice = std::slice::from_raw_parts((*raw).bytes, (*raw).len);
            let out = std::str::from_utf8(slice).unwrap_or("").to_string();
            bc::bb_string_release(raw);
            bc::bb_term_free(term);
            out
        };
        assert!(
            txt.contains("HELLO"),
            "OSC 8 ST split mid-terminator must not eat 'HELLO': row text {txt:?}"
        );
        let url = link_url_at(chunks_a, 0, 0);
        assert_eq!(
            url.as_deref(),
            Some("https://a.example/"),
            "OSC 8 with ST split must still attribute the URL on (0,0)"
        );
    }
}

#[test]
fn osc8_bel_terminator_in_separate_chunk() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // BEL (0x07) is a one-byte alternative to ST. The terminator can
    // arrive in a separate chunk. Pin: the OSC 8 closes on BEL even
    // when the URL prefix and BEL are in different chunks.
    let chunks: &[&[u8]] = &[b"\x1b]8;;https://b.example/", b"\x07HI\x1b]8;;\x07"];
    unsafe {
        let url = link_url_at(chunks, 0, 0);
        assert_eq!(
            url.as_deref(),
            Some("https://b.example/"),
            "OSC 8 with BEL split into separate chunk must still attribute"
        );
        // 'H' must land at (0, 0).
        let cell = cell_at_after(chunks, 0, 0);
        assert_eq!(
            cell.ch, b'H' as u32,
            "BEL-terminated OSC 8 must not eat the following 'H'"
        );
    }
}

// ===========================================================================
// OSC 7 cwd fragmentation
// ===========================================================================

#[test]
fn osc7_payload_split_mid_byte_still_emits_cwd_event() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // OSC 7 `\x1b]7;file:///tmp/x\x1b\\` split mid-byte must still
    // surface a CwdChanged event with the decoded path "/tmp/x".
    let payload = b"\x1b]7;file:///tmp/x\x1b\\";
    for split in 1..payload.len() {
        let (a, b) = payload.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let cap = drive_chunks(&chunks);
            let any_cwd = cap.cwds.iter().any(|s| s == "/tmp/x");
            assert!(
                any_cwd,
                "OSC 7 split at {split}: must emit CwdChanged for '/tmp/x'; got {:?}",
                cap.cwds
            );
        }
    }
}

// ===========================================================================
// OSC 0 / OSC 2 title-set fragmentation
// ===========================================================================

#[test]
fn osc2_title_split_across_chunks_still_fires_event() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // alacritty surfaces `\x1b]0;TITLE\x07` and `\x1b]2;TITLE\x07` as
    // an `Event::Title` which our RoutingListener forwards as a
    // `BBEventKind::Title`. Verify the event survives every split.
    let payload = b"\x1b]2;hello-title\x07";
    for split in 1..payload.len() {
        let (a, b) = payload.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let cap = drive_chunks(&chunks);
            let any_title = cap.titles.iter().any(|s| s == "hello-title");
            assert!(
                any_title,
                "OSC 2 split at {split}: must emit Title event 'hello-title'; got {:?}",
                cap.titles
            );
        }
    }
}

#[test]
fn osc0_title_byte_by_byte_still_fires_event() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // OSC 0 sets both icon name and title in xterm; alacritty maps it
    // to Title. Drive the bytes one at a time.
    let payload = b"\x1b]0;icon-and-title\x07";
    let chunks: Vec<&[u8]> = payload.iter().map(std::slice::from_ref).collect();
    unsafe {
        let cap = drive_chunks(&chunks);
        let any_title = cap.titles.iter().any(|s| s == "icon-and-title");
        assert!(
            any_title,
            "OSC 0 byte-by-byte must emit Title event; got {:?}",
            cap.titles
        );
    }
}

// ===========================================================================
// DCS handling — non-XTGETTCAP DCSes must stay inert
// ===========================================================================

#[test]
fn sixel_dcs_byte_by_byte_does_not_leak_or_emit() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // Sixel: `\x1bPq#0;2;0;0;0~~~\x1b\\`. Drive byte-by-byte. Must
    // produce ZERO events and leave the grid empty for row 0; a
    // following 'Z' must land at (0,0) cleanly.
    let payload = b"\x1bPq#0;2;0;0;0~~~\x1b\\Z";
    let chunks: Vec<&[u8]> = payload.iter().map(std::slice::from_ref).collect();
    unsafe {
        let cap = drive_chunks(&chunks);
        assert!(
            cap.events.is_empty(),
            "Sixel byte-by-byte must produce no events; got {:?}",
            cap.events
        );
        let cell = cell_at_after(&chunks, 0, 0);
        assert_eq!(
            cell.ch, b'Z' as u32,
            "After Sixel + ST, the trailing 'Z' must land at (0,0); got ch={:#x}",
            cell.ch
        );
    }
}

#[test]
fn regis_dcs_at_each_split_does_not_leak() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // ReGIS uses `\x1bPp...\x1b\\` (DCS p ... ST). It's not implemented
    // by alacritty; must be inert. Test every split point.
    let payload = b"\x1bPpS(I(B))\x1b\\X";
    for split in 1..payload.len() {
        let (a, b) = payload.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let cap = drive_chunks(&chunks);
            // No events allowed.
            assert!(
                cap.events.is_empty(),
                "ReGIS split at {split} must produce no events; got {:?}",
                cap.events
            );
            // Row 0 must end with X (and not contain literal 'S(I(B))').
            let row = row0_text(&payload[..]);
            assert!(
                !row.contains("S(I(B))"),
                "ReGIS payload bytes must not bleed onto the grid; row0={row:?}"
            );
            // Ensure that the second feed produces same final state as one shot.
            let term_full = bc::bb_term_new(80, 24, 100);
            bc::bb_term_input(term_full, payload.as_ptr(), payload.len());
            let raw = bc::bb_term_text_range(term_full, 0, 0, 0, 79, 0);
            let slice = std::slice::from_raw_parts((*raw).bytes, (*raw).len);
            let row_full = std::str::from_utf8(slice).unwrap_or("").to_string();
            bc::bb_string_release(raw);
            bc::bb_term_free(term_full);
            // Both the split and full feeds must show 'X' at end.
            let term_split = bc::bb_term_new(80, 24, 100);
            for c in &chunks {
                bc::bb_term_input(term_split, c.as_ptr(), c.len());
            }
            let raw2 = bc::bb_term_text_range(term_split, 0, 0, 0, 79, 0);
            let slice2 = std::slice::from_raw_parts((*raw2).bytes, (*raw2).len);
            let row_split = std::str::from_utf8(slice2).unwrap_or("").to_string();
            bc::bb_string_release(raw2);
            bc::bb_term_free(term_split);
            assert_eq!(
                row_full.trim_end_matches('\u{0}'),
                row_split.trim_end_matches('\u{0}'),
                "ReGIS split at {split}: row text differs full={row_full:?} split={row_split:?}"
            );
        }
    }
}

#[test]
fn unknown_dcs_with_st_split_does_not_corrupt_state() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // After an unknown DCS where ST is split across chunks, a follow-up
    // DA1 query must still reply. This pins that the DCS state machine
    // returns to ground correctly even when ST is fragmented.
    let chunks: &[&[u8]] = &[b"\x1bPzunknown_payload\x1b", b"\\\x1b[c"];
    unsafe {
        let cap = drive_chunks(chunks);
        let any_da1 = cap.pty_writes.iter().any(|w| w == b"\x1b[?6c");
        assert!(
            any_da1,
            "DA1 reply must arrive after fragmented unknown DCS; got writes {:?}",
            cap.pty_writes
        );
    }
}

// ===========================================================================
// DECSC / DECRC — ESC 7 / ESC 8 cursor save/restore
// ===========================================================================

#[test]
fn decsc_decrc_split_around_save_restore_preserves_cursor() {
    // pre-flight: ~120 KiB × multiple chunk shapes, ~10 ms.
    //
    // Sequence:
    //   ESC[5;5H      cursor to (5,5)
    //   ESC 7         save
    //   ESC[10;10HXY  move + write
    //   ESC 8         restore
    //   Z             write 'Z' at the restored cursor
    //
    // Final state: 'Z' at (5,5) (col 5 1-indexed → col 4), 'XY' at
    // (10,10..11). We feed the sequence in several chunk shapes
    // including ones that split at the lone ESC of DECSC and DECRC.
    let payload: &[u8] = b"\x1b[5;5H\x1b7\x1b[10;10HXY\x1b8Z";
    let shapes: &[Vec<&[u8]>] = &[
        // single-shot
        vec![payload],
        // split right before ESC 7 (DECSC)
        vec![&payload[..6], &payload[6..]],
        // split between ESC and 7 of DECSC (the lone ESC must not be
        // misinterpreted as printable)
        vec![&payload[..7], &payload[7..]],
        // split right before ESC 8 (DECRC)
        vec![&payload[..16], &payload[16..]],
        // split between ESC and 8 of DECRC
        vec![&payload[..17], &payload[17..]],
        // byte-by-byte
        payload.iter().map(std::slice::from_ref).collect(),
    ];
    for (i, shape) in shapes.iter().enumerate() {
        unsafe {
            let cell_z = cell_at_after(shape, 4, 4); // (col 5, row 5) 1-indexed
            assert_eq!(
                cell_z.ch, b'Z' as u32,
                "shape {i}: 'Z' must land at restored cursor (4,4); got ch={:#x} at (4,4)",
                cell_z.ch
            );
            let cell_x = cell_at_after(shape, 9, 9);
            let cell_y = cell_at_after(shape, 10, 9);
            assert_eq!(
                cell_x.ch, b'X' as u32,
                "shape {i}: 'X' must land at (9,9); got {:#x}",
                cell_x.ch
            );
            assert_eq!(
                cell_y.ch, b'Y' as u32,
                "shape {i}: 'Y' must land at (10,9); got {:#x}",
                cell_y.ch
            );
        }
    }
}

// ===========================================================================
// DECTCEM (cursor visibility) and other ?-prefix modes under fragmentation
// ===========================================================================

#[test]
fn dectcem_show_hide_split_at_every_offset_toggles_correctly() {
    // pre-flight: ~120 KiB × ~14 splits, ~30 ms.
    //
    // `\x1b[?25l` hides the cursor; `\x1b[?25h` shows. Each is 8 bytes.
    // Split at every internal boundary; verify the SHOW_CURSOR bit is
    // cleared/set after the parse completes.
    let hide = b"\x1b[?25l";
    let show = b"\x1b[?25h";
    for split in 1..hide.len() {
        let (a, b) = hide.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let m = mode_after(&chunks);
            assert_eq!(
                m & bc::bb_mode::SHOW_CURSOR,
                0,
                "DECTCEM hide split at {split} must clear SHOW_CURSOR; mode={m:#x}"
            );
        }
    }
    for split in 1..show.len() {
        let (a, b) = show.split_at(split);
        // First hide, then split-show.
        let chunks: Vec<&[u8]> = vec![hide, a, b];
        unsafe {
            let m = mode_after(&chunks);
            assert_ne!(
                m & bc::bb_mode::SHOW_CURSOR,
                0,
                "DECTCEM show split at {split} must set SHOW_CURSOR; mode={m:#x}"
            );
        }
    }
}

#[test]
fn bracketed_paste_split_at_every_offset_toggles_correctly() {
    // pre-flight: ~120 KiB × ~16 splits, ~10 ms.
    //
    // `\x1b[?2004h` and `\x1b[?2004l`. Same exhaustion treatment as
    // DECTCEM. Verify BRACKETED_PASTE bit toggles correctly.
    let on = b"\x1b[?2004h";
    let off = b"\x1b[?2004l";
    for split in 1..on.len() {
        let (a, b) = on.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let m = mode_after(&chunks);
            assert_ne!(
                m & bc::bb_mode::BRACKETED_PASTE,
                0,
                "?2004h split at {split} must set BRACKETED_PASTE; mode={m:#x}"
            );
        }
    }
    for split in 1..off.len() {
        let (a, b) = off.split_at(split);
        let chunks: Vec<&[u8]> = vec![on, a, b];
        unsafe {
            let m = mode_after(&chunks);
            assert_eq!(
                m & bc::bb_mode::BRACKETED_PASTE,
                0,
                "?2004l split at {split} must clear BRACKETED_PASTE; mode={m:#x}"
            );
        }
    }
}

#[test]
fn deckpam_deckpnm_split_around_lone_esc() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // `\x1b=` is DECKPAM (application keypad), `\x1b>` is DECKPNM
    // (normal keypad). Both are 2-byte ESC sequences. The chunk boundary
    // can land between the ESC and the final byte. Pin APP_KEYPAD bit.
    let app = b"\x1b=";
    let normal = b"\x1b>";
    // Single shot enable.
    unsafe {
        assert_ne!(
            mode_after(&[&app[..]]) & bc::bb_mode::APP_KEYPAD,
            0,
            "ESC = (single shot) must set APP_KEYPAD"
        );
        // Split between ESC and =.
        assert_ne!(
            mode_after(&[&app[..1], &app[1..]]) & bc::bb_mode::APP_KEYPAD,
            0,
            "ESC = (split) must set APP_KEYPAD"
        );
        // Disable.
        assert_eq!(
            mode_after(&[&app[..], &normal[..]]) & bc::bb_mode::APP_KEYPAD,
            0,
            "ESC > after ESC = must clear APP_KEYPAD"
        );
        // Disable with split ESC.
        assert_eq!(
            mode_after(&[&app[..], &normal[..1], &normal[1..]]) & bc::bb_mode::APP_KEYPAD,
            0,
            "ESC > (split) must clear APP_KEYPAD"
        );
    }
}

#[test]
fn decckm_app_cursor_split_at_every_offset_toggles_correctly() {
    // pre-flight: ~120 KiB, ~10 ms.
    //
    // `\x1b[?1h` enables application cursor (DECCKM); `\x1b[?1l`
    // disables. Important: ?1h is also DECCKM-on, used by readline-
    // like input editors. APP_CURSOR mode bit must reflect.
    let on = b"\x1b[?1h";
    let off = b"\x1b[?1l";
    for split in 1..on.len() {
        let (a, b) = on.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let m = mode_after(&chunks);
            assert_ne!(
                m & bc::bb_mode::APP_CURSOR,
                0,
                "?1h split at {split} must set APP_CURSOR; mode={m:#x}"
            );
        }
    }
    for split in 1..off.len() {
        let (a, b) = off.split_at(split);
        let chunks: Vec<&[u8]> = vec![on, a, b];
        unsafe {
            let m = mode_after(&chunks);
            assert_eq!(
                m & bc::bb_mode::APP_CURSOR,
                0,
                "?1l split at {split} must clear APP_CURSOR; mode={m:#x}"
            );
        }
    }
}

// ===========================================================================
// DECSTBM (scroll region) under fragmentation
// ===========================================================================

#[test]
fn decstbm_split_at_every_offset_takes_effect() {
    // pre-flight: ~120 KiB, ~20 ms.
    //
    // `\x1b[5;20r` sets the scroll region to rows 5..20. We can't read
    // the region directly via FFI, but we can probe its effect: with
    // the region active, a `\x1b[H` followed by 20 newlines should cause
    // scrolling INSIDE the region only, leaving rows 0..4 untouched.
    //
    // Setup: write 'TOP' on row 0, then set scroll region, then move
    // cursor to (1,1), emit 25 newlines + 'BOTTOM'. Row 0 must still
    // show 'TOP'; that proves the scroll region engaged.
    let stbm = b"\x1b[5;20r";
    for split in 1..stbm.len() {
        let (a, b) = stbm.split_at(split);
        let mut full: Vec<u8> = Vec::new();
        full.extend_from_slice(b"\x1b[1;1HTOP");
        full.extend_from_slice(a);
        // Carry the boundary by feeding tail in a separate chunk.
        let mut after: Vec<u8> = Vec::new();
        after.extend_from_slice(b);
        // Position to row 6, then emit 30 newlines so we exceed scroll
        // region's 16 rows. That forces the region to scroll, but
        // ROW 0 ('TOP') stays put because it's outside [5..=20].
        after.extend_from_slice(b"\x1b[6;1H");
        for i in 0..30 {
            after.extend_from_slice(format!("L{}\n", i).as_bytes());
        }
        let chunks: Vec<&[u8]> = vec![&full, &after];
        unsafe {
            let cell0 = cell_at_after(&chunks, 0, 0);
            let cell1 = cell_at_after(&chunks, 1, 0);
            let cell2 = cell_at_after(&chunks, 2, 0);
            assert_eq!(
                cell0.ch, b'T' as u32,
                "DECSTBM split {split}: row 0 col 0 must still be 'T'; got {:#x}",
                cell0.ch
            );
            assert_eq!(
                cell1.ch, b'O' as u32,
                "DECSTBM split {split}: row 0 col 1 must still be 'O'; got {:#x}",
                cell1.ch
            );
            assert_eq!(
                cell2.ch, b'P' as u32,
                "DECSTBM split {split}: row 0 col 2 must still be 'P'; got {:#x}",
                cell2.ch
            );
        }
    }
}

// ===========================================================================
// CHA (Cursor Horizontal Absolute) under fragmentation
// ===========================================================================

#[test]
fn cha_split_at_every_offset_lands_at_correct_column() {
    // pre-flight: ~120 KiB, ~10 ms.
    //
    // `\x1b[10G` moves cursor to column 10 (1-indexed → col 9). Then
    // we write 'C'. Final cell at (9, 0) must be 'C'. Test every
    // possible split point.
    let payload = b"\x1b[10GC";
    for split in 1..payload.len() {
        let (a, b) = payload.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let cell = cell_at_after(&chunks, 9, 0);
            assert_eq!(
                cell.ch, b'C' as u32,
                "CHA split {split}: col-9 cell must be 'C'; got ch={:#x}",
                cell.ch
            );
            // Cells skipped over by CHA may be left as alacritty's sentinel
            // (`'\0'`) or a space (`0x20`), depending on whether the cursor
            // walked through them. What we forbid: any digit, semicolon, or
            // CSI introducer leaking onto the grid (the symptom of a parser
            // state-recovery regression).
            let cell_zero = cell_at_after(&chunks, 0, 0);
            assert!(
                cell_zero.ch == 0 || cell_zero.ch == b' ' as u32,
                "CHA split {split}: col-0 cell must be empty / space (no leaked params); \
                 got ch={:#x}",
                cell_zero.ch
            );
            // Verify the digit '1' or '0' from the param didn't leak: scan
            // cells 0..9 for any digit character.
            for c in 0..9u16 {
                let cell_c = cell_at_after(&chunks, c, 0);
                let ch = cell_c.ch;
                let is_digit = (b'0' as u32..=b'9' as u32).contains(&ch);
                let is_csi_introducer = ch == b'[' as u32 || ch == b';' as u32;
                assert!(
                    !is_digit && !is_csi_introducer,
                    "CHA split {split}: cell ({c},0) leaked CSI param char ch={:#x}",
                    ch
                );
            }
        }
    }
}

// ===========================================================================
// Save-cursor + ED-all-injection interaction
// ===========================================================================

#[test]
fn save_cursor_around_ed_all_does_not_clobber_saved_state() {
    // pre-flight: ~120 KiB × multiple chunk shapes, ~10 ms.
    //
    // The new ED-all-injection logic emits `\x1b[3J` mid-chunk after
    // the dispatching `J` byte. Concern: if a save-cursor (DECSC) was
    // active and the saved-state is tied to the processor's current
    // cursor, does the injection accidentally bump it?
    //
    // Sequence:
    //   ESC[5;5H        cursor to (5,5)
    //   ESC[31m         set FG red
    //   ESC 7           save (cursor + SGR are part of saved state)
    //   ESC[2J          ED-all (triggers 3J injection)
    //   ESC[1;1H        cursor home
    //   ESC[39m         reset FG
    //   ESC 8           restore — must put cursor back at (5,5) with red FG
    //   X
    //
    // Final state: 'X' at (4, 4) with BOLD off and a non-default FG.
    // We don't pin the exact red-color value (it may be palette-indexed
    // 31 = 0xCD0000 or theme-mapped), but we do pin: the cell is at the
    // restored position AND it has a non-default FG (i.e. not 0).
    let payload: &[u8] = b"\x1b[5;5H\x1b[31m\x1b7\x1b[2J\x1b[1;1H\x1b[39m\x1b8X";
    let shapes: &[Vec<&[u8]>] = &[
        vec![payload],
        // split right after ED-all dispatching J — this is exactly
        // where the 3J injection happens
        vec![&payload[..15], &payload[15..]],
        // boundary inside ED-all params
        vec![&payload[..14], &payload[14..]],
        // boundary at the parked-ESC after 2J (the ratatui shape
        // that broke the original sequence)
        vec![&payload[..16], &payload[16..]],
        // byte-by-byte
        payload.iter().map(std::slice::from_ref).collect(),
    ];
    for (i, shape) in shapes.iter().enumerate() {
        unsafe {
            let cell = cell_at_after(shape, 4, 4);
            assert_eq!(
                cell.ch, b'X' as u32,
                "shape {i}: 'X' must land at restored (4,4); got ch={:#x}",
                cell.ch
            );
            // The saved SGR state was red FG. After DECRC we should
            // see a non-default fg (alacritty's default fg is the
            // configured palette[Foreground], which we don't know
            // here, but red is index 31's RGB which is not the
            // default). Pin that fg differs from a fresh-grid cell's
            // fg.
            let fresh = cell_at_after(&[b"X"], 0, 0);
            assert_ne!(
                cell.fg, fresh.fg,
                "shape {i}: restored SGR red must differ from default fg; cell.fg={:#x} fresh.fg={:#x}",
                cell.fg, fresh.fg
            );
        }
    }
}

// ===========================================================================
// modify-other-keys exhaustion under fragmentation
// ===========================================================================

#[test]
fn modify_other_keys_exhaustive_split_lights_bit() {
    // pre-flight: ~120 KiB × every split, ~10 ms.
    //
    // The existing test pins ONE split point. Here we test every
    // internal byte boundary of `\x1b[>4;2m` to ensure parser state
    // survives the boundary in all positions.
    let payload = b"\x1b[>4;2m";
    for split in 1..payload.len() {
        let (a, b) = payload.split_at(split);
        let chunks: Vec<&[u8]> = vec![a, b];
        unsafe {
            let m = mode_after(&chunks);
            assert_ne!(
                m & bc::bb_mode::MODIFY_OTHER_KEYS,
                0,
                "modify_other_keys split at {split} must light bit; mode={m:#x}"
            );
        }
    }
}

// ===========================================================================
// Two-chunk grid permutation: every split of a realistic spinner frame
// ===========================================================================

#[test]
fn realistic_spinner_frame_every_split_idempotent() {
    // pre-flight: ~120 KiB × ~30 splits, ~30 ms.
    //
    // A complete spinner frame mixing every surface above:
    //   ESC[?25l        hide cursor (mode bit)
    //   ESC[?2004h      bracketed paste on (mode bit)
    //   ESC 7           save cursor
    //   ESC[10;5H       CUP
    //   ESC[2K          EL
    //   ESC[31;1m       SGR red+bold
    //   ESC]8;;url\x1b\\link\x1b]8;;\x1b\\
    //   ESC[0m          SGR reset
    //   ESC 8           restore cursor
    //   ESC[?25h        show cursor
    //
    // Test every two-way split. Final state must:
    //   - Have 'l','i','n','k' on row 9 cols 4..7
    //   - Have URL attribution on those cells
    //   - Have SHOW_CURSOR set, BRACKETED_PASTE set
    let url = "https://x.example/p";
    let mut payload: Vec<u8> = Vec::new();
    payload.extend_from_slice(b"\x1b[?25l\x1b[?2004h\x1b7\x1b[10;5H\x1b[2K\x1b[31;1m");
    payload.extend_from_slice(format!("\x1b]8;;{}\x1b\\link\x1b]8;;\x1b\\", url).as_bytes());
    payload.extend_from_slice(b"\x1b[0m\x1b8\x1b[?25h");
    let two_way = all_two_way_splits(&payload);
    for (i, shape) in two_way.iter().enumerate() {
        unsafe {
            let m = mode_after(shape);
            assert_ne!(
                m & bc::bb_mode::SHOW_CURSOR,
                0,
                "split {i}: SHOW_CURSOR must be set after `?25h`; mode={m:#x}"
            );
            assert_ne!(
                m & bc::bb_mode::BRACKETED_PASTE,
                0,
                "split {i}: BRACKETED_PASTE must remain set; mode={m:#x}"
            );
            for (col, ch) in [(4u16, b'l'), (5, b'i'), (6, b'n'), (7, b'k')] {
                let cell = cell_at_after(shape, col, 9);
                assert_eq!(
                    cell.ch, ch as u32,
                    "split {i}: ({col},9) must be {:?}; got {:#x}",
                    ch as char, cell.ch
                );
                let link = link_url_at(shape, col, 9);
                assert_eq!(
                    link.as_deref(),
                    Some(url),
                    "split {i}: ({col},9) must attribute to {url:?}; got {link:?}"
                );
            }
        }
    }
}

// ===========================================================================
// N-way fragmentation of common sequences (the chunk-shape sweep)
// ===========================================================================

#[test]
fn common_sequences_survive_1_2_4_16_64_byte_chunks() {
    // pre-flight: ~120 KiB × multiple shapes × multiple sequences, ~50 ms.
    //
    // Sweep every common sequence through chunk sizes 1, 2, 4, 16, 64.
    // For each chunk size, verify the post-condition holds. This is
    // the breadth-first sister to the byte-by-byte exhaustion tests
    // above — catches a state-survival regression at any chunk size.
    let chunk_sizes: &[usize] = &[1, 2, 4, 16, 64];
    type ModeCheck = fn(*mut bc::BBTerm) -> bool;
    let cases: &[(&[u8], &str, ModeCheck)] = &[
        (b"\x1b[?25l\x1b[?25h", "DECTCEM cycle", |term| unsafe {
            bc::bb_term_current_mode(term) & bc::bb_mode::SHOW_CURSOR != 0
        }),
        (b"\x1b[?2004h", "bracketed paste on", |term| unsafe {
            bc::bb_term_current_mode(term) & bc::bb_mode::BRACKETED_PASTE != 0
        }),
        (b"\x1b[?1h", "DECCKM on", |term| unsafe {
            bc::bb_term_current_mode(term) & bc::bb_mode::APP_CURSOR != 0
        }),
        (b"\x1b[?1049h", "alt-screen on", |term| unsafe {
            bc::bb_term_current_mode(term) & bc::bb_mode::ALT_SCREEN != 0
        }),
        (b"\x1b[>4;2m", "modifyOtherKeys 2", |term| unsafe {
            bc::bb_term_current_mode(term) & bc::bb_mode::MODIFY_OTHER_KEYS != 0
        }),
    ];
    for &(payload, label, predicate) in cases {
        for &csz in chunk_sizes {
            unsafe {
                let term = bc::bb_term_new(80, 24, 100);
                let chunks: Vec<&[u8]> = payload.chunks(csz).collect();
                for c in &chunks {
                    bc::bb_term_input(term, c.as_ptr(), c.len());
                }
                assert!(
                    predicate(term),
                    "{label} failed at chunk_size={csz}; mode={:#x}",
                    bc::bb_term_current_mode(term)
                );
                bc::bb_term_free(term);
            }
        }
    }
}

// ===========================================================================
// Defensive: split at the boundary just BEFORE an ED-all so injection logic
// runs across chunks
// ===========================================================================

#[test]
fn ed_all_injection_after_save_cursor_split_boundary() {
    // pre-flight: ~120 KiB, ~10 ms.
    //
    // Targeted regression for the ED-all + injection path. The fix
    // commit (6fdd331) walked byte-by-byte to find the exact ED-all
    // dispatch position and inject `\x1b[3J` only there. We pin that
    // a chunk ending JUST BEFORE the dispatching 'J' (so the 'J'
    // arrives in the next chunk) still injects correctly and doesn't
    // double-inject or miss.
    //
    // Test: feed scrollback-builder lines, then ED-all in two chunks
    // splitting RIGHT BEFORE the 'J'. After the feed, scrollback
    // history_size should be at most ~zero (3J cleared it). Then a
    // CUP + write should land cleanly without leaked params.
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        for i in 0..100 {
            let line = format!("history-line-{}\n", i);
            bc::bb_term_input(term, line.as_ptr(), line.len());
        }
        let snap = bc::bb_term_take_snapshot(term);
        let history_before = (*snap).history_size;
        bc::bb_snap_release(snap);
        assert!(
            history_before > 0,
            "precondition: history must accumulate before ED-all"
        );

        // Split: first chunk is `\x1b[2`, second is `J\x1b[1;1HHELLO`.
        bc::bb_term_input(term, b"\x1b[2".as_ptr(), 3);
        bc::bb_term_input(term, b"J\x1b[1;1HHELLO".as_ptr(), 12);

        let snap = bc::bb_term_take_snapshot(term);
        let history_after = (*snap).history_size;
        let cell = *((*snap).cells.add(0));
        bc::bb_snap_release(snap);
        assert_eq!(
            history_after, 0,
            "ED-all split at boundary must still inject 3J and clear history; \
             before={history_before} after={history_after}"
        );
        assert_eq!(
            cell.ch, b'H' as u32,
            "after split-boundary ED-all + CUP, 'H' must land at (0,0); got ch={:#x}",
            cell.ch
        );
        bc::bb_term_free(term);
    }
}

// ===========================================================================
// Adversarial: OSC fragmentation interleaved with CSI in the same chunk
// ===========================================================================

#[test]
fn osc_and_csi_interleaved_under_fragmentation() {
    // pre-flight: ~120 KiB × 8 shapes, ~10 ms.
    //
    // A single chunk like `\x1b]8;;url\x1b\\\x1b[31mX\x1b[0m\x1b]8;;\x1b\\`
    // mixes OSC + CSI. Across various chunk sizes the cell at (0,0)
    // must be 'X' with red fg AND have URL attribution.
    let url = "https://example.com/q";
    let payload = format!("\x1b]8;;{}\x1b\\\x1b[31mX\x1b[0m\x1b]8;;\x1b\\", url);
    let bytes = payload.as_bytes();
    let chunk_sizes: &[usize] = &[1, 2, 3, 4, 7, 16, 64, bytes.len()];
    for &csz in chunk_sizes {
        let chunks: Vec<&[u8]> = bytes.chunks(csz).collect();
        unsafe {
            let cell = cell_at_after(&chunks, 0, 0);
            assert_eq!(
                cell.ch, b'X' as u32,
                "chunk_size={csz}: (0,0) must be 'X'; got ch={:#x}",
                cell.ch
            );
            let link = link_url_at(&chunks, 0, 0);
            assert_eq!(
                link.as_deref(),
                Some(url),
                "chunk_size={csz}: (0,0) must attribute to URL; got {link:?}"
            );
            // Default fg (no SGR) is some specific value; with SGR 31
            // it must differ.
            let fresh = cell_at_after(&[b"X"], 0, 0);
            assert_ne!(
                cell.fg, fresh.fg,
                "chunk_size={csz}: SGR-31 fg must differ from default; got {:#x}",
                cell.fg
            );
        }
    }
}
