//! Blind regression tests for sec-osc8-uri-retention: the OSC 8 hyperlink
//! target (URI) and `id=` parameter must not be retained, uncapped, per cell
//! in the grid and in scrollback.
//!
//! Written from the bug report, the surrounding documentation and the
//! existing OSC 8 tests only, without sight of the implementation.
//!
//! Observable contract:
//!   - `ESC ] 8 ; <params> ; <URI> ESC \` may carry a very large URI or
//!     `id=` value (the parser accepts an OSC payload of up to ~8 MiB). Text
//!     printed while the link is open is attributed to it; the cell holds on
//!     to whatever the terminal decided to remember about the link.
//!   - The memory the terminal retains after such a stream must NOT track
//!     the number of bytes the stream carried (1 byte retained per byte
//!     sent, i.e. "hidden retention ~1:1 with bytes sent"). Any sane remedy
//!     satisfies this: cap the URI / id length at ingest, drop over-long
//!     links, intern or share equal targets, or enforce a total budget. The
//!     test is agnostic to which one is chosen; it only demands that the
//!     retained heap stays under a small constant budget that is far below
//!     the bytes sent.
//!   - The repo already documents that a URI longer than 4 KiB can never
//!     become a live link (`osc8_drops_attribution_when_uri_exceeds_cap`
//!     in `osc8_hyperlinks.rs`; over-long URIs drop to "no attribution"
//!     instead of being truncated). Holding megabytes of such a URI per row
//!     for the lifetime of the scrollback is therefore pure waste, and one
//!     test below (E) pins that for URIs of 64 KiB (16x the snapshot cap).
//!   - Ordinary links keep working (guard test, passes before and after).
//!
//! How memory is observed: this test binary installs a counting global
//! allocator (wrapping `System`) and reads the live-byte counter around the
//! stream. That is exact, deterministic and independent of RSS / malloc zone
//! caching. The counter is process-wide, so every test takes `SERIAL` first
//! so the cargo test harness's parallel threads cannot pollute a
//! measurement. The measurement is taken with our own input buffer already
//! allocated (it is part of the baseline), after one warm-up OSC of the same
//! size so a parser-side scratch buffer is not mistaken for retention.
//!
//! Pre-flight cost (memory x time), per test, on a buggy build:
//!   - A: 40 rows x 1 MiB distinct URI = 40 MiB sent, ~40 MiB retained.
//!   - B: 64 cells x 512 KiB distinct URI on one row = 32 MiB sent/retained.
//!   - C: 32 rows x 1 MiB `id=` = 32 MiB sent/retained.
//!   - D: 32 rows x the SAME 1 MiB URI = 32 MiB sent/retained.
//!   - E: 256 rows x 64 KiB distinct URI = 16 MiB sent/retained.
//!   - Guard: 8 rows x 1 MiB = 8 MiB transient plus a few KiB.
//!
//! A fixed build stays far below each budget. Each test owns one 80x24
//! BBTerm with at most 300 lines of scrollback (a few hundred KiB of
//! cells) and one reusable input buffer of at most ~1 MiB; peak per test
//! on a buggy build is under ~100 MiB, nothing is held across tests, and
//! there is no I/O or sleeping. The real attack (hundreds of MiB per
//! second for an unbounded time, 8 MiB per OSC) is NOT reproduced here.

use std::alloc::{GlobalAlloc, Layout, System};
use std::ffi::CStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};

use blackbird_core as bc;

// ---------------------------------------------------------------------------
// Counting allocator
// ---------------------------------------------------------------------------

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

struct CountingAlloc;

fn note_growth(bytes: usize) {
    let now = LIVE.fetch_add(bytes, Ordering::SeqCst) + bytes;
    PEAK.fetch_max(now, Ordering::SeqCst);
}

fn note_shrink(bytes: usize) {
    LIVE.fetch_sub(bytes, Ordering::SeqCst);
}

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = System.alloc(layout);
        if !p.is_null() {
            note_growth(layout.size());
        }
        p
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let p = System.alloc_zeroed(layout);
        if !p.is_null() {
            note_growth(layout.size());
        }
        p
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
        note_shrink(layout.size());
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let p = System.realloc(ptr, layout, new_size);
        if !p.is_null() {
            if new_size >= layout.size() {
                note_growth(new_size - layout.size());
            } else {
                note_shrink(layout.size() - new_size);
            }
        }
        p
    }
}

#[global_allocator]
static ALLOC: CountingAlloc = CountingAlloc;

fn live_bytes() -> usize {
    LIVE.load(Ordering::SeqCst)
}

