//! BUG-7 — the CORE half of the DEC mode 2026 (synchronized output)
//! stalled-update watchdog.
//!
//! ## The bug these tests exist for
//!
//! Between BSU (`\x1b[?2026h`) and ESU (`\x1b[?2026l`) the vendored vte
//! parser buffers every byte instead of mutating the grid, and arms a
//! private abort deadline (`SYNC_UPDATE_TIMEOUT`, 150 ms). vte does NOT
//! self-abort: `Processor::advance` only consults that deadline when MORE
//! bytes arrive, so noticing expiry and calling `stop_sync` is the
//! EMBEDDER's job. Blackbird never did it, so a producer that emits BSU
//! and then dies (a TUI SIGKILLed mid-frame, a dropped ssh, a hostile
//! file) left the tab frozen: every later byte buffered and nothing ever
//! rendered, self-healing only at the 2 MiB buffer cap — i.e. never, from
//! a dead producer.
//!
//! The fix exposes two entry points so the embedder can see and end a
//! stalled update:
//!
//! * `bb_term_sync_status(term) -> BBSyncStatus` — O(1) pure read of
//!   `{ remaining_ns, buffered_bytes, pending, expired }`. `expired` is
//!   the core's own verdict; callers must never recompute it from a host
//!   clock or hardcode vte's private constant.
//! * `bb_term_flush_sync_update(term, force) -> u8` — terminate a pending
//!   update, replaying its buffered bytes into the grid. `force == 0`
//!   makes the core re-check its own deadline first (so a live frame can
//!   never be torn); `force == 1` aborts unconditionally and exists so
//!   these tests can pin flush mechanics without sleeping.
//!
//! ## Oracles
//!
//! Everything here is observed through the public FFI only — grid text
//! and cursor/mode fields via `bb_term_take_snapshot`, side effects via
//! the registered `BBEventCb`. No test reaches into crate internals, and
//! no test hardcodes vte's timeout as a *predicate* (only as a sanity
//! ceiling on `remaining_ns`, called out at the constant). The
//! stray-ESU test uses a second terminal that never saw mode 2026 at all
//! as a differential oracle, rather than a hand-written expected grid.
//!
//! Sibling file: `sync_output.rs` pins the untouched happy paths
//! (complete region lands atomically, region survives fragmented feeds,
//! bytes are withheld pre-ESU). Its module doc predates this FFI and
//! still claims sync state is not exposed; that claim is what this file
//! supersedes.
//!
//! ## Pre-flight cost (CLAUDE.md test-authoring rule)
//!
//! Grids are 20 × 2 with 32 lines of scrollback: 40 live cells ≈ 1 KiB,
//! scrollback allocated lazily. The dominant per-terminal cost is vte's
//! pre-existing `SyncState` buffer (`Vec::with_capacity(2 MiB)`), which
//! every `BBTerm` in the process already pays — one per terminal, at
//! most two terminals alive at once (the stray-ESU differential test).
//! Peak ≈ 4 MiB per test thread. Exactly ONE `thread::sleep(160 ms)` in
//! the whole file (the expiry test); every other test uses `force = 1`.
//! Total wall clock well under a second.

use std::ffi::c_void;
use std::sync::Mutex;
use std::time::Duration;

use blackbird_core::*;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const COLS: u16 = 20;
const ROWS: u16 = 2;
const SCROLLBACK: u32 = 32;

/// Test-local mirror of vte's private `SYNC_UPDATE_TIMEOUT` (150 ms),
/// used ONLY as an upper-bound sanity ceiling on `remaining_ns` — never
/// as an expiry predicate. Production callers must not duplicate it at
/// all (that is the whole point of shipping `expired` in the struct); a
/// test may, because a test is allowed to know the fixture it drives. If
/// a vte bump widens the window this ceiling is the loud failure that
/// says "re-read the constant", which is the intended behaviour.
const VTE_SYNC_WINDOW_NS: u64 = 150_000_000;

/// Comfortably past `VTE_SYNC_WINDOW_NS`. Only ever used to get *past*
/// the deadline; no test asserts an upper bound on elapsed time, so CI
/// contention can delay us arbitrarily without flaking.
const PAST_THE_WINDOW: Duration = Duration::from_millis(160);

