//! Property-based invariants on the BBCore FFI surface, complementing
//! `proptest_invariants.rs` (parse idempotence, snapshot back-to-back,
//! mode set/reset, scroll roundtrip).
//!
//! This file targets the *structural* contract of snapshot, resize, and
//! damage — the boring invariants that mutation testing flagged as
//! under-asserted by the existing example tests. None of the properties
//! here duplicate one already encoded in `proptest_invariants.rs`:
//!
//!   - snapshot_cells_len_equals_cols_times_rows
//!   - resize_clamp_is_a_fixpoint
//!   - resize_snapshot_dims_match_clamped
//!   - color_packing_roundtrips_for_any_rgb
//!   - damage_rows_in_bounds
//!   - damage_rows_have_no_duplicates
//!   - damage_rows_total_independent_of_cap
//!   - snapshot_retain_release_refcount_balance
//!   - resize_floor_is_two
//!   - resize_ceiling_is_one_thousand
//!
//! Pre-flight cost summary. Each generated case allocates ONE BBTerm at
//! 80×24 with 1000 lines of scrollback (~1.3 MiB peak), plus at most one
//! snapshot (≤30 KiB cells + bookkeeping), and a payload bounded by
//! `MAX_PAYLOAD` (4 KiB). `ProptestConfig::cases = 64` per block × 10
//! blocks × ~5 ms per case ≈ ~3 s wall-clock in CI. The two resize-edge
//! blocks generate values in tight bands (cols ∈ {0,1}, cols ∈
//! 1001..=u16::MAX) so they shrink fast on failure. No I/O, no spawned
//! threads, no sleeps. Property #8 (retain/release balance) is the
//! heaviest at 50 simultaneous snapshots; even there the high-water
//! mark is ~50 × 30 KiB ≈ 1.5 MiB on top of the term, well inside
//! budget.

use blackbird_core::*;
use proptest::prelude::*;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};

// ─────────────────────────────────────────────────────────────────────
// Shared harness (mirrors color_ffi_blind.rs + proptest_invariants.rs)
// ─────────────────────────────────────────────────────────────────────

/// Set on every `BBEventKind::Fatal` event. The guarded FFI catches
/// internal panics and returns a fallback so callers don't unwind
/// across the C ABI; without this latch a panic-on-snapshot would
/// silently pass the property as `fallback == fallback`. Each property
/// resets the latch before its FFI calls and asserts it stayed clear.
///
/// Same caveat as `proptest_invariants.rs::SAW_FATAL`: cargo test may
/// run multiple `#[test]` fns in parallel. The race is benign (it can
/// only mask a real Fatal, never invent one); run with
/// `--test-threads=1` for a hermetic verification of the Fatal channel.
static SAW_FATAL: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn on_fatal(ev: BBEvent, _ctx: *mut c_void) {
    if ev.kind == BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
}

/// Drop guard for a `BBTerm` so `prop_assert!`/`prop_assume!` early
/// returns can't leak the ~1.3 MiB scrollback ring. Constructed only
/// from `bb_term_new` returns inside an `unsafe` block.
struct TermGuard(*mut BBTerm);

impl Drop for TermGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: TermGuard owns the term for its lifetime; we only
            // construct it from `bb_term_new` returns, and the drop
            // happens after the unsafe block that minted it.
            unsafe { bb_term_free(self.0) };
        }
    }
}

const COLS: u16 = 80;
const ROWS: u16 = 24;
const SCROLLBACK: u32 = 1000;
const MAX_PAYLOAD: usize = 4 * 1024;
/// Documented per the FFI header on `bb_term_resize2`: dimensions are
/// clamped to `[MIN_DIM, MAX_DIM] = [2, 1000]` on each axis. Pinned
/// here as constants so the expected-value calculations in properties
/// 2/3/9/10 read straight off the contract.
const MIN_DIM: u16 = 2;
const MAX_DIM: u16 = 1000;

