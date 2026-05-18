//! Blind black-box tests for the snapshot ref-counting FFI.
//!
//! These tests are authored against `core/include/BBCore.h` only — no
//! implementation source was consulted. They verify the documented
//! contract for:
//!   - `bb_term_take_snapshot` (acquire, refcount = 1)
//!   - `bb_snap_retain`        (increment, returns input pointer, null = null)
//!   - `bb_snap_release`       (decrement; free at zero; null = no-op)
//!
//! Memory/time budget: every test runs in <100 ms and the per-iteration
//! work is tiny (80x24 grid, no I/O). The tight loops below are sized so
//! the whole file completes well under a few seconds in debug.
//!
//! The contract from the header (paraphrased):
//!   * `bb_snap_retain(null) == null`, no side effects.
//!   * `bb_snap_release(null)` is a no-op.
//!   * `bb_snap_retain(snap)` returns the exact input pointer.
//!   * Each acquire (take_snapshot OR retain) must be paired with one
//!     release; allocation is freed when the refcount hits zero.
//!   * Both retain/release are "safe to call from any thread".
//!   * `cells` is stable, non-null, and points to `cells_len` `BBCell`s
//!     for the snapshot's lifetime.
//!   * Panics in retain/release are caught and swallowed; fallback values
//!     are the input pointer (retain) and unit (release).

use blackbird_core::*;
use std::ffi::c_void;
use std::sync::Mutex;

/// Send/Sync wrapper around a raw snapshot pointer so we can hand it to
/// `std::thread::spawn`. The header documents retain/release as "safe to
/// call from any thread"; this wrapper just lets the borrow checker know.
///
/// We store the pointer as a `usize` so the inner type itself is `Send`
/// (raw pointers are `!Send`, and the auto-derived `Send` for a tuple
/// struct containing a `*const _` is what trips spawn). Converting back
/// to the pointer is a `as *const BBSnap` inside the closure.
#[derive(Copy, Clone)]
struct SnapPtr(usize);
impl SnapPtr {
    fn new(p: *const BBSnap) -> Self {
        SnapPtr(p as usize)
    }
    fn get(self) -> *const BBSnap {
        self.0 as *const BBSnap
    }
}

// --- shared sink / driver, modeled on tests/color_query.rs ---------------

#[derive(Default)]
struct Sink {
    events: Mutex<Vec<u32>>,
}

unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = &*(ctx as *const Sink);
    sink.events.lock().unwrap().push(ev.kind as u32);
}

/// Build a small terminal with an event callback wired up so we can assert
/// "no Fatal event fired" as a positive observation alongside null-safety.
unsafe fn make_term_with_sink(sink: &Sink) -> *mut BBTerm {
    let term = bb_term_new(80, 24, 1000);
    assert!(!term.is_null(), "bb_term_new(80,24,1000) must succeed");
    bb_term_set_event_cb(term, Some(cb), sink as *const _ as *mut c_void);
    term
}

fn fatal_count(sink: &Sink) -> usize {
    let fatal = BBEventKind::Fatal as u32;
    sink.events
        .lock()
        .unwrap()
        .iter()
        .filter(|k| **k == fatal)
        .count()
}

// --- 1. Null safety -----------------------------------------------------

#[test]
fn retain_null_returns_null_and_fires_no_events() {
    let sink = Sink::default();
    unsafe {
        let term = make_term_with_sink(&sink);
        let before = sink.events.lock().unwrap().len();

        let out = bb_snap_retain(std::ptr::null());
        assert!(out.is_null(), "retain(null) must return null");

        let after = sink.events.lock().unwrap().len();
        assert_eq!(
            before, after,
            "retain(null) must not fire any callback events"
        );
        bb_term_free(term);
    }
}

#[test]
fn release_null_is_noop_and_fires_no_events() {
    let sink = Sink::default();
    unsafe {
        let term = make_term_with_sink(&sink);
        let before = sink.events.lock().unwrap().len();

        // Multiple null-releases must all be safe.
        bb_snap_release(std::ptr::null());
        bb_snap_release(std::ptr::null());
        bb_snap_release(std::ptr::null());

        let after = sink.events.lock().unwrap().len();
        assert_eq!(
            before, after,
            "release(null) must not fire any callback events"
        );
        bb_term_free(term);
    }
}

// --- 2. Identity --------------------------------------------------------

