//! blackbird_core — C ABI around `alacritty_terminal`.

use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Once};

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi::Processor;
use alacritty_terminal::vte::Parser;

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
// Submodules — extracted from the original monolith (REFACTOR.md Wave 1).
// Each is re-exported below so `blackbird_core::*` and the cbindgen header
// stay byte-identical.
// ---------------------------------------------------------------------------

mod callback;
mod color;
mod event;
mod osc;
mod rate_limit;
mod scrub;
mod snapshot;
mod text;

use callback::*;
use color::*;
pub use event::{BBEvent, BBEventCb, BBEventKind};
use osc::*;
use rate_limit::*;
pub use snapshot::{bb_mode, cell_flags, BBCell, BBSnap};
use snapshot::{extract_mode_with_extras, snapshot, BBSnapOwned};
use text::extract_text_range;

// NB: kept at the crate root (not in `snapshot`) purely so cbindgen emits this
// `#define` ahead of `BB_STRING_MAGIC`, keeping the generated header byte-for-
// byte identical. The doc below is verbatim from its former snapshot.rs home.
/// Sentinel for `BBCell::underline_color` meaning "no explicit underline
/// colour set; use the cell's fg". Chosen as u32::MAX because alacritty's
/// RGB representation tops out at 0x00FF_FFFF and 0xFF000000 bits are
/// otherwise unused — picking a sentinel outside the valid RGB range avoids
/// a flag bit.
pub const UNDERLINE_COLOR_UNSET: u32 = 0xFFFF_FFFF;

/// Shape of the OSC 133 prompt/command mark the shell emitted.
///
/// Values match the C enum layout — Swift casts these integers directly.
/// A / B / C / D are the four standard kinds in the de-facto prompt-marks
/// spec (Apple Terminal, iTerm2, kitty, Ghostty):
///   A = prompt start     — "I'm about to draw my prompt"
///   B = command start    — "prompt done, user is typing the command"
///   C = command output   — "user pressed enter, command is running"
///   D = command end      — "command finished, exit code follows"
/// Numeric values start at 1 so 0 stays reserved for "no mark".
#[repr(u8)]
#[derive(Clone, Copy)]
pub enum BBPromptMarkKind {
    A = 1,
    B = 2,
    C = 3,
    D = 4,
}

// ---------------------------------------------------------------------------
// BBTerm
// ---------------------------------------------------------------------------

