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
// Submodules — extracted from the original monolith (REFACTOR.md Wave 1).
// Each is re-exported below so `blackbird_core::*` and the cbindgen header
// stay byte-identical.
// ---------------------------------------------------------------------------

mod event;
mod rate_limit;

pub use event::{BBEvent, BBEventCb, BBEventKind};
use rate_limit::*;

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
    /// Title/Bell tumbling windows (audit S1-002). Same UnsafeCell
    /// discipline as `slot`; accessed only inside the fire()/reset
    /// busy-guard scopes.
    title_rate: UnsafeCell<EventRateState>,
    bell_rate: UnsafeCell<EventRateState>,
    /// Coalesce-to-latest latch for rate-suppressed titles (review
    /// follow-up to audit S1-002). Title is last-writer-wins state: a
    /// plain drop of the NEWEST title in a burst left the window title
    /// pinned to the 32nd-of-window value — and nothing re-emits in the
    /// default configuration (the bundled shell integration sends no
    /// OSC 0/2), so the stale title persisted indefinitely. Suppressed
    /// titles overwrite this latch; `flush_suppressed_title` (called
    /// from `bb_term_input` after each chunk) re-attempts delivery, so
    /// the latest title lands on the first chunk after the window
    /// rolls — bounding the flood to its cap while preserving
    /// last-writer-wins correctness.
    suppressed_title: UnsafeCell<Option<String>>,
    /// One-shot breadcrumb latch for the first suppressed title
    /// (mirrors `osc133_rate_limited_logged`'s stance).
    title_suppressed_logged: UnsafeCell<bool>,
    #[cfg(debug_assertions)]
    busy: std::sync::atomic::AtomicBool,
}

/// RAII overlap detector for the `UnsafeCell`-backed FFI cells. In
/// debug builds `enter` panics when the flag is already held — i.e.
/// another thread is INSIDE the cell right now (serialized access from
/// different threads never trips it); in release it is a zero-sized
/// no-op. The type exists in BOTH configurations with the same
/// signature (review follow-up to audit S1-004) so guard extents read
/// identically in release control flow and `drop(guard)` works
/// un-cfg'd; `#[must_use]` stops a bare `self.debug_enter();`
/// statement from silently discarding the guard and disabling
/// detection for the scope it meant to protect.
#[cfg(debug_assertions)]
#[must_use]
struct DebugBusyGuard<'a>(&'a std::sync::atomic::AtomicBool);

#[cfg(not(debug_assertions))]
#[must_use]
struct DebugBusyGuard<'a>(std::marker::PhantomData<&'a ()>);

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

// Empty Drop keeps release-mode `drop(guard)` clippy-clean
// (drop_non_drop) and compiles to nothing.
#[cfg(not(debug_assertions))]
impl Drop for DebugBusyGuard<'_> {
    fn drop(&mut self) {}
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
            title_rate: UnsafeCell::new(EventRateState::new(
                TITLE_EVENT_PER_SECOND,
                EVENT_RATE_WINDOW,
            )),
            bell_rate: UnsafeCell::new(EventRateState::new(
                BELL_EVENT_PER_SECOND,
                EVENT_RATE_WINDOW,
            )),
            suppressed_title: UnsafeCell::new(None),
            title_suppressed_logged: UnsafeCell::new(false),
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
    fn debug_enter(&self) -> DebugBusyGuard<'_> {
        DebugBusyGuard(std::marker::PhantomData)
    }

    /// Reset the Title/Bell sliding windows so a pre-clear flood does
    /// not strand the post-clear session's budget. Mirrors the PtyWrite
    /// reset on `bb_term_clear_all` (audit H-3); added with the caps in
    /// audit S1-002.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn reset_event_rates(&self) {
        let _busy = self.debug_enter();
        *self.title_rate.get() = EventRateState::new(TITLE_EVENT_PER_SECOND, EVENT_RATE_WINDOW);
        *self.bell_rate.get() = EventRateState::new(BELL_EVENT_PER_SECOND, EVENT_RATE_WINDOW);
    }

    /// Re-attempt delivery of a rate-suppressed title (see
    /// `suppressed_title`). Called from `bb_term_input` after each
    /// chunk's parser drains — outside any alacritty borrow and outside
    /// handler dispatch. If the window is still saturated, `fire`
    /// re-latches the same title; once it rolls, the latest title is
    /// delivered exactly once.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn flush_suppressed_title(&self) {
        let pending = {
            let _busy = self.debug_enter();
            (*self.suppressed_title.get()).take()
        };
        let Some(title) = pending else { return };
        let bytes = title.as_bytes();
        self.fire(BBEvent {
            kind: BBEventKind::Title,
            payload: bytes.as_ptr(),
            len: bytes.len(),
            i32_arg: 0,
        });
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
        if matches!(event.kind, BBEventKind::Title) {
            if (*self.title_rate.get()).allow() {
                // An admitted title supersedes anything latched.
                *self.suppressed_title.get() = None;
            } else {
                // Coalesce-to-latest instead of dropping: keep the
                // NEWEST suppressed title for redelivery once the
                // window rolls (see `suppressed_title`).
                let bytes = if event.payload.is_null() || event.len == 0 {
                    &[][..]
                } else {
                    std::slice::from_raw_parts(event.payload, event.len)
                };
                *self.suppressed_title.get() = Some(String::from_utf8_lossy(bytes).into_owned());
                if !*self.title_suppressed_logged.get() {
                    *self.title_suppressed_logged.get() = true;
                    eprintln!(
                        "[blackbird_core] Title event rate cap ({TITLE_EVENT_PER_SECOND}/s) \
                         engaged — coalescing to latest. One-shot per session."
                    );
                }
                return;
            }
        }
        if matches!(event.kind, BBEventKind::Bell) && !(*self.bell_rate.get()).allow() {
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
    fn debug_enter(&self) -> DebugBusyGuard<'_> {
        DebugBusyGuard(std::marker::PhantomData)
    }

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

