//! The C-callback dispatch machinery: `CallbackCell` (the interior-mutable
//! slot shared between `BBTerm` and its `RoutingListener`), the deferred
//! `ColorRequestQueue` for OSC 10/11/12 replies, and `RoutingListener` itself
//! (the alacritty `EventListener` that scrubs/rate-limits/forwards events).
//! Moved out of the monolith verbatim (REFACTOR.md Wave 1); behavior unchanged.

use std::cell::UnsafeCell;
use std::os::raw::c_void;
use std::sync::Arc;

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::vte::ansi::Rgb;

use crate::event::{BBEvent, BBEventCb, BBEventKind};
use crate::rate_limit::{
    EventRateState, PtyWriteRateCell, BELL_EVENT_PER_SECOND, EVENT_RATE_WINDOW,
    TITLE_EVENT_PER_SECOND,
};
use crate::scrub::scrub_title_controls;
use crate::HandlerInFlightGuard;

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
pub(crate) struct CallbackCell {
    pub(crate) slot: UnsafeCell<(Option<BBEventCb>, *mut c_void)>,
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
    pub(crate) pty_write_rate: Arc<PtyWriteRateCell>,
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
pub(crate) struct DebugBusyGuard<'a>(&'a std::sync::atomic::AtomicBool);

#[cfg(not(debug_assertions))]
#[must_use]
pub(crate) struct DebugBusyGuard<'a>(std::marker::PhantomData<&'a ()>);

#[cfg(debug_assertions)]
impl<'a> DebugBusyGuard<'a> {
    pub(crate) fn enter(flag: &'a std::sync::atomic::AtomicBool, what: &str) -> Self {
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
    pub(crate) fn new(pty_write_rate: Arc<PtyWriteRateCell>) -> Self {
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
    pub(crate) unsafe fn reset_event_rates(&self) {
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
    pub(crate) unsafe fn flush_suppressed_title(&self) {
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
    pub(crate) unsafe fn set(&self, cb: Option<BBEventCb>, ctx: *mut c_void) {
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
    pub(crate) unsafe fn fire(&self, event: BBEvent) {
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
pub(crate) struct ColorRequestQueue {
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
pub(crate) const COLOR_REQUEST_QUEUE_CAP: usize = 256;

pub(crate) struct ColorRequestEntry {
    pub(crate) index: usize,
    pub(crate) formatter: Arc<dyn Fn(Rgb) -> String + Sync + Send>,
}

// SAFETY: the owning BBTerm is never shared across threads; same reasoning
// as CallbackCell.
unsafe impl Send for ColorRequestQueue {}
unsafe impl Sync for ColorRequestQueue {}

impl ColorRequestQueue {
    pub(crate) fn new() -> Self {
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
    pub(crate) unsafe fn push(&self, entry: ColorRequestEntry) -> bool {
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
    pub(crate) unsafe fn drain(&self) -> Vec<ColorRequestEntry> {
        let _busy = self.debug_enter();
        *self.cap_hit_logged.get() = false;
        std::mem::take(&mut *self.entries.get())
    }

    /// Number of currently-queued entries. Test-only introspection.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    #[cfg(test)]
    pub(crate) unsafe fn len(&self) -> usize {
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
pub(crate) struct RoutingListener {
    pub(crate) cell: Arc<CallbackCell>,
    pub(crate) color_queue: Arc<ColorRequestQueue>,
    // Audit H-4 (2026-04-29): the PtyWrite rate cap (32/sec, audit M1)
    // moved into `CallbackCell::fire` so all three dispatch paths
    // (this listener, `dispatch_xtgettcap`, `drain_color_requests`)
    // inherit it by construction. The shared `Arc<PtyWriteRateCell>`
    // now lives on `CallbackCell`; the listener doesn't need its own
    // reference because every send_event PtyWrite goes through
    // `self.cell.fire`.
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
