//! blackbird_core — C ABI around `alacritty_terminal`.

use std::sync::atomic::{AtomicUsize, Ordering};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi::Processor;

/// Dimensions struct required by `Term::new`.
///
/// `total_lines` returns only the visible rows here, not `rows + scrollback`.
/// In 0.26's grid model, `Dimensions::total_lines` is the number of lines
/// currently allocated in the ring buffer (screen + accumulated history). When
/// sizing a *new* terminal the buffer starts at `screen_lines` rows; the grid
/// grows into the scrollback region lazily as output scrolls off-screen.
/// `Term::new` reads `scrolling_history` from `Config` (not from
/// `Dimensions::total_lines`) to set `Grid::max_scroll_limit`.  The only
/// methods `Term::new` calls on `Dimensions` are `screen_lines()` and
/// `columns()`, which is confirmed by alacritty's own internal `TermSize`
/// test helper (term/mod.rs:2436-2439) doing the same thing.
#[derive(Clone, Copy)]
struct TermSize {
    cols: usize,
    rows: usize,
}

impl Dimensions for TermSize {
    fn columns(&self) -> usize {
        self.cols
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn total_lines(&self) -> usize {
        self.rows
    }
}

/// We don't listen to `alacritty_terminal` events yet — events we care about
/// are re-emitted to Swift via `bb_term_set_event_cb` in a later task.
#[derive(Clone, Default)]
struct NoopListener;

impl EventListener for NoopListener {
    fn send_event(&self, _event: Event) {}
}

/// Opaque handle exposed to Swift.
pub struct BBTerm {
    term: Term<NoopListener>,
    processor: Processor,
}

/// Create a new terminal. Returns null on invalid input.
///
/// # Safety
/// The returned pointer must be freed exactly once via `bb_term_free`.
///
/// Until `catch_unwind` is added to FFI entry points (Task 7), the caller must
/// ensure no Rust panic can unwind through this function (UB to unwind through
/// `extern "C"`).
#[no_mangle]
pub unsafe extern "C" fn bb_term_new(cols: u16, rows: u16, scrollback: u32) -> *mut BBTerm {
    if cols == 0 || rows == 0 {
        return std::ptr::null_mut();
    }
    let size = TermSize {
        cols: cols as usize,
        rows: rows as usize,
    };
    let config = Config {
        scrolling_history: scrollback as usize,
        ..Default::default()
    };

    let term = Term::new(config, &size, NoopListener);
    let bb = Box::new(BBTerm {
        term,
        processor: Processor::new(),
    });
    Box::into_raw(bb)
}

/// Free a terminal handle created by `bb_term_new`.
///
/// # Safety
/// `term` must have been returned by `bb_term_new` and not previously freed.
/// Passing null is a no-op.
///
/// Until `catch_unwind` is added to FFI entry points (Task 7), the caller must
/// ensure no Rust panic can unwind through this function (UB to unwind through
/// `extern "C"`).
#[no_mangle]
pub unsafe extern "C" fn bb_term_free(term: *mut BBTerm) {
    if term.is_null() {
        return;
    }
    drop(Box::from_raw(term));
}

/// Feed `len` bytes from `bytes` into the terminal's VT parser.
///
/// # Safety
/// - `term` must be non-null, properly aligned (obtained from `bb_term_new`),
///   and not freed for the duration of this call.
/// - `bytes` must be non-null when `len > 0` and point to a readable region of
///   at least `len` bytes. Passing `bytes = null, len = 0` is safe (no-op).
/// - No two threads may call any `bb_term_*` function concurrently on the same
///   `term`; interior state is mutated and `Term`/`Processor` are not `Sync`.
/// - Until `catch_unwind` is added to FFI entry points (Task 7), the caller
///   must ensure no Rust panic can unwind through this function (UB to unwind
///   through `extern "C"`).
#[no_mangle]
pub unsafe extern "C" fn bb_term_input(term: *mut BBTerm, bytes: *const u8, len: usize) {
    if term.is_null() || len == 0 || bytes.is_null() {
        return;
    }
    let bb = &mut *term;
    let slice = std::slice::from_raw_parts(bytes, len);
    bb.processor.advance(&mut bb.term, slice);
}

/// Flat cell layout for cross-language consumption. Swift reads these directly.
/// Colors are hardcoded for now — TODO(plan-5) wires theme-aware colors.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct BBCell {
    pub ch: u32, // Unicode scalar; 0 means empty
    pub fg: u32, // 0xRRGGBB
    pub bg: u32,
    pub flags: u16, // See cell_flags
    pub _reserved: u16,
}