/// Maximum byte length of a single OSC 7 URL accepted for percent-decode
/// (audit L-20, 2026-04-29). OSC 8's `OSC8_URI_MAX` is 4096 by the same
/// reasoning: a legitimate `file://` URL for a cwd is at most a few
/// hundred bytes; oversized payloads are either malicious spam or a
/// bug, and the unbounded `Vec::with_capacity(bytes.len())` inside
/// `percent_decode` would otherwise let a remote allocate megabytes per
/// OSC 7 chunk.
const OSC7_URL_MAX: usize = 4096;

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
    /// further up in any later snapshot.
    ///
    /// Scope of the algebra (review-tightened): it is reliable for
    /// content that scrolls toward history via ordinary full-width
    /// output flow. Content still in the VIEWPORT can additionally be
    /// moved by operations this counter does not see — reverse index /
    /// CSI T at the top of the screen (`scroll_down`), IL/DL, and
    /// DECSTBM scroll-region rotations — so anchors to viewport rows
    /// drift under full-screen TUI redraws (shell prompt flows don't
    /// use these). Invalidation rules for consumers:
    /// - ANY resize (either axis) invalidates all anchors.
    /// - Clears are PTY-initiated and not separately signalled; detect
    ///   them by `history_size` shrinking between snapshots (ED 3 /
    ///   RIS reset history while this counter holds still) and drop
    ///   anchors then.
    /// - The counter never moves backward for a live handle.
    ///
    /// Appended at the struct tail to preserve existing field offsets
    /// (same rule as `history_size`). Audit S5-004/S5-005.
    pub lines_scrolled: u64,
    /// 1 when the cursor is parked ON the last written cell with
    /// alacritty's `input_needs_wrap` set — the input line exactly
    /// filled the row, so the shell's LOGICAL cursor position is one
    /// character PAST `cursor_col` even though the grid cursor hasn't
    /// wrapped yet. Grid state alone cannot distinguish this from a
    /// cursor legitimately sitting on a character (e.g. after
    /// arrow-left); consumers doing character-position math (the
    /// find-replace splice) need this bit. Audit S5-003 review
    /// follow-up. Appended at the tail per the ABI-evolution rule.
    pub cursor_pending_wrap: u8,
    pub _pad3: [u8; 7],
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
        cursor_pending_wrap: bool,
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
                cursor_pending_wrap: cursor_pending_wrap as u8,
                _pad3: [0; 7],
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
        let cursor_pending_wrap = grid.cursor.input_needs_wrap;
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
            cursor_pending_wrap,
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
        // Expose the public `snap` field (first field at offset 0). Cast the
        // BBSnapOwned pointer rather than forming `&(*owned_ptr).snap`: snap is
        // the first `#[repr(C)]` field (identical address), but a `&BBSnap`
        // reference would narrow the Stacked/Tree Borrows tag to snap's extent
        // [0x0..size_of::<BBSnap>()), making the later `rc` access in
        // bb_snap_retain / bb_snap_release (a field PAST snap) an out-of-range
        // retag → UB. The pointer cast preserves provenance over the whole
        // allocation, so the rc field is legally reachable. (miri H-5 surface.)
        let owned_ptr = Box::into_raw(owned);
        owned_ptr as *const BBSnap
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
mod tests;
