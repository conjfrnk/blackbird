//! H-5 (audit 2026-05-03) — `FFI_HANDLER_IN_FLIGHT` re-entry coverage.
//!
//! `bb_term_input` was the only entry point that consulted the
//! `FFI_HANDLER_IN_FLIGHT` thread-local before reborrowing `&mut *term`
//! (audit M-9). Every other entry that takes `*mut BBTerm` and reborrows
//! the alacritty `Term` was a latent UB hole: a misbehaving callback that
//! synchronously called e.g. `bb_term_clear_all` while `bb_term_input`'s
//! `processor.advance(&mut bb.term, …)` was still on stack would alias
//! `&mut Term`. H-5 extended the same gate to the rest of the FFI surface.
//!
//! These tests pin the post-fix behaviour: each protected entry called
//! from inside a Bell callback must short-circuit (early-return the
//! documented panic-fallback value) and, critically, must NOT mutate the
//! aliased term. We can't assert "no UB" directly in Rust, but we can
//! assert "no observable side effect" — every outer-call invariant we
//! pre-arranged stays intact.
//!
//! Pre-flight: each test owns a single 20×5 BBTerm, no large allocations,
//! no spawned threads. ~50 KiB peak, ~1 ms wall-clock per test.
//!
//! These tests intentionally do NOT exercise re-entry into `bb_term_input`
//! — that case is already covered by the in-crate test
//! `tests::input_does_not_reenter_from_inside_event_handler`.
//!
//! ## H-5 miri surface — CLEAN under Stacked + Tree Borrows (2026-06-20)
//!
//! These tests run under miri (`cargo +nightly miri test`). Two things make
//! the FFI re-entry surface borrow-stack clean:
//!   1. Every guarded FFI entry checks the `FFI_HANDLER_IN_FLIGHT` latch via
//!      `ffi_reentry_blocked` (a thread-local read, NO `*term` deref) and
//!      bails BEFORE materialising `&mut *term` / `&*term`, so a re-entrant
//!      call never takes a second borrow that aliases the outer
//!      `bb_term_input`'s tag.
//!   2. `bb_term_take_snapshot` returns the snapshot handle by casting the
//!      `BBSnapOwned` box pointer (`owned_ptr as *const BBSnap`) instead of
//!      forming `&(*owned_ptr).snap`, which had narrowed the borrow-stack tag
//!      to the snap field's extent and made the `rc` field access in
//!      `bb_snap_retain` / `bb_snap_release` an out-of-range retag → UB. (That
//!      was the actual UB miri flagged; see core/src/lib.rs comment.)
//!
//! The non-miri runs on every PR continue to pin the runtime invariants
//! (no observable mutation, no crash, documented fallback returned).

use std::os::raw::c_void;
use std::sync::Mutex;

use blackbird_core as bc;

/// State shared between the test body and the C callback. Holds the term
/// pointer so the callback can re-enter, plus a flag to ensure we only
/// re-enter ONCE per Bell (the latch makes recursion a no-op anyway, but
/// double-calling pollutes the assertion).
struct ReentryState {
    term: *mut bc::BBTerm,
    fired: Mutex<u32>,
    inner_result: Mutex<InnerResult>,
}
// SAFETY: the test holds the term on a single thread and the callback is
// invoked synchronously from `bb_term_input` on that same thread. The
// Mutex is for &mut access discipline through &State, not for cross-thread
// sharing.
unsafe impl Send for ReentryState {}
unsafe impl Sync for ReentryState {}

/// Captures whatever the inner protected call returned, so the test body
/// can pin "the early-return path produced the documented fallback value".
#[derive(Default, Clone, Copy)]
struct InnerResult {
    snapshot_ptr_was_null: bool,
    snapshot_called: bool,
    mode_value: u32,
    mode_called: bool,
    text_range_was_null: bool,
    text_range_called: bool,
    resize_applied: (u16, u16),
    resize_called: bool,
}

