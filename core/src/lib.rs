//! blackbird_core — C ABI around `alacritty_terminal`.

use std::cell::UnsafeCell;
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::cell::Flags as CellFlags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor};

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
    /// Reserved for future use. Not currently emitted by RoutingListener —
    /// alacritty 0.26 doesn't surface cursor-shape changes as events. Swift
    /// readers should consume cursor state from snapshots.
    CursorShape = 3,
    Osc52Clipboard = 4,
    /// Bytes that should be written BACK to the PTY (terminal → shell).
    /// alacritty_terminal generates these in response to DSR queries (ESC[6n),
    /// DA1/DA2, DECRPM, and similar terminal-identification sequences. If the
    /// host ignores these, apps like nvim that probe terminal capabilities
    /// will time out waiting for a response.
    PtyWrite = 5,
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
                Event::PtyWrite(ref s) => {
                    let bytes = s.as_bytes();
                    (*self.cell).fire(BBEvent {
                        kind: BBEventKind::PtyWrite,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                    });
                }
                // All other variants (MouseCursorDirty, ResetTitle, ClipboardLoad,
                // ColorRequest, TextAreaSizeRequest, CursorBlinkingChange,
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

fn payload_to_string(payload: &(dyn std::any::Any + Send)) -> String {
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
                let msg = payload_to_string(&*payload);
                let (cb, ctx) = *bb.callback.0.get();
                if let Some(cb) = cb {
                    let bytes = msg.as_bytes();
                    let ev = BBEvent {
                        kind: BBEventKind::Fatal,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                    };
                    // Double-panic safety: if the callback itself panics,
                    // catch and discard. Better to drop the Fatal notification
                    // than to unwind across extern "C" (UB).
                    // AssertUnwindSafe is sound here: state after a double-panic
                    // is considered poisoned; callers won't reuse this BBTerm.
                    let _ = catch_unwind(AssertUnwindSafe(|| cb(ev, ctx)));
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
        // Augment every `ESC [ 2 J` (ED All — erase the visible screen) with
        // a trailing `ESC [ 3 J` (ED Saved — erase scrollback). `clear(1)`
        // on macOS only emits 2J (from the xterm-256color terminfo); users
        // expect it to also wipe scrollback, as iTerm2 and the util-linux
        // `clear -x` do by default. Matching the exact 4-byte sequence is
        // robust for the common case — shell and ncurses write the whole
        // clear capability in a single write(2), so we don't need to track
        // parser state across input batches. Edge cases (0-padded params,
        // semicolon-separated params, sequence split across reads) fall
        // through to normal processing without breaking anything.
        let needle = b"\x1B[2J";
        let extra = b"\x1B[3J";
        let mut cursor = 0usize;
        while let Some(rel) = slice[cursor..]
            .windows(needle.len())
            .position(|w| w == needle)
        {
            let end = cursor + rel + needle.len(); // one past the J
            bb.processor.advance(&mut bb.term, &slice[cursor..end]);
            bb.processor.advance(&mut bb.term, extra);
            cursor = end;
        }
        if cursor < slice.len() {
            bb.processor.advance(&mut bb.term, &slice[cursor..]);
        }
    })
}

/// Flat cell layout for cross-language consumption. Swift reads these directly.
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

/// Terminal mode bitflags mirrored from `alacritty_terminal::term::TermMode`.
/// These are stable across Blackbird versions; the underlying alacritty bits
/// are intentionally not exposed directly so we can version them independently.
pub mod bb_mode {
    pub const ALT_SCREEN: u32 = 1 << 0;
    pub const APP_CURSOR: u32 = 1 << 1;
    pub const APP_KEYPAD: u32 = 1 << 2;
    pub const BRACKETED_PASTE: u32 = 1 << 3;
    pub const MOUSE_REPORT_CLICK: u32 = 1 << 4;
    pub const MOUSE_MOTION: u32 = 1 << 5;
    pub const MOUSE_DRAG: u32 = 1 << 6;
    pub const SGR_MOUSE: u32 = 1 << 7;
    pub const FOCUS_IN_OUT: u32 = 1 << 8;
    pub const SHOW_CURSOR: u32 = 1 << 9;
    pub const LINE_WRAP: u32 = 1 << 10;
}

