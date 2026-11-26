//! blackbird_core — C ABI around `alacritty_terminal`.

use std::os::raw::{c_char, c_void};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Once};

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi::Processor;
use alacritty_terminal::vte::Parser;

/// `total_lines` is only the visible rows: `Term::new` reads the scrollback size from `Config`.
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

mod callback;
mod color;
mod diag;
mod event;
mod guard;
mod input;
mod osc;
mod rate_limit;
mod scrub;
mod snapshot;
mod text;

use callback::*;
use diag::breadcrumb;
pub use event::{BBEvent, BBEventCb, BBEventKind};
use guard::{ffi_reentry_blocked, guard_no_term, guard_with_term};
use input::{flush_sync_update, process_input, sync_status, WEDGED_STRING_CHUNKS};
use rate_limit::*;
pub use snapshot::{bb_mode, cell_flags, BBCell, BBGridState, BBSnap};
use snapshot::{extract_mode_with_extras, grid_state, snapshot, BBSnapOwned};
use text::extract_text_range;

// Kept at the crate root so cbindgen emits this `#define` ahead of `BB_STRING_MAGIC`.
/// Sentinel for `BBCell::underline_color`: no explicit underline colour, use the cell's fg.
pub const UNDERLINE_COLOR_UNSET: u32 = 0xFFFF_FFFF;

/// OSC 133 mark kind: A = prompt start, B = command start, C = command output, D = command end
/// (exit code follows). Values start at 1 so 0 stays reserved for "no mark".
#[repr(u8)]
#[derive(Clone, Copy)]
pub enum BBPromptMarkKind {
    A = 1,
    B = 2,
    C = 3,
    D = 4,
}

/// Hashing and equality go through `to_bytes()` (no NUL) to match `Borrow<[u8]>`.
#[derive(Debug)]
pub(crate) struct UriKey(Arc<std::ffi::CStr>);

impl UriKey {
    pub(crate) fn new(arc: Arc<std::ffi::CStr>) -> Self {
        Self(arc)
    }

    pub(crate) fn arc(&self) -> &Arc<std::ffi::CStr> {
        &self.0
    }
}

impl PartialEq for UriKey {
    fn eq(&self, other: &Self) -> bool {
        self.0.to_bytes() == other.0.to_bytes()
    }
}

impl Eq for UriKey {}

impl std::hash::Hash for UriKey {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.0.to_bytes().hash(state);
    }
}

impl std::borrow::Borrow<[u8]> for UriKey {
    fn borrow(&self) -> &[u8] {
        self.0.to_bytes()
    }
}

/// Opaque handle exposed to Swift.
pub struct BBTerm {
    /// Set after a caught panic; mutating entry points then no-op. `Cell` so `&*term` can set it.
    pub(crate) poisoned: std::cell::Cell<bool>,
    pub(crate) term: Term<RoutingListener>,
    pub(crate) processor: Processor,
    /// Consecutive parser advances that ended inside an OSC / DCS / SOS / PM / APC string.
    pub(crate) string_state_chunks: u32,
    pub(crate) osc_parser: Parser,
    /// Deferred OSC 10/11/12 replies, drained after every `processor.advance`.
    pub(crate) color_queue: Arc<ColorRequestQueue>,
    pub(crate) color_query_enabled: bool,
    /// The host's theme. OSC 104 / 110 / 111 / 112 clear `term.colors()` slots to `None`; this
    /// shadow makes a reset return to the theme, not to the hard-coded xterm tables.
    pub(crate) theme_colors: alacritty_terminal::term::color::Colors,
    /// The prior chunk had an ESC and may have left the OSC parser mid-sequence, so the next one
    /// is advanced through it regardless. ESC-free streams skip that parser entirely.
    pub(crate) osc_possibly_pending: bool,
    pub(crate) osc_tap: crate::osc::OscTapState,
    pub(crate) terminal_version: String,
    pub(crate) prompt_mark_rate: EventRateState,
    pub(crate) osc7_rate: EventRateState,
    pub(crate) startup_hostname: Vec<u8>,
    /// Separate from `osc7_rate`, which rejected sequences must not consume.
    pub(crate) osc7_hostname_rate: EventRateState,
    pub(crate) osc_latches: crate::osc::OscLatches,
    /// Tumbling window: the `ColorRequestQueue` cap bounds one drain interval, not the total.
    pub(crate) color_query_reply_window_start: std::time::Instant,
    pub(crate) color_query_reply_window_count: u32,
    pub(crate) color_query_reply_drop_logged: bool,
    pub(crate) callback: Arc<CallbackCell>,
    /// Persistent OSC 8 URI intern store, shared across snapshots. Over the `uri_cache_bytes`
    /// budget new URIs drop to `link_id = 0` rather than evicting older entries.
    pub(crate) uri_cstr_cache: std::collections::HashSet<UriKey>,
    pub(crate) uri_cache_bytes: usize,
    pub(crate) osc8_id_exhaustion_logged: bool,
    pub(crate) osc8_intern_cap_logged: bool,
    /// Latch for the live-byte budget on retained hyperlink strings (`HYPERLINK_LIVE_MAX`).
    pub(crate) osc8_live_cap_logged: bool,
}

