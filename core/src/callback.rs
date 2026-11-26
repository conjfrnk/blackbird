use std::cell::UnsafeCell;
use std::os::raw::c_void;
use std::sync::Arc;

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::vte::ansi::Rgb;

use crate::diag::breadcrumb;
use crate::event::{BBEvent, BBEventCb, BBEventKind};
use crate::guard::HandlerInFlightGuard;
use crate::rate_limit::{
    EventRateState, PtyWriteRateCell, BELL_EVENT_PER_SECOND, EVENT_RATE_WINDOW,
    NOTIFICATION_EVENT_PER_SECOND, OSC52_EVENT_PER_SECOND, TITLE_EVENT_PER_SECOND,
};
use crate::scrub::scrub_title_controls;

/// Sound only because the FFI contract forbids concurrent calls on one `term` handle. The debug
/// `busy` flag detects OVERLAPPING access, not thread identity: a serial queue has no fixed thread.
pub(crate) struct CallbackCell {
    pub(crate) slot: UnsafeCell<(Option<BBEventCb>, *mut c_void)>,
    /// Gated in `fire`, so every PtyWrite path inherits the cap.
    pub(crate) pty_write_rate: Arc<PtyWriteRateCell>,
    title_rate: UnsafeCell<EventRateState>,
    bell_rate: UnsafeCell<EventRateState>,
    notification_rate: UnsafeCell<EventRateState>,
    osc52_rate: UnsafeCell<EventRateState>,
    /// Latest rate-suppressed title (last-writer-wins), redelivered by `flush_suppressed_title`.
    suppressed_title: UnsafeCell<Option<String>>,
    /// Same latch for OSC 52 writes. The Swift side also flushes it from a timer: a write that
    /// waited for the next input chunk could overwrite what the user copied in the meantime.
    suppressed_osc52: UnsafeCell<Option<String>>,
    title_suppressed_logged: UnsafeCell<bool>,
    notification_suppressed_logged: UnsafeCell<bool>,
    #[cfg(debug_assertions)]
    busy: std::sync::atomic::AtomicBool,
}

/// Overlap detector: `enter` panics in debug builds when the flag is held; a no-op in release.
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

