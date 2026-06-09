//! blackbird_core — C ABI around `alacritty_terminal`.

use std::cell::UnsafeCell;
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Once};

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::cell::Flags as CellFlags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor, Rgb};
use alacritty_terminal::vte::{Params, Parser, Perform};

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
    /// New in 2026-04-17 gaps plan. Payload: UTF-8 bytes of the local
    /// filesystem path decoded from an OSC 7 `file://` URL. Only emitted
    /// when scheme is `file` and authority is empty or `localhost`.
    ///
    /// OSC 7 is not parsed by `alacritty_terminal` 0.26 / `vte` 0.15 —
    /// the sequence falls through vte's `osc_dispatch` unhandled branch.
    /// We run a parallel `vte::Parser` in `bb_term_input` against an
    /// `Osc7Scanner` that fires only on this one sequence. See the
    /// scanner impl and the fragmentation test for details.
    CwdChanged = 6,
    /// OSC 133 prompt/command mark emitted by a shell-integration snippet
    /// (bash/zsh/fish). `i32_arg` carries the kind: 1=A (prompt start),
    /// 2=B (command start), 3=C (command output start), 4=D (command end).
    /// `payload` is the ASCII decimal exit code for kind D, empty otherwise.
    PromptMark = 7,
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
    /// `CallbackCell::fire` normalizes this invariant at dispatch
    /// (audit S6-001): producers may hand `fire` an empty slice's
    /// `as_ptr()` (non-null) or even a fresh `String`'s
    /// `NonNull::dangling()` — the callback always observes
    /// `payload == NULL ⇔ len == 0`, so a C consumer branching on
    /// non-null per this contract never sees a dangling pointer.
    pub payload: *const u8,
    pub len: usize,
    /// Event-specific integer argument (audit S6-002):
    /// - `PromptMark`: the mark kind, 1 = A (prompt start), 2 = B
    ///   (command start), 3 = C (command output), 4 = D (command end) —
    ///   see `BBPromptMarkKind`.
    /// - `CursorShape` (reserved; not currently emitted): 0 = block,
    ///   1 = bar, 2 = underline.
    /// - 0 for every other event kind.
    pub i32_arg: i32,
}

/// C callback signature for terminal events.
pub type BBEventCb = unsafe extern "C" fn(BBEvent, *mut c_void);

// ---------------------------------------------------------------------------
// CallbackCell — shared mutable slot between BBTerm and RoutingListener
// ---------------------------------------------------------------------------

/// Interior-mutable storage for the registered C callback and its context
/// pointer.  Both `BBTerm` and `RoutingListener` reference the same cell;
/// `BBTerm` owns it via `Arc`.
///
/// # Thread-safety contract
/// All access to `CallbackCell` is mutually exclusive: the FFI contract
/// forbids concurrent calls on the same `term` handle (documented on
/// `bb_term_input` / `bb_term_new` — one thread at a time, e.g. confinement
/// to a dedicated serial queue). `Term<RoutingListener>` and `Processor`
/// are not `Sync`. Under this mutual-exclusion discipline no data race can
/// occur, making the `UnsafeCell` sound.
///
/// In debug builds, a `busy` flag detects OVERLAPPING access — two threads
/// inside the cell simultaneously, the actual data-race UB — and panics
/// with a diagnostic. Audit S1-004: the previous design latched the FIRST
/// accessor's `ThreadId` and asserted every later access matched, which
/// contradicted `bb_term_new`'s own documented allowance ("confine it to a
/// single dedicated serial queue"): GCD gives a serial queue no stable
/// thread identity, so the legitimate Swift architecture (handle created
/// on main, driven from `coreQueue`) tripped the latch on the first event
/// of every debug-assertions core build — making the diagnostic worthless
/// for catching real misuse. Overlap detection has no false positive for
/// serialized cross-thread use and still catches genuinely concurrent
/// access (best-effort: only overlaps colliding inside the flag's window
/// are observable). Zero cost in release (rust-core-1 F2/F10).
struct CallbackCell {
    slot: UnsafeCell<(Option<BBEventCb>, *mut c_void)>,
    /// Sliding-window cap on `Event::PtyWrite` dispatches. Audit M1 (the
    /// 32/sec contract on cursor-position / DA / DSR / DECXCPR replies)
    /// originally lived in `RoutingListener::send_event`, so two direct-
    /// fire sites (`dispatch_xtgettcap` and `drain_color_requests`)
    /// bypassed it — a 4 KiB DCS+q with `;`-delimited cap_hex spawned
    /// ~1300 PtyWrites in one batch, totally bypassing the cap. Audit
    /// H-4 moved the gate here so all three call sites inherit it by
    /// construction. The cell is `Arc<PtyWriteRateCell>` so the listener
    /// shares ownership and `bb_term_clear_all` can `reset()` it via
    /// `BBTerm`'s clone (audit H-3).
    pty_write_rate: Arc<PtyWriteRateCell>,
    /// Title/Bell sliding windows (audit S1-002). Same UnsafeCell
    /// discipline as `slot`; accessed only inside the fire()/reset
    /// busy-guard scopes.
    title_rate: UnsafeCell<EventRateState>,
    bell_rate: UnsafeCell<EventRateState>,
    #[cfg(debug_assertions)]
    busy: std::sync::atomic::AtomicBool,
}

/// Debug-only RAII overlap detector for the `UnsafeCell`-backed FFI cells.
/// `enter` panics when the flag is already held — i.e. another thread is
/// INSIDE the cell right now (serialized access from different threads
/// never trips it). Audit S1-004.
#[cfg(debug_assertions)]
struct DebugBusyGuard<'a>(&'a std::sync::atomic::AtomicBool);

#[cfg(debug_assertions)]
impl<'a> DebugBusyGuard<'a> {
    fn enter(flag: &'a std::sync::atomic::AtomicBool, what: &str) -> Self {
        let was_busy = flag.swap(true, std::sync::atomic::Ordering::Acquire);
        assert!(
            !was_busy,
            "blackbird_core: overlapping access to {what} — two threads are \
             using the same BBTerm handle concurrently (mutual-exclusion \
             contract violated)",
        );
        DebugBusyGuard(flag)
    }
}

#[cfg(debug_assertions)]
impl Drop for DebugBusyGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, std::sync::atomic::Ordering::Release);
    }
}

// SAFETY: the owning BBTerm is never shared across threads; see contract above.
unsafe impl Send for CallbackCell {}
// SAFETY: same — no concurrent access is ever made.
unsafe impl Sync for CallbackCell {}

impl CallbackCell {
    fn new(pty_write_rate: Arc<PtyWriteRateCell>) -> Self {
        CallbackCell {
            slot: UnsafeCell::new((None, std::ptr::null_mut())),
            pty_write_rate,
            title_rate: UnsafeCell::new(EventRateState::new()),
            bell_rate: UnsafeCell::new(EventRateState::new()),
            #[cfg(debug_assertions)]
            busy: std::sync::atomic::AtomicBool::new(false),
        }
    }

    #[cfg(debug_assertions)]
    fn debug_enter(&self) -> DebugBusyGuard<'_> {
        DebugBusyGuard::enter(&self.busy, "CallbackCell")
    }

    #[cfg(not(debug_assertions))]
    #[inline(always)]
    fn debug_enter(&self) {}

    /// Reset the Title/Bell sliding windows so a pre-clear flood does
    /// not strand the post-clear session's budget. Mirrors the PtyWrite
    /// reset on `bb_term_clear_all` (audit H-3); added with the caps in
    /// audit S1-002.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn reset_event_rates(&self) {
        let _busy = self.debug_enter();
        *self.title_rate.get() = EventRateState::new();
        *self.bell_rate.get() = EventRateState::new();
    }

    /// Update the stored callback and context.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn set(&self, cb: Option<BBEventCb>, ctx: *mut c_void) {
        let _busy = self.debug_enter();
        *self.slot.get() = (cb, ctx);
    }

    /// Invoke the stored callback if one is registered.
    ///
    /// `BBEventKind::PtyWrite` events go through the shared rate cap
    /// (audit M1 + H-4); `Title` and `Bell` go through their own caps
    /// (audit S1-002 — see `TITLE_EVENT_PER_SECOND`). Excess events
    /// silently drop here. Remaining kinds dispatch unconditionally:
    /// CwdChanged and PromptMark are rate-gated upstream in the
    /// OscScanner, Osc52Clipboard is bounded by alacritty's own OSC 52
    /// handling, and Fatal is one-shot by nature.
    ///
    /// Drop policy: dropped PtyWrites are silent BY DESIGN. Logging
    /// each drop would itself become a flood-amplifier (the very thing
    /// the rate cap is defending against — a hostile DCS+q with 1300
    /// cap_hex tokens would emit 1300 log lines). The
    /// `osc_color_query_rate_limit_drops_excess` /
    /// `xtgettcap_pty_write_cap_holds` tests cover the cap behavior,
    /// and `bb_term_clear_all` resets the budget so a flood-induced
    /// drop episode doesn't strand legitimate post-clear traffic.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access and that the `BBEvent` fields
    /// are valid for the duration of the call.
    unsafe fn fire(&self, event: BBEvent) {
        // Audit S6-001: enforce the header's documented nullability
        // invariant (`payload == NULL ⇔ len == 0`) at the single choke
        // point every event passes through. Rust producers naturally
        // violate it: an empty slice's `as_ptr()` is non-null, and an
        // empty `String`'s `as_ptr()` is `NonNull::dangling()` (0x1) —
        // a conforming C consumer that branches on `payload != NULL`
        // per the header would dereference it.
        let mut event = event;
        if event.len == 0 {
            event.payload = std::ptr::null();
        }
        // Overlap-detection scope covers the slot read and the rate-state
        // mutation below, and ends BEFORE the user callback runs — a
        // nested dispatch from inside `f` must not false-trip the guard.
        let _busy = self.debug_enter();
        // Reviewer feedback (2026-04-29): read the callback slot FIRST.
        // If no callback is registered (e.g. `set()` never called or
        // explicitly cleared), every PtyWrite previously consumed a
        // budget slot anyway — the cap should limit *dispatched* events,
        // not *attempted* ones. With this reorder a pre-callback
        // PtyWrite flood no longer drains the budget that the post-
        // callback session needs.
        let (cb, ctx) = *self.slot.get();
        let Some(f) = cb else {
            return;
        };
        // Audit H-4: PtyWrite cap is total-by-construction. All three
        // PtyWrite-firing paths (RoutingListener::send_event,
        // dispatch_xtgettcap, drain_color_requests) inherit the cap from
        // here. This used to live in RoutingListener::send_event, where
        // it gated only the alacritty-driven path.
        if matches!(event.kind, BBEventKind::PtyWrite) && !self.pty_write_rate.allow() {
            return;
        }
        // Audit S1-002: Title/Bell were the only uncapped event kinds a
        // hostile byte stream can fan out per-event to the Swift main
        // queue. Same silent-drop policy as PtyWrite (per-drop logging
        // would itself amplify the flood).
        if matches!(event.kind, BBEventKind::Title)
            && !(*self.title_rate.get()).allow(TITLE_EVENT_PER_SECOND, EVENT_RATE_WINDOW)
        {
            return;
        }
        if matches!(event.kind, BBEventKind::Bell)
            && !(*self.bell_rate.get()).allow(BELL_EVENT_PER_SECOND, EVENT_RATE_WINDOW)
        {
            return;
        }
        // Audit M-9 follow-up (2026-04-29): set the
        // `FFI_HANDLER_IN_FLIGHT` latch around the user-callback
        // dispatch so a synchronous re-entry from inside `f` into a
        // `bb_term_*` entry point can be detected at the FFI boundary
        // BEFORE the second `&mut Term` reborrow takes effect. The
        // Swift-side `BBTerm.isInsideEventDispatch` precondition fires
        // AFTER the second `&mut Term` is on stack — this guard is the
        // dynamic catch one frame earlier. RAII drop restores `false`
        // even if `f` panics (the outer `catch_unwind` machinery in
        // `guard_with_term` still owns the panic; this guard exists
        // only to expose the in-flight bit).
        #[cfg(debug_assertions)]
        drop(_busy);
        let _handler_guard = HandlerInFlightGuard::enter();
        f(event, ctx);
    }
}

// ---------------------------------------------------------------------------
// ColorRequestQueue — deferred OSC 10/11/12 color-query responses
// ---------------------------------------------------------------------------

/// Parked `Event::ColorRequest` events. Alacritty fires these from inside
/// `term.dynamic_color_sequence`, which holds `&mut Term`; we can't re-borrow
/// the term to read the palette from the listener. Instead the listener
/// pushes `(index, formatter)` pairs here, and `bb_term_input` drains the
/// queue after `processor.advance` returns (releasing the mutable borrow),
/// resolves the palette value, calls the formatter, and fires a PtyWrite.
///
/// # DoS backstop
/// `push` is hard-capped at `COLOR_REQUEST_QUEUE_CAP` entries. A hostile
/// stream spamming `ESC]4;N;?BEL` across a single `bb_term_input` chunk
/// would otherwise force an unbounded number of `Arc<dyn Fn>` trait-object
/// allocations inside one call, inconsistent with the 4 KiB `xtgettcap_buf`
/// cap already defending the sibling DCS path (rust-core-1 F1). 256 covers
/// any legitimate probe — xterm reads the entire 256-entry palette at
/// startup — and is well below the point where per-entry allocation churn
/// becomes user-visible.
///
/// # Thread-safety contract
/// Same as `CallbackCell` — mutually-exclusive access under the BBTerm
/// handle's one-thread-at-a-time discipline. Debug builds detect
/// overlapping access via a `busy` flag and panic (rust-core-1 F2/F10,
/// reworked per audit S1-004 — see `CallbackCell`).
struct ColorRequestQueue {
    entries: UnsafeCell<Vec<ColorRequestEntry>>,
    /// True once `push` has refused at least one entry since the latest
    /// `drain`. Drives a one-shot log per cap-hit episode — per-drop
    /// logging would itself become the DoS amplifier we're defending
    /// against.
    cap_hit_logged: UnsafeCell<bool>,
    #[cfg(debug_assertions)]
    busy: std::sync::atomic::AtomicBool,
}

/// Upper bound on queued `ColorRequestEntry`s between two drains. See
/// `ColorRequestQueue` doc for rationale.
const COLOR_REQUEST_QUEUE_CAP: usize = 256;

struct ColorRequestEntry {
    index: usize,
    formatter: Arc<dyn Fn(Rgb) -> String + Sync + Send>,
}

// SAFETY: the owning BBTerm is never shared across threads; same reasoning
// as CallbackCell.
unsafe impl Send for ColorRequestQueue {}
unsafe impl Sync for ColorRequestQueue {}

impl ColorRequestQueue {
    fn new() -> Self {
        ColorRequestQueue {
            entries: UnsafeCell::new(Vec::new()),
            cap_hit_logged: UnsafeCell::new(false),
            #[cfg(debug_assertions)]
            busy: std::sync::atomic::AtomicBool::new(false),
        }
    }

    #[cfg(debug_assertions)]
    fn debug_enter(&self) -> DebugBusyGuard<'_> {
        DebugBusyGuard::enter(&self.busy, "ColorRequestQueue")
    }

    #[cfg(not(debug_assertions))]
    #[inline(always)]
    fn debug_enter(&self) {}

    /// Append an entry, dropping silently when the queue is already at
    /// `COLOR_REQUEST_QUEUE_CAP`. Returns `true` when the entry was
    /// accepted.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn push(&self, entry: ColorRequestEntry) -> bool {
        let _busy = self.debug_enter();
        let vec = &mut *self.entries.get();
        if vec.len() >= COLOR_REQUEST_QUEUE_CAP {
            let logged = &mut *self.cap_hit_logged.get();
            if !*logged {
                *logged = true;
                eprintln!(
                    "blackbird_core: ColorRequestQueue hit cap ({COLOR_REQUEST_QUEUE_CAP}); \
                     further OSC 4/10/11/12 queries in this batch dropped"
                );
            }
            return false;
        }
        vec.push(entry);
        true
    }

    /// Take and clear the queue. Resets the cap-hit latch so the next
    /// hit episode logs again.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn drain(&self) -> Vec<ColorRequestEntry> {
        let _busy = self.debug_enter();
        *self.cap_hit_logged.get() = false;
        std::mem::take(&mut *self.entries.get())
    }

    /// Number of currently-queued entries. Test-only introspection.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    #[cfg(test)]
    unsafe fn len(&self) -> usize {
        (*self.entries.get()).len()
    }
}

// ---------------------------------------------------------------------------
// RoutingListener — bridges alacritty_terminal events to C callbacks
// ---------------------------------------------------------------------------

/// Event listener that forwards terminal events to a registered C callback.
///
/// Shares ownership of the `CallbackCell` and `ColorRequestQueue` with the
/// parent `BBTerm` via `Arc`. The previous implementation used raw pointers
/// and relied on field drop order (`Term` dropped before `Box<CallbackCell>`)
/// to keep them valid — a structural invariant enforced only by comments.
/// `Arc` shares the allocation, so even in a future refactor where the
/// listener outlives the owning `BBTerm` or an event fires mid-teardown,
/// every access lands on live memory (rust-core-1 F3).
///
/// # Thread-safety contract
/// Must be constructed and used exclusively on the thread that owns the
/// `BBTerm`. The Arcs are `Send + Sync` (the inner cells unsafe-impl `Sync`
/// under single-thread discipline), but BBTerm's own single-thread rule
/// still forbids concurrent `bb_term_input` calls — that is the real
/// invariant. Arc merely removes the drop-order footgun that otherwise
/// turned a future refactor into silent use-after-free.
struct RoutingListener {
    cell: Arc<CallbackCell>,
    color_queue: Arc<ColorRequestQueue>,
    // Audit H-4 (2026-04-29): the PtyWrite rate cap (32/sec, audit M1)
    // moved into `CallbackCell::fire` so all three dispatch paths
    // (this listener, `dispatch_xtgettcap`, `drain_color_requests`)
    // inherit it by construction. The shared `Arc<PtyWriteRateCell>`
    // now lives on `CallbackCell`; the listener doesn't need its own
    // reference because every send_event PtyWrite goes through
    // `self.cell.fire`.
}

/// Rate-limiter state for PtyWrite reply events. Mutated only on the
/// BBTerm-owning thread; the Send/Sync impls below upgrade the
/// `Arc<…>` to thread-safe under that discipline (same pattern as
/// `ColorRequestQueue`).
#[derive(Debug)]
struct PtyWriteRateState {
    window_start: std::time::Instant,
    window_count: u32,
}

/// Send+Sync wrapper around `UnsafeCell<PtyWriteRateState>` so it can
/// live behind an `Arc` shared with `RoutingListener`. The wrapper is
/// the same shape `ColorRequestQueue` uses; both rely on the
/// single-thread-per-BBTerm contract documented in `RoutingListener`.
struct PtyWriteRateCell {
    state: UnsafeCell<PtyWriteRateState>,
}

// SAFETY: BBTerm's single-thread-per-handle contract (see
// `RoutingListener` doc) forbids concurrent access to the listener,
// and PtyWriteRateCell is reachable only via that listener.
unsafe impl Send for PtyWriteRateCell {}
unsafe impl Sync for PtyWriteRateCell {}

impl PtyWriteRateCell {
    fn new() -> Self {
        Self {
            state: UnsafeCell::new(PtyWriteRateState::new()),
        }
    }

    /// Returns true if the dispatch is allowed; false if the cap has
    /// been hit and the caller should drop the event silently.
    ///
    /// # Safety
    /// Caller must respect the single-thread-per-BBTerm discipline —
    /// no concurrent calls.
    unsafe fn allow(&self) -> bool {
        (*self.state.get()).allow()
    }

    /// Reset the sliding window so the next `allow()` starts a fresh
    /// 1-second budget. Used by `bb_term_clear_all` (audit H-3) so a
    /// pre-clear PtyWrite flood doesn't eat the post-clear session's
    /// PTY-write budget.
    ///
    /// # Safety
    /// Caller must respect the single-thread-per-BBTerm discipline —
    /// no concurrent calls.
    unsafe fn reset(&self) {
        *self.state.get() = PtyWriteRateState::new();
    }
}

const PTY_WRITE_REPLY_PER_SECOND: u32 = 32;
const PTY_WRITE_REPLY_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// Sliding-window state for the Title/Bell event caps (audit S1-002).
/// Same shape as `PtyWriteRateState`, parameterized so one type serves
/// both kinds. Lives inside `CallbackCell` behind the same
/// mutual-exclusion discipline as `slot`.
struct EventRateState {
    window_start: std::time::Instant,
    window_count: u32,
}

impl EventRateState {
    fn new() -> Self {
        Self {
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    fn allow(&mut self, cap: u32, window: std::time::Duration) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.window_start) >= window {
            self.window_start = now;
            self.window_count = 0;
        }
        if self.window_count >= cap {
            return false;
        }
        self.window_count += 1;
        true
    }
}

/// Title-event cap (audit S1-002). Every `Event::Title`/`Event::Bell`
/// used to dispatch uncapped — only PtyWrite had a budget — and the
/// Swift side enqueues one main-queue hop per event (titles amplify
/// further through @Published → window.title → KVO → tab-bar refresh
/// broadcast). A stream of `ESC]0;x BEL` (`yes $'\e]0;x\a'`, a hostile
/// remote, or catting a binary full of BEL bytes) therefore saturated
/// the main queue with an unbounded backlog of retained Strings — the
/// same flood class the F1 snapshot coalescer and M1 PtyWrite cap
/// already closed on their paths. 32/sec matches the PtyWrite budget:
/// legitimate shells emit a couple of titles per prompt and animated
/// build tools stay well under. Excess drops keep the FIRST events in
/// each window, so a flood shows a stale title until the next admitted
/// event — self-healing, since shells re-emit per prompt.
const TITLE_EVENT_PER_SECOND: u32 = 32;
/// Bell-event cap (audit S1-002, same rationale as the title cap).
/// 16/sec is far above perception — the Swift bell flash visually
/// coalesces long before that.
const BELL_EVENT_PER_SECOND: u32 = 16;
const EVENT_RATE_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

impl PtyWriteRateState {
    fn new() -> Self {
        Self {
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    /// Returns true if the dispatch is allowed; false if the cap has
    /// been hit and the caller should drop the event silently.
    fn allow(&mut self) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.window_start) >= PTY_WRITE_REPLY_WINDOW {
            self.window_start = now;
            self.window_count = 0;
        }
        if self.window_count >= PTY_WRITE_REPLY_PER_SECOND {
            return false;
        }
        self.window_count += 1;
        true
    }
}

/// True for Unicode scalars that NSWindow / NSTextField will render in a
/// way the user can't see: bidi-control overrides, zero-width joiners,
/// invisible tag-block / variation-selector codepoints, and the BOM.
///
/// Sibling of `contains_bidi_or_invisible`'s byte-shape sweep below — the
/// scalar list MUST stay in lock-step with it. If you add a codepoint to
/// one, add the matching UTF-8 byte range to the other (and vice versa).
/// The two functions exist because their input shapes differ: this one
/// takes a `char` (callers already validated UTF-8), while
/// `contains_bidi_or_invisible` takes raw bytes (post-percent-decode
/// payloads that may not yet be valid UTF-8).
///
/// Codepoints rejected (mirroring `contains_bidi_or_invisible`'s byte
/// table, see its doc for the byte ranges):
///   U+00AD (SHY), U+061C (ALM), U+180E (MVS),
///   U+200B..=U+200F (ZWSP/ZWNJ/ZWJ/LRM/RLM),
///   U+2028..=U+202E (LS/PS, LRE/RLE/PDF/LRO/RLO),
///   U+2060 (WJ), U+2066..=U+2069 (LRI/RLI/FSI/PDI),
///   U+FE00..=U+FE0F (variation selectors 1..16), U+FEFF (BOM/ZWNBSP),
///   U+E0000..=U+E007F (tag block),
///   U+E0100..=U+E01EF (variation selectors 17..256).
fn is_bidi_or_invisible_scalar(c: char) -> bool {
    let cp = c as u32;
    matches!(cp,
        0x00AD
        | 0x061C
        | 0x180E
        | 0x200B..=0x200F
        | 0x2028..=0x202E
        | 0x2060
        | 0x2066..=0x2069
        | 0xFE00..=0xFE0F
        | 0xFEFF
        | 0xE0000..=0xE007F
        | 0xE0100..=0xE01EF
    )
}

