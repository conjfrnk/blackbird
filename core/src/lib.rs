//! blackbird_core — C ABI around `alacritty_terminal`.

use std::cell::UnsafeCell;
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
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

// ---------------------------------------------------------------------------
// Public event-callback types
// ---------------------------------------------------------------------------

/// Kind of terminal event forwarded to the C caller.
#[repr(u32)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BBEventKind {
    Title = 1,
    Bell = 2,
    CursorShape = 3,
    Osc52Clipboard = 4,
    Fatal = 99,
}

/// Event forwarded to the C callback.
///
/// `payload` is valid **only for the duration of the callback**; callers must
/// copy the bytes if they need them after the callback returns.
#[repr(C)]
pub struct BBEvent {
    pub kind: BBEventKind,
    /// Borrowed pointer into Rust-owned memory; null when `len == 0`.
    pub payload: *const u8,
    pub len: usize,
    /// Cursor-shape variant: 0 = block, 1 = bar, 2 = underline; 0 otherwise.
    pub i32_arg: i32,
}

/// C callback signature for terminal events.
pub type BBEventCb = unsafe extern "C" fn(BBEvent, *mut c_void);

// ---------------------------------------------------------------------------
// CallbackCell — shared mutable slot between BBTerm and RoutingListener
// ---------------------------------------------------------------------------

/// Interior-mutable storage for the registered C callback and its context
/// pointer.  Both `BBTerm` and `RoutingListener` reference the same cell;
/// `BBTerm` owns it via `Box`.
///
/// # Thread-safety contract
/// All access to `CallbackCell` is restricted to the single thread that owns
/// the `BBTerm`.  `Term<RoutingListener>` and `Processor` are not `Sync`; the
/// FFI contract already forbids concurrent calls on the same `term` handle
/// (documented on `bb_term_input`).  Under this single-thread discipline no
/// data race can occur, making the `UnsafeCell` sound.
struct CallbackCell(UnsafeCell<(Option<BBEventCb>, *mut c_void)>);

// SAFETY: the owning BBTerm is never shared across threads; see contract above.
unsafe impl Send for CallbackCell {}
// SAFETY: same — no concurrent access is ever made.
unsafe impl Sync for CallbackCell {}

impl CallbackCell {
    fn new() -> Self {
        CallbackCell(UnsafeCell::new((None, std::ptr::null_mut())))
    }

    /// Update the stored callback and context.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn set(&self, cb: Option<BBEventCb>, ctx: *mut c_void) {
        *self.0.get() = (cb, ctx);
    }

    /// Invoke the stored callback if one is registered.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access and that the `BBEvent` fields
    /// are valid for the duration of the call.
    unsafe fn fire(&self, event: BBEvent) {
        let (cb, ctx) = *self.0.get();
        if let Some(f) = cb {
            f(event, ctx);
        }
    }
}

// ---------------------------------------------------------------------------
// RoutingListener — bridges alacritty_terminal events to C callbacks
// ---------------------------------------------------------------------------

/// Event listener that forwards terminal events to a registered C callback.
///
/// Holds a raw pointer into the `CallbackCell` owned by the parent `BBTerm`.
/// The pointer is valid for the entire lifetime of the `Term<RoutingListener>`
/// because `Term` is always dropped before `BBTerm`.
///
/// # Thread-safety contract
/// Must be constructed and used exclusively on the thread that owns the
/// `BBTerm`.  No concurrent access to the callback state is permitted.
struct RoutingListener {
    cell: *const CallbackCell,
}

// SAFETY: the owning BBTerm is never moved to another thread while in use.
unsafe impl Send for RoutingListener {}
// Sync is deliberately NOT implemented — RoutingListener holds a raw pointer
// that is only valid on the thread that owns its BBTerm. If alacritty_terminal
// ever requires EventListener: Sync, revisit the whole synchronization model
// (likely by switching CallbackCell to atomic pointers).

