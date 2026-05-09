//! VT-100 / 220 / 420 conformance harness — Blackbird's first dedicated
//! conformance suite. Peers (kitty, foot) drive vttest / esctest.py against
//! a real terminal binary; we don't have one to drive (BBCore is a library,
//! not a binary), so this file mirrors esctest.py's *intent* — a single
//! known-good escape sequence per test, with a single observable assertion
//! about grid state or PTY reply — using the same FFI surface other
//! integration tests use.
//!
//! Coverage groups (matching the task plan):
//!   A — DEC private mode set/reset round-trips (10 modes)
//!   B — Cursor positioning (CUU/CUD/CUF/CUB/CNL/CPL/CHA/CUP/HVP/VPA)
//!   C — Erase variants (ED 0/1/2/3, EL 0/1/2, DECSED)
//!   D — Scroll region / SU / SD / IL / DL
//!   E — Save / restore cursor (DECSC/DECRC, SCO save/restore)
//!   F — IND / RI / NEL (ESC D / ESC M / ESC E)
//!   G — Common SGR variants pinning
//!   H — DSR / DA replies
//!
//! Pin policy: each test asserts Blackbird's *current* contract (alacritty
//! 0.26 + Blackbird's wrappers), not "xterm-perfect". Where alacritty
//! diverges from xterm — DECCOLM ignored, DECARM stubbed, ED 3 may not
//! erase scrollback — the divergence is documented inline as a `PINNED
//! divergence` comment so a future spec-driven refactor knows which
//! invariants are policy and which are accidents.
//!
//! Pre-flight cost: ~50 tests × 24×80 grid (~250 KB each) × small feeds
//! → ~12 MB peak resident if all parallel, well under budget. Single-
//! threaded fine; <2 s wall-clock.
//!
//! Provenance: tests written against publicly-documented spec sequences
//! (xterm ctlseqs, DEC STD 070), then ran against the current FFI to pin
//! the answer. Where the FFI doesn't expose enough state to assert the
//! invariant cleanly (DECARM, DECSED, true reverse-video grid pixels),
//! the test is annotated `PINNED gap` rather than asserting on stale or
//! synthetic data.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

// ---------------------------------------------------------------------------
// Shared scaffolding
// ---------------------------------------------------------------------------

const COLS: u16 = 80;
const ROWS: u16 = 24;
const SCROLLBACK: u32 = 100;

/// Captured PtyWrite payloads from the registered callback. Used by
/// Group H (reply-shape assertions) and a couple of Group A tests that
/// also probe DECRQM round-trips. Mirror of the pattern in
/// `terminal_replies.rs`.
#[derive(Default)]
struct Captured {
    pty_writes: Vec<Vec<u8>>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    if ev.kind as u32 != bc::BBEventKind::PtyWrite as u32 {
        return;
    }
    if ev.payload.is_null() || ev.len == 0 {
        return;
    }
    let cap = &*(ctx as *const Mutex<Captured>);
    let bytes = std::slice::from_raw_parts(ev.payload, ev.len);
    cap.lock().unwrap().pty_writes.push(bytes.to_vec());
}

/// Allocate a fresh terminal at the conformance default size. All Group
/// A-G tests use this; Group H tests use `setup_term_with_capture` so
/// they can drain the PtyWrite channel.
unsafe fn setup_term(cols: u16, rows: u16, scrollback: u32) -> *mut bc::BBTerm {
    let term = bc::bb_term_new(cols, rows, scrollback);
    assert!(
        !term.is_null(),
        "bb_term_new({cols},{rows},{scrollback}) must succeed"
    );
    term
}

/// Allocate a terminal and register the PtyWrite-capture callback. The
/// returned tuple is `(term, capture_arc, leaked_ptr)` — caller must call
/// `teardown_term_with_capture` to drop the term, unhook the callback,
/// and reclaim the leaked Arc.
unsafe fn setup_term_with_capture() -> (*mut bc::BBTerm, Arc<Mutex<Captured>>, *mut c_void) {
    let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
    let cap_ptr = Arc::into_raw(cap.clone()) as *mut c_void;
    let term = setup_term(COLS, ROWS, SCROLLBACK);
    bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ptr);
    (term, cap, cap_ptr)
}

unsafe fn teardown_term_with_capture(term: *mut bc::BBTerm, cap_ptr: *mut c_void) {
    bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
    bc::bb_term_free(term);
    drop(Arc::from_raw(cap_ptr as *const Mutex<Captured>));
}

unsafe fn feed(term: *mut bc::BBTerm, bytes: &[u8]) {
    bc::bb_term_input(term, bytes.as_ptr(), bytes.len());
}

/// Take a snapshot, return its mode word. Releases the snapshot before
/// returning so callers don't have to.
unsafe fn snap_mode(term: *mut bc::BBTerm) -> u32 {
    let snap = bc::bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot must succeed");
    let m = (*snap).mode;
    bc::bb_snap_release(snap);
    m
}

/// Take a snapshot, return `(cursor_row, cursor_col)` 0-indexed (matching
/// alacritty's internal convention; spec-side CUP rows/cols are 1-indexed,
/// so a CUP 5;7 lands the cursor at internal (4, 6)). Releases the snap.
unsafe fn snap_cursor(term: *mut bc::BBTerm) -> (u16, u16) {
    let snap = bc::bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot must succeed");
    let rc = ((*snap).cursor_row, (*snap).cursor_col);
    bc::bb_snap_release(snap);
    rc
}

/// Read the visible characters of `row` from a snapshot. Empty cells
/// (`ch == 0`) become spaces. Used by Group C (erase) and Group D
/// (scroll) assertions.
unsafe fn read_row_chars(term: *mut bc::BBTerm, row: u16) -> String {
    let snap = bc::bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot must succeed");
    let s = &*snap;
    let cols = s.cols as usize;
    let start = (row as usize) * cols;
    let mut out = String::with_capacity(cols);
    for i in 0..cols {
        let cell = *s.cells.add(start + i);
        if cell.ch == 0 {
            out.push(' ');
        } else {
            out.push(char::from_u32(cell.ch).unwrap_or('?'));
        }
    }
    bc::bb_snap_release(snap);
    out
}

