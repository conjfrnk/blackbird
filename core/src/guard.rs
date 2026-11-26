//! Panic-catching and FFI re-entry guards that every extern "C" entry routes through.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Once;

use crate::diag::breadcrumb;
use crate::{BBEvent, BBEventKind, BBTerm};

pub(crate) fn payload_to_string(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".to_string()
    }
}

/// A panic nested inside a Fatal dispatch on this thread is SWALLOWED, not re-dispatched: the
/// user callback is still on the stack (deadlock or unbounded recursion).
///
/// # Safety
/// `term` must be either null (no event delivery) or a valid `&*term` target.
pub(crate) unsafe fn guard_with_term<T>(
    term: *mut BBTerm,
    fallback: T,
    f: impl FnOnce() -> T,
) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(payload) => {
            if FFI_FATAL_IN_FLIGHT.with(|c| c.get()) {
                return fallback;
            }
            let _guard = FatalInFlightGuard::enter();
            if !term.is_null() {
                let bb = &*term;
                bb.poisoned.set(true);
                let msg = payload_to_string(&*payload);
                let (cb, ctx) = *bb.callback.slot.get();
                if let Some(cb) = cb {
                    let bytes = msg.as_bytes();
                    // Bypasses `CallbackCell::fire` (the cell may be mid-panic), so uphold
                    // `payload == NULL ⇔ len == 0` here.
                    let ev = BBEvent {
                        kind: BBEventKind::Fatal,
                        payload: if bytes.is_empty() {
                            std::ptr::null()
                        } else {
                            bytes.as_ptr()
                        },
                        len: bytes.len(),
                        i32_arg: 0,
                        cursor_row: 0,
                        lines_scrolled: 0,
                    };
                    // A panicking callback must not unwind across extern "C" (UB): catch and
                    // discard it.
                    let _ = catch_unwind(AssertUnwindSafe(|| cb(ev, ctx)));
                }
            }
            fallback
        }
    }
}

thread_local! {
    static FFI_FATAL_IN_FLIGHT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

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
    /// True while `CallbackCell::fire` runs the C callback on this thread. `ffi_reentry_blocked`
    /// must precede EVERY `*term` deref in an entry point, including the poison flag read.
    static FFI_HANDLER_IN_FLIGHT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

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

static HANDLER_REENTRY_LOGGED: Once = Once::new();

/// True when the calling entry point would alias the `&mut Term` an outer entry holds while it
/// dispatches an event, or the `&*term` the Fatal path holds outside `CallbackCell::fire`.
pub(crate) fn ffi_reentry_blocked(entry: &str) -> bool {
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
        breadcrumb!(
            "[blackbird_core] {entry} called from inside {path} — \
             dropping re-entrant call to avoid &mut Term alias. Audit H-5/fix-#09."
        );
    });
    true
}

pub(crate) fn guard_no_term<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_payload) => fallback,
    }
}