/// Drive a single re-entry attempt. The callback runs `inner` once when
/// it sees the first Bell event; subsequent Bells (defended against by
/// the latch but not assumed) are ignored. Returns `(captured_inner_result,
/// outer_x_intact)`: the test body uses the captured result to pin the
/// inner call's documented fallback return, and `outer_x_intact` to pin
/// "the re-entered call did not actually mutate the aliased term".
fn run_and_capture<F>(inner: F) -> (InnerResult, bool)
where
    F: Fn(&ReentryState) + Send + Sync + 'static,
{
    let state = Box::into_raw(Box::new(ReentryState {
        term: std::ptr::null_mut(),
        fired: Mutex::new(0),
        inner_result: Mutex::new(InnerResult::default()),
    }));

    type InnerFn = Box<dyn Fn(&ReentryState) + Send + Sync>;
    thread_local! {
        static CB_INNER: std::cell::RefCell<Option<InnerFn>> =
            const { std::cell::RefCell::new(None) };
    }
    CB_INNER.with(|c| {
        *c.borrow_mut() = Some(Box::new(inner));
    });

    unsafe extern "C" fn cb(ev: bc::BBEvent, ctx: *mut c_void) {
        if ev.kind != bc::BBEventKind::Bell {
            return;
        }
        let state = unsafe { &*(ctx as *const ReentryState) };
        let mut fired = state.fired.lock().unwrap();
        if *fired > 0 {
            return;
        }
        *fired += 1;
        drop(fired);
        CB_INNER.with(|c| {
            if let Some(f) = c.borrow().as_ref() {
                f(state);
            }
        });
    }

    let result;
    let outer_x_intact;
    unsafe {
        let term = bc::bb_term_new(20, 5, 100);
        assert!(!term.is_null());
        bc::bb_term_input(term, b"X".as_ptr(), 1);
        (*state).term = term;
        bc::bb_term_set_event_cb(term, Some(cb), state as *mut c_void);

        let bel: u8 = 0x07;
        bc::bb_term_input(term, &bel as *const u8, 1);

        // Capture the inner result snapshot before tearing down state.
        result = *(*state).inner_result.lock().unwrap();

        // Snapshot the grid AFTER the BEL+callback round-trip so we can
        // verify the prearranged "X" survived any re-entered mutator.
        // Note: this snapshot call happens from outside any callback, so
        // the latch is clear — this taps the cell content directly.
        let snap = bc::bb_term_take_snapshot(term);
        let cols = (*snap).cols;
        let cell0 = *((*snap).cells.add(0));
        outer_x_intact = cols >= 1 && cell0.ch == b'X' as u32;
        bc::bb_snap_release(snap);

        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);
        drop(Box::from_raw(state));
    }
    CB_INNER.with(|c| {
        *c.borrow_mut() = None;
    });
    (result, outer_x_intact)
}

#[test]
fn clear_all_inside_callback_does_not_alias_term() {
    // The re-entered `bb_term_clear_all` would otherwise wipe the prearranged
    // 'X' AND alias `&mut Term` with the outer `bb_term_input`'s borrow.
    // With the H-5 fix both effects are suppressed.
    let (_, outer_x_intact) = run_and_capture(|state| unsafe {
        bc::bb_term_clear_all(state.term);
    });
    assert!(
        outer_x_intact,
        "re-entered bb_term_clear_all must be short-circuited; the \
         prearranged 'X' was wiped, indicating either the latch failed \
         or the inner clear ran (UB)"
    );
}

#[test]
fn take_snapshot_inside_callback_returns_null() {
    let (result, outer_x_intact) = run_and_capture(|state| unsafe {
        let snap = bc::bb_term_take_snapshot(state.term);
        let mut r = state.inner_result.lock().unwrap();
        r.snapshot_called = true;
        r.snapshot_ptr_was_null = snap.is_null();
        // We don't release a real snapshot here — it's null by contract.
        // The defensive guard: bb_snap_release tolerates null.
        bc::bb_snap_release(snap);
    });
    assert!(result.snapshot_called, "test plumbing");
    assert!(
        result.snapshot_ptr_was_null,
        "re-entered bb_term_take_snapshot must return null (the documented \
         panic-fallback) instead of taking a real snapshot under an aliased \
         &mut Term"
    );
    assert!(outer_x_intact, "outer 'X' state must not change");
}

#[test]
fn current_mode_inside_callback_returns_zero() {
    let (result, outer_x_intact) = run_and_capture(|state| unsafe {
        let m = bc::bb_term_current_mode(state.term);
        let mut r = state.inner_result.lock().unwrap();
        r.mode_called = true;
        r.mode_value = m;
    });
    assert!(result.mode_called, "test plumbing");
    assert_eq!(
        result.mode_value, 0,
        "re-entered bb_term_current_mode must return 0 (the documented \
         null-fallback) instead of reading the term under an aliased \
         &Term"
    );
    assert!(outer_x_intact, "outer 'X' state must not change");
}