#[test]
fn retain_returns_exact_input_pointer() {
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null(), "take_snapshot must yield non-null");

        let r1 = bb_snap_retain(snap);
        assert_eq!(r1, snap, "retain must return the input pointer verbatim");

        let r2 = bb_snap_retain(r1);
        assert_eq!(r2, snap, "retain is idempotent w.r.t. returned pointer");

        // 1 (acquire) + 2 (retain) = 3 releases.
        bb_snap_release(snap);
        bb_snap_release(snap);
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn snapshot_fields_match_terminal_dimensions() {
    // Vary dimensions across several configurations so a hardcoded
    // 80×24-returning impl would fail. Confirms snapshot copies the grid
    // shape correctly rather than echoing a baked default.
    for (cols, rows) in [(80u16, 24u16), (132, 40), (40, 12), (200, 60)] {
        unsafe {
            let term = bb_term_new(cols, rows, 1000);
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());

            assert_eq!(
                (*snap).cols,
                cols,
                "snapshot cols must echo bb_term_new dims ({cols}x{rows})"
            );
            assert_eq!(
                (*snap).rows,
                rows,
                "snapshot rows must echo bb_term_new dims ({cols}x{rows})"
            );
            assert_eq!(
                (*snap).cells_len,
                (cols as usize) * (rows as usize),
                "cells_len must equal cols*rows per header invariant ({cols}x{rows})"
            );
            assert!(!(*snap).cells.is_null(), "cells must be non-null for any snapshot");

            bb_snap_release(snap);
            bb_term_free(term);
        }
    }
}

// --- 3. Basic acquire/release pair --------------------------------------

#[test]
fn tight_acquire_release_loop_is_bounded() {
    // 10_000 iterations on an 80x24 grid; each snapshot must be released
    // exactly once. If the implementation leaks, this scales linearly and
    // the long-session memory gate would catch it; here we mostly assert
    // we complete inside the time budget without panicking.
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        for i in 0..10_000 {
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null(), "snapshot {i} returned null");
            bb_snap_release(snap);
        }
        bb_term_free(term);
    }
}

// --- 4. Retain/release balance ------------------------------------------

#[test]
fn retain_release_balanced_pairs_stay_bounded() {
    // refcount goes: 1 (take) → 2 (retain) → 1 (release) → 0 (release).
    // Between the two releases we dereference the snapshot's `cells_len` —
    // under ASan / MIRI, a retain that skipped its fetch_add would leave the
    // snapshot already-freed at this point (the first release would drop the
    // refcount 1→0 and free), making the read a UAF the sanitizer surfaces.
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        for i in 0..10_000 {
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null(), "snapshot {i} returned null");
            let r = bb_snap_retain(snap);
            assert_eq!(r, snap);
            bb_snap_release(snap); // refcount 2 → 1 — snapshot must remain alive.
            let cells_len_alive = (*snap).cells_len;
            assert_eq!(
                cells_len_alive,
                80 * 24,
                "snapshot must still be valid after a single release on refcount 2"
            );
            bb_snap_release(snap); // refcount 1 → 0, free.
        }
        bb_term_free(term);
    }
}

// --- 5. Multiple retains ------------------------------------------------

#[test]
fn five_retains_six_releases_per_snapshot_is_balanced() {
    // Between each release we read `cells_len`; the snapshot must stay live
    // until the final release drops the refcount to 0. Under ASan / MIRI,
    // any retain that secretly skipped its fetch_add would surface as a UAF
    // on the read after the first few releases.
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        for i in 0..1_000 {
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null(), "snapshot {i} returned null");

            // 5 retains → refcount 6.
            for _ in 0..5 {
                let r = bb_snap_retain(snap);
                assert_eq!(r, snap, "retain must return input pointer");
            }
            // 5 releases → refcount 1. Read between each to surface UAF if
            // the refcount got out of sync.
            for k in 0..5 {
                bb_snap_release(snap);
                assert_eq!(
                    (*snap).cells_len,
                    80 * 24,
                    "snapshot must remain valid after {k}+1 releases on refcount 6"
                );
            }
            // Final release → refcount 0, free.
            bb_snap_release(snap);
        }
        bb_term_free(term);
    }
}

// --- 6. Cross-thread retain/release -------------------------------------

#[test]
fn cross_thread_retain_and_release_is_safe() {
    // The header says retain/release are safe from any thread. We take
    // a snapshot on thread A, retain it (twice), hand the pointer to
    // thread B which releases once, then drop the last reference on A.
    //
    // The snapshot pointer crosses threads via the module-level `SnapPtr`
    // Send wrapper. The terminal handle itself stays on thread A — its
    // contract is single-threaded.
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());

        // Thread A: refcount goes 1 → 2 → 3.
        let r1 = bb_snap_retain(snap);
        let r2 = bb_snap_retain(snap);
        assert_eq!(r1, snap);
        assert_eq!(r2, snap);

        let p = SnapPtr::new(snap);
        let handle = std::thread::spawn(move || {
            let ptr = p.get();
            // Touch the immutable fields from thread B — the header
            // promises `cells` is stable post-construction.
            // SAFETY: snapshot pointer is retained twice on thread A
            // before being shared; the snapshot remains live until the
            // matching release calls below.
            let cols = (*ptr).cols;
            let rows = (*ptr).rows;
            assert_eq!(cols, 80);
            assert_eq!(rows, 24);
            // refcount 3 → 2.
            bb_snap_release(ptr);
        });
        handle.join().expect("worker thread must not panic");

        // Back on thread A: refcount 2 → 1 → 0.
        bb_snap_release(snap);
        bb_snap_release(snap);

        bb_term_free(term);
    }
}

// --- 7. Snapshot outlives terminal --------------------------------------