/// Immutable snapshot of terminal grid state. Ref-counted via `bb_snap_retain` /
/// `bb_snap_release`. The `cells` pointer is stable for the lifetime of the snapshot.
///
/// `cells` is non-null and points to exactly `cells_len` consecutive `BBCell` elements for the
/// lifetime of this snapshot. It is never null for any snapshot returned by
/// `bb_term_take_snapshot`, because `bb_term_new` rejects zero dimensions and `display_iter()`
/// always yields `cols * rows` cells.
///
/// The actual heap allocation is `BBSnapOwned`; the raw pointer exposed to C points to the
/// `snap` field at offset 0 of that struct. Do not construct or free `BBSnap` directly.
#[repr(C)]
pub struct BBSnap {
    pub cols: u16,
    pub rows: u16,
    pub cursor_col: u16,
    pub cursor_row: u16,
    pub cursor_visible: u8,
    pub _pad: u8, // align display_offset to 2-byte boundary
    /// Number of lines the viewport is scrolled above the live grid. 0 means
    /// we're pinned to the bottom (live content). When > 0 the renderer must
    /// offset the cursor by this amount or hide it if the live cursor row is
    /// no longer visible.
    pub display_offset: u16,
    pub mode: u32, // terminal mode bitflags — see bb_mode constants
    pub cells_len: usize,
    pub cells: *const BBCell,
    /// Total lines currently retained in scrollback (grows as output flows
    /// off-screen, capped at the scrollback limit). Used by the scroll
    /// indicator to size its thumb proportional to total-buffer vs viewport.
    /// Appended here to preserve the existing offsets of cells_len/cells.
    pub history_size: u32,
    /// DECSCUSR cursor shape: 0 = block, 1 = bar/beam, 2 = underline, 3 = hidden.
    /// Sourced from `Term::cursor_style().shape` at snapshot time. Callers
    /// render according to this; a value of 3 means the renderer should skip
    /// drawing the cursor entirely.
    pub cursor_shape: u8,
    pub _pad2b: [u8; 3],
}

unsafe impl Send for BBSnap {}
// SAFETY: all fields are read-only after BBSnapOwned::new returns; cells aliases
// cells_owned's heap buffer which is never reallocated after construction.
unsafe impl Sync for BBSnap {}

/// Private heap owner for a snapshot. `snap` is the first field so that a
/// `*const BBSnap` == `*const BBSnapOwned` via a simple cast, enabling the
/// public C API to hand out `*const BBSnap` while retaining full ownership here.
#[repr(C)]
struct BBSnapOwned {
    snap: BBSnap,
    rc: AtomicUsize,
    cells_owned: Vec<BBCell>,
}

// SAFETY: see BBSnap's unsafe impl Send above; same reasoning applies.
unsafe impl Send for BBSnapOwned {}
// SAFETY: rc is AtomicUsize (Sync); snap and cells_owned are read-only after construction.
unsafe impl Sync for BBSnapOwned {}

impl BBSnapOwned {
    // Passing 8 args is deliberate — collapsing into a struct just to appease
    // the lint would obscure the call site, which is a single private caller
    // inside `bb_term_take_snapshot`.
    #[allow(clippy::too_many_arguments)]
    fn new(
        cols: u16,
        rows: u16,
        cursor: (u16, u16, bool),
        display_offset: u16,
        history_size: u32,
        mode: u32,
        cursor_shape: u8,
        cells: Vec<BBCell>,
    ) -> Box<BBSnapOwned> {
        let mut owned = Box::new(BBSnapOwned {
            snap: BBSnap {
                cols,
                rows,
                cursor_col: cursor.0,
                cursor_row: cursor.1,
                cursor_visible: cursor.2 as u8,
                _pad: 0,
                display_offset,
                mode,
                cells_len: cells.len(),
                cells: std::ptr::null(),
                history_size,
                cursor_shape,
                _pad2b: [0; 3],
            },
            rc: AtomicUsize::new(1),
            cells_owned: cells,
        });
        // Capture the stable heap pointer into the public field.
        owned.snap.cells = owned.cells_owned.as_ptr();
        owned
    }

    /// Recover a mutable `BBSnapOwned` reference from a `*const BBSnap`.
    ///
    /// # Safety
    /// `snap` must point to the `snap` field of a live `BBSnapOwned` allocated
    /// by `BBSnapOwned::new`. Because `snap` is the first field and both types
    /// are `#[repr(C)]`, the pointer values are identical.
    unsafe fn from_snap_ptr(snap: *const BBSnap) -> *mut BBSnapOwned {
        snap as *mut BBSnapOwned
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
    cb: Option<unsafe extern "C" fn(BBEvent, *mut c_void)>,
    ctx: *mut c_void,
) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        (*term).callback.set(cb, ctx);
    })
}

/// Convert an alacritty `Color` to a 0xRRGGBB u32, consulting the terminal's
/// palette first (so OSC 4/10/11/12 and `bb_term_set_named_color` overrides
/// route through). Falls back to built-in xterm defaults when a slot is unset.
fn color_to_rgb(color: &Color, palette: &alacritty_terminal::term::color::Colors) -> u32 {
    match color {
        Color::Spec(rgb) => ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32),
        Color::Named(name) => {
            let idx = *name as usize;
            if let Some(rgb) = palette[idx] {
                ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32)
            } else {
                named_color_rgb(name)
            }
        }
        Color::Indexed(idx) => {
            if let Some(rgb) = palette[*idx as usize] {
                ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32)
            } else {
                indexed_color_rgb(*idx)
            }
        }
    }
}

