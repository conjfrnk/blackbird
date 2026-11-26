//! Blind regression tests for OSC8-c: the over-long `id=` handling and the
//! re-apply markers of the OSC 8 per-terminal live-byte budget.
//!
//! Written from the bug report, the public C surface (`BBCore.h`), the
//! existing OSC 8 tests and the vendor marker test only, without sight of the
//! implementation bodies.
//!
//! The refusal-log truthfulness tests that used to live here (OSC8-c part 1)
//! judged the log with a classifier that treated a hedge phrase ANYWHERE in
//! the log as a hedge on every remedy, so they could only pass. They are
//! replaced by `osc8_refusal_log_truth_blind.rs`, which reads each clause of
//! the log as a claim and compares it with what the core really frees.
//!
//! Contract under test
//! -------------------
//!   1. LONG `id=`. The core never reads the `id=` OSC 8 parameter. An
//!      OSC 8 whose `id=` is longer than 256 bytes but whose URI is
//!      acceptable must still produce a working link (the id may be ignored
//!      or truncated) and must not be refused silently. The parser accepts
//!      an OSC payload of up to ~8 MiB (see `osc8_uri_retention_blind.rs`),
//!      so ids of several KiB reach the grid.
//!   2. RE-APPLY MARKERS. Every `Term` field added for the budget
//!      (`hyperlink_live`, `hyperlink_live_max`, `hyperlink_over_budget`),
//!      at its declaration and at its initialiser, carries the repo's
//!      `Blackbird fix (re-apply on bump)` marker (so a re-vendor of
//!      `alacritty_terminal` can find it), and the vendor marker test
//!      (`vendor_markers_blind.rs`) lists the fields, so dropping a marker
//!      is caught.
//!
//! Pre-flight cost (memory x time): the in-process tests are a few KiB each
//! (the longest `id=` is 64 KiB) plus reading two source files of a few
//! hundred KiB.

use std::ffi::CStr;

use blackbird_core as bc;

// ---------------------------------------------------------------------------
// FFI harness
// ---------------------------------------------------------------------------

/// A snapshot, released on drop.
struct Snap {
    ptr: *const bc::BBSnap,
}

impl Snap {
    fn rows(&self) -> usize {
        unsafe { (*self.ptr).rows as usize }
    }

    fn cols(&self) -> usize {
        unsafe { (*self.ptr).cols as usize }
    }

    /// Unicode scalar printed in the cell (0 = empty).
    fn ch(&self, row: usize, col: usize) -> u32 {
        assert!(
            row < self.rows() && col < self.cols(),
            "cell ({row},{col}) outside the {}x{} snapshot",
            self.rows(),
            self.cols()
        );
        unsafe {
            let len = (*self.ptr).cells_len;
            let idx = row * self.cols() + col;
            assert!(idx < len, "cell index {idx} outside cells_len {len}");
            let cells: &[bc::BBCell] = std::slice::from_raw_parts((*self.ptr).cells, len);
            cells[idx].ch
        }
    }

    /// The URL attributed to a cell, or `None` when it carries no link.
    fn link_url(&self, row: usize, col: usize) -> Option<String> {
        unsafe {
            let id = bc::bb_snap_link_id_at(self.ptr, row as u16, col as u16);
            if id == 0 {
                return None;
            }
            let c = bc::bb_snap_link_url(self.ptr, id);
            assert!(
                !c.is_null(),
                "link id {id} at ({row},{col}) must resolve to a URL"
            );
            Some(CStr::from_ptr(c as *const _).to_string_lossy().into_owned())
        }
    }
}

impl Drop for Snap {
    fn drop(&mut self) {
        unsafe { bc::bb_snap_release(self.ptr) };
    }
}

/// A terminal, freed on drop.
struct Term {
    ptr: *mut bc::BBTerm,
}

impl Term {
    fn new(cols: u16, rows: u16, scrollback: u32) -> Self {
        let ptr = unsafe { bc::bb_term_new(cols, rows, scrollback) };
        assert!(!ptr.is_null(), "bb_term_new returned null");
        Term { ptr }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.ptr, bytes.as_ptr(), bytes.len()) };
    }

    fn poisoned(&self) -> u8 {
        unsafe { bc::bb_term_is_poisoned(self.ptr) }
    }

    fn snapshot(&self) -> Snap {
        let ptr = unsafe { bc::bb_term_take_snapshot(self.ptr) };
        assert!(!ptr.is_null(), "bb_term_take_snapshot returned null");
        Snap { ptr }
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        unsafe { bc::bb_term_free(self.ptr) };
    }
}

// ---------------------------------------------------------------------------
// Part 1: an over-long `id=` must not cost the link
// ---------------------------------------------------------------------------

/// `len` bytes of a legal `id=` value (printable ASCII with no `;` or `:`,
/// the OSC 8 separators), distinct per `salt`.
fn id_of_len(len: usize, salt: char) -> String {
    let alphabet: Vec<char> = format!("{salt}abcdefghijklmnopqrstuvwxyz0123456789-_")
        .chars()
        .collect();
    (0..len).map(|i| alphabet[i % alphabet.len()]).collect()
}

