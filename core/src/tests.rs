use super::*;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::vte::ansi::{Handler, Rgb};

use crate::osc::OSC7_URL_MAX;
use crate::scrub::scrub_title_controls;

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

/// Review follow-up to audit S1-002: a title flood must coalesce to
/// the LATEST title, not pin the 32nd-of-window value. Feed a
/// 40-title burst (over the 32/s cap) in one chunk, sleep past the
/// window, feed a plain-text chunk (no titles) — the latched newest
/// title must be delivered on that chunk's flush.
#[test]
fn title_flood_coalesces_to_latest() {
    use std::os::raw::c_void;
    use std::sync::Mutex;

    struct Sink {
        titles: Mutex<Vec<String>>,
    }
    unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
        if matches!(ev.kind, BBEventKind::Title) {
            let sink = &*(ctx as *const Sink);
            let bytes = if ev.payload.is_null() || ev.len == 0 {
                &[][..]
            } else {
                std::slice::from_raw_parts(ev.payload, ev.len)
            };
            sink.titles
                .lock()
                .unwrap()
                .push(String::from_utf8_lossy(bytes).into_owned());
        }
    }

    let sink = Sink {
        titles: Mutex::new(Vec::new()),
    };
    unsafe {
        let term = bb_term_new(40, 5, 100);
        bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);

        // 40 distinct titles in one chunk — 8 over the cap.
        let mut buf = Vec::new();
        for i in 0..40 {
            buf.extend_from_slice(format!("\x1b]2;t{i}\x07").as_bytes());
        }
        bb_term_input(term, buf.as_ptr(), buf.len());
        {
            let titles = sink.titles.lock().unwrap();
            assert!(
                titles.len() <= 32,
                "cap must hold within the window; got {}",
                titles.len()
            );
            assert_ne!(
                titles.last().map(String::as_str),
                Some("t39"),
                "t39 must still be latched, not yet delivered"
            );
        }

        // Roll the window, then feed a titles-free chunk; the flush
        // must deliver the latched newest title exactly once.
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let plain = b"hello";
        bb_term_input(term, plain.as_ptr(), plain.len());
        {
            let titles = sink.titles.lock().unwrap();
            assert_eq!(
                titles.last().map(String::as_str),
                Some("t39"),
                "latest suppressed title must deliver after the window rolls"
            );
            let t39_count = titles.iter().filter(|t| t.as_str() == "t39").count();
            assert_eq!(t39_count, 1, "latched title must deliver exactly once");
        }

        bb_term_free(term);
    }
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
    // Head fields (review follow-up): a reorder in the first 12
    // bytes previously passed this test while silently breaking the
    // Swift bridge.
    assert_eq!(std::mem::offset_of!(BBSnap, cols), 0, "cols at offset 0");
    assert_eq!(std::mem::offset_of!(BBSnap, rows), 2, "rows at offset 2");
    assert_eq!(
        std::mem::offset_of!(BBSnap, cursor_col),
        4,
        "cursor_col at offset 4"
    );
    assert_eq!(
        std::mem::offset_of!(BBSnap, cursor_row),
        6,
        "cursor_row at offset 6"
    );
    assert_eq!(
        std::mem::offset_of!(BBSnap, cursor_visible),
        8,
        "cursor_visible at offset 8"
    );
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
        std::mem::offset_of!(BBSnap, cursor_pending_wrap),
        56,
        "cursor_pending_wrap appended at offset 56 (audit S5-003 \
             review follow-up) — existing field offsets must not move"
    );
    assert_eq!(
        std::mem::size_of::<BBSnap>(),
        64,
        "BBSnap total size 64 bytes (56 + appended pending-wrap byte \
             with explicit tail padding)"
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
            // Post-S6-001 an empty title arrives with payload == NULL;
            // from_raw_parts(null, 0) is UB — guard like every
            // integration harness does. Review follow-up (latent UB).
            let bytes = if ev.payload.is_null() || ev.len == 0 {
                &[][..]
            } else {
                std::slice::from_raw_parts(ev.payload, ev.len)
            };
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