/// Map the 16 ANSI named colors (and semantic aliases) to xterm defaults.
fn named_color_rgb(name: &NamedColor) -> u32 {
    match name {
        NamedColor::Black => 0x000000,
        NamedColor::Red => 0xCC0000,
        NamedColor::Green => 0x4E9A06,
        NamedColor::Yellow => 0xC4A000,
        NamedColor::Blue => 0x3465A4,
        NamedColor::Magenta => 0x75507B,
        NamedColor::Cyan => 0x06989A,
        NamedColor::White => 0xD3D7CF,
        NamedColor::BrightBlack => 0x555753,
        NamedColor::BrightRed => 0xEF2929,
        NamedColor::BrightGreen => 0x8AE234,
        NamedColor::BrightYellow => 0xFCE94F,
        NamedColor::BrightBlue => 0x729FCF,
        NamedColor::BrightMagenta => 0xAD7FA8,
        NamedColor::BrightCyan => 0x34E2E2,
        NamedColor::BrightWhite => 0xEEEEEC,
        // Semantic aliases — Foreground defaults to light grey, Background to black
        NamedColor::Foreground | NamedColor::BrightForeground => 0xEEEEEE,
        NamedColor::Background => 0x000000,
        // Dim variants: map to the base color (terminal dims it visually)
        NamedColor::DimBlack => 0x000000,
        NamedColor::DimRed => 0xCC0000,
        NamedColor::DimGreen => 0x4E9A06,
        NamedColor::DimYellow => 0xC4A000,
        NamedColor::DimBlue => 0x3465A4,
        NamedColor::DimMagenta => 0x75507B,
        NamedColor::DimCyan => 0x06989A,
        NamedColor::DimWhite => 0xD3D7CF,
        NamedColor::DimForeground => 0xEEEEEE,
        // Cursor and any future variants
        _ => 0xEEEEEE,
    }
}

/// Map xterm 256-color palette index to 0xRRGGBB.
fn indexed_color_rgb(idx: u8) -> u32 {
    match idx {
        0..=15 => {
            // Standard 16 colors — same mapping as named_color_rgb
            const TABLE: [u32; 16] = [
                0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
                0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
            ];
            TABLE[idx as usize]
        }
        16..=231 => {
            // 6×6×6 color cube
            let i = (idx - 16) as u32;
            let r = (i / 36) % 6;
            let g = (i / 6) % 6;
            let b = i % 6;
            let to_byte = |v: u32| -> u32 {
                if v == 0 {
                    0
                } else {
                    55 + 40 * v
                }
            };
            (to_byte(r) << 16) | (to_byte(g) << 8) | to_byte(b)
        }
        232..=255 => {
            // 24-step grayscale ramp
            let v = 8 + 10 * (idx - 232) as u32;
            (v << 16) | (v << 8) | v
        }
    }
}

/// Extract our stable `cell_flags` bitset from alacritty's `Flags`.
fn extract_cell_flags(f: CellFlags) -> u16 {
    let mut out: u16 = 0;
    if f.contains(CellFlags::BOLD) {
        out |= cell_flags::BOLD;
    }
    if f.contains(CellFlags::ITALIC) {
        out |= cell_flags::ITALIC;
    }
    if f.contains(CellFlags::UNDERLINE) {
        out |= cell_flags::UNDERLINE;
    }
    if f.contains(CellFlags::INVERSE) {
        out |= cell_flags::REVERSE;
    }
    if f.contains(CellFlags::DIM) {
        out |= cell_flags::DIM;
    }
    if f.contains(CellFlags::STRIKEOUT) {
        out |= cell_flags::STRIKE;
    }
    out
}