static DIM_CLAMP_LOGGED: Once = Once::new();

/// Below 2 alacritty's reflow math degenerates (a 1-col grid becomes millions of 1-cell rows).
const MIN_DIM: u16 = 2;
/// A caller passing `u16::MAX` would otherwise allocate hundreds of GB.
const MAX_DIM: u16 = 1000;
const SCROLLBACK_MAX: u32 = 200_000;
/// Backstop only: must exceed `SCROLLBACK_MAX + MAX_DIM` so it never truncates a real buffer.
pub(crate) const MAX_TEXT_RANGE_ROWS: u32 = 262_144;

/// Create a terminal; null on a zero dimension or internal error. `cols` / `rows` are clamped to
/// `[2, 1000]`, `scrollback` to 200 000 lines. The handle is NOT thread-safe: every `bb_term_*`
/// call on it must be mutually exclusive (one thread, or one serial queue).
/// # Safety
/// The returned pointer must be freed exactly once via `bb_term_free`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_new(cols: u16, rows: u16, scrollback: u32) -> *mut BBTerm {
    guard_no_term(std::ptr::null_mut(), || {
        if cols == 0 || rows == 0 {
            return std::ptr::null_mut();
        }
        let clamped_cols = cols.clamp(MIN_DIM, MAX_DIM);
        let clamped_rows = rows.clamp(MIN_DIM, MAX_DIM);
        if clamped_cols != cols || clamped_rows != rows {
            DIM_CLAMP_LOGGED.call_once(|| {
                breadcrumb!(
                    "[blackbird_core] dim clamp engaged in bb_term_new: requested=({}, {}) clamped=({}, {}) bounds=[{}, {}]",
                    cols, rows, clamped_cols, clamped_rows, MIN_DIM, MAX_DIM
                );
            });
        }
        let size = TermSize {
            cols: clamped_cols as usize,
            rows: clamped_rows as usize,
        };
        let scrollback = scrollback.min(SCROLLBACK_MAX);
        let config = Config {
            scrolling_history: scrollback as usize,
            // Without this alacritty's kitty keyboard handlers early-return (`ESC[>1u` is ignored).
            kitty_keyboard: true,
            // alacritty's default `Osc52::OnlyCopy` lets any PTY program write the clipboard.
            osc52: alacritty_terminal::term::Osc52::Disabled,
            ..Default::default()
        };

        let pty_write_rate = Arc::new(PtyWriteRateCell::new());
        let callback = Arc::new(CallbackCell::new(Arc::clone(&pty_write_rate)));
        let color_queue = Arc::new(ColorRequestQueue::new());
        let listener = RoutingListener {
            cell: Arc::clone(&callback),
            color_queue: Arc::clone(&color_queue),
        };
        let term = Term::new(config, &size, listener);
        let bb = Box::new(BBTerm {
            term,
            processor: Processor::new(),
            string_state_chunks: 0,
            osc_parser: Parser::new(),
            color_queue,
            color_query_enabled: false,
            theme_colors: Default::default(),
            osc_possibly_pending: false,
            poisoned: std::cell::Cell::new(false),
            osc_tap: crate::osc::OscTapState::default(),
            terminal_version: String::new(),
            callback,
            uri_cstr_cache: std::collections::HashSet::new(),
            uri_cache_bytes: 0,
            osc8_id_exhaustion_logged: false,
            osc8_intern_cap_logged: false,
            osc8_live_cap_logged: false,
            prompt_mark_rate: EventRateState::new(PROMPT_MARK_PER_SECOND, PROMPT_MARK_WINDOW),
            osc7_rate: EventRateState::new(OSC7_INGEST_PER_SECOND, OSC7_INGEST_WINDOW),
            startup_hostname: crate::osc::local_hostname(),
            osc7_hostname_rate: EventRateState::new(OSC7_INGEST_PER_SECOND, OSC7_INGEST_WINDOW),
            osc_latches: crate::osc::OscLatches::default(),
            color_query_reply_window_start: std::time::Instant::now(),
            color_query_reply_window_count: 0,
            color_query_reply_drop_logged: false,
        });
        Box::into_raw(bb)
    })
}