/// Captures every event the core fires, in order.
#[derive(Default)]
struct Sink {
    events: Mutex<Vec<(u32, i32, Vec<u8>)>>,
}

impl Sink {
    /// `(i32_arg, payload)` for every event of `kind`, in fire order.
    fn of_kind(&self, kind: BBEventKind) -> Vec<(i32, Vec<u8>)> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|(k, _, _)| *k == kind as u32)
            .map(|(_, arg, payload)| (*arg, payload.clone()))
            .collect()
    }

    fn event_count(&self) -> usize {
        self.events.lock().unwrap().len()
    }
}

unsafe extern "C" fn capture(ev: BBEvent, ctx: *mut c_void) {
    let sink = &*(ctx as *const Sink);
    let payload = if ev.len > 0 && !ev.payload.is_null() {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    sink.events
        .lock()
        .unwrap()
        .push((ev.kind as u32, ev.i32_arg, payload));
}

unsafe fn new_term() -> *mut BBTerm {
    let term = bb_term_new(COLS, ROWS, SCROLLBACK);
    assert!(!term.is_null(), "bb_term_new returned null");
    term
}

unsafe fn feed(term: *mut BBTerm, bytes: &[u8]) {
    bb_term_input(term, bytes.as_ptr(), bytes.len());
}

/// Everything a snapshot says about visible state, in one comparable
/// value. Used as the differential oracle for "this byte was inert".
#[derive(Debug, PartialEq, Eq)]
struct GridShape {
    rows: Vec<String>,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: u8,
    cursor_shape: u8,
    mode: u32,
    display_offset: u32,
    history_size: u32,
}

unsafe fn grid_shape(term: *mut BBTerm) -> GridShape {
    let snap = bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
    let s = &*snap;
    let mut rows = Vec::with_capacity(s.rows as usize);
    for row in 0..s.rows as usize {
        let start = row * s.cols as usize;
        let mut line = String::new();
        for col in 0..s.cols as usize {
            let cell = *s.cells.add(start + col);
            // `\0` is alacritty's "never written" sentinel; render it as a
            // blank so an untouched row compares equal to a cleared one.
            line.push(if cell.ch == 0 {
                ' '
            } else {
                char::from_u32(cell.ch).unwrap_or(' ')
            });
        }
        rows.push(line.trim_end().to_string());
    }
    let shape = GridShape {
        rows,
        cursor_row: s.cursor_row,
        cursor_col: s.cursor_col,
        cursor_visible: s.cursor_visible,
        cursor_shape: s.cursor_shape,
        mode: s.mode,
        display_offset: s.display_offset,
        history_size: s.history_size,
    };
    bb_snap_release(snap);
    shape
}

/// Row `row`'s text with trailing blanks trimmed.
unsafe fn row_text(term: *mut BBTerm, row: usize) -> String {
    grid_shape(term).rows[row].clone()
}

/// Pin "no synchronized update is open, and no residue of one is left".
#[track_caller]
unsafe fn assert_idle(term: *mut BBTerm, ctx: &str) {
    let s = bb_term_sync_status(term);
    assert_eq!(s.pending, 0, "{ctx}: a synchronized update is still open");
    assert_eq!(
        s.expired, 0,
        "{ctx}: expired must be 0 when nothing is pending"
    );
    assert_eq!(
        s.remaining_ns, 0,
        "{ctx}: remaining_ns must be 0 when nothing is pending"
    );
    assert_eq!(
        s.buffered_bytes, 0,
        "{ctx}: the sync buffer must be empty when nothing is pending"
    );
}

// ---------------------------------------------------------------------------
// (a) A bare BSU opens an update and withholds everything after it
// ---------------------------------------------------------------------------

#[test]
fn fresh_terminal_reports_no_pending_sync_update() {
    // The idle reading is the fail-safe default the whole watchdog keys
    // off: if this were ever non-zero on a terminal that never saw mode
    // 2026, the Swift watchdog would arm a timer on every session.
    unsafe {
        let term = new_term();
        assert_idle(term, "fresh terminal");
        feed(term, b"hi");
        assert_idle(term, "after ordinary text");
        assert_eq!(row_text(term, 0), "hi", "ordinary text must render");
        bb_term_free(term);
    }
}

#[test]
fn bare_bsu_marks_pending_and_withholds_following_bytes_from_the_grid() {
    // The exact shape of a producer that opened a frame and then died:
    // BSU plus some payload, no ESU. The bytes must be accounted for as
    // buffered, and must NOT be visible.
    unsafe {
        let term = new_term();
        feed(term, b"XY");
        feed(term, b"\x1b[?2026hZZZZZ");

        let s = bb_term_sync_status(term);
        assert_ne!(s.pending, 0, "BSU must open a synchronized update");
        assert_eq!(
            s.expired, 0,
            "an update opened microseconds ago cannot already be expired"
        );
        assert!(
            s.remaining_ns > 0,
            "a live update must report time remaining, got {}",
            s.remaining_ns
        );
        assert!(
            s.remaining_ns <= VTE_SYNC_WINDOW_NS,
            "remaining_ns {} exceeds the core's own {}ns window — the deadline \
             is not the one vte armed",
            s.remaining_ns,
            VTE_SYNC_WINDOW_NS
        );
        // Lower bound: the five withheld payload bytes are accounted for.
        // Upper bound: nothing beyond the chunk we fed can be in there.
        // (The BSU sequence itself is consumed by the normal parser path,
        // so the expected value is 5 — the range tolerates a vte that
        // chooses to retain the opening escape as well.)
        assert!(
            (5..=13).contains(&s.buffered_bytes),
            "buffered_bytes {} does not account for the 5 withheld bytes",
            s.buffered_bytes
        );

        assert_eq!(
            row_text(term, 0),
            "XY",
            "bytes inside an open synchronized region leaked into the grid"
        );
        bb_term_free(term);
    }
}

#[test]
fn pending_sync_state_accumulates_across_fragmented_feeds() {
    // PTY reads arrive in arbitrary chunks. A frame opened in one chunk
    // and abandoned several chunks later must present as ONE open update
    // whose buffer grows — this is what the Swift watchdog polls.
    unsafe {
        let term = new_term();

        feed(term, b"\x1b[?2026h");
        let opened = bb_term_sync_status(term);
        assert_ne!(opened.pending, 0, "a lone BSU chunk must open the update");
        assert_eq!(
            opened.buffered_bytes, 0,
            "the BSU sequence itself is consumed, not buffered"
        );

        feed(term, b"AB");
        let mid = bb_term_sync_status(term);
        assert_ne!(mid.pending, 0, "the update must stay open across chunks");
        assert_eq!(mid.buffered_bytes, 2, "the whole chunk must be withheld");

        feed(term, b"CD");
        let more = bb_term_sync_status(term);
        assert_ne!(more.pending, 0, "still one open update, not a new one");
        assert_eq!(
            more.buffered_bytes, 4,
            "each fragment must append to the same buffer"
        );

        assert_eq!(
            row_text(term, 0),
            "",
            "nothing may render while the producer's frame is open"
        );

        assert_eq!(
            bb_term_flush_sync_update(term, 1),
            1,
            "forced flush must terminate the open update"
        );
        assert_eq!(
            row_text(term, 0),
            "ABCD",
            "every buffered fragment must replay, in order"
        );
        assert_idle(term, "after flushing a fragmented region");
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// (b) The flush makes the withheld bytes visible
// ---------------------------------------------------------------------------

#[test]
fn forced_flush_lands_the_withheld_bytes_in_the_grid() {
    unsafe {
        let term = new_term();
        feed(term, b"XY");
        feed(term, b"\x1b[?2026hZZZZZ");
        assert_eq!(row_text(term, 0), "XY", "precondition: bytes withheld");

        assert_eq!(
            bb_term_flush_sync_update(term, 1),
            1,
            "forced flush must report that it terminated an open update"
        );
        assert_eq!(
            row_text(term, 0),
            "XYZZZZZ",
            "the flush must replay the buffered bytes into the grid"
        );
        assert_idle(term, "after a forced flush");
        bb_term_free(term);
    }
}

#[test]
fn unforced_flush_declines_while_the_core_deadline_is_still_live() {
    // `force == 0` is the only value production passes: the core
    // re-checks its own deadline, so a Swift-side logic bug physically
    // cannot tear a frame a TUI legitimately asked for.
    unsafe {
        let term = new_term();
        feed(term, b"XY");
        feed(term, b"\x1b[?2026hZZZ");

        let before = bb_term_sync_status(term);
        assert_ne!(before.pending, 0, "precondition: an update is open");
        let flushed = bb_term_flush_sync_update(term, 0);

        if before.expired == 0 {
            assert_eq!(
                flushed, 0,
                "unforced flush must decline while the core's deadline is live"
            );
            assert_eq!(
                row_text(term, 0),
                "XY",
                "a declined flush must not land buffered bytes"
            );
            let after = bb_term_sync_status(term);
            assert_ne!(
                after.pending, 0,
                "a declined flush must leave the update open"
            );
            assert_eq!(
                after.buffered_bytes, before.buffered_bytes,
                "a declined flush must not drain the buffer"
            );
        } else {
            // Only reachable if this thread was descheduled for longer
            // than the core's whole window between the feed and the
            // status read. Then declining would be the bug.
            assert_eq!(
                flushed, 1,
                "the core reported its deadline elapsed, so an unforced \
                 flush must proceed"
            );
            assert_eq!(row_text(term, 0), "XYZZZ");
        }
        bb_term_free(term);
    }
}

#[test]
fn unforced_flush_lands_bytes_once_the_core_deadline_expires() {
    // The headline BUG-7 assertion. Note what is deliberately NOT
    // asserted: that vte aborted by itself. It does not, and cannot —
    // hence `expired == 1 && pending == 1` with the grid still empty.
    unsafe {
        let term = new_term();
        feed(term, b"XY");
        feed(term, b"\x1b[?2026hZZZ");

        std::thread::sleep(PAST_THE_WINDOW);

        let s = bb_term_sync_status(term);
        assert_ne!(
            s.pending, 0,
            "the update must still be open — vte never self-aborts without \
             further input, which is precisely BUG-7"
        );
        assert_ne!(
            s.expired, 0,
            "the core must report its own deadline as elapsed"
        );
        assert_eq!(
            s.remaining_ns, 0,
            "remaining_ns must clamp to 0 once the deadline has passed"
        );
        assert_eq!(
            row_text(term, 0),
            "XY",
            "expiry alone must not land bytes — the embedder has to ask"
        );

        assert_eq!(
            bb_term_flush_sync_update(term, 0),
            1,
            "an UNFORCED flush must succeed once the core's deadline elapsed"
        );
        assert_eq!(
            row_text(term, 0),
            "XYZZZ",
            "the stalled frame must become visible"
        );
        assert_idle(term, "after an expiry-driven flush");
        bb_term_free(term);
    }
}

#[test]
fn repeated_flush_is_idempotent_and_never_replays_twice() {
    // The watchdog's re-arm loop calls this repeatedly; a second call
    // replaying the same buffer would duplicate a whole frame's output.
    unsafe {
        let term = new_term();
        feed(term, b"XY");
        feed(term, b"\x1b[?2026hZZZ");

        assert_eq!(bb_term_flush_sync_update(term, 1), 1, "first flush");
        let once = row_text(term, 0);
        assert_eq!(once, "XYZZZ", "first flush replays exactly once");

        assert_eq!(
            bb_term_flush_sync_update(term, 1),
            0,
            "a second forced flush has nothing left to terminate"
        );
        assert_eq!(
            bb_term_flush_sync_update(term, 0),
            0,
            "an unforced flush after a forced one is also a no-op"
        );
        assert_eq!(
            row_text(term, 0),
            once,
            "buffered bytes must not be replayed a second time"
        );
        assert_idle(term, "after repeated flushes");
        bb_term_free(term);
    }
}

#[test]
fn a_new_bsu_after_a_forced_flush_opens_a_fresh_update() {
    // Guarantees the watchdog's loop terminates: a flush always leaves
    // `pending == 0`, and only NEW input can re-open an update.
    unsafe {
        let term = new_term();
        feed(term, b"XY");
        feed(term, b"\x1b[?2026hZZZ");
        assert_eq!(bb_term_flush_sync_update(term, 1), 1, "first flush");

        feed(term, b"\x1b[?2026hQQ");
        let s = bb_term_sync_status(term);
        assert_ne!(s.pending, 0, "a post-flush BSU must open a NEW update");
        assert_eq!(s.expired, 0, "the new update starts unexpired");
        assert!(
            s.remaining_ns > 0 && s.remaining_ns <= VTE_SYNC_WINDOW_NS,
            "the new deadline must sit inside a fresh window, got {}ns",
            s.remaining_ns
        );
        assert!(
            (2..=10).contains(&s.buffered_bytes),
            "buffered_bytes {} does not account for the 2 withheld bytes",
            s.buffered_bytes
        );
        assert_eq!(
            row_text(term, 0),
            "XYZZZ",
            "the second region's bytes must be withheld too"
        );

        assert_eq!(bb_term_flush_sync_update(term, 1), 1, "second flush");
        assert_eq!(row_text(term, 0), "XYZZZQQ");
        assert_idle(term, "after the second flush");
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// (c) A complete BSU..ESU pair needs no flush at all
// ---------------------------------------------------------------------------

#[test]
fn complete_bsu_esu_pair_renders_without_any_flush() {
    // The happy path must be byte-identical to pre-fix behaviour: ESU
    // does the work, the new FFI observes an idle terminal, and a flush
    // call finds nothing to do.
    unsafe {
        let term = new_term();
        feed(term, b"\x1b[?2026h\x1b[2JHELLO\x1b[?2026l");

        assert_eq!(
            row_text(term, 0),
            "HELLO",
            "a complete region must land on ESU with no embedder help"
        );
        assert_idle(term, "after ESU");
        assert_eq!(
            bb_term_flush_sync_update(term, 1),
            0,
            "there is nothing to terminate after a complete region"
        );
        assert_eq!(
            row_text(term, 0),
            "HELLO",
            "the no-op flush must not disturb the rendered frame"
        );
        bb_term_free(term);
    }
}

#[test]
fn esu_arriving_in_a_later_chunk_closes_the_update_without_a_flush() {
    // The slow-but-alive producer. `pending` must go true then false on
    // its own; if the watchdog ever saw this as stuck it would tear a
    // frame the TUI legitimately asked for.
    unsafe {
        let term = new_term();
        feed(term, b"\x1b[?2026h");
        assert_ne!(
            bb_term_sync_status(term).pending,
            0,
            "precondition: the region is open"
        );
        feed(term, b"ABC");
        assert_ne!(
            bb_term_sync_status(term).pending,
            0,
            "still open before ESU"
        );
        feed(term, b"\x1b[?2026l");

        assert_idle(term, "after a late ESU");
        assert_eq!(
            row_text(term, 0),
            "ABC",
            "the whole region must land atomically on ESU"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// (d) The flush is a harmless no-op when nothing is pending
// ---------------------------------------------------------------------------

#[test]
fn flush_is_a_harmless_no_op_when_nothing_is_pending() {
    // The Swift watchdog is allowed to call this speculatively, and
    // `bb_term_clear_all` calls it unconditionally on every ⌘K. Both
    // depend on "nothing pending" costing exactly nothing observable:
    // no grid change, no cursor move, no event.
    unsafe {
        let sink = Sink::default();
        let term = new_term();
        bb_term_set_event_cb(term, Some(capture), &sink as *const _ as *mut c_void);
        feed(term, b"HELLO");
        let before = grid_shape(term);

        assert_eq!(
            bb_term_flush_sync_update(term, 0),
            0,
            "unforced flush with nothing pending must report no-op"
        );
        assert_eq!(
            bb_term_flush_sync_update(term, 1),
            0,
            "FORCED flush with nothing pending must also report no-op — \
             force means 'ignore the deadline', not 'invent an update'"
        );

        assert_eq!(
            grid_shape(term),
            before,
            "a no-op flush must not disturb grid, cursor or mode"
        );
        assert_idle(term, "after a no-op flush");
        assert_eq!(
            sink.event_count(),
            0,
            "a no-op flush must not fire events, got {:?}",
            sink.events.lock().unwrap()
        );
        bb_term_free(term);
    }
}

#[test]
fn sync_status_on_a_null_term_is_all_zero() {
    // Null must read as "nothing pending" — the fail-safe direction:
    // preserve the status quo rather than tear a frame we cannot reason
    // about.
    unsafe {
        let s = bb_term_sync_status(std::ptr::null_mut());
        assert_eq!(s.pending, 0, "null term must report nothing pending");
        assert_eq!(s.expired, 0, "null term must not report expiry");
        assert_eq!(s.remaining_ns, 0, "null term must report no deadline");
        assert_eq!(s.buffered_bytes, 0, "null term must report an empty buffer");
    }
}

#[test]
fn flush_on_a_null_term_returns_zero() {
    unsafe {
        assert_eq!(
            bb_term_flush_sync_update(std::ptr::null_mut(), 0),
            0,
            "unforced flush on null must be a no-op"
        );
        assert_eq!(
            bb_term_flush_sync_update(std::ptr::null_mut(), 1),
            0,
            "forced flush on null must be a no-op"
        );
    }
}

// ---------------------------------------------------------------------------
// (e) A trailing ESU after a forced flush is inert
// ---------------------------------------------------------------------------

#[test]
fn trailing_esu_after_a_forced_flush_is_inert() {
    // After the watchdog aborts a stalled frame, the producer may still
    // be alive and send its ESU late (slow ssh, resumed process). That
    // orphaned ESU must be a no-op, not a grid corruption and not a
    // wedge.
    //
    // Oracle: a second terminal fed the same visible text that never saw
    // mode 2026 at all. Comparing whole `GridShape`s (rows + cursor +
    // mode + scroll state) rather than a hand-written expected string
    // means an ESU that quietly perturbed, say, the cursor or a mode bit
    // still fails this test.
    unsafe {
        let stray_sink = Sink::default();
        let control_sink = Sink::default();
        let stray = new_term();
        let control = new_term();
        bb_term_set_event_cb(stray, Some(capture), &stray_sink as *const _ as *mut c_void);
        bb_term_set_event_cb(
            control,
            Some(capture),
            &control_sink as *const _ as *mut c_void,
        );

        feed(stray, b"XY");
        feed(stray, b"\x1b[?2026hZZZ");
        assert_eq!(
            bb_term_flush_sync_update(stray, 1),
            1,
            "precondition: the stalled frame was aborted"
        );
        // The orphan: its BSU was consumed by the flush long ago.
        feed(stray, b"\x1b[?2026l");
        feed(stray, b"!");

        feed(control, b"XYZZZ!");

        assert_eq!(
            grid_shape(stray),
            grid_shape(control),
            "a trailing ESU must be inert — the flushed terminal must match \
             one that never saw mode 2026"
        );
        assert_idle(stray, "after a trailing ESU");

        // Not wedged, leg 1: it still answers a mode query, with the same
        // bytes the control terminal answers. `?2026` is spec'd to report
        // Reset (`;2`) regardless of parser-internal sync state, so a
        // divergence here would mean the stray ESU left mode state behind.
        feed(stray, b"\x1b[?2026$p");
        feed(control, b"\x1b[?2026$p");
        let stray_writes = stray_sink.of_kind(BBEventKind::PtyWrite);
        assert_eq!(
            stray_writes,
            vec![(0, b"\x1b[?2026;2$y".to_vec())],
            "DECRQM ?2026 must still answer 'supported, inactive'"
        );
        assert_eq!(
            stray_writes,
            control_sink.of_kind(BBEventKind::PtyWrite),
            "the flushed terminal must answer exactly like the control"
        );

        // Not wedged, leg 2: it still renders new output immediately.
        feed(stray, b"?");
        assert_eq!(
            row_text(stray, 0),
            "XYZZZ!?",
            "the terminal must keep rendering after a trailing ESU"
        );
        assert_idle(stray, "after post-ESU output");

        bb_term_free(stray);
        bb_term_free(control);
    }
}

// ---------------------------------------------------------------------------
// Side effects the flush owes (and the ones it must not duplicate)
// ---------------------------------------------------------------------------

#[test]
fn forced_flush_delivers_colour_query_replies_buffered_inside_the_region() {
    // A silent-failure sibling of BUG-7: an `OSC 11 ?` issued inside a
    // stalled region queues a reply that only resolves on the next
    // parser advance — and from a dead producer there is no next input.
    // The flush must discharge the same post-advance tail `bb_term_input`
    // does, or the TUI waits forever for its background colour.
    unsafe {
        let sink = Sink::default();
        let term = new_term();
        bb_term_set_event_cb(term, Some(capture), &sink as *const _ as *mut c_void);
        // Replies are off by default (the zsh-vi-mode mitigation).
        bb_term_set_color_query_enabled(term, 1);

        feed(term, b"\x1b[?2026h\x1b]11;?\x1b\\");
        assert_eq!(
            sink.of_kind(BBEventKind::PtyWrite).len(),
            0,
            "the reply must be withheld while the region is open"
        );

        assert_eq!(
            bb_term_flush_sync_update(term, 1),
            1,
            "precondition: the stalled region was flushed"
        );

        let writes = sink.of_kind(BBEventKind::PtyWrite);
        assert_eq!(
            writes.len(),
            1,
            "the flush must resolve exactly one deferred colour query, got {writes:?}"
        );
        let reply = String::from_utf8(writes[0].1.clone()).expect("reply must be UTF-8");
        assert!(
            reply.starts_with("\x1b]11;rgb:"),
            "expected an OSC 11 rgb reply, got {reply:?}"
        );
        assert!(
            reply.ends_with("\x1b\\"),
            "ST-terminated query must get an ST-terminated reply, got {reply:?}"
        );
        bb_term_free(term);
    }
}

#[test]
fn flush_does_not_refire_prompt_marks_already_seen_at_feed_time() {
    // The parallel OSC scanner runs over the RAW chunk, independent of
    // sync state, so OSC 133 / OSC 7 fire at feed time even inside an
    // open region. The flush replays only through the grid processor; if
    // it ever re-fed the buffer to the OSC scanner, every prompt mark and
    // cwd change inside a stalled frame would fire twice and corrupt
    // prompt navigation.
    unsafe {
        let sink = Sink::default();
        let term = new_term();
        bb_term_set_event_cb(term, Some(capture), &sink as *const _ as *mut c_void);

        feed(term, b"\x1b[?2026h\x1b]133;A\x1b\\hello");
        let at_feed = sink.of_kind(BBEventKind::PromptMark);
        assert_eq!(
            at_feed,
            vec![(1, Vec::new())],
            "an A mark inside an open region must still fire once at feed time"
        );
        assert_eq!(
            row_text(term, 0),
            "",
            "precondition: the region's text is still withheld"
        );

        assert_eq!(bb_term_flush_sync_update(term, 1), 1, "flush the region");

        assert_eq!(
            sink.of_kind(BBEventKind::PromptMark),
            at_feed,
            "the replay must not re-fire prompt marks the scanner already saw"
        );
        assert_eq!(
            row_text(term, 0),
            "hello",
            "the withheld text must land on flush"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// ⌘K must escape a wedged region (the BUG-7 sibling in bb_term_clear_all)
// ---------------------------------------------------------------------------

#[test]
fn clear_all_escapes_a_wedged_sync_update() {
    // `bb_term_clear_all` drives the wipe by feeding `ESC[H ESC[2J
    // ESC[3J` through the same parser — which, with a sync update
    // pending, buffers those bytes instead of applying them. So ⌘K, the
    // user's only manual escape hatch from a frozen tab, did nothing AND
    // left up to 2 MiB of adversary-controlled bytes alive across the
    // "wipe". After the fix the clear must both take effect and leave the
    // parser idle.
    unsafe {
        let term = new_term();
        feed(term, b"visible");
        feed(term, b"\x1b[?2026hBOOM");
        assert_eq!(
            row_text(term, 0),
            "visible",
            "precondition: the terminal is wedged with BOOM buffered"
        );
        assert_ne!(
            bb_term_sync_status(term).pending,
            0,
            "precondition: an update is open"
        );

        bb_term_clear_all(term);

        assert_idle(term, "after clear_all");
        let shape = grid_shape(term);
        assert!(
            shape.rows.iter().all(|r| r.is_empty()),
            "clear_all must wipe the grid, including bytes it had to replay \
             to get there, got {:?}",
            shape.rows
        );
        assert_eq!(shape.cursor_row, 0, "clear_all homes the cursor");
        assert_eq!(shape.cursor_col, 0, "clear_all homes the cursor");
        assert_eq!(
            shape.history_size, 0,
            "clear_all must wipe scrollback as well as the viewport"
        );

        feed(term, b"AFTER");
        assert_eq!(
            row_text(term, 0),
            "AFTER",
            "the terminal must be usable again after ⌘K"
        );
        assert_idle(term, "after post-clear output");
        bb_term_free(term);
    }
}