/// Map `alacritty_terminal::term::TermMode` to our stable `bb_mode` bitflags.
fn extract_mode(term_mode: &TermMode) -> u32 {
    let mut m: u32 = 0;
    if term_mode.contains(TermMode::ALT_SCREEN) {
        m |= bb_mode::ALT_SCREEN;
    }
    if term_mode.contains(TermMode::APP_CURSOR) {
        m |= bb_mode::APP_CURSOR;
    }
    if term_mode.contains(TermMode::APP_KEYPAD) {
        m |= bb_mode::APP_KEYPAD;
    }
    if term_mode.contains(TermMode::BRACKETED_PASTE) {
        m |= bb_mode::BRACKETED_PASTE;
    }
    if term_mode.contains(TermMode::MOUSE_REPORT_CLICK) {
        m |= bb_mode::MOUSE_REPORT_CLICK;
    }
    if term_mode.contains(TermMode::MOUSE_MOTION) {
        m |= bb_mode::MOUSE_MOTION;
    }
    if term_mode.contains(TermMode::MOUSE_DRAG) {
        m |= bb_mode::MOUSE_DRAG;
    }
    if term_mode.contains(TermMode::SGR_MOUSE) {
        m |= bb_mode::SGR_MOUSE;
    }
    if term_mode.contains(TermMode::FOCUS_IN_OUT) {
        m |= bb_mode::FOCUS_IN_OUT;
    }
    if term_mode.contains(TermMode::SHOW_CURSOR) {
        m |= bb_mode::SHOW_CURSOR;
    }
    if term_mode.contains(TermMode::LINE_WRAP) {
        m |= bb_mode::LINE_WRAP;
    }
    m
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
        let palette = bb.term.colors();
        let grid = bb.term.grid();

        let rows = grid.screen_lines() as u16;
        let cols = grid.columns() as u16;
        let mut cells: Vec<BBCell> = Vec::with_capacity(rows as usize * cols as usize);

        for indexed in grid.display_iter() {
            cells.push(BBCell {
                ch: indexed.c as u32,
                fg: color_to_rgb(&indexed.fg, palette),
                bg: color_to_rgb(&indexed.bg, palette),
                flags: extract_cell_flags(indexed.flags),
                _reserved: 0,
            });
        }

        let cursor_point = grid.cursor.point;
        // cursor_point.line.0 is a 0-based screen row (Line wraps i32; visible rows are 0..rows-1).
        // cursor_point.column.0 is a 0-based column (Column wraps usize).
        let cursor_row = cursor_point.line.0.max(0) as u16;
        let cursor_col = cursor_point.column.0 as u16;
        // display_offset: lines scrolled above the live grid. When > 0 the
        // `cells` above are from scrollback; the live cursor at `cursor_row`
        // is actually `cursor_row + display_offset` from the top of the
        // visible viewport — and may be below it entirely.
        let display_offset = grid.display_offset().min(u16::MAX as usize) as u16;
        let history_size = grid.history_size().min(u32::MAX as usize) as u32;
        let mode = extract_mode(bb.term.mode());
        // Read current DECSCUSR cursor shape. alacritty_terminal 0.26 exposes
        // `Term::cursor_style() -> CursorStyle` whose `.shape` is one of
        // Block/Underline/Beam/HollowBlock/Hidden. We pack to a stable u8:
        // 0 = block (default), 1 = bar/beam, 2 = underline, 3 = hidden.
        // HollowBlock renders as block in v1 (no dedicated outline shape).
        let cursor_shape: u8 = {
            use alacritty_terminal::vte::ansi::CursorShape;
            match bb.term.cursor_style().shape {
                CursorShape::Block => 0,
                CursorShape::Beam => 1,
                CursorShape::Underline => 2,
                CursorShape::Hidden => 3,
                CursorShape::HollowBlock => 0,
            }
        };
        let owned = BBSnapOwned::new(
            cols,
            rows,
            (cursor_col, cursor_row, true),
            display_offset,
            history_size,
            mode,
            cursor_shape,
            cells,
        );
        // Expose the public `snap` field (first field at offset 0).
        let owned_ptr = Box::into_raw(owned);
        &(*owned_ptr).snap as *const BBSnap
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
        let owned = BBSnapOwned::from_snap_ptr(snap);
        (*owned).rc.fetch_add(1, Ordering::Relaxed);
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
        let owned = BBSnapOwned::from_snap_ptr(snap);
        let prev = (*owned).rc.fetch_sub(1, Ordering::Release);
        if prev == 1 {
            std::sync::atomic::fence(Ordering::Acquire);
            drop(Box::from_raw(owned));
        }
    })
}

/// Scroll the display by `delta` lines. Positive = scroll up (show older
/// content), negative = scroll down (show newer content, towards bottom).
///
/// # Safety
/// Same preconditions as `bb_term_input`. Passing null or delta == 0 is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_scroll(term: *mut BBTerm, delta: i32) {
    guard_with_term(term, (), || {
        if term.is_null() || delta == 0 {
            return;
        }
        let bb = &mut *term;
        use alacritty_terminal::grid::Scroll;
        bb.term.scroll_display(Scroll::Delta(delta));
    })
}

/// Snap the viewport back to the live grid (display_offset = 0). Called after
/// any user keystroke so typing/Enter always brings them back from scrollback
/// history. A no-op if already at the bottom.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_scroll_to_bottom(term: *mut BBTerm) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        let bb = &mut *term;
        use alacritty_terminal::grid::Scroll;
        bb.term.scroll_display(Scroll::Bottom);
    })
}