#[test]
fn snapshot_remains_valid_after_terminal_is_freed() {
    // Documented header invariant: snapshots are independently ref-counted
    // and `cells` is stable "for the snapshot's lifetime". The lifetime is
    // controlled by retain/release, not by the parent `BBTerm`, so freeing
    // the terminal first must NOT invalidate the snapshot. We exercise
    // both reading immutable fields and calling release after free.
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        // Retain so we can prove a second release on the freed-term path.
        let r = bb_snap_retain(snap);
        assert_eq!(r, snap);

        // Capture immutable, snapshot-owned values BEFORE freeing the term
        // so we have something concrete to assert against AFTER.
        let cols_before = (*snap).cols;
        let cells_before = (*snap).cells;
        assert_eq!(cols_before, 80);
        assert!(!cells_before.is_null());

        bb_term_free(term);

        // Snapshot must still be readable — the cells pointer is stable
        // for the snapshot's lifetime, not the terminal's.
        let cols_after = (*snap).cols;
        let cells_after = (*snap).cells;
        assert_eq!(cols_after, 80, "cols must survive terminal teardown");
        assert_eq!(
            cells_after, cells_before,
            "cells pointer must be stable across the parent term's drop"
        );

        // Two releases (one for the original acquire, one for the retain).
        bb_snap_release(snap);
        bb_snap_release(snap);
    }
}

// --- 8. Multiple concurrent snapshots from same term --------------------

#[test]
fn ten_snapshots_from_same_term_are_independent() {
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        let mut snaps: Vec<*const BBSnap> = Vec::with_capacity(10);
        for _ in 0..10 {
            let s = bb_term_take_snapshot(term);
            assert!(!s.is_null(), "every snapshot acquire must succeed");
            snaps.push(s);
        }

        // Each snapshot describes a valid 80x24 grid independently.
        for (i, s) in snaps.iter().enumerate() {
            assert_eq!((**s).cols, 80, "snap {i} cols");
            assert_eq!((**s).rows, 24, "snap {i} rows");
            assert!(!(**s).cells.is_null(), "snap {i} cells");
        }

        // Retain each one different numbers of times, then release the
        // matching count. If the refcounts were shared across snapshots
        // this asymmetric pattern would either UAF (under-release) or
        // double-free (over-release).
        for (i, s) in snaps.iter().enumerate() {
            for _ in 0..i {
                let r = bb_snap_retain(*s);
                assert_eq!(r, *s);
            }
        }
        for (i, s) in snaps.iter().enumerate() {
            for _ in 0..(i + 1) {
                bb_snap_release(*s);
            }
        }

        bb_term_free(term);
    }
}

#[test]
fn snapshots_taken_after_input_advance_independently() {
    // Drive the parser, snapshot, drive more, snapshot again. The second
    // snapshot must be its own ref-counted allocation; releasing the
    // first must not invalidate the second.
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        let payload_a = b"hello";
        bb_term_input(term, payload_a.as_ptr(), payload_a.len());
        let s1 = bb_term_take_snapshot(term);
        assert!(!s1.is_null());

        let payload_b = b" world";
        bb_term_input(term, payload_b.as_ptr(), payload_b.len());
        let s2 = bb_term_take_snapshot(term);
        assert!(!s2.is_null());
        assert_ne!(
            s1, s2,
            "two distinct take_snapshot calls must return distinct handles"
        );

        // Release in arbitrary order; both must be independently freeable.
        bb_snap_release(s1);
        // s2 must still be readable after s1 is freed.
        assert_eq!((*s2).cols, 80);
        assert_eq!((*s2).rows, 24);
        bb_snap_release(s2);

        bb_term_free(term);
    }
}

// --- Bonus: contention smoke -------------------------------------------

#[test]
fn parallel_retain_release_storm_is_balanced() {
    // Spawn N worker threads that each retain a shared snapshot many
    // times and immediately release the same number of times. Final
    // refcount should land back at 1, which the main thread then
    // releases. If retain/release weren't atomic, miran/tsan/ASan would
    // catch the race; here we settle for "no panics, no Fatal events,
    // process exits cleanly".

    let sink = Sink::default();
    unsafe {
        let term = make_term_with_sink(&sink);
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());

        let p = SnapPtr::new(snap);
        let mut handles = Vec::new();
        for _ in 0..4 {
            handles.push(std::thread::spawn(move || {
                let ptr = p.get();
                // SAFETY: snapshot is acquired on the main thread and
                // outlives this worker via the final release after join.
                for _ in 0..500 {
                    let r = bb_snap_retain(ptr);
                    assert_eq!(r, ptr, "retain identity must hold cross-thread");
                    bb_snap_release(ptr);
                }
            }));
        }
        for h in handles {
            h.join().expect("worker thread must not panic");
        }

        // Final release of the original acquire.
        bb_snap_release(snap);

        assert_eq!(
            fatal_count(&sink),
            0,
            "no Fatal events must have been delivered during the storm"
        );
        bb_term_free(term);
    }
}
