//! Blind regression tests for OSC8-b: the per-terminal live-byte budget that
//! bounds how much heap OSC 8 hyperlinks may retain.
//!
//! Written from the bug report, the surrounding documentation and the
//! existing OSC 8 tests (`osc8_uri_retention_blind.rs`,
//! `osc8_link_cap_recovery.rs`, `osc7_hostname_any_machine_blind.rs`) only,
//! without sight of the implementation bodies.
//!
//! Observable contract (what the bug report demands):
//!   1. Each distinct OSC 8 link is a separate retained allocation. A stream
//!      of distinct links whose URIs are each UNDER the per-link length cap
//!      (4 KiB; we use 2.1 KiB and 3 KiB) is limited only by the per-terminal
//!      live-byte budget (32 MiB, `HYPERLINK_LIVE_MAX`). The heap those links
//!      retain must stay within that budget. The budget must count what the
//!      allocator really holds (capacity), not just `len()`: a URI whose
//!      buffer is up to 2x its length must not let the terminal retain up to
//!      2x the budget. (heap tests)
//!   2. Once the budget is exhausted, later links are refused. That used to
//!      be silent: the symptom is "links stopped working" with nothing in
//!      the log. It must leave a one-shot / rate-limited breadcrumb on
//!      stderr, like the sibling OSC 8 intern-cap breadcrumb
//!      (`[blackbird_core] OSC 8 URI intern budget ... exhausted`), once per
//!      session, not once per refused link. (breadcrumb tests)
//!   3. The budget is credited back when the links that hold it go away:
//!      rows scrolling out of the scrollback ring, scrollback erased with
//!      `ED 3`, cells overwritten in place. After that, ordinary links work
//!      again. (credit tests)
//!   4. The accounting type (the shared live-byte counter) is an
//!      implementation detail and must not appear in the public API of the
//!      vendored `alacritty_terminal` / `vte` crates. (API test; a source
//!      scan of the `pub` declarations, because a negative-compile test would
//!      need a second crate.)
//!
//! A note on how refusal is observed: a refused link leaves its text on the
//! grid but no link attribution, so `bb_snap_link_id_at` returns 0 for the
//! cell. The snapshot has its own, separate 1 MiB URI intern cap, so every
//! snapshot below is taken only when the viewport holds a handful of
//! distinct URIs (or none), never while thousands of distinct 3 KiB links
//! are on screen; otherwise a 0 could be that cap rather than the live
//! budget.
//!
//! How memory is observed: a counting global allocator (wrapping `System`),
//! exactly as in `osc8_uri_retention_blind.rs`. The counter is process-wide,
//! so every test takes `SERIAL`.
//!
//! Which tests are expected to FAIL on the buggy build:
//!   - `*_breadcrumb*` (no breadcrumb is ever logged),
//!   - `hyperlink_accounting_type_is_not_part_of_the_public_api`
//!     (`Hyperlink::bounded` is `pub` and takes `&Arc<AtomicUsize>`),
//!   - the two `*_containing_semicolons` heap tests: URIs with a few `;`
//!     (legal in a URI, and the OSC parameter separator) were measured
//!     retaining ~1.9x the heap their lengths add up to (~61 MiB against the
//!     32 MiB budget). The plain-URI heap test measures ~32.0 MiB on the same
//!     build and is a guard that passes before and after.
//!
//! The credit tests (`links_work_again_after_*`) pin behaviour the report
//! says is untested today; they pass on a build whose credit-on-drop works
//! and fail on one that leaks the counter.
//!
//! Pre-flight cost (memory x time), per test, on a buggy build:
//!   - Every flooding test feeds 36-43 MB of OSC 8 input (12 000 to 20 000
//!     distinct links of 2.1 or 3 KiB) through one reusable <= 70 KiB buffer.
//!   - Terminals are 2 columns x 24 rows with at most 21 000 lines of
//!     scrollback (about 100 B per history row, ~2 MB of grid), except the
//!     overwrite test: 100 x 24 cells, no scrolling, 5 rounds of 2 400 links.
//!   - Retained link heap is capped by the budget on a fixed build (32 MiB)
//!     and is at most ~65 MiB on a buggy build; nothing is held across tests
//!     (each test frees its terminal(s) before returning), so the peak per
//!     test is under ~110 MiB. The breadcrumb child process runs two of these
//!     floods one after the other (never concurrently), ~50 MiB peak.
//!   - No sleeping, no I/O except re-exec'ing this binary once for the
//!     breadcrumb tests and reading ~30 vendored source files for the API
//!     test.

use std::alloc::{GlobalAlloc, Layout, System};
use std::ffi::CStr;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};

use blackbird_core as bc;

// ---------------------------------------------------------------------------
// Counting allocator
// ---------------------------------------------------------------------------

static LIVE: AtomicUsize = AtomicUsize::new(0);