/// Clear the visible screen AND the scrollback, moving the cursor to the
/// top-left. Implemented by feeding the VT sequences directly to the
/// parser (same path a shell's `clear` would take), so the rest of the
/// terminal state (palette, cursor color, etc.) is untouched.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn bb_term_clear_all(term: *mut BBTerm) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        let bb = &mut *term;
        // H = cursor home, 2J = erase display, 3J = erase scrollback.
        bb.processor.advance(&mut bb.term, b"\x1b[H\x1b[2J\x1b[3J");
    })
}

/// Update one slot of the terminal's color palette. Slot indices match
/// alacritty's `NamedColor` ordering: 0..=15 = 16 ANSI colors, 16..=255 =
/// extended 256-palette, 256 = Foreground, 257 = Background, 258 = Cursor,
/// 259 = BrightForeground, plus a few more (see alacritty's NamedColor enum).
/// `rgb` is packed 0xRRGGBB.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null `term` is a no-op. Out-of-
/// range slots are silently ignored by alacritty's Colors setter.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_named_color(term: *mut BBTerm, slot: u16, rgb: u32) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        let bb = &mut *term;
        let r = ((rgb >> 16) & 0xFF) as u8;
        let g = ((rgb >> 8) & 0xFF) as u8;
        let b = (rgb & 0xFF) as u8;
        use alacritty_terminal::vte::ansi::{Handler, Rgb};
        bb.term.set_color(slot as usize, Rgb { r, g, b });
    })
}

/// Owned UTF-8 byte buffer returned from text-extraction FFIs.
///
/// `bytes`/`len` describe a read-only view into the heap buffer whose raw
/// parts are stored in `_owned_ptr` / `_owned_cap`. The Rust side
/// heap-allocates a `Box<BBString>`, builds the payload as a `Vec<u8>`, then
/// decomposes the vec (ptr + capacity) and installs the pointer into
/// `bytes`. Callers must free via `bb_string_release` exactly once; nothing
/// else keeps the backing allocation alive.
///
/// The `_owned_*` fields are intentionally present in the C-visible layout
/// to keep the struct self-contained (one `Box<BBString>` + one `Vec<u8>`
/// buffer, freed together by `bb_string_release`). Consumers on the C side
/// should read only `bytes` and `len` and otherwise treat the struct as
/// opaque — never poke into the owned fields. Using raw pointer + capacity
/// instead of a literal `Vec<u8>` field lets cbindgen emit a complete,
/// FFI-safe layout that Swift can import: `Vec<u8>` is not `repr(C)`, so a
/// `Vec` field would surface as an incomplete type in the generated header.
#[repr(C)]
pub struct BBString {
    pub bytes: *const u8,
    pub len: usize,
    _owned_ptr: *mut u8,
    _owned_cap: usize,
}