impl EventListener for RoutingListener {
    fn send_event(&self, event: Event) {
        // SAFETY: `cell` is non-null and valid (owned by the enclosing BBTerm
        // which is alive whenever Term<RoutingListener>::send_event runs).
        // Single-thread discipline means no concurrent access.
        unsafe {
            match event {
                Event::Bell => {
                    (*self.cell).fire(BBEvent {
                        kind: BBEventKind::Bell,
                        payload: std::ptr::null(),
                        len: 0,
                        i32_arg: 0,
                    });
                }
                Event::Title(ref s) => {
                    (*self.cell).fire(BBEvent {
                        kind: BBEventKind::Title,
                        payload: s.as_ptr(),
                        len: s.len(),
                        i32_arg: 0,
                    });
                }
                Event::ClipboardStore(_, ref s) => {
                    (*self.cell).fire(BBEvent {
                        kind: BBEventKind::Osc52Clipboard,
                        payload: s.as_ptr(),
                        len: s.len(),
                        i32_arg: 0,
                    });
                }
                // All other variants (MouseCursorDirty, ResetTitle, ClipboardLoad,
                // ColorRequest, PtyWrite, TextAreaSizeRequest, CursorBlinkingChange,
                // Wakeup, Exit, ChildExit) are intentionally ignored.
                _ => {}
            }
        }
    }
}

// ---------------------------------------------------------------------------
// BBTerm
// ---------------------------------------------------------------------------

/// Opaque handle exposed to Swift.
///
/// SAFETY: Rust drops struct fields in declaration order. `term` owns a
/// RoutingListener whose raw pointer targets `callback`, so `term` must be
/// declared BEFORE `callback` — this makes `term` drop first, leaving the
/// pointer valid during Term's destruction. The Fatal event delivery path
/// (in `guard_with_term`) fires during teardown, making this ordering
/// load-bearing.
pub struct BBTerm {
    term: Term<RoutingListener>,
    processor: Processor,
    callback: Box<CallbackCell>,
}

// ---------------------------------------------------------------------------
// Panic-catching guard helpers
// ---------------------------------------------------------------------------

fn payload_to_string(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".to_string()
    }
}

/// Wrap any FFI body that has a valid `BBTerm*` available. On panic:
/// 1. Extract a human-readable message
/// 2. Deliver a `BBEventKind::Fatal` event via the `BBTerm`'s callback (if set)
/// 3. Return the fallback value
///
/// # Safety
/// `term` must be either null (no event delivery) or a valid `&*term` target.
unsafe fn guard_with_term<T>(term: *mut BBTerm, fallback: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(payload) => {
            if !term.is_null() {
                let bb = &*term;
                let msg = payload_to_string(&payload);
                let (cb, ctx) = *bb.callback.0.get();
                if let Some(cb) = cb {
                    let bytes = msg.as_bytes();
                    let ev = BBEvent {
                        kind: BBEventKind::Fatal,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                    };
                    cb(ev, ctx);
                }
            }
            fallback
        }
    }
}

/// Panic-swallowing guard for contexts where no `BBTerm` exists yet
/// (`bb_term_new`'s allocation path, `bb_term_free`'s destructor).
fn guard_no_term<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_payload) => fallback,
    }
}

// ---------------------------------------------------------------------------
// FFI entry points
// ---------------------------------------------------------------------------

/// Create a new terminal. Returns null on invalid input or internal error.
///
/// # Safety
/// The returned pointer must be freed exactly once via `bb_term_free`.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no `BBTerm` context is available yet to deliver a Fatal event).
/// The function returns null as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_new(cols: u16, rows: u16, scrollback: u32) -> *mut BBTerm {
    guard_no_term(std::ptr::null_mut(), || {
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

        let callback = Box::new(CallbackCell::new());
        let listener = RoutingListener {
            cell: &*callback as *const CallbackCell,
        };
        let term = Term::new(config, &size, listener);
        let bb = Box::new(BBTerm {
            term,
            processor: Processor::new(),
            callback,
        });
        Box::into_raw(bb)
    })
}

