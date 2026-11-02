//! Blind regression tests for VT-2: the XTPUSHTITLE (`CSI 22 t`) title stack
//! must not turn a few input bytes into a full heap copy of the window title.
//!
//! Written from the bug report and the terminal conventions only, without
//! sight of the implementation.
//!
//! Observable contract:
//!   - `OSC 2 ; <title> BEL` may carry a very large title (the parser accepts
//!     up to ~8 MiB). Each following `CSI 22 t` is five bytes of input.
//!   - Retained heap after N such pushes must NOT grow as `N * title_len`.
//!     Any sane remedy satisfies this: share the title (Rc/Arc), cap what a
//!     stack entry may hold, cap the stack's total bytes, or refuse oversized
//!     titles. The test is agnostic to which one is chosen; it only demands
//!     that the amplification is bounded by a small constant budget rather
//!     than by (pushes x title size).
//!   - Ordinary titles keep working: push, overwrite, pop restores the
//!     pushed title byte-for-byte (guard test, passes before and after).
//!
//! How memory is observed: this test binary installs a counting global
//! allocator (wrapping `System`) and reads the live-byte counter around the
//! pushes. That is exact, deterministic and independent of RSS / malloc
//! zone caching. Because the counter is process-wide, every test takes
//! `SERIAL` first so the cargo test harness's parallel threads cannot
//! pollute a measurement.
//!
//! Pre-flight cost (memory x time), per test:
//!   - A: 1 MiB title, 256 pushes. Buggy build retains ~256 MiB (256 x 1 MiB
//!     clones), peak ~258 MiB; a fixed build stays under a few MiB.
//!     256 x 1 MiB memcpy is tens of milliseconds.
//!   - B: 64 KiB title, 4096 pushes (the full stack depth, 20,480 input
//!     bytes). Buggy build retains ~256 MiB; a fixed build stays tiny.
//!   - Guard + instrument self-check: a few KiB.
//!
//! Nothing here approaches the 8 MiB x 4096 = 32 GiB of the real attack.
//! One 10x3 BBTerm with 16 lines of scrollback per measurement; no I/O, no
//! sleeps.

use std::alloc::{GlobalAlloc, Layout, System};
use std::os::raw::c_void;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

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

const MIB: usize = 1024 * 1024;