/// Extract UTF-8 text from the terminal buffer between two buffer-relative
/// points. `start_line`/`end_line` are grid lines where 0 is the top of the
/// visible viewport and negative values reach into scrollback (buffer-relative,
/// matching alacritty's `Line(i32)` convention).
///
/// `rect == 0` selects prose mode: the first line is emitted from `start_col`
/// to the end of the row, the last line from column 0 to `end_col`, and
/// middle lines are taken in full. Trailing spaces are trimmed from every
/// line except the last to avoid pulling the grid's blank fill into copied
/// output.
///
/// `rect != 0` selects rectangular mode: every line is clipped to
/// `[start_col, end_col]` with no trimming.
///
/// `\0` cells (alacritty's "unrendered" sentinel) are emitted as spaces. Real
/// spaces come through as-is. Lines outside `[topmost_line, bottommost_line]`
/// are skipped silently. Points are normalized so `(start_line, start_col)
/// <= (end_line, end_col)` before iterating.
///
/// Returns a heap-allocated `BBString` the caller must free with
/// `bb_string_release`. Returns null when `term` is null.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Caller owns the returned pointer.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// null as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_text_range(
    term: *mut BBTerm,
    start_line: i32,
    start_col: u16,
    end_line: i32,
    end_col: u16,
    rect: u8,
) -> *mut BBString {
    guard_with_term(term, std::ptr::null_mut(), || {
        if term.is_null() {
            return std::ptr::null_mut();
        }
        use alacritty_terminal::index::{Column, Line};

        let bb = &*term;
        let grid = bb.term.grid();

        let cols = grid.columns();
        if cols == 0 {
            // No columns to read from; return an empty string for C-side
            // convenience (single allocation pair, len == 0).
            return bb_string_new(Vec::new());
        }
        let last_col = cols - 1;

        // Normalize so (start_line, start_col) <= (end_line, end_col).
        let (s_line, s_col, e_line, e_col) = {
            let a = (start_line, start_col as usize);
            let b = (end_line, end_col as usize);
            let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
            (lo.0, lo.1.min(last_col), hi.0, hi.1.min(last_col))
        };

        let topmost = grid.topmost_line().0;
        let bottommost = grid.bottommost_line().0;

        // Clamp to what actually exists in the grid before iterating. A
        // caller that passes i32::MIN / i32::MAX (or the fuzzer in
        // core/fuzz) would otherwise spin ~4 billion loop iterations that
        // each do nothing but bounds-check and increment.
        let iter_start = s_line.max(topmost);
        let iter_end = e_line.min(bottommost);

        // Collect each line's emitted text, then join with '\n' at the end.
        let mut lines: Vec<String> = Vec::new();

        let rectangular = rect != 0;
        let single_line = s_line == e_line;

        if iter_start > iter_end {
            return bb_string_new(Vec::new());
        }

        let mut line_i = iter_start;
        while line_i <= iter_end {
            let (col_lo, col_hi, trim) = if rectangular {
                // Rectangular mode clips every row to the column span of
                // the bounding box. Tuple-normalisation above only orders
                // (line, col) as a pair, so a rectangle anchored at
                // top-right+bottom-left would land here with s_col > e_col
                // and the inner `while c <= col_hi` loop would skip the
                // row entirely. Sort columns independently so the box's
                // geometry is always extracted.
                (s_col.min(e_col), s_col.max(e_col), false)
            } else if single_line {
                (s_col, e_col, false)
            } else if line_i == s_line {
                (s_col, last_col, true)
            } else if line_i == e_line {
                (0usize, e_col, false)
            } else {
                (0usize, last_col, true)
            };

            let mut text = String::with_capacity(col_hi.saturating_sub(col_lo) + 1);
            let row = &grid[Line(line_i)];
            let mut c = col_lo;
            while c <= col_hi {
                let ch = row[Column(c)].c;
                // alacritty uses '\0' for unrendered/empty cells; surface as
                // a plain space so callers can concatenate without seeing
                // embedded NULs in their UTF-8.
                let out = if ch == '\0' { ' ' } else { ch };
                text.push(out);
                c += 1;
            }

            if trim {
                let trimmed_len = text.trim_end_matches(' ').len();
                text.truncate(trimmed_len);
            }

            lines.push(text);
            line_i += 1;
        }

        let joined = lines.join("\n");
        bb_string_new(joined.into_bytes())
    })
}

/// Allocate a `BBString` wrapping `bytes`. The vec's heap buffer is stolen
/// (via `Vec::into_raw_parts`-style decomposition) and held in `_owned_ptr` +
/// `_owned_cap` so `bb_string_release` can rebuild and drop it.
///
/// # Safety
/// The returned pointer must be released exactly once via `bb_string_release`.
unsafe fn bb_string_new(bytes: Vec<u8>) -> *mut BBString {
    let mut v = bytes;
    v.shrink_to_fit();
    let len = v.len();
    let cap = v.capacity();
    // SAFETY: leaking the vec is safe; its raw parts are recorded below and
    // will be reconstituted in bb_string_release.
    let ptr = v.as_mut_ptr();
    std::mem::forget(v);
    let boxed = Box::new(BBString {
        bytes: ptr as *const u8,
        len,
        _owned_ptr: ptr,
        _owned_cap: cap,
    });
    Box::into_raw(boxed)
}