/// Free a terminal. No-op for null and from inside an event callback (the handle leaks instead).
/// # Safety
/// `term` must have been returned by `bb_term_new` and not previously freed.
#[no_mangle]
pub unsafe extern "C" fn bb_term_free(term: *mut BBTerm) {
    guard_no_term((), || {
        if term.is_null() {
            return;
        }
        if ffi_reentry_blocked("bb_term_free") {
            return;
        }
        drop(Box::from_raw(term));
    })
}

/// Feed `len` bytes into the VT parser. A panic is caught and delivered as a `Fatal` event.
/// # Safety
/// `term` must be a live handle from `bb_term_new` with no concurrent `bb_term_*` call on it.
/// `bytes` must be readable for `len` bytes (`null, 0` is a no-op); `len <= isize::MAX`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_input(term: *mut BBTerm, bytes: *const u8, len: usize) {
    guard_with_term(term, (), || {
        if term.is_null() || len == 0 || bytes.is_null() {
            return;
        }
        // A re-entering callback must bail before `&mut *term` below aliases the outer borrow.
        if ffi_reentry_blocked("bb_term_input") {
            return;
        }
        if poison_blocked(term) {
            return;
        }
        if len > isize::MAX as usize {
            panic!(
                "bb_term_input: len {len} exceeds isize::MAX (slice::from_raw_parts precondition)"
            );
        }
        process_input(&mut *term, std::slice::from_raw_parts(bytes, len));
    })
}

/// Resize the grid; zero dimensions are ignored. Prefer `bb_term_resize2`, which reports clamping.
/// # Safety
/// Same preconditions as `bb_term_input`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_resize(term: *mut BBTerm, cols: u16, rows: u16) {
    let _ = bb_term_resize2(term, cols, rows);
}

/// Dimensions the grid was actually resized to after clamping to `[2, 1000]`; `clamped` is
/// non-zero when either differs from the request. All zero on a no-op call.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BBResizeResult {
    pub applied_cols: u16,
    pub applied_rows: u16,
    pub clamped: u8,
    pub _pad: [u8; 3],
}

/// State of the DEC mode 2026 (synchronized output) buffer. vte does NOT self-abort: it only
/// consults its deadline when more bytes arrive, so the embedder must notice expiry and abort.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BBSyncStatus {
    /// Nanoseconds until the core's abort deadline; `0` when not pending or already elapsed.
    pub remaining_ns: u64,
    /// Bytes currently held in the parser's sync buffer (`0 ..= 2 MiB`).
    pub buffered_bytes: u64,
    pub pending: u8,
    /// Non-zero when pending AND the core's deadline has elapsed. The only expiry verdict a
    /// caller may use: do not recompute it from a host clock or hardcode vte's timeout.
    pub expired: u8,
    pub _pad: [u8; 6],
}

impl BBSyncStatus {
    pub(crate) const fn idle() -> Self {
        Self {
            remaining_ns: 0,
            buffered_bytes: 0,
            pending: 0,
            expired: 0,
            _pad: [0; 6],
        }
    }
}

/// Resize the grid and report the applied dimensions (see `BBResizeResult`). When `clamped`, tell
/// `TIOCSWINSZ` the APPLIED size, or the shell and the grid disagree about the viewport.
/// # Safety
/// Same as `bb_term_resize`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_resize2(
    term: *mut BBTerm,
    cols: u16,
    rows: u16,
) -> BBResizeResult {
    let fallback = BBResizeResult {
        applied_cols: 0,
        applied_rows: 0,
        clamped: 0,
        _pad: [0; 3],
    };
    guard_with_term(term, fallback, || {
        if term.is_null() || cols == 0 || rows == 0 {
            return fallback;
        }
        if ffi_reentry_blocked("bb_term_resize2") {
            return fallback;
        }
        if poison_blocked(term) {
            return fallback;
        }
        let bb = &mut *term;
        let applied_cols = cols.clamp(MIN_DIM, MAX_DIM);
        let applied_rows = rows.clamp(MIN_DIM, MAX_DIM);
        let clamped_flag = applied_cols != cols || applied_rows != rows;
        if clamped_flag {
            DIM_CLAMP_LOGGED.call_once(|| {
                breadcrumb!(
                    "[blackbird_core] dim clamp engaged in bb_term_resize2: requested=({}, {}) clamped=({}, {}) bounds=[{}, {}]",
                    cols, rows, applied_cols, applied_rows, MIN_DIM, MAX_DIM
                );
            });
        }
        let size = TermSize {
            cols: applied_cols as usize,
            rows: applied_rows as usize,
        };
        bb.term.resize(size);
        BBResizeResult {
            applied_cols,
            applied_rows,
            clamped: u8::from(clamped_flag),
            _pad: [0; 3],
        }
    })
}