struct CountingAlloc;

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = System.alloc(layout);
        if !p.is_null() {
            LIVE.fetch_add(layout.size(), Ordering::SeqCst);
        }
        p
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let p = System.alloc_zeroed(layout);
        if !p.is_null() {
            LIVE.fetch_add(layout.size(), Ordering::SeqCst);
        }
        p
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
        LIVE.fetch_sub(layout.size(), Ordering::SeqCst);
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let p = System.realloc(ptr, layout, new_size);
        if !p.is_null() {
            if new_size >= layout.size() {
                LIVE.fetch_add(new_size - layout.size(), Ordering::SeqCst);
            } else {
                LIVE.fetch_sub(layout.size() - new_size, Ordering::SeqCst);
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

/// Serialises every test in this binary (the allocator counter is global).
static SERIAL: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|e| e.into_inner())
}

const KIB: usize = 1024;
const MIB: usize = 1024 * 1024;

/// The documented per-terminal live-byte budget for OSC 8 hyperlinks
/// (`HYPERLINK_LIVE_MAX`).
const LIVE_BUDGET: usize = 32 * MIB;

/// Instrument self-check: a known 1 MiB allocation must move the live
/// counter by about 1 MiB and be released again. If this fails, every
/// "retained bytes" number below would be meaningless.
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

    /// Rows whose column 0 shows the ASCII character `c`.
    fn rows_with_char_in_col0(&self, c: u8) -> Vec<usize> {
        (0..self.rows())
            .filter(|&r| self.ch(r, 0) == u32::from(c))
            .collect()
    }

    fn link_id(&self, row: usize, col: usize) -> u32 {
        unsafe { bc::bb_snap_link_id_at(self.ptr, row as u16, col as u16) }
    }

    /// Number of viewport cells that carry any link attribution.
    fn linked_cells(&self) -> usize {
        let mut n = 0;
        for r in 0..self.rows() {
            for c in 0..self.cols() {
                if self.link_id(r, c) != 0 {
                    n += 1;
                }
            }
        }
        n
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
// Input builders
// ---------------------------------------------------------------------------

/// URI lengths. 3 KiB is the report's example; 2 KiB + 52 is "just over a
/// power of two", the worst case for a buffer that grows by doubling (a
/// 4 KiB buffer holding 2.1 KiB, i.e. nearly 2x its length).
const URI_3K: usize = 3 * KIB;
const URI_JUST_OVER_2K: usize = 2 * KIB + 52;
/// A link comfortably costlier than any flood link, used as the "does the
/// budget have room again" probe. Still under the 4 KiB per-link cap.
const URI_PROBE: usize = 3 * KIB + 512;

/// Flush threshold for the reusable feed buffer.
const FEED_BATCH: usize = 64 * KIB;

/// The exact URI the builders produce for `tag`: a unique 22-byte prefix
/// padded with `a` up to `len` bytes.
fn uri_for(tag: usize, len: usize) -> String {
    let mut uri = format!("https://x.test/{tag:06}/");
    assert!(
        uri.len() <= len,
        "uri prefix {} longer than {len}",
        uri.len()
    );
    while uri.len() < len {
        uri.push('a');
    }
    uri
}

/// Like `uri_for`, but every `semi_every`-th byte after the prefix is a `;`
/// (0 = none). A `;` is legal in a URI (`https://h/p;jsessionid=1`,
/// `?a=1;b=2`) and is also the OSC parameter separator, so such a URI takes
/// a different path through the parser than a `;`-free one. Exactly `len`
/// bytes, unique per `tag`.
fn shaped_uri(tag: usize, len: usize, semi_every: usize) -> String {
    let mut uri = format!("https://x.test/{tag:06}/");
    assert!(
        uri.len() <= len,
        "uri prefix {} longer than {len}",
        uri.len()
    );
    while uri.len() < len {
        if semi_every > 0 && uri.len() % semi_every == semi_every - 1 {
            uri.push(';');
        } else {
            uri.push('a');
        }
    }
    uri
}

/// `ESC ] 8 ; ; <uri> ESC \ x` : one linked `x`, link left open.
fn push_open_link_x(buf: &mut Vec<u8>, tag: usize, uri_len: usize) {
    push_open_link_x_shaped(buf, tag, uri_len, 0);
}

fn push_open_link_x_shaped(buf: &mut Vec<u8>, tag: usize, uri_len: usize, semi_every: usize) {
    buf.extend_from_slice(b"\x1b]8;;");
    buf.extend_from_slice(shaped_uri(tag, uri_len, semi_every).as_bytes());
    buf.extend_from_slice(b"\x1b\\x");
}

const CLOSE_LINK: &[u8] = b"\x1b]8;;\x1b\\";

/// One scrolling row: a distinct link around one `x`, closed, then CR LF.
fn push_link_row(buf: &mut Vec<u8>, tag: usize, uri_len: usize) {
    push_link_row_shaped(buf, tag, uri_len, 0);
}

fn push_link_row_shaped(buf: &mut Vec<u8>, tag: usize, uri_len: usize, semi_every: usize) {
    push_open_link_x_shaped(buf, tag, uri_len, semi_every);
    buf.extend_from_slice(CLOSE_LINK);
    buf.extend_from_slice(b"\r\n");
}

/// Feeds `count` distinct linked rows (tags `first_tag..first_tag+count`).
fn flood_link_rows(term: &Term, first_tag: usize, count: usize, uri_len: usize) {
    flood_link_rows_shaped(term, first_tag, count, uri_len, 0);
}

fn flood_link_rows_shaped(
    term: &Term,
    first_tag: usize,
    count: usize,
    uri_len: usize,
    semi_every: usize,
) {
    let mut buf: Vec<u8> = Vec::with_capacity(FEED_BATCH + uri_len + 128);
    for i in 0..count {
        push_link_row_shaped(&mut buf, first_tag + i, uri_len, semi_every);
        if buf.len() >= FEED_BATCH {
            term.feed(&buf);
            buf.clear();
        }
    }
    if !buf.is_empty() {
        term.feed(&buf);
    }
    assert_eq!(term.poisoned(), 0, "the link flood poisoned the term");
}

/// Control for the heap tests: the same number of rows, no OSC 8 at all.
fn flood_plain_rows(term: &Term, count: usize) {
    let mut buf: Vec<u8> = Vec::with_capacity(FEED_BATCH + 16);
    for _ in 0..count {
        buf.extend_from_slice(b"x\r\n");
        if buf.len() >= FEED_BATCH {
            term.feed(&buf);
            buf.clear();
        }
    }
    if !buf.is_empty() {
        term.feed(&buf);
    }
    assert_eq!(term.poisoned(), 0, "the plain flood poisoned the term");
}

/// `count` x CR LF, fed in chunks.
fn feed_newlines(term: &Term, count: usize) {
    let chunk: Vec<u8> = b"\r\n".repeat(4096);
    let mut left = count;
    while left > 0 {
        let n = left.min(4096);
        term.feed(&chunk[..n * 2]);
        left -= n;
    }
}

// ---------------------------------------------------------------------------
// Heap tests
// ---------------------------------------------------------------------------

struct HeapReport {
    sent_uri_bytes: usize,
    plain_retained: usize,
    with_links_retained: usize,
}

impl HeapReport {
    fn link_heap(&self) -> usize {
        self.with_links_retained.saturating_sub(self.plain_retained)
    }

    fn describe(&self) -> String {
        format!(
            "URI bytes sent={} ({:.1} MiB); heap retained by the plain control={} ({:.2} MiB); \
             heap retained with links={} ({:.2} MiB); heap attributable to links={} ({:.2} MiB); \
             documented budget={} ({} MiB)",
            self.sent_uri_bytes,
            self.sent_uri_bytes as f64 / MIB as f64,
            self.plain_retained,
            self.plain_retained as f64 / MIB as f64,
            self.with_links_retained,
            self.with_links_retained as f64 / MIB as f64,
            self.link_heap(),
            self.link_heap() as f64 / MIB as f64,
            LIVE_BUDGET,
            LIVE_BUDGET / MIB,
        )
    }
}

/// Streams `count` distinct links of `uri_len` bytes into a scrollback big
/// enough to keep them all, and reports the heap they pin, net of the same
/// number of plain rows (grid and row storage cost the same either way).
fn measure_link_heap(uri_len: usize, semi_every: usize, count: usize) -> HeapReport {
    assert_counter_is_live();
    let scrollback = (count + 200) as u32;

    let plain_retained = {
        let term = Term::new(2, 24, scrollback);
        let baseline = live_bytes();
        flood_plain_rows(&term, count);
        live_bytes().saturating_sub(baseline)
    };

    let with_links_retained = {
        let term = Term::new(2, 24, scrollback);
        let baseline = live_bytes();
        flood_link_rows_shaped(&term, 0, count, uri_len, semi_every);
        let retained = live_bytes().saturating_sub(baseline);
        // Non-vacuity: the stream was consumed and really scrolled.
        let snap = term.snapshot();
        assert_eq!(
            snap.rows_with_char_in_col0(b'x').len(),
            snap.rows() - 1,
            "the visible rows must each show the `x` of their line"
        );
        assert!(
            snap.history() as usize + snap.rows() > count,
            "{count} lines must have scrolled into history without eviction; history_size={}",
            snap.history()
        );
        retained
    };

    HeapReport {
        sent_uri_bytes: count * uri_len,
        plain_retained,
        with_links_retained,
    }
}

/// Slack on top of the 32 MiB budget for per-cell bookkeeping that is not a
/// hyperlink buffer (cell extras, allocator headers the counter cannot see).
const HEAP_TOLERANCE: usize = 2 * MIB;

fn assert_heap_within_budget(name: &str, r: &HeapReport) {
    eprintln!("[heap] {name}: {}", r.describe());
    assert!(
        r.sent_uri_bytes >= LIVE_BUDGET + LIVE_BUDGET / 4,
        "{name}: rig too small to exhaust the budget: {}",
        r.describe()
    );
    // Non-vacuity: the budget admits plenty of links; a build that refuses
    // everything would trivially satisfy the bound below.
    assert!(
        r.link_heap() >= 4 * MIB,
        "{name}: links retained suspiciously little heap, the flood is not exercising the \
         budget (are links being refused outright?): {}",
        r.describe()
    );
    assert!(
        r.link_heap() <= LIVE_BUDGET + HEAP_TOLERANCE,
        "{name}: distinct OSC 8 links retained {:.2} MiB of heap, more than the {} MiB live \
         budget (+{} MiB tolerance). The budget must count real capacity, not just len(). {}",
        r.link_heap() as f64 / MIB as f64,
        LIVE_BUDGET / MIB,
        HEAP_TOLERANCE / MIB,
        r.describe()
    );
}

/// Guard (passes before and after the fix): the report's trigger, 3 KiB
/// URIs (under the 4 KiB per-link cap), so the live budget is the only
/// thing limiting retention. The retained heap tracks the budget.
#[test]
fn live_budget_bounds_retained_heap_for_plain_3kib_uris() {
    let _g = serial();
    let r = measure_link_heap(URI_3K, 0, 14_000);
    assert_heap_within_budget("3 KiB URIs", &r);
}

/// 3 KiB URIs that contain `;` (two of them, 1 500 bytes apart, e.g.
/// matrix parameters). Measured on the unfixed build, such links pin about
/// 1.9x the heap that their lengths add up to, so the "32 MiB" budget lets
/// the terminal keep ~60 MiB. The budget must count real capacity.
#[test]
fn live_budget_bounds_retained_heap_for_3kib_uris_containing_semicolons() {
    let _g = serial();
    let r = measure_link_heap(URI_3K, 1500, 14_000);
    assert_heap_within_budget("3 KiB URIs with `;` every 1500 bytes", &r);
}

/// The same with URIs just over a power of two (2 KiB + 52) and four `;`:
/// the worst case for len()-based costing of a buffer that grew by doubling
/// (4 KiB held for 2.1 KiB).
#[test]
fn live_budget_bounds_retained_heap_for_uris_just_over_a_power_of_two_containing_semicolons() {
    let _g = serial();
    let r = measure_link_heap(URI_JUST_OVER_2K, 512, 20_500);
    assert_heap_within_budget("2 KiB + 52 B URIs with `;` every 512 bytes", &r);
}

// ---------------------------------------------------------------------------
// Breadcrumb tests (child process, stderr)
// ---------------------------------------------------------------------------

const CHILD_ENV: &str = "BB_OSC8_LIVE_BUDGET_BLIND_CHILD";
const CHILD_ENTRY_TEST: &str = "exhausting_the_live_budget_leaves_a_bounded_breadcrumb";

/// Enough 3 KiB links to exhaust a 32 MiB budget even if every link were
/// costed at its bare length (32 MiB / 3 KiB = 10 923): 13 000 x 3 KiB.
const EXHAUST_COUNT: usize = 13_000;
/// Scrollback roomy enough that nothing scrolls out (and credits the
/// budget back) during the flood.
const EXHAUST_SCROLLBACK: u32 = 17_000;
const MORE_REFUSED: usize = 3_000;

/// Runs inside the re-executed child. Prints phase markers to stderr; the
/// core's own `eprintln!` breadcrumbs land in between.
fn breadcrumb_child() {
    let run_session = |tag_prefix: &str, with_second_flood: bool| {
        eprintln!("@@PHASE {tag_prefix}_BEGIN");
        let term = Term::new(2, 24, EXHAUST_SCROLLBACK);

        // Rig check: before the budget is touched, a link is accepted.
        let mut canary: Vec<u8> = Vec::new();
        push_open_link_x(&mut canary, 999_999, URI_3K);
        canary.extend_from_slice(CLOSE_LINK);
        term.feed(&canary);
        {
            let snap = term.snapshot();
            assert_ne!(
                snap.link_id(0, 0),
                0,
                "child rig: the canary link must be accepted before any flood"
            );
        }

        eprintln!("@@PHASE {tag_prefix}_FLOOD");
        feed_newlines(&term, 1);
        flood_link_rows(&term, 0, EXHAUST_COUNT, URI_3K);

        eprintln!("@@PHASE {tag_prefix}_SNAPSHOT");
        {
            let snap = term.snapshot();
            // The newest rows' links were refused: the budget is exhausted.
            let last_row = snap.rows() - 2;
            assert_eq!(
                snap.ch(last_row, 0),
                u32::from(b'x'),
                "child rig: the newest flood row must be visible"
            );
            assert_eq!(
                snap.link_id(last_row, 0),
                0,
                "child rig: after {EXHAUST_COUNT} distinct 3 KiB links the budget must have \
                 refused the newest one"
            );
        }

        if with_second_flood {
            eprintln!("@@PHASE {tag_prefix}_FLOOD2");
            flood_link_rows(&term, EXHAUST_COUNT, MORE_REFUSED, URI_3K);
        }
        drop(term);
    };

    run_session("S1", true);
    run_session("S2", false);
    eprintln!("@@PHASE END");
}

struct ChildReport {
    stderr: String,
    /// (phase name, breadcrumb lines seen in it), in order of appearance.
    counts: Vec<(String, usize)>,
}

impl ChildReport {
    fn count(&self, phase: &str) -> usize {
        self.counts
            .iter()
            .filter(|(n, _)| n == phase)
            .map(|(_, c)| *c)
            .sum()
    }

    fn phases(&self) -> Vec<String> {
        self.counts.iter().map(|(n, _)| n.clone()).collect()
    }
}

/// A line that tells the maintainer the OSC 8 live budget refused links.
/// The pre-existing intern-cap line ("OSC 8 URI intern budget ... exhausted")
/// is a different budget and is excluded; the scenario also never lets the
/// snapshot cache fill, so it cannot fire here anyway.
fn is_budget_breadcrumb(line: &str) -> bool {
    let l = line.to_ascii_lowercase();
    let about_osc8 = l.contains("osc 8") || l.contains("osc8") || l.contains("hyperlink");
    let about_refusal = [
        "budget", "limit", "cap", "exhaust", "refus", "drop", "full", "exceed",
    ]
    .iter()
    .any(|w| l.contains(w));
    about_osc8 && about_refusal && !l.contains("intern budget")
}

static CHILD_REPORT: OnceLock<ChildReport> = OnceLock::new();

fn child_report() -> &'static ChildReport {
    CHILD_REPORT.get_or_init(|| {
        let exe = std::env::current_exe().expect("current_exe");
        let out = Command::new(exe)
            .args([
                "--exact",
                CHILD_ENTRY_TEST,
                "--nocapture",
                "--test-threads=1",
            ])
            .env(CHILD_ENV, "1")
            .output()
            .expect("re-exec the test binary as the breadcrumb child");
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        assert!(
            out.status.success(),
            "breadcrumb child failed ({:?}); stderr:\n{stderr}",
            out.status
        );

        let mut counts: Vec<(String, usize)> = vec![("(before)".to_string(), 0)];
        for line in stderr.lines() {
            if let Some(name) = line.strip_prefix("@@PHASE ") {
                counts.push((name.trim().to_string(), 0));
            } else if is_budget_breadcrumb(line) {
                if let Some(last) = counts.last_mut() {
                    last.1 += 1;
                }
            }
        }
        ChildReport { stderr, counts }
    })
}