#[test]
fn text_range_inside_callback_returns_null() {
    let (result, outer_x_intact) = run_and_capture(|state| unsafe {
        let s = bc::bb_term_text_range(state.term, 0, 0, 0, 0, 0);
        let mut r = state.inner_result.lock().unwrap();
        r.text_range_called = true;
        r.text_range_was_null = s.is_null();
        bc::bb_string_release(s); // tolerates null
    });
    assert!(result.text_range_called, "test plumbing");
    assert!(
        result.text_range_was_null,
        "re-entered bb_term_text_range must return null (the documented \
         panic-fallback) instead of allocating a BBString while aliasing \
         the outer &Term"
    );
    assert!(outer_x_intact, "outer 'X' state must not change");
}

#[test]
fn resize2_inside_callback_returns_zeroed_result() {
    let (result, outer_x_intact) = run_and_capture(|state| unsafe {
        let r = bc::bb_term_resize2(state.term, 40, 10);
        let mut g = state.inner_result.lock().unwrap();
        g.resize_called = true;
        g.resize_applied = (r.applied_cols, r.applied_rows);
    });
    assert!(result.resize_called, "test plumbing");
    assert_eq!(
        result.resize_applied,
        (0, 0),
        "re-entered bb_term_resize2 must return the documented \
         BBResizeResult{{0,0,0,...}} fallback instead of running a real \
         resize against an aliased &mut Term (got {:?})",
        result.resize_applied
    );
    assert!(outer_x_intact, "outer 'X' state must not change");
}

#[test]
fn scroll_apis_inside_callback_are_silently_dropped() {
    // No observable return value; we just verify the calls don't crash
    // and that the outer 'X' invariant survives. With the latch off
    // (pre-fix) the inner mutators would alias &mut Term — UB. The
    // assertion here is "the test runs to completion".
    let (_, outer_x_intact) = run_and_capture(|state| unsafe {
        bc::bb_term_scroll(state.term, 1);
        bc::bb_term_scroll_to_bottom(state.term);
        bc::bb_term_set_named_color(state.term, 0, 0xFF00FF);
        bc::bb_term_set_color_query_enabled(state.term, 1);
        // bb_term_set_event_cb to None would be especially nasty:
        // it'd clear the very callback we're inside. Verify the latch
        // protects that path too.
        bc::bb_term_set_event_cb(state.term, None, std::ptr::null_mut());
    });
    assert!(
        outer_x_intact,
        "after several latched mutator calls, outer 'X' must survive — \
         any change here means the latch let one through"
    );
}

// ---------------------------------------------------------------------------
// Sibling check: the latch is RAII, not sticky. After the callback returns,
// a follow-up entry point from outside the callback must run normally.
// ---------------------------------------------------------------------------

#[test]
fn entry_points_resume_after_callback_returns() {
    let (_, _) = run_and_capture(|state| unsafe {
        // Just touch a latched entry; doesn't matter that it short-circuits.
        bc::bb_term_clear_all(state.term);
    });
    // Now from main test thread (no callback on stack), every entry point
    // should run normally. The simplest probe: bb_term_take_snapshot must
    // return non-null on a fresh, non-null term.
    unsafe {
        let term = bc::bb_term_new(20, 5, 100);
        assert!(!term.is_null());
        let snap = bc::bb_term_take_snapshot(term);
        assert!(
            !snap.is_null(),
            "post-callback bb_term_take_snapshot must succeed — RAII drop \
             of HandlerInFlightGuard left the latch sticky"
        );
        bc::bb_snap_release(snap);

        let m = bc::bb_term_current_mode(term);
        // Default term has at least *some* default mode bits set
        // (alacritty enables LINE_WRAP and similar by default), so a 0
        // return here would indicate the latch leaked.
        assert!(
            m != 0,
            "post-callback bb_term_current_mode returned 0 — likely the \
             FFI_HANDLER_IN_FLIGHT latch wasn't cleared on guard drop"
        );

        bc::bb_term_free(term);
    }
}