pub mod cell_flags {
    pub const BOLD: u16 = 1 << 0;
    pub const ITALIC: u16 = 1 << 1;
    pub const UNDERLINE: u16 = 1 << 2;
    pub const REVERSE: u16 = 1 << 3;
    pub const DIM: u16 = 1 << 4;
    pub const STRIKE: u16 = 1 << 5;
}

/// Immutable snapshot. Ref-counted. The `cells` pointer is stable for the lifetime of the snapshot.
///
/// `cells` is non-null and points to exactly `cells_len` consecutive `BBCell` elements for the
/// lifetime of this snapshot. It is never null for any snapshot returned by
/// `bb_term_take_snapshot`, because `bb_term_new` rejects zero dimensions and `display_iter()`
/// always yields `cols * rows` cells.
#[repr(C)]
pub struct BBSnap {
    pub cols: u16,
    pub rows: u16,
    pub cursor_col: u16,
    pub cursor_row: u16,
    pub cursor_visible: u8,
    pub _pad: [u8; 7],
    pub cells_len: usize,
    pub cells: *const BBCell,

    // Non-C-visible fields below (cbindgen will skip these once we configure it in Task 8).
    #[doc(hidden)]
    rc: AtomicUsize,
    #[doc(hidden)]
    cells_owned: Vec<BBCell>,
}

unsafe impl Send for BBSnap {}
// SAFETY: after BBSnap::new returns, no field is ever mutated:
// - cols/rows/cursor_*/_pad/cells_len/cells are set once in the struct literal
// - cells_owned is private and no method mutates it (no push/pop/reallocate)
// - rc is AtomicUsize, which is Sync
// - cells aliases cells_owned's heap buffer, which is sound because both are
//   read-only after construction
unsafe impl Sync for BBSnap {}

impl BBSnap {
    fn new(cols: u16, rows: u16, cursor: (u16, u16, bool), cells: Vec<BBCell>) -> Box<BBSnap> {
        let mut s = Box::new(BBSnap {
            cols,
            rows,
            cursor_col: cursor.0,
            cursor_row: cursor.1,
            cursor_visible: cursor.2 as u8,
            _pad: [0; 7],
            cells_len: cells.len(),
            cells: std::ptr::null(),
            rc: AtomicUsize::new(1),
            cells_owned: cells,
        });
        // Once the Box is allocated and cells_owned is in place, take the stable pointer.
        s.cells = s.cells_owned.as_ptr();
        s
    }
}

/// Resize the terminal grid. Out-of-range (zero) dimensions are ignored.
///
/// # Safety
/// `term` must be a valid non-null pointer from `bb_term_new`, properly
/// aligned, not freed for the duration of the call. No concurrent calls on
/// the same term. Until `catch_unwind` is added (Task 7), no Rust panic may
/// unwind through this function (UB to unwind through `extern "C"`).
#[no_mangle]
pub unsafe extern "C" fn bb_term_resize(term: *mut BBTerm, cols: u16, rows: u16) {
    if term.is_null() || cols == 0 || rows == 0 {
        return;
    }
    let bb = &mut *term;
    let size = TermSize {
        cols: cols as usize,
        rows: rows as usize,
    };
    bb.term.resize(size);
}