/// Read the SGR flags of cell at `(row, col)`. Group G (SGR) uses this.
unsafe fn snap_cell_flags(term: *mut bc::BBTerm, row: u16, col: u16) -> u16 {
    let snap = bc::bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot must succeed");
    let s = &*snap;
    let cols = s.cols as usize;
    let cell = *s.cells.add((row as usize) * cols + col as usize);
    let flags = cell.flags;
    bc::bb_snap_release(snap);
    flags
}

/// Read the FG colour of cell at `(row, col)`. Group G uses this for
/// 256-colour and direct-colour pinning.
unsafe fn snap_cell_fg(term: *mut bc::BBTerm, row: u16, col: u16) -> u32 {
    let snap = bc::bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot must succeed");
    let s = &*snap;
    let cols = s.cols as usize;
    let cell = *s.cells.add((row as usize) * cols + col as usize);
    let fg = cell.fg;
    bc::bb_snap_release(snap);
    fg
}

// ===========================================================================
// Group A — DEC private mode set/reset round-trips
// ===========================================================================
//
// For every mode tracked by `bb_mode::*`, fire `\x1b[?<n>h` and assert the
// mode bit lights, then `\x1b[?<n>l` and assert it clears. Modes that
// alacritty stubs (DECARM, DECCOLM, DECSCNM) or doesn't surface
// (DECOM origin) are pinned via cursor-position or DECRQM round-trip
// instead.