/// Register the event callback (`cb = None` clears it); `ctx` is forwarded verbatim. Null no-ops.
/// # Safety
/// `term` and `ctx` must stay valid while the callback is registered. The callback may run
/// synchronously inside `bb_term_input` and must not call any `bb_term_*` function on that handle.
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
        if ffi_reentry_blocked("bb_term_set_event_cb") {
            return;
        }
        (*term).callback.set(cb, ctx);
    })
}

/// Register the process-wide diagnostic sink (breadcrumbs, panic `file:line`). Set-once: the first
/// non-null registration wins. `cb` receives a UTF-8 message (not NUL-terminated) valid only for
/// the call, on any thread, and must not call any `bb_term_*` function.
/// # Safety
/// `cb` must stay valid for the life of the process.
#[no_mangle]
pub unsafe extern "C" fn bb_set_log_cb(cb: Option<unsafe extern "C" fn(*const u8, usize)>) {
    guard_no_term((), || {
        if let Some(cb) = cb {
            diag::install(cb);
        }
    })
}

/// Take an immutable snapshot of the grid. Returns null on null input.
/// # Safety
/// Same preconditions as `bb_term_input`. The result must be released by exactly one
/// `bb_snap_release` per successful call (plus one per `bb_snap_retain`).
#[no_mangle]
pub unsafe extern "C" fn bb_term_take_snapshot(term: *mut BBTerm) -> *const BBSnap {
    guard_with_term(term, std::ptr::null(), || {
        if term.is_null() {
            return std::ptr::null();
        }
        if ffi_reentry_blocked("bb_term_take_snapshot") {
            return std::ptr::null();
        }
        snapshot(&mut *term)
    })
}

/// Increment the refcount and return `snap`. Null is a no-op. Safe to call from any thread.
/// # Safety
/// `snap` must come from `bb_term_take_snapshot` / `bb_snap_retain` and not be released to zero.
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

/// Decrement the refcount; free at zero. Null is a no-op. Safe to call from any thread.
/// # Safety
/// Each `snap` must be released exactly once per acquire (take or retain).
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

/// OSC 8 link id at a snapshot cell; 0 for null, out-of-grid or no link. Safe from any thread.
/// # Safety
/// Same as `bb_snap_retain`.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_link_id_at(snap: *const BBSnap, row: u16, col: u16) -> u32 {
    guard_no_term(0u32, || {
        if snap.is_null() {
            return 0;
        }
        let s = &*snap;
        if (row as usize) >= (s.rows as usize) || (col as usize) >= (s.cols as usize) {
            return 0;
        }
        let idx = (row as usize) * (s.cols as usize) + (col as usize);
        if idx >= s.cells_len {
            return 0;
        }
        let cell = &*s.cells.add(idx);
        cell.link_id as u32
    })
}

/// Resolve an OSC 8 link id to its UTF-8 URL; null for a null `snap`, id 0 or an unknown id. The
/// pointer is valid for the snapshot's lifetime. Safe to call from any thread.
/// # Safety
/// Same as `bb_snap_retain`.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_link_url(
    snap: *const BBSnap,
    link_id: u32,
) -> *const std::os::raw::c_char {
    guard_no_term(std::ptr::null(), || {
        if snap.is_null() || link_id == 0 {
            return std::ptr::null();
        }
        let owned = BBSnapOwned::from_snap_ptr(snap);
        let links = &(*owned).links;
        match links.get(link_id as usize) {
            Some(cstr) => cstr.as_ptr(),
            None => std::ptr::null(),
        }
    })
}

/// Copy the zero-width scalars (combining marks, VS16, ZWJ) of the cell at `(row, col)` into
/// `out`. Returns the TOTAL count, which may exceed `out_cap`; `out = null` probes the count.
/// # Safety
/// `snap` as for `bb_snap_retain`. `out` must be null or writable for `out_cap * 4` bytes; no
/// u32 alignment is required. Safe to call from any thread.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_zerowidth_at(
    snap: *const BBSnap,
    row: u16,
    col: u16,
    out: *mut u32,
    out_cap: usize,
) -> usize {
    guard_no_term(0usize, || {
        if snap.is_null() {
            return 0;
        }
        let s = &*snap;
        if (row as usize) >= (s.rows as usize) || (col as usize) >= (s.cols as usize) {
            return 0;
        }
        let idx = (row as usize) * (s.cols as usize) + (col as usize);
        let owned = BBSnapOwned::from_snap_ptr(snap);
        let marks = (*owned).zerowidth.at(idx);
        let total = marks.len();
        if out.is_null() || out_cap == 0 {
            return total;
        }
        let n = total.min(out_cap);
        std::ptr::copy_nonoverlapping(
            marks.as_ptr() as *const u8,
            out as *mut u8,
            n * std::mem::size_of::<u32>(),
        );
        total
    })
}