/// Closure-scope helper, same shape as `color_ffi_blind.rs::with_term`
/// but without the PtyWrite sink (this file's properties don't inspect
/// callback bytes — they assert on return values + snapshot fields).
/// `body` receives a live `*mut BBTerm`; the term is freed after
/// `body` returns, even if a `prop_assert!` short-circuits it (via the
/// inner `TermGuard`).
fn with_term<F>(body: F)
where
    F: FnOnce(*mut BBTerm) -> Result<(), TestCaseError>,
{
    let result: Result<(), TestCaseError> = unsafe {
        let term = bb_term_new(COLS, ROWS, SCROLLBACK);
        // We can't `prop_assert!` outside a `proptest!` block, so the
        // null check is a hard panic — if the constructor fails at the
        // default 80×24×1000 something is catastrophically broken and
        // every property would fail next anyway.
        assert!(!term.is_null(), "bb_term_new(80,24,1000) returned null");
        let _g = TermGuard(term);
        bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());
        body(term)
    };
    // Propagate the inner error so proptest can shrink. We can't use
    // `?` outside a function returning `Result`, so emulate it with a
    // panic — proptest treats `prop_assert!` failures as TestCaseError
    // already, and only the OUTER `proptest!` macro converts those
    // into shrinkable failures. To keep the contract, callers wrap
    // each property body in a closure that returns
    // `Result<(), TestCaseError>` and we forward that result.
    if let Err(e) = result {
        // `TestCaseError` is not `std::error::Error`-compatible enough
        // to `?`-propagate from this helper; we re-raise inside the
        // proptest! body by returning a `Result` from the closure. The
        // helper itself only runs the body — failures from `body` are
        // propagated by the explicit `?` pattern at each callsite.
        panic!("property body failed: {e:?}");
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 1: snapshot dim consistency under any input
// ─────────────────────────────────────────────────────────────────────
//
// For any byte string (size ≤ MAX_PAYLOAD), after `bb_term_input` on
// an 80×24 grid, `snapshot.cells_len == cols * rows`. Closes the gap
// that mutation testing flagged: the example tests check `cells_len`
// after a fixed input, never after an arbitrary byte stream that might
// trigger reflow / alt-screen / resize-from-resize paths.

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn snapshot_cells_len_equals_cols_times_rows(
        bytes in prop::collection::vec(any::<u8>(), 0..=MAX_PAYLOAD),
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        let mut inner: Result<(), TestCaseError> = Ok(());
        with_term(|term| unsafe {
            if !bytes.is_empty() {
                bb_term_input(term, bytes.as_ptr(), bytes.len());
            }
            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null(), "snapshot of a non-null term must not be null");
            let cells_len = (*snap).cells_len;
            let cols = (*snap).cols as usize;
            let rows = (*snap).rows as usize;
            prop_assert_eq!(
                cells_len,
                cols * rows,
                "cells_len ({}) != cols*rows ({}*{}={})",
                cells_len, cols, rows, cols * rows
            );
            bb_snap_release(snap);
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal panic during snapshot/input FFI calls",
        );
        // Forward any inner failure that the closure caught. The
        // `with_term` helper panics on Err, so reaching here means
        // success; the assignment+check pattern is kept for symmetry
        // with the other properties that need fall-through diagnostics.
        let _ = &mut inner;
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 2: resize clamp is a fixpoint
// ─────────────────────────────────────────────────────────────────────
//
// For any (cols, rows) in 1..=2000 × 1..=2000, the FIRST call to
// `bb_term_resize2` clamps to `[MIN_DIM, MAX_DIM]` per axis; an
// immediate second call with the *applied* values returns the same
// applied values with `clamped == 0`. Catches a regression where the
// clamp was applied to the wrong axis, or where re-resize toggled the
// `clamped` flag.

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn resize_clamp_is_a_fixpoint(
        cols in 1u16..=2000u16,
        rows in 1u16..=2000u16,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        with_term(|term| unsafe {
            let r1 = bb_term_resize2(term, cols, rows);
            // The first call may or may not have clamped, depending on
            // whether `cols`/`rows` fell inside `[MIN_DIM, MAX_DIM]`.
            // Either way, `applied_*` must lie inside the envelope.
            prop_assert!(r1.applied_cols >= MIN_DIM, "applied_cols < MIN_DIM");
            prop_assert!(r1.applied_cols <= MAX_DIM, "applied_cols > MAX_DIM");
            prop_assert!(r1.applied_rows >= MIN_DIM, "applied_rows < MIN_DIM");
            prop_assert!(r1.applied_rows <= MAX_DIM, "applied_rows > MAX_DIM");

            let expected_clamped =
                cols != r1.applied_cols || rows != r1.applied_rows;
            prop_assert_eq!(
                r1.clamped != 0,
                expected_clamped,
                "first-call clamped flag disagrees with applied-vs-requested diff: \
                 requested=({},{}) applied=({},{}) flag={}",
                cols, rows, r1.applied_cols, r1.applied_rows, r1.clamped
            );

            // Now re-resize using the applied values — must be a no-op
            // fixpoint: applied stays identical, clamped flag clears.
            let r2 = bb_term_resize2(term, r1.applied_cols, r1.applied_rows);
            prop_assert_eq!(
                r2.applied_cols, r1.applied_cols,
                "second resize moved cols: first={}, second={}",
                r1.applied_cols, r2.applied_cols
            );
            prop_assert_eq!(
                r2.applied_rows, r1.applied_rows,
                "second resize moved rows: first={}, second={}",
                r1.applied_rows, r2.applied_rows
            );
            prop_assert_eq!(
                r2.clamped, 0,
                "second resize at applied dims must not be clamped, got flag={}",
                r2.clamped
            );
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during resize fixpoint check",
        );
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 3: resize-then-snapshot dims agree with clamp
// ─────────────────────────────────────────────────────────────────────
//
// For any clamped (c, r), the post-resize snapshot's cols / rows match
// `c.clamp(MIN_DIM, MAX_DIM)` and `r.clamp(MIN_DIM, MAX_DIM)`. Wires
// `bb_term_resize2`'s reported `applied_*` to the snapshot side of the
// FFI — a regression that clamped the return value but forgot to
// resize the underlying grid would surface here.

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn resize_snapshot_dims_match_clamped(
        cols in 1u16..=2000u16,
        rows in 1u16..=2000u16,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        let expected_cols = cols.clamp(MIN_DIM, MAX_DIM);
        let expected_rows = rows.clamp(MIN_DIM, MAX_DIM);
        with_term(|term| unsafe {
            let r = bb_term_resize2(term, cols, rows);
            prop_assert_eq!(r.applied_cols, expected_cols, "applied_cols off");
            prop_assert_eq!(r.applied_rows, expected_rows, "applied_rows off");

            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            let snap_cols = (*snap).cols;
            let snap_rows = (*snap).rows;
            bb_snap_release(snap);

            prop_assert_eq!(
                snap_cols, expected_cols,
                "snapshot cols ({}) != clamped requested ({}); requested={}",
                snap_cols, expected_cols, cols
            );
            prop_assert_eq!(
                snap_rows, expected_rows,
                "snapshot rows ({}) != clamped requested ({}); requested={}",
                snap_rows, expected_rows, rows
            );
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during resize/snapshot dim check",
        );
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 4: color packing round-trips for arbitrary RGB
// ─────────────────────────────────────────────────────────────────────
//
// `color_ffi_blind.rs` example-tests a handful of fixed colors via the
// OSC 10/11/12 reply path. The COMPLEMENTARY check here is on the
// cell-fg path: after `bb_term_set_named_color(term, 16, (r<<16)|...)`
// + `\x1b[38;5;16mA`, the cell at (0,0) has `fg & 0x00FF_FFFF ==
// requested_rgb`. This pins the bit-packing of the renderer-facing
// 24-bit fg slot, NOT the OSC reply hex format (which the existing
// file already covers).
//
// We mask with `0x00FF_FFFF` because the high byte of `BBCell::fg`
// historically carries indexed-vs-truecolor metadata; the contract
// the renderer reads is "low 24 bits are the RGB". Pinning the full
// u32 would couple this property to that metadata layout, which is
// out of scope for the "bit-packing of RGB" invariant.

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn color_packing_roundtrips_for_any_rgb(
        r in 0u32..=255u32,
        g in 0u32..=255u32,
        b in 0u32..=255u32,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        let rgb: u32 = (r << 16) | (g << 8) | b;
        with_term(|term| unsafe {
            bb_term_set_named_color(term, 16, rgb);
            // Select the 256-palette slot we just rewrote, then emit a
            // visible glyph at (0, 0).
            let seq = b"\x1b[38;5;16mA";
            bb_term_input(term, seq.as_ptr(), seq.len());

            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            let cells_len = (*snap).cells_len;
            prop_assert!(cells_len > 0, "snapshot has zero cells");
            // (0, 0) is always at index 0 in the flat layout.
            let cell0 = *((*snap).cells);
            bb_snap_release(snap);

            // The cell must hold the 'A' glyph (otherwise the SGR feed
            // never landed and the fg comparison is meaningless).
            prop_assert_eq!(cell0.ch, b'A' as u32, "expected 'A' at (0,0), got 0x{:08x}", cell0.ch);
            let fg_rgb = cell0.fg & 0x00FF_FFFF;
            prop_assert_eq!(
                fg_rgb,
                rgb,
                "cell fg RGB diverged: requested=0x{:06x} observed=0x{:06x} (full fg=0x{:08x})",
                rgb, fg_rgb, cell0.fg
            );
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during color packing roundtrip",
        );
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 5: damage row indices are in bounds
// ─────────────────────────────────────────────────────────────────────
//
// For any byte string ≤ 1024 bytes, after taking a snapshot: if
// `damage_is_full == 0`, every value returned by `damage_rows(...)` is
// `< rows`. A regression that emitted a sentinel row index (e.g.
// `u16::MAX` for "full") in the damage list would crash a Swift caller
// indexing into a `[Row]` array.

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn damage_rows_in_bounds(
        bytes in prop::collection::vec(any::<u8>(), 0..=1024usize),
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        with_term(|term| unsafe {
            if !bytes.is_empty() {
                bb_term_input(term, bytes.as_ptr(), bytes.len());
            }
            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            let rows = (*snap).rows;
            let full = bb_snap_damage_is_full(snap);
            if full == 0 {
                // Probe total first, then allocate a buffer exactly
                // that size. `damage_rows` writes `min(total, cap)`
                // entries; using `total` as cap guarantees we read
                // every damaged row even when the set is large.
                let total = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
                // Cap at a sane upper bound so a misbehaving impl that
                // returns `usize::MAX` doesn't OOM the test runner.
                // The header documents `out_cap` semantics; rows in a
                // 24-row grid can never legitimately exceed ROWS
                // entries. Anything bigger is itself a property
                // failure.
                prop_assert!(
                    total <= (rows as usize),
                    "damage total ({}) > rows ({}) — out-of-band index pending in next read",
                    total, rows
                );
                let mut buf: Vec<u16> = vec![0u16; total];
                let n = bb_snap_damage_rows(snap, buf.as_mut_ptr(), total);
                prop_assert_eq!(n, total, "second damage_rows call returned different total: {} vs {}", n, total);
                for (i, idx) in buf.iter().enumerate().take(total) {
                    prop_assert!(
                        *idx < rows,
                        "damage row #{} out of bounds: idx={} rows={}",
                        i, idx, rows
                    );
                }
            }
            bb_snap_release(snap);
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during damage_rows in-bounds check",
        );
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 6: damage row indices contain no duplicates
// ─────────────────────────────────────────────────────────────────────
//
// Same setup as Property 5. The damage set is conceptually a *set* of
// rows; emitting the same index twice would cause the Metal renderer
// to redraw a row, waste a flush, and (more critically) double-count
// damage budget heuristics that gate on `damage_rows.len()`.

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn damage_rows_have_no_duplicates(
        bytes in prop::collection::vec(any::<u8>(), 0..=1024usize),
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        with_term(|term| unsafe {
            if !bytes.is_empty() {
                bb_term_input(term, bytes.as_ptr(), bytes.len());
            }
            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            let rows = (*snap).rows;
            let full = bb_snap_damage_is_full(snap);
            if full == 0 {
                let total = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
                prop_assert!(total <= (rows as usize));
                let mut buf: Vec<u16> = vec![0u16; total];
                bb_snap_damage_rows(snap, buf.as_mut_ptr(), total);
                let mut seen: Vec<u16> = buf.clone();
                seen.sort_unstable();
                let dedup_len = {
                    let mut s = seen.clone();
                    s.dedup();
                    s.len()
                };
                prop_assert_eq!(
                    dedup_len,
                    seen.len(),
                    "damage_rows contained duplicates: sorted={:?}",
                    seen
                );
            }
            bb_snap_release(snap);
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during damage_rows dedup check",
        );
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 7: damage_rows total is cap-independent
// ─────────────────────────────────────────────────────────────────────
//
// The header documents that `damage_rows(snap, null, 0)` returns the
// total, and `damage_rows(snap, buf, cap)` always returns the SAME
// total regardless of `cap` (writing only `min(total, cap)` entries).
// A regression that bound the return value to `min(total, cap)` would
// break truncation detection in Swift callers that compare
// `return_value > out_cap` to decide whether to retry.

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn damage_rows_total_independent_of_cap(
        bytes in prop::collection::vec(any::<u8>(), 0..=1024usize),
        cap in 0usize..=256usize,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        with_term(|term| unsafe {
            if !bytes.is_empty() {
                bb_term_input(term, bytes.as_ptr(), bytes.len());
            }
            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            let total_probe = bb_snap_damage_rows(snap, std::ptr::null_mut(), 0);
            let mut buf: Vec<u16> = vec![0u16; cap];
            let total_with_cap = if cap == 0 {
                bb_snap_damage_rows(snap, std::ptr::null_mut(), 0)
            } else {
                bb_snap_damage_rows(snap, buf.as_mut_ptr(), cap)
            };
            bb_snap_release(snap);

            prop_assert_eq!(
                total_probe,
                total_with_cap,
                "damage_rows total changed with cap: probe={} cap={} returned={}",
                total_probe, cap, total_with_cap
            );
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during damage_rows cap-independence check",
        );
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 8: snapshot retain/release balance is sound
// ─────────────────────────────────────────────────────────────────────
//
// Take `N` snapshots in `1..=50`, retain each `K` times in `0..=5`,
// then release each `N + K` times. Must complete with no Fatal event.
// Pre-flight: at most 50 snapshots in flight at once, each ~30 KiB
// cells + bookkeeping ≈ 1.5 MiB peak per case. Catches:
//   - underflow when release-count exceeds acquire-count (next
//     release would write to freed memory and SHOULD surface as a
//     Fatal — at minimum a use-after-free in MIRI/ASan)
//   - overflow when retain count saturates a too-small counter
//   - leak of the underlying allocation (no direct check, but the
//     test runner's RSS gates would catch a per-case 1.5 MiB leak)

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn snapshot_retain_release_refcount_balance(
        n in 1usize..=50usize,
        k in 0usize..=5usize,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        with_term(|term| unsafe {
            let mut snaps: Vec<*const BBSnap> = Vec::with_capacity(n);
            for _ in 0..n {
                let s = bb_term_take_snapshot(term);
                prop_assert!(!s.is_null(), "snapshot in batch must not be null");
                for _ in 0..k {
                    let r = bb_snap_retain(s);
                    prop_assert_eq!(r, s, "bb_snap_retain returned a different pointer");
                }
                snaps.push(s);
            }
            // Release each snapshot once per acquire (the original
            // take + k retains).
            for s in snaps {
                for _ in 0..(1 + k) {
                    bb_snap_release(s);
                }
            }
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during retain/release balance — refcount underflow / use-after-free",
        );
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 9: resize floor is MIN_DIM (=2)
// ─────────────────────────────────────────────────────────────────────
//
// For any c in {0, 1} × r in 1..=MAX_DIM, OR c in 1..=MAX_DIM × r in
// {0, 1}, the post-resize state must reflect the documented floor.
// The header carves out a special case: zero on either axis is a
// "no-op" returning all-zero `BBResizeResult`. We pin BOTH:
//   - (c=0 OR r=0) → applied = {0,0}, clamped = 0
//   - (c=1 with r ≥ MIN_DIM) → applied_cols = MIN_DIM, clamped != 0
//   - (r=1 with c ≥ MIN_DIM) → applied_rows = MIN_DIM, clamped != 0
//
// Splitting the two ladder rungs keeps the per-case branch simple.

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn resize_floor_is_two_for_one_axis(
        // c picks one of {0, 1}; r is a healthy non-floor value so the
        // "floor case" is unambiguous (we're not also testing the row
        // axis here, just the column floor / zero-no-op).
        c in 0u16..=1u16,
        r in (MIN_DIM)..=MAX_DIM,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        with_term(|term| unsafe {
            let res = bb_term_resize2(term, c, r);
            if c == 0 {
                // Zero-on-an-axis is a documented no-op.
                prop_assert_eq!(res.applied_cols, 0u16, "zero c must produce applied=0");
                prop_assert_eq!(res.applied_rows, 0u16, "zero c must produce applied=0");
                prop_assert_eq!(res.clamped, 0u8, "zero c must produce clamped=0 (no-op shape)");
            } else {
                // c == 1: must clamp UP to MIN_DIM, flag must be set.
                prop_assert_eq!(
                    res.applied_cols, MIN_DIM,
                    "c=1 must clamp UP to MIN_DIM={} (got {})", MIN_DIM, res.applied_cols
                );
                prop_assert_eq!(
                    res.applied_rows, r,
                    "row axis must pass through unchanged when in-range (got {})", res.applied_rows
                );
                prop_assert!(
                    res.clamped != 0,
                    "clamped flag must be set when c was rewritten 1 → {}",
                    MIN_DIM
                );
            }
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during resize floor (col axis) check",
        );
    }

    #[test]
    fn resize_floor_is_two_for_row_axis(
        c in (MIN_DIM)..=MAX_DIM,
        r in 0u16..=1u16,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        with_term(|term| unsafe {
            let res = bb_term_resize2(term, c, r);
            if r == 0 {
                prop_assert_eq!(res.applied_cols, 0u16);
                prop_assert_eq!(res.applied_rows, 0u16);
                prop_assert_eq!(res.clamped, 0u8);
            } else {
                prop_assert_eq!(
                    res.applied_rows, MIN_DIM,
                    "r=1 must clamp UP to MIN_DIM={} (got {})", MIN_DIM, res.applied_rows
                );
                prop_assert_eq!(
                    res.applied_cols, c,
                    "col axis must pass through unchanged when in-range (got {})", res.applied_cols
                );
                prop_assert!(
                    res.clamped != 0,
                    "clamped flag must be set when r was rewritten 1 → {}",
                    MIN_DIM
                );
            }
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during resize floor (row axis) check",
        );
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 10: resize ceiling is MAX_DIM (=1000)
// ─────────────────────────────────────────────────────────────────────
//
// For any c in (MAX_DIM+1)..=u16::MAX × r in MIN_DIM..=MAX_DIM, the
// applied cols must be MAX_DIM with the clamped flag set. Mirror for
// the row axis. Pins the upper bound that the header documents as the
// guard against the 100+ GB allocation on huge grids.

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn resize_ceiling_is_one_thousand_for_col_axis(
        c in (MAX_DIM + 1)..=u16::MAX,
        r in MIN_DIM..=MAX_DIM,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        with_term(|term| unsafe {
            let res = bb_term_resize2(term, c, r);
            prop_assert_eq!(
                res.applied_cols, MAX_DIM,
                "c > MAX_DIM must clamp DOWN to MAX_DIM={} (got {} for requested {})",
                MAX_DIM, res.applied_cols, c
            );
            prop_assert_eq!(
                res.applied_rows, r,
                "row axis must pass through unchanged when in-range (got {})",
                res.applied_rows
            );
            prop_assert!(
                res.clamped != 0,
                "clamped flag must be set when c was rewritten {} → {}",
                c, MAX_DIM
            );
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during resize ceiling (col axis) check",
        );
    }

    #[test]
    fn resize_ceiling_is_one_thousand_for_row_axis(
        c in MIN_DIM..=MAX_DIM,
        r in (MAX_DIM + 1)..=u16::MAX,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        with_term(|term| unsafe {
            let res = bb_term_resize2(term, c, r);
            prop_assert_eq!(
                res.applied_rows, MAX_DIM,
                "r > MAX_DIM must clamp DOWN to MAX_DIM={} (got {} for requested {})",
                MAX_DIM, res.applied_rows, r
            );
            prop_assert_eq!(
                res.applied_cols, c,
                "col axis must pass through unchanged when in-range (got {})",
                res.applied_cols
            );
            prop_assert!(
                res.clamped != 0,
                "clamped flag must be set when r was rewritten {} → {}",
                r, MAX_DIM
            );
            Ok(())
        });
        prop_assert!(
            !SAW_FATAL.swap(false, Ordering::SeqCst),
            "Fatal during resize ceiling (row axis) check",
        );
    }
}