/// Take an immutable snapshot of the current grid state.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Returns null on null input.
/// The returned pointer must be released by exactly one `bb_snap_release` per
/// successful call (plus one per `bb_snap_retain`).
#[no_mangle]
pub unsafe extern "C" fn bb_term_take_snapshot(term: *mut BBTerm) -> *const BBSnap {
    if term.is_null() {
        return std::ptr::null();
    }
    let bb = &*term;
    let grid = bb.term.grid();

    let rows = grid.screen_lines() as u16;
    let cols = grid.columns() as u16;
    let mut cells: Vec<BBCell> = Vec::with_capacity(rows as usize * cols as usize);

    for indexed in grid.display_iter() {
        cells.push(BBCell {
            ch: indexed.c as u32,
            fg: 0xEEEEEE, // TODO(plan-5): theme-aware color mapping
            bg: 0x000000,
            flags: 0,
            _reserved: 0,
        });
    }

    let cursor_point = grid.cursor.point;
    // cursor_point.line.0 is a 0-based screen row (Line wraps i32; visible rows are 0..rows-1).
    // cursor_point.column.0 is a 0-based column (Column wraps usize).
    let cursor_row = cursor_point.line.0.max(0) as u16;
    let cursor_col = cursor_point.column.0 as u16;
    let snap = BBSnap::new(cols, rows, (cursor_col, cursor_row, true), cells);
    Box::into_raw(snap)
}

/// Increment refcount. Returns the input pointer for fluent usage.
///
/// # Safety
/// `snap` must be a pointer returned by `bb_term_take_snapshot` or previously
/// retained, and not yet released to zero. Null is a no-op (returns null).
/// Safe to call from any thread.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_retain(snap: *const BBSnap) -> *const BBSnap {
    if snap.is_null() {
        return snap;
    }
    (*snap).rc.fetch_add(1, Ordering::Relaxed);
    snap
}