/// Toggle OSC 10 / 11 / 12 `?` replies. Off by default: a reply puts the palette back into the PTY.
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_color_query_enabled(term: *mut BBTerm, enabled: u8) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        if ffi_reentry_blocked("bb_term_set_color_query_enabled") {
            return;
        }
        if poison_blocked(term) {
            return;
        }
        (*term).color_query_enabled = enabled != 0;
    })
}

/// Set the version string XTVERSION replies carry (`DCS > | Blackbird <v> ST`). ASCII printable
/// only, capped at 32 bytes; anything else is rejected. Null clears it.
/// # Safety
/// Same preconditions as `bb_term_input`; `version` must be a NUL-terminated C string or null.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_terminal_version(term: *mut BBTerm, version: *const c_char) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        if ffi_reentry_blocked("bb_term_set_terminal_version") {
            return;
        }
        if poison_blocked(term) {
            return;
        }
        let bb = &mut *term;
        if version.is_null() {
            bb.terminal_version.clear();
            return;
        }
        let bytes = std::ffi::CStr::from_ptr(version).to_bytes();
        if bytes.len() > 32 || !bytes.iter().all(|b| b.is_ascii_graphic()) {
            return;
        }
        bb.terminal_version = String::from_utf8_lossy(bytes).into_owned();
    })
}

/// Allow (`enabled != 0`) or refuse OSC 52 clipboard WRITES; reads (`?`) are never answered. Off
/// at `bb_term_new`. An accepted write arrives as `BBEventKind::Osc52Clipboard`, decoded.
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_osc52_write_enabled(term: *mut BBTerm, enabled: u8) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        if ffi_reentry_blocked("bb_term_set_osc52_write_enabled") {
            return;
        }
        if poison_blocked(term) {
            return;
        }
        let policy = if enabled != 0 {
            alacritty_terminal::term::Osc52::OnlyCopy
        } else {
            alacritty_terminal::term::Osc52::Disabled
        };
        (*term).term.set_osc52(policy);
    })
}

/// Current terminal mode as a `bb_mode::*` union. O(1), no snapshot. Null returns 0.
/// # Safety
/// Same preconditions as `bb_term_input`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_current_mode(term: *mut BBTerm) -> u32 {
    guard_with_term(term, 0u32, || {
        if term.is_null() {
            return 0;
        }
        if ffi_reentry_blocked("bb_term_current_mode") {
            return 0;
        }
        let bb = &*term;
        extract_mode_with_extras(bb)
    })
}

/// Read `BBGridState` without a snapshot: O(1), no damage drain. Null returns all-zero (`cols` 0).
/// # Safety
/// Same preconditions as `bb_term_input`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_grid_state(term: *mut BBTerm) -> BBGridState {
    guard_with_term(term, BBGridState::default(), || {
        if term.is_null() {
            return BBGridState::default();
        }
        if ffi_reentry_blocked("bb_term_grid_state") {
            return BBGridState::default();
        }
        grid_state(&*term)
    })
}

/// Read the DEC 2026 sync state: O(1), no mutation, no events. Null returns "nothing pending".
/// # Safety
/// Same preconditions as `bb_term_input`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_sync_status(term: *mut BBTerm) -> BBSyncStatus {
    guard_with_term(term, BBSyncStatus::idle(), || {
        if term.is_null() {
            return BBSyncStatus::idle();
        }
        if ffi_reentry_blocked("bb_term_sync_status") {
            return BBSyncStatus::idle();
        }
        sync_status(&*term)
    })
}

/// Non-zero once a caught panic has poisoned this terminal; 0 for null or a re-entrant call.
/// # Safety
/// `term` must be null or a handle returned by `bb_term_new` that has not been freed.
#[no_mangle]
pub unsafe extern "C" fn bb_term_is_poisoned(term: *const BBTerm) -> u8 {
    if term.is_null() {
        return 0;
    }
    if ffi_reentry_blocked("bb_term_is_poisoned") {
        return 0;
    }
    u8::from(poison_blocked(term))
}

/// Terminate a pending DEC 2026 synchronized update, replaying its buffered bytes into the grid
/// (the replay can fire events, as `bb_term_input` does). Returns `1` iff one was terminated.
/// `force == 0` acts only once the core's own deadline has elapsed; `force == 1` always aborts.
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op returning `0`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_flush_sync_update(term: *mut BBTerm, force: u8) -> u8 {
    guard_with_term(term, 0u8, || {
        if term.is_null() {
            return 0;
        }
        if ffi_reentry_blocked("bb_term_flush_sync_update") {
            return 0;
        }
        if poison_blocked(term) {
            return 0;
        }
        u8::from(flush_sync_update(&mut *term, force != 0))
    })
}

