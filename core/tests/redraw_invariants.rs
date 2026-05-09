//! Pins parser/renderer invariants for the TUI redraw patterns Ink-based
//! TUIs (Claude Code, ratatui apps, fzf) emit. Each test asserts a single
//! invariant about how alacritty 0.26 / vte 0.15 / BBCore handles a
//! specific redraw pattern; if a future `cargo update` regresses one of
//! these, the test fails loudly with a printed grid in the failure
//! message rather than silently corrupting the dogfood experience.
//!
//! Origin: 2026-05-08 dogfood report — `(ctrl+b to run in background)`
//! lines stacking inside Claude Code's running-agents block. Investigation
//! concluded the stacking is upstream (Claude Code renders one hint per
//! active backgroundable agent) and not Blackbird's fault. These tests
//! are the byproduct: a regression net proving the parser/renderer is
//! innocent across the whole Ink-style redraw pattern space.
//!
//! Pre-flight memory budget: each test creates one or two 80×24 BBTerms
//! (~250-300 KiB each, dominated by the 100-line scrollback) plus a small
//! captured-events Arc. 10 tests, sub-second total runtime, deterministic.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

/// Captured FFI events. The `fatal_payloads` field is the load-bearing
/// one — if `bb_term_input` or `bb_term_take_snapshot` panics inside
/// `guard_with_term`, BBCore synthesises a `Fatal` event and returns the
/// fallback (null/unit) silently. Without capturing and asserting on
/// fatals, a real parser bug would slip past the cell-grid checks here
/// because the snapshot would just be the previous frame's content.
/// `pty_writes` is captured so redraw-only tests can assert nothing went
/// back to the shell — these tests feed no query bytes, so any PtyWrite
/// is a regression.
#[derive(Default)]
struct Captured {
    fatal_payloads: Vec<Vec<u8>>,
    pty_writes: Vec<Vec<u8>>,
}

impl Captured {
    /// Move the vecs out, leaving the original empty. Used by the Arc
    /// unwrap fallback in `drive_and_dump` / `run_with_capture`, where the
    /// outer `cap` clone is still live (so `try_unwrap` sees ≥2 strong
    /// refs and the fallback path is the actual happy path, not an edge
    /// case).
    fn take(&mut self) -> Captured {
        Captured {
            fatal_payloads: std::mem::take(&mut self.fatal_payloads),
            pty_writes: std::mem::take(&mut self.pty_writes),
        }
    }
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    let cap = unsafe { &*(ctx as *const Mutex<Captured>) };
    let mut g = cap.lock().unwrap();
    let payload = if !ev.payload.is_null() && ev.len > 0 {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    match ev.kind {
        bc::BBEventKind::Fatal => g.fatal_payloads.push(payload),
        bc::BBEventKind::PtyWrite => g.pty_writes.push(payload),
        _ => {}
    }
}

const COLS: u16 = 80;
const ROWS: u16 = 24;

/// Run `feed_fn` against a fresh 80×24 term, return the cell grid as
/// `Vec<Vec<char>>` indexed `[row][col]`. Asserts no Fatal events fired
/// and no PtyWrite traffic occurred — these tests don't feed query bytes,
/// so either is a regression worth surfacing.
unsafe fn drive_and_dump(feed_fn: impl FnOnce(*mut bc::BBTerm)) -> Vec<Vec<char>> {
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;

    let term = bc::bb_term_new(COLS, ROWS, 100);
    assert!(!term.is_null(), "bb_term_new must succeed for {COLS}×{ROWS}");
    bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);

    feed_fn(term);

    let snap = bc::bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot must succeed");

    let cols = (*snap).cols as usize;
    let rows = (*snap).rows as usize;
    let mut out = Vec::with_capacity(rows);
    for r in 0..rows {
        let mut row = Vec::with_capacity(cols);
        for c in 0..cols {
            let cell = *((*snap).cells.add(r * cols + c));
            let ch = if cell.ch == 0 {
                ' '
            } else {
                char::from_u32(cell.ch).unwrap_or('?')
            };
            row.push(ch);
        }
        out.push(row);
    }
    bc::bb_snap_release(snap);
    bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
    bc::bb_term_free(term);