fn assert_child_walked_every_phase(r: &ChildReport) {
    assert_eq!(
        r.phases(),
        vec![
            "(before)",
            "S1_BEGIN",
            "S1_FLOOD",
            "S1_SNAPSHOT",
            "S1_FLOOD2",
            "S2_BEGIN",
            "S2_FLOOD",
            "S2_SNAPSHOT",
            "END"
        ],
        "rig precondition: the child must walk every phase; child stderr:\n{}",
        r.stderr
    );
}

/// "Once exhausted every later OSC 8 link is silently dropped and the
/// maintainer cannot diagnose 'links stopped working'": the first refusal
/// of a session must be logged, but a flood of refusals must not flood the
/// log (one-shot / rate-limited), and nothing may be logged while the
/// budget still has room.
#[test]
fn exhausting_the_live_budget_leaves_a_bounded_breadcrumb() {
    if matches!(std::env::var(CHILD_ENV).as_deref(), Ok("1")) {
        breadcrumb_child();
        return;
    }
    let _g = serial();
    let r = child_report();
    assert_child_walked_every_phase(r);

    assert_eq!(
        r.count("(before)") + r.count("S1_BEGIN"),
        0,
        "nothing may be logged before the budget is touched; child stderr:\n{}",
        r.stderr
    );
    let flood = r.count("S1_FLOOD");
    let snapshot = r.count("S1_SNAPSHOT");
    let flood2 = r.count("S1_FLOOD2");
    let total = flood + snapshot + flood2;
    assert!(
        total >= 1,
        "after 13 000 distinct 3 KiB OSC 8 links exhausted the live budget and a further 3 000 \
         were refused, the log must carry a breadcrumb mentioning OSC 8 and the exhausted \
         budget/limit; measured 0 line(s) (flood={flood}, snapshot={snapshot}, flood2={flood2}). \
         child stderr:\n{}",
        r.stderr
    );
    assert!(
        total <= 5,
        "~5 000 refused links must not log a line each (one-shot / rate-limited); measured \
         {total} line(s) (flood={flood}, snapshot={snapshot}, flood2={flood2}). child stderr:\n{}",
        r.stderr
    );
}

