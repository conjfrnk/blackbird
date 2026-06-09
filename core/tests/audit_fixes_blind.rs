//! Blind regression tests for the 2026-06 audit fixes, written against the
//! public C FFI surface (core/include/BBCore.h) and the behavioral spec
//! only — never the implementation.
//!
//! Contracts pinned here:
//! - S5-001: zero-width scalars (combining marks, VS16) survive
//!   `bb_term_text_range` extraction.
//! - S5-002: prose extraction is WRAPLINE-aware — soft-wrapped rows join
//!   with no '\n', hard newlines keep exactly one, wrap-boundary spaces
//!   are preserved.
//! - S5-009: prompt-mark rate cap (240/s) admits interactive-scale bursts
//!   in full while still capping floods.
//! - S6-001: BBEvent payload nullability — `payload == NULL ⇔ len == 0`.
//! - S1-002: Title (≤ 32/s) and Bell (≤ 16/s) rate caps.
//! - S5-004/S5-005: BBSnap::lines_scrolled is a monotonic scroll counter
//!   that keeps growing after history_size saturates.
//!
//! Pre-flight memory budget: largest grid is 80×24 (< 100 KB of cells);
//! largest feed is 1000 × 11 B ≈ 11 KB. Everything well under 1 MB.

use blackbird_core::*;
use std::ffi::c_void;
use std::sync::Mutex;

// ---------------------------------------------------------------------------
// Event-capture plumbing (cribbed from core/tests/osc133.rs, extended to
// record payload nullability for the S6-001 contract).
// ---------------------------------------------------------------------------

/// One recorded BBEvent. `payload_null` is sampled BEFORE any copy so the
/// nullability invariant is observed exactly as the C callback saw it.
#[derive(Clone)]
struct EventRec {
    kind: u32,
    payload_null: bool,
    len: usize,
    bytes: Vec<u8>,
    i32_arg: i32,
}

#[derive(Default)]
struct Capture {
    events: Vec<EventRec>,
}

fn install_capture(term: *mut BBTerm) -> Box<Mutex<Capture>> {
    let cap = Box::new(Mutex::new(Capture::default()));
    let ctx = Box::as_ref(&cap) as *const Mutex<Capture> as *mut c_void;
    unsafe {
        bb_term_set_event_cb(term, Some(trampoline), ctx);
    }
    cap
}

unsafe extern "C" fn trampoline(ev: BBEvent, ctx: *mut c_void) {
    let m = &*(ctx as *const Mutex<Capture>);
    let payload_null = ev.payload.is_null();
    let bytes = if ev.len > 0 && !payload_null {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    m.lock().unwrap().events.push(EventRec {
        kind: ev.kind as u32,
        payload_null,
        len: ev.len,
        bytes,
        i32_arg: ev.i32_arg,
    });
}

const KIND_TITLE: u32 = 1; // BB_EVENT_KIND_TITLE
const KIND_BELL: u32 = 2; // BB_EVENT_KIND_BELL
const KIND_PROMPT_MARK: u32 = 7; // BB_EVENT_KIND_PROMPT_MARK

// ---------------------------------------------------------------------------
// Text-extraction helper (cribbed from core/tests/text_range_bounds.rs —
// tolerates the documented `bytes == NULL ⇔ len == 0` empty shape).
// ---------------------------------------------------------------------------

/// Run `bb_term_text_range` and decode the reply as UTF-8. Panics on a
/// null reply (none of these scenarios should produce one).
fn extract(
    term: *mut BBTerm,
    start_line: i32,
    start_col: u16,
    end_line: i32,
    end_col: u16,
    rect: u8,
) -> String {
    unsafe {
        let raw = bb_term_text_range(term, start_line, start_col, end_line, end_col, rect);
        assert!(!raw.is_null(), "bb_term_text_range returned null");
        let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
            &[]
        } else {
            std::slice::from_raw_parts((*raw).bytes, (*raw).len)
        };
        let s = std::str::from_utf8(bytes)
            .expect("text_range reply must be valid UTF-8")
            .to_string();
        bb_string_release(raw);
        s
    }
}

// ---------------------------------------------------------------------------
// 1. Zero-width retention (audit S5-001)
// ---------------------------------------------------------------------------