const URL_A: &str = "https://example.com/docs?page=7";
const URL_B: &str = "https://example.org/other/path#frag";
const URL_C: &str = "https://example.net/third";

/// Ids at and under the historical 256-byte limit: these worked before the
/// bug and are the rig's controls.
const SHORT_ID_LENS: [usize; 4] = [0, 1, 255, 256];
/// Ids over it: the report's trigger. 64 KiB is far cheaper than the 8 MiB
/// OSC payload the parser accepts.
const LONG_ID_LENS: [usize; 5] = [257, 300, 1_000, 4_096, 65_536];

/// Feeds `ESC ] 8 ; id=<id> ; URL_A ESC \ ab ESC ] 8 ; ; ESC \ c` into a fresh
/// terminal and returns the printed text and what the first three cells of
/// row 0 resolve to.
fn link_after_id(id_len: usize) -> (Vec<u32>, [Option<String>; 3]) {
    let id = id_of_len(id_len, 'q');
    let seq = format!("\x1b]8;id={id};{URL_A}\x1b\\ab\x1b]8;;\x1b\\c");
    let term = Term::new(80, 24, 100);
    term.feed(seq.as_bytes());
    assert_eq!(
        term.poisoned(),
        0,
        "an id= of {id_len} bytes poisoned the terminal"
    );
    let snap = term.snapshot();
    let text: Vec<u32> = (0..3).map(|c| snap.ch(0, c)).collect();
    let links = [
        snap.link_url(0, 0),
        snap.link_url(0, 1),
        snap.link_url(0, 2),
    ];
    (text, links)
}

/// The report's trigger: a URI that is acceptable keeps its link whatever the
/// (unread) id= looks like.
#[test]
fn overlong_osc8_id_param_does_not_drop_an_acceptable_link() {
    let want_text: Vec<u32> = vec![u32::from(b'a'), u32::from(b'b'), u32::from(b'c')];
    let want_links: [Option<String>; 3] = [Some(URL_A.to_owned()), Some(URL_A.to_owned()), None];

    // Rig: ids up to the old limit already work, and the text always prints
    // (so a missing link is a dropped attribution, not a lost payload).
    let mut control_failures: Vec<String> = Vec::new();
    for len in SHORT_ID_LENS {
        let (text, links) = link_after_id(len);
        if text != want_text || links != want_links {
            control_failures.push(format!("id={len}B -> text {text:?} links {links:?}"));
        }
    }
    assert_eq!(
        control_failures,
        Vec::<String>::new(),
        "rig precondition: an `ab` link with an id of <= 256 bytes must attribute both cells to \
         {URL_A:?} and leave the cell after the close unlinked"
    );

    let mut failures: Vec<String> = Vec::new();
    for len in LONG_ID_LENS {
        let (text, links) = link_after_id(len);
        assert_eq!(
            text, want_text,
            "an id= of {len} bytes must not swallow or reorder the printed text"
        );
        if links != want_links {
            failures.push(format!(
                "id={len}B: cells (0,0),(0,1),(0,2) resolve to {links:?}"
            ));
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "an OSC 8 with an over-long id= and the acceptable URI {URL_A:?} must still link `ab` \
         (the core never reads the id; ignore or truncate it) - expected {want_links:?} for every \
         length in {LONG_ID_LENS:?}"
    );
}

/// The refusal must not wedge or poison what follows: the next links (long id
/// again, then a short one) and the plain text between them keep their exact
/// attribution.
#[test]
fn overlong_osc8_id_param_leaves_following_links_and_text_intact() {
    let long_a = id_of_len(300, 'a');
    let long_b = id_of_len(2_000, 'b');
    let seq = format!(
        "\x1b]8;id={long_a};{URL_A}\x1b\\ab\
         \x1b]8;id={long_b};{URL_B}\x1b\\cd\
         \x1b]8;;\x1b\\e\
         \x1b]8;id=short;{URL_C}\x1b\\f\x1b]8;;\x1b\\"
    );
    let term = Term::new(80, 24, 100);
    term.feed(seq.as_bytes());
    assert_eq!(term.poisoned(), 0, "the stream poisoned the terminal");
    let snap = term.snapshot();

    let text: Vec<u32> = (0..6).map(|c| snap.ch(0, c)).collect();
    assert_eq!(
        text,
        "abcdef".bytes().map(u32::from).collect::<Vec<u32>>(),
        "all six characters must print in order"
    );
    let links: Vec<Option<String>> = (0..6).map(|c| snap.link_url(0, c)).collect();
    let want: Vec<Option<String>> = vec![
        Some(URL_A.to_owned()),
        Some(URL_A.to_owned()),
        Some(URL_B.to_owned()),
        Some(URL_B.to_owned()),
        None,
        Some(URL_C.to_owned()),
    ];
    assert_eq!(
        links, want,
        "cells a,b -> {URL_A} (id 300 B); c,d -> {URL_B} (id 2000 B); e unlinked; f -> {URL_C} \
         (short id). Measured per-cell links: {links:?}"
    );
}

// ---------------------------------------------------------------------------
// Part 2: the budget fields on Term carry the re-apply marker
// ---------------------------------------------------------------------------