/// Per-session latch, like the intern-cap breadcrumb: a brand-new terminal
/// that exhausts its own budget must say so too (tab 2 must not lose the
/// breadcrumb because tab 1 already used it).
#[test]
fn a_fresh_session_exhausting_the_live_budget_leaves_its_own_breadcrumb() {
    let _g = serial();
    let r = child_report();
    assert_child_walked_every_phase(r);

    let s2 = r.count("S2_FLOOD") + r.count("S2_SNAPSHOT");
    assert!(
        (1..=5).contains(&s2),
        "a second session that exhausts its own OSC 8 live budget must leave its own bounded \
         breadcrumb (1..=5 lines); measured {s2} line(s). child stderr:\n{}",
        r.stderr
    );
}

// ---------------------------------------------------------------------------
// Credit-on-drop tests
// ---------------------------------------------------------------------------

/// Exhausts the budget on `term` (2 columns, scrollback >= EXHAUST_COUNT + 24
/// lines) and proves it: the newest flood row's link was refused.
fn exhaust_budget_into_history(term: &Term, name: &str) {
    // 12 000 x 3 KiB = 36 MiB of URIs against a 32 MiB budget (about
    // 10 400 links when costed at len + overhead, about 7 900 when costed at
    // a 4 KiB capacity): the tail of the flood must be refused.
    flood_link_rows(term, 0, 12_000, URI_3K);
    let snap = term.snapshot();
    let last_row = snap.rows() - 2;
    assert_eq!(
        snap.ch(last_row, 0),
        u32::from(b'x'),
        "{name}: the newest flood row must be visible"
    );
    assert_eq!(
        snap.link_id(last_row, 0),
        0,
        "{name}: precondition failed: 12 000 distinct 3 KiB links (36 MiB of URIs) did not \
         exhaust the 32 MiB live budget, so the newest link still got attributed"
    );
    assert!(
        snap.history() >= 11_000,
        "{name}: the flood rows must be held in scrollback; history_size={}",
        snap.history()
    );
}