/// Free a `BBString` returned by `bb_term_text_range`.
///
/// Rebuilds the owned `Vec<u8>` from `_owned_ptr`/`_owned_cap`/`len` so its
/// heap buffer is deallocated with the matching `Vec` allocator, then drops
/// the `Box<BBString>`.
///
/// # Safety
/// `s` must have been returned by `bb_term_text_range` and not previously
/// released. Passing null is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no `BBTerm` context is available). The function returns unit as
/// the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_string_release(s: *mut BBString) {
    guard_no_term((), || {
        if s.is_null() {
            return;
        }
        let boxed = Box::from_raw(s);
        // Reconstitute the owned vec so its heap buffer is freed via the
        // matching `Vec<u8>` allocator. `_owned_ptr` may be a dangling
        // sentinel when `_owned_cap == 0` (empty-string case); that's what
        // `Vec::as_mut_ptr` handed us in `bb_string_new`, and
        // `Vec::from_raw_parts` accepts the round-trip as long as the triple
        // came from a real `Vec`, which it did.
        let _ = Vec::from_raw_parts(boxed._owned_ptr, boxed.len, boxed._owned_cap);
        drop(boxed);
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

            // Lower-level test — reads the grid directly through the Rust API
            // rather than via the FFI snapshot (covered by `snapshot_contains_input`).
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
    fn mode_app_cursor_set_by_decset_1() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            assert!(!term.is_null());

            // Default mode: APP_CURSOR should be off.
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            assert_eq!(
                (*snap).mode & bb_mode::APP_CURSOR,
                0,
                "APP_CURSOR should be clear before DECSET 1"
            );
            bb_snap_release(snap);

            // Send DECSET 1 — enables application cursor keys.
            let seq = b"\x1b[?1h";
            bb_term_input(term, seq.as_ptr(), seq.len());

            let snap2 = bb_term_take_snapshot(term);
            assert!(!snap2.is_null());
            assert_ne!(
                (*snap2).mode & bb_mode::APP_CURSOR,
                0,
                "APP_CURSOR should be set after DECSET 1"
            );
            // Default modes should also be set.
            assert_ne!(
                (*snap2).mode & bb_mode::SHOW_CURSOR,
                0,
                "SHOW_CURSOR should be set by default"
            );
            assert_ne!(
                (*snap2).mode & bb_mode::LINE_WRAP,
                0,
                "LINE_WRAP should be set by default"
            );
            bb_snap_release(snap2);
            bb_term_free(term);
        }
    }

    #[test]
    fn snap_layout_matches_expected() {
        // BBSnap is the C-visible struct (32 bytes). BBSnapOwned wraps it at offset 0.
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
        // Verify BBSnapOwned layout: snap is at offset 0 so pointer casts are sound.
        assert_eq!(
            std::mem::offset_of!(BBSnapOwned, snap),
            0,
            "snap must be at offset 0 in BBSnapOwned"
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

    /// Regression: resize_changes_dimensions covers the nominal case, but the
    /// interesting failure mode is resize + scrollback. Feeding enough lines
    /// to build history and then shrinking should preserve the scrollback
    /// count (alacritty reflows but retains history up to the configured
    /// limit). This catches any future refactor that accidentally drops the
    /// history buffer on resize.
    #[test]
    fn resize_preserves_scrollback_history() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            assert!(!term.is_null());
            // 8 line-feeds past the 3-row screen → 5 lines in history.
            let input = b"aaa\nbbb\nccc\nddd\neee\nfff\nggg\nhhh";
            bb_term_input(term, input.as_ptr(), input.len());

            let before = bb_term_take_snapshot(term);
            let before_hist = (*before).history_size;
            assert!(
                before_hist >= 5,
                "history should have built to >=5 lines, got {}",
                before_hist
            );
            bb_snap_release(before);

            // Shrink vertically. alacritty reflows but keeps history.
            bb_term_resize(term, 10, 2);
            let after = bb_term_take_snapshot(term);
            assert_eq!((*after).rows, 2);
            assert!(
                (*after).history_size >= before_hist,
                "resize shrinking rows must not evict scrollback"
            );
            bb_snap_release(after);

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
    fn text_range_extracts_single_line() {
        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_input(term, b"hello world".as_ptr(), 11);
            let s = bb_term_text_range(term, 0, 0, 0, 10, 0);
            assert!(!s.is_null());
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "hello world");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    #[test]
    fn text_range_spans_multiple_lines() {
        unsafe {
            let term = bb_term_new(5, 3, 100);
            bb_term_input(term, b"aaa\r\nbbb\r\nccc".as_ptr(), 13);
            let s = bb_term_text_range(term, 0, 0, 2, 2, 0);
            assert!(!s.is_null());
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "aaa\nbbb\nccc");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// Regression: before the clamp, feeding i32::MIN / i32::MAX as the
    /// line bounds caused the inner while loop to iterate ~4 billion times
    /// doing nothing but increment. This test should return nearly-instantly
    /// now; if someone removes the clamp it'll hang the test runner (which
    /// is exactly the signal we want).
    #[test]
    fn text_range_clamps_huge_line_range() {
        unsafe {
            let term = bb_term_new(5, 3, 100);
            bb_term_input(term, b"hi".as_ptr(), 2);
            let start = std::time::Instant::now();
            let s = bb_term_text_range(term, i32::MIN, 0, i32::MAX, 4, 0);
            let elapsed = start.elapsed();
            assert!(
                elapsed.as_secs() < 1,
                "text_range with i32::MIN..i32::MAX must be clamped — took {:?}",
                elapsed
            );
            // Only the grid's real lines contribute; "hi" is on line 0.
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            let out = std::str::from_utf8(bytes).unwrap();
            assert!(out.contains("hi"), "expected 'hi' in output, got {out:?}");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    #[test]
    fn text_range_reads_scrollback() {
        unsafe {
            let term = bb_term_new(3, 2, 100);
            bb_term_input(term, b"AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE".as_ptr(), 23);
            let s = bb_term_text_range(term, -3, 0, -3, 2, 0);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "AAA");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// Regression: rectangular selection anchored top-right + bottom-left
    /// arrives with s_col > e_col after tuple-normalisation. The previous
    /// rectangular branch passed those straight into the inner loop, so
    /// `while c <= col_hi` never executed and every line came back empty.
    /// Now sort columns independently.
    #[test]
    fn text_range_rectangular_independent_col_sort() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            bb_term_input(term, b"abcdefghij\r\nABCDEFGHIJ\r\n1234567890".as_ptr(), 32);
            // Anchor at (0, 4), cursor at (2, 2) — rectangular mode. The
            // bounding rect spans cols 2..=4 on rows 0..=2.
            let s = bb_term_text_range(term, 0, 4, 2, 2, 1);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(
                std::str::from_utf8(bytes).unwrap(),
                "cde\nCDE\n345",
                "rectangular mode must extract the bounding rect regardless of corner order"
            );
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    #[test]
    fn text_range_rectangular_clips_columns() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            bb_term_input(term, b"abcdefghij\r\nABCDEFGHIJ\r\n1234567890".as_ptr(), 32);
            let s = bb_term_text_range(term, 0, 2, 2, 4, 1);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "cde\nCDE\n345");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    #[test]
    fn text_range_null_term_returns_null() {
        unsafe {
            assert!(bb_term_text_range(std::ptr::null_mut(), 0, 0, 0, 0, 0).is_null());
        }
    }

    #[test]
    fn string_release_null_is_noop() {
        unsafe {
            bb_string_release(std::ptr::null_mut());
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
    fn set_named_color_changes_background_default() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            bb_term_input(term, b"x".as_ptr(), 1);
            // Slot 257 = NamedColor::Background in alacritty 0.26.
            bb_term_set_named_color(term, 257, 0xFF00AA);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            // Second cell in row 0 wasn't written → uses default bg → now 0xFF00AA.
            assert_eq!(cells[1].bg, 0xFF00AA);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn set_named_color_null_term_is_noop() {
        unsafe {
            bb_term_set_named_color(std::ptr::null_mut(), 0, 0xFFFFFF);
        }
    }

    #[test]
    fn cursor_shape_defaults_to_block() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cursor_shape, 0);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn cursor_shape_set_by_decscusr() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            // DECSCUSR 5 = steady bar (beam).
            bb_term_input(term, b"\x1B[5 q".as_ptr(), 5);
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cursor_shape, 1); // 1 = bar
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// SGR 7 (reverse video) must surface on the cell via the REVERSE flag
    /// so the Metal renderer can draw the inverted highlight. Without this
    /// the vim/less/ncurses highlight bars come through as plain text.
    #[test]
    fn sgr_reverse_sets_cell_reverse_flag() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            // ESC [ 7 m  switches to reverse video; then "A" writes the cell.
            bb_term_input(term, b"\x1b[7mA".as_ptr(), 5);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            assert_eq!(char::from_u32(cells[0].ch), Some('A'));
            assert_ne!(
                cells[0].flags & cell_flags::REVERSE,
                0,
                "cell written under SGR 7 should report REVERSE flag"
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// SGR 2 (dim / faint) — plain text renders normally, dim cells are
    /// surfaced via the DIM flag so the renderer can halve their brightness.
    #[test]
    fn sgr_dim_sets_cell_dim_flag() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            bb_term_input(term, b"\x1b[2mx".as_ptr(), 5);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            assert_ne!(cells[0].flags & cell_flags::DIM, 0);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// SGR 0 (reset) must clear accumulated attribute flags so subsequent
    /// text doesn't inherit the highlight.
    #[test]
    fn sgr_reset_clears_reverse_flag() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            bb_term_input(term, b"\x1b[7mA\x1b[0mB".as_ptr(), 10);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            assert_ne!(
                cells[0].flags & cell_flags::REVERSE,
                0,
                "A should be REVERSE"
            );
            assert_eq!(
                cells[1].flags & cell_flags::REVERSE,
                0,
                "B should not be REVERSE after SGR 0"
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn clear_all_wipes_viewport_and_scrollback() {
        unsafe {
            let term = bb_term_new(3, 2, 100);
            bb_term_input(term, b"AAA\r\nBBB\r\nCCC\r\nDDD".as_ptr(), 16);
            bb_term_clear_all(term);
            let snap = bb_term_take_snapshot(term);
            // Display has 2 rows of blanks. History should be empty.
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            for c in cells {
                assert!(c.ch == 0 || c.ch == b' ' as u32, "got ch={}", c.ch);
            }
            assert_eq!((*snap).history_size, 0, "history not cleared");
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }
}