    // Reclaim the leaked Arc, then move the captured data out. The
    // outer `cap` clone is still in scope at this point, so `try_unwrap`
    // will see ≥2 strong refs and take the fallback path; that path
    // locks the inner mutex, swaps the vecs out, and returns them. Both
    // paths land at a valid `Captured` struct ready to assert on.
    let captured = Arc::try_unwrap(Arc::from_raw(cap_ptr as *const Mutex<Captured>))
        .unwrap_or_else(|arc| Mutex::new(arc.lock().unwrap().take()))
        .into_inner()
        .unwrap();
    assert!(
        captured.fatal_payloads.is_empty(),
        "BBCore fired Fatal during redraw test — parser regression: {:?}",
        captured.fatal_payloads
    );
    assert!(
        captured.pty_writes.is_empty(),
        "redraw-only test must not emit PtyWrite (no query bytes were fed); \
         got {:?}",
        captured.pty_writes
    );

    out
}

fn count_rows_containing(grid: &[Vec<char>], needle: &str) -> usize {
    grid.iter()
        .filter(|row| row.iter().collect::<String>().contains(needle))
        .count()
}

fn dump_grid(grid: &[Vec<char>]) -> String {
    let mut s = String::new();
    for (i, row) in grid.iter().enumerate() {
        let line: String = row.iter().collect();
        s.push_str(&format!("{i:02}|{}|\n", line.trim_end()));
    }
    s
}

unsafe fn feed(term: *mut bc::BBTerm, bytes: &[u8]) {
    bc::bb_term_input(term, bytes.as_ptr(), bytes.len());
}

/// Build a frame string: N "AGENT i" lines + trailing "FOOTER" line, each
/// terminated `\r\n`. No trailing newline after the footer (Ink-style
/// frames typically end without one, leaving the cursor at end-of-footer).
fn frame_text(n_agents: usize) -> Vec<u8> {
    let mut s = String::new();
    for i in 0..n_agents {
        s.push_str(&format!("AGENT {i} running tool things\r\n"));
    }
    s.push_str("FOOTER");
    s.into_bytes()
}

/// `ansi-escapes.eraseLines(N)` byte sequence: for i in 0..N { ESC[2K; if
/// i<N-1 then ESC[1A; }; if N>0 then ESC[G. Used by the eraseLines-style
/// redraw tests to mimic what Ink emits for incremental updates.
fn erase_lines(n: usize) -> Vec<u8> {
    let mut buf: Vec<u8> = Vec::new();
    for i in 0..n {
        buf.extend_from_slice(b"\x1b[2K");
        if i < n - 1 {
            buf.extend_from_slice(b"\x1b[1A");
        }
    }
    if n > 0 {
        buf.extend_from_slice(b"\x1b[G");
    }
    buf
}

// =====================================================================
// 2J full-screen redraw — the canonical Ink emit pattern (per BBCore
// comment in lib.rs:1893). Cursor home + ED-all + reprint should leave
// exactly one frame on the grid regardless of where the frame sits.
// =====================================================================

#[test]
fn ink_2j_redraw_short_frame_no_residue() {
    unsafe {
        let grid = drive_and_dump(|term| {
            // 6 agent rows + footer (7 visible). Three Ink-style redraws.
            feed(term, &frame_text(6));
            for _ in 0..3 {
                feed(term, b"\x1b[H\x1b[2J");
                feed(term, &frame_text(6));
            }
        });
        let footers = count_rows_containing(&grid, "FOOTER");
        assert_eq!(
            footers, 1,
            "Ink-style 2J redraw must leave exactly 1 FOOTER. Got {footers}.\n{}",
            dump_grid(&grid)
        );
    }
}

#[test]
fn ink_2j_redraw_frame_at_viewport_bottom_no_residue() {
    unsafe {
        let grid = drive_and_dump(|term| {
            // 23 agents + footer = 24 rows, fills the 24-row viewport.
            feed(term, &frame_text(23));
            for _ in 0..3 {
                feed(term, b"\x1b[H\x1b[2J");
                feed(term, &frame_text(23));
            }
        });
        let footers = count_rows_containing(&grid, "FOOTER");
        assert_eq!(
            footers, 1,
            "2J redraw at viewport bottom must leave 1 FOOTER. Got {footers}.\n{}",
            dump_grid(&grid)
        );
    }
}