// Empty Drop keeps release-mode `drop(guard)` clippy-clean (drop_non_drop).
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
            notification_rate: UnsafeCell::new(EventRateState::new(
                NOTIFICATION_EVENT_PER_SECOND,
                EVENT_RATE_WINDOW,
            )),
            osc52_rate: UnsafeCell::new(EventRateState::new(
                OSC52_EVENT_PER_SECOND,
                EVENT_RATE_WINDOW,
            )),
            suppressed_title: UnsafeCell::new(None),
            suppressed_osc52: UnsafeCell::new(None),
            title_suppressed_logged: UnsafeCell::new(false),
            notification_suppressed_logged: UnsafeCell::new(false),
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

    /// # Safety
    /// Caller must ensure no concurrent access.
    pub(crate) unsafe fn reset_event_rates(&self) {
        let _busy = self.debug_enter();
        *self.title_rate.get() = EventRateState::new(TITLE_EVENT_PER_SECOND, EVENT_RATE_WINDOW);
        *self.bell_rate.get() = EventRateState::new(BELL_EVENT_PER_SECOND, EVENT_RATE_WINDOW);
        *self.notification_rate.get() =
            EventRateState::new(NOTIFICATION_EVENT_PER_SECOND, EVENT_RATE_WINDOW);
        *self.osc52_rate.get() = EventRateState::new(OSC52_EVENT_PER_SECOND, EVENT_RATE_WINDOW);
        // A latched pre-clear clipboard payload must not land on the clipboard after a reset.
        *self.suppressed_osc52.get() = None;
    }

    /// # Safety
    /// No concurrent access; call outside any alacritty borrow and outside handler dispatch.
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
            cursor_row: 0,
            lines_scrolled: 0,
        });
    }

    /// Returns the wait until the cap's window rolls while a write is held back, else `None`.
    ///
    /// # Safety
    /// Same contract as `flush_suppressed_title`.
    pub(crate) unsafe fn flush_suppressed_osc52(&self) -> Option<std::time::Duration> {
        let pending = {
            let _busy = self.debug_enter();
            (*self.suppressed_osc52.get()).as_ref()?;
            if let Some(wait) = (*self.osc52_rate.get()).retry_after() {
                return Some(wait);
            }
            (*self.suppressed_osc52.get()).take()
        };
        let text = pending?;
        let bytes = text.as_bytes();
        self.fire(BBEvent {
            kind: BBEventKind::Osc52Clipboard,
            payload: bytes.as_ptr(),
            len: bytes.len(),
            i32_arg: 0,
            cursor_row: 0,
            lines_scrolled: 0,
        });
        None
    }

    /// # Safety
    /// Caller must ensure no concurrent access.
    pub(crate) unsafe fn set(&self, cb: Option<BBEventCb>, ctx: *mut c_void) {
        let _busy = self.debug_enter();
        *self.slot.get() = (cb, ctx);
    }

    /// Dropped PtyWrites are silent BY DESIGN: logging each drop would itself amplify a flood.
    ///
    /// # Safety
    /// No concurrent access; the `BBEvent` fields must be valid for the duration of the call.
    pub(crate) unsafe fn fire(&self, event: BBEvent) {
        // Enforce `payload == NULL ⇔ len == 0`: an empty slice's `as_ptr()` is non-null.
        let mut event = event;
        if event.len == 0 {
            event.payload = std::ptr::null();
        }
        // The overlap guard must end BEFORE the callback runs: a nested dispatch must not trip it.
        let _busy = self.debug_enter();
        // Read the slot FIRST: with no callback registered, an event must not consume rate budget.
        let (cb, ctx) = *self.slot.get();
        let Some(f) = cb else {
            return;
        };
        if matches!(event.kind, BBEventKind::PtyWrite) && !self.pty_write_rate.allow() {
            return;
        }
        if matches!(event.kind, BBEventKind::Title) {
            if (*self.title_rate.get()).allow() {
                *self.suppressed_title.get() = None;
            } else {
                let bytes = if event.payload.is_null() || event.len == 0 {
                    &[][..]
                } else {
                    std::slice::from_raw_parts(event.payload, event.len)
                };
                *self.suppressed_title.get() = Some(String::from_utf8_lossy(bytes).into_owned());
                if !*self.title_suppressed_logged.get() {
                    *self.title_suppressed_logged.get() = true;
                    breadcrumb!(
                        "[blackbird_core] Title event rate cap ({TITLE_EVENT_PER_SECOND}/s) \
                         engaged — coalescing to latest. One-shot per session."
                    );
                }
                return;
            }
        }
        if matches!(event.kind, BBEventKind::Osc52Clipboard) {
            if (*self.osc52_rate.get()).allow() {
                *self.suppressed_osc52.get() = None;
            } else {
                let bytes = if event.payload.is_null() || event.len == 0 {
                    &[][..]
                } else {
                    std::slice::from_raw_parts(event.payload, event.len)
                };
                *self.suppressed_osc52.get() = Some(String::from_utf8_lossy(bytes).into_owned());
                return;
            }
        }
        if matches!(event.kind, BBEventKind::Bell) && !(*self.bell_rate.get()).allow() {
            return;
        }
        if matches!(event.kind, BBEventKind::Notification)
            && !(*self.notification_rate.get()).allow()
        {
            if !*self.notification_suppressed_logged.get() {
                *self.notification_suppressed_logged.get() = true;
                breadcrumb!(
                    "[blackbird_core] notification rate cap ({NOTIFICATION_EVENT_PER_SECOND}/s) hit; further notifications this second dropped (logged once)"
                );
            }
            return;
        }
        // Lets a callback's synchronous re-entry into `bb_term_*` bail BEFORE reborrowing `Term`.
        drop(_busy);
        let _handler_guard = HandlerInFlightGuard::enter();
        f(event, ctx);
    }
}

/// `Event::ColorRequest` fires while alacritty holds `&mut Term`, so entries park here until the
/// drain after `processor.advance` returns. Same access discipline as `CallbackCell`.
pub(crate) struct ColorRequestQueue {
    entries: UnsafeCell<Vec<ColorRequestEntry>>,
    cap_hit_logged: UnsafeCell<bool>,
    #[cfg(debug_assertions)]
    busy: std::sync::atomic::AtomicBool,
}