/// Re-attempt delivery of an OSC 52 write the rate cap held back, without more PTY input. Returns
/// `0` when nothing is held back, else the nanoseconds to wait before calling again.
/// # Safety
/// Same preconditions as `bb_term_input`. Null returns `0`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_flush_suppressed_osc52(term: *mut BBTerm) -> u64 {
    guard_with_term(term, 0u64, || {
        if term.is_null() {
            return 0;
        }
        if ffi_reentry_blocked("bb_term_flush_suppressed_osc52") {
            return 0;
        }
        if poison_blocked(term) {
            return 0;
        }
        match (*term).callback.flush_suppressed_osc52() {
            // Never 0 for a still-held write, so 0 stays "nothing pending".
            Some(wait) => u64::try_from(wait.as_nanos()).unwrap_or(u64::MAX).max(1),
            None => 0,
        }
    })
}

/// Non-zero when every row needs a redraw, regardless of `bb_snap_damage_rows`. Null returns 1.
/// # Safety
/// Same as `bb_snap_retain`.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_damage_is_full(snap: *const BBSnap) -> u8 {
    guard_no_term(1u8, || {
        if snap.is_null() {
            return 1;
        }
        let owned = BBSnapOwned::from_snap_ptr(snap);
        if (*owned).damage_full {
            1
        } else {
            0
        }
    })
}

/// Copy the damaged-row indices into `out`. Returns the TOTAL count (may exceed `out_cap`;
/// `out = null` probes it), or 0 when the damage is full: check `bb_snap_damage_is_full` first.
/// # Safety
/// `snap` as for `bb_snap_retain`. `out` must be null or writable for `out_cap * 2` bytes; no
/// u16 alignment is required. Safe to call from any thread.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_damage_rows(
    snap: *const BBSnap,
    out: *mut u16,
    out_cap: usize,
) -> usize {
    guard_no_term(0usize, || {
        if snap.is_null() {
            return 0;
        }
        let owned = BBSnapOwned::from_snap_ptr(snap);
        if (*owned).damage_full {
            return 0;
        }
        let rows = &(*owned).damaged_rows;
        let total = rows.len();
        if out.is_null() || out_cap == 0 {
            return total;
        }
        let n = total.min(out_cap);
        std::ptr::copy_nonoverlapping(
            rows.as_ptr() as *const u8,
            out as *mut u8,
            n * std::mem::size_of::<u16>(),
        );
        total
    })
}

/// Scroll the display by `delta` lines: positive shows older content, negative newer.
/// # Safety
/// Same preconditions as `bb_term_input`. Passing null or delta == 0 is a no-op.
#[no_mangle]
pub unsafe extern "C" fn bb_term_scroll(term: *mut BBTerm, delta: i32) {
    guard_with_term(term, (), || {
        if term.is_null() || delta == 0 {
            return;
        }
        if ffi_reentry_blocked("bb_term_scroll") {
            return;
        }
        if poison_blocked(term) {
            return;
        }
        let bb = &mut *term;
        use alacritty_terminal::grid::Scroll;
        bb.term.scroll_display(Scroll::Delta(delta));
    })
}

/// Snap the viewport back to the live grid (display_offset = 0).
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn bb_term_scroll_to_bottom(term: *mut BBTerm) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        if ffi_reentry_blocked("bb_term_scroll_to_bottom") {
            return;
        }
        if poison_blocked(term) {
            return;
        }
        let bb = &mut *term;
        use alacritty_terminal::grid::Scroll;
        bb.term.scroll_display(Scroll::Bottom);
    })
}