#[test]
fn deccm_decckm_app_cursor_round_trip() {
    // DECCKM (?1) — application cursor keys mode. Snapshot exposes this
    // as bb_mode::APP_CURSOR.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[?1h");
        assert_ne!(
            snap_mode(term) & bc::bb_mode::APP_CURSOR,
            0,
            "DECSET ?1h must light APP_CURSOR"
        );
        feed(term, b"\x1b[?1l");
        assert_eq!(
            snap_mode(term) & bc::bb_mode::APP_CURSOR,
            0,
            "DECRST ?1l must clear APP_CURSOR"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn deccolm_3_is_ignored_pinned_divergence() {
    // PINNED divergence: DECCOLM (?3) on xterm switches the screen to
    // 132 cols. alacritty 0.26 declines to honor it (would resize the
    // grid mid-stream, which Blackbird drives via TIOCSWINSZ instead).
    // The DECRQM reply for ?3 is "0" (NotSupported); the cols stay at
    // whatever the host requested. Pin both signals.
    unsafe {
        let (term, cap, cap_ptr) = setup_term_with_capture();
        feed(term, b"\x1b[?3h");
        // Cols unchanged.
        let snap = bc::bb_term_take_snapshot(term);
        assert_eq!(
            (*snap).cols,
            COLS,
            "DECCOLM must NOT change column count (alacritty 0.26 ignores ?3h)"
        );
        bc::bb_snap_release(snap);
        // DECRQM reply confirms NotSupported.
        feed(term, b"\x1b[?3$p");
        let writes = cap.lock().unwrap().pty_writes.clone();
        assert_eq!(
            writes,
            vec![b"\x1b[?3;0$y".to_vec()],
            "DECCOLM (?3) DECRQM must reply '0' (NotSupported); got {:?}",
            writes
        );
        teardown_term_with_capture(term, cap_ptr);
    }
}

#[test]
fn decscnm_5_reverse_video_pinned_divergence() {
    // PINNED divergence: DECSCNM (?5) reverse video is not in alacritty
    // 0.26's NamedPrivateMode table — the DECRQM reply is "0" (NotRecognized),
    // and BBSnap.mode does not expose a REVERSE_VIDEO bit. The renderer
    // treats reverse video as a per-cell SGR flag, not a screen-wide
    // mode, so the gap is intentional. Pin both signals so a future
    // alacritty bump that adds DECSCNM as a named mode (and would change
    // the DECRQM reply to '1' or '2') fails this test loudly and the
    // renderer's reverse-video handling can be reviewed.
    unsafe {
        let (term, cap, cap_ptr) = setup_term_with_capture();
        feed(term, b"\x1b[?5$p");
        let writes_initial = cap.lock().unwrap().pty_writes.clone();
        assert_eq!(
            writes_initial,
            vec![b"\x1b[?5;0$y".to_vec()],
            "DECSCNM ?5 must reply '0' (NotRecognized) on alacritty 0.26 — \
             a reply of '1' or '2' means DECSCNM was added to the named-mode \
             table and the renderer's reverse-video gap must be reviewed; \
             got {:?}",
            writes_initial
        );
        teardown_term_with_capture(term, cap_ptr);
    }
}

#[test]
fn decom_6_origin_mode_round_trip_via_cursor_position() {
    // DECOM (?6) is not surfaced through BBSnap.mode either. Origin
    // mode's observable effect is that subsequent CUP rows are
    // interpreted relative to the scroll region instead of absolute.
    // Pin via behaviour: DECSTBM 5;10, DECOM on, CUP 1;1 → cursor must
    // land at row index 4 (1-indexed row 5 absolute = row 1 relative).
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        // Set scroll region rows 5-10 (1-indexed), enable origin.
        feed(term, b"\x1b[5;10r\x1b[?6h\x1b[1;1H");
        let (r, c) = snap_cursor(term);
        assert_eq!(
            (r, c),
            (4, 0),
            "DECOM on + CUP 1;1 must land at scroll-region top (row 4 absolute); got ({r},{c})"
        );
        // Disable origin, CUP 1;1 → absolute (0,0).
        feed(term, b"\x1b[?6l\x1b[1;1H");
        let (r2, c2) = snap_cursor(term);
        assert_eq!(
            (r2, c2),
            (0, 0),
            "DECOM off + CUP 1;1 must land at absolute (0,0); got ({r2},{c2})"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn decawm_7_auto_wrap_round_trip() {
    // DECAWM (?7) — auto-wrap. Default ON. Pin both directions via
    // bb_mode::LINE_WRAP.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        assert_ne!(
            snap_mode(term) & bc::bb_mode::LINE_WRAP,
            0,
            "DECAWM must default ON"
        );
        feed(term, b"\x1b[?7l");
        assert_eq!(
            snap_mode(term) & bc::bb_mode::LINE_WRAP,
            0,
            "DECRST ?7l must clear LINE_WRAP"
        );
        feed(term, b"\x1b[?7h");
        assert_ne!(
            snap_mode(term) & bc::bb_mode::LINE_WRAP,
            0,
            "DECSET ?7h must re-light LINE_WRAP"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn decarm_8_auto_repeat_pinned_gap_no_state_exposed() {
    // PINNED gap: DECARM (?8) auto-repeat is parsed by alacritty but
    // there is no observable side-effect — alacritty doesn't keep an
    // auto-repeat policy and DECRQM ?8 is not in the named-mode table.
    // The most we can pin is "DECRQM replies '0' (NotRecognized)" so
    // a future change that started honouring auto-repeat fails this
    // test loudly. This matches the spec's "if not implemented, reply
    // 0" contract.
    unsafe {
        let (term, cap, cap_ptr) = setup_term_with_capture();
        feed(term, b"\x1b[?8$p");
        let writes = cap.lock().unwrap().pty_writes.clone();
        assert_eq!(
            writes,
            vec![b"\x1b[?8;0$y".to_vec()],
            "DECARM ?8 DECRQM must reply '0' (NotRecognized) on alacritty 0.26; \
             a non-zero reply means auto-repeat was implemented and this test \
             needs review; got {:?}",
            writes
        );
        teardown_term_with_capture(term, cap_ptr);
    }
}

#[test]
fn dectcem_25_show_cursor_round_trip() {
    // DECTCEM (?25) — show cursor. Default ON.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        assert_ne!(
            snap_mode(term) & bc::bb_mode::SHOW_CURSOR,
            0,
            "DECTCEM must default ON"
        );
        feed(term, b"\x1b[?25l");
        assert_eq!(
            snap_mode(term) & bc::bb_mode::SHOW_CURSOR,
            0,
            "DECRST ?25l must clear SHOW_CURSOR"
        );
        feed(term, b"\x1b[?25h");
        assert_ne!(
            snap_mode(term) & bc::bb_mode::SHOW_CURSOR,
            0,
            "DECSET ?25h must re-light SHOW_CURSOR"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn alt_screen_47_legacy_pinned_divergence() {
    // PINNED divergence: legacy DECSET ?47h — older vim/emacs occasionally
    // emit this. alacritty 0.26 ignores it (no save, no swap, no
    // ALT_SCREEN bit). Pin the no-op so a future alacritty upgrade that
    // started honouring 47h fails loudly and the alt-screen-isolation
    // tests can be reviewed accordingly.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[?47h");
        assert_eq!(
            snap_mode(term) & bc::bb_mode::ALT_SCREEN,
            0,
            "alacritty 0.26 ignores ?47h — ALT_SCREEN must NOT light. \
             A change here means legacy ?47h was implemented and the \
             alt-screen-isolation tests should be reviewed."
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn alt_screen_1049_xterm_round_trip() {
    // DECSET ?1049 — modern alt-screen-with-save (vim/less/htop). Round-trip.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        assert_eq!(
            snap_mode(term) & bc::bb_mode::ALT_SCREEN,
            0,
            "alt screen starts disabled"
        );
        feed(term, b"\x1b[?1049h");
        assert_ne!(
            snap_mode(term) & bc::bb_mode::ALT_SCREEN,
            0,
            "DECSET ?1049h must light ALT_SCREEN"
        );
        feed(term, b"\x1b[?1049l");
        assert_eq!(
            snap_mode(term) & bc::bb_mode::ALT_SCREEN,
            0,
            "DECRST ?1049l must clear ALT_SCREEN"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn bracketed_paste_2004_round_trip() {
    // DECSET ?2004 — bracketed paste. Round-trip via bb_mode::BRACKETED_PASTE.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[?2004h");
        assert_ne!(
            snap_mode(term) & bc::bb_mode::BRACKETED_PASTE,
            0,
            "DECSET ?2004h must light BRACKETED_PASTE"
        );
        feed(term, b"\x1b[?2004l");
        assert_eq!(
            snap_mode(term) & bc::bb_mode::BRACKETED_PASTE,
            0,
            "DECRST ?2004l must clear BRACKETED_PASTE"
        );
        bc::bb_term_free(term);
    }
}

// ===========================================================================
// Group B — Cursor positioning
// ===========================================================================
//
// Each test places the cursor at a known location, fires the sequence,
// and asserts the resulting cursor row/col. Coordinates in BBSnap are
// 0-indexed; CSI sequences are 1-indexed, so CUP 5;7 → snap (4, 6).

#[test]
fn cuu_cursor_up_clamps_at_row_0() {
    // CUU `\x1b[<n>A` — up. From row 0, must NOT go negative; clamps at row 0.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        // Place cursor at row 5 absolute, then move up 3.
        feed(term, b"\x1b[6;1H\x1b[3A");
        assert_eq!(snap_cursor(term), (2, 0), "CUU 3 from row 5 → row 2");
        // Move up 100 — must clamp to row 0.
        feed(term, b"\x1b[100A");
        assert_eq!(snap_cursor(term), (0, 0), "CUU 100 must clamp to row 0");
        bc::bb_term_free(term);
    }
}

#[test]
fn cud_cursor_down_clamps_at_last_row() {
    // CUD `\x1b[<n>B` — down. From last row, must NOT go past the grid.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        // Place cursor at row 0, then move down 5.
        feed(term, b"\x1b[1;1H\x1b[5B");
        assert_eq!(snap_cursor(term), (5, 0), "CUD 5 from row 0 → row 5");
        // Move down 1000 — must clamp to last row (ROWS - 1 = 23).
        feed(term, b"\x1b[1000B");
        assert_eq!(
            snap_cursor(term),
            (ROWS - 1, 0),
            "CUD 1000 must clamp to last row"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn cuf_cursor_forward_clamps_at_last_col() {
    // CUF `\x1b[<n>C` — right. Clamps at last col.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[1;1H\x1b[5C");
        assert_eq!(snap_cursor(term), (0, 5), "CUF 5 → col 5");
        feed(term, b"\x1b[10000C");
        assert_eq!(
            snap_cursor(term),
            (0, COLS - 1),
            "CUF 10000 must clamp to last col ({})",
            COLS - 1
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn cub_cursor_backward_clamps_at_col_0() {
    // CUB `\x1b[<n>D` — left. Clamps at col 0.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[1;10H\x1b[3D");
        assert_eq!(snap_cursor(term), (0, 6), "CUB 3 from col 9 → col 6");
        feed(term, b"\x1b[1000D");
        assert_eq!(snap_cursor(term), (0, 0), "CUB 1000 must clamp to col 0");
        bc::bb_term_free(term);
    }
}

#[test]
fn cnl_next_line_moves_down_and_resets_col() {
    // CNL `\x1b[<n>E` — down N rows, col = 0 (unlike CUD which preserves col).
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[1;15H\x1b[3E");
        assert_eq!(
            snap_cursor(term),
            (3, 0),
            "CNL 3 from (0,14) must land at (3, 0)"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn cpl_previous_line_moves_up_and_resets_col() {
    // CPL `\x1b[<n>F` — up N rows, col = 0.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[10;15H\x1b[3F");
        assert_eq!(
            snap_cursor(term),
            (6, 0),
            "CPL 3 from (9,14) must land at (6, 0)"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn cha_column_absolute_moves_within_row() {
    // CHA `\x1b[<n>G` — absolute column on same row.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[5;1H\x1b[20G");
        assert_eq!(
            snap_cursor(term),
            (4, 19),
            "CHA 20 from row 5 must land at (4, 19)"
        );
        // CHA 0 / missing → defaults to col 1 (per vte's next_param_or(1)).
        feed(term, b"\x1b[G");
        assert_eq!(
            snap_cursor(term),
            (4, 0),
            "CHA missing-param must default to col 1 (snap col 0)"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn cup_position_with_args_lands_correctly() {
    // CUP `\x1b[<r>;<c>H` — primary positioning. 1-indexed.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[10;25H");
        assert_eq!(
            snap_cursor(term),
            (9, 24),
            "CUP 10;25 must land at (9, 24)"
        );
        // Missing args → defaults (1;1) per spec.
        feed(term, b"\x1b[H");
        assert_eq!(
            snap_cursor(term),
            (0, 0),
            "CUP missing-args must default to (1, 1) → (0, 0)"
        );
        // Out-of-range args clamp to grid bounds.
        feed(term, b"\x1b[1000;1000H");
        assert_eq!(
            snap_cursor(term),
            (ROWS - 1, COLS - 1),
            "CUP 1000;1000 must clamp to last row/col"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn hvp_position_alias_of_cup() {
    // HVP `\x1b[<r>;<c>f` — synonym for CUP. The spec keeps both for
    // backward-compatibility with VT52. They MUST be exact aliases.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[7;13f");
        assert_eq!(
            snap_cursor(term),
            (6, 12),
            "HVP 7;13 must match CUP 7;13: (6, 12)"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn vpa_line_absolute_moves_within_column() {
    // VPA `\x1b[<n>d` — absolute row, same col.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[1;15H\x1b[10d");
        assert_eq!(
            snap_cursor(term),
            (9, 14),
            "VPA 10 from col 15 must land at (9, 14)"
        );
        // VPA missing → defaults to row 1.
        feed(term, b"\x1b[d");
        assert_eq!(
            snap_cursor(term),
            (0, 14),
            "VPA missing-param must default to row 1 (snap row 0)"
        );
        bc::bb_term_free(term);
    }
}

// ===========================================================================
// Group C — Erase variants
// ===========================================================================
//
// Each test seeds the grid with a known pattern, places the cursor
// somewhere predictable, fires the erase, and asserts which cells are
// blank. We use single-row patterns where possible to keep assertions
// terse.

/// Seed the grid with N rows of "ABCDE...." (78 chars from 'A' onward,
/// then ' ', ' '). All rows identical so we can detect partial erasure
/// by comparing row content. Cursor is left at end-of-line on the last
/// seeded row.
unsafe fn seed_grid(term: *mut bc::BBTerm, rows: u16) {
    for r in 0..rows {
        let goto = format!("\x1b[{};1H", r + 1);
        feed(term, goto.as_bytes());
        // 78 distinct chars + 2 trailing spaces (so the row ends in
        // spaces, helping us tell "erased" from "filled with content").
        let mut line = String::with_capacity(80);
        for i in 0..78 {
            line.push(char::from_u32(b'A' as u32 + (i as u32 % 26)).unwrap());
        }
        line.push(' ');
        line.push(' ');
        feed(term, line.as_bytes());
    }
}

#[test]
fn ed_0_erase_cursor_to_end_clears_below() {
    // ED 0 (`\x1b[J` or `\x1b[0J`): erase from cursor (inclusive) to
    // end of screen. Rows above cursor untouched; cursor's row is
    // erased from cursor col onward; rows below are blanked.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, ROWS);
        // Place cursor at row 12 col 40, then ED 0.
        feed(term, b"\x1b[12;40H\x1b[J");
        // Row 0 untouched (full content).
        assert!(
            read_row_chars(term, 0).starts_with("ABCDE"),
            "row 0 must be untouched by ED 0"
        );
        // Row 11 (cursor's row, 1-indexed 12) — first 39 chars kept,
        // remainder blanked.
        let row11 = read_row_chars(term, 11);
        assert!(
            row11.starts_with("ABCDEFGHIJ"),
            "row 11 first 10 chars kept; got {row11:?}"
        );
        assert_eq!(
            &row11.as_bytes()[39..],
            &b" ".repeat((COLS - 39) as usize)[..],
            "row 11 cells from cursor (col 39) onward must be blank"
        );
        // Row 12 (below cursor) fully blank.
        assert_eq!(
            read_row_chars(term, 12),
            " ".repeat(COLS as usize),
            "row 12 must be entirely blank after ED 0"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn ed_1_erase_start_to_cursor_clears_above() {
    // ED 1 (`\x1b[1J`): erase from start of screen to cursor (inclusive).
    // Rows above cursor blanked; cursor's row blanked up to cursor col;
    // rows below untouched.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, ROWS);
        feed(term, b"\x1b[12;40H\x1b[1J");
        // Row 0 blanked.
        assert_eq!(
            read_row_chars(term, 0),
            " ".repeat(COLS as usize),
            "row 0 must be blank after ED 1"
        );
        // Row 11 first 40 cols (0..=39 inclusive) blanked, remainder kept.
        let row11 = read_row_chars(term, 11);
        assert_eq!(
            &row11.as_bytes()[..40],
            &b" ".repeat(40)[..],
            "row 11 cols 0..40 must be blank after ED 1"
        );
        assert!(
            row11.as_bytes()[40] != b' ',
            "row 11 col 40 must still hold seed content; got {row11:?}"
        );
        // Row 12 untouched.
        assert!(
            read_row_chars(term, 12).starts_with("ABCDE"),
            "row 12 must be untouched by ED 1"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn ed_2_erase_whole_screen() {
    // ED 2 (`\x1b[2J`): blank every row in the visible viewport.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, ROWS);
        feed(term, b"\x1b[2J");
        for r in 0..ROWS {
            assert_eq!(
                read_row_chars(term, r),
                " ".repeat(COLS as usize),
                "row {r} must be blank after ED 2"
            );
        }
        bc::bb_term_free(term);
    }
}

#[test]
fn ed_3_erase_scrollback_xterm_extension() {
    // ED 3 (`\x1b[3J`): xterm extension — erase scrollback. alacritty
    // 0.26 implements this as `clear_screen(All)` which clears both
    // visible + scrollback. Pin: history_size must drop to 0 after
    // ED 3 even when scrollback was populated.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        // Push 50 lines into scrollback by feeding 50 newlines after seeding.
        for _ in 0..50 {
            feed(term, b"line\r\n");
        }
        let snap = bc::bb_term_take_snapshot(term);
        let hist_before = (*snap).history_size;
        bc::bb_snap_release(snap);
        assert!(
            hist_before > 0,
            "precondition: scrollback must be populated; got history_size = {hist_before}"
        );
        feed(term, b"\x1b[3J");
        let snap = bc::bb_term_take_snapshot(term);
        let hist_after = (*snap).history_size;
        bc::bb_snap_release(snap);
        assert_eq!(
            hist_after, 0,
            "ED 3 must clear scrollback (history_size 0); got {hist_after} \
             (alacritty 0.26 wires ED 3 to clear_screen(All))"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn el_0_erase_cursor_to_eol() {
    // EL 0 (`\x1b[K` or `\x1b[0K`): erase line from cursor to end of line.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, 5);
        feed(term, b"\x1b[3;40H\x1b[K");
        let row2 = read_row_chars(term, 2);
        assert!(
            row2.starts_with("ABCDE"),
            "row 2 prefix preserved by EL 0"
        );
        assert_eq!(
            &row2.as_bytes()[39..],
            &b" ".repeat((COLS - 39) as usize)[..],
            "row 2 from cursor col onward must be blank"
        );
        // Adjacent rows untouched.
        assert!(
            read_row_chars(term, 1).starts_with("ABCDE"),
            "row 1 untouched"
        );
        assert!(
            read_row_chars(term, 3).starts_with("ABCDE"),
            "row 3 untouched"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn el_1_erase_bol_to_cursor() {
    // EL 1 (`\x1b[1K`): erase from beginning of line to cursor (inclusive).
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, 5);
        feed(term, b"\x1b[3;40H\x1b[1K");
        let row2 = read_row_chars(term, 2);
        assert_eq!(
            &row2.as_bytes()[..40],
            &b" ".repeat(40)[..],
            "row 2 cols 0..40 blanked by EL 1"
        );
        assert!(
            row2.as_bytes()[40] != b' ',
            "row 2 col 40 must still hold seed content"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn el_2_erase_whole_line() {
    // EL 2 (`\x1b[2K`): erase entire line.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, 5);
        feed(term, b"\x1b[3;40H\x1b[2K");
        assert_eq!(
            read_row_chars(term, 2),
            " ".repeat(COLS as usize),
            "row 2 must be entirely blank after EL 2"
        );
        // Other rows untouched.
        assert!(
            read_row_chars(term, 1).starts_with("ABCDE"),
            "row 1 untouched"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn dec_selective_erase_ed_pinned_divergence() {
    // PINNED divergence: DECSED `\x1b[?<n>J` (selective erase, DEC private)
    // erases only "non-protected" cells in xterm. alacritty 0.26 does not
    // implement DECSED at all — the `?` private-flag form is silently
    // dropped without degrading to plain ED. So a `\x1b[?2J` with a fully
    // seeded grid leaves the grid UNCHANGED. Pin that no-op so a future
    // alacritty change that started honouring DECSED (either with full
    // protected-cell semantics, or as a degraded ED-alias) fails loudly.
    //
    // Real-world impact: vim's :set selection=exclusive emits
    // ESC[?<n>J in some configs; on alacritty/Blackbird those are
    // currently silent no-ops. TUIs that rely on selective erase (very
    // few in practice) will see stale content.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, 5);
        feed(term, b"\x1b[?2J");
        // Every seeded row must remain INTACT — alacritty drops `?2J`.
        for r in 0..5 {
            let row = read_row_chars(term, r);
            assert!(
                row.starts_with("ABCDE"),
                "DECSED 2 (`\\x1b[?2J`) must be a no-op on alacritty 0.26; \
                 row {r} = {row:?} (a blanked row means DECSED was implemented \
                 and the test needs review)"
            );
        }
        bc::bb_term_free(term);
    }
}

// ===========================================================================
// Group D — Scroll region
// ===========================================================================
//
// DECSTBM defines a top/bottom margin pair; SU/SD shift the region; IL/DL
// insert/delete lines within the region.

#[test]
fn decstbm_set_region_then_scroll_up_within_region() {
    // DECSTBM `\x1b[<top>;<bottom>r`: set scrolling region. Combined with
    // SU `\x1b[<n>S`: scroll the contents of the region up. Rows outside
    // the region are NOT affected.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, ROWS);
        // Region rows 5-10 (1-indexed). SU 1: row 5's content lost; rows
        // 6-10 each shift up by one; row 10 becomes blank.
        feed(term, b"\x1b[5;10r\x1b[5;1H\x1b[1S");
        // Row outside region (above) untouched.
        assert!(
            read_row_chars(term, 0).starts_with("ABCDE"),
            "row 0 (above region) untouched"
        );
        // Row 11 (below region in 1-indexed terms — rows 0-9 here) untouched.
        // Region in 0-indexed is rows 4..=9. Row 10 is below.
        assert!(
            read_row_chars(term, 10).starts_with("ABCDE"),
            "row 10 (below region) untouched"
        );
        // Last row of region (0-indexed row 9) must be blank — content shifted up.
        assert_eq!(
            read_row_chars(term, 9),
            " ".repeat(COLS as usize),
            "last row of scroll region must be blank after SU 1"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn su_scroll_up_full_screen_no_region() {
    // SU `\x1b[<n>S`: with no prior DECSTBM, the whole grid is the
    // region. Scrolling up by 1 pushes row 0 into scrollback and blanks
    // the bottom row.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, ROWS);
        feed(term, b"\x1b[1S");
        // Row 0 used to hold seed content; now holds row 1's seed (which
        // is identical to row 0's seed in our seeding). The MEANINGFUL
        // assertion is that the BOTTOM row is now blank.
        assert_eq!(
            read_row_chars(term, ROWS - 1),
            " ".repeat(COLS as usize),
            "bottom row must be blank after SU 1 with no region"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn sd_scroll_down_within_region() {
    // SD `\x1b[<n>T`: scroll region down. Top row of region becomes blank.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, ROWS);
        // Region rows 5-10 (1-indexed → 0-indexed 4..=9). SD 1: row 9
        // content lost; rows 4-8 shift down; row 4 becomes blank.
        feed(term, b"\x1b[5;10r\x1b[1T");
        assert_eq!(
            read_row_chars(term, 4),
            " ".repeat(COLS as usize),
            "first row of region must be blank after SD 1"
        );
        // Outside region untouched.
        assert!(
            read_row_chars(term, 0).starts_with("ABCDE"),
            "row 0 (above region) untouched"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn il_insert_lines_at_cursor_within_region() {
    // IL `\x1b[<n>L`: insert N blank lines at the cursor. Existing content
    // shifts down; bottom-most lines fall off the region.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, ROWS);
        // Cursor at row 5 (1-indexed) within region 5;10. IL 2.
        feed(term, b"\x1b[5;10r\x1b[5;1H\x1b[2L");
        // Row 4 (cursor row in 0-indexed) must be blank.
        assert_eq!(
            read_row_chars(term, 4),
            " ".repeat(COLS as usize),
            "row 4 (cursor's row) must be blank after IL 2"
        );
        assert_eq!(
            read_row_chars(term, 5),
            " ".repeat(COLS as usize),
            "row 5 (cursor's row + 1) must also be blank after IL 2"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn dl_delete_lines_at_cursor_within_region() {
    // DL `\x1b[<n>M`: delete N lines at the cursor. Lines below shift up;
    // bottom of region becomes blank.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, ROWS);
        feed(term, b"\x1b[5;10r\x1b[5;1H\x1b[2M");
        // Bottom of region (row 9 0-indexed) must be blank.
        assert_eq!(
            read_row_chars(term, 9),
            " ".repeat(COLS as usize),
            "bottom of region must be blank after DL 2"
        );
        // Row 8 must also be blank (2 lines deleted from top).
        assert_eq!(
            read_row_chars(term, 8),
            " ".repeat(COLS as usize),
            "second-from-bottom must also be blank"
        );
        bc::bb_term_free(term);
    }
}

// ===========================================================================
// Group E — Save / restore cursor
// ===========================================================================
//
// DECSC/DECRC (ESC 7 / ESC 8) and ANSI SCO (`\x1b[s` / `\x1b[u`) both save
// and restore cursor position. DECSC additionally saves SGR/charset state;
// SCO is position-only. We pin the position-only intersection here; the
// SGR-state half is covered by `tui_rendering_robustness.rs`.

#[test]
fn decsc_decrc_round_trip_position() {
    // ESC 7 saves cursor; ESC 8 restores. Positions must match after a
    // round-trip even when intermediate moves happen.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[10;20H");
        feed(term, b"\x1b7"); // DECSC
        // Move somewhere else.
        feed(term, b"\x1b[1;1H");
        assert_eq!(snap_cursor(term), (0, 0), "moved to (0,0) before restore");
        feed(term, b"\x1b8"); // DECRC
        assert_eq!(
            snap_cursor(term),
            (9, 19),
            "DECRC must restore to saved position (10;20 → snap (9, 19))"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn decrc_without_decsc_falls_back_to_origin() {
    // DECRC with no prior DECSC — alacritty's saved state is initialised
    // to (0, 0), so DECRC moves the cursor to home. Pin: this is the
    // current contract (xterm does the same).
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[10;20H");
        feed(term, b"\x1b8");
        assert_eq!(
            snap_cursor(term),
            (0, 0),
            "DECRC with no DECSC must restore to home (0, 0); got {:?}",
            snap_cursor(term)
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn sco_save_restore_position() {
    // ANSI SCO `\x1b[s` save / `\x1b[u` restore — alacritty implements
    // these as aliases for DECSC/DECRC for cursor position.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[7;13H");
        feed(term, b"\x1b[s"); // SCO save
        feed(term, b"\x1b[24;80H");
        assert_eq!(
            snap_cursor(term),
            (23, 79),
            "moved to (23,79) before SCO restore"
        );
        feed(term, b"\x1b[u"); // SCO restore
        assert_eq!(
            snap_cursor(term),
            (6, 12),
            "SCO restore must return to (7;13 → (6, 12))"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn decsc_decrc_preserves_sgr_state() {
    // DECSC saves the active SGR; DECRC restores it. After restore,
    // freshly-typed cells must carry the saved attributes (bold here).
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        // Set bold, save, clear bold, type something, restore, type again.
        feed(term, b"\x1b[5;5H\x1b[1m\x1b7\x1b[22mPLAIN\x1b8BOLD");
        // After DECRC, cursor is back at (5,5) (0-indexed (4,4)). The
        // 4-char "BOLD" overprints "PLAI" of "PLAIN" — but with the
        // saved SGR (bold). Read cell flags at (4, 4).
        let flags = snap_cell_flags(term, 4, 4);
        assert_ne!(
            flags & bc::cell_flags::BOLD,
            0,
            "cell at (4, 4) must carry BOLD (from DECSC-saved SGR); flags=0x{flags:x}"
        );
        bc::bb_term_free(term);
    }
}

// ===========================================================================
// Group F — IND / RI / NEL
// ===========================================================================

#[test]
fn ind_index_moves_down_one_row() {
    // IND (`\x1b D`): move cursor down one row. Same column. If at the
    // last row, scrolls the screen up by one (top row falls off).
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[5;10H\x1bD");
        assert_eq!(
            snap_cursor(term),
            (5, 9),
            "IND from (4,9) must land at (5, 9)"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn ind_at_bottom_row_scrolls() {
    // IND at last row: cursor stays at last row, content scrolls up.
    // Top row falls off (into scrollback). Pin via cursor stuck at last
    // row + bottom row is now blank.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        seed_grid(term, ROWS);
        feed(term, b"\x1b[24;1H\x1bD");
        assert_eq!(
            snap_cursor(term),
            (ROWS - 1, 0),
            "IND at last row must keep cursor at last row (scroll, not move)"
        );
        // Bottom row must now be blank (top row was pushed off, everything
        // shifted up by one, bottom is the new blank line).
        assert_eq!(
            read_row_chars(term, ROWS - 1),
            " ".repeat(COLS as usize),
            "after IND at bottom, last row must be blank"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn ri_reverse_index_moves_up_one_row() {
    // RI (`\x1b M`): move cursor up one row. Same column. At top row,
    // scrolls the screen down by one.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[5;10H\x1bM");
        assert_eq!(
            snap_cursor(term),
            (3, 9),
            "RI from (4,9) must land at (3, 9)"
        );
        // RI at top row: cursor stays, screen scrolls down.
        feed(term, b"\x1b[1;1H");
        seed_grid(term, ROWS);
        feed(term, b"\x1b[1;1H\x1bM");
        assert_eq!(
            snap_cursor(term),
            (0, 0),
            "RI at top row must keep cursor at top row (scroll, not move)"
        );
        // Top row must now be blank.
        assert_eq!(
            read_row_chars(term, 0),
            " ".repeat(COLS as usize),
            "after RI at top, top row must be blank"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn nel_next_line_moves_to_col_0_of_next_row() {
    // NEL (`\x1b E`): equivalent to CR + LF — move to column 0 of next row.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[5;15H\x1bE");
        assert_eq!(
            snap_cursor(term),
            (5, 0),
            "NEL from (4, 14) must land at (5, 0)"
        );
        bc::bb_term_free(term);
    }
}

// ===========================================================================
// Group G — Common SGR variants pinning
// ===========================================================================
//
// SGR is a sprawling parameter space; this group pins the headline cases
// that real-world TUIs depend on. Per-cell colour/flag extraction is the
// observable surface (BBCell.fg / .flags).

#[test]
fn sgr_0_reset_clears_active_attributes() {
    // SGR 0 resets all attributes. After bold + reset, new cells are
    // plain.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[1;1H\x1b[1mB\x1b[0mP");
        // Cell 0: bold; cell 1: plain.
        assert_ne!(
            snap_cell_flags(term, 0, 0) & bc::cell_flags::BOLD,
            0,
            "cell (0,0) 'B' must be bold"
        );
        assert_eq!(
            snap_cell_flags(term, 0, 1) & bc::cell_flags::BOLD,
            0,
            "cell (0,1) 'P' must be plain after SGR 0"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn sgr_38_5_n_indexed_256_color_fg() {
    // SGR 38;5;<n>: indexed 256-colour foreground. Index 196 is bright red.
    // alacritty resolves indexed colours through the palette; the FG u32
    // we read should match the palette entry for index 196 (xterm default
    // 0xFF0000).
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[1;1H\x1b[38;5;196mR");
        let fg = snap_cell_fg(term, 0, 0);
        // Pin: palette[196] is bright red 0xFF0000 in the default palette.
        // A renderer-side palette swap would change the value but the
        // structure (u32 RGB) stays.
        assert_eq!(
            fg, 0x00FF_0000,
            "SGR 38;5;196 must yield bright red (0xFF0000); got 0x{fg:08x}"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn sgr_38_2_r_g_b_direct_color_fg() {
    // SGR 38;2;<r>;<g>;<b>: direct (24-bit) colour FG. The cell's FG must
    // exactly match the requested RGB.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[1;1H\x1b[38;2;128;200;64mD");
        let fg = snap_cell_fg(term, 0, 0);
        assert_eq!(
            fg, 0x0080_C840,
            "SGR 38;2;128;200;64 must yield 0x80C840; got 0x{fg:08x}"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn sgr_4_colon_n_underline_styles() {
    // SGR 4:<n> — colon-separated underline style (kitty / vte
    // extension). 4:3 is undercurl, 4:4 is dotted, 4:5 is dashed.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[1;1H\x1b[4:3mC\x1b[4:4mD\x1b[4:5mE");
        let f0 = snap_cell_flags(term, 0, 0);
        let f1 = snap_cell_flags(term, 0, 1);
        let f2 = snap_cell_flags(term, 0, 2);
        assert_ne!(
            f0 & bc::cell_flags::UNDERCURL,
            0,
            "cell (0,0) 'C' must carry UNDERCURL; flags=0x{f0:x}"
        );
        assert_ne!(
            f1 & bc::cell_flags::UNDERLINE_DOTTED,
            0,
            "cell (0,1) 'D' must carry UNDERLINE_DOTTED; flags=0x{f1:x}"
        );
        assert_ne!(
            f2 & bc::cell_flags::UNDERLINE_DASHED,
            0,
            "cell (0,2) 'E' must carry UNDERLINE_DASHED; flags=0x{f2:x}"
        );
        bc::bb_term_free(term);
    }
}

#[test]
fn sgr_1_bold_22_bold_off() {
    // SGR 1: bold on. SGR 22: bold off (also clears DIM). Pin both.
    unsafe {
        let term = setup_term(COLS, ROWS, SCROLLBACK);
        feed(term, b"\x1b[1;1H\x1b[1mB\x1b[22mN");
        assert_ne!(
            snap_cell_flags(term, 0, 0) & bc::cell_flags::BOLD,
            0,
            "cell (0,0) 'B' must be bold after SGR 1"
        );
        assert_eq!(
            snap_cell_flags(term, 0, 1) & bc::cell_flags::BOLD,
            0,
            "cell (0,1) 'N' must NOT be bold after SGR 22"
        );
        bc::bb_term_free(term);
    }
}

// ===========================================================================
// Group H — DSR / DA replies
// ===========================================================================
//
// Reply assertions: feed the query, drain PtyWrite events from the
// callback, assert the reply bytes. Many of these overlap with
// terminal_replies.rs but conformance tests are intentionally independent
// — the duplicated assertions ensure the full conformance contract
// survives a partial refactor of either file.

#[test]
fn conformance_dsr_5_status_report() {
    // DSR 5: status request → reply 0n (OK).
    unsafe {
        let (term, cap, cap_ptr) = setup_term_with_capture();
        feed(term, b"\x1b[5n");
        let writes = cap.lock().unwrap().pty_writes.clone();
        assert_eq!(
            writes,
            vec![b"\x1b[0n".to_vec()],
            "DSR 5 must reply '\\x1b[0n'; got {:?}",
            writes
        );
        teardown_term_with_capture(term, cap_ptr);
    }
}

#[test]
fn conformance_dsr_6_cursor_position_report() {
    // DSR 6 (CPR): reply with current cursor (1-indexed).
    unsafe {
        let (term, cap, cap_ptr) = setup_term_with_capture();
        feed(term, b"\x1b[7;13H\x1b[6n");
        let writes = cap.lock().unwrap().pty_writes.clone();
        assert_eq!(
            writes,
            vec![b"\x1b[7;13R".to_vec()],
            "DSR 6 after CUP 7;13 must reply '\\x1b[7;13R'; got {:?}",
            writes
        );
        teardown_term_with_capture(term, cap_ptr);
    }
}

#[test]
fn conformance_da1_primary_attributes() {
    // DA1 (`\x1b[c`): reply identifies as VT102 → '\x1b[?6c'.
    unsafe {
        let (term, cap, cap_ptr) = setup_term_with_capture();
        feed(term, b"\x1b[c");
        let writes = cap.lock().unwrap().pty_writes.clone();
        assert_eq!(
            writes,
            vec![b"\x1b[?6c".to_vec()],
            "DA1 must reply '\\x1b[?6c'; got {:?}",
            writes
        );
        teardown_term_with_capture(term, cap_ptr);
    }
}

#[test]
fn conformance_da2_secondary_attributes_shape() {
    // DA2 (`\x1b[>c`): reply '\x1b[>0;<version>;1c'. Version varies; pin
    // prefix and suffix only.
    unsafe {
        let (term, cap, cap_ptr) = setup_term_with_capture();
        feed(term, b"\x1b[>c");
        let writes = cap.lock().unwrap().pty_writes.clone();
        assert_eq!(writes.len(), 1, "DA2 must reply once; got {writes:?}");
        let reply = &writes[0];
        assert!(
            reply.starts_with(b"\x1b[>0;"),
            "DA2 reply prefix must be '\\x1b[>0;'; got {:?}",
            reply
        );
        assert!(
            reply.ends_with(b";1c"),
            "DA2 reply suffix must be ';1c'; got {:?}",
            reply
        );
        teardown_term_with_capture(term, cap_ptr);
    }
}

#[test]
fn conformance_da3_tertiary_attributes_pinned_gap() {
    // PINNED gap: DA3 (`\x1b[=c`) is parsed by alacritty but produces no
    // reply — alacritty does not respond to the tertiary attributes
    // query. Pin the silence so a future change that started replying is
    // surfaced (any reply could carry shell-controllable text and would
    // need a security review for DECRPSS-style echo attacks).
    unsafe {
        let (term, cap, cap_ptr) = setup_term_with_capture();
        feed(term, b"\x1b[=c");
        let writes = cap.lock().unwrap().pty_writes.clone();
        assert!(
            writes.is_empty(),
            "DA3 (`\\x1b[=c`) must produce NO reply on alacritty 0.26; got {:?}. \
             A non-empty reply means DA3 was implemented and the Group H test \
             needs review for echo-attack hardening.",
            writes
        );
        teardown_term_with_capture(term, cap_ptr);
    }
}