#[test]
fn zero_width_combining_mark_survives_extraction() {
    // 'e' + U+0301 COMBINING ACUTE ACCENT occupy one cell; extraction over
    // that cell must keep the combining mark after the base char.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        let seq = b"e\xcc\x81"; // e + U+0301
        bb_term_input(term, seq.as_ptr(), seq.len());

        let got = extract(term, 0, 0, 0, 0, 0);
        assert!(
            got.contains("e\u{301}"),
            "S5-001: combining U+0301 must survive extraction after 'e'; got {got:?}"
        );
        bb_term_free(term);
    }
}

#[test]
fn vs16_variation_selector_survives_extraction() {
    // U+26A0 WARNING SIGN + VS16 (U+FE0F) — the emoji-presentation
    // sequence. The VS16 zero-width mark must come back out of
    // bb_term_text_range.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        let seq = b"\xe2\x9a\xa0\xef\xb8\x8f"; // U+26A0 U+FE0F
        bb_term_input(term, seq.as_ptr(), seq.len());

        let got = extract(term, 0, 0, 0, 9, 0);
        assert!(
            got.contains('\u{26a0}'),
            "base scalar U+26A0 missing from extraction; got {got:?}"
        );
        assert!(
            got.contains('\u{fe0f}'),
            "S5-001: VS16 U+FE0F must survive extraction; got {got:?}"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// 2. WRAPLINE awareness (audit S5-002)
// ---------------------------------------------------------------------------

#[test]
fn soft_wrapped_line_extracts_without_newline() {
    // 120 'a's on an 80-col grid soft-wrap onto row 1. Extracting both
    // rows in prose mode must yield the 120 'a's contiguously — no '\n'
    // injected at the wrap point.
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        assert!(!term.is_null());
        let feed = [b'a'; 120];
        bb_term_input(term, feed.as_ptr(), feed.len());

        let got = extract(term, 0, 0, 1, 79, 0);
        assert!(
            !got.contains('\n'),
            "S5-002: soft-wrapped rows must join without '\\n'; got {got:?}"
        );
        assert_eq!(
            got.trim_end_matches(' '),
            "a".repeat(120),
            "S5-002: all 120 'a's must extract contiguously; got {got:?}"
        );
        bb_term_free(term);
    }
}

#[test]
fn hard_newline_extracts_with_exactly_one_newline() {
    // `bbb\r\nccc` is a HARD line break — extraction of the two rows must
    // contain exactly one '\n' between bbb and ccc.
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        assert!(!term.is_null());
        let feed = b"bbb\r\nccc";
        bb_term_input(term, feed.as_ptr(), feed.len());

        let got = extract(term, 0, 0, 1, 79, 0);
        assert_eq!(
            got.matches('\n').count(),
            1,
            "hard newline must produce exactly one '\\n'; got {got:?}"
        );
        let (first, second) = got.split_once('\n').expect("one newline present");
        assert_eq!(
            first.trim_end_matches(' '),
            "bbb",
            "row 0 content wrong; got {got:?}"
        );
        assert_eq!(
            second.trim_end_matches(' '),
            "ccc",
            "row 1 content wrong; got {got:?}"
        );
        bb_term_free(term);
    }
}