/// Clear the visible screen AND the scrollback and home the cursor. The palette is preserved;
/// rate-limiter, cache and OSC / DCS scanner state are reset. The grid parser is NOT reset, so a
/// sequence split across the clear completes; a string open across more than one chunk is dropped.
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn bb_term_clear_all(term: *mut BBTerm) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        if ffi_reentry_blocked("bb_term_clear_all") {
            return;
        }
        if poison_blocked(term) {
            return;
        }
        let bb = &mut *term;
        // Abort a pending DEC 2026 update FIRST: its replay draws into the grid the clear erases.
        let _ = flush_sync_update(bb, true);
        // Handler calls, deliberately NOT `ESC[H` / `ESC[2J` / `ESC[3J` through `bb.processor`:
        // the parser may be mid-sequence, and an injected ESC would abort or truncate it.
        {
            use alacritty_terminal::vte::ansi::{ClearMode, Handler};
            bb.term.goto(0, 0);
            bb.term.clear_screen(ClearMode::All);
            bb.term.clear_screen(ClearMode::Saved);
        }
        bb.term.clear_inactive_grid();
        // A string open since before the PREVIOUS chunk is a wedged sender, not a split: drop it.
        if bb.string_state_chunks >= WEDGED_STRING_CHUNKS && bb.processor.abort_string() {
            bb.string_state_chunks = 0;
        }
        // Reset the tap's own parser: a mid-DCS XTGETTCAP must not accumulate post-clear bytes.
        bb.osc_parser = Parser::new();
        bb.osc_possibly_pending = false;
        bb.osc_tap.reset();
        bb.color_query_reply_window_start = std::time::Instant::now();
        bb.color_query_reply_window_count = 0;
        bb.color_query_reply_drop_logged = false;

        bb.prompt_mark_rate = EventRateState::new(PROMPT_MARK_PER_SECOND, PROMPT_MARK_WINDOW);
        bb.osc7_rate = EventRateState::new(OSC7_INGEST_PER_SECOND, OSC7_INGEST_WINDOW);
        bb.osc7_hostname_rate = EventRateState::new(OSC7_INGEST_PER_SECOND, OSC7_INGEST_WINDOW);
        bb.callback.pty_write_rate.reset();
        bb.callback.reset_event_rates();

        // Clear unconditionally, not `retain(strong_count > 1)`: Swift still pins the pre-clear
        // snapshot here, so retain would keep everything. Snapshots hold their own Arc clones.
        bb.uri_cstr_cache.clear();
        bb.osc8_intern_cap_logged = false;
        bb.osc8_live_cap_logged = false;
        bb.uri_cache_bytes = 0;
    })
}

/// Update one palette slot; `rgb` is packed 0xRRGGBB. Slots follow alacritty's `NamedColor`:
/// 0..=255 = palette, 256 = Foreground, 257 = Background, 258 = Cursor, 259..=266 =
/// DimBlack..DimWhite, 267 = BrightForeground, 268 = DimForeground. Other slots are ignored.
/// # Safety
/// Same preconditions as `bb_term_input`. Null `term` is a no-op.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_named_color(term: *mut BBTerm, slot: u16, rgb: u32) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        if ffi_reentry_blocked("bb_term_set_named_color") {
            return;
        }
        if poison_blocked(term) {
            return;
        }
        let bb = &mut *term;
        // `Term::set_color` panics out of range; libFuzzer aborts before `catch_unwind` runs.
        if (slot as usize) >= alacritty_terminal::term::color::COUNT {
            return;
        }
        let r = ((rgb >> 16) & 0xFF) as u8;
        let g = ((rgb >> 8) & 0xFF) as u8;
        let b = (rgb & 0xFF) as u8;
        use alacritty_terminal::vte::ansi::{Handler, Rgb};
        bb.term.set_color(slot as usize, Rgb { r, g, b });
        bb.theme_colors[slot as usize] = Some(Rgb { r, g, b });
    })
}

/// Owned UTF-8 buffer returned from text-extraction FFIs. Read only `bytes` and `len`
/// (`bytes == NULL ⇔ len == 0`); free exactly once via `bb_string_release`.
#[repr(C)]
pub struct BBString {
    pub bytes: *const u8,
    pub len: usize,
    _owned_ptr: *mut u8,
    _owned_cap: usize,
    /// `BB_STRING_MAGIC` when live, `0` after release.
    _magic: u64,
}

pub const BB_STRING_MAGIC: u64 = 0xB1AC_5BBD_5721_57E0;

/// Extract UTF-8 text between two points; line 0 is the top of the viewport and negative lines
/// reach into scrollback. `flags`: bit 0 = rectangular (clip every line to `[start_col, end_col]`,
/// no trimming), bit 1 = keep a tab's blank fill (one char per cell), bit 2 = end every line with
/// `\r` if it soft-wrapped and `\n` if not. Returns a `BBString` to free with `bb_string_release`;
/// null on a null `term` or a caught panic. A zero-area range returns an empty `BBString`.
/// # Safety
/// Same preconditions as `bb_term_input`. Caller owns the returned pointer.
#[no_mangle]
pub unsafe extern "C" fn bb_term_text_range(
    term: *mut BBTerm,
    start_line: i32,
    start_col: u16,
    end_line: i32,
    end_col: u16,
    flags: u8,
) -> *mut BBString {
    guard_with_term(term, std::ptr::null_mut(), || {
        if term.is_null() {
            return std::ptr::null_mut();
        }
        if ffi_reentry_blocked("bb_term_text_range") {
            return std::ptr::null_mut();
        }
        bb_string_new(extract_text_range(
            &*term, start_line, start_col, end_line, end_col, flags,
        ))
    })
}