fn peak_bytes() -> usize {
    PEAK.load(Ordering::SeqCst)
}

/// Serialises every test in this binary (the allocator counters are global).
static SERIAL: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|e| e.into_inner())
}

const KIB: usize = 1024;
const MIB: usize = 1024 * 1024;

/// Instrument self-check: a known 1 MiB allocation must move the live
/// counter by about 1 MiB and be released again. If this fails, every
/// "retained bytes" number below would be meaningless. The cargo harness's
/// own threads allocate and free a few KiB concurrently, so the comparison
/// allows `SLACK` of noise (the budgets below are MiB).
fn assert_counter_is_live() {
    const SLACK: usize = 64 * KIB;
    let before = live_bytes();
    let probe: Vec<u8> = vec![7u8; MIB];
    let during = live_bytes();
    assert_eq!(
        probe.iter().map(|&b| b as usize).sum::<usize>(),
        7 * MIB,
        "probe buffer must hold what we wrote"
    );
    assert!(
        during + SLACK >= before + MIB,
        "counting allocator did not see a 1 MiB Vec: before={before} during={during}"
    );
    drop(probe);
    let after = live_bytes();
    assert!(
        after + MIB <= during + SLACK,
        "counting allocator did not see the 1 MiB Vec released: during={during} after={after}"
    );
}

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

    fn history(&self) -> u32 {
        unsafe { (*self.ptr).history_size }
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

    /// Number of rows whose column `col` shows an `x`.
    fn rows_with_x_in_col(&self, col: usize) -> usize {
        (0..self.rows())
            .filter(|&r| self.ch(r, col) == u32::from(b'x'))
            .count()
    }

    /// Number of columns of row `row` that show an `x`.
    fn cols_with_x_in_row(&self, row: usize) -> usize {
        (0..self.cols())
            .filter(|&c| self.ch(row, c) == u32::from(b'x'))
            .count()
    }

    /// The URL attributed to a cell, or `None` when it carries no link.
    fn link_url(&self, row: u16, col: u16) -> Option<String> {
        unsafe {
            let id = bc::bb_snap_link_id_at(self.ptr, row, col);
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
// Flood runner
// ---------------------------------------------------------------------------

struct FloodResult {
    /// Total bytes handed to the terminal by the flood (excludes the warm-up).
    sent: usize,
    /// Live-heap growth attributable to the flood, before any snapshot.
    retained: usize,
    /// Same, after a snapshot was taken and released.
    retained_after_snapshot: usize,
    /// Highest live heap reached during the flood, above the baseline.
    peak_over_baseline: usize,
    baseline_live: usize,
}

impl FloodResult {
    fn report(&self) -> String {
        format!(
            "sent={} retained={} ({:.1} MiB) retained_after_snapshot={} ({:.1} MiB) \
             peak_over_baseline={} baseline_live={}",
            self.sent,
            self.retained,
            self.retained as f64 / MIB as f64,
            self.retained_after_snapshot,
            self.retained_after_snapshot as f64 / MIB as f64,
            self.peak_over_baseline,
            self.baseline_live
        )
    }
}

/// Feeds `count` sequences produced by `fill(i, buf)` into `term`, then
/// `epilogue`, and reports what the terminal kept.
///
/// `buf_cap` is the largest sequence `fill` will build; the reusable input
/// buffer is allocated at that capacity BEFORE the baseline so the input
/// buffer is never counted as retention. A warm-up OSC 2 of the same size
/// runs first so a parser-side scratch buffer of that size is part of the
/// baseline too (what is measured is what the flood adds on top).
///
/// `verify` runs on a snapshot taken after the flood (non-vacuity checks:
/// the stream really was consumed and really scrolled).
fn run_flood(
    term: &Term,
    count: usize,
    buf_cap: usize,
    mut fill: impl FnMut(usize, &mut Vec<u8>),
    epilogue: &[u8],
    verify: impl FnOnce(&Snap),
) -> FloodResult {
    assert_counter_is_live();

    let mut buf: Vec<u8> = Vec::with_capacity(buf_cap);

    // Warm-up: OSC 2 ; AAAA... BEL, buf_cap bytes long. Title text is not
    // part of this bug; it only primes parser scratch capacity.
    buf.extend_from_slice(b"\x1b]2;");
    buf.resize(buf_cap - 1, b'A');
    buf.push(0x07);
    assert_eq!(buf.len(), buf_cap, "warm-up OSC must fill the buffer");
    term.feed(&buf);
    assert_eq!(term.poisoned(), 0, "the warm-up OSC poisoned the term");

    let baseline_live = live_bytes();
    PEAK.store(baseline_live, Ordering::SeqCst);

    let mut sent = 0usize;
    for i in 0..count {
        buf.clear();
        fill(i, &mut buf);
        assert!(
            !buf.is_empty() && buf.len() <= buf_cap,
            "fill({i}) built {} bytes, outside 1..={buf_cap}",
            buf.len()
        );
        term.feed(&buf);
        sent += buf.len();
    }
    if !epilogue.is_empty() {
        term.feed(epilogue);
        sent += epilogue.len();
    }

    // Our own reusable input buffer is in the baseline (allocated above, and
    // `fill` never grows it past `buf_cap`), so this is terminal retention.
    let retained = live_bytes().saturating_sub(baseline_live);
    let peak_over_baseline = peak_bytes().saturating_sub(baseline_live);
    assert_eq!(term.poisoned(), 0, "the flood poisoned the term");

    {
        let snap = term.snapshot();
        verify(&snap);
    } // snapshot released here.
    let retained_after_snapshot = live_bytes().saturating_sub(baseline_live);

    drop(buf);

    FloodResult {
        sent,
        retained,
        retained_after_snapshot,
        peak_over_baseline,
        baseline_live,
    }
}

/// Appends `prefix` followed by `fill_byte` padding up to exactly `total`
/// bytes.
fn push_padded(buf: &mut Vec<u8>, prefix: &str, total: usize, fill_byte: u8) {
    assert!(
        prefix.len() <= total,
        "prefix {} longer than total {total}",
        prefix.len()
    );
    buf.extend_from_slice(prefix.as_bytes());
    let pad = total - prefix.len();
    buf.resize(buf.len() + pad, fill_byte);
}

fn assert_bounded(name: &str, what: &str, r: &FloodResult, budget: usize) {
    assert!(
        r.retained < budget,
        "{name}: {what} retained {} bytes ({:.1} MiB) of heap after the stream; the stream \
         carried {} bytes ({:.1} MiB), so retention is {:.2}x the bytes sent; budget {budget} \
         bytes. {}",
        r.retained,
        r.retained as f64 / MIB as f64,
        r.sent,
        r.sent as f64 / MIB as f64,
        r.retained as f64 / r.sent as f64,
        r.report(),
    );
    assert!(
        r.retained_after_snapshot < budget,
        "{name}: {what} left {} bytes ({:.1} MiB) of heap after a snapshot was taken and \
         released; budget {budget} bytes. {}",
        r.retained_after_snapshot,
        r.retained_after_snapshot as f64 / MIB as f64,
        r.report(),
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A: the report's trigger. `ESC ] 8 ; ; <1 MiB URI> ESC \ x ESC ] 8 ; ; ESC \ CR LF`
/// repeated with a DIFFERENT URI each time. 40 MiB in, one visible `x` per
/// line out; the lines scroll into history. EXPECTED TO FAIL on the buggy
/// build (retains ~40 MiB).
#[test]
fn distinct_megabyte_uris_on_scrolling_rows_are_not_retained_one_to_one() {
    let _g = serial();
    const COUNT: usize = 40;
    const URI_LEN: usize = MIB;
    const BUDGET: usize = 8 * MIB;

    let term = Term::new(80, 24, 100);
    let r = run_flood(
        &term,
        COUNT,
        URI_LEN + 64,
        |i, buf| {
            buf.extend_from_slice(b"\x1b]8;;");
            push_padded(buf, &format!("https://x.test/{i:06}/"), URI_LEN, b'a');
            buf.extend_from_slice(b"\x1b\\x\x1b]8;;\x1b\\\r\n");
        },
        b"",
        |snap| {
            // Non-vacuity: every line printed its `x` (the last row is the
            // empty cursor row), and the lines really reached scrollback.
            assert_eq!(
                snap.rows_with_x_in_col(0),
                snap.rows() - 1,
                "the visible rows must each show the `x` of their line"
            );
            assert!(
                snap.history() as usize + snap.rows() > COUNT,
                "{COUNT} lines must have scrolled into history; history_size={}",
                snap.history()
            );
        },
    );

    assert!(r.sent >= COUNT * URI_LEN, "flood too small: {}", r.report());
    assert_bounded("A", "40 distinct 1 MiB OSC 8 URIs", &r, BUDGET);
}

/// B: the "one distinct link per cell" amplification inside a single row.
/// 64 cells, each opened with its own 512 KiB URI. No scrolling involved.
/// EXPECTED TO FAIL on the buggy build (retains ~32 MiB).
#[test]
fn distinct_large_uris_across_the_cells_of_one_row_are_not_retained() {
    let _g = serial();
    const CELLS: usize = 64;
    const URI_LEN: usize = 512 * KIB;
    const BUDGET: usize = 8 * MIB;

    let term = Term::new(80, 24, 100);
    let r = run_flood(
        &term,
        CELLS,
        URI_LEN + 64,
        |i, buf| {
            // Opening a new link replaces the previous one; no explicit
            // close between cells, as terminals that emit dense links do.
            buf.extend_from_slice(b"\x1b]8;;");
            push_padded(buf, &format!("https://x.test/{i:06}/"), URI_LEN, b'a');
            buf.extend_from_slice(b"\x1b\\x");
        },
        b"\x1b]8;;\x1b\\",
        |snap| {
            assert_eq!(
                snap.cols_with_x_in_row(0),
                CELLS,
                "row 0 must show one `x` per cell written"
            );
            assert_eq!(snap.history(), 0, "nothing should have scrolled");
        },
    );

    assert!(r.sent >= CELLS * URI_LEN, "flood too small: {}", r.report());
    assert_bounded(
        "B",
        "64 cells of one row, each with a 512 KiB URI",
        &r,
        BUDGET,
    );
}

/// C: the `id=` parameter is just as unbounded as the URI. A tiny, ordinary
/// URI but a 1 MiB `id=` value per link, on scrolling rows.
/// EXPECTED TO FAIL on the buggy build (retains ~32 MiB).
#[test]
fn megabyte_link_ids_on_scrolling_rows_are_not_retained_one_to_one() {
    let _g = serial();
    const COUNT: usize = 32;
    const ID_LEN: usize = MIB;
    const BUDGET: usize = 8 * MIB;

    let term = Term::new(80, 24, 100);
    let r = run_flood(
        &term,
        COUNT,
        ID_LEN + 128,
        |i, buf| {
            buf.extend_from_slice(b"\x1b]8;id=");
            push_padded(buf, &format!("{i:06}-"), ID_LEN, b'b');
            buf.extend_from_slice(b";https://example.com/page\x1b\\x\x1b]8;;\x1b\\\r\n");
        },
        b"",
        |snap| {
            assert_eq!(
                snap.rows_with_x_in_col(0),
                snap.rows() - 1,
                "the visible rows must each show the `x` of their line"
            );
            assert!(
                snap.history() as usize + snap.rows() > COUNT,
                "{COUNT} lines must have scrolled into history; history_size={}",
                snap.history()
            );
        },
    );

    assert!(r.sent >= COUNT * ID_LEN, "flood too small: {}", r.report());
    assert_bounded("C", "32 OSC 8 links with a 1 MiB id= each", &r, BUDGET);
}

/// D: the SAME 1 MiB URI re-opened on every row. Each `set` is a fresh
/// allocation on the buggy build ("distinct or not"). A remedy may cap, drop
/// or share; none of them may keep 32 separate copies.
/// EXPECTED TO FAIL on the buggy build (retains ~32 MiB).
#[test]
fn identical_megabyte_uri_reopened_on_every_row_is_not_kept_per_row() {
    let _g = serial();
    const COUNT: usize = 32;
    const URI_LEN: usize = MIB;
    const BUDGET: usize = 8 * MIB;

    let term = Term::new(80, 24, 100);
    let r = run_flood(
        &term,
        COUNT,
        URI_LEN + 64,
        |_i, buf| {
            buf.extend_from_slice(b"\x1b]8;;");
            push_padded(buf, "https://x.test/same/", URI_LEN, b'a');
            buf.extend_from_slice(b"\x1b\\x\x1b]8;;\x1b\\\r\n");
        },
        b"",
        |snap| {
            assert_eq!(
                snap.rows_with_x_in_col(0),
                snap.rows() - 1,
                "the visible rows must each show the `x` of their line"
            );
            assert!(
                snap.history() as usize + snap.rows() > COUNT,
                "{COUNT} lines must have scrolled into history; history_size={}",
                snap.history()
            );
        },
    );

    assert!(r.sent >= COUNT * URI_LEN, "flood too small: {}", r.report());
    assert_bounded("D", "32 re-opens of the same 1 MiB OSC 8 URI", &r, BUDGET);
}

/// E: URIs that are far past the documented 4 KiB "can never be a live
/// link" line, but small enough that a lax remedy might still keep them:
/// 64 KiB, 256 rows deep in scrollback. Holding all 16 MiB of them would
/// keep content the snapshot refuses to surface at all.
/// EXPECTED TO FAIL on the buggy build (retains ~16 MiB).
#[test]
fn uris_sixteen_times_the_snapshot_cap_are_not_retained_across_scrollback() {
    let _g = serial();
    const COUNT: usize = 256;
    const URI_LEN: usize = 64 * KIB;
    const BUDGET: usize = 4 * MIB;

    let term = Term::new(80, 24, 300);
    let r = run_flood(
        &term,
        COUNT,
        URI_LEN + 64,
        |i, buf| {
            buf.extend_from_slice(b"\x1b]8;;");
            push_padded(buf, &format!("https://x.test/{i:06}/"), URI_LEN, b'a');
            buf.extend_from_slice(b"\x1b\\x\x1b]8;;\x1b\\\r\n");
        },
        b"",
        |snap| {
            assert_eq!(
                snap.rows_with_x_in_col(0),
                snap.rows() - 1,
                "the visible rows must each show the `x` of their line"
            );
            assert!(
                snap.history() as usize + snap.rows() > COUNT,
                "{COUNT} lines must have scrolled into history without eviction; \
                 history_size={}",
                snap.history()
            );
        },
    );

    assert!(r.sent >= COUNT * URI_LEN, "flood too small: {}", r.report());
    assert_bounded("E", "256 OSC 8 URIs of 64 KiB each", &r, BUDGET);
}

/// Guard (passes before and after the fix): a remedy must not break
/// hyperlinks. Ordinary links, with and without an `id=`, still attribute
/// exactly their text with their exact URL, including after a burst of
/// over-long links on the same terminal.
#[test]
fn ordinary_hyperlinks_still_attribute_exactly_after_a_large_link_burst() {
    let _g = serial();
    assert_counter_is_live();

    let term = Term::new(80, 24, 100);

    // A burst of over-long links first (8 rows, 1 MiB each, transient).
    {
        let mut buf: Vec<u8> = Vec::with_capacity(MIB + 64);
        for i in 0..8usize {
            buf.clear();
            buf.extend_from_slice(b"\x1b]8;;");
            push_padded(&mut buf, &format!("https://x.test/{i:06}/"), MIB, b'a');
            buf.extend_from_slice(b"\x1b\\x\x1b]8;;\x1b\\\r\n");
            term.feed(&buf);
        }
    }

    // Then two ordinary links on one fresh line: one with an id= and a short
    // URL, one without an id and a ~1 KB URL (well under the 4 KiB line).
    let short = "https://example.com/docs?q=1";
    let mut mid = String::from("https://example.com/long/");
    while mid.len() < 1000 {
        mid.push('m');
    }
    assert_eq!(mid.len(), 1000, "mid-sized URL must be exactly 1000 bytes");

    let line = format!(
        "\x1b]8;id=guard-1;{short}\x1b\\ab\x1b]8;;\x1b\\ \x1b]8;;{mid}\x1b\\cd\x1b]8;;\x1b\\"
    );
    term.feed(line.as_bytes());
    assert_eq!(
        term.poisoned(),
        0,
        "burst + ordinary links poisoned the term"
    );

    let snap = term.snapshot();
    // The line was written on the row the cursor sat on after the burst:
    // find it as the row whose column 0 shows `a`.
    let row = (0..snap.rows())
        .find(|&r| snap.ch(r, 0) == u32::from(b'a'))
        .unwrap_or_else(|| panic!("the ordinary-link line `ab cd` is not visible"));
    assert_eq!(snap.ch(row, 1), u32::from(b'b'), "`ab` must be printed");
    assert_eq!(snap.ch(row, 3), u32::from(b'c'), "`cd` must be printed");
    let row = row as u16;

    assert_eq!(
        snap.link_url(row, 0).as_deref(),
        Some(short),
        "first cell of the id= link must resolve to its exact URL"
    );
    assert_eq!(
        snap.link_url(row, 1).as_deref(),
        Some(short),
        "second cell of the id= link must resolve to its exact URL"
    );
    assert_eq!(
        snap.link_url(row, 2),
        None,
        "the plain space between the links must carry no link"
    );
    assert_eq!(
        snap.link_url(row, 3).as_deref(),
        Some(mid.as_str()),
        "first cell of the 1000-byte-URL link must resolve to its exact URL"
    );
    assert_eq!(
        snap.link_url(row, 4).as_deref(),
        Some(mid.as_str()),
        "second cell of the 1000-byte-URL link must resolve to its exact URL"
    );
    assert_eq!(
        snap.link_url(row, 5),
        None,
        "the cell after the closed link must carry no link"
    );
}