#[test]
fn wrap_boundary_space_is_preserved() {
    // 79 'b's + ' ' + 'x': the space lands at col 79 (last column), the
    // line wraps, 'x' sits at row 1 col 0. Extracting both rows must keep
    // the space — result "b"*79 + " " + "x" with no newline.
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        assert!(!term.is_null());
        let mut feed = vec![b'b'; 79];
        feed.push(b' ');
        feed.push(b'x');
        bb_term_input(term, feed.as_ptr(), feed.len());

        let got = extract(term, 0, 0, 1, 79, 0);
        assert!(
            !got.contains('\n'),
            "S5-002: wrapped rows must join without '\\n'; got {got:?}"
        );
        let want = format!("{} x", "b".repeat(79));
        assert_eq!(
            got.trim_end_matches(' '),
            want,
            "S5-002: the wrap-boundary space at col 79 must be preserved; got {got:?}"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// 3. Prompt-mark interactive rates (audit S5-009)
// ---------------------------------------------------------------------------

#[test]
fn interactive_prompt_mark_burst_is_delivered_in_full() {
    // 10 back-to-back shell-integration cycles (C, D;0, A, B = 4 marks
    // each → 40 total) in ONE bb_term_input call. Interactive-scale
    // bursts sit far below the 240/s cap and must not be dropped.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        let cap = install_capture(term);

        let cycle = b"\x1b]133;C\x1b\\\x1b]133;D;0\x1b\\\x1b]133;A\x1b\\\x1b]133;B\x1b\\";
        let mut feed = Vec::with_capacity(cycle.len() * 10);
        for _ in 0..10 {
            feed.extend_from_slice(cycle);
        }
        bb_term_input(term, feed.as_ptr(), feed.len());

        let events = cap.lock().unwrap().events.clone();
        let marks: Vec<i32> = events
            .iter()
            .filter(|e| e.kind == KIND_PROMPT_MARK)
            .map(|e| e.i32_arg)
            .collect();
        assert_eq!(
            marks.len(),
            40,
            "S5-009: all 40 interactive-burst prompt marks must be delivered; got {}",
            marks.len()
        );
        assert!(
            marks.iter().all(|&k| (1..=4).contains(&k)),
            "every PromptMark i32_arg must be 1..=4; got {marks:?}"
        );
        // 10 cycles → exactly 10 of each kind.
        for kind in 1..=4 {
            let n = marks.iter().filter(|&&k| k == kind).count();
            assert_eq!(n, 10, "expected 10 marks of kind {kind}, got {n}");
        }
        bb_term_free(term);
    }
}

#[test]
fn prompt_mark_flood_is_capped_at_240() {
    // 1000 OSC 133;A in one call: the documented per-second cap is 240.
    // The limiter is a cap, not a kill-switch — at least one must land.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        let cap = install_capture(term);

        let one = b"\x1b]133;A\x07";
        let mut feed = Vec::with_capacity(one.len() * 1000);
        for _ in 0..1000 {
            feed.extend_from_slice(one);
        }
        bb_term_input(term, feed.as_ptr(), feed.len());

        let events = cap.lock().unwrap().events.clone();
        let n = events.iter().filter(|e| e.kind == KIND_PROMPT_MARK).count();
        assert!(
            n <= 240,
            "S5-009: prompt-mark flood must be capped at 240/s; got {n}"
        );
        assert!(n >= 1, "rate limiter must not drop everything; got {n}");
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// 4. BBEvent payload nullability (audit S6-001)
// ---------------------------------------------------------------------------

#[test]
fn empty_payload_events_carry_null_pointer() {
    // Empty-payload prompt mark + empty title: every event delivered with
    // len == 0 must carry payload == NULL (the `payload == NULL ⇔ len == 0`
    // invariant from the header).
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        let cap = install_capture(term);

        let seq = b"\x1b]133;A\x07\x1b]0;\x07";
        bb_term_input(term, seq.as_ptr(), seq.len());

        let events = cap.lock().unwrap().events.clone();
        // The empty-payload prompt mark must have fired so the invariant
        // check below is not vacuous.
        assert!(
            events
                .iter()
                .any(|e| e.kind == KIND_PROMPT_MARK && e.len == 0),
            "expected an empty-payload PromptMark event"
        );
        for e in &events {
            if e.len == 0 {
                assert!(
                    e.payload_null,
                    "S6-001: event kind {} with len == 0 must carry payload == NULL",
                    e.kind
                );
            }
        }
        bb_term_free(term);
    }
}

#[test]
fn nonempty_payload_event_carries_valid_pointer() {
    // OSC 133;D;0 — the exit code "0" rides the payload: len 1, non-null,
    // bytes read back as b"0".
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        let cap = install_capture(term);

        let seq = b"\x1b]133;D;0\x07";
        bb_term_input(term, seq.as_ptr(), seq.len());

        let events = cap.lock().unwrap().events.clone();
        let d_marks: Vec<&EventRec> = events
            .iter()
            .filter(|e| e.kind == KIND_PROMPT_MARK && e.i32_arg == 4)
            .collect();
        assert_eq!(d_marks.len(), 1, "expected exactly one D PromptMark");
        let d = d_marks[0];
        assert_eq!(d.len, 1, "D;0 payload must have len 1");
        assert!(
            !d.payload_null,
            "S6-001: non-empty payload must be non-null"
        );
        assert_eq!(d.bytes, b"0", "D payload must read back as b\"0\"");
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// 5. Title / Bell rate caps (audit S1-002)
// ---------------------------------------------------------------------------

#[test]
fn title_flood_is_capped_at_32_per_second() {
    // 200 title sets in one call land in a single rolling-second window:
    // delivered Title events must be ≤ 32 and ≥ 1.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        let cap = install_capture(term);

        let one = b"\x1b]0;t\x07";
        let mut feed = Vec::with_capacity(one.len() * 200);
        for _ in 0..200 {
            feed.extend_from_slice(one);
        }
        bb_term_input(term, feed.as_ptr(), feed.len());

        let events = cap.lock().unwrap().events.clone();
        let n = events.iter().filter(|e| e.kind == KIND_TITLE).count();
        assert!(
            n <= 32,
            "S1-002: title flood must be capped at 32/s; got {n}"
        );
        assert!(n >= 1, "title cap must not drop everything; got {n}");
        bb_term_free(term);
    }
}

#[test]
fn bell_flood_is_capped_at_16_per_second() {
    // 200 raw BEL bytes in one call: delivered Bell events ≤ 16 and ≥ 1.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert!(!term.is_null());
        let cap = install_capture(term);

        let feed = [0x07u8; 200];
        bb_term_input(term, feed.as_ptr(), feed.len());

        let events = cap.lock().unwrap().events.clone();
        let n = events.iter().filter(|e| e.kind == KIND_BELL).count();
        assert!(
            n <= 16,
            "S1-002: bell flood must be capped at 16/s; got {n}"
        );
        assert!(n >= 1, "bell cap must not drop everything; got {n}");
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// 6. lines_scrolled counter (audits S5-004 / S5-005)
// ---------------------------------------------------------------------------

#[test]
fn lines_scrolled_is_monotonic_and_outgrows_history_size() {
    // 10×4 grid, 100-line scrollback. lines_scrolled starts at 0, grows
    // as lines flow off-screen, and — unlike history_size, which plateaus
    // at the cap — keeps growing after the ring saturates.
    unsafe {
        let term = bb_term_new(10, 4, 100);
        assert!(!term.is_null());

        // Fresh term: counter is 0.
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let ls0 = (*snap).lines_scrolled;
        bb_snap_release(snap);
        assert_eq!(ls0, 0, "fresh terminal must report lines_scrolled == 0");

        // Feed 8 lines on a 4-row grid: roughly 8 - (rows - 1) = 5 lines
        // scroll into history; cursor-row mechanics give a small tolerance
        // band of [5, 10].
        let mut feed = Vec::new();
        for _ in 0..8 {
            feed.extend_from_slice(b"x\r\n");
        }
        bb_term_input(term, feed.as_ptr(), feed.len());

        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let ls1 = (*snap).lines_scrolled;
        bb_snap_release(snap);
        assert!(
            ls1 > ls0,
            "lines_scrolled must strictly grow after 8 fed lines; {ls0} -> {ls1}"
        );
        assert!(
            (5..=10).contains(&ls1),
            "after 8 lines on a 4-row grid lines_scrolled should land in [5, 10]; got {ls1}"
        );

        // Feed 200 more lines: history_size saturates at the 100-line cap
        // but lines_scrolled keeps counting past it. Snapshot every 50
        // lines to pin monotonicity across consecutive snapshots.
        let mut prev = ls1;
        for _ in 0..4 {
            let mut chunk = Vec::new();
            for _ in 0..50 {
                chunk.extend_from_slice(b"x\r\n");
            }
            bb_term_input(term, chunk.as_ptr(), chunk.len());

            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            let ls = (*snap).lines_scrolled;
            bb_snap_release(snap);
            assert!(
                ls >= prev,
                "lines_scrolled must never decrease while feeding text; {prev} -> {ls}"
            );
            prev = ls;
        }

        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let ls_final = (*snap).lines_scrolled;
        let hist_final = (*snap).history_size;
        bb_snap_release(snap);

        assert!(
            hist_final <= 100,
            "history_size must saturate at the 100-line cap; got {hist_final}"
        );
        assert!(
            ls_final > ls1,
            "lines_scrolled must keep growing through the 200 extra lines; {ls1} -> {ls_final}"
        );
        assert!(
            ls_final > hist_final as u64,
            "S5-004/S5-005: lines_scrolled ({ls_final}) must outgrow saturated \
             history_size ({hist_final})"
        );

        bb_term_free(term);
    }
}
