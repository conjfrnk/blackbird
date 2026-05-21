//! Audit #01 (2026-05-21) — `bb_term_free` re-entry from inside a user
//! event callback is a use-after-free.
//!
//! Scenario: the host registers a `BBEventCb` via `bb_term_set_event_cb`,
//! then calls `bb_term_input`. Alacritty's `processor.advance(&mut bb.term,
//! …)` synchronously fires a `Bell` event up through `RoutingListener`,
//! which invokes the C callback. If the callback calls `bb_term_free(term)`
//! at that point, the current implementation runs
//! `Box::from_raw(term); drop(...)` while `processor.advance`'s `&mut Term`
//! borrow is still live on the outer frame. Subsequent `processor.advance`
//! frames in the same input chunk — and `dispatch_xtgettcap` /
//! `drain_color_requests` operations that the outer `bb_term_input` performs
//! after `processor.advance` returns — then read/write freed memory. A
//! Phase-2 verifier observed SIGSEGV in this exact pattern 3/3 consecutive
//! runs on the current HEAD.
//!
//! The post-fix contract pinned by this test: `bb_term_free`, called from
//! inside an in-flight FFI handler, must be a no-op. The term stays alive
//! (a defensive leak, chosen over UAF), the outer `bb_term_input` returns
//! cleanly, and the term remains usable. A second `bb_term_free` call from
//! OUTSIDE the callback then frees the box exactly once.
//!
//! We can't directly assert "no UAF". Instead we pin observable invariants
//! that only hold if the in-callback free was suppressed:
//!   1. `bb_term_input` completes without aborting the process.
//!   2. After the input returns, `bb_term_take_snapshot` on the same term
//!      yields a non-null snapshot whose cols/rows match construction —
//!      a freed box would not.
//!   3. `bb_term_current_mode` on the same term returns a non-zero mode
//!      bitset (alacritty enables `LINE_WRAP` and friends by default), so
//!      a zero return would indicate either the box was freed or the
//!      re-entry latch leaked. (Either way, the fix isn't right.)
//!   4. The final, OUTSIDE-the-callback `bb_term_free` succeeds — the
//!      in-callback call must NOT have already consumed the box, or this
//!      second free would be a double-free.
//!
//! ## Expected pre-fix behaviour
//!
//! On current HEAD this test SIGSEGVs inside `bb_term_input` after the
//! callback re-enters `bb_term_free`. `cargo test` reports the test as
//! a signal-killed failure. Once `bb_term_free` consults the
//! `FFI_HANDLER_IN_FLIGHT` latch (or equivalent) and short-circuits when
//! a handler is on the stack, every assertion below holds.
//!
//! ## miri
//!
//! `#[cfg_attr(miri, ignore)]` for the same reason as
//! `handler_reentry_guard.rs`: H-5 detects the &mut materialisation that
//! precedes the latch check, which is a separate, deferred class of UB
//! (KNOWN_ISSUES tracks it as a v1.0 hardening follow-up). Non-miri
//! `cargo test` runs continue to pin the runtime invariant here.
//!
//! Pre-flight budget: one 20×5 BBTerm, no large allocations, no spawned
//! threads, no scrollback fill. Peak ~20 KiB, wall-clock ~1 ms.

use std::os::raw::c_void;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};

use blackbird_core as bc;

/// State shared between the test body and the C callback. Owns the term
/// pointer (so the callback can re-enter) and a one-shot latch so we only
/// fire the inner free on the FIRST Bell — subsequent Bells (and the
/// Title/PtyWrite events the post-fix path might emit) must not retrigger.
struct State {
    term: AtomicPtr<bc::BBTerm>,
    freed: AtomicBool,
}
// SAFETY: the test owns the term on a single thread; the callback runs
// synchronously from `bb_term_input` on that same thread. The atomics are
// used for &State discipline, not for cross-thread sharing.
unsafe impl Send for State {}
unsafe impl Sync for State {}

unsafe extern "C" fn cb(ev: bc::BBEvent, ctx: *mut c_void) {
    if ev.kind != bc::BBEventKind::Bell {
        return;
    }
    // SAFETY: ctx is the State* we registered in `bb_term_set_event_cb`
    // below; it lives for the duration of the test.
    let state = unsafe { &*(ctx as *const State) };
    if state.freed.swap(true, Ordering::SeqCst) {
        return;
    }
    let term = state.term.load(Ordering::SeqCst);
    // SAFETY: pre-fix this is the UAF — `bb_term_free` drops the Box
    // while the outer `bb_term_input`'s `&mut Term` borrow is still live.
    // Post-fix this is a documented no-op when a handler is on the stack.
    unsafe { bc::bb_term_free(term) };
}

#[test]
#[cfg_attr(miri, ignore)] // PRODUCT-BUG: see file header (H-5 &mut materialisation precedes the proposed latch check)
fn free_inside_bell_callback_is_a_noop_and_term_stays_usable() {
    // SAFETY: every FFI call below operates on a single-threaded BBTerm
    // we own for the duration of this test; pointers are non-null where
    // required by the FFI contract.
    unsafe {
        let term = bc::bb_term_new(20, 5, 100);
        assert!(!term.is_null(), "test plumbing: bb_term_new returned null");

        let state = Box::into_raw(Box::new(State {
            term: AtomicPtr::new(term),
            freed: AtomicBool::new(false),
        }));

        bc::bb_term_set_event_cb(term, Some(cb), state as *mut c_void);

        // BEL (0x07) fires `BBEventKind::Bell` synchronously from inside
        // alacritty's `processor.advance`, which is the in-flight handler
        // frame we need on the stack when the callback re-enters
        // `bb_term_free`.
        let bel: u8 = 0x07;
        bc::bb_term_input(term, &bel as *const u8, 1);

        // Invariant 1: the callback fired (otherwise we proved nothing).
        assert!(
            (*state).freed.load(Ordering::SeqCst),
            "Bell callback never fired — test plumbing failed before \
             exercising the re-entry path"
        );

        // Invariant 2: term is still usable. A freed box would either
        // crash here or return null/garbage.
        let snap = bc::bb_term_take_snapshot(term);
        assert!(
            !snap.is_null(),
            "bb_term_take_snapshot returned null after the in-callback \
             bb_term_free — either the term was actually freed (UAF \
             elsewhere) or the FFI re-entry latch leaked"
        );
        assert_eq!(
            (*snap).cols,
            20,
            "snapshot cols mismatch after in-callback bb_term_free — \
             memory was reused"
        );
        assert_eq!(
            (*snap).rows,
            5,
            "snapshot rows mismatch after in-callback bb_term_free — \
             memory was reused"
        );
        bc::bb_snap_release(snap);

        // Invariant 3: default mode bits remain set. alacritty enables
        // LINE_WRAP and similar by default; a 0 return would imply the
        // term was freed (we'd be reading scrubbed memory) or the latch
        // wasn't dropped after the callback returned.
        let mode = bc::bb_term_current_mode(term);
        assert!(
            mode != 0,
            "bb_term_current_mode returned 0 after in-callback \
             bb_term_free — expected default mode bitset to remain set"
        );

        // Invariant 4: the OUTSIDE-the-callback free must succeed without
        // a double-free panic. If the in-callback free had actually run,
        // this would be UB (or, with the catch_unwind in `bb_term_free`,
        // would swallow a double-free panic silently — but the prior
        // invariants would have already failed).
        bc::bb_term_set_event_cb(term, None, std::ptr::null_mut());
        bc::bb_term_free(term);

        // Tear down the State box we owned via Box::into_raw.
        drop(Box::from_raw(state));
    }
}