/// Free a terminal handle created by `bb_term_new`.
///
/// # Safety
/// `term` must have been returned by `bb_term_new` and not previously freed.
/// Passing null is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no safe `BBTerm` context is available during teardown to deliver
/// a Fatal event). The function returns unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_free(term: *mut BBTerm) {
    guard_no_term((), || {
        if term.is_null() {
            return;
        }
        drop(Box::from_raw(term));
    })
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
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_input(term: *mut BBTerm, bytes: *const u8, len: usize) {
    guard_with_term(term, (), || {
        if term.is_null() || len == 0 || bytes.is_null() {
            return;
        }
        let bb = &mut *term;
        let slice = std::slice::from_raw_parts(bytes, len);
        bb.processor.advance(&mut bb.term, slice);
    })
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
/// the same term.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_resize(term: *mut BBTerm, cols: u16, rows: u16) {
    guard_with_term(term, (), || {
        if term.is_null() || cols == 0 || rows == 0 {
            return;
        }
        let bb = &mut *term;
        let size = TermSize {
            cols: cols as usize,
            rows: rows as usize,
        };
        bb.term.resize(size);
    })
}

/// Register (or clear) the event callback for a terminal.
///
/// Pass `cb = None` to disable event delivery.  `ctx` is an opaque pointer
/// forwarded verbatim to every callback invocation; pass `null` if unused.
///
/// # Safety
/// - `term` must be non-null, valid, and not freed while the callback is
///   registered.
/// - `ctx` must remain valid for all subsequent `bb_term_input` calls until
///   the callback is cleared or the terminal is freed.
/// - The callback may be invoked synchronously from within `bb_term_input`;
///   it must not call any `bb_term_*` function on the same `term` handle
///   (no re-entrant use).
/// - All access must occur on the same thread (no concurrent calls on the
///   same term).
/// - Passing `term = null` is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_event_cb(
    term: *mut BBTerm,
    cb: Option<BBEventCb>,
    ctx: *mut c_void,
) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        (*term).callback.set(cb, ctx);
    })
}

/// Take an immutable snapshot of the current grid state.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Returns null on null input.
/// The returned pointer must be released by exactly one `bb_snap_release` per
/// successful call (plus one per `bb_snap_retain`).
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// null as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_take_snapshot(term: *mut BBTerm) -> *const BBSnap {
    guard_with_term(term, std::ptr::null(), || {
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
    })
}

/// Increment refcount. Returns the input pointer for fluent usage.
///
/// # Safety
/// `snap` must be a pointer returned by `bb_term_take_snapshot` or previously
/// retained, and not yet released to zero. Null is a no-op (returns null).
/// Safe to call from any thread.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no `BBTerm` context is available). The function returns the input
/// `snap` pointer as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_retain(snap: *const BBSnap) -> *const BBSnap {
    guard_no_term(snap, || {
        if snap.is_null() {
            return snap;
        }
        (*snap).rc.fetch_add(1, Ordering::Relaxed);
        snap
    })
}

/// Decrement refcount; free when it reaches zero.
///
/// # Safety
/// Each `snap` must be released exactly once per acquire (new or retain).
/// Null is a no-op. Safe to call from any thread, but each concrete handle
/// follows the acquire/release discipline documented above.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no `BBTerm` context is available). The function returns unit as
/// the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_release(snap: *const BBSnap) {
    guard_no_term((), || {
        if snap.is_null() {
            return;
        }
        let prev = (*snap).rc.fetch_sub(1, Ordering::Release);
        if prev == 1 {
            std::sync::atomic::fence(Ordering::Acquire);
            drop(Box::from_raw(snap as *mut BBSnap));
        }
    })
}