/// Opaque handle exposed to Swift.
///
/// `callback` and `color_queue` are shared with the owned `Term`'s
/// `RoutingListener` via `Arc`. Field drop order between `term` and the
/// cells is no longer load-bearing for memory safety (rust-core-1 F3):
/// each Arc keeps its inner cell alive as long as any clone exists, so an
/// event firing during `Term`'s destruction still lands on live memory.
pub struct BBTerm {
    pub(crate) term: Term<RoutingListener>,
    pub(crate) processor: Processor,
    /// Parallel `vte::Parser` that drives `OscScanner` for OSC 7 (cwd) and
    /// OSC 133 (prompt marks). Stateful across `bb_term_input` calls so
    /// fragmented sequences resolve to a single event. Kept separate from
    /// alacritty's internal parser so we never perturb the grid-mutation
    /// path. Consolidated from two parsers into one on 2026-04-19 —
    /// throughput tests showed running bytes through three parsers
    /// (alacritty + 2 parallels) cost ~15 % versus two parsers.
    pub(crate) osc_parser: Parser,
    /// Deferred queue of OSC 10/11/12 color-query responses — see
    /// ColorRequestQueue. Drained after every `processor.advance` call in
    /// `bb_term_input` so the response writes land in the same input
    /// batch that emitted the query. Responses are actually emitted only
    /// when `color_query_enabled` is true.
    pub(crate) color_queue: Arc<ColorRequestQueue>,
    /// Whether OSC 10 / 11 / 12 `?` queries produce a reply. Off by
    /// default: historically, replying leaked the palette back into the
    /// PTY, which zsh-vi-mode could interpret as commands (CVE class on
    /// older shells). Users who want nvim / tmux auto-theming on a
    /// modern shell can opt in via Preferences. See
    /// `core/tests/terminal_replies.rs::osc_10_11_color_queries_are_silent`
    /// for the default-off pinning.
    pub(crate) color_query_enabled: bool,
    /// Latch: "the prior `bb_term_input` chunk contained an ESC byte and
    /// may have left the OSC parser mid-sequence." When this is set, we
    /// advance the OSC parser regardless of whether the current chunk has
    /// ESC/BEL, so a split sequence (`\x1b]7;file://pa` + `th\x1b\\`)
    /// resolves correctly. Cleared when we advance on a chunk with NO
    /// ESC — which means either the prior sequence terminated in-chunk
    /// (BEL seen, or ESC\ fully present) or we had a false latch. For
    /// pure-text streams (no ESC anywhere), both bits stay false and we
    /// skip the osc_parser entirely — the dominant case for `yes(1)`,
    /// `cat` on logs, and pipe output. Saves ~10-15 % on plain_text.
    pub(crate) osc_possibly_pending: bool,
    /// XTGETTCAP (Kitty capability query) parser state. `in_xtgettcap`
    /// latches true between `hook` (header `DCS + q` seen) and `unhook`
    /// (ST terminator seen); `xtgettcap_buf` accumulates the payload
    /// bytes. Persists across `bb_term_input` calls so a DCS fragmented
    /// across PTY reads resolves to a single reply. See `OscScanner`'s
    /// `hook`/`put`/`unhook` and `core/tests/xtgettcap.rs`.
    pub(crate) in_xtgettcap: bool,
    pub(crate) xtgettcap_buf: Vec<u8>,
    /// xterm `modifyOtherKeys` current level. `0` = off, `1` = level 1
    /// (encode colliders + "unmapped" Ctrl combos), `2` = level 2
    /// (encode every modified printable, overriding legacy byte
    /// mappings). Driven by parser observations of `CSI > 4 ; N m`.
    /// Swift-side KeyEncoder reads this indirectly via
    /// `bb_mode::MODIFY_OTHER_KEYS` (any non-zero level → bit set).
    pub(crate) modify_other_keys: u8,
    /// OSC 133 A/B/C rate-limit window (audit synthesis #10). See
    /// `PromptMarkRateState`. Persisted across `bb_term_input` calls so
    /// the sliding window covers prompt marks that arrive in different
    /// PTY chunks.
    pub(crate) prompt_mark_rate: PromptMarkRateState,
    /// OSC 7 (CWD) ingest rate-limit window (audit M-7). See
    /// `Osc7RateState`. Persisted across `bb_term_input` calls — same
    /// rationale as `prompt_mark_rate`.
    pub(crate) osc7_rate: Osc7RateState,
    /// OSC 7 reject-log latches, one bool per `OSC7_REJECT_*` class
    /// index. Audit L3: pre-fix these were a process-wide
    /// `static [Once; 8]`, so the first BBTerm in the process to hit
    /// each rejection class consumed the latch and sibling tabs (or
    /// reborn shells in the same tab) silently dropped the same
    /// reject. Per-instance flags restore one-shot-per-session log
    /// semantics without re-introducing log flood.
    pub(crate) osc7_reject_logged: [bool; 8],
    /// One-shot latch for the OSC 133 D non-digit reject path (audit
    /// L1 + reviewer follow-up). Same per-instance / one-shot rule
    /// as `osc7_reject_logged` but only one class so a single bool
    /// suffices.
    pub(crate) osc133_d_nondigit_logged: bool,
    /// One-shot latch for the OSC 133 A/B/C tainted-payload reject path
    /// (audit S3R-001/S3R-002). Same per-instance / one-shot rule as
    /// `osc133_d_nondigit_logged`.
    pub(crate) osc133_abc_tainted_logged: bool,
    /// One-shot latch for the OSC 133 rate-cap drop breadcrumb (audit
    /// S5-009). Same per-instance / one-shot rule as its siblings.
    pub(crate) osc133_rate_limited_logged: bool,
    /// OSC 10/11/12 color-query reply sliding-window state (bug #17). The
    /// per-call `ColorRequestQueue` cap stops a single chunk from forcing
    /// 256+ allocations, but a hostile stream can fan replies across many
    /// chunks. Gating each `PtyWrite` reply in `drain_color_requests` by
    /// this 1-second window with `COLOR_QUERY_REPLY_PER_SECOND` cap makes
    /// the rate limit total, not per-call. Persisted across
    /// `bb_term_input` calls for the same reason as `prompt_mark_rate`.
    pub(crate) color_query_reply_window_start: std::time::Instant,
    pub(crate) color_query_reply_window_count: u32,
    pub(crate) callback: Arc<CallbackCell>,
    /// Persistent OSC 8 URI intern store (rust-core-3 F1). Maps URI string →
    /// shared `Arc<CStr>`; entries survive across snapshots so the same URI
    /// appearing frame after frame is interned exactly once (not per-snapshot).
    /// A new snapshot pushes `Arc::clone(&cstr)` into its local `links` Vec —
    /// cheap (one atomic increment) vs. the old `CString::new(uri.to_owned())`
    /// per appearance.
    ///
    /// Bounded globally by `uri_cache_bytes` against
    /// `OSC8_TOTAL_INTERN_BYTES_CAP` (1 MiB) so a hostile TUI writing
    /// distinct 4 KiB URIs cannot retain arbitrary megabytes of CStrings.
    /// When the budget would be exceeded, new URIs silently drop to
    /// `link_id = 0` (no link) rather than evicting older entries —
    /// eviction would invalidate the `*const c_char` returned by
    /// `bb_snap_link_url` on still-live snapshots that reference those
    /// Arcs.
    pub(crate) uri_cstr_cache: std::collections::HashMap<String, Arc<std::ffi::CStr>>,
    /// Total bytes currently retained by `uri_cstr_cache` (sum of URI byte
    /// lengths, excluding the terminating NUL). Drives the
    /// `OSC8_TOTAL_INTERN_BYTES_CAP` gate in `bb_term_take_snapshot`.
    pub(crate) uri_cache_bytes: usize,
    /// One-shot latch: have we already emitted the per-snapshot
    /// `id-exhaustion` breadcrumb? OSC 8 link-id space is u16, leaving
    /// 65 534 distinct URIs per snapshot before attribution is silently
    /// dropped (lib.rs phase-1 link-build). The cap is essentially
    /// unreachable on any realistic TUI but reachable by a hostile
    /// remote emitting unique per-cell URIs; without an observability
    /// hook, support engineers triaging "my OSC 8 links stopped working"
    /// have no breadcrumb. Latch keeps the log one-shot per session to
    /// avoid eprintln spam on a streaming hostile payload. Audit S2-014.
    pub(crate) osc8_id_exhaustion_logged: bool,
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
///
/// # Nested-delivery contract
/// If a panic occurs while a Fatal event is already being dispatched on this
/// thread (i.e. the user callback called back into a `bb_term_*` function
/// and that call panicked), the nested Fatal is SWALLOWED rather than
/// re-dispatched. Re-dispatching would invoke the same user callback while
/// it is still on the stack — a recipe for deadlock (the callback may hold
/// the lock it took on first entry) or unbounded recursion (if the callback
/// immediately re-panics). The Swift side cannot assume every panic within
/// a re-entered FFI call surfaces as a Fatal event; the first panic will,
/// subsequent nested ones won't. See rust-core-5 F3.
unsafe fn guard_with_term<T>(term: *mut BBTerm, fallback: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(payload) => {
            // Re-entry guard: the dispatch below calls the user callback
            // with a Fatal event. If that dispatch is already in flight on
            // this thread (callback → bb_term_* → panic → we're here
            // again), swallow the payload to break the cycle.
            if FFI_FATAL_IN_FLIGHT.with(|c| c.get()) {
                return fallback;
            }
            let _guard = FatalInFlightGuard::enter();
            if !term.is_null() {
                let bb = &*term;
                let msg = payload_to_string(&*payload);
                let (cb, ctx) = *bb.callback.slot.get();
                if let Some(cb) = cb {
                    let bytes = msg.as_bytes();
                    // Same payload normalization CallbackCell::fire applies
                    // (audit S6-001): this Fatal dispatch deliberately
                    // bypasses fire() (the cell may be mid-panic), so it
                    // must uphold the `payload == NULL ⇔ len == 0` header
                    // contract itself — an empty panic message's
                    // `as_bytes().as_ptr()` is NonNull::dangling(), the
                    // exact shape S6-001 eliminated. Review follow-up.
                    let ev = BBEvent {
                        kind: BBEventKind::Fatal,
                        payload: if bytes.is_empty() {
                            std::ptr::null()
                        } else {
                            bytes.as_ptr()
                        },
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

thread_local! {
    /// True while `guard_with_term` is dispatching a Fatal event to the user
    /// callback on this thread. Re-entering (callback → bb_term_* → panic)
    /// drops the nested Fatal instead of recursing. See rust-core-5 F3.
    static FFI_FATAL_IN_FLIGHT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// RAII guard: flips `FFI_FATAL_IN_FLIGHT` to `true` on entry and back to
/// `false` on drop. The Drop impl also fires if an unexpected panic escapes
/// the inner `catch_unwind`, ensuring the latch never sticks.
struct FatalInFlightGuard;
impl FatalInFlightGuard {
    fn enter() -> Self {
        FFI_FATAL_IN_FLIGHT.with(|c| c.set(true));
        FatalInFlightGuard
    }
}
impl Drop for FatalInFlightGuard {
    fn drop(&mut self) {
        FFI_FATAL_IN_FLIGHT.with(|c| c.set(false));
    }
}

thread_local! {
    /// True while `CallbackCell::fire` is invoking the registered C callback
    /// on this thread. Captures the call-graph shape "callback synchronously
    /// re-enters bb_term_*" — alacritty's `&mut Term` borrow held by the
    /// outer entry point is still live, so the second `&mut Term` reborrow
    /// inside the re-entered call would alias.
    ///
    /// Sibling of the Swift-side M-9 `BBTerm.isInsideEventDispatch`
    /// precondition: the Swift guard fires AFTER the second `&mut Term`
    /// has already taken effect on stack; this Rust guard fires BEFORE
    /// the second reborrow, catching the violation at the actual UB
    /// boundary. Audit follow-up to M-9 (2026-04-29).
    ///
    /// Checked by `ffi_reentry_blocked` at the top of EVERY guarded entry
    /// point — `bb_term_input` (the canonical re-entry vector), plus
    /// `bb_term_{resize2,take_snapshot,current_mode,scroll,scroll_to_bottom,
    /// clear_all,text_range,set_named_color,set_event_cb,free,…}` — BEFORE
    /// each materialises its `&mut *term` / `&*term`, so a re-entrant call
    /// bails (reading this thread-local, no `*term` deref) before taking a
    /// second borrow. The Swift-side `isInsideEventDispatch` precondition
    /// still backstops them. (Note: the remaining miri-validation of this
    /// surface — confirming the borrow-stack is clean under Tree Borrows so
    /// `core/tests/handler_reentry_guard.rs` can drop its `cfg_attr(miri,
    /// ignore)` — is tracked in KNOWN_ISSUES.md; it needs a nightly miri run.)
    static FFI_HANDLER_IN_FLIGHT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// RAII guard: flips `FFI_HANDLER_IN_FLIGHT` to `true` while the user
/// callback is on stack, restores `false` on drop. Acquired inside
/// `CallbackCell::fire` immediately around the `f(event, ctx)` call so a
/// callback that synchronously re-enters `bb_term_*` is observable via
/// the latch BEFORE the inner call grabs `&mut Term`.
pub(crate) struct HandlerInFlightGuard;
impl HandlerInFlightGuard {
    pub(crate) fn enter() -> Self {
        FFI_HANDLER_IN_FLIGHT.with(|c| c.set(true));
        HandlerInFlightGuard
    }
}
impl Drop for HandlerInFlightGuard {
    fn drop(&mut self) {
        FFI_HANDLER_IN_FLIGHT.with(|c| c.set(false));
    }
}

/// One-shot latch for the handler-reentry warning. Audit M-9 follow-up
/// (2026-04-29).
static HANDLER_REENTRY_LOGGED: Once = Once::new();

/// Returns `true` when the calling FFI entry point would alias the outer
/// `&mut Term` borrow held by `bb_term_input` (or any other entry currently
/// dispatching through `CallbackCell::fire`). Audit H-5 (2026-05-03):
/// every entry point that reborrows `&mut *term` / `&*term` consults this
/// before the reborrow so a misbehaving callback that synchronously calls
/// back into a `bb_term_*` function bails out cleanly instead of producing
/// a second mutable alias of the alacritty `Term`. The first re-entry on
/// process lifetime is logged once via `HANDLER_REENTRY_LOGGED`; later
/// hits are silent so a sustained regression doesn't flood the log.
///
/// Audit S1-043 / S2-011 / fix-#09 (2026-05-11): also short-circuits when
/// a Fatal dispatch is in flight (`FFI_FATAL_IN_FLIGHT`). The Fatal path
/// in `guard_with_term` holds `&*term` while invoking the user callback
/// outside of `CallbackCell::fire` (so `FFI_HANDLER_IN_FLIGHT` is NOT
/// engaged on that path). A Fatal handler that synchronously calls
/// `bb_term_input` would otherwise reborrow `&mut *term`, aliasing the
/// outer `&*term`, AND fire a nested event whose Swift dispatch would
/// trip the release-mode `isInsideEventDispatch` precondition and abort
/// the process. Treating both latches as equivalent re-entry signals
/// keeps the Rust core defensive against either dispatch flavour.
fn ffi_reentry_blocked(entry: &str) -> bool {
    let in_handler = FFI_HANDLER_IN_FLIGHT.with(|c| c.get());
    let in_fatal = FFI_FATAL_IN_FLIGHT.with(|c| c.get());
    if !in_handler && !in_fatal {
        return false;
    }
    HANDLER_REENTRY_LOGGED.call_once(|| {
        let path = if in_fatal {
            "fatal dispatch"
        } else {
            "event handler"
        };
        eprintln!(
            "[blackbird_core] {entry} called from inside {path} — \
             dropping re-entrant call to avoid &mut Term alias. Audit H-5/fix-#09."
        );
    });
    true
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

/// One-shot latch for the dim-clamp warning. Sibling of the Swift-side
/// `BBTerm.didLogDimClamp` (audit follow-up 2026-04-29). Fires the first
/// time `bb_term_new` or `bb_term_resize2` clamps a caller-supplied
/// dimension — captures Swift wrappers / future direct C consumers that
/// hand the FFI an out-of-envelope value. Single global latch (not
/// per-callsite) so a sustained regression doesn't flood the log.
static DIM_CLAMP_LOGGED: Once = Once::new();

/// Minimum grid dimension (cells per row/column). Below 2 alacritty's reflow
/// math degenerates: a 1-col grid with scrollback becomes millions of 1-cell
/// rows on shrink. Shared between `bb_term_new` (init clamp, audit H-7) and
/// `bb_term_resize2` (resize clamp) so both paths agree.
const MIN_DIM: u16 = 2;
/// Maximum grid dimension. A caller passing `u16::MAX` would otherwise allocate
/// `rows × (cols + scrollback) × cell_size` bytes — at 65535 × (65535 + 200000)
/// × 32B that's ~520 GB, enough to freeze any machine. 1000 × 1000 × 32B ≈
/// 32 MB grid, comfortable.
const MAX_DIM: u16 = 1000;
/// Scrollback ceiling. Alacritty allocates lazily, so the realistic memory
/// cost of `MAX_DIM × SCROLLBACK_MAX × ~16B = ~3.1 GB` worst-case never
/// materialises in practice — but the cap is real defence against a runaway
/// caller. 200k lines covers dense Claude Code / build-log workloads.
const SCROLLBACK_MAX: u32 = 200_000;
/// Per-call row cap on `bb_term_text_range`. Retained purely as a backstop
/// against absurd-range callers (the fuzzer passing i32::MIN..i32::MAX) —
/// sized so it can NEVER truncate a real buffer: the largest possible
/// span is `SCROLLBACK_MAX + MAX_DIM = 201 000` rows, comfortably under
/// the cap.
///
/// History (audit M-1, 2026-05-03 → audit S5-010, 2026-06-09): M-1 set
/// this to 65 536 reasoning that "whole-history copies are typically
/// capped by SCROLLBACK_MAX so 65 536 leaves a generous margin over
/// plausible interactive selections" — but Select All is a first-class
/// menu action and sessions default to 100 000 lines of scrollback, so
/// ⌘A+⌘C on a full buffer silently returned only the OLDEST 65 536 rows
/// and dropped the newest ~34 000 (usually the part the user wanted),
/// with no log, error, or UI signal anywhere on the path. The transient
/// allocation the cap bounds is proportional to content the terminal
/// already retains in cell form (~32 B/cell vs ≤4 B/char extracted), so
/// a content-sized extraction is strictly smaller than the grid backing
/// it and the M-1 DoS-amplification concern doesn't apply to in-range
/// requests; only the absurd-range case needs the bound.
pub(crate) const MAX_TEXT_RANGE_ROWS: u32 = 262_144;

/// Create a new terminal. Returns null on invalid input or internal error.
///
/// # Thread safety
/// The returned handle is NOT Sync / Sendable. Once created, every subsequent
/// `bb_term_*` call on this handle MUST happen on the same thread; the handle
/// may never be accessed concurrently from two threads. In Swift, restrict
/// the handle to the @MainActor or confine it to a single dedicated serial
/// queue — serial-queue confinement means calls may arrive on DIFFERENT
/// threads over time (GCD provides no stable thread identity), which is
/// fine: the contract is mutual exclusion plus the queue's memory ordering,
/// not thread identity. Debug builds panic on OVERLAPPING access (two
/// threads inside the handle simultaneously) — rust-core-1 F2/F10, reworked
/// per audit S1-004.
///
/// # Safety
/// The returned pointer must be freed exactly once via `bb_term_free`.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no `BBTerm` context is available yet to deliver a Fatal event).
/// The function returns null as the fallback value.
///
/// # Clamping
/// `cols` and `rows` are clamped to `[MIN_DIM, MAX_DIM]` (currently `[2, 1000]`)
/// — symmetric with `bb_term_resize2`. A `0` on either axis still returns null
/// (treated as "no terminal requested"), matching pre-2026-04-29 behaviour.
/// `scrollback` is capped at `SCROLLBACK_MAX` (200 000 lines). Pre-H-7 a 1×1
/// grid was constructable and silently grew to 2×2 on the next resize; now
/// the clamp lands at construction time so the grid the caller observes via
/// snapshot matches what they asked for (modulo the public `[MIN_DIM, MAX_DIM]`
/// envelope).
#[no_mangle]
pub unsafe extern "C" fn bb_term_new(cols: u16, rows: u16, scrollback: u32) -> *mut BBTerm {
    guard_no_term(std::ptr::null_mut(), || {
        if cols == 0 || rows == 0 {
            return std::ptr::null_mut();
        }
        // Audit H-7: clamp BOTH bounds, symmetric with `bb_term_resize2`.
        // Pre-H-7 the floor was missing here, so `bb_term_new(1, 1, …)`
        // succeeded and then silently grew on the next resize call.
        let clamped_cols = cols.clamp(MIN_DIM, MAX_DIM);
        let clamped_rows = rows.clamp(MIN_DIM, MAX_DIM);
        // Audit follow-up (2026-04-29): one-shot warning when the clamp
        // engages. Sibling of the Swift-side `BBTerm.didLogDimClamp`
        // pattern. Captures direct C consumers (and Swift wrappers
        // whose own clamp regresses) that feed out-of-envelope dims.
        if clamped_cols != cols || clamped_rows != rows {
            DIM_CLAMP_LOGGED.call_once(|| {
                eprintln!(
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
            // Opt into alacritty's kitty keyboard protocol dispatch. Without
            // this, push_keyboard_mode / pop_keyboard_modes / set_keyboard_mode
            // handlers early-return and the TermMode bits never light, even
            // when the TUI asks for disambiguated escape codes via ESC[>1u.
            // Claude Code, nvim 0.10+, WezTerm shells all expect this.
            kitty_keyboard: true,
            // Disable alacritty's in-term OSC 52 clipboard handling. The
            // alacritty default is `Osc52::OnlyCopy`, which lets any PTY
            // program silently stuff the macOS clipboard on write. Blackbird
            // owns the Swift-side clipboard gate (see `Osc52Clipboard` event
            // in `MainWindowController.swift`); disabling the alacritty
            // handler entirely gives defence-in-depth: even if the Swift
            // gate regresses, a hostile remote can't fall through to the
            // built-in `ClipboardStore` event. `Event::ClipboardStore` is
            // only emitted when alacritty accepts the OSC 52 write, so
            // `Osc52::Disabled` also stops the forwarding path at the
            // source. Users who want the historical behaviour must re-enable
            // via a future Preferences toggle.
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
            osc_parser: Parser::new(),
            color_queue,
            color_query_enabled: false,
            osc_possibly_pending: false,
            in_xtgettcap: false,
            xtgettcap_buf: Vec::with_capacity(64),
            callback,
            uri_cstr_cache: std::collections::HashMap::new(),
            uri_cache_bytes: 0,
            osc8_id_exhaustion_logged: false,
            modify_other_keys: 0,
            prompt_mark_rate: PromptMarkRateState::new(),
            osc7_rate: Osc7RateState::new(),
            osc7_reject_logged: [false; 8],
            osc133_d_nondigit_logged: false,
            osc133_abc_tainted_logged: false,
            osc133_rate_limited_logged: false,
            color_query_reply_window_start: std::time::Instant::now(),
            color_query_reply_window_count: 0,
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
/// Calling this from inside a user event callback (registered via
/// `bb_term_set_event_cb`) violates the contract documented in BBCore.h
/// ("must not call any bb_term_* function on the same term handle"). The
/// header gates every other term-* entry point on `ffi_reentry_blocked`,
/// turning the violation into a silent no-op; `bb_term_free` was the lone
/// exception and would unconditionally `drop(Box::from_raw(term))` while
/// alacritty's `processor.advance(&mut bb.term, …)` was still on the outer
/// `bb_term_input` stack — a use-after-free. Audit fix-#01 (2026-05-21):
/// engage the same gate here so a handler-driven free becomes a contained
/// leak (the BBTerm box stays alive but the Swift wrapper nilled its
/// handle, so it's unreachable) instead of UAF. Leak >> UAF.
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
        if ffi_reentry_blocked("bb_term_free") {
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
/// - `len` must be `<= isize::MAX as usize`. Larger values are rejected up
///   front (no input processed) with a Fatal event dispatched — defense-in-
///   depth against `slice::from_raw_parts`'s safety precondition (audit
///   L-11). Swift's BBTerm wrapper can't construct such an input, but C-ABI
///   consumers (fuzzers, native bindings, pre-Swift-conversion test harnesses)
///   can.
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
        // Audit M-9 follow-up (2026-04-29) + H-5 (2026-05-03): re-entry
        // catch one frame earlier than the Swift-side
        // `BBTerm.isInsideEventDispatch` precondition. If the user
        // callback (currently on stack via `CallbackCell::fire`)
        // synchronously called back into `bb_term_input`, the outer
        // `&mut Term` borrow held by the outer call is still live.
        // Bailing here drops the input bytes silently (they're already
        // bytes the parser saw) but critically prevents the second
        // `&mut *term` reborrow below from aliasing.
        //
        // One-shot warning + early return is the right shape: a panic
        // here would be caught by `guard_with_term` and dispatched back
        // to the same callback we're trying to protect, defeating the
        // purpose. Audit H-5 extended the same gate to every other
        // entry point that reborrows `&mut *term` / `&*term`; the
        // helper centralises the latch read and one-shot log.
        if ffi_reentry_blocked("bb_term_input") {
            return;
        }
        // Audit L-11 (2026-04-29): defense-in-depth against
        // `slice::from_raw_parts`'s safety precondition that the slice
        // length fit in an isize (`len * mem::size_of::<u8>()` must be
        // representable as `isize`). The Swift wrapper can't reach this
        // path because Swift `Data.count` is `Int = isize`; a C ABI
        // consumer (fuzzer, native binding) can. `panic!` here is
        // caught by `guard_with_term` and surfaced as a Fatal event so
        // the host learns about the contract violation instead of
        // silently UB'ing.
        if len > isize::MAX as usize {
            panic!(
                "bb_term_input: len {len} exceeds isize::MAX (slice::from_raw_parts precondition)"
            );
        }
        let bb = &mut *term;
        let slice = std::slice::from_raw_parts(bytes, len);
        // `CSI 2 J` (ED All — erase visible viewport) is NOT augmented with
        // `CSI 3 J` (erase scrollback). A previous revision auto-injected 3J
        // on every top-level 2J so `clear(1)` would also wipe scrollback,
        // matching `clear -x` / iTerm2's optional behavior. That heuristic
        // misfired in the field: TUIs (Claude Code's Ink renderer, ratatui
        // spinners, fzf full-screen redraws) emit 2J on every redraw cycle,
        // and the injected 3J wiped the user's scrollback on each frame.
        // Users now have ⌘K (`bb_term_clear_all`) for the explicit
        // viewport+scrollback wipe; `clear(1)` is viewport-only, matching
        // xterm / Alacritty / Terminal.app.
        //
        // Fast path: if the chunk contains no ESC byte at all, we can't have
        // any CSI sequence, so the OSC-parser is only needed when a prior
        // chunk left one pending.
        if memchr::memchr(0x1B, slice).is_none() {
            bb.processor.advance(&mut bb.term, slice);
            // OSC parser skip: pure-text chunks don't need the parallel
            // state machine UNLESS (a) a prior chunk opened an OSC that
            // may still be open, or (b) this chunk contains a BEL that
            // could be an OSC terminator. For streams with zero ESC / BEL
            // (the plain_text / `yes(1)` / `cat log` case), we skip
            // vte::Parser entirely after the first ESC-free chunk.
            //
            // Clearing the latch: after an ESC-free advance, any
            // ST-terminated (ESC \) OSC is still pending by definition
            // (ST requires an ESC, which we didn't see). Only a BEL in
            // this chunk can have terminated the pending sequence, so we
            // clear the latch only then. Unterminated sequences stay
            // pending forever — pathological but harmless.
            let has_bel = memchr::memchr(0x07, slice).is_some();
            // Also drive the parallel parser while we are mid-XTGETTCAP:
            // a `put`-heavy hex payload can be pure ASCII with no ESC/BEL,
            // so the `hook` latch is what keeps us here.
            //
            // `|| bb.in_xtgettcap`: defensive. If a future code path ever
            // clears `osc_possibly_pending` while a DCS is still open
            // (e.g. a ST-only terminator path we haven't needed yet),
            // this keeps the osc_parser alive so our hook/put/unhook
            // state advances. No current fragmentation scenario reaches
            // this branch because `osc_possibly_pending` stays true from
            // the DCS's opening ESC; kept as a safety belt.
            if bb.osc_possibly_pending || has_bel || bb.in_xtgettcap {
                let mut osc = OscScanner {
                    cell: &bb.callback,
                    in_xtgettcap: &mut bb.in_xtgettcap,
                    xtgettcap_buf: &mut bb.xtgettcap_buf,
                    modify_other_keys: &mut bb.modify_other_keys,
                    prompt_mark_rate: &mut bb.prompt_mark_rate,
                    osc7_rate: &mut bb.osc7_rate,
                    osc7_reject_logged: &mut bb.osc7_reject_logged,
                    osc133_d_nondigit_logged: &mut bb.osc133_d_nondigit_logged,
                    osc133_abc_tainted_logged: &mut bb.osc133_abc_tainted_logged,
                    osc133_rate_limited_logged: &mut bb.osc133_rate_limited_logged,
                };
                bb.osc_parser.advance(&mut osc, slice);
                if has_bel {
                    bb.osc_possibly_pending = false;
                }
            }
            drain_color_requests(bb);
            bb.callback.flush_suppressed_title();
            return;
        }
        // Chunk contains ESC — may open a new OSC that terminates in a
        // later chunk. Set the latch so subsequent ESC-free chunks still
        // reach the parser.
        bb.osc_possibly_pending = true;
        // Drive the parallel OSC parser whole-chunk: it watches for OSC 7,
        // OSC 133, and the modify-other-keys CSI. None of those need byte-
        // precise dispatch positions, so a single `advance` is enough.
        let mut osc = OscScanner {
            cell: &bb.callback,
            in_xtgettcap: &mut bb.in_xtgettcap,
            xtgettcap_buf: &mut bb.xtgettcap_buf,
            modify_other_keys: &mut bb.modify_other_keys,
            prompt_mark_rate: &mut bb.prompt_mark_rate,
            osc7_rate: &mut bb.osc7_rate,
            osc7_reject_logged: &mut bb.osc7_reject_logged,
            osc133_d_nondigit_logged: &mut bb.osc133_d_nondigit_logged,
            osc133_abc_tainted_logged: &mut bb.osc133_abc_tainted_logged,
            osc133_rate_limited_logged: &mut bb.osc133_rate_limited_logged,
        };
        bb.osc_parser.advance(&mut osc, slice);
        bb.processor.advance(&mut bb.term, slice);
        drain_color_requests(bb);
        bb.callback.flush_suppressed_title();
    })
}

/// Resolve every pending OSC 10/11/12 response and emit it as a PtyWrite
/// event. Called after every `processor.advance` in `bb_term_input`
/// returns — at that point we're no longer inside alacritty's `&mut Term`
/// borrow, so the palette is readable.
///
/// # Safety
/// Caller must ensure single-threaded access to `bb.color_queue` and
/// `bb.callback` (the usual BBTerm thread discipline).
unsafe fn drain_color_requests(bb: &mut BBTerm) {
    let entries = (*bb.color_queue).drain();
    if entries.is_empty() {
        return;
    }
    // Security default: drop the queue silently unless the user has
    // explicitly enabled replies. Ignoring here rather than blocking the
    // push keeps the wire path identical in both modes — a future
    // always-enable would only need to flip this flag.
    if !bb.color_query_enabled {
        return;
    }
    let palette = bb.term.colors();
    // `palette` is alacritty's fixed-width `Colors` table. Its length is a
    // public `COUNT` constant (269 today — 256 indexed + 13 named). The
    // `Index` impl panics on out-of-bounds, so bound-check first. A
    // direct index was sound for every value the current alacritty/vte
    // surface can emit, but future widenings must not panic into
    // `BBEventKind::Fatal` (rust-core-2 F2).
    for entry in entries {
        // Bug #17 sliding-window gate: cap PtyWrite replies at
        // COLOR_QUERY_REPLY_PER_SECOND across the rolling
        // COLOR_QUERY_REPLY_WINDOW. The per-chunk
        // ColorRequestQueue cap stops in-call amplification; this
        // covers the cross-chunk case.
        let now = std::time::Instant::now();
        if now.duration_since(bb.color_query_reply_window_start) >= COLOR_QUERY_REPLY_WINDOW {
            bb.color_query_reply_window_start = now;
            bb.color_query_reply_window_count = 0;
        }
        if bb.color_query_reply_window_count >= COLOR_QUERY_REPLY_PER_SECOND {
            // Drop silently — matching the PromptMarkRateState pattern.
            continue;
        }

        let slot: Option<alacritty_terminal::vte::ansi::Rgb> =
            if entry.index < alacritty_terminal::term::color::COUNT {
                palette[entry.index]
            } else {
                None
            };
        // palette[idx] is Option<Rgb>. None means the theme hasn't set
        // this slot; fall back to a sensible default so we still reply
        // rather than leaving the TUI timing out.
        let rgb = slot.unwrap_or_else(|| palette_default_rgb(entry.index));
        let reply = (entry.formatter)(rgb);
        // The `reply` String owns its bytes for the duration of this
        // scope; `fire` is synchronous (calls the registered C callback
        // which must copy bytes if it wants to outlive the call).
        let bytes = reply.as_bytes();
        bb.callback.fire(BBEvent {
            kind: BBEventKind::PtyWrite,
            payload: bytes.as_ptr(),
            len: bytes.len(),
            i32_arg: 0,
        });
        // Audit fix-#14 (2026-05-21): increment AFTER successful fire so
        // a user-callback panic (caught by guard_with_term's outer
        // catch_unwind) doesn't leave the rate-limit counter desynced
        // from actual deliveries. Cumulative count over the window now
        // reflects only replies that the callback observed.
        bb.color_query_reply_window_count += 1;
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
///
/// Callers that need to know whether the requested dimensions were clamped
/// should prefer `bb_term_resize2`, which returns the actually-applied dims
/// and a `clamped` flag. The void-returning form here is retained for ABI
/// stability; it internally delegates to the same clamp logic.
#[no_mangle]
pub unsafe extern "C" fn bb_term_resize(term: *mut BBTerm, cols: u16, rows: u16) {
    let _ = bb_term_resize2(term, cols, rows);
}

/// Result of `bb_term_resize2`. `applied_cols` / `applied_rows` report the
/// dimensions the grid was actually resized to after clamping (floor = 2,
/// ceiling = 1000 on each axis); `clamped` is non-zero when either requested
/// dim differed from the applied value. On a no-op call (null term, or zero
/// in either dim) all three fields are `0`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BBResizeResult {
    pub applied_cols: u16,
    pub applied_rows: u16,
    /// Non-zero when the request was rewritten by the clamp; zero when the
    /// grid now holds exactly the requested dims (or on no-op).
    pub clamped: u8,
    pub _pad: [u8; 3],
}

/// Resize the terminal grid and report the actually-applied dimensions.
///
/// Dimensions are clamped to `[2, 1000]` on each axis to avoid the reflow
/// explosion on tiny grids and the 100+ GB allocation on huge grids
/// (documented in the floor/ceiling comment inside this function and in
/// `MEMORY`). Zero on either axis is a no-op and returns
/// `BBResizeResult { 0, 0, 0 }`.
///
/// `clamped` is the signal to Swift that `TIOCSWINSZ` should be told the
/// APPLIED size, not the requested one — otherwise the shell and the grid
/// disagree about the viewport (rust-core-3 F4).
///
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
        // Floor + ceiling on dimensions. See module-level `MIN_DIM` /
        // `MAX_DIM` for rationale. Symmetric with `bb_term_new` (audit H-7).
        let bb = &mut *term;
        let applied_cols = cols.clamp(MIN_DIM, MAX_DIM);
        let applied_rows = rows.clamp(MIN_DIM, MAX_DIM);
        let clamped_flag = applied_cols != cols || applied_rows != rows;
        // Audit follow-up (2026-04-29): one-shot warning when the clamp
        // engages. Shares `DIM_CLAMP_LOGGED` with `bb_term_new` so a
        // single sustained regression produces exactly one log line
        // regardless of which entry point trips first.
        if clamped_flag {
            DIM_CLAMP_LOGGED.call_once(|| {
                eprintln!(
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
        if ffi_reentry_blocked("bb_term_set_event_cb") {
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
        if ffi_reentry_blocked("bb_term_take_snapshot") {
            return std::ptr::null();
        }
        snapshot(&mut *term)
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

/// Look up the OSC 8 link id at a snapshot cell. Returns 0 when `snap` is
/// null, `(row, col)` is outside the grid, or the cell has no OSC 8
/// attribution.
///
/// Pass the returned non-zero id to `bb_snap_link_url` to get the URL.
///
/// Safe to call from any thread (the snapshot's link table is immutable
/// post-construction). Audit L-10 (2026-04-29).
///
/// # Safety
/// `snap` must be non-null and returned by `bb_term_take_snapshot` /
/// `bb_snap_retain`, not yet released to zero.
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

/// Resolve an OSC 8 link id to its UTF-8 URL. Returns null when `snap` is
/// null, `link_id == 0`, or the id is unknown. The returned pointer is
/// valid for the snapshot's lifetime (until the matching `bb_snap_release`
/// drops the refcount to zero).
///
/// Safe to call from any thread (the snapshot's URL table is immutable
/// post-construction). Audit L-10 (2026-04-29).
///
/// # Safety
/// `snap` must be non-null and returned by `bb_term_take_snapshot` /
/// `bb_snap_retain`, not yet released to zero.
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
            // Index 0 is the empty-string sentinel, already filtered above.
            Some(cstr) => cstr.as_ptr(),
            None => std::ptr::null(),
        }
    })
}

/// Toggle OSC 10 / 11 / 12 `?` reply behaviour. Disabled by default so
/// a hostile remote can't round-trip the palette back into the PTY
/// (mitigates the zsh-vi-mode command-injection class). Pass `1` to
/// enable replies when running a known-safe shell that wants nvim /
/// tmux auto-theming.
///
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
        (*term).color_query_enabled = enabled != 0;
    })
}

/// Read the current terminal mode bitfield as a `bb_mode::*` union.
/// O(1) — no snapshot allocation. Use when a caller needs to branch on
/// a single mode bit (e.g., focus-event emission must check
/// `FOCUS_IN_OUT` before writing `\x1b[I` / `\x1b[O` to the PTY, since
/// emitting those bytes when the TUI hasn't enabled mode 1004 would be
/// interpreted as `HPA` / a cursor move).
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null returns 0 (no bits set),
/// which is the correct default for "don't emit".
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// 0 as the fallback value.
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

/// Report whether the snapshot's damage set is "full" (all rows need a
/// redraw — scroll, insert-mode, viewport scrollback change). When true,
/// the renderer must treat every row as damaged regardless of
/// `bb_snap_damage_rows`.
///
/// # Safety
/// `snap` must be a pointer from `bb_term_take_snapshot` or retained from
/// one. Null returns 1 (the safe default: repaint everything).
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

/// Copy the snapshot's damaged-row indices into the caller's buffer. Returns
/// the TOTAL number of damaged rows (which may exceed `out_cap`); the
/// function writes at most `min(total, out_cap)` rows into `out`.
///
/// Truncation detection: callers compare the return value against `out_cap`.
/// If `return_value > out_cap`, the buffer was too small and the caller
/// should re-allocate at `return_value` slots and retry to avoid leaving
/// stale pixels on the undrawn rows.
///
/// Length probe: passing `out = null` with any `out_cap` returns the
/// total count without writing anything, so a caller can size a buffer
/// before allocating.
///
/// If the damage is `Full`, returns 0 — callers must check
/// `bb_snap_damage_is_full` first and treat "full" as "all rows need
/// redraw" regardless of this function's return value.
///
/// # Safety
/// - `snap` must be a pointer from `bb_term_take_snapshot` or retained
/// - `out` must either be null OR point to at least `out_cap * 2` bytes of
///   writable memory. No u16 alignment is required on `out` — the body
///   copies byte-wise (rust-core-4 F3).
/// - Safe to call from any thread.
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
        // Length probe: caller passed null to size a buffer without writing.
        if out.is_null() || out_cap == 0 {
            return total;
        }
        let n = total.min(out_cap);
        // Copy as raw bytes (not u16) so an unaligned `out` — e.g. a caller
        // that cast a u8 buffer via `.cast::<u16>()` at an odd address — is
        // well-defined on every target, not just those that forgive
        // unaligned stores. Each u16 is 2 bytes, so `n * 2` bytes total
        // (rust-core-4 F3).
        std::ptr::copy_nonoverlapping(
            rows.as_ptr() as *const u8,
            out as *mut u8,
            n * std::mem::size_of::<u16>(),
        );
        // Truncation signal: callers compare the returned `total` against
        // `out_cap`; `total > out_cap` means the buffer was too small and
        // the caller should re-allocate at `total` and retry. We don't
        // `debug_assert` here because truncation is a legitimate API shape
        // when the caller is size-probing — the log is routed via Swift
        // when the caller wants diagnostics.
        total
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
        if ffi_reentry_blocked("bb_term_scroll") {
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
        if ffi_reentry_blocked("bb_term_scroll_to_bottom") {
            return;
        }
        let bb = &mut *term;
        use alacritty_terminal::grid::Scroll;
        bb.term.scroll_display(Scroll::Bottom);
    })
}

/// Clear the visible screen AND the scrollback, moving the cursor to the
/// top-left. Equivalent to `clear -x` (BSD) / iTerm2's "⌘K" wipe — NOT
/// what `clear(1)` emits, which is viewport-only (a plain `\x1b[H\x1b[2J`
/// that leaves scrollback intact). The terminal palette is intentionally
/// preserved (the user's theme survives ⌘K). All other parser / rate-
/// limiter / cache state IS reset so a pre-clear adversarial flood
/// can't degrade the post-clear session — see audit H-3 (2026-04-29).
///
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
        let bb = &mut *term;
        // H = cursor home, 2J = erase display, 3J = erase scrollback.
        bb.processor.advance(&mut bb.term, b"\x1b[H\x1b[2J\x1b[3J");
        // Audit RC-02 + P2-02 — also reset our parallel-parser state and
        // rate-limit windows. Without this, a mid-sequence parser
        // continues into post-clear bytes (most dangerous: a mid-DCS
        // XTGETTCAP that accumulates post-clear bytes into its reply).
        // The comparable `processor.advance` above only resets alacritty's
        // grid; our scanner is a separate vte::Parser tracked alongside.
        bb.osc_parser = Parser::new();
        bb.osc_possibly_pending = false;
        bb.in_xtgettcap = false;
        bb.xtgettcap_buf.clear();
        // Rate-limit budgets are session state. A pre-clear OSC 11 flood
        // shouldn't leave the post-clear session unable to answer
        // legitimate color queries for the rest of the 1s window.
        bb.color_query_reply_window_start = std::time::Instant::now();
        bb.color_query_reply_window_count = 0;

        // Audit H-3 (2026-04-29): five sibling state slots survived the
        // pre-existing reset list, leaving these adversarial-state
        // primitives carryable across ⌘K:
        //
        //   1. `prompt_mark_rate` — pre-clear OSC 133 flood degraded
        //      post-clear prompt navigation for up to 1 s.
        //   2. `osc7_rate` — pre-clear OSC 7 flood ate the 1-s ingest
        //      budget, so post-clear `cd` events dropped silently.
        //   3. `modify_other_keys` — xterm modifyOtherKeys mode persisted
        //      across the wipe.
        //   4. `pty_write_rate` (Arc on the callback) — pre-clear OSC 11
        //      flood ate the 1-s PTY-write budget.
        //   5. `uri_cstr_cache` / `uri_cache_bytes` — pre-clear OSC 8
        //      cache flood blocked legitimate post-clear OSC 8 links
        //      until app relaunch (the 1 MiB byte-cap stayed exhausted).
        bb.prompt_mark_rate = PromptMarkRateState::new();
        bb.osc7_rate = Osc7RateState::new();
        bb.modify_other_keys = 0;
        bb.callback.pty_write_rate.reset();
        bb.callback.reset_event_rates();

        // OSC 8 URI intern cache: drain unconditionally. Audit S5-002.
        //
        // The previous shape used
        // `retain(|_uri, arc| Arc::strong_count(arc) > 1)` to keep
        // entries still referenced by a live snapshot. That semantics
        // sounds safe but breaks the documented H-3 invariant in
        // production: Swift's `TerminalSession.clearAll` runs the FFI
        // call while `TerminalView.currentSnapshot` still pins the
        // pre-clear snapshot. Every cache entry's Arc has
        // strong_count > 1, retain keeps everything, and a pre-clear
        // adversarial flood permanently disables OSC 8 attribution for
        // the rest of the BBTerm lifetime (or until a SECOND clearAll
        // happens after the snapshot was released — but Swift always
        // re-pins on publish).
        //
        // Memory safety of the unconditional clear: each snapshot's
        // `links: Vec<Arc<std::ffi::CStr>>` holds its own Arc clones
        // (cf. `bb_term_take_snapshot` at the cache-resolve path).
        // Dropping the cache's Arc only decrements; the snapshot's
        // clone keeps the CStr alive for the lifetime of the snapshot.
        // The `*const c_char` pointers returned by `bb_snap_link_url`
        // come from the snapshot's own Arc, not the cache's, so they
        // do not dangle. (The "would dangle" caveat in the prior
        // comment was incorrect — the snapshot's links table owns its
        // Arc independently.)
        //
        // The reachability test `osc8_link_cap_resets_on_clear_all_even_with_live_snapshot`
        // pins this invariant; the original
        // `osc8_link_cap_resets_on_clear_all` (which released
        // snap_pre BEFORE clearAll) continues to pass for the same
        // reason — clear() always drops references, regardless of
        // whether external owners exist.
        bb.uri_cstr_cache.clear();
        bb.uri_cache_bytes = 0;
    })
}

/// Update one slot of the terminal's color palette. Slot indices match
/// alacritty's `NamedColor` ordering (vte-0.15.0/src/ansi.rs): 0..=15 =
/// 16 ANSI colors, 16..=255 = extended 256-palette, 256 = Foreground,
/// 257 = Background, 258 = Cursor, 259..=266 = DimBlack..DimWhite,
/// 267 = BrightForeground, 268 = DimForeground. `rgb` is packed
/// 0xRRGGBB. Slot count is alacritty's `term::color::COUNT` (269 in
/// 0.26); slots ≥ COUNT are silently ignored.
/// (Pre-fix-#24 this doc said "259 = BrightForeground" — wrong; that
/// slot is DimBlack. The correct mapping was confirmed against
/// vte-0.15.0 source on 2026-05-11.)
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null `term` is a no-op. Slots
/// beyond alacritty's palette length are silently ignored.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_named_color(term: *mut BBTerm, slot: u16, rgb: u32) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        if ffi_reentry_blocked("bb_term_set_named_color") {
            return;
        }
        let bb = &mut *term;
        // alacritty's Term::set_color indexes its Colors array directly; any
        // slot ≥ the array length panics with an index-out-of-bounds. The
        // Colors layout is `[Option<Rgb>; COUNT]` with COUNT = 269 in 0.26
        // (256 palette + 13 named). The Swift side only uses 0..=258, but
        // the FFI must survive arbitrary input (fuzzer, misbehaving API
        // user) without panicking — libFuzzer's panic hook aborts the
        // process before `guard_with_term`'s `catch_unwind` ever runs, so
        // "catch the panic" is not a substitute for "don't panic". Gate
        // against the constant COUNT from alacritty's public API.
        if (slot as usize) >= alacritty_terminal::term::color::COUNT {
            return;
        }
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
///
/// `_magic` is a sentinel set by `bb_string_new` (to `BB_STRING_MAGIC`) and
/// zeroed by `bb_string_release` before the heap buffer is reconstructed.
/// It gives `bb_string_release` a cheap defence against double-free and
/// wild-pointer input: a mismatching `_magic` short-circuits without
/// calling `Vec::from_raw_parts` (which would be UB on stale pointers).
/// Safety belt for Swift callers — still single-free by contract.
#[repr(C)]
pub struct BBString {
    pub bytes: *const u8,
    pub len: usize,
    _owned_ptr: *mut u8,
    _owned_cap: usize,
    /// Magic sentinel: `BB_STRING_MAGIC` when live, `0` after release.
    /// Double-free and wild-pointer input are rejected cheaply.
    _magic: u64,
}

/// Magic sentinel stamped into `BBString::_magic` on construction. Any
/// 64-bit constant unlikely to appear on the heap by accident. Also
/// invariant-encodes the string "BlackbirdStr" via the low byte pattern.
pub const BB_STRING_MAGIC: u64 = 0xB1AC_5BBD_5721_57E0;

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
/// spaces come through as-is. Wide-char spacer cells (alacritty's
/// `WIDE_CHAR_SPACER` / `LEADING_WIDE_CHAR_SPACER` flags) are SKIPPED entirely
/// — the preceding primary cell already held the wide glyph's character, and
/// emitting a space for the spacer would double-count columns and break paste
/// round-trip for CJK/emoji (e.g. "中文" would emit as "中 文 "). Lines outside
/// `[topmost_line, bottommost_line]` are skipped silently. Points are
/// normalized so `(start_line, start_col) <= (end_line, end_col)` before
/// iterating.
///
/// Returns a heap-allocated `BBString` the caller must free with
/// `bb_string_release`. Returns null on (a) null `term` or (b) a panic
/// during text extraction (caught by `catch_unwind` and reported as a
/// `BBEventKind::Fatal` event before this function returns null).
/// Zero-area ranges return an empty `BBString`, not null. Callers
/// cannot distinguish (a) from (b) by the return value alone; wire a
/// Fatal event handler if you need to learn about extraction panics.
/// Audit L-9 (2026-04-29).
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
        if ffi_reentry_blocked("bb_term_text_range") {
            return std::ptr::null_mut();
        }
        bb_string_new(extract_text_range(
            &*term, start_line, start_col, end_line, end_col, rect,
        ))
    })
}

/// Allocate a `BBString` wrapping `bytes`. The vec's heap buffer is stolen
/// (via `Vec::into_raw_parts`-style decomposition) and held in `_owned_ptr` +
/// `_owned_cap` so `bb_string_release` can rebuild and drop it.
///
/// Stamps `_magic` with `BB_STRING_MAGIC` so `bb_string_release` can detect
/// a double-free or wild-pointer input before invoking `Vec::from_raw_parts`
/// (which would be UB on stale parts).
///
/// For an empty payload (`bytes.is_empty()`), both `bytes` and `_owned_ptr`
/// are set to null so a C consumer can rely on `bytes == NULL ⇔ len == 0`.
/// `Vec::new().as_mut_ptr()` would otherwise hand back `NonNull::dangling()`
/// (a non-null sentinel equal to `align_of::<u8>()`), which (a) breaks that
/// invariant for Swift/C callers and (b) is UB if passed to `memcpy` with
/// `n == 0` under strict C11 semantics. `bb_string_release` mirrors the
/// null check and skips `Vec::from_raw_parts` for the empty case
/// (rust-core-4 F1).
///
/// # Safety
/// The returned pointer must be released exactly once via `bb_string_release`.
unsafe fn bb_string_new(bytes: Vec<u8>) -> *mut BBString {
    if bytes.is_empty() {
        // Drop the vec eagerly; we know its capacity is irrelevant once we
        // publish null. Any residual heap buffer (non-zero cap on an empty
        // vec) deallocates with the Vec's own allocator, not ours to track.
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
    // SAFETY: leaking the vec is safe; its raw parts are recorded below and
    // will be reconstituted in bb_string_release.
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

/// Free a `BBString` returned by `bb_term_text_range`.
///
/// Rebuilds the owned `Vec<u8>` from `_owned_ptr`/`_owned_cap`/`len` so its
/// heap buffer is deallocated with the matching `Vec` allocator, then drops
/// the `Box<BBString>`.
///
/// Defends against double-free and wild-pointer input by checking
/// `_magic` against `BB_STRING_MAGIC` before touching the owned parts. A
/// mismatching magic returns early (with a one-line log) without calling
/// `Vec::from_raw_parts` — that would be UB on stale/invalid raw parts and
/// the null guard can't catch it. Successful releases zero the magic so a
/// subsequent double-release is detected cheaply.
///
/// Audit fix-#25 (2026-05-11): the magic check + zero is performed via
/// `AtomicU64::compare_exchange` (`AcqRel`/`Acquire`), so two threads
/// racing release on the same pointer cannot both observe
/// `BB_STRING_MAGIC` before either's zero-write lands. Exactly one
/// thread's CAS succeeds and proceeds to `Box::from_raw`; the loser
/// observes the zeroed sentinel and short-circuits, avoiding the
/// double-free that the previous non-atomic `ptr::read` + `ptr::write`
/// sequence permitted. The struct field stays `u64` (no cbindgen header
/// churn) and is accessed atomically via `AtomicU64::from_ptr`.
///
/// # Safety
/// `s` must have been returned by `bb_term_text_range` and not previously
/// released. Passing null is a no-op. Concurrent calls from multiple
/// threads on the SAME pointer are tolerated: the CAS singles out one
/// caller as the actual freer.
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
        // Atomic compare-exchange on the magic sentinel. AtomicU64::from_ptr
        // (stable since Rust 1.84) creates a borrowed AtomicU64 view over
        // the existing u64 field — no struct-layout change, so the cbindgen
        // header and the `bb_string_magic_layout_pinned` test stay valid.
        //
        // SAFETY (from_ptr): the caller's contract requires `s` to point
        // to a live BBString allocation. _magic was initialised
        // non-atomically by bb_string_new BEFORE the pointer was published
        // (Box::into_raw + return-across-FFI synchronizes-with any later
        // observer). For the lifetime of this release call, every access
        // to _magic on this pointer is through AtomicU64::from_ptr, so
        // the "no non-atomic access during the borrow" rule holds.
        let magic_ptr = std::ptr::addr_of!((*s)._magic) as *mut u64;
        let magic_atomic = AtomicU64::from_ptr(magic_ptr);
        match magic_atomic.compare_exchange(BB_STRING_MAGIC, 0, Ordering::AcqRel, Ordering::Acquire)
        {
            Ok(_) => {
                // We claimed the deallocation. Any concurrent release on
                // the same pointer observes magic=0 and falls into the
                // Err branch below.
            }
            Err(found) => {
                // Zero magic => already released (double-free or lost CAS
                // race). Any other value => wild/uninitialized pointer.
                // Either way, don't touch the owned parts. Logging through
                // eprintln! is acceptable: this is a development-side
                // signal, not a hot path.
                eprintln!(
                    "bb_string_release: magic mismatch (got {:#x}, expected {:#x}); \
                     refusing to free possibly-invalid BBString",
                    found, BB_STRING_MAGIC
                );
                return;
            }
        }
        let boxed = Box::from_raw(s);
        // Reconstitute the owned vec so its heap buffer is freed via the
        // matching `Vec<u8>` allocator. `bb_string_new` short-circuits
        // empty payloads to `_owned_ptr = null`, so skip `from_raw_parts`
        // there — calling it with a null pointer is UB even when cap is 0
        // (rust-core-4 F1).
        if !boxed._owned_ptr.is_null() {
            let _ = Vec::from_raw_parts(boxed._owned_ptr, boxed.len, boxed._owned_cap);
        }
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
        if ffi_reentry_blocked("bb_term_test_only_panic") {
            return;
        }
        panic!("intentional test panic");
    });
}

#[cfg(test)]
mod tests;