/// Upper bound on queued `ColorRequestEntry`s between two drains.
pub(crate) const COLOR_REQUEST_QUEUE_CAP: usize = 256;

pub(crate) struct ColorRequestEntry {
    pub(crate) index: usize,
    /// The slot's program-set value when the query was parsed, not when it is drained.
    pub(crate) current: Option<Rgb>,
    pub(crate) formatter: Arc<dyn Fn(Rgb) -> String + Sync + Send>,
}

// SAFETY: the owning BBTerm is never shared across threads; same reasoning as CallbackCell.
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

    /// # Safety
    /// Caller must ensure no concurrent access.
    pub(crate) unsafe fn push(&self, entry: ColorRequestEntry) -> bool {
        let _busy = self.debug_enter();
        let vec = &mut *self.entries.get();
        if vec.len() >= COLOR_REQUEST_QUEUE_CAP {
            let logged = &mut *self.cap_hit_logged.get();
            if !*logged {
                *logged = true;
                breadcrumb!(
                    "blackbird_core: ColorRequestQueue hit cap ({COLOR_REQUEST_QUEUE_CAP}); \
                     further OSC 4/10/11/12 queries before the next drain dropped"
                );
            }
            return false;
        }
        vec.push(entry);
        true
    }

    /// # Safety
    /// Caller must ensure no concurrent access.
    pub(crate) unsafe fn drain(&self) -> Vec<ColorRequestEntry> {
        let _busy = self.debug_enter();
        *self.cap_hit_logged.get() = false;
        std::mem::take(&mut *self.entries.get())
    }

    /// # Safety
    /// Caller must ensure no concurrent access.
    #[cfg(test)]
    pub(crate) unsafe fn len(&self) -> usize {
        (*self.entries.get()).len()
    }
}

/// The `Arc`-shared cells stay live even if an event fires mid-teardown. Use only under the
/// owning `BBTerm`'s one-thread-at-a-time discipline.
pub(crate) struct RoutingListener {
    pub(crate) cell: Arc<CallbackCell>,
    pub(crate) color_queue: Arc<ColorRequestQueue>,
}

impl EventListener for RoutingListener {
    fn send_event(&self, event: Event) {
        // SAFETY: `cell` and `color_queue` remain live for as long as any Arc clone exists;
        // single-thread discipline means no concurrent access.
        unsafe {
            match event {
                Event::Bell => {
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Bell,
                        payload: std::ptr::null(),
                        len: 0,
                        i32_arg: 0,
                        cursor_row: 0,
                        lines_scrolled: 0,
                    });
                }
                Event::Title(ref s) => {
                    let scrubbed = scrub_title_controls(s);
                    let bytes = scrubbed.as_bytes();
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Title,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                        cursor_row: 0,
                        lines_scrolled: 0,
                    });
                }
                Event::ClipboardStore(_, ref s) => {
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Osc52Clipboard,
                        payload: s.as_ptr(),
                        len: s.len(),
                        i32_arg: 0,
                        cursor_row: 0,
                        lines_scrolled: 0,
                    });
                }
                Event::PtyWrite(ref s) => {
                    let bytes = s.as_bytes();
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::PtyWrite,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                        cursor_row: 0,
                        lines_scrolled: 0,
                    });
                }
                Event::ColorRequest(index, current, formatter) => {
                    // A push refused at the cap is dropped; `push` logs it once.
                    let _ = self.color_queue.push(ColorRequestEntry {
                        index,
                        current,
                        formatter,
                    });
                }
                // `ResetTitle` fires from `pop_title` (XTWINOPS 23) with no saved title and from
                // `set_title(None)`: forward a Title with an EMPTY payload to clear the OSC title.
                Event::ResetTitle => {
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Title,
                        payload: core::ptr::null(),
                        len: 0,
                        i32_arg: 0,
                        cursor_row: 0,
                        lines_scrolled: 0,
                    });
                }
                _ => {}
            }
        }
    }
}