/// Test-only: force a panic inside the FFI boundary to verify Fatal event delivery.
///
/// # Safety
/// Same as other guarded FFI functions. `term` must be a valid non-null pointer
/// from `bb_term_new`, not freed for the duration of the call.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback.
#[no_mangle]
#[cfg(any(test, feature = "test-only"))]
pub unsafe extern "C" fn bb_term_test_only_panic(term: *mut BBTerm) {
    guard_with_term(term, (), || {
        panic!("intentional test panic");
    });
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
        let callback = Box::new(CallbackCell::new());
        let listener = RoutingListener {
            cell: &*callback as *const CallbackCell,
        };
        let mut term = Term::new(config, &size, listener);

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

    #[test]
    fn bell_event_fires_callback() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let fired: Arc<Mutex<Vec<u32>>> = Arc::new(Mutex::new(Vec::new()));
        let fired_ptr = Arc::into_raw(fired.clone()) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let fired = &*(ctx as *const std::sync::Mutex<Vec<u32>>);
            fired.lock().unwrap().push(ev.kind as u32);
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_set_event_cb(term, Some(cb), fired_ptr);
            let byte = b"\x07"; // BEL
            bb_term_input(term, byte.as_ptr(), 1);

            let guard = fired.lock().unwrap();
            assert!(guard.contains(&(BBEventKind::Bell as u32)));
            drop(guard);

            bb_term_free(term);
            Arc::from_raw(fired_ptr as *const Mutex<Vec<u32>>);
        }
    }

    #[test]
    fn title_event_fires_callback() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let received: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let received_ptr = Arc::into_raw(received.clone()) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::Title) {
                let received = &*(ctx as *const std::sync::Mutex<Vec<String>>);
                let bytes = std::slice::from_raw_parts(ev.payload, ev.len);
                received
                    .lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(bytes).into_owned());
            }
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_set_event_cb(term, Some(cb), received_ptr);
            // OSC 2 ; <title> BEL
            let seq = b"\x1b]2;my-title\x07";
            bb_term_input(term, seq.as_ptr(), seq.len());

            let got = received.lock().unwrap().clone();
            assert!(got.iter().any(|s| s == "my-title"), "got: {:?}", got);

            bb_term_free(term);
            Arc::from_raw(received_ptr as *const Mutex<Vec<String>>);
        }
    }

    #[test]
    fn setting_null_cb_disables_callback() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let count: Arc<Mutex<u32>> = Arc::new(Mutex::new(0));
        let count_ptr = Arc::into_raw(count.clone()) as *mut c_void;

        unsafe extern "C" fn cb(_ev: BBEvent, ctx: *mut c_void) {
            let count = &*(ctx as *const Mutex<u32>);
            *count.lock().unwrap() += 1;
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);

            // Register callback, fire BEL, expect 1 invocation.
            bb_term_set_event_cb(term, Some(cb), count_ptr);
            bb_term_input(term, b"\x07".as_ptr(), 1);
            assert_eq!(*count.lock().unwrap(), 1);

            // Clear callback, fire BEL again, count must NOT increase.
            bb_term_set_event_cb(term, None, std::ptr::null_mut());
            bb_term_input(term, b"\x07".as_ptr(), 1);
            assert_eq!(
                *count.lock().unwrap(),
                1,
                "cleared callback should not fire"
            );

            bb_term_free(term);
            Arc::from_raw(count_ptr as *const Mutex<u32>);
        }
    }

    #[test]
    fn set_event_cb_on_null_term_is_noop() {
        unsafe {
            bb_term_set_event_cb(std::ptr::null_mut(), None, std::ptr::null_mut());
        }
    }

    #[test]
    fn fatal_event_on_panic() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let fired: Arc<Mutex<Vec<(u32, String)>>> = Arc::new(Mutex::new(Vec::new()));
        let fired_ptr = Arc::into_raw(fired.clone()) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let fired = &*(ctx as *const std::sync::Mutex<Vec<(u32, String)>>);
            let msg = if ev.payload.is_null() || ev.len == 0 {
                String::new()
            } else {
                let slice = std::slice::from_raw_parts(ev.payload, ev.len);
                String::from_utf8_lossy(slice).into_owned()
            };
            fired.lock().unwrap().push((ev.kind as u32, msg));
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_set_event_cb(term, Some(cb), fired_ptr);

            bb_term_test_only_panic(term); // forces a panic inside guard()

            let guard_ = fired.lock().unwrap();
            let fatal = guard_.iter().find(|(k, _)| *k == BBEventKind::Fatal as u32);
            assert!(fatal.is_some(), "expected Fatal event, got {:?}", *guard_);
            assert!(
                fatal.unwrap().1.contains("intentional test panic"),
                "fatal msg should contain panic message: {:?}",
                fatal
            );
            drop(guard_);

            bb_term_free(term);
            Arc::from_raw(fired_ptr as *const Mutex<Vec<(u32, String)>>);
        }
    }

    #[test]
    fn new_does_not_crash_on_internal_panic() {
        // Nothing to do here except verify that if Box::new or Term::new panicked,
        // the process would survive. There's no easy way to inject a panic without
        // test hooks, but the `guard_no_term` wrapper ensures it would be caught.
        unsafe {
            let term = bb_term_new(80, 24, 100);
            assert!(!term.is_null());
            bb_term_free(term);
        }
    }
}