/// After credit, an ordinary short link with an `id=` and a large probe
/// link (3.5 KiB, costlier than any flood link, so it cannot slip into
/// leftover budget room) are both attributed with their exact URLs.
fn assert_links_work_again(term: &Term, name: &str) {
    const ORDINARY: &str = "https://example.com/after-recovery?q=1";
    const PROBE_TAG: usize = 900_001;

    let mut buf: Vec<u8> = Vec::new();
    buf.extend_from_slice(b"\x1b]8;id=recover-1;");
    buf.extend_from_slice(ORDINARY.as_bytes());
    buf.extend_from_slice(b"\x1b\\ab");
    buf.extend_from_slice(CLOSE_LINK);
    buf.extend_from_slice(b"\r\n");
    push_link_row(&mut buf, PROBE_TAG, URI_PROBE);
    term.feed(&buf);
    assert_eq!(term.poisoned(), 0, "{name}: the term was poisoned");

    let snap = term.snapshot();
    let a_rows = snap.rows_with_char_in_col0(b'a');
    let x_rows = snap.rows_with_char_in_col0(b'x');
    assert_eq!(
        (a_rows.len(), x_rows.len()),
        (1, 1),
        "{name}: exactly one `ab` row and one probe `x` row must be visible; a_rows={a_rows:?} \
         x_rows={x_rows:?}"
    );
    let (ord_row, probe_row) = (a_rows[0], x_rows[0]);

    assert_eq!(
        snap.link_url(ord_row, 0).as_deref(),
        Some(ORDINARY),
        "{name}: after the budget holders went away an ordinary link must be attributed again \
         (first cell)"
    );
    assert_eq!(
        snap.link_url(ord_row, 1).as_deref(),
        Some(ORDINARY),
        "{name}: ordinary link, second cell"
    );
    let probe_url = snap.link_url(probe_row, 0);
    assert_eq!(
        probe_url.as_deref().map(str::len),
        Some(URI_PROBE),
        "{name}: a 3.5 KiB link must be attributed again once the budget was credited back; \
         got {:?} bytes of URL (None = still refused, the budget was not credited)",
        probe_url.as_deref().map(str::len)
    );
    assert_eq!(
        probe_url.as_deref(),
        Some(uri_for(PROBE_TAG, URI_PROBE).as_str()),
        "{name}: the probe link must resolve to its exact URL"
    );
}