#[test]
fn ink_2j_redraw_oversize_frame_no_visible_residue() {
    unsafe {
        let grid = drive_and_dump(|term| {
            // 30 rows + footer in a 24-row viewport. Each print overflows;
            // the visible bottom is the tail of the frame.
            feed(term, &frame_text(30));
            for _ in 0..3 {
                feed(term, b"\x1b[H\x1b[2J");
                feed(term, &frame_text(30));
            }
        });
        let footers = count_rows_containing(&grid, "FOOTER");
        assert_eq!(
            footers, 1,
            "Oversize-frame redraws must keep visible viewport clean. \
             Got {footers}.\n{}",
            dump_grid(&grid)
        );
    }
}

#[test]
fn ink_2j_redraw_with_trailing_newline_no_residue() {
    unsafe {
        let grid = drive_and_dump(|term| {
            // Frame ends with an extra \r\n that triggers a scroll on each
            // cycle (cursor was at bottom row, \n pushes it past).
            feed(term, &frame_text(23));
            feed(term, b"\r\n");
            for _ in 0..3 {
                feed(term, b"\x1b[H\x1b[2J");
                feed(term, &frame_text(23));
                feed(term, b"\r\n");
            }
        });
        let footers = count_rows_containing(&grid, "FOOTER");
        assert_eq!(
            footers, 1,
            "Trailing-newline scroll case must still leave 1 FOOTER on the \
             visible grid (older copies must scroll into history). Got \
             {footers}.\n{}",
            dump_grid(&grid)
        );
    }
}

// =====================================================================
// eraseLines (ansi-escapes pattern) — Ink's incremental redraw form.
// =====================================================================

#[test]
fn ink_eraselines_redraw_correct_count_no_residue() {
    unsafe {
        let grid = drive_and_dump(|term| {
            // 7-row frame, redraw with eraseLines(7) (correct count).
            feed(term, &frame_text(6));
            for _ in 0..3 {
                feed(term, &erase_lines(7));
                feed(term, &frame_text(6));
            }
        });
        let footers = count_rows_containing(&grid, "FOOTER");
        assert_eq!(
            footers, 1,
            "Correct-count eraseLines must leave 1 FOOTER. Got {footers}.\n{}",
            dump_grid(&grid)
        );
    }
}

// =====================================================================
// Two-segment static + in-place dynamic — mimics Ink's <Static>+<Box>
// shape. Static block above, dynamic footer redrawn in place via
// `\r CSI 2K`.
// =====================================================================

#[test]
fn two_segment_static_above_dynamic_footer_no_leak() {
    unsafe {
        let grid = drive_and_dump(|term| {
            feed(term, b"AGENT 0\r\nAGENT 1\r\nAGENT 2\r\nAGENT 3\r\nAGENT 4\r\nFOOTER");
            // Three redraws of just the footer line: \r → start of line,
            // ESC[2K → erase line, then reprint.
            for _ in 0..3 {
                feed(term, b"\r\x1b[2KFOOTER");
            }
        });
        let footers = count_rows_containing(&grid, "FOOTER");
        assert_eq!(
            footers, 1,
            "Two-segment redraw must leave 1 FOOTER. Got {footers}.\n{}",
            dump_grid(&grid)
        );
    }
}

// =====================================================================
// Pending-wrap (DECAWM) edge case. A line of exactly COLS chars puts
// alacritty in `input_needs_wrap` state. Following \r\n must drop the
// flag without committing the wrap; otherwise the next row is pushed
// down by one and the producer's row math diverges from the grid.
// =====================================================================

#[test]
fn pending_wrap_then_newline_does_not_consume_extra_row() {
    unsafe {
        let grid = drive_and_dump(|term| {
            let row0: Vec<u8> = std::iter::repeat(b'X').take(COLS as usize).collect();
            feed(term, &row0);
            feed(term, b"\r\nMARKER");
        });
        let row0: String = grid[0].iter().collect();
        let row1: String = grid[1].iter().collect();
        let row2: String = grid[2].iter().collect();
        assert!(
            row1.starts_with("MARKER"),
            "MARKER must land on row 1 (pending wrap NOT committed). \
             row0={row0:?} row1={row1:?} row2={row2:?}"
        );
        assert!(
            !row2.starts_with("MARKER"),
            "MARKER must NOT land on row 2 (would mean pending wrap committed). \
             row1={row1:?} row2={row2:?}"
        );
    }
}