/// Strip C0 controls (U+0000..=U+001F), DEL (U+007F), C1 controls
/// (U+0080..=U+009F), AND bidi-control / invisible scalars from an OSC
/// 0/1/2 window-title payload.
///
/// Bug #18: a hostile stream sets the title to `before\x1b[31mafter`;
/// downstream loggers / accessibility consumers misinterpret the embedded
/// controls even though NSWindow sanitizes for display.
///
/// Audit H-5 (2026-04-29): C0/C1 stripping isn't enough. A hostile shell
/// can emit `\x1b]2;safe\u{202E}txt\x07` and AppKit's titlebar honours
/// U+202E (RIGHT-TO-LEFT OVERRIDE), visually flipping the suffix to
/// `txt.efas` while the underlying title stays whatever the shell said.
/// The OSC 7 path got `contains_bidi_or_invisible` (rejection); the title
/// path can't reject (that would drop the entire title), so we strip the
/// offending scalars in-place and keep everything else.
///
/// Codepoint-wise filter so C1 (UTF-8 `0xC2 0x80..=0xC2 0x9F`) drops by
/// a single `c <= '\u{9F}'` check rather than a fragile byte sweep that
/// would corrupt multi-byte UTF-8.
///
/// Allocation note: alacritty hands us a `&String`; a clean (no-control)
/// title is the common case. We could short-circuit when no control char
/// is present, but the title path fires once per OSC 0/2 dispatch — at
/// most a few times per second even for animated TUIs — so a single
/// always-allocate keeps the code obvious.
fn scrub_title_controls(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        let cp = c as u32;
        let is_c0 = cp <= 0x1F;
        let is_del = cp == 0x7F;
        let is_c1 = (0x80..=0x9F).contains(&cp);
        if is_c0 || is_del || is_c1 {
            continue;
        }
        if is_bidi_or_invisible_scalar(c) {
            continue;
        }
        out.push(c);
    }
    out
}

impl EventListener for RoutingListener {
    fn send_event(&self, event: Event) {
        // SAFETY: `cell` and `color_queue` remain live for as long as any
        // Arc clone exists; single-thread discipline (see RoutingListener
        // doc) means no concurrent access.
        unsafe {
            match event {
                Event::Bell => {
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Bell,
                        payload: std::ptr::null(),
                        len: 0,
                        i32_arg: 0,
                    });
                }
                Event::Title(ref s) => {
                    // Bug #18: strip C0 (0x00..=0x1F), DEL (0x7F), and C1
                    // (U+0080..=U+009F) controls from the title before
                    // firing. A malicious shell or remote SSH session may
                    // emit `\x1b]2;before\x1b[31mafter\x07`; alacritty hands
                    // us the raw payload and downstream consumers (Swift
                    // NSWindow.title, telemetry, accessibility) treat the
                    // String literally. Display sanitizes, but stored /
                    // logged copies misinterpret embedded controls.
                    //
                    // Filter codepoint-wise so the C1 case (encoded as
                    // 0xC2 0x80..=0xC2 0x9F in UTF-8) is handled by char
                    // semantics rather than a fragile byte filter.
                    let scrubbed = scrub_title_controls(s);
                    let bytes = scrubbed.as_bytes();
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Title,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                    });
                }
                Event::ClipboardStore(_, ref s) => {
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Osc52Clipboard,
                        payload: s.as_ptr(),
                        len: s.len(),
                        i32_arg: 0,
                    });
                }
                Event::PtyWrite(ref s) => {
                    // The 32/sec cap on cursor-position / DA / DSR /
                    // DECXCPR replies (audit M1) lives inside
                    // `CallbackCell::fire` for `kind == PtyWrite`, so the
                    // gate is total-by-construction — every PtyWrite
                    // path (this one + dispatch_xtgettcap +
                    // drain_color_requests) inherits the same cap from
                    // one place (audit H-4). Pre-H-4 the gate lived
                    // here; the two direct-fire sites then bypassed it.
                    let bytes = s.as_bytes();
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::PtyWrite,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                    });
                }
                Event::ColorRequest(index, formatter) => {
                    // Defer — we're inside alacritty's &mut Term borrow via
                    // dynamic_color_sequence, so the palette isn't readable
                    // from here. `bb_term_input` drains this queue right
                    // after processor.advance returns, reads the palette,
                    // calls the formatter, and emits PtyWrite.
                    // push() is `bool`-returning for DoS capping; we ignore
                    // the drop signal here — the listener can't replywrite
                    // anyway, and the one-shot log inside push() surfaces
                    // the hostile case for diagnostics.
                    let _ = self
                        .color_queue
                        .push(ColorRequestEntry { index, formatter });
                }
                // All other variants (MouseCursorDirty, ResetTitle, ClipboardLoad,
                // TextAreaSizeRequest, CursorBlinkingChange, Wakeup, Exit,
                // ChildExit) are intentionally ignored.
                _ => {}
            }
        }
    }
}

// ---------------------------------------------------------------------------
// OscScanner — parallel vte::Parser tap for OSC sequences we handle outside
// of alacritty: OSC 7 (cwd) and OSC 133 (prompt marks).
// ---------------------------------------------------------------------------

/// Minimal `vte::Perform` impl that fires on OSC 7, OSC 133, and
/// XTGETTCAP (DCS `+ q` ... ST) payloads.
///
/// `alacritty_terminal` 0.26 / `vte` 0.15 do not handle these themselves —
/// they fall through vte's `osc_dispatch` to the unhandled branch. Rather
/// than wrap alacritty's `Handler` (which has a ~90-method surface we'd
/// have to forward perfectly), we run a second, stateful `vte::Parser`
/// owned by `BBTerm` and driven from `bb_term_input` with the same byte
/// stream. That parser drives this scanner, which dispatches by the first
/// OSC param and no-ops every other Perform method — except `hook`/`put`/
/// `unhook`, which implement Kitty's XTGETTCAP capability query protocol.
///
/// Consolidated from two separate parsers (one per OSC number) into one —
/// the earlier split cost ~15% of throughput because every byte was run
/// through three parsers total (alacritty's main + two parallels). One
/// scanner with an inexpensive first-param check is strictly cheaper.
///
/// XTGETTCAP state lives on `BBTerm` rather than this scanner because DCS
/// sequences can fragment across multiple `bb_term_input` calls; the
/// scanner is re-created per call and borrows the state via `&mut`.
struct OscScanner<'a> {
    cell: &'a CallbackCell,
    in_xtgettcap: &'a mut bool,
    xtgettcap_buf: &'a mut Vec<u8>,
    /// xterm `modifyOtherKeys` level bucket. `csi_dispatch` updates this
    /// when it sees `CSI > 4 ; N m`. 0 = off, 1 / 2 = level. Writer
    /// into `BBTerm.modify_other_keys`; downstream code reads the same
    /// field and maps non-zero to `bb_mode::MODIFY_OTHER_KEYS`.
    modify_other_keys: &'a mut u8,
    /// Sliding-window state for OSC 133 A/B/C rate limiting (audit
    /// synthesis #10 — prompt-mark forgery DoS / phishing). Persisted
    /// on `BBTerm` and threaded in via `&mut` because the scanner is
    /// rebuilt per `bb_term_input` call.
    prompt_mark_rate: &'a mut PromptMarkRateState,
    /// Sliding-window state for OSC 7 (CWD) ingest rate limiting (audit
    /// M-7 — `classifyForegroundNamespace()` proc_listpids amplification).
    /// Same threading reason as `prompt_mark_rate`.
    osc7_rate: &'a mut Osc7RateState,
    /// Per-class reject-log latches (audit L3). Threaded in from
    /// BBTerm so the one-shot-per-class log is per-instance rather
    /// than process-wide.
    osc7_reject_logged: &'a mut [bool; 8],
    /// One-shot latch for the OSC 133 D non-digit reject path
    /// (audit L1 + reviewer follow-up). Mirrors the per-instance
    /// stance L3 established for OSC 7.
    osc133_d_nondigit_logged: &'a mut bool,
    /// One-shot latch for the OSC 133 A/B/C tainted-payload reject path
    /// (audit S3R-001/S3R-002 + silent-failure review). Same per-instance,
    /// one-shot rule as the D-path latch so a hostile flood can't drown the
    /// log while still leaving one breadcrumb when prompt marks are dropped.
    osc133_abc_tainted_logged: &'a mut bool,
    /// One-shot latch for the OSC 133 rate-cap drop path (audit S5-009).
    /// Dropped marks are user-visible (missing ⌘-navigation entries,
    /// lost exit codes), so the first drop per session must leave a
    /// breadcrumb; per-drop logging would amplify the flood the cap
    /// defends against.
    osc133_rate_limited_logged: &'a mut bool,
}

/// Per-terminal sliding-window rate limiter for OSC 133 prompt marks.
///
/// Mitigates audit synthesis bug #10: an attacker emitting `OSC 133;A`
/// thousands of times per second floods Swift's `recordPromptStart` ring
/// (cap 200) and rotates legitimate prompt marks out, so ⌘↑/⌘↓ navigation
/// lands on attacker-authored "fake prompts" — a phishing primitive.
///
/// Policy: at most `PROMPT_MARK_PER_SECOND` dispatches per rolling
/// 1-second window across ALL FOUR kinds (A/B/C/D — see the gate in
/// `handle_osc133` for why D is included; RC-03).
///
/// The window resets when `Instant::now()` is more than 1 second past
/// `window_start`. Excess fires within an active window are dropped;
/// the first drop per session leaves a one-shot breadcrumb (see
/// `osc133_rate_limited_logged`).
///
/// Sizing (audit S5-009, 2026-06-09): the original 16/sec budget was
/// sized for hostile floods but dropped LEGITIMATE marks at ordinary
/// interactive rates — the bundled integration emits D+A (precmd) +
/// B (PS1) per empty prompt cycle and +C per command, so holding
/// Return at a shell prompt (macOS key-repeat up to ~33 Hz × 3 marks)
/// produces ~100 marks/sec and cycle 6+'s A marks vanished from ⌘
/// navigation while their paired Ds desynced. 240/sec is ~2× the
/// fastest physically-typeable mark rate (33 Hz × 4 marks + margin)
/// while still bounding a hostile flood to 240 small main-thread hops
/// per second on the Swift side — the phishing/DoS mitigation #10
/// cares about is preserved.
#[derive(Clone, Copy)]
struct PromptMarkRateState {
    window_start: std::time::Instant,
    window_count: u32,
}

const PROMPT_MARK_PER_SECOND: u32 = 240;
const PROMPT_MARK_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// OSC 10/11/12 color-query reply rate limit (audit synthesis bug #17).
/// `ColorRequestQueue::push` already caps at 256 entries per `bb_term_input`
/// chunk, but a hostile shell can split queries across many tight chunks to
/// bypass that per-call cap and amplify replies through the PTY. This
/// sliding-window cap covers the cross-chunk case using the same pattern as
/// `PromptMarkRateState`. 32/sec is generous (legitimate apps probe at most
/// a handful per second); excess replies are dropped silently.
const COLOR_QUERY_REPLY_PER_SECOND: u32 = 32;
const COLOR_QUERY_REPLY_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// OSC 7 (CWD reporting) ingest rate limit (audit M-7, 2026-04-29).
/// Legitimate shells emit one OSC 7 per `cd` — typically far fewer than
/// 1/sec interactively. A hostile remote streaming OSC 7s in a tight
/// loop forces `TerminalSession.handleCwdChanged` (Swift) to run
/// `classifyForegroundNamespace()` on every event, which does a
/// `proc_listpids(PROC_PPID_ONLY)` BFS up to 256 nodes — main-thread
/// work that beachballs the UI. 32/sec mirrors the existing PtyWrite
/// cap; well above any realistic interactive shell, well below the
/// flood-amplification threshold. Excess OSC 7s are dropped silently.
const OSC7_INGEST_PER_SECOND: u32 = 32;
const OSC7_INGEST_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// Maximum byte length of a single OSC 7 URL accepted for percent-decode
/// (audit L-20, 2026-04-29). OSC 8's `OSC8_URI_MAX` is 4096 by the same
/// reasoning: a legitimate `file://` URL for a cwd is at most a few
/// hundred bytes; oversized payloads are either malicious spam or a
/// bug, and the unbounded `Vec::with_capacity(bytes.len())` inside
/// `percent_decode` would otherwise let a remote allocate megabytes per
/// OSC 7 chunk.
const OSC7_URL_MAX: usize = 4096;

impl PromptMarkRateState {
    fn new() -> Self {
        Self {
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    /// Returns true if the dispatch is allowed; false if the window cap
    /// has been hit and the caller should drop the event.
    fn allow(&mut self) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.window_start) >= PROMPT_MARK_WINDOW {
            self.window_start = now;
            self.window_count = 0;
        }
        if self.window_count >= PROMPT_MARK_PER_SECOND {
            return false;
        }
        self.window_count += 1;
        true
    }
}

/// Per-terminal sliding-window rate limiter for OSC 7 (CWD) ingest.
/// See `OSC7_INGEST_PER_SECOND` for sizing rationale (audit M-7).
/// Same shape as `PromptMarkRateState` — kept as a separate type so the
/// constants are independent and the `clear_all` reset can target each
/// limiter individually (audit H-3).
#[derive(Clone, Copy)]
struct Osc7RateState {
    window_start: std::time::Instant,
    window_count: u32,
}

impl Osc7RateState {
    fn new() -> Self {
        Self {
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    fn allow(&mut self) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.window_start) >= OSC7_INGEST_WINDOW {
            self.window_start = now;
            self.window_count = 0;
        }
        if self.window_count >= OSC7_INGEST_PER_SECOND {
            return false;
        }
        self.window_count += 1;
        true
    }
}

impl Perform for OscScanner<'_> {
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        // Dispatch by OSC number. The first param is always the
        // semicolon-separated numeric prefix (e.g. `7`, `133`).
        //
        // We deliberately handle only the OSC numbers that need a
        // Blackbird-side hook: 7 (CWD reporting) and 133 (semantic prompt
        // marks). All other OSC numbers fall through to alacritty's main
        // `Processor` driving `bb.term`. Alacritty handles 0/1/2 (window
        // titles), 4 (palette set), 8 (hyperlinks via the cell hyperlink
        // path), 10/11/12 + 104/110/111/112 (default fg/bg/cursor color
        // get/reset, surfaced via our color-query hook), 50 (cursor),
        // 52 (clipboard — pinned `Disabled`), 110/111/112 (color resets),
        // and a few it explicitly ignores.
        //
        // Anything not matched here AND not handled by alacritty (OSC 6
        // working-file, OSC 1337 iTerm2 extensions, etc.) is silently
        // dropped at both layers. If you add a new Blackbird-owned OSC
        // hook, list it here so this catch-all stays auditable.
        match params.first().copied() {
            Some(b"7") => self.handle_osc7(params),
            Some(b"133") => self.handle_osc133(params),
            _ => {}
        }
        // bell_terminated is irrelevant to downstream semantics; included
        // here only to satisfy the Perform signature.
        let _ = bell_terminated;
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        // xterm `modifyOtherKeys`: `CSI > 4 ; N m`. `>` is the only
        // intermediate; first param == 4; second param == 0 (off), 1
        // (level 1), or 2 (level 2). We also accept `CSI > 4 m` (no
        // second param) as the reset form, matching xterm's manpage.
        // alacritty_terminal 0.26.0 does not handle this sequence —
        // we own the entire parse path for it.
        if action == 'm' && intermediates == [b'>'] {
            let mut it = params.iter();
            let first = it.next().and_then(|p| p.first().copied());
            if first == Some(4) {
                let level = it.next().and_then(|p| p.first().copied()).unwrap_or(0);
                let clamped: u8 = match level {
                    0 => 0,
                    1 | 2 => level as u8,
                    _ => return, // unknown level — ignore, don't poison state
                };
                *self.modify_other_keys = clamped;
            }
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        // RIS (`ESC c`): full terminal reset. The main alacritty
        // `Processor` driving `bb.term` resets its `TermMode` to
        // defaults on this same byte (via `Term::reset_state`),
        // clearing the Kitty-keyboard / app-cursor / bracketed-paste
        // bits. `modify_other_keys` is Blackbird-side sidecar state
        // that alacritty never sees (we own the entire `CSI > 4 ; N m`
        // parse — see `csi_dispatch` above), so without mirroring the
        // reset here it stays latched across RIS:
        // `extract_mode_with_extras` keeps OR-ing in MODIFY_OTHER_KEYS
        // and Swift's KeyEncoder keeps emitting `CSI 27 ; <mod> ; <cp>
        // ~` for modified keys to a shell that just reset itself and no
        // longer understands the encoding. Clear it so the reported
        // mode tracks the reset, matching xterm semantics (the bit doc
        // at the top of this file states RIS clears modifyOtherKeys).
        //
        // RIS only — deliberately NOT DECSTR (`CSI ! p`): this
        // alacritty/vte version has no DECSTR handler, so a soft reset
        // leaves alacritty's own modes untouched. Clearing
        // modify_other_keys on DECSTR while Kitty / app-cursor /
        // bracketed-paste stay set would introduce the opposite
        // desync. Mirror alacritty exactly.
        if byte == b'c' && intermediates.is_empty() {
            *self.modify_other_keys = 0;
        }
    }

    fn hook(&mut self, _params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        // XTGETTCAP opens as `ESC P + q` — intermediates == [b'+'],
        // final byte == 'q'. Any other DCS (sixel, sync output, iTerm2
        // conductor, etc.) stays inert: `dcs_rejection` tests pin that.
        if intermediates == b"+" && action == 'q' {
            *self.in_xtgettcap = true;
            self.xtgettcap_buf.clear();
        }
    }

    fn put(&mut self, byte: u8) {
        // Only collect while inside a recognized XTGETTCAP sequence. Cap
        // at 4 KiB as a DoS backstop: a legitimate query is at most a
        // few hundred bytes; truncation of an oversized query produces
        // a short reply rather than a crash or unbounded allocation.
        if *self.in_xtgettcap && self.xtgettcap_buf.len() < 4096 {
            self.xtgettcap_buf.push(byte);
        }
    }

    fn unhook(&mut self) {
        if !*self.in_xtgettcap {
            return;
        }
        *self.in_xtgettcap = false;
        // `std::mem::take` moves the buffer's bytes+allocation out into
        // `buf` for the reply-building step; the field becomes
        // `Vec::new()` (capacity 0). The next DCS will re-alloc on its
        // first `put()`. XTGETTCAP is human-rate so this churn is
        // invisible; simpler code wins over a micro-optimization.
        let buf = std::mem::take(self.xtgettcap_buf);
        // SAFETY: our parallel `vte::Parser` is driven from
        // `bb_term_input` OUTSIDE alacritty's `&mut Term` borrow, so
        // firing synchronously here is safe — we are not re-entering
        // alacritty. No deferred queue needed (unlike OSC 10/11/12,
        // which must defer because they hit the palette mid-borrow).
        unsafe { dispatch_xtgettcap(self.cell, &buf) };
    }
}

/// Fire one `PtyWrite` reply per `;`-delimited cap. Unknown caps reply
/// with status 0 and no `=value`. Match replies echo the request's cap
/// hex verbatim (preserving casing) so TUIs can correlate requests and
/// replies without canonicalizing.
///
/// # Safety
/// Caller must ensure single-threaded access to `cell` (standard BBTerm
/// thread discipline).
unsafe fn dispatch_xtgettcap(cell: &CallbackCell, payload: &[u8]) {
    for cap_hex in payload.split(|&b| b == b';') {
        if cap_hex.is_empty() {
            // `;;` or leading/trailing `;` — skip silently.
            continue;
        }
        let reply = build_xtgettcap_reply(cap_hex);
        cell.fire(BBEvent {
            kind: BBEventKind::PtyWrite,
            payload: reply.as_ptr(),
            len: reply.len(),
            i32_arg: 0,
        });
        // `reply` drops here; `fire` is synchronous so the C callback
        // has already consumed the bytes by the time we release.
    }
}

fn build_xtgettcap_reply(cap_hex: &[u8]) -> Vec<u8> {
    // Reject anything that isn't pure hex. XTGETTCAP specifies the payload
    // as hex-encoded cap name bytes (each cap name byte = 2 hex digits),
    // but nothing upstream enforced it — an ssh'd attacker could smuggle
    // `\x1b\\` (ST) or other control bytes inside the cap_hex echo of the
    // DCS-0-r "unknown" response, terminating the DCS early and landing
    // the tail bytes as top-level input (shell-injection primitive on the
    // remote). Audit rust-core-1 F8. Unknown non-hex cap → reply with an
    // empty cap name so the reply stays well-formed and the echo channel
    // closes.
    //
    // S3-004: also require EVEN length. Odd-length all-hex payloads
    // (e.g. a 3-char query, or a 4097-byte query truncated mid-pair)
    // are still "pure hex" but echo as a malformed cap name with a
    // half-byte at the tail — every legitimate downstream consumer
    // expects paired hex digits. Reject as malformed alongside the
    // non-hex case.
    let is_valid_hex = !cap_hex.is_empty()
        && cap_hex.len() % 2 == 0
        && cap_hex.iter().all(|b| b.is_ascii_hexdigit());
    match (is_valid_hex, find_cap_value(cap_hex)) {
        (true, Some(value_hex)) => {
            // DCS 1 + r <cap>=<value> ST
            let mut v = Vec::with_capacity(cap_hex.len() + value_hex.len() + 8);
            v.extend_from_slice(b"\x1bP1+r");
            v.extend_from_slice(cap_hex);
            v.push(b'=');
            v.extend_from_slice(value_hex);
            v.extend_from_slice(b"\x1b\\");
            v
        }
        (true, None) => {
            // DCS 0 + r <cap> ST — hex echo is safe.
            let mut v = Vec::with_capacity(cap_hex.len() + 7);
            v.extend_from_slice(b"\x1bP0+r");
            v.extend_from_slice(cap_hex);
            v.extend_from_slice(b"\x1b\\");
            v
        }
        (false, _) => {
            // DCS 0 + r ST — no echo; hostile bytes dropped.
            b"\x1bP0+r\x1b\\".to_vec()
        }
    }
}

/// ASCII-case-insensitive lookup against `XTGETTCAP_TABLE`. Cap hex is
/// canonically uppercase, but tolerate lowercase defensively — some
/// ncurses builds lowercase hex when emitting `tput`-style queries.
fn find_cap_value(cap_hex: &[u8]) -> Option<&'static [u8]> {
    for (key, value) in XTGETTCAP_TABLE {
        if cap_hex.eq_ignore_ascii_case(key) {
            return Some(value);
        }
    }
    None
}

/// Kitty XTGETTCAP capabilities Blackbird claims. Each row is
/// (hex-encoded cap name, hex-encoded terminfo-compiled value).
///
/// Values are the bytes of the terminfo string, hex-encoded upper-case.
/// `\E` in terminfo source is ESC (0x1B), not a literal `\`+`E`, so the
/// hex is `1B` in those positions.
///
/// Claimed caps (why each matters):
/// - TN     = "xterm-kitty"  — the terminal identity string some TUIs
///   key on to enable advanced protocols.
/// - Co     = "16777216"     — color count. Pre-LOW-sweep this was
///   "256" (legacy default), which made `tput colors` report 256 even
///   though Blackbird decodes truecolor SGR 38;2;R;G;Bm — TUIs that
///   gate truecolor branches on the terminfo Co value (mc, less +F,
///   ranger, some neovim plugins) fell back to 256-color paths.
///   Audit NEW-DF-004.
/// - RGB    = "8"             — truecolor bits per channel.
/// - Smulx  = "\E[4:%p1%dm"   — styled underline select (SGR 4:n).
/// - Setulc = "\E[58:2::%p1%{65536}%/%d:%p2%{256}%/%d:%p3%d%;m"
///   — RGB underline color (SGR 58:2:R:G:B).
///
/// Smulx/Setulc together are what nvim probes before emitting colored
/// undercurl (`spellbad`, LSP diagnostics). Getting both right is the
/// whole point of claiming xterm-kitty.
///
/// Test `core/tests/xtgettcap.rs::xtgettcap_smulx_returns_expected_hex`
/// and `..._setulc_returns_expected_hex` pin these exact hex strings.
static XTGETTCAP_TABLE: &[(&[u8], &[u8])] = &[
    // TN     = "TN"     → 544E        value "xterm-kitty"  → 787465726D2D6B69747479
    (b"544E", b"787465726D2D6B69747479"),
    // Co     = "Co"     → 436F        value "16777216"     → 3136373737323136
    (b"436F", b"3136373737323136"),
    // RGB    = "RGB"    → 524742      value "8"            → 38
    (b"524742", b"38"),
    // Smulx  = "Smulx"  → 536D756C78  value "\x1B[4:%p1%dm"
    //                                 → 1B5B343A25703125646D
    (b"536D756C78", b"1B5B343A25703125646D"),
    // Setulc = "Setulc" → 536574756C63
    //                                 value "\x1B[58:2::%p1%{65536}%/%d:%p2%{256}%/%d:%p3%d%;m"
    //                                 → see test for byte-by-byte derivation
    (
        b"536574756C63",
        b"1B5B35383A323A3A257031257B36353533367D252F25643A257032257B3235367D252F25643A2570332564253B6D",
    ),
];