/// Credit when rows fall out of the scrollback ring: print enough blank
/// lines that every link-bearing row is overwritten by the ring.
#[test]
fn links_work_again_after_budget_holders_scroll_out_of_history() {
    let _g = serial();
    const SCROLLBACK: u32 = 12_500;
    let term = Term::new(2, 24, SCROLLBACK);
    exhaust_budget_into_history(&term, "scroll-out");

    // 12 000 link rows are in history; push SCROLLBACK + a full screen of
    // blank lines so the ring has recycled every one of them.
    feed_newlines(&term, SCROLLBACK as usize + 24 + 100);
    {
        let snap = term.snapshot();
        assert_eq!(
            snap.history(),
            SCROLLBACK,
            "scroll-out: the scrollback ring must be full of blank lines"
        );
        assert_eq!(
            snap.rows_with_char_in_col0(b'x').len(),
            0,
            "scroll-out: no flood row may still be visible"
        );
    }
    assert_links_work_again(&term, "scroll-out");
}

/// Credit when scrollback is erased (`ED 3`, `CSI 3 J`).
#[test]
fn links_work_again_after_budget_holders_are_erased_with_ed3() {
    let _g = serial();
    let term = Term::new(2, 24, 12_500);
    exhaust_budget_into_history(&term, "ed3");

    // Home + ED 2 pushes the visible rows into history, ED 3 then erases
    // all of history: the viewport is blank and nothing holds a link.
    term.feed(b"\x1b[H\x1b[2J\x1b[3J");
    {
        let snap = term.snapshot();
        assert_eq!(
            snap.history(),
            0,
            "ed3: CSI 3 J must have erased the scrollback holding the links"
        );
        assert_eq!(
            snap.rows_with_char_in_col0(b'x').len(),
            0,
            "ed3: the viewport must be blank after the clear"
        );
    }
    assert_links_work_again(&term, "ed3");
}

