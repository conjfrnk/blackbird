//! The panic-catching + FFI re-entry guard machinery. Every extern "C" entry
//! routes its body through `guard_with_term`/`guard_no_term` so a core panic
//! becomes a `BBEventKind::Fatal` rather than UB across the C boundary (Part I
//! §2), and consults `ffi_reentry_blocked` before reborrowing `&mut Term` so a
//! callback that synchronously re-enters bails before aliasing (Part I §7).
//! Extracted from the monolith verbatim (REFACTOR.md Wave 1).

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Once;

use crate::{BBEvent, BBEventKind, BBTerm};

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
pub(crate) unsafe fn guard_with_term<T>(
    term: *mut BBTerm,
    fallback: T,
    f: impl FnOnce() -> T,
) -> T {
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
        eprintln!(
            "[blackbird_core] {entry} called from inside {path} — \
             dropping re-entrant call to avoid &mut Term alias. Audit H-5/fix-#09."
        );
    });
    true
}

/// Panic-swallowing guard for contexts where no `BBTerm` exists yet
/// (`bb_term_new`'s allocation path, `bb_term_free`'s destructor).
pub(crate) fn guard_no_term<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_payload) => fallback,
    }
}