// =====================================================================
// Damage-set vs. actual-content divergence. The renderer's partial-
// rebuild fast path (MetalRenderer.swift:1064-1082) trusts alacritty's
// damage set: rows NOT in the set keep last frame's cached glyph
// instances. If alacritty under-reports damage on a row whose content
// actually changed, the renderer paints stale glyphs there.
//
// These tests use the FFI directly (not drive_and_dump) because they
// take multiple snapshots between feeds. Same Fatal/PtyWrite hygiene
// applied via run_with_capture.
// =====================================================================

/// One frame's worth of state: row text + damage info + cursor.
struct Frame {
    rows: Vec<String>,
    damage_full: bool,
    damaged: Vec<u16>,
    #[allow(dead_code)] // Reserved for future cursor-aware tests.
    cursor: (u16, u16),
}

unsafe fn capture_frame(term: *mut bc::BBTerm) -> Frame {
    let snap = bc::bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot must succeed");
    let cols = (*snap).cols as usize;
    let rows = (*snap).rows as usize;
    let mut row_text = Vec::with_capacity(rows);
    for r in 0..rows {
        let mut s = String::with_capacity(cols);
        for c in 0..cols {
            let cell = *((*snap).cells.add(r * cols + c));
            let ch = if cell.ch == 0 {
                ' '
            } else {
                char::from_u32(cell.ch).unwrap_or('?')
            };
            s.push(ch);
        }
        row_text.push(s);
    }
    let damage_full = bc::bb_snap_damage_is_full(snap) != 0;
    let mut buf = vec![0u16; rows];
    let n = bc::bb_snap_damage_rows(snap, buf.as_mut_ptr(), buf.len());
    buf.truncate(n);
    let cursor = ((*snap).cursor_row, (*snap).cursor_col);
    bc::bb_snap_release(snap);
    Frame { rows: row_text, damage_full, damaged: buf, cursor }
}

fn rows_that_actually_changed(a: &Frame, b: &Frame) -> Vec<u16> {
    a.rows
        .iter()
        .zip(b.rows.iter())
        .enumerate()
        .filter(|(_, (x, y))| x != y)
        .map(|(i, _)| i as u16)
        .collect()
}

/// Setup → run body → teardown helper for tests that need multiple
/// snapshots. Mirrors `drive_and_dump`'s Fatal/PtyWrite hygiene.
unsafe fn run_with_capture(body: impl FnOnce(*mut bc::BBTerm)) {
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;

    let term = bc::bb_term_new(COLS, ROWS, 100);
    assert!(!term.is_null(), "bb_term_new must succeed");
    bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);

    body(term);

    bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
    bc::bb_term_free(term);

    // Reclaim the leaked Arc, then move the captured data out. The
    // outer `cap` clone is still in scope at this point, so `try_unwrap`
    // will see ≥2 strong refs and take the fallback path; that path
    // locks the inner mutex, swaps the vecs out, and returns them. Both
    // paths land at a valid `Captured` struct ready to assert on.
    let captured = Arc::try_unwrap(Arc::from_raw(cap_ptr as *const Mutex<Captured>))
        .unwrap_or_else(|arc| Mutex::new(arc.lock().unwrap().take()))
        .into_inner()
        .unwrap();
    assert!(
        captured.fatal_payloads.is_empty(),
        "Fatal fired during damage test: {:?}",
        captured.fatal_payloads
    );
    assert!(
        captured.pty_writes.is_empty(),
        "no PtyWrite expected during damage test: {:?}",
        captured.pty_writes
    );
}