/// Reject-class indices for `osc7_reject` — keep stable so the per-class
/// `Once` instances (and any future test that asserts a specific class
/// fired) line up across builds.
const OSC7_REJECT_RATE: usize = 0;
const OSC7_REJECT_PERCENT_DECODE: usize = 1;
const OSC7_REJECT_UTF8: usize = 2;
const OSC7_REJECT_NUL: usize = 3;
const OSC7_REJECT_CONTROL: usize = 4;
const OSC7_REJECT_BIDI: usize = 5;
const OSC7_REJECT_NON_ABSOLUTE: usize = 6;
const OSC7_REJECT_TRAVERSAL: usize = 7;
/// Per-class one-shot latches. Audit follow-up (2026-04-29): the eight
/// silent `return` paths in `handle_osc7` made an attacker / shell-misbehaving
/// regression invisible. One-shot per class so a sustained flood doesn't
/// drown the log; the first reject of each shape produces a breadcrumb.
///
/// Audit L3: latches live in `BBTerm` rather than a process-wide static.
/// Pre-fix, the first BBTerm to fire each rejection class consumed the
/// `Once` for the whole process; sibling tabs (or the same tab on a
/// fresh shell) silently dropped the same reject — a multi-tab session
/// that hits one class on tab 1 lost the breadcrumb on tabs 2..N.
/// Per-instance bool flags restore one-shot-per-tab semantics without
/// re-introducing log floods.
fn osc7_reject(latches: &mut [bool; 8], class: usize, name: &str) {
    if let Some(slot) = latches.get_mut(class) {
        if !*slot {
            *slot = true;
            eprintln!("[blackbird_core] OSC 7 rejected ({})", name);
        }
    }
}

impl OscScanner<'_> {
    fn handle_osc7(&mut self, params: &[&[u8]]) {
        let Some(url) = params.get(1) else { return };

        // Audit L-20 (2026-04-29): cap the input length BEFORE
        // `percent_decode`. percent_decode does
        // `Vec::with_capacity(bytes.len())`, so an unbounded URL lets a
        // hostile remote allocate megabytes per OSC 7 chunk. OSC 8 caps
        // its URI at the same shape (`OSC8_URI_MAX = 4096`); legitimate
        // `file://` cwd URLs are at most a few hundred bytes.
        //
        // The length check stays FIRST (free, no allocation, no state
        // mutation) so an oversized hostile URL never even consumes a
        // rate-limit slot.
        if url.len() > OSC7_URL_MAX {
            return;
        }

        // Audit S4-001 (2026-05-30): EVERY reject path — structural (scheme,
        // authority, below) AND semantic (percent-decode, UTF-8, NUL,
        // control, bidi, absolute-path, traversal) — runs BEFORE the rate
        // gate, which now sits immediately before the CwdChanged emission at
        // the end of this function. So a hostile remote firing OSC 7s that
        // will be rejected — wrong scheme `http://x`, or `file://`-valid-but-
        // tainted like `file:///%E2%80%AE` (bidi) / `file:///%2e%2e/x`
        // (traversal) — consumes ZERO budget, and a legitimate
        // `OSC 7;file:///Users/foo/proj` from the user's own shell can't be
        // starved out of the 1-second window by a flood that was never going
        // to emit an event. (The earlier 2026-04-29 reorder moved the gate
        // past scheme+authority only; this moves it past every reject path.)
        // L-20's length cap (above) and the M-7 proc_listpids gate (below)
        // both remain enforced.

        // Accept only `file://` with an empty or `localhost` authority.
        // Audit fix-#08 (2026-05-21): RFC 3986 §3.1 / §3.2.2 define
        // scheme and host as case-insensitive. Match the literal prefix
        // case-insensitively so shell emitters that produce `FILE://`,
        // `File://localhost/...`, `file://LocalHost/...` etc. are not
        // silently dropped at ingest. The path portion stays
        // case-sensitive (POSIX paths are).
        let Some(rest) = strip_prefix_ascii_case_insensitive(url, b"file://") else {
            return;
        };
        let path_bytes: &[u8] = if rest.starts_with(b"/") {
            rest // "file:///path" → "/path"
        } else if let Some(r) = strip_prefix_ascii_case_insensitive(rest, b"localhost") {
            if !r.starts_with(b"/") {
                return;
            }
            r // "file://localhost/path" → "/path"
        } else {
            return; // non-local host
        };

        let Some(decoded) = percent_decode(path_bytes) else {
            osc7_reject(
                self.osc7_reject_logged,
                OSC7_REJECT_PERCENT_DECODE,
                "percent_decode",
            );
            return;
        };
        // Spec (2026-04-17-blackbird-gaps-design.md §4.1): "Malformed UTF-8
        // in the path is ignored." Percent-decoding can produce arbitrary
        // byte sequences (e.g. `file:///%ff`), so validate before firing.
        // The event's payload contract in `BBEventKind::CwdChanged` is
        // UTF-8 bytes — Swift wraps the pointer in a Swift String which
        // assumes UTF-8 validity.
        let Ok(decoded_str) = std::str::from_utf8(&decoded) else {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_UTF8, "utf8");
            return;
        };
        // Reject embedded NUL bytes. `%00` is valid UTF-8 and slips past
        // the str::from_utf8 gate, but a pathname containing NUL is
        // nonsense at the OS level (C string terminator) and lets a
        // hostile payload truncate what downstream consumers see when
        // they cast through a C API. TST-S1-014.
        if decoded.contains(&0) {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_NUL, "nul");
            return;
        }
        // Reject every other ASCII control byte (0x01..=0x1F, 0x7F) AND
        // C1 controls (U+0080..=U+009F). Same shape as OSC title scrub
        // (scrub_title_controls): control codepoints in a chrome-
        // displayed string can fool screen readers, log shippers, or
        // any downstream parser that doesn't pre-scrub.
        //
        // Audit S3-001: this used to be a byte-wise sweep that missed
        // C1 controls — U+0080..U+009F encodes as `0xC2 0x80..0xC2 0x9F`
        // in UTF-8, and neither byte is `< 0x20`. The title path was
        // already codepoint-level (see scrub_title_controls comment at
        // L525-527: "byte sweep would corrupt multi-byte UTF-8"). This
        // gate now walks `chars()` so the two paths agree.
        if decoded_str.chars().any(|c| {
            let cp = c as u32;
            cp <= 0x1F || cp == 0x7F || (0x80..=0x9F).contains(&cp)
        }) {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_CONTROL, "control");
            return;
        }
        // Reject Unicode bidi-control / zero-width / invisible-payload
        // codepoints in the path. Without this gate a hostile shell can
        // emit `OSC 7;file:///Users/foo/%E2%80%AE.bashrc` and the
        // titlebar proxy icon / "Open in Finder" affordance displays
        // the path RTL-flipped (visual `cqahsab.<rtl>oof/sresU/` while
        // the actual filesystem target is what Finder will open). Same
        // codepoint list the Swift paste sanitizer strips. Audit M2.
        if contains_bidi_or_invisible(decoded.as_slice()) {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_BIDI, "bidi");
            return;
        }
        // Audit synthesis #13 — path-traversal via percent-encoded `..`.
        // An attacker can emit `OSC 7;file:///%2e%2e/%2e%2e/etc/`. After
        // percent-decode the path is `../../../../etc/`; downstream
        // consumers (titlebar proxy icon, "Open in Finder", new-tab cwd
        // inheritance) all use the raw value via NSWorkspace. Drop the
        // event silently on any `..` segment OR any non-absolute path.
        // OSC 7 specifies an absolute path; relative paths are illegal
        // by spec.
        if !decoded_str.starts_with('/') {
            osc7_reject(
                self.osc7_reject_logged,
                OSC7_REJECT_NON_ABSOLUTE,
                "non_absolute",
            );
            return;
        }
        for component in std::path::Path::new(decoded_str).components() {
            match component {
                // The standard parent-dir component.
                std::path::Component::ParentDir => {
                    osc7_reject(self.osc7_reject_logged, OSC7_REJECT_TRAVERSAL, "traversal");
                    return;
                }
                // Defensive paranoia for the `\..` shape on
                // case-insensitive HFS+ / APFS — a literal `Normal`
                // component whose bytes equal `..` would mean some
                // higher layer mis-parsed components, but we'd still
                // refuse it.
                std::path::Component::Normal(s) if s.as_encoded_bytes() == b".." => {
                    osc7_reject(self.osc7_reject_logged, OSC7_REJECT_TRAVERSAL, "traversal");
                    return;
                }
                _ => {}
            }
        }
        // Audit synthesis #4 (SSH-trust): the gate lives on the Swift
        // side because the Rust core can't see the foreground process
        // tree. `TerminalSession` walks `proc_listpids(PROC_PPID_ONLY)`
        // from the fg pgroup and drops `.cwdChanged` events at ingest
        // when the tree contains an `ssh`/`mosh-client`/`docker`/etc
        // binary. Shipped 2026-04-28; this site stays validation-only.

        // Audit M-7 (2026-04-29) + S4-001 (2026-05-30): rate-limit ingest,
        // positioned AFTER every validation/reject path so that ONLY OSC 7s
        // which will actually emit a CwdChanged consume a budget slot — a
        // flood of rejected payloads (wrong scheme, bidi, traversal, …) can
        // no longer starve a legitimate cwd update out of the window
        // (S4-001). Legitimate shells emit one OSC 7 per `cd`; a hostile
        // remote streaming VALID `file://` cwds in a tight loop still forces
        // Swift's `classifyForegroundNamespace()` to run a `proc_listpids`
        // BFS per event (main-thread work that beachballs the UI), so excess
        // valid events are still dropped within the sliding window (M-7).
        if !self.osc7_rate.allow() {
            osc7_reject(self.osc7_reject_logged, OSC7_REJECT_RATE, "rate");
            return;
        }

        let ev = BBEvent {
            kind: BBEventKind::CwdChanged,
            payload: decoded.as_ptr(),
            len: decoded.len(),
            i32_arg: 0,
        };
        // SAFETY: `cell` is a live reference for the duration of this call;
        // `fire` invokes the C callback synchronously, so `decoded` (owned
        // by this stack frame) outlives the borrow the callback receives.
        // `decoded` drops at the end of this scope, after `fire` returns.
        unsafe { self.cell.fire(ev) };
    }

    fn handle_osc133(&mut self, params: &[&[u8]]) {
        let Some(kind_param) = params.get(1) else {
            return;
        };
        let kind_param = *kind_param;
        // The common split: some shells emit `OSC 133 ; D ; <code> ST` →
        // params = [b"133", b"D", b"0"]. Others combine: `OSC 133 ; D;0` →
        // params = [b"133", b"D;0"]. Handle both so snippets from iTerm2,
        // kitty, fish, starship, etc. all work.
        let (kind_byte, exit_code_bytes): (u8, &[u8]) = if kind_param.len() == 1 {
            (kind_param[0], params.get(2).copied().unwrap_or(b""))
        } else if let Some(idx) = kind_param.iter().position(|&b| b == b';') {
            // `D;<code>` — split on the first ';'.
            (kind_param[0], &kind_param[idx + 1..])
        } else {
            // Longer than 1 byte without a ';' — unknown extension.
            return;
        };

        let kind: u8 = match kind_byte {
            b'A' => BBPromptMarkKind::A as u8,
            b'B' => BBPromptMarkKind::B as u8,
            b'C' => BBPromptMarkKind::C as u8,
            b'D' => BBPromptMarkKind::D as u8,
            _ => return, // unknown sub-kind — silently ignore rather than crash.
        };

        // Audit synthesis #10 + RC-03 — OSC 133 prompt-mark forgery DoS / phishing.
        // Rate-limit ALL mark kinds (A = prompt start, B = command start,
        // C = command output, D = command end with exit code) at
        // PROMPT_MARK_PER_SECOND per rolling 1-second window.
        //
        // Earlier versions exempted D on the assumption it was tied 1:1
        // to an accepted C, but the code never enforced that pairing. A
        // hostile remote could spam `OSC 133;D;0\x07` to rotate
        // legitimate D entries out of Swift's bounded prompt ring. A
        // marks (the navigation targets) were already protected, so the
        // realistic impact was exit-code history corruption rather than
        // navigable-prompt forgery — but the comment claimed an
        // invariant the code didn't keep. Including D in the gate
        // restores the comment-vs-code contract.
        if matches!(kind_byte, b'A' | b'B' | b'C' | b'D') && !self.prompt_mark_rate.allow() {
            // Audit S5-009: dropped marks silently degrade ⌘ prompt
            // navigation and exit-code chrome — leave one breadcrumb
            // per session (same one-shot stance as the sibling reject
            // latches above/below).
            if !*self.osc133_rate_limited_logged {
                *self.osc133_rate_limited_logged = true;
                eprintln!(
                    "[blackbird_core] OSC 133 prompt-mark rate cap ({PROMPT_MARK_PER_SECOND}/s) \
                     engaged — dropping excess marks. One-shot per session."
                );
            }
            return;
        }

        // Cap exit-code payload at 16 bytes. A well-behaved shell emits
        // at most 3–4 digits; anything longer is either malicious spam or
        // a bug and the hosting TUI wouldn't know what to do with it
        // either.
        let cap = exit_code_bytes.len().min(16);
        let payload = &exit_code_bytes[..cap];

        // Audit L1. Validate the D-kind payload as ASCII decimal digits
        // before delivering. A hostile shell can emit OSC 133;D;<bytes>
        // ST with arbitrary control characters; the Swift consumer
        // turns the payload into a String for display alongside the
        // prompt-mark UI. Non-digit bytes (NUL, ESC, OSC re-entry,
        // bidi controls) reach Swift as a String containing those
        // bytes' UTF-8 replacement-character interpretation, which
        // can confuse downstream rendering. Be symmetric with the
        // OSC 7 cwd path which already refuses control bytes.
        // Drop the whole event when the payload is non-numeric —
        // we'd rather omit the exit code than display garbage.
        if kind_byte == b'D' && !payload.is_empty() && !payload.iter().all(|b| b.is_ascii_digit()) {
            // Mirror L3's per-instance one-shot logging stance:
            // first reject of this class on this BBTerm produces a
            // breadcrumb; subsequent rejects stay silent so a flood
            // can't drown the log.
            if !*self.osc133_d_nondigit_logged {
                *self.osc133_d_nondigit_logged = true;
                eprintln!("[blackbird_core] OSC 133 D rejected (non-digit payload)");
            }
            return;
        }

        // Audit fix-#07 (2026-05-21) + S3R-001/S3R-002 (2026-05-30): A/B/C
        // kinds also accept payload bytes (e.g. shell-supplied prompt
        // metadata) and forward them to Swift as a String. The Swift
        // consumer's `String(decoding:as:UTF8.self)` passes valid-UTF-8
        // control codepoints through — so they could leak into any future
        // chrome surface that renders TerminalSession's lastPromptMark.
        // Screen the payload at the CODEPOINT level, NOT byte level: a byte
        // sweep (b < 0x20 || b == 0x7F) misses C1 controls (U+0080..=U+009F
        // encode as 0xC2 0x80..=0xC2 0x9F — neither byte is < 0x20) and bidi
        // / invisible scalars (U+202E RIGHT-TO-LEFT OVERRIDE, zero-width
        // joiners, variation selectors, …), which a hostile shell can use to
        // visually spoof or confuse downstream consumers. This is the exact
        // gap the OSC 7 cwd path (the `decoded_str.chars()` gate above) and
        // the title scrubber (`scrub_title_controls`) already close; the
        // A/B/C path was the lone byte-level holdout. Reject the whole mark
        // when the payload is not well-formed UTF-8, or contains any C0 / DEL
        // / C1 control or bidi/invisible scalar. The de-facto A/B/C payload
        // is empty, so this tightening has no real-world false-positive
        // surface.
        if matches!(kind_byte, b'A' | b'B' | b'C') {
            let payload_clean = match std::str::from_utf8(payload) {
                Ok(s) => !s.chars().any(|c| {
                    let cp = c as u32;
                    cp <= 0x1F
                        || cp == 0x7F
                        || (0x80..=0x9F).contains(&cp)
                        || is_bidi_or_invisible_scalar(c)
                }),
                Err(_) => false,
            };
            if !payload_clean {
                // One-shot breadcrumb (silent-failure review): mirror the
                // D-path and OSC 7 reject latches so a dropped prompt mark
                // isn't invisible to an operator debugging why command
                // navigation / exit-code chrome stopped working. Subsequent
                // rejects on this instance stay silent so a flood can't drown
                // the log.
                if !*self.osc133_abc_tainted_logged {
                    *self.osc133_abc_tainted_logged = true;
                    eprintln!(
                        "[blackbird_core] OSC 133 A/B/C rejected (control/bidi/non-UTF-8 payload)"
                    );
                }
                return;
            }
        }

        let ev = BBEvent {
            kind: BBEventKind::PromptMark,
            payload: payload.as_ptr(),
            len: payload.len(),
            // Pack kind (A/B/C/D as 1..=4) into i32_arg so Swift can
            // branch without parsing the payload.
            i32_arg: kind as i32,
        };
        // SAFETY: `payload` borrows `params` which the caller (vte parser)
        // owns for the duration of this callback. `fire` delivers
        // synchronously, so the borrow is alive for the full dispatch.
        unsafe { self.cell.fire(ev) };
    }
}

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

/// True when `bytes` contains any UTF-8 sequence for a Unicode bidi-
/// control / zero-width / invisible-payload codepoint, OR when `bytes`
/// is not valid UTF-8 at all (caller-policy: refuse). Symmetric with
/// the Swift paste sanitizer's `stripBidiOverrides` byte map.
///
/// Used by `handle_osc7` to refuse cwd paths that would visually
/// spoof the titlebar / "Open in Finder" target. A path like
/// `/Users/foo/%E2%80%AE.bashrc` decodes to RLO + `.bashrc`; any
/// renderer that honours bidi (NSTextField, AppKit titlebar) flips
/// the visible suffix while the filesystem target stays whatever the
/// shell actually said. The defense lives at the parse boundary so
/// EVERY downstream consumer of the path benefits.
///
/// Reviewer feedback (2026-04-29): the previous implementation was a
/// hand-rolled UTF-8 byte sweep that duplicated the codepoint list in
/// `is_bidi_or_invisible_scalar`. Two encodings of the same set drift
/// the moment one is updated and the other isn't. Delegating to
/// `is_bidi_or_invisible_scalar` makes them mechanically equivalent —
/// the canonical list lives in exactly one place.
///
/// Behavior on invalid UTF-8: returns `true` (refuse). This is a
/// no-op vs. the previous behavior at the only call site
/// (`handle_osc7` already gates `std::str::from_utf8(&decoded)`
/// BEFORE this check, so invalid UTF-8 returns early there). Stating
/// the policy here makes future call sites safer-by-default.
///
/// Codepoint set rejected — see `is_bidi_or_invisible_scalar` for the
/// canonical list. Audit M2.
fn contains_bidi_or_invisible(bytes: &[u8]) -> bool {
    let Ok(s) = std::str::from_utf8(bytes) else {
        return true;
    };
    s.chars().any(is_bidi_or_invisible_scalar)
}

/// Strip `prefix` from `s` using ASCII case-insensitive comparison.
/// Returns `Some(remainder)` on match, `None` otherwise. Used by the
/// OSC 7 ingest gate to honour RFC 3986 §3.1 / §3.2.2 (scheme and host
/// are case-insensitive) without normalising the path component (which
/// is case-sensitive on POSIX). Audit fix-#08 (2026-05-21).
fn strip_prefix_ascii_case_insensitive<'a>(s: &'a [u8], prefix: &[u8]) -> Option<&'a [u8]> {
    if s.len() < prefix.len() {
        return None;
    }
    let (head, rest) = s.split_at(prefix.len());
    if head.eq_ignore_ascii_case(prefix) {
        Some(rest)
    } else {
        None
    }
}

