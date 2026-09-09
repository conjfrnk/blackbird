//! Blind behaviour tests for the OSC tap after a prompt mark.
//!
//! `bb_term_input` runs a side parser ("the tap") that only cares about a
//! few OSC sequences alacritty ignores (OSC 7 cwd, OSC 133 marks). The tap
//! is latched on/off around OSC introducers so plain text doesn't pay for
//! a second parser pass. The observable contract this file pins:
//!
//!   1. After an ST-terminated prompt mark, 1 MiB of plain text must not be
//!      measurably slower than without the mark (the latch must release).
//!      That one is a timing test, so it is `#[ignore]` — see below.
//!   2. Deterministically: after the mark, an OSC 7 split across two
//!      `bb_term_input` calls — BEL-terminated, ST-terminated, split inside
//!      the ST, or split inside the `ESC ]` introducer — still yields
//!      exactly one CwdChanged with the right path.
//!
//! Cost: the deterministic tests feed < 100 bytes each. The two tests that
//! feed 1 MiB allocate one 1 MiB buffer and drive it in 64 KiB chunks
//! against an 80×24 grid with 1000 lines of scrollback (< 4 MB total).

use std::ffi::c_void;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use blackbird_core::*;

const PROMPT_MARK_ST: &[u8] = b"\x1b]133;A\x1b\\";
const CHUNK: usize = 64 * 1024;
const MIB: usize = 1024 * 1024;

struct Sink {
    events: Mutex<Vec<(u32, Vec<u8>, i32)>>,
}

impl Sink {
    fn new() -> Self {
        Sink {
            events: Mutex::new(Vec::new()),
        }
    }
    fn cwd_changes(&self) -> Vec<Vec<u8>> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|(k, _, _)| *k == BBEventKind::CwdChanged as u32)
            .map(|(_, p, _)| p.clone())
            .collect()
    }
    fn prompt_marks(&self) -> Vec<i32> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|(k, _, _)| *k == BBEventKind::PromptMark as u32)
            .map(|(_, _, a)| *a)
            .collect()
    }
    fn fatals(&self) -> usize {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|(k, _, _)| *k == BBEventKind::Fatal as u32)
            .count()
    }
}

extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = unsafe { &*(ctx as *const Sink) };
    let bytes = if ev.len == 0 || ev.payload.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ev.payload, ev.len).to_vec() }
    };
    sink.events
        .lock()
        .unwrap()
        .push((ev.kind as u32, bytes, ev.i32_arg));
}

unsafe fn make_term(sink: &Sink) -> *mut BBTerm {
    let term = bb_term_new(80, 24, 1000);
    assert!(!term.is_null());
    bb_term_set_event_cb(term, Some(cb), sink as *const Sink as *mut c_void);
    term
}

unsafe fn feed(term: *mut BBTerm, bytes: &[u8]) {
    bb_term_input(term, bytes.as_ptr(), bytes.len());
}

/// Feed `chunks` in order after an ST-terminated prompt mark; return the
/// sink for inspection.
fn drive_after_mark(chunks: &[&[u8]]) -> Sink {
    let sink = Sink::new();
    unsafe {
        let term = make_term(&sink);
        feed(term, PROMPT_MARK_ST);
        for c in chunks {
            feed(term, c);
        }
        bb_term_free(term);
    }
    assert_eq!(
        sink.prompt_marks(),
        vec![1],
        "the A mark itself must fire once"
    );
    assert_eq!(sink.fatals(), 0);
    sink
}

// ---------------------------------------------------------------------------
// Deterministic fragmentation checks
// ---------------------------------------------------------------------------

#[test]
fn osc7_split_mid_path_bel_terminated_after_mark() {
    let sink = drive_after_mark(&[b"\x1b]7;file://localhost/tmp", b"/x\x07"]);
    assert_eq!(
        sink.cwd_changes(),
        vec![b"/tmp/x".to_vec()],
        "exactly one CwdChanged for /tmp/x"
    );
}

#[test]
fn osc7_split_mid_path_st_terminated_after_mark() {
    let sink = drive_after_mark(&[b"\x1b]7;file://localhost/tm", b"p\x1b\\"]);
    assert_eq!(sink.cwd_changes(), vec![b"/tmp".to_vec()]);
}

#[test]
fn osc7_split_inside_st_terminator_after_mark() {
    // ESC of the ST at the end of one chunk, the backslash opens the next.
    let sink = drive_after_mark(&[b"\x1b]7;file://localhost/tmp\x1b", b"\\"]);
    assert_eq!(sink.cwd_changes(), vec![b"/tmp".to_vec()]);
}

