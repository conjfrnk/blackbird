//! Repro for the in-the-wild "Claude Code spinner" rendering glitch where
//! a CSI cursor-position parameter (e.g. `53;15`) bleeds into the visible
//! grid as if it were literal text. The hypothesis space:
//!
//!   1. Chunked-read fragmentation in `bb_term_input` exposes a vte parser
//!      state-recovery edge case where `ESC[<params>` is split across two
//!      `bb_term_input` calls and the parser drops the prefix but writes
//!      params as text.
//!   2. The OSC `[2J` ED-all augmentation (`bb_term_input` injects
//!      `\x1b[3J` after seeing top-level `\x1b[2J`) interferes with a
//!      subsequent CSI sequence.
//!   3. A CUP whose row exceeds the grid height (e.g. row 53 on a 30-row
//!      viewport) causes a broken state where alacritty silently accepts
//!      the bytes as text rather than as a control sequence.
//!   4. The actual Claude Code redraw pattern (CUP + EL + write, in tight
//!      loops at typically the same row) leaks param bytes when fed in
//!      mixed chunk shapes.
//!
//! Each test below stresses one hypothesis and asserts that NO row in the
//! final snapshot contains any contiguous subsequence of CSI param bytes
//! that the parser was supposed to swallow. In particular, no cell may
//! carry the digits / `;` from a CSI sequence the test itself fed.
//!
//! Pre-flight: every test owns at most one 80×24 BBTerm; total memory
//! budget per test is ~120 KiB; no I/O, no sleeps, no spawned threads.
//! Largest payload is ~32 KiB (rapid-redraw stress). All tests run in
//! well under 50 ms locally.

use blackbird_core as bc;

/// Take a fresh snapshot of `term` and return all visible cells as a
/// 2-D vector of unicode scalars. Returns `(rows, cols, cells_per_row)`.
unsafe fn snapshot_grid(term: *mut bc::BBTerm) -> (u16, u16, Vec<Vec<u32>>) {
    let snap = bc::bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "snapshot must not be null");
    let cols = (*snap).cols;
    let rows = (*snap).rows;
    let mut grid: Vec<Vec<u32>> = Vec::with_capacity(rows as usize);
    for r in 0..rows {
        let mut row: Vec<u32> = Vec::with_capacity(cols as usize);
        for c in 0..cols {
            let idx = (r as usize) * (cols as usize) + c as usize;
            let cell = *((*snap).cells.add(idx));
            row.push(cell.ch);
        }
        grid.push(row);
    }
    bc::bb_snap_release(snap);
    (rows, cols, grid)
}

/// Render a row as a debug `String` for failure messages. Empty cells (`ch == 0`)
/// become `'.'` so trailing whitespace is visible.
fn row_to_debug_string(row: &[u32]) -> String {
    let mut s = String::with_capacity(row.len());
    for &ch in row {
        if ch == 0 {
            s.push('.');
        } else if let Some(c) = char::from_u32(ch) {
            // Replace control chars with U+FFFD-ish marker so they don't
            // produce zero-width output that hides the actual issue.
            if c.is_control() {
                s.push('\u{FFFD}');
            } else {
                s.push(c);
            }
        } else {
            s.push('?');
        }
    }
    s
}

/// Render a row as a "visible" String — only printable chars, packed
/// contiguously. Zeroed cells are dropped; this is the form we substring-
/// match against to catch leaked CSI params.
fn row_to_visible_string(row: &[u32]) -> String {
    let mut s = String::with_capacity(row.len());
    for &ch in row {
        if ch == 0 {
            continue;
        }
        if let Some(c) = char::from_u32(ch) {
            if !c.is_control() {
                s.push(c);
            }
        }
    }
    s
}

/// Assert that no row's visible content contains `forbidden`. Panics with a
/// dump of every row on failure so the smoking gun is easy to read.
fn assert_no_row_contains(grid: &[Vec<u32>], forbidden: &[&str], label: &str) {
    for (r, row) in grid.iter().enumerate() {
        let vis = row_to_visible_string(row);
        for needle in forbidden {
            if vis.contains(needle) {
                let mut dump = String::new();
                for (rr, rrow) in grid.iter().enumerate() {
                    dump.push_str(&format!(
                        "  row {:>2}: {:?}\n",
                        rr,
                        row_to_debug_string(rrow)
                    ));
                }
                panic!(
                    "[{label}] row {r} contains forbidden CSI-param substring {needle:?}\n\
                     row visible text: {vis:?}\n\
                     full grid dump:\n{dump}"
                );
            }
        }
    }
}