/// Decrement refcount; free when it reaches zero.
///
/// # Safety
/// Each `snap` must be released exactly once per acquire (new or retain).
/// Null is a no-op. Safe to call from any thread, but each concrete handle
/// follows the acquire/release discipline documented above.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_release(snap: *const BBSnap) {
    if snap.is_null() {
        return;
    }
    let prev = (*snap).rc.fetch_sub(1, Ordering::Release);
    if prev == 1 {
        std::sync::atomic::fence(Ordering::Acquire);
        drop(Box::from_raw(snap as *mut BBSnap));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::grid::Dimensions;
    use alacritty_terminal::vte::ansi::Handler;

    #[test]
    fn alacritty_terminal_is_linked() {
        let _ = std::mem::size_of::<alacritty_terminal::term::Config>();
    }

    #[test]
    fn new_and_free_roundtrip() {
        unsafe {
            let term = bb_term_new(80, 24, 10_000);
            assert!(!term.is_null(), "bb_term_new returned null");
            bb_term_free(term);
        }
    }

    #[test]
    fn free_null_is_noop() {
        unsafe {
            bb_term_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn new_with_zero_dims_returns_null() {
        unsafe {
            assert!(bb_term_new(0, 24, 1000).is_null());
            assert!(bb_term_new(80, 0, 1000).is_null());
        }
    }

    /// Verify that scrollback is wired up: after feeding enough newlines to
    /// push lines off-screen the grid's history grows up to the scrollback
    /// limit, confirming `Config::scrolling_history` was applied correctly.
    #[test]
    fn scrollback_is_retained() {
        let scrollback: usize = 5;
        let rows: usize = 3;
        let cols: usize = 10;

        let size = TermSize { cols, rows };
        let config = Config {
            scrolling_history: scrollback,
            ..Default::default()
        };
        let mut term = Term::new(config, &size, NoopListener);

        // Feed (rows + scrollback) newlines so that exactly `scrollback` lines
        // are pushed into history.
        let total_newlines = rows + scrollback;
        for _ in 0..total_newlines {
            term.linefeed();
        }

        // `history_size()` = total_lines - screen_lines (from the grid model).
        // It should equal the scrollback limit once fully populated.
        let history = term.history_size();
        assert_eq!(
            history, scrollback,
            "expected {} scrollback lines, got {}",
            scrollback, history
        );
    }

    #[test]
    fn input_writes_to_grid() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            assert!(!term.is_null());
            let bytes = b"hello";
            bb_term_input(term, bytes.as_ptr(), bytes.len());

            // `display_iter()` is a flat cell-by-cell iterator over visible cells.
            // Each item is `Indexed<&Cell>` which derefs to `&Cell`; `Cell.c` is the char.
            // TODO(task-4): replace with bb_term_take_snapshot
            let bb = &*term;
            let text: String = bb
                .term
                .grid()
                .display_iter()
                .take(5)
                .map(|indexed| indexed.c)
                .collect();
            assert_eq!(text, "hello");

            bb_term_free(term);
        }
    }

    #[test]
    fn input_with_null_term_is_noop() {
        unsafe {
            let bytes = b"x";
            bb_term_input(std::ptr::null_mut(), bytes.as_ptr(), bytes.len());
        }
    }

    #[test]
    fn input_with_zero_len_leaves_grid_unchanged() {
        unsafe {
            let term = bb_term_new(80, 24, 100);
            bb_term_input(term, b"ignored".as_ptr(), 0);
            let bb = &*term;
            let grid = bb.term.grid();
            let first_cell = grid.display_iter().next().expect("grid has cells");
            assert_eq!(first_cell.c, ' ', "grid should be untouched");
            bb_term_free(term);
        }
    }

    #[test]
    fn input_with_null_bytes_is_noop() {
        unsafe {
            let term = bb_term_new(80, 24, 100);
            bb_term_input(term, std::ptr::null(), 5);
            bb_term_free(term);
        }
    }

    #[test]
    fn snapshot_contains_input() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            let bytes = b"hi";
            bb_term_input(term, bytes.as_ptr(), bytes.len());

            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());

            let s = &*snap;
            assert_eq!(s.cols, 80);
            assert_eq!(s.rows, 24);
            // `cells` is a flat row-major array of length cols*rows.
            let cell0 = &*s.cells;
            let cell1 = &*s.cells.add(1);
            assert_eq!(char::from_u32(cell0.ch), Some('h'));
            assert_eq!(char::from_u32(cell1.ch), Some('i'));

            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn snap_two_owners_release_cleanly() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            let owner_a = bb_term_take_snapshot(term); // rc = 1
            let owner_b = bb_snap_retain(owner_a); // rc = 2, same address
            assert_eq!(owner_a, owner_b); // retain returns the input pointer
            bb_snap_release(owner_b); // rc = 1 (owner_b done)
            bb_snap_release(owner_a); // rc = 0, freed (owner_a done)
            bb_term_free(term);
        }
    }

    #[test]
    fn snap_layout_matches_expected() {
        // C-visible portion: 32 bytes. Full struct (with private rc + Vec) is larger; we only assert the public layout.
        assert_eq!(
            std::mem::offset_of!(BBSnap, cells_len),
            16,
            "cells_len must be at offset 16 for a clean C ABI"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, cells),
            24,
            "cells must be at offset 24 for a clean C ABI"
        );
    }

    #[test]
    fn snap_null_retain_release_are_noops() {
        unsafe {
            let _ = bb_snap_retain(std::ptr::null());
            bb_snap_release(std::ptr::null());
        }
    }

    #[test]
    fn take_snapshot_from_null_term_returns_null() {
        unsafe {
            assert!(bb_term_take_snapshot(std::ptr::null_mut()).is_null());
        }
    }

    #[test]
    fn resize_changes_dimensions() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_resize(term, 120, 40);
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cols, 120);
            assert_eq!((*snap).rows, 40);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn resize_to_zero_is_noop() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_resize(term, 0, 40); // no-op
            bb_term_resize(term, 120, 0); // no-op
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cols, 80);
            assert_eq!((*snap).rows, 24);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn resize_null_term_is_noop() {
        unsafe {
            bb_term_resize(std::ptr::null_mut(), 80, 24);
        }
    }
}