#[test]
fn osc7_split_inside_introducer_after_mark() {
    // ESC ends one chunk, `]7;…` starts the next. A latch keyed on "does this
    // chunk contain ESC ]" would miss this one.
    let sink = drive_after_mark(&[b"prompt$ \x1b", b"]7;file://localhost/tmp\x07"]);
    assert_eq!(sink.cwd_changes(), vec![b"/tmp".to_vec()]);
}

#[test]
fn osc7_byte_at_a_time_after_mark() {
    let seq: &[u8] = b"\x1b]7;file://localhost/Users/foo/bar\x1b\\";
    let chunks: Vec<&[u8]> = seq.chunks(1).collect();
    let sink = drive_after_mark(&chunks);
    assert_eq!(sink.cwd_changes(), vec![b"/Users/foo/bar".to_vec()]);
}

#[test]
fn osc7_after_mark_and_1mib_of_plain_text_still_fires() {
    // The latch must not stay "armed" or "disarmed" permanently: after a
    // mark and a megabyte of text, both a fresh OSC 7 and a fresh mark work.
    let line = b"the quick brown fox jumps over the lazy dog 0123456789\n";
    let text: Vec<u8> = line.iter().copied().cycle().take(MIB).collect();
    let sink = Sink::new();
    unsafe {
        let term = make_term(&sink);
        feed(term, PROMPT_MARK_ST);
        for c in text.chunks(CHUNK) {
            feed(term, c);
        }
        feed(term, b"\x1b]7;file://localhost/tmp\x07");
        feed(term, b"\x1b]133;D;0\x1b\\");
        bb_term_free(term);
    }
    assert_eq!(sink.cwd_changes(), vec![b"/tmp".to_vec()]);
    assert_eq!(sink.prompt_marks(), vec![1, 4]);
    assert_eq!(sink.fatals(), 0);
}

#[test]
fn text_between_mark_and_split_osc7_is_not_swallowed() {
    // Plain text after the mark must still land in the grid, and the split
    // OSC 7 afterwards must still be parsed.
    let sink = Sink::new();
    unsafe {
        let term = make_term(&sink);
        feed(term, PROMPT_MARK_ST);
        feed(term, b"hello");
        feed(term, b"\x1b]7;file://localhost/tm");
        feed(term, b"p\x1b\\");
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let row0: Vec<u32> = (0..5).map(|i| (*(*snap).cells.add(i)).ch).collect();
        bb_snap_release(snap);
        bb_term_free(term);
        assert_eq!(
            row0,
            b"hello".iter().map(|&b| b as u32).collect::<Vec<_>>(),
            "text after the mark must reach the grid"
        );
    }
    assert_eq!(sink.cwd_changes(), vec![b"/tmp".to_vec()]);
}

// ---------------------------------------------------------------------------
// Timing check — ignored by default (wall-clock ratios flake on shared CI
// runners). Run explicitly:
//   cargo test -p blackbird_core --test osc_tap_latch_blind --release -- --ignored --nocapture
// ---------------------------------------------------------------------------

unsafe fn time_feed(prefix: Option<&[u8]>, text: &[u8]) -> Duration {
    let sink = Sink::new();
    let term = make_term(&sink);
    if let Some(p) = prefix {
        feed(term, p);
    }
    let start = Instant::now();
    for c in text.chunks(CHUNK) {
        feed(term, c);
    }
    let elapsed = start.elapsed();
    bb_term_free(term);
    elapsed
}

#[test]
#[ignore = "wall-clock ratio; flaky on shared CI runners — run with --ignored --nocapture in release"]
fn plain_text_after_prompt_mark_is_not_slower_than_without() {
    let line = b"the quick brown fox jumps over the lazy dog 0123456789\n";
    let text: Vec<u8> = line.iter().copied().cycle().take(MIB).collect();

    let min = |prefix: Option<&[u8]>| unsafe {
        let a = time_feed(prefix, &text);
        let b = time_feed(prefix, &text);
        a.min(b)
    };
    let without = min(None);
    let with = min(Some(PROMPT_MARK_ST));
    let ratio = with.as_secs_f64() / without.as_secs_f64();
    eprintln!("1 MiB plain: without mark {without:?}, after mark {with:?}, ratio {ratio:.2}");
    assert!(
        ratio < 1.5,
        "plain text after an ST-terminated prompt mark ran {ratio:.2}× slower — \
         the OSC tap latch is not releasing"
    );
}