/// Credit when cells are overwritten in place. The links live in the
/// viewport (100 x 24 cells, never scrolled), are overwritten with plain
/// text each round, and across the rounds far more distinct links are
/// created (12 000 x 3 KiB = 36 MiB of URIs) than the budget could ever
/// hold at once. If overwriting did not credit the budget back, the budget
/// would be exhausted long before the end.
#[test]
fn links_work_again_after_budget_holders_are_overwritten_in_place() {
    let _g = serial();
    const COLS: usize = 100;
    const ROWS: usize = 24;
    const ROUNDS: usize = 5;
    // Rig sizing (compile-time): without credit the rounds could not fit in
    // the budget; with it each round holds at most 2 400 links (~10 MiB), a
    // third of the budget.
    const _: () = assert!(ROUNDS * COLS * ROWS * URI_3K >= LIVE_BUDGET + LIVE_BUDGET / 16);

    let term = Term::new(COLS as u16, ROWS as u16, 100);
    let mut buf: Vec<u8> = Vec::with_capacity(FEED_BATCH + URI_3K + 128);
    let mut tag = 0usize;
    for round in 0..ROUNDS {
        // Links over every cell, no scrolling.
        buf.extend_from_slice(b"\x1b[H");
        for row in 0..ROWS {
            for _col in 0..COLS {
                push_open_link_x(&mut buf, tag, URI_3K);
                tag += 1;
                if buf.len() >= FEED_BATCH {
                    term.feed(&buf);
                    buf.clear();
                }
            }
            if row + 1 < ROWS {
                buf.extend_from_slice(b"\r\n");
            }
        }
        buf.extend_from_slice(CLOSE_LINK);
        // Overwrite every one of those cells with plain text.
        buf.extend_from_slice(b"\x1b[H");
        for row in 0..ROWS {
            buf.resize(buf.len() + COLS, b'o');
            if row + 1 < ROWS {
                buf.extend_from_slice(b"\r\n");
            }
        }
        term.feed(&buf);
        buf.clear();
        assert_eq!(term.poisoned(), 0, "round {round} poisoned the term");
    }
    {
        let snap = term.snapshot();
        assert_eq!(
            snap.history(),
            0,
            "overwrite: nothing may have scrolled into history (the links must be overwritten, \
             not scrolled away)"
        );
        assert_eq!(
            snap.linked_cells(),
            0,
            "overwrite: plain text over linked cells must clear the attribution"
        );
        assert_eq!(
            snap.ch(ROWS - 1, COLS - 1),
            u32::from(b'o'),
            "overwrite: the screen must be full of the overwriting text"
        );
    }

    // Probe at the home position: ordinary link over `ab`, big probe link
    // over the first cell of row 1.
    const ORDINARY: &str = "https://example.com/after-recovery?q=1";
    const PROBE_TAG: usize = 900_002;
    buf.extend_from_slice(b"\x1b[H\x1b]8;id=recover-2;");
    buf.extend_from_slice(ORDINARY.as_bytes());
    buf.extend_from_slice(b"\x1b\\ab");
    buf.extend_from_slice(CLOSE_LINK);
    buf.extend_from_slice(b"\x1b[2;1H");
    push_open_link_x(&mut buf, PROBE_TAG, URI_PROBE);
    buf.extend_from_slice(CLOSE_LINK);
    term.feed(&buf);

    let snap = term.snapshot();
    assert_eq!(
        (snap.ch(0, 0), snap.ch(0, 1), snap.ch(1, 0)),
        (u32::from(b'a'), u32::from(b'b'), u32::from(b'x')),
        "overwrite: the probe text must be at the home position"
    );
    assert_eq!(
        snap.link_url(0, 0).as_deref(),
        Some(ORDINARY),
        "overwrite: an ordinary link must be attributed after 12 000 links were created and \
         overwritten"
    );
    let probe_url = snap.link_url(1, 0);
    assert_eq!(
        probe_url.as_deref().map(str::len),
        Some(URI_PROBE),
        "overwrite: a 3.5 KiB link must be attributed after 12 000 links were created and \
         overwritten in place (None = the budget leaked); got {:?} bytes of URL",
        probe_url.as_deref().map(str::len)
    );
    assert_eq!(
        probe_url.as_deref(),
        Some(uri_for(PROBE_TAG, URI_PROBE).as_str()),
        "overwrite: the probe link must resolve to its exact URL"
    );
}