/// Instrument self-check: a known 1 MiB allocation must move the live
/// counter by about 1 MiB and be released again. If this fails, every
/// "retained bytes" number below would be meaningless. The cargo harness's
/// own threads allocate and free a few KiB concurrently, so the comparison
/// allows `SLACK` of noise (the budgets below are tens of MiB).
fn assert_counter_is_live() {
    const SLACK: usize = 64 * 1024;
    let before = live_bytes();
    let probe = vec![7u8; MIB];
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
// FFI harness (payloads of large events are NOT retained: only their length)
// ---------------------------------------------------------------------------

const KIND_TITLE: u32 = bc::BBEventKind::Title as u32;
const KIND_FATAL: u32 = bc::BBEventKind::Fatal as u32;
/// Payloads up to this size are copied into the sink so the guard test can
/// compare text; larger ones are recorded by length only so the harness
/// never retains a copy of a huge title itself.
const KEEP_PAYLOAD_UP_TO: usize = 4096;

struct TitleEvent {
    len: usize,
    text: Option<String>,
}

#[derive(Default)]
struct Sink {
    titles: Vec<TitleEvent>,
    fatals: usize,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    let sink = &*(ctx as *const Mutex<Sink>);
    let mut sink = sink.lock().unwrap();
    match ev.kind as u32 {
        KIND_TITLE => {
            let text = if ev.payload.is_null() || ev.len == 0 {
                Some(String::new())
            } else if ev.len <= KEEP_PAYLOAD_UP_TO {
                Some(
                    String::from_utf8_lossy(std::slice::from_raw_parts(ev.payload, ev.len))
                        .into_owned(),
                )
            } else {
                None
            };
            sink.titles.push(TitleEvent { len: ev.len, text });
        }
        KIND_FATAL => sink.fatals += 1,
        _ => {}
    }
}

struct Harness {
    term: *mut bc::BBTerm,
    sink: Arc<Mutex<Sink>>,
    ctx: *mut c_void,
}

impl Harness {
    fn new() -> Self {
        let sink: Arc<Mutex<Sink>> = Arc::new(Mutex::new(Sink::default()));
        let ctx = Arc::into_raw(sink.clone()) as *mut c_void;
        let term = unsafe { bc::bb_term_new(10, 3, 16) };
        assert!(!term.is_null(), "bb_term_new returned null");
        unsafe { bc::bb_term_set_event_cb(term, Some(capture_cb), ctx) };
        Harness { term, sink, ctx }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    fn fatals(&self) -> usize {
        self.sink.lock().unwrap().fatals
    }

    fn title_event_count(&self) -> usize {
        self.sink.lock().unwrap().titles.len()
    }

    /// Delivered title texts in order (only those small enough to be kept).
    fn kept_titles(&self) -> Vec<String> {
        self.sink
            .lock()
            .unwrap()
            .titles
            .iter()
            .filter_map(|t| t.text.clone())
            .collect()
    }

    fn largest_title_event(&self) -> usize {
        self.sink
            .lock()
            .unwrap()
            .titles
            .iter()
            .map(|t| t.len)
            .max()
            .unwrap_or(0)
    }

    fn is_poisoned(&self) -> u8 {
        unsafe { bc::bb_term_is_poisoned(self.term) }
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        unsafe {
            bc::bb_term_set_event_cb(self.term, None, std::ptr::null_mut());
            bc::bb_term_free(self.term);
            drop(Arc::from_raw(self.ctx as *const Mutex<Sink>));
        }
    }
}

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

struct Cost {
    /// Heap in use once the title is set and before any push.
    baseline_live: usize,
    /// Growth in live heap attributable to the pushes (after the input
    /// buffers are freed, i.e. what the terminal itself kept).
    retained: usize,
    /// Highest live heap reached during the pushes, above the baseline.
    peak_over_baseline: usize,
    title_events: usize,
    largest_title_event: usize,
}

impl Cost {
    fn report(&self) -> String {
        format!(
            "baseline_live={} retained={} peak_over_baseline={} title_events={} \
             largest_title_event={}",
            self.baseline_live,
            self.retained,
            self.peak_over_baseline,
            self.title_events,
            self.largest_title_event
        )
    }
}

/// Set a `title_len`-byte title with OSC 2, then feed `pushes` x `CSI 22 t`
/// and report what the terminal kept.
fn measure_push_cost(title_len: usize, pushes: usize) -> Cost {
    assert_counter_is_live();
    let h = Harness::new();

    // OSC 2 ; AAAA... BEL
    {
        let mut seq = Vec::with_capacity(title_len + 8);
        seq.extend_from_slice(b"\x1b]2;");
        seq.resize(seq.len() + title_len, b'A');
        seq.push(0x07);
        h.feed(&seq);
    } // `seq` freed here, so it is not part of the baseline.

    assert_eq!(h.fatals(), 0, "setting the title raised a Fatal event");
    assert_eq!(h.is_poisoned(), 0, "setting the title poisoned the term");

    let baseline_live = live_bytes();
    PEAK.store(baseline_live, Ordering::SeqCst);

    // CSI 22 t is 5 bytes each.
    let chunk = b"\x1b[22t".repeat(pushes);
    assert_eq!(chunk.len(), 5 * pushes, "push chunk must be 5 bytes a push");
    h.feed(&chunk);
    drop(chunk); // exclude our own input buffer from the retained figure.

    let retained = live_bytes().saturating_sub(baseline_live);
    let peak_over_baseline = peak_bytes().saturating_sub(baseline_live);

    assert_eq!(h.fatals(), 0, "the pushes raised a Fatal event");
    assert_eq!(h.is_poisoned(), 0, "the pushes poisoned the term");

    Cost {
        baseline_live,
        retained,
        peak_over_baseline,
        title_events: h.title_event_count(),
        largest_title_event: h.largest_title_event(),
    }
}

/// Retained / peak growth allowed after the pushes. The buggy build holds
/// ~256 MiB in both A and B (8x this budget); a shared, capped or refused
/// title holds a few MiB at most.
const BUDGET: usize = 32 * MIB;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// EXPECTED TO FAIL on the buggy build (retains ~256 MiB).
#[test]
fn push_title_does_not_retain_a_full_copy_of_a_large_title_per_push() {
    let _g = serial();
    const TITLE: usize = MIB;
    const PUSHES: usize = 256;

    let c = measure_push_cost(TITLE, PUSHES);

    // The naive cost this test exists to forbid.
    let naive = TITLE * PUSHES;
    assert!(
        c.retained < BUDGET,
        "{PUSHES} x CSI 22 t ({} input bytes) on a {TITLE}-byte title retained {} bytes \
         ({:.1} MiB) of heap; naive per-push clone cost is {naive} bytes ({} MiB); \
         budget {BUDGET}. {}",
        5 * PUSHES,
        c.retained,
        c.retained as f64 / MIB as f64,
        naive / MIB,
        c.report(),
    );
    assert!(
        c.peak_over_baseline < BUDGET,
        "{PUSHES} x CSI 22 t on a {TITLE}-byte title drove peak heap {} bytes ({:.1} MiB) \
         above the pre-push baseline; budget {BUDGET}. {}",
        c.peak_over_baseline,
        c.peak_over_baseline as f64 / MIB as f64,
        c.report(),
    );
}

/// The full stack depth with a smaller title: the amplification must also
/// not scale with the number of pushes. EXPECTED TO FAIL on the buggy build
/// (4096 x 64 KiB = 256 MiB).
#[test]
fn push_title_to_full_stack_depth_stays_within_a_small_heap_budget() {
    let _g = serial();
    const TITLE: usize = 64 * 1024;
    const PUSHES: usize = 4096;

    let c = measure_push_cost(TITLE, PUSHES);

    let naive = TITLE * PUSHES;
    assert!(
        c.retained < BUDGET,
        "{PUSHES} x CSI 22 t ({} input bytes) on a {TITLE}-byte title retained {} bytes \
         ({:.1} MiB) of heap; naive per-push clone cost is {naive} bytes ({} MiB); \
         budget {BUDGET}. {}",
        5 * PUSHES,
        c.retained,
        c.retained as f64 / MIB as f64,
        naive / MIB,
        c.report(),
    );
    assert!(
        c.peak_over_baseline < BUDGET,
        "{PUSHES} x CSI 22 t on a {TITLE}-byte title drove peak heap {} bytes ({:.1} MiB) \
         above the pre-push baseline; budget {BUDGET}. {}",
        c.peak_over_baseline,
        c.peak_over_baseline as f64 / MIB as f64,
        c.report(),
    );
}

/// Guard (passes before and after the fix): a remedy must not break the
/// feature. Ordinary titles still round-trip exactly through nested
/// push / overwrite / pop, and pushing a title big enough to matter does not
/// disturb a later small push.
#[test]
fn ordinary_titles_still_round_trip_through_push_and_pop() {
    let _g = serial();
    assert_counter_is_live();

    let h = Harness::new();
    // A 200-byte title: well under any plausible per-entry cap.
    let long: String = "0123456789".repeat(20);
    assert_eq!(long.len(), 200);

    h.feed(format!("\x1b]2;{long}\x07").as_bytes());
    h.feed(b"\x1b[22t"); // push `long`
    h.feed(b"\x1b]2;two\x07");
    h.feed(b"\x1b[22t"); // push `two`
    h.feed(b"\x1b]2;three\x07");
    h.feed(b"\x1b[23t"); // pop -> `two`
    h.feed(b"\x1b[23t"); // pop -> `long`

    assert_eq!(h.fatals(), 0, "push/pop raised a Fatal event");
    assert_eq!(
        h.kept_titles(),
        vec![
            long.clone(),
            "two".to_string(),
            "three".to_string(),
            "two".to_string(),
            long,
        ],
        "set, set, set, pop, pop must deliver long/two/three then restore two then long; \
         title events delivered: {}",
        h.title_event_count()
    );
}