#[test]
fn damage_set_covers_every_changed_row_eraselines_pattern() {
    unsafe {
        run_with_capture(|term| {
            feed(term, &frame_text(5));
            let f0 = capture_frame(term);

            // Frame 1: redraw via eraseLines(6) + same content. Cell content
            // is identical to f0 but cursor moved through erased rows, so
            // alacritty marks them damaged. Pin the partial-damage shape:
            // damage_full must be FALSE here (otherwise the renderer's
            // partial-rebuild fast path would be bypassed and this test is
            // meaningless).
            feed(term, &erase_lines(6));
            feed(term, &frame_text(5));
            let f1 = capture_frame(term);
            assert!(
                !f1.damage_full,
                "eraseLines+reprint must produce partial damage (not full); \
                 if alacritty starts marking this case fully damaged, the \
                 renderer's partial-rebuild path is dead code"
            );
            for &r in &rows_that_actually_changed(&f0, &f1) {
                assert!(
                    f1.damaged.contains(&r),
                    "row {r} content changed between f0 and f1 but is NOT in \
                     damage set {:?} — renderer would paint stale glyphs",
                    f1.damaged
                );
            }

            // Frame 2: GROW the block by one (eraseLines(6) but reprint 7
            // rows). Pin the same partial-damage shape and the damage-
            // covers-changes invariant.
            feed(term, &erase_lines(6));
            feed(term, &frame_text(6));
            let f2 = capture_frame(term);
            assert!(
                !f2.damage_full,
                "eraseLines+grow must produce partial damage; got full"
            );
            for &r in &rows_that_actually_changed(&f1, &f2) {
                assert!(
                    f2.damaged.contains(&r),
                    "row {r} content changed between f1 and f2 but is NOT in \
                     damage set {:?}",
                    f2.damaged
                );
            }
        });
    }
}

#[test]
fn damage_set_covers_every_changed_row_2j_at_viewport_bottom() {
    unsafe {
        run_with_capture(|term| {
            feed(term, &frame_text(23));
            let _f0 = capture_frame(term);

            // 2J marks the entire grid fully damaged in alacritty (see
            // `clear_screen` → `mark_fully_damaged`). Pin that contract: any
            // future change that started reporting partial damage on 2J
            // would alter the renderer's behaviour and this test should
            // fail loudly so that interaction is reviewed deliberately.
            feed(term, b"\x1b[H\x1b[2J");
            feed(term, &frame_text(23));
            let f1 = capture_frame(term);
            assert!(
                f1.damage_full,
                "2J must mark fully damaged; if alacritty changed this, the \
                 renderer's full-rebuild trigger needs review"
            );

            // Same with grown content.
            feed(term, b"\x1b[H\x1b[2J");
            let mut grown = String::new();
            for i in 0..23 {
                grown.push_str(&format!("AGENT {i} running tool things\r\n"));
            }
            grown.push_str("FOOTER_V2");
            feed(term, grown.as_bytes());
            let f2 = capture_frame(term);
            assert!(f2.damage_full, "2J + reprint must mark fully damaged");
        });
    }
}

#[test]
fn renderer_simulation_matches_snapshot_through_growing_redraws() {
    // Reproduce the renderer's partial-rebuild against alacritty's damage
    // set EXACTLY: build a text-cache per row, only rebuild rows in the
    // damage set, then compare the cached text to the ground-truth
    // snapshot content. If any row diverges, the renderer would paint
    // stale glyphs.
    unsafe {
        run_with_capture(|term| {
            let mut row_cache: Vec<String> = vec![String::new(); ROWS as usize];

            let refresh = |term: *mut bc::BBTerm, row_cache: &mut Vec<String>| -> Frame {
                let f = capture_frame(term);
                if f.damage_full {
                    for (i, r) in f.rows.iter().enumerate() {
                        row_cache[i] = r.clone();
                    }
                } else {
                    for &row in &f.damaged {
                        let r = row as usize;
                        if r < f.rows.len() {
                            row_cache[r] = f.rows[r].clone();
                        }
                    }
                }
                f
            };

            feed(term, &frame_text(5));
            let f = refresh(term, &mut row_cache);
            for (i, gt) in f.rows.iter().enumerate() {
                assert_eq!(row_cache[i], *gt, "cycle 0 row {i} divergence");
            }

            // 5 cycles, each growing the frame by one row while the
            // producer (intentionally) miscounts and erases only 6 rows.
            for cycle in 1..=5 {
                let agents = 5 + cycle;
                feed(term, &erase_lines(6));
                feed(term, &frame_text(agents));
                let f = refresh(term, &mut row_cache);
                for (i, gt) in f.rows.iter().enumerate() {
                    assert_eq!(
                        row_cache[i], *gt,
                        "cycle {cycle} row {i}: cache={:?} snapshot={:?} \
                         damage_full={} damaged={:?}",
                        row_cache[i], gt, f.damage_full, f.damaged
                    );
                }
            }
        });
    }
}