/// Common forbidden substrings — these are exact CSI param shapes the tests
/// below feed. If ANY of them lands in the visible grid, the parser leaked.
const FORBIDDEN_CUP_PARAMS: &[&str] = &[
    "53;15", // the actual symptom from Connor's screenshot
    "10;1", "5;1", "1;1H", // a literal "[1;1H" trailing — the H means a final byte slipped
    "[2J", "[K", "[H",
];

// ---------------------------------------------------------------------------
// Hypothesis 1: chunked-read fragmentation of CSI sequences
// ---------------------------------------------------------------------------

#[test]
fn cup_byte_by_byte_split_does_not_leak_params() {
    // pre-flight: ~120 KiB (80×24 grid + one snapshot), ~5 ms.
    //
    // Feed every byte of a CUP + write + CUP + write pattern through a
    // separate `bb_term_input` call. The vte parser's state must persist
    // across these single-byte calls. After the feed, assert no row in
    // the visible grid carries the CUP param digits or the `[`/`H`
    // bracketing — they should have been silently consumed by the
    // parser.
    //
    // Pattern is the smallest reproduction of the screenshot symptom:
    //
    //     ESC [ 5 3 ; 1 5 H Reading 3 files…
    //     ESC [ 1 ; 1 H BANNER
    //
    // We expect ONLY the literal text "Reading 3 files…" / "BANNER" to
    // appear; the parser may clamp 53 to row 23 (last row) silently.
    let payload: Vec<u8> = b"\x1b[53;15HReading 3 files...\x1b[1;1HBANNER".to_vec();
    unsafe {
        let term = bc::bb_term_new(80, 24, 100);
        for byte in &payload {
            bc::bb_term_input(term, std::ptr::from_ref(byte), 1);
        }
        let (_rows, _cols, grid) = snapshot_grid(term);
        assert_no_row_contains(
            &grid,
            FORBIDDEN_CUP_PARAMS,
            "cup_byte_by_byte_split_does_not_leak_params",
        );

        // Stronger pin: at least one row contains "BANNER" (the second
        // write must land somewhere) and at least one row contains
        // "Reading 3" (clamped, but the text content should make it).
        let any_banner = grid
            .iter()
            .any(|row| row_to_visible_string(row).contains("BANNER"));
        assert!(
            any_banner,
            "expected literal 'BANNER' to land somewhere; grid:\n{}",
            grid.iter()
                .enumerate()
                .map(|(r, row)| format!("  row {r}: {:?}", row_to_debug_string(row)))
                .collect::<Vec<_>>()
                .join("\n")
        );
        let any_reading = grid
            .iter()
            .any(|row| row_to_visible_string(row).contains("Reading 3"));
        assert!(
            any_reading,
            "expected 'Reading 3' to land somewhere (clamp may move it); grid:\n{}",
            grid.iter()
                .enumerate()
                .map(|(r, row)| format!("  row {r}: {:?}", row_to_debug_string(row)))
                .collect::<Vec<_>>()
                .join("\n")
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn cup_after_ed_all_does_not_leak_params() {
    // pre-flight: ~120 KiB, ~5 ms.
    //
    // Hypothesis 2: the `\x1b[2J` augmentation (append `\x1b[3J`) breaks
    // a subsequent CSI in the same chunk. We feed the screen-clear
    // followed immediately by CUP + write, in several chunk shapes:
    // single-shot, byte-by-byte, and a worst-case split where the
    // boundary lands inside the CUP introducer.
    let chunk_shapes: &[Vec<&[u8]>] = &[
        // single-shot: everything in one call
        vec![b"\x1b[2J\x1b[1;1HHEADER\x1b[10;1HSTATUS"],
        // ED-all + CUP arrive separately (i.e. ED-all augmentation must
        // not poison the CSI parser state for the next chunk)
        vec![b"\x1b[2J", b"\x1b[1;1HHEADER", b"\x1b[10;1HSTATUS"],
        // boundary lands AT the ESC byte after the 3J injection point —
        // this is the most fragile shape
        vec![b"\x1b[2J\x1b", b"[1;1HHEADER", b"\x1b[10;1HSTATUS"],
        // boundary inside CUP params
        vec![b"\x1b[2J\x1b[1;", b"1HHEADER\x1b[10;", b"1HSTATUS"],
    ];
    for (i, shape) in chunk_shapes.iter().enumerate() {
        unsafe {
            let term = bc::bb_term_new(80, 24, 100);
            for chunk in shape {
                bc::bb_term_input(term, chunk.as_ptr(), chunk.len());
            }
            let (_rows, _cols, grid) = snapshot_grid(term);
            assert_no_row_contains(
                &grid,
                FORBIDDEN_CUP_PARAMS,
                &format!("cup_after_ed_all_does_not_leak_params/shape{i}"),
            );
            // Stronger pins.
            let any_header = grid
                .iter()
                .any(|row| row_to_visible_string(row).contains("HEADER"));
            assert!(
                any_header,
                "shape {i}: expected 'HEADER' to land somewhere; grid:\n{}",
                grid.iter()
                    .enumerate()
                    .map(|(r, row)| format!("  row {r}: {:?}", row_to_debug_string(row)))
                    .collect::<Vec<_>>()
                    .join("\n")
            );
            let any_status = grid
                .iter()
                .any(|row| row_to_visible_string(row).contains("STATUS"));
            assert!(
                any_status,
                "shape {i}: expected 'STATUS' to land somewhere; grid:\n{}",
                grid.iter()
                    .enumerate()
                    .map(|(r, row)| format!("  row {r}: {:?}", row_to_debug_string(row)))
                    .collect::<Vec<_>>()
                    .join("\n")
            );
            bc::bb_term_free(term);
        }
    }
}

#[test]
fn cup_with_oversize_row_clamps_silently() {
    // pre-flight: ~120 KiB (30-row grid), ~3 ms.
    //
    // Hypothesis 3: CUP row > grid height. Claude Code's spinner uses a
    // small viewport (24-30 rows) and emits `\x1b[53;15H` in some
    // contexts. xterm/vte's contract is to clamp out-of-range CUP
    // coordinates to the nearest in-range cell silently. A regression
    // that wrote the params as literal text would land them on the grid.
    let payload = b"\x1b[53;15HSpinner text\x1b[1;1HBanner";
    unsafe {
        // Use a 30-row grid: 53 is well above it.
        let term = bc::bb_term_new(80, 30, 100);
        bc::bb_term_input(term, payload.as_ptr(), payload.len());
        let (_rows, _cols, grid) = snapshot_grid(term);
        assert_no_row_contains(
            &grid,
            FORBIDDEN_CUP_PARAMS,
            "cup_with_oversize_row_clamps_silently/single_shot",
        );

        // Now retry as byte-by-byte fragmentation.
        bc::bb_term_free(term);
        let term = bc::bb_term_new(80, 30, 100);
        for byte in payload.iter() {
            bc::bb_term_input(term, std::ptr::from_ref(byte), 1);
        }
        let (_rows, _cols, grid) = snapshot_grid(term);
        assert_no_row_contains(
            &grid,
            FORBIDDEN_CUP_PARAMS,
            "cup_with_oversize_row_clamps_silently/byte_by_byte",
        );
        bc::bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Hypothesis 4: the actual Claude Code redraw pattern
// ---------------------------------------------------------------------------

/// Compose a "Claude Code spinner" frame: hide cursor, save cursor, CUP to a
/// row, EL (erase line), write a status, restore cursor, show cursor.
/// `row` is 1-indexed per the CSI grammar; `text` is printable ASCII.
fn spinner_frame(row: u16, col: u16, text: &str) -> Vec<u8> {
    let mut buf = Vec::with_capacity(text.len() + 32);
    buf.extend_from_slice(b"\x1b[?25l"); // hide cursor
    buf.extend_from_slice(b"\x1b[s"); // save cursor (DEC private save)
    buf.extend_from_slice(format!("\x1b[{};{}H", row, col).as_bytes()); // CUP
    buf.extend_from_slice(b"\x1b[2K"); // EL all
    buf.extend_from_slice(text.as_bytes());
    buf.extend_from_slice(b"\x1b[u"); // restore cursor
    buf.extend_from_slice(b"\x1b[?25h"); // show cursor
    buf
}

#[test]
fn rapid_inplace_redraw_pattern_no_visible_params() {
    // pre-flight: ~120 KiB grid + ~32 KiB payload feed in chunks, ~30 ms.
    //
    // Reproduce the actual Claude Code spinner cadence: ~10 frames per
    // second, each frame is hide-cursor + save + CUP + EL + write +
    // restore + show-cursor. We feed 100 frames at varying chunk sizes
    // (1, 2, 4, 16, 64, 1024, full). The final grid must show ONLY the
    // last frame's status text plus the persistent banner — never any
    // CSI params or escape introducers.
    //
    // The 53;15 CUP from the screenshot is included to stress hypothesis
    // 3 simultaneously: row 53 on a 30-row grid is out-of-range and must
    // clamp without leaking params.
    let chunk_sizes: &[usize] = &[1, 2, 4, 16, 64, 1024, usize::MAX];
    for &chunk_size in chunk_sizes {
        unsafe {
            let term = bc::bb_term_new(80, 30, 100);
            // Persistent banner.
            let banner = b"\x1b[1;1H\x1b[2KBANNER ROW";
            bc::bb_term_input(term, banner.as_ptr(), banner.len());
            // 100 spinner frames at row 53;15. Each frame label is its
            // index, padded so successive frames land in the same cells.
            let mut all_bytes: Vec<u8> = Vec::with_capacity(8192);
            for i in 0..100u32 {
                let text = format!("Reading {:>3} files", i);
                let frame = spinner_frame(53, 15, &text);
                all_bytes.extend_from_slice(&frame);
            }
            // Feed in chunks of `chunk_size` (or one shot if usize::MAX).
            let csz = chunk_size.min(all_bytes.len());
            if chunk_size == usize::MAX {
                bc::bb_term_input(term, all_bytes.as_ptr(), all_bytes.len());
            } else {
                let mut i = 0;
                while i < all_bytes.len() {
                    let end = (i + csz).min(all_bytes.len());
                    bc::bb_term_input(term, all_bytes[i..].as_ptr(), end - i);
                    i = end;
                }
            }
            let (_rows, _cols, grid) = snapshot_grid(term);
            assert_no_row_contains(
                &grid,
                FORBIDDEN_CUP_PARAMS,
                &format!("rapid_inplace_redraw_pattern_no_visible_params/chunk_size={chunk_size}"),
            );
            // Per-frame: also forbid every param shape the loop emitted.
            // We only check `53;15` (the constant CUP) here because the
            // numeric prefixes vary per frame.
            for (r, row) in grid.iter().enumerate() {
                let vis = row_to_visible_string(row);
                assert!(
                    !vis.contains("53;15"),
                    "chunk_size={chunk_size}: row {r} leaks CUP params: {vis:?}"
                );
                assert!(
                    !vis.contains("[2K"),
                    "chunk_size={chunk_size}: row {r} leaks EL bytes: {vis:?}"
                );
                assert!(
                    !vis.contains("?25l") && !vis.contains("?25h"),
                    "chunk_size={chunk_size}: row {r} leaks DECTCEM: {vis:?}"
                );
            }

            // The last frame's text must land somewhere visible — that
            // is the actual status the user expects to see. With CUP row
            // 53 on a 30-row grid the parser should clamp to row 29 (the
            // bottom).
            let any_last_frame = grid
                .iter()
                .any(|row| row_to_visible_string(row).contains("Reading  99 files"));
            assert!(
                any_last_frame,
                "chunk_size={chunk_size}: expected the last spinner frame text to land; grid:\n{}",
                grid.iter()
                    .enumerate()
                    .map(|(r, row)| format!("  row {r}: {:?}", row_to_debug_string(row)))
                    .collect::<Vec<_>>()
                    .join("\n")
            );
            bc::bb_term_free(term);
        }
    }
}

#[test]
fn cup_split_at_every_internal_offset() {
    // pre-flight: ~120 KiB + ~30 trial reps × 1 KiB payload, ~30 ms.
    //
    // Exhaustive variant: for the canonical sequence
    //
    //     ESC [ 2 J ESC [ 5 3 ; 1 5 H Reading 3 files
    //
    // try every possible 2-way split point. Each split feeds the two
    // halves through separate `bb_term_input` calls. The parser MUST
    // arrive at the same final grid shape (modulo the timing of `\x1b[3J`
    // injection) for every split; in particular, no split may produce a
    // grid containing any CSI param substring.
    //
    // This is the sharpest possible probe of hypothesis 1 — every
    // boundary-position is exhausted.
    let payload: Vec<u8> = b"\x1b[2J\x1b[53;15HReading 3 files".to_vec();
    for split in 0..payload.len() {
        unsafe {
            let term = bc::bb_term_new(80, 30, 100);
            let (head, tail) = payload.split_at(split);
            if !head.is_empty() {
                bc::bb_term_input(term, head.as_ptr(), head.len());
            }
            if !tail.is_empty() {
                bc::bb_term_input(term, tail.as_ptr(), tail.len());
            }
            let (_rows, _cols, grid) = snapshot_grid(term);
            assert_no_row_contains(
                &grid,
                FORBIDDEN_CUP_PARAMS,
                &format!("cup_split_at_every_internal_offset/split={split}"),
            );
            // Last 'g' of "Reading" must reach the grid (the text is the
            // visible payload).
            let any_text = grid
                .iter()
                .any(|row| row_to_visible_string(row).contains("Reading 3 files"));
            assert!(
                any_text,
                "split={split}: expected 'Reading 3 files' on the grid; got:\n{}",
                grid.iter()
                    .enumerate()
                    .map(|(r, row)| format!("  row {r}: {:?}", row_to_debug_string(row)))
                    .collect::<Vec<_>>()
                    .join("\n")
            );
            bc::bb_term_free(term);
        }
    }
}