/// An empty payload publishes null `bytes`, never `Vec`'s `NonNull::dangling()`.
/// # Safety
/// The returned pointer must be released exactly once via `bb_string_release`.
unsafe fn bb_string_new(bytes: Vec<u8>) -> *mut BBString {
    if bytes.is_empty() {
        drop(bytes);
        let boxed = Box::new(BBString {
            bytes: std::ptr::null(),
            len: 0,
            _owned_ptr: std::ptr::null_mut(),
            _owned_cap: 0,
            _magic: BB_STRING_MAGIC,
        });
        return Box::into_raw(boxed);
    }
    let mut v = bytes;
    v.shrink_to_fit();
    let len = v.len();
    let cap = v.capacity();
    let ptr = v.as_mut_ptr();
    std::mem::forget(v);
    let boxed = Box::new(BBString {
        bytes: ptr as *const u8,
        len,
        _owned_ptr: ptr,
        _owned_cap: cap,
        _magic: BB_STRING_MAGIC,
    });
    Box::into_raw(boxed)
}

/// Free a `BBString`. Null is a no-op. A `_magic` mismatch (double free, wild pointer) returns
/// without freeing; concurrent releases of the SAME pointer are tolerated (one CAS wins).
/// # Safety
/// `s` must have been returned by `bb_term_text_range` and not previously released.
#[no_mangle]
pub unsafe extern "C" fn bb_string_release(s: *mut BBString) {
    guard_no_term((), || {
        if s.is_null() {
            return;
        }
        // SAFETY (from_ptr): `_magic` was initialised before the pointer was published, and for
        // the lifetime of this call every access to it goes through `AtomicU64::from_ptr`.
        let magic_ptr = std::ptr::addr_of!((*s)._magic) as *mut u64;
        let magic_atomic = AtomicU64::from_ptr(magic_ptr);
        match magic_atomic.compare_exchange(BB_STRING_MAGIC, 0, Ordering::AcqRel, Ordering::Acquire)
        {
            Ok(_) => {
                // We claimed the deallocation; a concurrent release observes magic=0.
            }
            Err(found) => {
                // Zero magic => already released. Any other value => wild/uninitialized pointer.
                breadcrumb!(
                    "bb_string_release: magic mismatch (got {:#x}, expected {:#x}); \
                     refusing to free possibly-invalid BBString",
                    found,
                    BB_STRING_MAGIC
                );
                return;
            }
        }
        let boxed = Box::from_raw(s);
        // `_owned_ptr` is null for an empty payload; `from_raw_parts` on null is UB even at cap 0.
        if !boxed._owned_ptr.is_null() {
            let _ = Vec::from_raw_parts(boxed._owned_ptr, boxed.len, boxed._owned_cap);
        }
        drop(boxed);
    })
}

/// True for a bidi-control / zero-width / invisible scalar; false for invalid code points.
#[no_mangle]
pub extern "C" fn bb_is_bidi_or_invisible_scalar(scalar: u32) -> bool {
    match char::from_u32(scalar) {
        Some(c) => scrub::is_bidi_or_invisible_scalar(c),
        None => false,
    }
}

/// Grid cells `Term::input` gives `scalar` when printed: 0 for zero-width marks, joiners,
/// variation selectors, control characters and invalid code points; 1; or 2 for wide glyphs.
#[no_mangle]
pub extern "C" fn bb_scalar_cell_width(scalar: u32) -> u8 {
    use unicode_width::UnicodeWidthChar;
    match char::from_u32(scalar).and_then(|c| c.width()) {
        // `Term::input` treats any width other than 0 or 1 as 2 cells; U+FDFD reports 3.
        Some(width) => width.min(2) as u8,
        None => 0,
    }
}

/// Test-only: force a panic inside the FFI boundary to verify Fatal event delivery.
/// # Safety
/// `term` must be a valid non-null pointer from `bb_term_new`, not freed during the call.
#[no_mangle]
#[cfg(any(test, feature = "test-only"))]
pub unsafe extern "C" fn bb_term_test_only_panic(term: *mut BBTerm) {
    guard_with_term(term, (), || {
        if ffi_reentry_blocked("bb_term_test_only_panic") {
            return;
        }
        panic!("intentional test panic");
    });
}

#[cfg(test)]
mod tests;

/// Mutating entries call this AFTER their `ffi_reentry_blocked` check (read-only entries stay
/// open): it reads through `*term`, which would alias the outer `&mut BBTerm` on re-entry.
/// # Safety
/// `term` must point at a live `BBTerm` with no `&mut BBTerm` derived from it live on this thread.
unsafe fn poison_blocked(term: *const BBTerm) -> bool {
    (*term).poisoned.get()
}