// ---------------------------------------------------------------------------
// Public API test
// ---------------------------------------------------------------------------

fn collect_rs_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("cannot read vendored source dir {}: {e}", dir.display()));
    for entry in entries {
        let path = entry.expect("dir entry").path();
        if path.is_dir() {
            collect_rs_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

/// `(1-based line, declaration text)` for every item declared with a bare
/// `pub` (not `pub(crate)` / `pub(super)`). A `fn` declaration is gathered
/// across lines up to its `{` or `;`; anything else is its first line.
fn bare_pub_declarations(src: &str) -> Vec<(usize, String)> {
    let lines: Vec<&str> = src.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let t = lines[i].trim_start();
        let is_pub = t.starts_with("pub ") && !t.starts_with("pub(");
        if is_pub {
            let is_fn = t.starts_with("pub fn ")
                || t.starts_with("pub const fn ")
                || t.starts_with("pub unsafe fn ")
                || t.starts_with("pub const unsafe fn ");
            let start = i;
            let mut text = String::from(t);
            if is_fn {
                while !text.contains('{')
                    && !text.contains(';')
                    && i + 1 < lines.len()
                    && i < start + 16
                {
                    i += 1;
                    text.push(' ');
                    text.push_str(lines[i].trim());
                }
                if let Some(end) = text.find(['{', ';']) {
                    text.truncate(end);
                }
            }
            out.push((start + 1, text));
        }
        i += 1;
    }
    out
}

/// "The accounting type is not part of the crate's public API": the shared
/// live-byte counter (`Arc<AtomicUsize>`) that the hyperlink budget is
/// debited from must not appear in any `pub` declaration of the vendored
/// `alacritty_terminal` or `vte` crates, and the budgeted constructor
/// (`Hyperlink::bounded`) that takes it must not be `pub`.
#[test]
fn hyperlink_accounting_type_is_not_part_of_the_public_api() {
    let _g = serial();
    let vendor = Path::new(env!("CARGO_MANIFEST_DIR")).join("../vendor");
    let mut files = Vec::new();
    collect_rs_files(&vendor.join("alacritty_terminal/src"), &mut files);
    collect_rs_files(&vendor.join("vte/src"), &mut files);
    files.sort();

    // Rig check: the scan really covers the file that declares Hyperlink.
    let mut saw_pub_hyperlink = false;
    let mut offenders: Vec<String> = Vec::new();
    for file in &files {
        let src = std::fs::read_to_string(file)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", file.display()));
        for (line, decl) in bare_pub_declarations(&src) {
            if decl.starts_with("pub struct Hyperlink") {
                saw_pub_hyperlink = true;
            }
            let names_counter = decl.contains("AtomicUsize");
            let is_budgeted_ctor = decl.contains("fn bounded");
            if names_counter || is_budgeted_ctor {
                offenders.push(format!(
                    "{}:{line}: {}",
                    file.strip_prefix(&vendor).unwrap_or(file).display(),
                    decl.trim()
                ));
            }
        }
    }
    assert!(
        files.len() >= 10 && saw_pub_hyperlink,
        "rig: the scan must cover the vendored crates and find `pub struct Hyperlink` \
         (scanned {} files, saw Hyperlink={saw_pub_hyperlink})",
        files.len()
    );
    assert!(
        offenders.is_empty(),
        "the OSC 8 live-budget accounting type must not leak through the public API of the \
         vendored crates (make it pub(crate) or private); public declarations that name \
         `AtomicUsize` or the budgeted constructor `bounded`:\n  {}",
        offenders.join("\n  ")
    );
}