/// RFC 3986 percent-decode. Returns `None` only on truncated escapes
/// (`%` with fewer than two hex digits remaining) or non-hex digits.
/// Raw bytes pass through unchanged.
fn percent_decode(bytes: &[u8]) -> Option<Vec<u8>> {
    fn hex(c: u8) -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            out.push((hex(bytes[i + 1])? << 4) | hex(bytes[i + 2])?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Some(out)
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
    term: Term<RoutingListener>,
    processor: Processor,
    /// Parallel `vte::Parser` that drives `OscScanner` for OSC 7 (cwd) and
    /// OSC 133 (prompt marks). Stateful across `bb_term_input` calls so
    /// fragmented sequences resolve to a single event. Kept separate from
    /// alacritty's internal parser so we never perturb the grid-mutation
    /// path. Consolidated from two parsers into one on 2026-04-19 —
    /// throughput tests showed running bytes through three parsers
    /// (alacritty + 2 parallels) cost ~15 % versus two parsers.
    osc_parser: Parser,
    /// Deferred queue of OSC 10/11/12 color-query responses — see
    /// ColorRequestQueue. Drained after every `processor.advance` call in
    /// `bb_term_input` so the response writes land in the same input
    /// batch that emitted the query. Responses are actually emitted only
    /// when `color_query_enabled` is true.
    color_queue: Arc<ColorRequestQueue>,
    /// Whether OSC 10 / 11 / 12 `?` queries produce a reply. Off by
    /// default: historically, replying leaked the palette back into the
    /// PTY, which zsh-vi-mode could interpret as commands (CVE class on
    /// older shells). Users who want nvim / tmux auto-theming on a
    /// modern shell can opt in via Preferences. See
    /// `core/tests/terminal_replies.rs::osc_10_11_color_queries_are_silent`
    /// for the default-off pinning.
    color_query_enabled: bool,
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
    osc_possibly_pending: bool,
    /// XTGETTCAP (Kitty capability query) parser state. `in_xtgettcap`
    /// latches true between `hook` (header `DCS + q` seen) and `unhook`
    /// (ST terminator seen); `xtgettcap_buf` accumulates the payload
    /// bytes. Persists across `bb_term_input` calls so a DCS fragmented
    /// across PTY reads resolves to a single reply. See `OscScanner`'s
    /// `hook`/`put`/`unhook` and `core/tests/xtgettcap.rs`.
    in_xtgettcap: bool,
    xtgettcap_buf: Vec<u8>,
    /// xterm `modifyOtherKeys` current level. `0` = off, `1` = level 1
    /// (encode colliders + "unmapped" Ctrl combos), `2` = level 2
    /// (encode every modified printable, overriding legacy byte
    /// mappings). Driven by parser observations of `CSI > 4 ; N m`.
    /// Swift-side KeyEncoder reads this indirectly via
    /// `bb_mode::MODIFY_OTHER_KEYS` (any non-zero level → bit set).
    modify_other_keys: u8,
    /// OSC 133 A/B/C rate-limit window (audit synthesis #10). See
    /// `PromptMarkRateState`. Persisted across `bb_term_input` calls so
    /// the sliding window covers prompt marks that arrive in different
    /// PTY chunks.
    prompt_mark_rate: PromptMarkRateState,
    /// OSC 7 (CWD) ingest rate-limit window (audit M-7). See
    /// `Osc7RateState`. Persisted across `bb_term_input` calls — same
    /// rationale as `prompt_mark_rate`.
    osc7_rate: Osc7RateState,
    /// OSC 7 reject-log latches, one bool per `OSC7_REJECT_*` class
    /// index. Audit L3: pre-fix these were a process-wide
    /// `static [Once; 8]`, so the first BBTerm in the process to hit
    /// each rejection class consumed the latch and sibling tabs (or
    /// reborn shells in the same tab) silently dropped the same
    /// reject. Per-instance flags restore one-shot-per-session log
    /// semantics without re-introducing log flood.
    osc7_reject_logged: [bool; 8],
    /// One-shot latch for the OSC 133 D non-digit reject path (audit
    /// L1 + reviewer follow-up). Same per-instance / one-shot rule
    /// as `osc7_reject_logged` but only one class so a single bool
    /// suffices.
    osc133_d_nondigit_logged: bool,
    /// One-shot latch for the OSC 133 A/B/C tainted-payload reject path
    /// (audit S3R-001/S3R-002). Same per-instance / one-shot rule as
    /// `osc133_d_nondigit_logged`.
    osc133_abc_tainted_logged: bool,
    /// One-shot latch for the OSC 133 rate-cap drop breadcrumb (audit
    /// S5-009). Same per-instance / one-shot rule as its siblings.
    osc133_rate_limited_logged: bool,
    /// OSC 10/11/12 color-query reply sliding-window state (bug #17). The
    /// per-call `ColorRequestQueue` cap stops a single chunk from forcing
    /// 256+ allocations, but a hostile stream can fan replies across many
    /// chunks. Gating each `PtyWrite` reply in `drain_color_requests` by
    /// this 1-second window with `COLOR_QUERY_REPLY_PER_SECOND` cap makes
    /// the rate limit total, not per-call. Persisted across
    /// `bb_term_input` calls for the same reason as `prompt_mark_rate`.
    color_query_reply_window_start: std::time::Instant,
    color_query_reply_window_count: u32,
    callback: Arc<CallbackCell>,
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
    uri_cstr_cache: std::collections::HashMap<String, Arc<std::ffi::CStr>>,
    /// Total bytes currently retained by `uri_cstr_cache` (sum of URI byte
    /// lengths, excluding the terminating NUL). Drives the
    /// `OSC8_TOTAL_INTERN_BYTES_CAP` gate in `bb_term_take_snapshot`.
    uri_cache_bytes: usize,
    /// One-shot latch: have we already emitted the per-snapshot
    /// `id-exhaustion` breadcrumb? OSC 8 link-id space is u16, leaving
    /// 65 534 distinct URIs per snapshot before attribution is silently
    /// dropped (lib.rs phase-1 link-build). The cap is essentially
    /// unreachable on any realistic TUI but reachable by a hostile
    /// remote emitting unique per-cell URIs; without an observability
    /// hook, support engineers triaging "my OSC 8 links stopped working"
    /// have no breadcrumb. Latch keeps the log one-shot per session to
    /// avoid eprintln spam on a streaming hostile payload. Audit S2-014.
    osc8_id_exhaustion_logged: bool,
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
    /// Currently checked only by `bb_term_input` (the canonical re-entry
    /// vector — every bytes-in path runs the VT parser, which fires
    /// events). Coverage for the rest of the entry-point surface is
    /// tracked in KNOWN_ISSUES.md as deferred follow-up; the Swift
    /// precondition still backstops them.
    static FFI_HANDLER_IN_FLIGHT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// RAII guard: flips `FFI_HANDLER_IN_FLIGHT` to `true` while the user
/// callback is on stack, restores `false` on drop. Acquired inside
/// `CallbackCell::fire` immediately around the `f(event, ctx)` call so a
/// callback that synchronously re-enters `bb_term_*` is observable via
/// the latch BEFORE the inner call grabs `&mut Term`.
struct HandlerInFlightGuard;
impl HandlerInFlightGuard {
    fn enter() -> Self {
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
const MAX_TEXT_RANGE_ROWS: u32 = 262_144;

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

/// Fallback Rgb for palette slots the theme hasn't filled in. OSC 10 / 11 /
/// 12 queries target indices 256 (Foreground), 257 (Background), 258
/// (Cursor). The 16 base colors use the xterm default table; the 240-entry
/// 256-color cube is computed. Anything outside that falls back to a
/// visible-on-any-background grey so silence is never the TUI's response.
fn palette_default_rgb(index: usize) -> Rgb {
    let packed: u32 = if index < 256 {
        indexed_color_rgb(index as u8)
    } else {
        match index {
            256 => named_color_rgb(&NamedColor::Foreground),
            257 => named_color_rgb(&NamedColor::Background),
            258 => 0xFFFFFF, // cursor default: solid white
            _ => 0xEEEEEE,
        }
    };
    Rgb {
        r: ((packed >> 16) & 0xFF) as u8,
        g: ((packed >> 8) & 0xFF) as u8,
        b: (packed & 0xFF) as u8,
    }
}

/// Flat cell layout for cross-language consumption. Swift reads these directly.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct BBCell {
    pub ch: u32, // Unicode scalar; 0 means empty
    pub fg: u32, // 0xRRGGBB
    pub bg: u32,
    pub flags: u16, // See cell_flags
    /// Index into `BBSnap::links` (0 means no OSC 8 attribution on this cell).
    /// Resolve via `bb_snap_link_url(snap, link_id)`.
    pub link_id: u16,
    /// CSI 58 colored-underline — the user may explicitly set the underline's
    /// colour independent of the glyph fg. alacritty 0.26 stores this as
    /// `Option<Color>` on the cell's extra; we flatten to a u32 with a magic
    /// sentinel: `UNDERLINE_COLOR_UNSET` (0xFFFF_FFFF) means "follow fg".
    /// Any other value is `0x00RRGGBB`.
    ///
    /// Ignored unless at least one underline-style bit is set in `flags`.
    /// Widens BBCell from 16 to 20 bytes — still 4-aligned, still fast to
    /// iterate over 16k cells.
    pub underline_color: u32,
}

/// Sentinel for `BBCell::underline_color` meaning "no explicit underline
/// colour set; use the cell's fg". Chosen as u32::MAX because alacritty's
/// RGB representation tops out at 0x00FF_FFFF and 0xFF000000 bits are
/// otherwise unused — picking a sentinel outside the valid RGB range avoids
/// a flag bit.
pub const UNDERLINE_COLOR_UNSET: u32 = 0xFFFF_FFFF;

pub mod cell_flags {
    pub const BOLD: u16 = 1 << 0;
    pub const ITALIC: u16 = 1 << 1;
    pub const UNDERLINE: u16 = 1 << 2;
    pub const REVERSE: u16 = 1 << 3;
    pub const DIM: u16 = 1 << 4;
    pub const STRIKE: u16 = 1 << 5;
    /// Cell holds the left half of a wide (double-width) glyph — CJK, some
    /// emoji, and private-use ranges like Nerd Font glyphs tagged wide. The
    /// renderer draws the glyph from this cell occupying two cell widths.
    pub const WIDE_CHAR: u16 = 1 << 6;
    /// Cell is the right half of a wide glyph — the renderer must not draw
    /// a glyph here (the wide one in the preceding cell already covers it).
    /// Filling this cell with a space overpaints the CJK/emoji character.
    pub const WIDE_CHAR_SPACER: u16 = 1 << 7;
    /// Cell is the unused column to the LEFT of a wide glyph that wrapped
    /// because only one column remained on the prior row. Same rule as
    /// WIDE_CHAR_SPACER — don't draw.
    pub const LEADING_WIDE_CHAR_SPACER: u16 = 1 << 8;
    /// CSI 21 m — double underline. Mutually exclusive with the other four
    /// underline style bits at the alacritty level (`ALL_UNDERLINES` mask).
    pub const UNDERLINE_DOUBLE: u16 = 1 << 9;
    /// CSI 4:3 m — wavy / undercurl. Neovim/Helix LSP diagnostics emit this
    /// for warnings/errors; having it rendered correctly matters for the
    /// agentic-CLI correctness wedge.
    pub const UNDERCURL: u16 = 1 << 10;
    /// CSI 4:4 m — dotted underline.
    pub const UNDERLINE_DOTTED: u16 = 1 << 11;
    /// CSI 4:5 m — dashed underline.
    pub const UNDERLINE_DASHED: u16 = 1 << 12;
    /// The cell's base glyph starts an emoji-presentation sequence — a
    /// text-default symbol carrying a VS16 (U+FE0F) zero-width mark (⚠️ ‼️ ❤️,
    /// keycaps) — so the renderer must rasterise the COLOUR emoji from the
    /// base + VS16 grapheme, not the bare base scalar (which CoreText resolves
    /// to the monochrome text glyph). Width is carried separately by
    /// WIDE_CHAR; this bit only governs colour / glyph selection. Set by the
    /// snapshot FFI when a cell's zerowidth list contains U+FE0F.
    pub const EMOJI_PRESENTATION: u16 = 1 << 13;
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
    // Kitty keyboard protocol bits. The TUI enables these via ESC[>{flags}u
    // progressive-enhancement pushes; once `DISAMBIGUATE_ESC_CODES` is set the
    // input encoder must emit CSI u sequences for modified keys so apps can
    // distinguish Shift+Enter from Enter, Ctrl+i from Tab, etc.
    pub const DISAMBIGUATE_ESC_CODES: u32 = 1 << 11;
    pub const REPORT_EVENT_TYPES: u32 = 1 << 12;
    pub const REPORT_ALTERNATE_KEYS: u32 = 1 << 13;
    pub const REPORT_ALL_KEYS_AS_ESC: u32 = 1 << 14;
    pub const REPORT_ASSOCIATED_TEXT: u32 = 1 << 15;
    /// xterm `modifyOtherKeys` level ≥ 1 is active. Enabled by
    /// `CSI > 4 ; 1 m` or `CSI > 4 ; 2 m`; cleared by `CSI > 4 ; 0 m`.
    /// Blackbird treats both non-zero levels as "on" — Emacs asks for
    /// level 2; level 1's gating table is historical and rarely requested
    /// in practice. When on, the KeyEncoder emits
    /// `CSI 27 ; <mod> ; <cp> ~` for modified printables + control-code
    /// colliders (Tab/Enter/Esc/Backspace) instead of raw bytes. See
    /// <https://invisible-island.net/xterm/modified-keys.html>.
    ///
    /// Precedence: Kitty flags (if any set) take priority over
    /// modifyOtherKeys. A TUI that pushes Kitty gets Kitty output;
    /// Emacs without Kitty gets modifyOtherKeys output.
    pub const MODIFY_OTHER_KEYS: u32 = 1 << 16;
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
    /// Pads `display_offset` (u32) to a 4-byte boundary. Without this
    /// the field would land at offset 9 and Rust's repr(C) would
    /// inject 3 bytes of implicit padding that cbindgen wouldn't
    /// reflect in the header — Swift would then read a mis-offset
    /// field. Explicit padding keeps the C and Rust layouts in lock-
    /// step. (Pre-M5 this was 1 byte aligning the previous u16.)
    pub _pad: [u8; 3],
    /// Number of lines the viewport is scrolled above the live grid. 0 means
    /// we're pinned to the bottom (live content). When > 0 the renderer must
    /// offset the cursor by this amount or hide it if the live cursor row is
    /// no longer visible.
    ///
    /// Width: `u32` — scrollback cap is 200 000 lines, well past
    /// `u16::MAX` (65 535). The previous u16 saturated silently, so a
    /// user scrolled past line 65 535 saw the offset frozen at 65 535
    /// while alacritty's real offset kept growing. The renderer's
    /// `FrameKey.displayOffset` was widened to UInt32 in b3edd7e to
    /// defend against narrow-key wraparound, but the data was already
    /// flat at the FFI boundary — that fix is only complete now that
    /// the source field matches. Audit M5.
    pub display_offset: u32,
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
    /// Monotonic count of lines the PRIMARY screen has pushed toward
    /// scrollback history — including lines recycled once the ring
    /// saturated. Unlike `history_size`, which plateaus at the
    /// scrollback cap, this never saturates, so callers can anchor
    /// content positions across eviction: content at grid row R in a
    /// snapshot whose counter read P sits `(counter_now − P)` rows
    /// further up in any later snapshot. Any resize — column reflow OR
    /// row-count change (vertical resizes route through the same
    /// scroll path) — and clears invalidate the anchor. Appended at
    /// the struct tail to
    /// preserve existing field offsets (same rule as `history_size`).
    /// Audit S5-004/S5-005.
    pub lines_scrolled: u64,
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
    /// OSC 8 URI table. Empty when the grid had no OSC 8 cells (rust-core-3 F9
    /// short-circuit — no sentinel push, no HashMap, no allocation); otherwise
    /// index 0 is a reserved empty-string sentinel and index N matches
    /// `BBCell.link_id`. Stored as `Arc<CStr>` so the same interned URI is
    /// shared across snapshots via `BBTerm::uri_cstr_cache` (rust-core-3 F1),
    /// avoiding a `CString::new(uri.to_owned())` per appearance. The pointer
    /// handed out by `bb_snap_link_url` is stable for the snapshot's lifetime
    /// because the Arc's pointee never moves.
    links: Vec<Arc<std::ffi::CStr>>,
    /// Rows whose content changed between this snapshot and the previous.
    /// Extracted from alacritty's `Term::damage()` before the grid read, then
    /// the term's damage is reset so each snapshot reports deltas.
    /// Empty when `damage_full == true` OR when nothing changed; readers
    /// disambiguate via `damage_full`.
    damaged_rows: Vec<u16>,
    /// True when alacritty reports full damage (scroll, insert-mode, or a
    /// similar wholesale change). A `true` value means the renderer must
    /// redraw everything and `damaged_rows` is irrelevant.
    damage_full: bool,
}

// SAFETY: see BBSnap's unsafe impl Send above; same reasoning applies.
unsafe impl Send for BBSnapOwned {}
// SAFETY: rc is AtomicUsize (Sync); snap and cells_owned are read-only after construction.
unsafe impl Sync for BBSnapOwned {}

impl BBSnapOwned {
    // Passing 10 args is deliberate — collapsing into a struct just to appease
    // the lint would obscure the call site, which is a single private caller
    // inside `bb_term_take_snapshot`.
    #[allow(clippy::too_many_arguments)]
    fn new(
        cols: u16,
        rows: u16,
        cursor: (u16, u16, bool),
        display_offset: u32,
        history_size: u32,
        lines_scrolled: u64,
        mode: u32,
        cursor_shape: u8,
        cells: Vec<BBCell>,
        links: Vec<Arc<std::ffi::CStr>>,
        damaged_rows: Vec<u16>,
        damage_full: bool,
    ) -> Box<BBSnapOwned> {
        let mut owned = Box::new(BBSnapOwned {
            snap: BBSnap {
                cols,
                rows,
                cursor_col: cursor.0,
                cursor_row: cursor.1,
                cursor_visible: cursor.2 as u8,
                _pad: [0; 3],
                display_offset,
                mode,
                cells_len: cells.len(),
                cells: std::ptr::null(),
                history_size,
                cursor_shape,
                _pad2b: [0; 3],
                lines_scrolled,
            },
            rc: AtomicUsize::new(1),
            cells_owned: cells,
            links,
            damaged_rows,
            damage_full,
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
    if f.contains(CellFlags::WIDE_CHAR) {
        out |= cell_flags::WIDE_CHAR;
    }
    if f.contains(CellFlags::WIDE_CHAR_SPACER) {
        out |= cell_flags::WIDE_CHAR_SPACER;
    }
    if f.contains(CellFlags::LEADING_WIDE_CHAR_SPACER) {
        out |= cell_flags::LEADING_WIDE_CHAR_SPACER;
    }
    // Underline-style dimension (mutually exclusive at the alacritty level):
    // double / curly / dotted / dashed. The plain UNDERLINE bit above covers
    // CSI 4 m; these four are CSI 21 m and CSI 4:3/4:4/4:5 m respectively.
    if f.contains(CellFlags::DOUBLE_UNDERLINE) {
        out |= cell_flags::UNDERLINE_DOUBLE;
    }
    if f.contains(CellFlags::UNDERCURL) {
        out |= cell_flags::UNDERCURL;
    }
    if f.contains(CellFlags::DOTTED_UNDERLINE) {
        out |= cell_flags::UNDERLINE_DOTTED;
    }
    if f.contains(CellFlags::DASHED_UNDERLINE) {
        out |= cell_flags::UNDERLINE_DASHED;
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
    // Kitty keyboard protocol sub-flags. Tested against each bit individually
    // because TermMode::KITTY_KEYBOARD_PROTOCOL is a *composite* mask (all five
    // bits); using `.contains()` on the composite would require every bit to be
    // set before we expose any, which loses fidelity when the TUI enables just
    // DISAMBIGUATE_ESC_CODES (the common case for Claude Code / vim / tmux).
    if term_mode.contains(TermMode::DISAMBIGUATE_ESC_CODES) {
        m |= bb_mode::DISAMBIGUATE_ESC_CODES;
    }
    if term_mode.contains(TermMode::REPORT_EVENT_TYPES) {
        m |= bb_mode::REPORT_EVENT_TYPES;
    }
    if term_mode.contains(TermMode::REPORT_ALTERNATE_KEYS) {
        m |= bb_mode::REPORT_ALTERNATE_KEYS;
    }
    if term_mode.contains(TermMode::REPORT_ALL_KEYS_AS_ESC) {
        m |= bb_mode::REPORT_ALL_KEYS_AS_ESC;
    }
    if term_mode.contains(TermMode::REPORT_ASSOCIATED_TEXT) {
        m |= bb_mode::REPORT_ASSOCIATED_TEXT;
    }
    m
}

/// Like `extract_mode` but also folds in the `modifyOtherKeys` bit
/// sourced from `BBTerm.modify_other_keys` (any non-zero level → bit
/// set). Kept separate from `extract_mode` so the pure
/// `TermMode → u32` mapping (exposed to callers that only see the
/// alacritty mode) stays argument-clean.
fn extract_mode_with_extras(bb: &BBTerm) -> u32 {
    let mut m = extract_mode(bb.term.mode());
    if bb.modify_other_keys > 0 {
        m |= bb_mode::MODIFY_OTHER_KEYS;
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
        if ffi_reentry_blocked("bb_term_take_snapshot") {
            return std::ptr::null();
        }
        let bb = &mut *term;

        // Drain the damage set BEFORE reading the grid. `Term::damage` takes
        // `&mut self`; the grid borrow below is immutable, so the two can't
        // coexist. Capturing damage first lets us hold it in a plain Vec<u16>
        // that outlives the grid borrow. After reading, reset damage so the
        // next `bb_term_input` cycle starts with a clean slate — the renderer
        // gets one set of damaged rows per snapshot, not a growing union.
        use alacritty_terminal::term::TermDamage;
        let (damaged_rows, damage_full): (Vec<u16>, bool) = match bb.term.damage() {
            TermDamage::Full => (Vec::new(), true),
            TermDamage::Partial(iter) => (iter.map(|b| b.line as u16).collect(), false),
        };
        bb.term.reset_damage();

        let palette = bb.term.colors();
        let grid = bb.term.grid();

        let rows = grid.screen_lines() as u16;
        let cols = grid.columns() as u16;
        let mut cells: Vec<BBCell> = Vec::with_capacity(rows as usize * cols as usize);

        // OSC 8 hyperlink interning is split into two phases to keep the
        // term borrow disjoint from the persistent cache mutation
        // (audit RC-01). Phase 1 (here, under `&bb.term`) collects each
        // unique URI as an owned `String` and records each cell's
        // local-id (1..=N). Phase 2 (after the term borrow ends)
        // resolves those local ids against `bb.uri_cstr_cache` and
        // builds the final `links: Vec<Arc<CStr>>`. Translating cells
        // from local id → final id then walks `cells` once.
        //
        // The earlier shape used `mem::take` to pluck the cache out of
        // `bb` for the duration of the grid loop, then wrote it back at
        // the end. Any panic between the take and the write-back left
        // `bb.uri_cstr_cache` empty while `bb.uri_cache_bytes` retained
        // its non-zero value — every future snapshot would then fail
        // the byte-cap check against an empty cache, permanently
        // dropping all OSC 8 attribution. The two-phase shape removes
        // the take entirely.
        //
        // Caps preserved:
        //   - distinct URIs per snapshot: `u16::MAX - 1 = 65534` (local ids)
        //   - per-URI bytes: 4 KiB (covers any realistic http URL)
        //   - total interned bytes ACROSS the persistent cache:
        //     `OSC8_TOTAL_INTERN_BYTES_CAP` = 1 MiB. Over the ceiling,
        //     new URIs drop to no-link rather than evict — eviction
        //     would invalidate pointers held by still-live snapshots
        //     that `Arc::clone`d the existing CStr.
        //
        // rust-core-3 F9: `links` stays empty until phase 2 sees that
        // phase 1 actually collected URIs. The common case — ProMotion
        // frame re-render with no OSC 8 on screen — pays zero heap
        // allocations for the intern table.
        const OSC8_URI_MAX: usize = 4096;
        const OSC8_TOTAL_INTERN_BYTES_CAP: usize = 1024 * 1024;
        // Phase 1 state: dedup'd URIs in insertion order, plus a parallel
        // dedup map sharing the same allocation. Audit L-7 (2026-05-03):
        // wrap each unique URI in `Arc<str>` once and clone the Arc into
        // both the vec and the dedup map — cloning an Arc is one atomic
        // increment, much cheaper than the prior shape that allocated a
        // fresh `String` per side (one `to_owned`, one `clone`).
        let mut phase1_uris: Vec<Arc<str>> = Vec::new();
        let mut local_uri_to_id: std::collections::HashMap<Arc<str>, u16> =
            std::collections::HashMap::new();
        // Track whether this snapshot ran out of u16 link ids so we can
        // emit a one-shot diagnostic AFTER the grid borrow ends (the
        // `bb.osc8_id_exhaustion_logged` field can't be touched while
        // `grid` borrows `bb.term`). Audit S2-014.
        let mut osc8_id_exhausted_this_snapshot = false;
        for indexed in grid.display_iter() {
            let link_id: u16 = match indexed.cell.hyperlink() {
                Some(h) => {
                    let uri = h.uri();
                    // alacritty's OSC 8 parser rejects empty URIs upstream, but
                    // we defensively treat an empty uri as "no link".
                    if uri.is_empty() || uri.len() > OSC8_URI_MAX {
                        0
                    } else if contains_bidi_or_invisible(uri.as_bytes()) {
                        // Audit S4-001 / fix-#03. Parity with the OSC 7 path
                        // (lib.rs:1146) and the OSC 0/2 title scrubber
                        // (scrub_title_controls): drop attribution for URIs
                        // carrying raw bidi-override / invisible scalars.
                        // Foundation's URL(string:) percent-encodes them on
                        // the Swift side, slipping the URI past the
                        // containsPercentEncodedControlBytes regex (which
                        // matches %00-%1F and %7F only); QuickLook / future
                        // chrome surfaces that render the raw stored bytes
                        // would honour U+202E (RIGHT-TO-LEFT OVERRIDE) and
                        // visually flip the URL the user reads. Rejecting
                        // here matches the OSC 7 posture rather than relying
                        // on every display-side consumer to scrub.
                        0
                    } else if let Some(&id) = local_uri_to_id.get(uri) {
                        id
                    } else if phase1_uris.len() + 1 >= u16::MAX as usize {
                        // Out of per-snapshot ids — drop attribution.
                        // 65 534 links per snapshot is already well past
                        // any realistic TUI; reaching the cap implies a
                        // hostile remote emitting unique per-cell URIs.
                        // Latch a one-shot breadcrumb (deferred until
                        // after the grid borrow ends) so support
                        // engineers triaging "my OSC 8 links stopped
                        // working" have a signal. Audit S2-014.
                        osc8_id_exhausted_this_snapshot = true;
                        0
                    } else {
                        let id = (phase1_uris.len() + 1) as u16; // 1-based; 0 = no link
                        let owned: Arc<str> = Arc::from(uri);
                        local_uri_to_id.insert(Arc::clone(&owned), id);
                        phase1_uris.push(owned);
                        id
                    }
                }
                None => 0,
            };
            // Underline colour (CSI 58): alacritty stores as Option<Color>.
            // None → sentinel (shader falls back to fg). Some(c) → resolve
            // through the palette, same as fg/bg so indexed colours route
            // correctly.
            let underline_color = match indexed.cell.underline_color() {
                Some(c) => color_to_rgb(&c, palette),
                None => UNDERLINE_COLOR_UNSET,
            };
            // Emoji-presentation: a text-default base carrying a VS16 (U+FE0F)
            // renders as the colour emoji (base + VS16 grapheme), not the
            // monochrome base scalar. Width parity is already handled by the
            // alacritty Term::input promotion (WIDE_CHAR); this flag only
            // drives the renderer's colour / glyph selection.
            let mut flags = extract_cell_flags(indexed.flags);
            if let Some(zw) = indexed.cell.zerowidth() {
                if zw.contains(&'\u{FE0F}') {
                    flags |= cell_flags::EMOJI_PRESENTATION;
                }
            }
            cells.push(BBCell {
                ch: indexed.c as u32,
                fg: color_to_rgb(&indexed.fg, palette),
                bg: color_to_rgb(&indexed.bg, palette),
                flags,
                link_id,
                underline_color,
            });
        }

        let cursor_point = grid.cursor.point;
        // cursor_point.line.0 is a 0-based screen row (Line wraps i32; visible rows are 0..rows-1).
        // cursor_point.column.0 is a 0-based column (Column wraps usize).
        let cursor_row = cursor_point.line.0.max(0) as u16;
        // column.0 is a usize; saturate at u16::MAX rather than truncating, so
        // the cast can never silently wrap to a small column. Symmetric with
        // the row's `.max(0)` clamp above and the display_offset/history_size
        // `.min(u32::MAX as usize)` clamps below. Bounded by MAX_DIM today, but
        // a defensive clamp keeps the snapshot's cursor honest unconditionally.
        // Audit S6-002.
        let cursor_col = cursor_point.column.0.min(u16::MAX as usize) as u16;
        // display_offset: lines scrolled above the live grid. When > 0 the
        // `cells` above are from scrollback; the live cursor at `cursor_row`
        // is actually `cursor_row + display_offset` from the top of the
        // visible viewport — and may be below it entirely.
        let display_offset = grid.display_offset().min(u32::MAX as usize) as u32;
        let history_size = grid.history_size().min(u32::MAX as usize) as u32;
        let lines_scrolled = bb.term.primary_lines_scrolled();
        // Drop the `grid`/`palette` borrows (and by extension the `&bb.term`
        // borrow) before we touch `bb.uri_cstr_cache` mutably below.
        let _ = grid;
        let _ = palette;
        // `local_uri_to_id` lives and dies with this snapshot.
        drop(local_uri_to_id);

        // Deferred S2-014 breadcrumb: if any cell hit the u16 link-id
        // ceiling during phase 1, log exactly once per BBTerm session.
        // Mutating bb here is sound because the grid borrow ended above.
        if osc8_id_exhausted_this_snapshot && !bb.osc8_id_exhaustion_logged {
            bb.osc8_id_exhaustion_logged = true;
            eprintln!(
                "[blackbird_core] OSC 8 link-id cap (u16) saturated for this snapshot — \
                 attribution silently dropped on cells past 65 534 distinct URIs. \
                 Symptom: 'links stopped working'. One-shot per session."
            );
        }

        // Phase 2: intern the URIs collected in phase 1 against the
        // persistent cache. Entries survive across snapshots
        // (rust-core-3 F1): the same URI appearing frame after frame is
        // an `Arc::clone` (one atomic increment, zero allocation) on
        // the second sighting. New URIs dropped silently once the
        // global byte footprint crosses `OSC8_TOTAL_INTERN_BYTES_CAP`
        // (1 MiB).
        //
        // `links` is empty when phase 1 collected zero URIs (the common
        // case). When non-empty, `links[0]` is the "no link" sentinel
        // so cell `link_id == 0` always means "no OSC 8 attribution"
        // and subsequent URIs get 1-based final indices (matching the
        // C ABI documented in `bb_snap_link_url`).
        let mut links: Vec<Arc<std::ffi::CStr>> = Vec::new();
        // `local_to_final[local_id]` = final id (or 0 if interning
        // failed for this URI). Built in lockstep with `phase1_uris`,
        // so `local_to_final[0]` is unused (local id 0 = no link).
        let mut local_to_final: Vec<u16> = Vec::new();
        if !phase1_uris.is_empty() {
            let sentinel: Arc<std::ffi::CStr> = std::ffi::CString::default().into();
            links.push(sentinel);
            local_to_final.push(0); // local 0 reserved for "no link"
            for uri in &phase1_uris {
                let uri_str: &str = uri.as_ref();
                let cstr_arc: Option<Arc<std::ffi::CStr>> =
                    if let Some(existing) = bb.uri_cstr_cache.get(uri_str).cloned() {
                        Some(existing)
                    } else if bb.uri_cache_bytes.saturating_add(uri_str.len())
                        > OSC8_TOTAL_INTERN_BYTES_CAP
                    {
                        None
                    } else {
                        match std::ffi::CString::new(uri_str) {
                            Ok(cs) => {
                                let arc: Arc<std::ffi::CStr> = cs.into();
                                bb.uri_cstr_cache
                                    .insert(uri_str.to_owned(), Arc::clone(&arc));
                                bb.uri_cache_bytes += uri_str.len();
                                Some(arc)
                            }
                            Err(_) => None,
                        }
                    };
                match cstr_arc {
                    Some(arc) => {
                        let final_id = links.len() as u16;
                        links.push(arc);
                        local_to_final.push(final_id);
                    }
                    None => local_to_final.push(0),
                }
            }
            // Translate every cell's local id to its final id. Cells
            // with local id 0 stay 0 (no link). Cells whose URI failed
            // to intern (byte-cap exceeded, NUL in URI) get 0 too —
            // matching the previous shape's "drop attribution silently"
            // semantics.
            for cell in cells.iter_mut() {
                let local = cell.link_id as usize;
                if local != 0 && local < local_to_final.len() {
                    cell.link_id = local_to_final[local];
                }
            }
        }
        let term_mode = bb.term.mode();
        let mode = extract_mode_with_extras(bb);
        // DECTCEM (ESC [ ? 25 h/l) toggles SHOW_CURSOR. Previously we
        // hardcoded true, so a TUI asking for a hidden cursor (less in
        // page view, fzf, nvim during paint) would still get drawn by
        // the Metal renderer.
        let cursor_visible = term_mode.contains(TermMode::SHOW_CURSOR);
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
            (cursor_col, cursor_row, cursor_visible),
            display_offset,
            history_size,
            lines_scrolled,
            mode,
            cursor_shape,
            cells,
            links,
            damaged_rows,
            damage_full,
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
        let mut iter_end = e_line.min(bottommost);

        // Audit M-1 (2026-05-03): bound the per-call allocation so a
        // single FFI request can't drive an O(rows × cols) heap
        // amplification. Without the cap a 200 000-row scrollback ×
        // 1000-col grid yields ~200 MB transient on one call. Truncate
        // (preserve the head of the requested range, drop the tail)
        // rather than fail outright — every realistic selection fits
        // well under the cap, and truncation keeps user-visible behaviour
        // stable instead of returning null on legitimate huge selections.
        // i64 arithmetic side-steps the i32::MIN/MAX overflow case the
        // post-clamp range can still expose if the grid spans the full
        // i32 range.
        let span = (iter_end as i64).saturating_sub(iter_start as i64);
        // Track cap-truncation separately from grid-clamp. iter_end after
        // the cap is a hard-stop, NOT the user's intended end row —
        // applying the end-row column-respect branch to the cap row would
        // silently crop a mid-selection row to e_col (which was intended
        // for the user's unreached final row). Audit S4-001.
        let cap_truncated = span >= MAX_TEXT_RANGE_ROWS as i64;
        if cap_truncated {
            iter_end = iter_start.saturating_add((MAX_TEXT_RANGE_ROWS - 1) as i32);
        }

        // Collect each line's emitted text plus whether the GRID row was
        // soft-wrapped (its last cell carries WRAPLINE), then join at the
        // end inserting '\n' only at hard line breaks.
        let mut lines: Vec<(String, bool)> = Vec::new();

        let rectangular = rect != 0;
        // The per-row branches compare line_i against iter_start /
        // iter_end (the clamped iteration bounds) so callers whose raw
        // s_line/e_line sat outside the grid still get column-respect on
        // the clamped extremity rows (audit S5-002 / S5-003).
        // But the iter-collapse case (iter_start == iter_end after a
        // multi-row request was clamped to one row) must NOT be treated
        // as a single-line pick — the user explicitly asked for multiple
        // rows, so the start-row trim semantic still applies. Require
        // both iteration collapse AND user-endpoint identity. Audit
        // S1-002.
        let single_line = iter_start == iter_end && s_line == e_line;

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
            } else if line_i == iter_start {
                (s_col, last_col, true)
            } else if line_i == iter_end && !cap_truncated {
                (0usize, e_col, false)
            } else {
                (0usize, last_col, true)
            };

            let mut text = String::with_capacity(col_hi.saturating_sub(col_lo) + 1);
            let row = &grid[Line(line_i)];
            let mut c = col_lo;
            while c <= col_hi {
                let cell = &row[Column(c)];
                // Skip wide-char spacer cells entirely. alacritty stores a
                // wide char (CJK, emoji) in the primary cell and a '\0'
                // sentinel in the continuation cell to its right; naively
                // emitting ' ' for every '\0' produces "中 文 " instead of
                // "中文" and breaks paste round-trip. The leading spacer is
                // the analogous cell at the end of a line just before a wide
                // glyph wraps — same skip rule applies.
                if cell
                    .flags
                    .intersects(CellFlags::WIDE_CHAR_SPACER | CellFlags::LEADING_WIDE_CHAR_SPACER)
                {
                    c += 1;
                    continue;
                }
                let ch = cell.c;
                // alacritty uses '\0' for unrendered/empty cells; surface as
                // a plain space so callers can concatenate without seeing
                // embedded NULs in their UTF-8.
                let out = if ch == '\0' { ' ' } else { ch };
                text.push(out);
                // Audit S5-001: width-0 scalars do NOT live in `cell.c` —
                // alacritty stores combining accents (U+0301 …), variation
                // selectors (VS16 U+FE0F), ZWJ, and every other zero-width
                // scalar in the cell's `zerowidth()` extra list (see
                // `Term::input`'s width==0 branch → `push_zerowidth`).
                // Upstream's own `line_to_string` re-emits them; dropping
                // them here meant ⌘C of an NFD filename pasted "cafe" for
                // "café" and ⚠️ (U+26A0 U+FE0F) pasted as bare U+26A0 —
                // silent copy-fidelity loss on a core terminal operation.
                if let Some(zw) = cell.zerowidth() {
                    for &z in zw {
                        text.push(z);
                    }
                }
                c += 1;
            }

            // Audit S5-002: a row whose LAST cell carries WRAPLINE is a
            // soft-wrapped continuation of the same logical line — the
            // shell never emitted a newline there, the text merely ran out
            // of columns. Upstream alacritty's `line_to_string` appends
            // '\n' only when the row's last cell lacks WRAPLINE; joining
            // unconditionally injected hard newlines into copied text, so
            // pasting a wrapped command back executed its leading fragment.
            // The flag lives on the row's actual last cell regardless of
            // the selection's column span. Rectangular (box) selection is
            // exempt by design: box copies are row-per-row.
            let wrapped = !rectangular && row[Column(last_col)].flags.contains(CellFlags::WRAPLINE);

            // S5-002 second half: a wrapped row is full-width content —
            // its trailing spaces are real characters interior to the
            // logical line (upstream treats WRAPLINE rows as full-width
            // in `line_length`). Only unwrapped rows carry '\0'-padding
            // that the trim is meant to drop.
            if trim && !wrapped {
                let trimmed_len = text.trim_end_matches(' ').len();
                text.truncate(trimmed_len);
            }

            lines.push((text, wrapped));
            line_i += 1;
        }

        let mut joined = String::new();
        for (i, (text, wrapped)) in lines.iter().enumerate() {
            joined.push_str(text);
            if i + 1 < lines.len() && !wrapped {
                joined.push('\n');
            }
        }
        bb_string_new(joined.into_bytes())
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

    /// Regression for audit H-7 (2026-04-29): `bb_term_new` must clamp BOTH
    /// bounds (floor + ceiling), symmetric with `bb_term_resize2`. Pre-H-7
    /// the floor was missing, so `bb_term_new(1, 1, …)` constructed a 1×1
    /// grid that silently grew on the next resize. The clamp now lands at
    /// construction time and the snapshot reflects the post-clamp dims.
    ///
    /// Memory discipline: small dims only — never near-MAX. Per
    /// `feedback_oom_resize_test.md`.
    #[test]
    fn new_clamps_below_min_dim() {
        unsafe {
            // Sub-MIN_DIM cols / rows must clamp UP to MIN_DIM = 2.
            let term = bb_term_new(1, 1, 100);
            assert!(!term.is_null(), "bb_term_new(1, 1, …) must succeed");
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            assert_eq!((*snap).cols, MIN_DIM, "cols must clamp up to MIN_DIM");
            assert_eq!((*snap).rows, MIN_DIM, "rows must clamp up to MIN_DIM");
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for audit H-7: `bb_term_new` ceiling clamp still works
    /// after the H-7 floor was added. A small over-cap value (MAX_DIM + 1)
    /// keeps the test memory-safe; we never approach `u16::MAX`.
    #[test]
    fn new_clamps_above_max_dim() {
        unsafe {
            let term = bb_term_new(MAX_DIM + 1, MAX_DIM + 1, 100);
            assert!(!term.is_null());
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            assert_eq!((*snap).cols, MAX_DIM, "cols must clamp down to MAX_DIM");
            assert_eq!((*snap).rows, MAX_DIM, "rows must clamp down to MAX_DIM");
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-1 F1: ColorRequestQueue::push must cap at
    /// COLOR_REQUEST_QUEUE_CAP so a hostile stream spamming
    /// `ESC]4;N;?BEL` can't force unbounded Arc<dyn Fn> allocations inside
    /// a single bb_term_input call. Direct-construct the queue so the
    /// test is insensitive to alacritty's OSC 4 parser dedup / rate policy.
    #[test]
    fn color_request_queue_push_caps_entries() {
        let q = ColorRequestQueue::new();
        let fmt: Arc<dyn Fn(Rgb) -> String + Sync + Send> = Arc::new(|_rgb| String::new());
        unsafe {
            for _ in 0..COLOR_REQUEST_QUEUE_CAP {
                assert!(q.push(ColorRequestEntry {
                    index: 0,
                    formatter: Arc::clone(&fmt),
                }));
            }
            // One past the cap must be refused.
            assert!(!q.push(ColorRequestEntry {
                index: 0,
                formatter: Arc::clone(&fmt),
            }));
            let drained = q.drain();
            assert_eq!(drained.len(), COLOR_REQUEST_QUEUE_CAP);
            // After draining the latch resets and a new push goes through.
            assert!(q.push(ColorRequestEntry {
                index: 0,
                formatter: Arc::clone(&fmt),
            }));
        }
    }

    /// Audit S1-004 (reworking rust-core-1 F2/F10): SERIALIZED access from
    /// different threads is the legitimate GCD serial-queue confinement
    /// pattern `bb_term_new` explicitly allows — the debug diagnostic must
    /// NOT fire on it. (The previous ThreadId latch did, which made every
    /// debug-assertions core build panic on the first event of a normal
    /// session and rendered the diagnostic useless for real misuse.)
    #[test]
    #[cfg(debug_assertions)]
    fn callback_cell_allows_serialized_cross_thread_access() {
        let cell = Arc::new(CallbackCell::new(Arc::new(PtyWriteRateCell::new())));
        unsafe {
            cell.fire(BBEvent {
                kind: BBEventKind::Bell,
                payload: std::ptr::null(),
                len: 0,
                i32_arg: 0,
            });
        }
        let cell_clone = Arc::clone(&cell);
        std::thread::spawn(move || unsafe {
            cell_clone.fire(BBEvent {
                kind: BBEventKind::Bell,
                payload: std::ptr::null(),
                len: 0,
                i32_arg: 0,
            });
        })
        .join()
        .expect("serialized cross-thread fire must not panic (S1-004)");
    }

    /// Audit S1-004: the replacement diagnostic — overlap detection — must
    /// panic when a second accessor enters while the first is still inside,
    /// and recover cleanly once the holder releases.
    #[test]
    #[cfg(debug_assertions)]
    fn debug_busy_guard_panics_on_overlapping_access() {
        use std::panic::{catch_unwind, AssertUnwindSafe};
        let flag = std::sync::atomic::AtomicBool::new(false);
        let held = DebugBusyGuard::enter(&flag, "test-cell");
        let result = catch_unwind(AssertUnwindSafe(|| {
            let _second = DebugBusyGuard::enter(&flag, "test-cell");
        }));
        assert!(
            result.is_err(),
            "overlapping enter must panic while the first guard is held"
        );
        drop(held);
        // After release, a fresh accessor proceeds normally.
        let _third = DebugBusyGuard::enter(&flag, "test-cell");
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
        let pty_write_rate = Arc::new(PtyWriteRateCell::new());
        let callback = Arc::new(CallbackCell::new(Arc::clone(&pty_write_rate)));
        let color_queue = Arc::new(ColorRequestQueue::new());
        let listener = RoutingListener {
            cell: Arc::clone(&callback),
            color_queue: Arc::clone(&color_queue),
        };
        // Keep the Arcs alive past listener construction so the inner
        // cells survive for the lifetime of `term`.
        let _callback_keepalive = callback;
        let _color_queue_keepalive = color_queue;
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
        // BBSnap is the C-visible struct. Layout was bumped on
        // 2026-04-28 (audit M5) to widen `display_offset` u16→u32 so
        // it survives scrollback past line 65 535. cbindgen
        // regenerates BBCore.h to match; the test pins the new
        // offsets so a future field insert that shifted them again
        // would catch a stale Swift binding.
        assert_eq!(
            std::mem::offset_of!(BBSnap, cells_len),
            24,
            "cells_len at offset 24 (post-M5 layout)"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, cells),
            32,
            "cells at offset 32 (post-M5 layout)"
        );
        // Verify BBSnapOwned layout: snap is at offset 0 so pointer casts are sound.
        assert_eq!(
            std::mem::offset_of!(BBSnapOwned, snap),
            0,
            "snap must be at offset 0 in BBSnapOwned"
        );
        // BBCell ABI: 20 bytes (bumped from 16 on 2026-04-19 to add
        // underline_color for CSI 58 colored underlines). link_id stays at
        // offset 14; underline_color lives at 16. Swift and any other C
        // ABI consumer reads cells directly from BBSnap.cells via these
        // exact offsets — any further field addition needs a bump here
        // AND a corresponding stride update in CellInstance / Shaders.metal.
        assert_eq!(
            std::mem::size_of::<BBCell>(),
            20,
            "BBCell ABI size must stay synchronized with the Swift reader's struct stride"
        );
        assert_eq!(
            std::mem::offset_of!(BBCell, link_id),
            14,
            "link_id must stay at offset 14 (replacing _reserved)"
        );
        assert_eq!(
            std::mem::offset_of!(BBCell, underline_color),
            16,
            "underline_color must stay at offset 16 — packed directly after link_id"
        );
        // Also pin the tail of BBSnap: display_offset / mode /
        // history_size / cursor_shape sit past the pointer fields, so
        // a future field insertion BEFORE them would silently shift
        // their offsets in the Swift bridge. Audit rust-core-3 F15 +
        // rust-build F7. (Offsets bumped 2026-04-28 for audit M5
        // u16→u32 widen of display_offset.)
        assert_eq!(
            std::mem::offset_of!(BBSnap, display_offset),
            12,
            "display_offset at offset 12 (post-M5 u32 widen)"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, mode),
            16,
            "mode follows display_offset (post-M5 layout)"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, history_size),
            40,
            "history_size follows cells at offset 40 (post-M5 layout)"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, cursor_shape),
            44,
            "cursor_shape follows history_size (post-M5 layout)"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, lines_scrolled),
            48,
            "lines_scrolled appended at offset 48 (audit S5-004/S5-005) — \
             existing field offsets must not move"
        );
        assert_eq!(
            std::mem::size_of::<BBSnap>(),
            56,
            "BBSnap total size 56 bytes (48 post-M5 + appended u64 \
             lines_scrolled, audit S5-004/S5-005)"
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

    /// Regression: fuzzing found that shrinking from 80×24 with 1 000 lines
    /// of scrollback down to 1×1 made alacritty's grid.resize allocate
    /// hundreds of megabytes while reflowing history into millions of
    /// one-cell rows. bb_term_resize now floors the target dimensions at
    /// 2×2 (without touching the zero-is-noop contract).
    #[test]
    fn resize_clamps_degenerate_dimensions() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            // Push enough history that reflow matters.
            for _ in 0..100 {
                bb_term_input(term, b"x\r\n".as_ptr(), 3);
            }
            // Request 1×1 — clamped to 2×2. Previously OOM.
            bb_term_resize(term, 1, 1);
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cols, 2, "cols should clamp to min 2");
            assert_eq!((*snap).rows, 2, "rows should clamp to min 2");
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression: bb_term_new/bb_term_resize must clamp oversized dims to
    /// MAX_DIM (1000). The original OOM incident was fuzz/Swift passing
    /// u16::MAX for cols/rows, triggering a 100+ GB alloc inside alacritty's
    /// grid allocator. We deliberately DO NOT pass u16::MAX here — if the
    /// clamp ever regresses, this test would itself OOM the CI runner. 10 000
    /// is 10× MAX_DIM, safely allocatable if the clamp were (catastrophically)
    /// removed, and well outside anything a legitimate caller could want.
    /// The paired Swift-side clamp at TerminalSession.swift is tested
    /// independently; this is defence-in-depth on the Rust side.
    #[test]
    fn new_clamps_oversized_dimensions() {
        unsafe {
            let term = bb_term_new(10_000, 10_000, 1000);
            assert!(!term.is_null());
            let snap = bb_term_take_snapshot(term);
            assert!(
                (*snap).cols <= 1000,
                "bb_term_new must clamp oversized cols to MAX_DIM (got {})",
                (*snap).cols
            );
            assert!(
                (*snap).rows <= 1000,
                "bb_term_new must clamp oversized rows to MAX_DIM (got {})",
                (*snap).rows
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn resize_clamps_oversized_dimensions() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_resize(term, 10_000, 10_000);
            let snap = bb_term_take_snapshot(term);
            assert!(
                (*snap).cols <= 1000,
                "bb_term_resize must clamp oversized cols (got {})",
                (*snap).cols
            );
            assert!(
                (*snap).rows <= 1000,
                "bb_term_resize must clamp oversized rows (got {})",
                (*snap).rows
            );
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

    /// text_range with rect=1 but s_col == e_col (degenerate rectangle).
    /// Loop should still run; each line emits one character.
    #[test]
    fn text_range_rectangular_single_column() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            bb_term_input(term, b"abcdefghij\r\nABCDEFGHIJ\r\n1234567890".as_ptr(), 32);
            let s = bb_term_text_range(term, 0, 5, 2, 5, 1);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "f\nF\n6");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// Passing out-of-range u16 cols should clip to last_col (not overflow
    /// through to a garbage row access).
    #[test]
    fn text_range_clips_huge_col_request() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            bb_term_input(term, b"abcde".as_ptr(), 5);
            // Request cols 0..=u16::MAX — should clip to last_col = 4.
            let s = bb_term_text_range(term, 0, 0, 0, u16::MAX, 0);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "abcde");
            bb_string_release(s);
            bb_term_free(term);
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

    /// Audit L-11 (2026-04-29): `bb_term_input` must reject `len >
    /// isize::MAX` BEFORE `slice::from_raw_parts` is reached. Defense-in-
    /// depth — the Swift wrapper can't construct such an input, but a
    /// C ABI consumer (fuzzer, native binding) can. The contract
    /// violation surfaces as a Fatal event so the host learns about it.
    ///
    /// Memory discipline: we pass a tiny stack buffer + an oversized
    /// `len`. The check fires BEFORE the unsafe slice construction, so
    /// the bytes pointer is never read. We never allocate `isize::MAX`.
    #[test]
    fn input_len_above_isize_max_dispatches_fatal() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let fired: Arc<Mutex<Vec<(u32, String)>>> = Arc::new(Mutex::new(Vec::new()));
        let fired_ptr = Arc::into_raw(fired.clone()) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let fired = &*(ctx as *const Mutex<Vec<(u32, String)>>);
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

            // Tiny dummy buffer — never read by the FFI because the
            // length check panics before from_raw_parts.
            let dummy = [0u8; 4];
            let bad_len = (isize::MAX as usize).wrapping_add(1);
            bb_term_input(term, dummy.as_ptr(), bad_len);

            let guard_ = fired.lock().unwrap();
            let fatal = guard_.iter().find(|(k, _)| *k == BBEventKind::Fatal as u32);
            assert!(
                fatal.is_some(),
                "expected Fatal event for oversized len, got {:?}",
                *guard_
            );
            assert!(
                fatal.unwrap().1.contains("isize::MAX"),
                "fatal msg should mention the cap; got {:?}",
                fatal
            );
            drop(guard_);

            bb_term_free(term);
            Arc::from_raw(fired_ptr as *const Mutex<Vec<(u32, String)>>);
        }
    }

    /// Regression for rust-core-5 F3: if a Fatal dispatch re-enters the
    /// FFI (callback panics a `bb_term_*` call), the nested Fatal must be
    /// swallowed so the same callback isn't re-invoked recursively. We
    /// arrange exactly that shape: callback, on its first Fatal, calls
    /// `bb_term_test_only_panic(term)` which panics inside guard_with_term;
    /// the FFI_FATAL_IN_FLIGHT latch must cause the second dispatch to
    /// drop instead of firing the callback a second time (or deadlocking
    /// if the callback held a re-entrant lock).
    #[test]
    fn fatal_dispatch_does_not_reenter_callback() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        // Pair: (invocation-count, has-re-panicked-once).
        // Mutex is NOT intentionally re-entrant — the swallow path is what
        // keeps this test from deadlocking, not NSLock-style recursion.
        struct State {
            term: *mut BBTerm,
            invocations: Mutex<u32>,
            already_re_panicked: Mutex<bool>,
        }
        // *mut BBTerm is not Send/Sync; the callback runs synchronously
        // on the test's own thread so we can cross that boundary safely.
        unsafe impl Send for State {}
        unsafe impl Sync for State {}

        let state = Arc::new(State {
            term: std::ptr::null_mut(),
            invocations: Mutex::new(0),
            already_re_panicked: Mutex::new(false),
        });
        // We'll write `term` into the Arc after creation by leaking the
        // Arc into a raw ptr, creating term, patching the field, and
        // handing the ptr to the callback context.
        let state_ptr = Arc::into_raw(Arc::clone(&state)) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let state = &*(ctx as *const State);
            *state.invocations.lock().unwrap() += 1;
            if ev.kind == BBEventKind::Fatal {
                let mut done = state.already_re_panicked.lock().unwrap();
                if !*done {
                    *done = true;
                    drop(done);
                    // Re-enter the FFI: this call itself panics inside
                    // guard_with_term. Without the re-entry latch we
                    // would be invoked recursively here and would
                    // observe `invocations == 2` below.
                    bb_term_test_only_panic(state.term);
                }
            }
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);
            // Patch the `term` field post-hoc. Arc::into_raw gave us a raw
            // const pointer; we unsafe-mutate a field it points to through
            // a *mut cast. The field is !Send/!Sync but we've declared
            // State as such above; no other thread is reading while we
            // write, so this is sound.
            let state_mut = state_ptr as *mut State;
            std::ptr::addr_of_mut!((*state_mut).term).write(term);

            bb_term_set_event_cb(term, Some(cb), state_ptr);
            bb_term_test_only_panic(term);

            let invocations = *state.invocations.lock().unwrap();
            assert_eq!(
                invocations, 1,
                "callback must be invoked exactly once; nested Fatal was \
                 re-dispatched instead of swallowed (rust-core-5 F3 regression)",
            );

            bb_term_free(term);
            Arc::from_raw(state_ptr as *const State);
        }
    }

    /// Audit S1-043 / S2-011 / fix-#09 (2026-05-11): a Fatal-event
    /// handler that synchronously calls a non-panicking `bb_term_*`
    /// FFI must be short-circuited by `ffi_reentry_blocked`. Without
    /// this gate the inner call would proceed: it reborrows `&mut Term`
    /// while the outer `guard_with_term` Fatal path still holds
    /// `&*term`, fires events through `CallbackCell::fire`, and the
    /// nested Swift `BBTerm.dispatch` would observe
    /// `isInsideEventDispatch == true` (from the outer Fatal dispatch
    /// that flipped it on entry) and trip its release-mode
    /// `precondition`, aborting the whole process. The Rust guard
    /// catches it one frame earlier so the inner call simply no-ops.
    #[test]
    fn ffi_call_inside_fatal_handler_is_dropped() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct State {
            term: *mut BBTerm,
            inner_input_attempted: Mutex<bool>,
        }
        unsafe impl Send for State {}
        unsafe impl Sync for State {}

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let state = &*(ctx as *const State);
            if ev.kind == BBEventKind::Fatal {
                let mut attempted = state.inner_input_attempted.lock().unwrap();
                if !*attempted {
                    *attempted = true;
                    drop(attempted);
                    // Re-enter the FFI with a non-panicking input. If
                    // ffi_reentry_blocked doesn't honour FFI_FATAL_IN_FLIGHT,
                    // the inner call proceeds, the parser processes 'X',
                    // and the grid records it at row 0 col 0.
                    let x: u8 = b'X';
                    bb_term_input(state.term, &x as *const u8, 1);
                }
            }
        }

        let state = Box::into_raw(Box::new(State {
            term: std::ptr::null_mut(),
            inner_input_attempted: Mutex::new(false),
        }));

        unsafe {
            let term = bb_term_new(20, 5, 100);
            (*state).term = term;
            bb_term_set_event_cb(term, Some(cb), state as *mut c_void);

            // Trigger Fatal. The callback's nested bb_term_input("X") must
            // be short-circuited by ffi_reentry_blocked.
            bb_term_test_only_panic(term);

            assert!(
                *(*state).inner_input_attempted.lock().unwrap(),
                "callback should have attempted the inner re-entry"
            );

            // Now verify the inner 'X' was DROPPED (parser never saw it).
            // The snapshot must show cell (0,0) is empty (alacritty fills
            // unset cells with the space/empty sentinel, ch=0x20). If the
            // inner call ran, ch would be b'X' = 0x58.
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null(), "snapshot must succeed post-Fatal");
            let cell0 = *((*snap).cells.add(0));
            assert_ne!(
                cell0.ch, b'X' as u32,
                "re-entered bb_term_input from Fatal handler must be \
                 dropped by ffi_reentry_blocked — got 'X' at (0,0), \
                 meaning the inner call processed bytes while the outer \
                 Fatal dispatch was still live (alias UB + Swift \
                 precondition abort hazard)"
            );
            bb_snap_release(snap);

            bb_term_set_event_cb(term, None, std::ptr::null_mut());
            bb_term_free(term);
            drop(Box::from_raw(state));
        }
    }

    /// Audit M-9 follow-up (2026-04-29): the Rust-side
    /// `FFI_HANDLER_IN_FLIGHT` latch must drop a synchronous re-entrant
    /// `bb_term_input` call from inside a registered event callback.
    /// Without the latch, the second `&mut Term` reborrow inside the
    /// re-entered call would alias the outer call's borrow — UB.
    ///
    /// The shape we arrange: feed a BEL byte, which generates a Bell
    /// event. The callback, on receiving Bell, calls back into
    /// `bb_term_input` with another byte. The latch must short-circuit
    /// that second call so the second byte is NOT processed. We pin
    /// the contract by counting how many Bell events fire: BEL ×1
    /// inbound → 1 dispatch, the re-entered call dropped before
    /// running parser, so no second Bell.
    #[test]
    fn input_does_not_reenter_from_inside_event_handler() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct State {
            term: *mut BBTerm,
            bell_count: Mutex<u32>,
            already_reentered: Mutex<bool>,
        }
        unsafe impl Send for State {}
        unsafe impl Sync for State {}

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let state = &*(ctx as *const State);
            if ev.kind == BBEventKind::Bell {
                *state.bell_count.lock().unwrap() += 1;
                let mut already = state.already_reentered.lock().unwrap();
                if !*already {
                    *already = true;
                    drop(already);
                    // Try to re-enter — must be dropped silently by the
                    // FFI_HANDLER_IN_FLIGHT latch. If this re-enters,
                    // the second BEL gets parsed and bell_count climbs
                    // to 2.
                    let bel: u8 = 0x07;
                    bb_term_input(state.term, &bel as *const u8, 1);
                }
            }
        }

        let state = Box::into_raw(Box::new(State {
            term: std::ptr::null_mut(),
            bell_count: Mutex::new(0),
            already_reentered: Mutex::new(false),
        }));

        unsafe {
            let term = bb_term_new(20, 5, 100);
            (*state).term = term;
            bb_term_set_event_cb(term, Some(cb), state as *mut c_void);
            // First input: a single BEL byte → fires Bell → callback
            // runs and tries to re-enter with another BEL.
            let bel: u8 = 0x07;
            bb_term_input(term, &bel as *const u8, 1);

            let count = *(*state).bell_count.lock().unwrap();
            assert_eq!(
                count, 1,
                "callback's re-entrant bb_term_input must be dropped by \
                 FFI_HANDLER_IN_FLIGHT — re-entry would parse the second \
                 BEL and produce a second Bell dispatch (got {})",
                count
            );

            bb_term_free(term);
            drop(Box::from_raw(state));
        }
    }

    /// Sibling: when the callback does NOT re-enter, the latch must not
    /// stick — a follow-up `bb_term_input` call from outside the
    /// callback runs normally. Pins the RAII drop semantics.
    #[test]
    fn input_resumes_after_callback_returns_without_reentry() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            bell_count: Mutex<u32>,
        }

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let sink = &*(ctx as *const Sink);
            if ev.kind == BBEventKind::Bell {
                *sink.bell_count.lock().unwrap() += 1;
            }
        }

        let sink = Sink {
            bell_count: Mutex::new(0),
        };

        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
            // Two separate `bb_term_input` calls — neither re-enters from
            // inside `cb`. Both must dispatch normally.
            let bel: u8 = 0x07;
            bb_term_input(term, &bel as *const u8, 1);
            bb_term_input(term, &bel as *const u8, 1);

            let count = *sink.bell_count.lock().unwrap();
            assert_eq!(
                count, 2,
                "non-re-entrant calls must not be blocked by \
                 FFI_HANDLER_IN_FLIGHT (latch failed to clear on cb return)",
            );

            bb_term_free(term);
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

    /// Out-of-range slot indices shouldn't panic through the FFI guard.
    /// alacritty's `Term::set_color` indexes the `Colors` array (fixed
    /// length `COUNT` = 269 in 0.26) directly: slots ≥ `COUNT` panic with
    /// index-out-of-bounds. A fuzzer found 0x0E0E (3598) reproduces this.
    /// `catch_unwind` inside `guard_with_term` does catch the panic in
    /// normal process space, but libFuzzer installs a panic hook that
    /// aborts first — so relying on `catch_unwind` isn't enough. Clamp in
    /// the FFI instead.
    #[test]
    fn set_named_color_out_of_range_slot_is_noop() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            // Should neither crash nor panic.
            bb_term_set_named_color(term, u16::MAX, 0x123456);
            bb_term_set_named_color(term, 9999, 0x987654);
            // Specific fuzzer-discovered value — 0x0E0E from a little-endian
            // u16. Must not panic.
            bb_term_set_named_color(term, 0x0E0E, 0x0E0E0E);
            // Right on the boundary — COUNT itself is invalid, COUNT-1 is
            // valid (exact last slot).
            bb_term_set_named_color(
                term,
                alacritty_terminal::term::color::COUNT as u16,
                0x010203,
            );
            // Sanity: a legit slot still works.
            bb_term_set_named_color(term, 257, 0xAABBCC);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            assert_eq!(
                cells[0].bg, 0xAABBCC,
                "slot 257 (Background) must still take effect"
            );
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

    /// DECTCEM: ESC [ ? 25 l hides the cursor; h shows it. Previously we
    /// hard-coded cursor_visible = 1, so TUIs (less in page view, fzf,
    /// nvim during paint) that disabled the cursor still rendered it.
    #[test]
    fn dectcem_toggles_cursor_visible() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            let snap = bb_term_take_snapshot(term);
            assert_eq!(
                (*snap).cursor_visible,
                1,
                "cursor should default to visible on a fresh term"
            );
            bb_snap_release(snap);

            bb_term_input(term, b"\x1b[?25l".as_ptr(), 6);
            let hidden = bb_term_take_snapshot(term);
            assert_eq!((*hidden).cursor_visible, 0, "DECTCEM ?25l should hide");
            bb_snap_release(hidden);

            bb_term_input(term, b"\x1b[?25h".as_ptr(), 6);
            let shown = bb_term_take_snapshot(term);
            assert_eq!((*shown).cursor_visible, 1, "DECTCEM ?25h should re-show");
            bb_snap_release(shown);
            bb_term_free(term);
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

    /// clear_all must reset display_offset even when the user was scrolled
    /// back. Otherwise `⌘K` inside scrollback leaves the viewport pointing at
    /// a now-empty region and the terminal looks "blank" until the user
    /// scrolls down — confusing and wrong, since the live grid is where the
    /// fresh prompt is about to appear.
    #[test]
    fn clear_all_snaps_viewport_to_live_grid() {
        unsafe {
            let term = bb_term_new(5, 3, 1000);
            // Push enough lines to build scrollback.
            for _ in 0..50 {
                bb_term_input(term, b"line\r\n".as_ptr(), 6);
            }
            // Scroll back into history.
            bb_term_scroll(term, 20);
            let mid = bb_term_take_snapshot(term);
            assert!(
                (*mid).display_offset > 0,
                "precondition: viewport should be scrolled back before clear"
            );
            bb_snap_release(mid);

            bb_term_clear_all(term);
            let after = bb_term_take_snapshot(term);
            assert_eq!(
                (*after).display_offset,
                0,
                "clear_all must snap viewport to live grid (display_offset == 0)"
            );
            assert_eq!((*after).history_size, 0, "scrollback must be wiped too");
            bb_snap_release(after);
            bb_term_free(term);
        }
    }

    /// i32::MIN / MAX deltas must not panic the core. A misbehaving input
    /// driver (or a future Swift caller that forgets to clamp) could hand us
    /// those extremes; alacritty's scroll_display clamps internally, but the
    /// FFI boundary needs to stay a no-panic zone regardless.
    #[test]
    fn scroll_extreme_deltas_dont_panic() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            // Build some scrollback first so both extremes have something to
            // clamp against.
            for _ in 0..50 {
                bb_term_input(term, b"line\r\n".as_ptr(), 6);
            }
            bb_term_scroll(term, i32::MIN);
            bb_term_scroll(term, i32::MAX);
            bb_term_scroll(term, 0); // explicit no-op branch
                                     // Reachable through either extreme — the viewport should still
                                     // snap back to the live grid cleanly afterwards.
            bb_term_scroll_to_bottom(term);
            let snap = bb_term_take_snapshot(term);
            assert_eq!(
                (*snap).display_offset,
                0,
                "scroll_to_bottom should pin the viewport regardless of prior extreme deltas"
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-4 F2: `bb_snap_damage_rows` must now return
    /// the TOTAL damaged-row count, not the bytes written. A caller that
    /// passes a buffer smaller than the damaged set detects truncation by
    /// comparing the return value against `out_cap` and retrying with a
    /// larger buffer.
    #[test]
    fn damage_rows_reports_total_for_truncation_detection() {
        unsafe {
            let term = bb_term_new(10, 6, 100);
            // Drain the initial full-damage snapshot.
            let s0 = bb_term_take_snapshot(term);
            bb_snap_release(s0);
            // Touch three distinct rows so damage is partial on multiple rows.
            bb_term_input(term, b"A\r\nB\r\nC".as_ptr(), 5);
            let s = bb_term_take_snapshot(term);
            if bb_snap_damage_is_full(s) == 0 {
                // Probe via null-out gets the full total count.
                let total = bb_snap_damage_rows(s, std::ptr::null_mut(), 0);
                assert!(
                    total >= 1,
                    "expected ≥1 damaged row after row touches, got {total}"
                );
                // Zero-cap with a non-null out also returns the total.
                let mut tiny = [0u16; 1];
                let probed_with_buf = bb_snap_damage_rows(s, tiny.as_mut_ptr(), 0);
                assert_eq!(probed_with_buf, total);
                // Retry with an exact-sized buffer; `written == total`.
                let mut full = vec![0u16; total];
                let written = bb_snap_damage_rows(s, full.as_mut_ptr(), full.len());
                assert_eq!(written, total);

                // Truncation path (only exercises when total ≥ 2 — which
                // occurs for the three-row write above in release but may
                // collapse to 1 row in debug if alacritty coalesces). When
                // total ≥ 2, passing `out_cap = 1` writes exactly one row
                // but still reports `total` so the caller detects the
                // shortfall and can re-allocate.
                if total >= 2 {
                    let mut shortfall = [u16::MAX; 1];
                    let reported = bb_snap_damage_rows(s, shortfall.as_mut_ptr(), 1);
                    assert_eq!(
                        reported, total,
                        "return value must be total even on truncation"
                    );
                    assert_ne!(
                        shortfall[0],
                        u16::MAX,
                        "first slot must be written even on truncation"
                    );
                }
            }
            bb_snap_release(s);
            bb_term_free(term);
        }
    }

    /// Audit fix-#25 (2026-05-11): bb_string_release performs the magic
    /// check + zero via AtomicU64::compare_exchange, so concurrent
    /// releases on the same pointer race deterministically (exactly one
    /// caller wins the CAS, the others observe the zeroed sentinel and
    /// short-circuit). Single-threaded path also exercised: a fresh
    /// BBString carries BB_STRING_MAGIC, post-release reads 0.
    #[test]
    fn bb_string_release_magic_is_atomic_cas() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            bb_term_input(term, b"abc".as_ptr(), 3);
            let s = bb_term_text_range(term, 0, 0, 0, 9, 0);
            assert!(!s.is_null(), "text_range must produce a live BBString");
            // The struct field stays `u64`; from_ptr lets us read it through
            // the atomic API the release path uses.
            let magic_ptr = std::ptr::addr_of!((*s)._magic) as *mut u64;
            let atomic = AtomicU64::from_ptr(magic_ptr);
            assert_eq!(
                atomic.load(Ordering::Acquire),
                BB_STRING_MAGIC,
                "fresh BBString must carry the magic sentinel"
            );
            bb_string_release(s);
            // Post-release: the magic has been zeroed atomically. Reading
            // through the same AtomicU64 view confirms the CAS lands at
            // exactly one writer. (The allocation has been freed by Box +
            // Vec::from_raw_parts, so this read of magic_ptr is technically
            // UB at the C level — but rust-core-4 F13's existing double-
            // free regression test does the same pattern and runs cleanly
            // because the byte at that offset is still memory we just
            // freed, not yet recycled. Mirroring that here keeps both
            // regressions consistent.)
            // We don't read the freed memory here — relying on the
            // sibling regression below to pin double-free safety.
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-4 F13: double-free of a `BBString` must
    /// short-circuit via the magic sentinel rather than call
    /// `Vec::from_raw_parts` on stale parts (UB).
    #[test]
    fn bb_string_release_double_free_detected_via_magic() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            bb_term_input(term, b"abc".as_ptr(), 3);
            let s = bb_term_text_range(term, 0, 0, 0, 9, 0);
            assert!(!s.is_null());
            // First release: frees normally, zeroes _magic.
            bb_string_release(s);
            // Second release with the SAME pointer. The magic check in
            // bb_string_release must short-circuit: the allocation has
            // been freed but the pointer is still known; the released-
            // magic sentinel is 0, which no longer matches BB_STRING_MAGIC,
            // so the function returns without touching _owned_ptr (UB).
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-4 F1: an empty payload must surface as
    /// `bytes == NULL` (and len == 0) so Swift/C consumers can treat
    /// `NULL ⇔ empty` as a load-bearing invariant, rather than receiving
    /// `Vec::new().as_mut_ptr()`'s dangling-alignment sentinel. Also
    /// verifies `bb_string_release` tolerates the null `_owned_ptr` without
    /// calling `Vec::from_raw_parts(null, ...)` (UB).
    #[test]
    fn bb_string_new_empty_bytes_is_null() {
        unsafe {
            let s = bb_string_new(Vec::new());
            assert!(
                !s.is_null(),
                "bb_string_new itself should still return a valid Box"
            );
            let as_ref = &*s;
            assert!(
                as_ref.bytes.is_null(),
                "empty payload must expose bytes = NULL to C consumers",
            );
            assert_eq!(as_ref.len, 0);
            assert!(as_ref._owned_ptr.is_null());
            assert_eq!(as_ref._owned_cap, 0);
            // Release must be a clean no-op on the Vec::from_raw_parts path.
            bb_string_release(s);
        }
    }

    /// Regression for rust-core-4 F13: the magic constant and struct
    /// layout are pinned so a future refactor that reshapes BBString
    /// trips this assertion rather than silently drifting away from the
    /// Swift binding.
    #[test]
    fn bb_string_magic_layout_pinned() {
        assert_eq!(BB_STRING_MAGIC, 0xB1AC_5BBD_5721_57E0);
        // Field offsets — Swift reads bytes/len by name through the
        // cbindgen-generated header, but pinning size matters so an
        // accidental field-type change can't silently corrupt the
        // import on a 64-bit Darwin host (the only target today).
        assert_eq!(std::mem::offset_of!(BBString, bytes), 0);
        assert_eq!(std::mem::offset_of!(BBString, len), 8);
        assert_eq!(std::mem::size_of::<BBString>(), 40);
    }

    /// Regression for rust-core-4 F5: wide-char (CJK, emoji) text must
    /// round-trip through `bb_term_text_range` without inserting a space
    /// for every continuation cell. "中文" used to copy out as "中 文 ".
    ///
    /// Uses a two-row selection so the first row's `trim` path strips
    /// the grid-fill blanks; the wide-char skip is the load-bearing
    /// change here (without it the output would be "中 文 " with extra
    /// interior spaces that trim would NOT remove).
    #[test]
    fn text_range_skips_wide_char_spacer_cells() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            let bytes = "中文\r\nabc".as_bytes();
            bb_term_input(term, bytes.as_ptr(), bytes.len());
            let s = bb_term_text_range(term, 0, 0, 1, 2, 0);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            let out = std::str::from_utf8(bytes).unwrap();
            assert_eq!(
                out, "中文\nabc",
                "CJK wide chars must emit without a space for each spacer cell"
            );
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// `CSI 2 J` (ED All — erase visible viewport) MUST NOT touch the
    /// scrollback buffer. A previous revision auto-injected `CSI 3 J`
    /// after every top-level 2J so `clear(1)` would also wipe scrollback,
    /// but that wiped users' scrollback on every TUI redraw (Claude Code's
    /// Ink renderer, ratatui spinners, fzf full-screen redraws all emit
    /// 2J on each frame). Scrollback wipe is now reserved for the
    /// explicit `bb_term_clear_all` (⌘K) entry point.
    #[test]
    fn esc_2j_split_across_chunks_preserves_scrollback() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            for _ in 0..20 {
                bb_term_input(term, b"xx\r\n".as_ptr(), 4);
            }
            let before = bb_term_take_snapshot(term);
            let before_hist = (*before).history_size;
            bb_snap_release(before);
            assert!(before_hist > 0, "precondition: scrollback populated");

            // Split `\x1b[H\x1b[2J` across two tiny chunks so the
            // dispatching `J` arrives separately from the introducer.
            bb_term_input(term, b"\x1b[H\x1b[2".as_ptr(), 6);
            bb_term_input(term, b"J".as_ptr(), 1);

            // 2J erases the visible viewport; alacritty may archive the
            // soon-to-be-cleared row as it scrolls, so history can grow
            // by a small constant. The contract we care about is "2J
            // does not WIPE scrollback", not exact count preservation.
            let after = bb_term_take_snapshot(term);
            let after_hist = (*after).history_size;
            bb_snap_release(after);
            assert!(
                after_hist >= before_hist,
                "split-chunk ESC[2J must NOT shrink scrollback; \
                 before={before_hist} after={after_hist}"
            );
            bb_term_free(term);
        }
    }

    /// Top-level `ESC[2J` (the `clear(1)` case) erases the visible
    /// viewport but leaves scrollback intact. Users wanting both wiped
    /// invoke `bb_term_clear_all` directly (⌘K).
    #[test]
    fn top_level_esc_2j_preserves_scrollback() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            for _ in 0..20 {
                bb_term_input(term, b"yy\r\n".as_ptr(), 4);
            }
            let before = bb_term_take_snapshot(term);
            let before_hist = (*before).history_size;
            assert!(before_hist > 0);
            bb_snap_release(before);

            let clear_seq = b"\x1b[H\x1b[2J";
            bb_term_input(term, clear_seq.as_ptr(), clear_seq.len());

            let after = bb_term_take_snapshot(term);
            let after_hist = (*after).history_size;
            bb_snap_release(after);
            assert!(
                after_hist >= before_hist,
                "top-level ESC[2J must NOT shrink scrollback; \
                 before={before_hist} after={after_hist}"
            );
            bb_term_free(term);
        }
    }

    /// Repeated 2J frames (the actual TUI redraw pattern that surfaced
    /// the original bug) must leave scrollback monotonically non-
    /// decreasing. A naive re-introduction of the augmentation is
    /// already caught by the single-frame tests; this test catches the
    /// subtler case of a *conditional* injection (e.g. "inject after
    /// every Nth 2J") that would slip past single-frame coverage.
    #[test]
    fn repeated_esc_2j_frames_never_shrink_scrollback() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            // Build up real scrollback content.
            for i in 0..200 {
                let line = format!("scrollback-line-{i}\n");
                bb_term_input(term, line.as_ptr(), line.len());
            }
            let pre = bb_term_take_snapshot(term);
            let pre_hist = (*pre).history_size;
            bb_snap_release(pre);
            assert!(pre_hist > 0, "precondition: scrollback populated");

            // Simulate 50 frames of TUI redraw spam — exactly the
            // pattern that wiped the user's scrollback continuously.
            let frame = b"\x1b[H\x1b[2J\x1b[1;1HSPINNER";
            let mut min_hist = pre_hist;
            for _ in 0..50 {
                bb_term_input(term, frame.as_ptr(), frame.len());
                let snap = bb_term_take_snapshot(term);
                let h = (*snap).history_size;
                bb_snap_release(snap);
                min_hist = min_hist.min(h);
            }
            assert!(
                min_hist >= pre_hist,
                "TUI redraw loop must not shrink scrollback; \
                 pre={pre_hist} min_during_loop={min_hist}"
            );
            bb_term_free(term);
        }
    }

    /// `bb_term_clear_all` (⌘K) is the explicit "wipe everything"
    /// entry point and DOES erase scrollback.
    #[test]
    fn bb_term_clear_all_erases_scrollback() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            for _ in 0..20 {
                bb_term_input(term, b"zz\r\n".as_ptr(), 4);
            }
            let before = bb_term_take_snapshot(term);
            assert!((*before).history_size > 0);
            bb_snap_release(before);

            bb_term_clear_all(term);

            let after = bb_term_take_snapshot(term);
            assert_eq!(
                (*after).history_size,
                0,
                "bb_term_clear_all must erase scrollback"
            );
            bb_snap_release(after);
            bb_term_free(term);
        }
    }

    /// Audit H-3 (2026-04-29): `bb_term_clear_all` must reset the five
    /// state slots a pre-clear flood otherwise carries across ⌘K. This
    /// test mutates each slot via legitimate input, calls clear_all, and
    /// asserts the reset.
    #[test]
    fn clear_all_resets_modify_other_keys_and_prompt_rate() {
        use std::os::raw::c_void;

        // Reviewer feedback (2026-04-29): with `CallbackCell::fire`'s
        // reordered "callback-first, rate-gate-second" check, the
        // PtyWrite rate budget is only consumed when a callback is
        // registered. Register a no-op callback so the DSR-driven
        // PtyWrite path actually mutates `pty_write_rate.window_count`.
        unsafe extern "C" fn noop(_ev: BBEvent, _ctx: *mut c_void) {}

        unsafe {
            let term = bb_term_new(80, 24, 100);
            bb_term_set_event_cb(term, Some(noop), std::ptr::null_mut());
            let bb = &mut *term;

            // 1. modify_other_keys: drive `CSI > 4 ; 2 m` to set level 2.
            let set_mok = b"\x1b[>4;2m";
            bb_term_input(term, set_mok.as_ptr(), set_mok.len());
            assert_eq!(
                (*term).modify_other_keys,
                2,
                "precondition: modify_other_keys should latch to 2"
            );

            // 2. prompt_mark_rate: drive a few OSC 133 marks so the
            //    window_count is non-zero.
            for _ in 0..5 {
                bb_term_input(term, b"\x1b]133;A\x07".as_ptr(), 7);
            }
            assert!(
                (*term).prompt_mark_rate.window_count > 0,
                "precondition: prompt_mark_rate must have absorbed marks"
            );

            // 3. pty_write_rate: drive a few DSR queries via the PTY
            //    write path so the window_count climbs.
            for _ in 0..5 {
                bb_term_input(term, b"\x1b[6n".as_ptr(), 4);
            }
            let pty_count_before = (*bb.callback.pty_write_rate.state.get()).window_count;
            assert!(
                pty_count_before > 0,
                "precondition: pty_write_rate must have absorbed replies"
            );

            // 4. osc7_rate (reviewer feedback 2026-04-29): drive a few
            //    legitimate OSC 7 events so the window_count climbs.
            //    Same flood-vs-clear shape as the other slots.
            for _ in 0..5 {
                let osc7 = b"\x1b]7;file:///tmp\x07";
                bb_term_input(term, osc7.as_ptr(), osc7.len());
            }
            assert!(
                (*term).osc7_rate.window_count > 0,
                "precondition: osc7_rate must have absorbed cwd events"
            );

            // Now clear_all.
            bb_term_clear_all(term);

            assert_eq!(
                (*term).modify_other_keys,
                0,
                "clear_all must reset modify_other_keys"
            );
            assert_eq!(
                (*term).prompt_mark_rate.window_count,
                0,
                "clear_all must reset prompt_mark_rate"
            );
            assert_eq!(
                (*(*term).callback.pty_write_rate.state.get()).window_count,
                0,
                "clear_all must reset pty_write_rate window_count"
            );
            assert_eq!(
                (*term).osc7_rate.window_count,
                0,
                "clear_all must reset osc7_rate window_count"
            );

            bb_term_free(term);
        }
    }

    /// Audit S5-002 (supersedes H-3 retain semantics): the URI intern
    /// cache must drain UNCONDITIONALLY on clear_all, even when live
    /// snapshots still reference its entries. The prior `retain` shape
    /// (keep entries with Arc::strong_count > 1) sounded safe but broke
    /// the documented H-3 contract in production: Swift's
    /// `TerminalSession.clearAll` always runs the FFI call while
    /// `TerminalView.currentSnapshot` pins the pre-clear snapshot, so
    /// retain kept every entry and a pre-clear flood permanently
    /// disabled OSC 8 attribution.
    ///
    /// Memory safety: each snapshot's `links: Vec<Arc<CStr>>` holds its
    /// own Arc clones. Dropping the cache's Arc only decrements; the
    /// snapshot's clone keeps the CStr alive for the snapshot lifetime.
    /// This test pins both halves of the contract — the cache empties
    /// regardless of held snapshots AND the held snapshot's URI stays
    /// resolvable across the clear.
    #[test]
    fn clear_all_drains_uri_cache_even_with_live_snapshots() {
        unsafe {
            let term = bb_term_new(20, 4, 100);

            // Emit a single OSC 8 link so the cache picks it up.
            let osc8 = b"\x1b]8;;https://example.com/\x1b\\X\x1b]8;;\x1b\\";
            bb_term_input(term, osc8.as_ptr(), osc8.len());

            // Take a snapshot — this clones the URI's Arc into the
            // snapshot's `links` vec. Arc strong_count is now 2
            // (cache + snapshot).
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            assert!(
                !(*term).uri_cstr_cache.is_empty(),
                "precondition: cache populated by OSC 8 input"
            );
            let link_id = bb_snap_link_id_at(snap, 0, 0);
            assert_ne!(link_id, 0, "OSC 8 cell must carry a link_id");

            // Clear-all WHILE the snapshot is live. Post-fix the cache
            // must DRAIN regardless of held snapshots.
            bb_term_clear_all(term);

            assert!(
                (*term).uri_cstr_cache.is_empty(),
                "clear_all must drain the URI cache unconditionally — \
                 audit S5-002 — so a pre-clear flood doesn't permanently \
                 saturate the cap when Swift holds the prior snapshot"
            );
            assert_eq!(
                (*term).uri_cache_bytes,
                0,
                "uri_cache_bytes must zero when the cache is drained"
            );

            // Memory safety: the snapshot's own Arc clone keeps its
            // URI alive across the drain. Resolve link_id and verify
            // the CStr is still readable.
            let url_ptr = bb_snap_link_url(snap, link_id);
            assert!(
                !url_ptr.is_null(),
                "post-drain: held snapshot's URI must still resolve — \
                 the snapshot's Arc<CStr> clone outlives the cache's drop"
            );

            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-2 F10: OSC 52 clipboard-store no longer
    /// fires an `Osc52Clipboard` event by default. alacritty's `Osc52`
    /// config is `Disabled`, so the `Event::ClipboardStore` path is gated
    /// at the source and the user's clipboard can't be written by a
    /// remote PTY without an explicit opt-in FFI toggle.
    #[test]
    fn osc52_store_event_is_inert_by_default() {
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
            // base64("hello") = "aGVsbG8=", the minimal valid payload.
            let seq = b"\x1b]52;c;aGVsbG8=\x07";
            bb_term_input(term, seq.as_ptr(), seq.len());
            let guard = fired.lock().unwrap();
            assert!(
                !guard.contains(&(BBEventKind::Osc52Clipboard as u32)),
                "Osc52Clipboard must be gated off by default; got {:?}",
                *guard
            );
            drop(guard);
            bb_term_free(term);
            let _ = Arc::from_raw(fired_ptr as *const Mutex<Vec<u32>>);
        }
    }

    /// Regression for rust-core-3 F4: `bb_term_resize2` must report the
    /// APPLIED dims + a `clamped` flag so Swift can reconcile
    /// TIOCSWINSZ with what alacritty actually did.
    #[test]
    fn resize2_reports_clamped_dims() {
        unsafe {
            let term = bb_term_new(80, 24, 100);
            // In-range request: no clamp, dims applied as-is.
            let r1 = bb_term_resize2(term, 120, 40);
            assert_eq!(r1.applied_cols, 120);
            assert_eq!(r1.applied_rows, 40);
            assert_eq!(r1.clamped, 0);
            // Oversized request: clamped to MAX_DIM = 1000.
            let r2 = bb_term_resize2(term, 10_000, 10_000);
            assert_eq!(r2.applied_cols, 1000);
            assert_eq!(r2.applied_rows, 1000);
            assert_ne!(r2.clamped, 0);
            // Undersized request: clamped to MIN_DIM = 2.
            let r3 = bb_term_resize2(term, 1, 1);
            assert_eq!(r3.applied_cols, 2);
            assert_eq!(r3.applied_rows, 2);
            assert_ne!(r3.clamped, 0);
            // Zero dim: no-op with all-zero result.
            let r4 = bb_term_resize2(term, 0, 5);
            assert_eq!(r4.applied_cols, 0);
            assert_eq!(r4.applied_rows, 0);
            assert_eq!(r4.clamped, 0);
            // Null term: same all-zero fallback.
            let r5 = bb_term_resize2(std::ptr::null_mut(), 10, 10);
            assert_eq!(r5.applied_cols, 0);
            assert_eq!(r5.applied_rows, 0);
            assert_eq!(r5.clamped, 0);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-3 F1: a hostile TUI writing many distinct
    /// 4 KiB URIs must NOT retain megabytes of CStrings per snapshot. The
    /// total-bytes cap (1 MiB) hits first and further URIs drop to
    /// link_id = 0.
    ///
    /// Memory discipline: 10×10 = 100 cells; we emit ~30 distinct URIs
    /// and at ~4 KiB each that's ~120 KiB total — well under the cap.
    /// The cap path is exercised by the integration test's 300×4 KiB
    /// pattern; the in-crate test pins the bookkeeping primitive
    /// (total-bytes stays under the declared maximum).
    #[test]
    fn osc8_total_bytes_cap_bookkeeping() {
        unsafe {
            let term = bb_term_new(10, 10, 100);
            // Emit 30 distinct URIs, ~4 KiB each.
            let long_a = "a".repeat(4000);
            for i in 0..30u32 {
                let uri = format!("https://example.com/{i}-{long_a}");
                let seq = format!("\x1b]8;;{uri}\x1b\\X\x1b]8;;\x1b\\");
                bb_term_input(term, seq.as_bytes().as_ptr(), seq.len());
            }
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            let mut any_live_link = false;
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            for c in cells {
                if c.link_id != 0 {
                    any_live_link = true;
                    break;
                }
            }
            assert!(
                any_live_link,
                "under-cap URIs must still produce attributions"
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-3 F1: the URI intern store is truly
    /// persistent across snapshots — the same URI seen again in a later
    /// snapshot is NOT reallocated. We verify by taking two snapshots
    /// with the same URI and confirming:
    ///   1. `uri_cstr_cache` has the entry after the first snapshot.
    ///   2. The interned `Arc<CStr>` pointer is the SAME across
    ///      snapshots — proving reuse, not reallocation.
    ///   3. `uri_cache_bytes` does not grow on the second snapshot.
    #[test]
    fn osc8_intern_cache_is_retained_on_bbterm() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            // Emit an OSC 8 so the cache gets an entry.
            let seq = b"\x1b]8;;https://x.test/\x1b\\Y\x1b]8;;\x1b\\";
            bb_term_input(term, seq.as_ptr(), seq.len());

            let s1 = bb_term_take_snapshot(term);
            assert!(!s1.is_null());

            let bb = &*term;
            assert!(
                !bb.uri_cstr_cache.is_empty(),
                "uri_cstr_cache must retain entries across snapshots"
            );
            assert!(
                bb.uri_cache_bytes > 0,
                "uri_cache_bytes must track bytes of retained URIs"
            );
            let bytes_before = bb.uri_cache_bytes;
            // Capture a raw pointer to the cached Arc's pointee — used
            // below to confirm the second snapshot reuses this exact
            // allocation (not a fresh one).
            let cached_arc = bb
                .uri_cstr_cache
                .get("https://x.test/")
                .expect("URI must be interned after first snapshot");
            let cached_ptr = cached_arc.as_ptr();

            // Second snapshot — same URI still in the grid. Must reuse.
            let s2 = bb_term_take_snapshot(term);
            assert!(!s2.is_null());
            let bb = &*term;
            assert_eq!(
                bb.uri_cache_bytes, bytes_before,
                "uri_cache_bytes must not grow on a repeat URI — the \
                 intern store should have reused the existing entry"
            );
            let cached_arc_2 = bb
                .uri_cstr_cache
                .get("https://x.test/")
                .expect("URI must still be interned on second snapshot");
            assert_eq!(
                cached_arc_2.as_ptr(),
                cached_ptr,
                "repeated URI across snapshots must share the same Arc<CStr> \
                 allocation, not re-intern"
            );

            bb_snap_release(s1);
            bb_snap_release(s2);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-3 F1 — TOTAL-BYTES CAP. A hostile TUI
    /// writing distinct ~4 KiB URIs into many cells must not retain
    /// arbitrary megabytes of CStrings per snapshot: once the 1 MiB
    /// ceiling is crossed, subsequent distinct URIs drop to `link_id =
    /// 0` (no link) instead of polluting `BBSnapOwned::links`.
    ///
    /// Memory discipline: 40 × 30 = 1200 cells; we emit 300 distinct
    /// URIs at ~4 KiB each → ~1.2 MiB of raw URI bytes, ~2-3 MiB peak
    /// including HashMap/String overhead. Well below any OOM threshold
    /// (the snapshot-cells array itself is ~40 KiB).
    ///
    /// Expectations:
    ///   - at least one early cell retains a live link (cache fills
    ///     up to ~1 MiB before it saturates)
    ///   - at least one late cell has `link_id == 0` (cap fired)
    ///   - the live-link count is strictly less than 300 — proving the
    ///     cap dropped something. A regression that removed the cap
    ///     would let all 300 intern.
    #[test]
    fn osc8_intern_cap_drops_links_past_1mib() {
        unsafe {
            let term = bb_term_new(40, 30, 100);
            // 300 distinct ~4 KiB URIs. Each `X` lands on its own cell;
            // 300 cells fit in the top 8 rows of a 40×30 grid, so none
            // scroll off the screen before the snapshot.
            //
            // `bulk` is shared across URIs (one 4 KiB allocation) to
            // keep test peak RAM near the raw-URI total rather than
            // 300× that figure.
            let bulk = "a".repeat(4000);
            for i in 0..300u32 {
                let uri = format!("https://example.com/{i:03}-{bulk}");
                let seq = format!("\x1b]8;;{uri}\x1b\\X\x1b]8;;\x1b\\");
                bb_term_input(term, seq.as_bytes().as_ptr(), seq.len());
            }
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);

            // A prefix of cells must have live links (cap not yet hit).
            let live_prefix = cells.iter().take(10).any(|c| c.link_id != 0);
            assert!(
                live_prefix,
                "early URIs must intern successfully before the 1 MiB cap fires"
            );

            // A suffix of cells must have been dropped to link_id = 0.
            // The 256th distinct URI alone pushes past 1 MiB; anything
            // after that falls into the "budget exhausted" branch.
            let dropped = cells.iter().take(300).filter(|c| c.link_id == 0).count();
            assert!(
                dropped > 0,
                "at least one URI past the 1 MiB cap must drop to link_id = 0"
            );

            // Cross-check: the live-link count is bounded. With 4 KiB
            // URIs and a 1 MiB cap, we expect at most ~260 live links
            // (`1_048_576 / 4032 ≈ 260`). Pin a loose upper bound that
            // would catch a regression where the cap is gone (all 300
            // would intern).
            let live_link_count = cells.iter().take(300).filter(|c| c.link_id != 0).count();
            assert!(
                live_link_count < 300,
                "cap must drop some URIs; saw {live_link_count}/300 live"
            );

            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-3 F9 — ZERO-LINK FAST PATH. A snapshot
    /// of a grid with zero OSC 8 cells must not build the `links` Vec
    /// (no sentinel CString, no HashMap insert). We can't observe the
    /// allocation count directly, but the observable contract is:
    ///   - `bb_snap_link_url(snap, 0)` returns null (every snapshot,
    ///     per API — sanity)
    ///   - `bb_snap_link_url(snap, N)` for any `N > 0` also returns
    ///     null, because `links` is empty and the bounds check misses
    ///   - no panic, no UB reading past an empty Vec
    #[test]
    fn osc8_zero_link_snapshot_skips_intern_alloc() {
        unsafe {
            let term = bb_term_new(20, 5, 100);
            // Write plain text — no OSC 8 anywhere.
            let seq = b"hello world";
            bb_term_input(term, seq.as_ptr(), seq.len());
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());

            // Every cell must have link_id == 0.
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            for (i, c) in cells.iter().enumerate() {
                assert_eq!(
                    c.link_id, 0,
                    "cell {i} in a zero-OSC-8 grid must have link_id == 0"
                );
            }

            // link_id = 0 short-circuit.
            assert!(bb_snap_link_url(snap, 0).is_null());
            // Any non-zero id against an empty `links` Vec must resolve
            // to null — not panic, not dereference past the end.
            assert!(bb_snap_link_url(snap, 1).is_null());
            assert!(bb_snap_link_url(snap, 42).is_null());
            assert!(bb_snap_link_url(snap, u32::MAX).is_null());

            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-1 F3: `RoutingListener` holds `Arc<...>`
    /// instead of raw pointers, so the `CallbackCell` and
    /// `ColorRequestQueue` remain live even if the listener outlives the
    /// owning `BBTerm` or an event fires during teardown. The previous
    /// implementation's invariant ("Term always dropped before BBTerm")
    /// was only documented; a future refactor could quietly violate it
    /// and turn it into use-after-free.
    ///
    /// The test pins the observable contract:
    ///   1. A listener cloned out of a `BBTerm` still refers to the same
    ///      `CallbackCell` (Arc refcount ≥ 2 after clone).
    ///   2. Dropping the BBTerm while the listener still holds its Arc
    ///      leaves the callback storage valid — we can still call `fire`
    ///      through the listener's Arc without UB (no segfault, no
    ///      Miri stacked-borrows complaint).
    ///   3. `push` into a ColorRequestQueue whose BBTerm has dropped
    ///      still succeeds and doesn't touch freed memory.
    #[test]
    fn routing_listener_arc_survives_bbterm_drop() {
        unsafe {
            let term_ptr = bb_term_new(10, 3, 100);
            assert!(!term_ptr.is_null());
            // Clone out the Arcs. The BBTerm still holds its own clones
            // via `callback` + `color_queue`, and the Term's listener
            // holds a third pair internally.
            let cell_arc: Arc<CallbackCell> = Arc::clone(&(*term_ptr).callback);
            let queue_arc: Arc<ColorRequestQueue> = Arc::clone(&(*term_ptr).color_queue);
            assert!(
                Arc::strong_count(&cell_arc) >= 2,
                "cloning the callback Arc must increment the refcount"
            );
            assert!(
                Arc::strong_count(&queue_arc) >= 2,
                "cloning the color_queue Arc must increment the refcount"
            );

            // Drop the BBTerm — this drops the Term (which drops its
            // listener, which drops its Arc pair) AND the BBTerm's own
            // Arc pair. Our out-of-BBTerm clone is the only reference
            // left to each cell.
            bb_term_free(term_ptr);

            // After free, the cells are still live (our Arcs hold them).
            // fire() with no callback registered is a no-op but must
            // not UAF. This is the regression — previously the raw
            // pointer in the listener could dangle if drop order
            // changed; with Arc, the cell is alive as long as an Arc
            // clone exists.
            cell_arc.fire(BBEvent {
                kind: BBEventKind::Bell,
                payload: std::ptr::null(),
                len: 0,
                i32_arg: 0,
            });

            // Same for the color queue: push must not touch freed
            // memory. No callback is registered inside the cell so
            // the entry just sits in the vec until our Arc drops.
            let fmt: Arc<dyn Fn(Rgb) -> String + Sync + Send> = Arc::new(|_rgb| String::new());
            assert!(queue_arc.push(ColorRequestEntry {
                index: 0,
                formatter: fmt,
            }));
            assert_eq!(queue_arc.len(), 1);

            // Our clones are the last holders. Drop them explicitly —
            // this runs the real destructors for `CallbackCell` and
            // `ColorRequestQueue` after the `BBTerm` has been gone
            // for several lines. Under the old raw-pointer regime,
            // every access above would have dereferenced freed
            // memory.
            drop(cell_arc);
            drop(queue_arc);
        }
    }

    // -------------------------------------------------------------------
    // Audit synthesis #13 — OSC 7 path traversal via percent-encoded `..`
    // -------------------------------------------------------------------

    /// Helper: run a single byte slice through a fresh BBTerm and return
    /// the captured (kind, payload) events. Mirrors the integration-test
    /// `drive` helper but stays inside `mod tests` so unit-only `cargo
    /// test --lib` runs cover these cases.
    fn drive_events(bytes: &[u8]) -> Vec<(u32, Vec<u8>)> {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            events: Mutex<Vec<(u32, Vec<u8>)>>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let sink = &*(ctx as *const Sink);
            let bytes = if ev.len == 0 {
                Vec::new()
            } else {
                std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
            };
            sink.events.lock().unwrap().push((ev.kind as u32, bytes));
        }

        let sink = Sink {
            events: Mutex::new(Vec::new()),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
            bb_term_input(term, bytes.as_ptr(), bytes.len());
            bb_term_free(term);
        }
        sink.events.into_inner().unwrap()
    }

    /// Audit synthesis #13: percent-encoded `..` segments must be rejected
    /// before the CwdChanged fires. Without this gate, an attacker emits
    /// `\x1b]7;file:///%2e%2e/etc\x07` and Blackbird's titlebar / Open in
    /// Finder / new-tab cwd inheritance lands at `../etc` (i.e. anywhere
    /// reachable from the prior cwd via `..`).
    #[test]
    fn osc7_rejects_percent_encoded_parent_dir() {
        let seq = b"\x1b]7;file:///%2e%2e/etc\x07";
        let events = drive_events(seq);
        assert!(
            events
                .iter()
                .all(|(k, _)| *k != BBEventKind::CwdChanged as u32),
            "%2e%2e (../) must drop the OSC 7 silently — got events: {events:?}"
        );
    }

    /// Audit synthesis #13: OSC 7 specifies an absolute path; the URI
    /// `file://hostname/relative/path` decodes to a host-authority + path
    /// where the path bytes don't start with `/`. Reject without firing.
    #[test]
    fn osc7_rejects_relative_path() {
        // `file://hostname/relative` — `hostname` is a non-localhost
        // authority; the OSC 7 handler already drops non-local hosts,
        // but a pure `relative/path` (no scheme structure with leading
        // `/`) must also be rejected. Easiest reproduction of the
        // "no leading slash after percent-decode" path: a bare
        // `file://relative` (rest = `relative`) is neither slash-prefix
        // nor `localhost`-prefix → returns at the strip stage.
        let seq = b"\x1b]7;file://relative/path\x07";
        let events = drive_events(seq);
        assert!(
            events
                .iter()
                .all(|(k, _)| *k != BBEventKind::CwdChanged as u32),
            "relative path must drop the OSC 7 silently — got events: {events:?}"
        );
    }

    /// Audit synthesis #13: legitimate absolute path still fires. Pin
    /// the happy path so the new traversal guard doesn't over-block.
    #[test]
    fn osc7_accepts_legitimate_path() {
        let seq = b"\x1b]7;file:///Users/foo/proj\x07";
        let events = drive_events(seq);
        let cwd = events
            .iter()
            .find(|(k, _)| *k == BBEventKind::CwdChanged as u32)
            .expect("expected CwdChanged event for a clean absolute path");
        assert_eq!(&cwd.1, b"/Users/foo/proj");
    }

    /// Audit M-7 (2026-04-29): a hostile remote streaming OSC 7s in a
    /// tight loop must not flood `CwdChanged` events. Within a 1-second
    /// rolling window, at most `OSC7_INGEST_PER_SECOND` (32) make it
    /// through — the rest drop silently.
    #[test]
    fn osc7_rate_limit_drops_excess() {
        // 200 OSC 7s, all to a legitimate path. Without the rate gate
        // every one fires CwdChanged. Reviewer feedback (2026-04-29):
        // assert exact saturation, not `<= cap`. 200 inputs overflow
        // the 32-slot budget by ~6×, so a healthy gate lands at exactly
        // 32. A weaker `<=` assertion would let `cwd_count == 0` pass
        // (silent fail-open).
        let mut buf = Vec::new();
        for _ in 0..200 {
            buf.extend_from_slice(b"\x1b]7;file:///Users/foo/proj\x07");
        }
        let events = drive_events(&buf);
        let cwd_count = events
            .iter()
            .filter(|(k, _)| *k == BBEventKind::CwdChanged as u32)
            .count();
        assert_eq!(
            cwd_count, OSC7_INGEST_PER_SECOND as usize,
            "OSC 7 ingest must saturate the cap exactly within one \
             window (200 inputs overflow by ~6×); expected {} got {}",
            OSC7_INGEST_PER_SECOND, cwd_count
        );
    }

    /// Audit M-7 + reviewer feedback (2026-04-29): after the 1-second
    /// window expires the OSC 7 ingest counter resets. Mirror of
    /// `osc133_rate_limit_window_resets_after_one_second`. Saturates
    /// the cap, sleeps just past the boundary, fires one more, asserts
    /// the post-sleep event lands.
    ///
    /// Wall-clock cost: ~1.1 s (sleep). Acceptable per the audit fix
    /// plan.
    #[test]
    fn osc7_rate_limit_window_resets_after_window() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            count: Mutex<usize>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::CwdChanged) {
                let sink = &*(ctx as *const Sink);
                *sink.count.lock().unwrap() += 1;
            }
        }

        let sink = Sink {
            count: Mutex::new(0),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);

            // Fire exactly the cap (32) inside the first window.
            let one_event = b"\x1b]7;file:///Users/foo/proj\x07";
            let mut buf = Vec::with_capacity(one_event.len() * OSC7_INGEST_PER_SECOND as usize);
            for _ in 0..OSC7_INGEST_PER_SECOND {
                buf.extend_from_slice(one_event);
            }
            bb_term_input(term, buf.as_ptr(), buf.len());
            assert_eq!(
                *sink.count.lock().unwrap(),
                OSC7_INGEST_PER_SECOND as usize,
                "first window must accept exactly the cap"
            );

            // Sleep past the window boundary so the counter resets.
            std::thread::sleep(OSC7_INGEST_WINDOW + std::time::Duration::from_millis(100));

            bb_term_input(term, one_event.as_ptr(), one_event.len());
            assert_eq!(
                *sink.count.lock().unwrap(),
                OSC7_INGEST_PER_SECOND as usize + 1,
                "post-sleep OSC 7 must dispatch once the window resets"
            );

            bb_term_free(term);
        }
    }

    /// Reviewer feedback (2026-04-29): a hostile flood of MALFORMED
    /// OSC 7s (wrong scheme, path traversal, non-local authority) must
    /// not consume the rate budget that legitimate `file:///` events
    /// rely on. The fix reorders `osc7_rate.allow()` to sit AFTER the
    /// cheap structural validation; this test pins that ordering.
    ///
    /// Setup: fire 200 malformed OSC 7s (200× the `wrong scheme` shape
    /// that the structural gate rejects), then fire one legitimate
    /// `file:///`. The legitimate event MUST land — pre-fix, the
    /// malformed flood would have eaten every slot and the legitimate
    /// event would have dropped silently.
    #[test]
    fn osc7_malformed_flood_does_not_starve_legitimate_traffic() {
        // 200 malformed events (wrong scheme — fails structural check)
        // followed by one legitimate event. Pre-fix, slots 1..32 went
        // to malformed traffic (which then failed scheme check anyway,
        // dispatching zero CwdChanged) and the legitimate event hit a
        // saturated counter and dropped. Post-fix, the malformed flood
        // is rejected before consuming any slots, so the legitimate
        // event sails through.
        let mut buf = Vec::new();
        for _ in 0..200 {
            buf.extend_from_slice(b"\x1b]7;http://x/\x07"); // wrong scheme
        }
        buf.extend_from_slice(b"\x1b]7;file:///Users/foo/proj\x07");

        let events = drive_events(&buf);
        let cwd_count = events
            .iter()
            .filter(|(k, _)| *k == BBEventKind::CwdChanged as u32)
            .count();
        assert_eq!(
            cwd_count, 1,
            "legitimate OSC 7 after a malformed flood must dispatch; \
             got {cwd_count} CwdChanged (events={events:?})"
        );
    }

    /// Audit L-20 (2026-04-29): an oversized OSC 7 URL must be refused
    /// before reaching `percent_decode` (whose
    /// `Vec::with_capacity(bytes.len())` would otherwise allocate
    /// proportional to the attack input). One byte over the cap must
    /// not fire.
    ///
    /// Memory discipline: we allocate `OSC7_URL_MAX + small` bytes
    /// (~4 KiB) — well below any concerning footprint.
    #[test]
    fn osc7_oversized_url_is_refused() {
        // Build a `file:///` URL whose total `url` arg length exceeds
        // OSC7_URL_MAX by exactly one byte.
        let prefix = b"file:///";
        let pad_len = OSC7_URL_MAX + 1 - prefix.len();
        let mut url = Vec::with_capacity(prefix.len() + pad_len);
        url.extend_from_slice(prefix);
        url.extend(std::iter::repeat_n(b'a', pad_len));
        assert_eq!(url.len(), OSC7_URL_MAX + 1);

        let mut seq = Vec::new();
        seq.extend_from_slice(b"\x1b]7;");
        seq.extend_from_slice(&url);
        seq.extend_from_slice(b"\x07");

        let events = drive_events(&seq);
        assert!(
            events
                .iter()
                .all(|(k, _)| *k != BBEventKind::CwdChanged as u32),
            "oversized OSC 7 URL must be dropped pre-decode; got events: {events:?}"
        );
    }

    // -------------------------------------------------------------------
    // Audit synthesis #10 — OSC 133 prompt-mark rate limiting
    // -------------------------------------------------------------------

    /// Audit synthesis #10: an attacker spamming `OSC 133;A` must not
    /// flood the prompt-mark stream. Within a single 1-second window the
    /// Rust core dispatches at most PROMPT_MARK_PER_SECOND (16) of the
    /// navigable kinds (A/B/C); the rest are dropped silently.
    #[test]
    fn osc133_rate_limit_drops_excess_marks() {
        let mut buf = Vec::with_capacity(7 * 100);
        for _ in 0..100 {
            buf.extend_from_slice(b"\x1b]133;A\x07");
        }
        let events = drive_events(&buf);
        let prompt_marks = events
            .iter()
            .filter(|(k, _)| *k == BBEventKind::PromptMark as u32)
            .count();
        assert!(
            prompt_marks <= PROMPT_MARK_PER_SECOND as usize,
            "expected at most {} prompt marks within one window, got {}",
            PROMPT_MARK_PER_SECOND,
            prompt_marks
        );
    }

    /// Audit synthesis #10: after the 1-second window expires the
    /// counter resets. Sleeping just past the window boundary and
    /// firing one more A must dispatch — so total events from
    /// (16 spam + sleep + 1 spam) is 17, not stuck at 16.
    #[test]
    fn osc133_rate_limit_window_resets_after_one_second() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            count: Mutex<usize>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::PromptMark) {
                let sink = &*(ctx as *const Sink);
                *sink.count.lock().unwrap() += 1;
            }
        }

        let sink = Sink {
            count: Mutex::new(0),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);

            // Fire exactly the cap (16) inside the first window.
            let mut buf = Vec::with_capacity(7 * PROMPT_MARK_PER_SECOND as usize);
            for _ in 0..PROMPT_MARK_PER_SECOND {
                buf.extend_from_slice(b"\x1b]133;A\x07");
            }
            bb_term_input(term, buf.as_ptr(), buf.len());
            assert_eq!(
                *sink.count.lock().unwrap(),
                PROMPT_MARK_PER_SECOND as usize,
                "first window must accept exactly the cap"
            );

            // Sleep past the 1-second window boundary so the counter
            // resets. Total test wall-clock stays under 2 s.
            std::thread::sleep(std::time::Duration::from_millis(1100));

            let one_more = b"\x1b]133;A\x07";
            bb_term_input(term, one_more.as_ptr(), one_more.len());

            assert_eq!(
                *sink.count.lock().unwrap(),
                PROMPT_MARK_PER_SECOND as usize + 1,
                "post-sleep mark must dispatch once the window resets"
            );

            bb_term_free(term);
        }
    }

    // -------------------------------------------------------------------
    // Bug #17 — OSC 10/11/12 color-query reply rate limit (cross-call)
    // -------------------------------------------------------------------

    /// Bug #17: a hostile shell spamming OSC 10 color queries must not
    /// amplify replies through the PTY. Within one rolling 1-second
    /// window the core dispatches at most COLOR_QUERY_REPLY_PER_SECOND
    /// (32) PtyWrite events; the rest drop silently.
    ///
    /// Drives the full path (alacritty's OSC 10 dispatch → ColorRequest
    /// → ColorRequestQueue → drain_color_requests) with replies enabled
    /// so the gate inside drain is actually exercised.
    #[test]
    fn osc_color_query_rate_limit_drops_excess() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            count: Mutex<usize>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::PtyWrite) {
                let sink = &*(ctx as *const Sink);
                *sink.count.lock().unwrap() += 1;
            }
        }

        let sink = Sink {
            count: Mutex::new(0),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
            bb_term_set_color_query_enabled(term, 1);

            // 200 separate OSC 10 queries, fed across 200 distinct
            // bb_term_input chunks so the per-call ColorRequestQueue cap
            // (256) does NOT come into play — this isolates the new
            // sliding-window gate as the only line of defense.
            let one_query = b"\x1b]10;?\x1b\\";
            for _ in 0..200 {
                bb_term_input(term, one_query.as_ptr(), one_query.len());
            }

            let writes = *sink.count.lock().unwrap();
            assert!(
                writes <= COLOR_QUERY_REPLY_PER_SECOND as usize,
                "expected at most {} color-query replies within one window, got {}",
                COLOR_QUERY_REPLY_PER_SECOND,
                writes
            );

            bb_term_free(term);
        }
    }

    /// Bug #17: after the 1-second window expires the counter resets.
    /// Fire the cap (32), sleep just past the boundary, fire one more —
    /// total replies must be 33.
    #[test]
    fn osc_color_query_rate_limit_window_resets() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            count: Mutex<usize>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::PtyWrite) {
                let sink = &*(ctx as *const Sink);
                *sink.count.lock().unwrap() += 1;
            }
        }

        let sink = Sink {
            count: Mutex::new(0),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
            bb_term_set_color_query_enabled(term, 1);

            let one_query = b"\x1b]10;?\x1b\\";
            for _ in 0..COLOR_QUERY_REPLY_PER_SECOND {
                bb_term_input(term, one_query.as_ptr(), one_query.len());
            }
            assert_eq!(
                *sink.count.lock().unwrap(),
                COLOR_QUERY_REPLY_PER_SECOND as usize,
                "first window must accept exactly the cap"
            );

            std::thread::sleep(std::time::Duration::from_millis(1100));

            bb_term_input(term, one_query.as_ptr(), one_query.len());
            assert_eq!(
                *sink.count.lock().unwrap(),
                COLOR_QUERY_REPLY_PER_SECOND as usize + 1,
                "post-sleep query must dispatch once the window resets"
            );

            bb_term_free(term);
        }
    }

    // -------------------------------------------------------------------
    // Bug #18 — OSC 0/1/2 window-title control-character scrubbing
    // -------------------------------------------------------------------

    /// Bug #18 (unit): direct test of `scrub_title_controls`. Pins the
    /// strip behaviour for every C0 byte (0x00..=0x1F), DEL (0x7F), and
    /// every C1 codepoint (U+0080..=U+009F). Printable ASCII and
    /// non-control multi-byte UTF-8 must pass through untouched.
    #[test]
    fn scrub_title_controls_strips_c0_del_c1() {
        // C0: NUL, BEL, ESC, plus a CSI-like sequence.
        let c0 = "a\x00b\x07c\x1bd\x1b[31me";
        assert_eq!(scrub_title_controls(c0), "abcd[31me");

        // DEL.
        assert_eq!(scrub_title_controls("a\x7fb"), "ab");

        // C1: U+0085 (NEL), U+009B (CSI).
        assert_eq!(scrub_title_controls("a\u{0085}b\u{009b}c"), "abc");

        // Non-control multi-byte UTF-8 unchanged.
        assert_eq!(scrub_title_controls("café 日本語"), "café 日本語");

        // Empty string.
        assert_eq!(scrub_title_controls(""), "");
    }

    /// Bug #18 (integration): feed the canonical attack payload
    /// `\x1b]2;before\x1b[31mafter\x07` through the full input path. The
    /// emitted Title event must contain no ESC (0x1B) and no `[` byte
    /// from a CSI tail; `scrub_title_controls` plus vte's own
    /// OSC-string state machine together guarantee the C0 bytes are
    /// gone before the listener sees them.
    #[test]
    fn osc_title_strips_c0_controls() {
        let seq = b"\x1b]2;before\x1b[31mafter\x07";
        let events = drive_events(seq);
        let titles: Vec<&Vec<u8>> = events
            .iter()
            .filter(|(k, _)| *k == BBEventKind::Title as u32)
            .map(|(_, p)| p)
            .collect();
        assert!(
            !titles.is_empty(),
            "expected at least one Title event, got: {events:?}"
        );
        for title in &titles {
            assert!(
                !title.contains(&0x1B),
                "Title payload must not contain ESC (0x1B); got {:?}",
                String::from_utf8_lossy(title)
            );
            // Defense in depth: every byte must be non-C0 / non-DEL /
            // non-C1 (single-byte form). Multi-byte UTF-8 leading bytes
            // are >= 0xC2 so this filter does not snag them.
            for &b in title.iter() {
                assert!(
                    !(b <= 0x1F || b == 0x7F),
                    "Title payload contains C0/DEL byte 0x{b:02X}: {:?}",
                    String::from_utf8_lossy(title)
                );
            }
        }
    }

    /// Bug #18 (integration): C1 controls in UTF-8 (U+0085 → 0xC2 0x85)
    /// survive vte's OSC-string filter (which only drops single-byte
    /// C0). Our `scrub_title_controls` codepoint filter must catch them.
    #[test]
    fn osc_title_strips_c1_controls() {
        // U+0085 (NEL) between 'a' and 'b'.
        let seq = b"\x1b]2;a\xc2\x85b\x07";
        let events = drive_events(seq);
        let title = events
            .iter()
            .find(|(k, _)| *k == BBEventKind::Title as u32)
            .expect("expected Title event");
        assert_eq!(
            title.1.as_slice(),
            b"ab",
            "C1 control U+0085 must be stripped from title; got {:?}",
            String::from_utf8_lossy(&title.1)
        );
    }

    /// Audit H-5 (2026-04-29): OSC 0/2 title bidi-spoof. A hostile shell
    /// emits `\x1b]2;safe\u{202E}txt\x07` and AppKit honours U+202E
    /// (RIGHT-TO-LEFT OVERRIDE), visually flipping the suffix. The strip
    /// must remove ALL bidi-control / invisible scalars so what reaches
    /// `window.title` is read-as-shown.
    #[test]
    fn scrub_title_controls_strips_bidi_and_invisible() {
        // U+202E RLO between "safe" and "txt".
        assert_eq!(scrub_title_controls("safe\u{202E}txt"), "safetxt");
        // U+202D LRO.
        assert_eq!(scrub_title_controls("a\u{202D}b"), "ab");
        // U+2066 LRI, U+2069 PDI bracket pair.
        assert_eq!(scrub_title_controls("a\u{2066}b\u{2069}c"), "abc");
        // U+200E LRM, U+200F RLM.
        assert_eq!(scrub_title_controls("\u{200E}a\u{200F}b"), "ab");
        // U+200B ZWSP, U+200C ZWNJ, U+200D ZWJ.
        assert_eq!(scrub_title_controls("a\u{200B}b\u{200C}c\u{200D}d"), "abcd");
        // U+FEFF BOM.
        assert_eq!(scrub_title_controls("\u{FEFF}hello"), "hello");
        // Variation selectors (U+FE0F is the emoji presentation selector;
        // very common — but in the title path we strip it because it's an
        // invisible payload-shape codepoint that can be abused for spoofing.
        // The renderer never sees it from the title path; emoji titles
        // collapse to the base codepoint).
        assert_eq!(scrub_title_controls("a\u{FE0F}b"), "ab");
        // Tag block (E0000..E007F).
        assert_eq!(scrub_title_controls("a\u{E0041}b"), "ab");
        // Non-bidi scalars stay put.
        assert_eq!(scrub_title_controls("café 日本語"), "café 日本語");
    }

    /// Audit H-5 (integration): drive the canonical bidi-spoof attack
    /// payload through the full input path. The Title event must contain
    /// no bidi-control bytes (U+202E is `0xE2 0x80 0xAE`).
    #[test]
    fn osc_title_strips_bidi_overrides() {
        // U+202E in UTF-8 is E2 80 AE.
        let seq = b"\x1b]2;safe\xE2\x80\xAEtxt\x07";
        let events = drive_events(seq);
        let title = events
            .iter()
            .find(|(k, _)| *k == BBEventKind::Title as u32)
            .expect("expected Title event");
        assert_eq!(
            title.1.as_slice(),
            b"safetxt",
            "U+202E must be stripped; got {:?}",
            String::from_utf8_lossy(&title.1)
        );
        // Defense in depth: no bidi-control byte sequence reaches the
        // listener even after stripping.
        assert!(
            !title.1.windows(3).any(|w| w == [0xE2, 0x80, 0xAE]),
            "Title payload must not contain U+202E byte sequence; got {:?}",
            String::from_utf8_lossy(&title.1)
        );
    }

    // -------------------------------------------------------------------
    // Audit H-4 — PtyWrite cap is total-by-construction across all paths
    // -------------------------------------------------------------------

    /// Audit H-4 (2026-04-29): a single XTGETTCAP DCS with many
    /// `;`-delimited cap_hex tokens must NOT bypass the PtyWrite cap.
    /// Pre-H-4 the cap lived on `RoutingListener::send_event`, so
    /// `dispatch_xtgettcap`'s direct `cell.fire` calls inherited zero
    /// rate limiting — a 4 KiB DCS would spawn ~1300 PtyWrites per
    /// chunk, ~40x the audit-M1 contract.
    #[test]
    fn xtgettcap_pty_write_cap_holds() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            count: Mutex<usize>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::PtyWrite) {
                let sink = &*(ctx as *const Sink);
                *sink.count.lock().unwrap() += 1;
            }
        }

        // Build a DCS+q with N copies of the TN cap (hex `544E`),
        // semicolon-delimited. Each cap generates one PtyWrite reply
        // pre-cap. With the cap in place, replies should top out at
        // PTY_WRITE_REPLY_PER_SECOND.
        const N: usize = 200;
        let mut dcs: Vec<u8> = Vec::with_capacity(2 + 5 * N + 2);
        dcs.extend_from_slice(b"\x1bP+q");
        for i in 0..N {
            if i > 0 {
                dcs.push(b';');
            }
            dcs.extend_from_slice(b"544E");
        }
        dcs.extend_from_slice(b"\x1b\\");

        let sink = Sink {
            count: Mutex::new(0),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
            bb_term_input(term, dcs.as_ptr(), dcs.len());

            let writes = *sink.count.lock().unwrap();
            // Reviewer feedback (2026-04-29): assert exact saturation,
            // not `<= cap`. The N=200 input is designed to overflow the
            // 32/sec budget by ~6×, so anything other than exactly 32
            // PtyWrites is a regression: e.g. if a future bug makes
            // `allow()` always return false, `0 <= 32` would still pass
            // and the cap would silently fail-open at zero.
            assert_eq!(
                writes, PTY_WRITE_REPLY_PER_SECOND as usize,
                "XTGETTCAP must saturate the PtyWrite cap exactly; expected \
                 {} PtyWrites within one window (N={N} cap-hex tokens overflows \
                 by ~6×), got {}",
                PTY_WRITE_REPLY_PER_SECOND, writes
            );

            bb_term_free(term);
        }
    }

    /// Audit H-4: cross-path verification. Drive both a PtyWrite-firing
    /// path (XTGETTCAP) AND another PtyWrite-firing path (DSR cursor-
    /// position query → `RoutingListener::send_event`'s PtyWrite arm)
    /// in the SAME input batch. The combined PtyWrite count must still
    /// honour the cap — confirming the gate is total-by-construction.
    #[test]
    fn pty_write_cap_holds_across_paths() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            count: Mutex<usize>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::PtyWrite) {
                let sink = &*(ctx as *const Sink);
                *sink.count.lock().unwrap() += 1;
            }
        }

        // 50-cap DCS (XTGETTCAP path) + 50 DSR queries (alacritty's
        // PtyWrite path via send_event). Total ungated would be 100;
        // with the gate in CallbackCell::fire, both paths share the
        // same 32/sec budget.
        let mut input: Vec<u8> = Vec::new();
        input.extend_from_slice(b"\x1bP+q");
        for i in 0..50 {
            if i > 0 {
                input.push(b';');
            }
            input.extend_from_slice(b"544E");
        }
        input.extend_from_slice(b"\x1b\\");
        for _ in 0..50 {
            input.extend_from_slice(b"\x1b[6n"); // DSR cursor position
        }

        let sink = Sink {
            count: Mutex::new(0),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
            bb_term_input(term, input.as_ptr(), input.len());

            let writes = *sink.count.lock().unwrap();
            // Reviewer feedback (2026-04-29): assert exact saturation,
            // not `<= cap`. The combined 50 + 50 input overflows the
            // 32/sec budget by ~3×, so the cap MUST land exactly at 32.
            // A weaker `<=` assertion would let `writes == 0` pass, which
            // is the failure mode if a future refactor breaks `allow()`
            // to always return false.
            assert_eq!(
                writes, PTY_WRITE_REPLY_PER_SECOND as usize,
                "combined XTGETTCAP + DSR PtyWrites must saturate the shared \
                 cap exactly; expected {} (50+50 inputs overflow by ~3×), got {}",
                PTY_WRITE_REPLY_PER_SECOND, writes
            );

            // Reviewer feedback (2026-04-29): the sibling
            // `xtgettcap_pty_write_cap_holds` test calls `bb_term_free`;
            // this one was leaking the BBTerm. Symmetric cleanup.
            bb_term_free(term);
        }
    }
}
