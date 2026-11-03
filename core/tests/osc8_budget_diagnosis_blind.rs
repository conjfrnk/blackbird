//! Blind regression tests for OSC8-c: the diagnosis text and surrounding
//! bookkeeping of the OSC 8 per-terminal live-byte budget.
//!
//! Written from the bug report, the public C surface (`BBCore.h`, the doc
//! comment of `bb_term_clear_all`), the existing OSC 8 tests and the vendor
//! marker test only, without sight of the implementation bodies.
//!
//! Contract under test
//! -------------------
//!   1. TRUTHFUL REFUSAL LOG. When the live budget is exhausted the core
//!      logs one breadcrumb so a maintainer can diagnose "links stopped
//!      working". That text must state only what is true. Every remedy it
//!      names without a condition must really give the budget back wherever
//!      the budget is held. The two remedies a text can plausibly name are
//!      ERASING the rows that hold links (modelled as the shell's "wipe
//!      everything" sequence `ESC[H ESC[2J ESC[3J`) and Cmd-K
//!      (`bb_term_clear_all`). The links are honestly freed when their cells
//!      scroll out of the retained scrollback or are overwritten; erasing the
//!      screen frees them only if the rows holding them are reachable and
//!      actually released. Two situations are exercised. `primary`: 110 rows
//!      of links in the primary grid (a few hundred lines of history, far
//!      below the spare-row threshold at which the row storage really
//!      releases rows). `alt`: the links are held by the INACTIVE alternate
//!      grid (a TUI drew them and exited; an erase issued on the primary
//!      screen does not reach the other grid). Either remedy for a false
//!      text is accepted: make the named action release everything, or stop
//!      promising it unconditionally ("only if the rows are released", "does
//!      not free", or simply not naming it). The test is agnostic. It
//!      classifies the log, and if the log names a remedy without a
//!      condition it demands that the remedy restores a rejected link in
//!      each situation.
//!   2. LONG `id=`. The core never reads the `id=` OSC 8 parameter. An
//!      OSC 8 whose `id=` is longer than 256 bytes but whose URI is
//!      acceptable must still produce a working link (the id may be ignored
//!      or truncated) and must not be refused silently. The parser accepts
//!      an OSC payload of up to ~8 MiB (see `osc8_uri_retention_blind.rs`),
//!      so ids of several KiB reach the grid.
//!   3. RE-APPLY MARKERS. Every `Term` field added for the budget
//!      (`hyperlink_live`, `hyperlink_live_max`, `hyperlink_over_budget`),
//!      at its declaration and at its initialiser, carries the repo's
//!      `Blackbird fix (re-apply on bump)` marker (so a re-vendor of
//!      `alacritty_terminal` can find it), and the vendor marker test
//!      (`vendor_markers_blind.rs`) lists the fields, so dropping a marker
//!      is caught.
//!
//! How the log is observed: the core writes with `eprintln!`, which the
//! libtest harness would swallow, so the floods run in a re-executed child
//! of this very test binary with `--nocapture`; the parent parses the
//! child's stderr (phase markers `@@PHASE`, results `@@RESULT`).
//!
//! A note on snapshots: a snapshot has its own 1 MiB URI intern cap. A
//! snapshot is therefore only ever taken when the viewport holds none or one
//! link, never while thousands of distinct 3.5 KiB links are on screen, so
//! a missing attribution always means the live budget and nothing else.
//!
//! Pre-flight cost (memory x time) of the child, a debug build:
//!   - Four runs one after the other (`primary` and `alt`, each probed after
//!     Cmd-K and after an erase), each with its own terminal that is freed
//!     before the next starts.
//!   - `primary`: 100 columns x 110 rows of distinct 3.5 KiB links (11 000
//!     links, ~39 MB of input through one reusable 64 KiB buffer). Terminal
//!     100 x 24, 500 lines of scrollback (~100 KiB of cells).
//!   - `alt`: 120 x 100 terminal, 12 000 distinct 3.5 KiB links, ~43 MB of
//!     input.
//!   - The link heap a terminal retains is bounded by its own 32 MiB budget
//!     (measured ~34 MiB with grid), so the peak is < ~60 MiB; the child
//!     takes a few seconds in total.
//!   - The in-process tests are a few KiB each (the longest `id=` is 64 KiB)
//!     plus reading two source files of a few hundred KiB.

use std::collections::BTreeMap;
use std::ffi::CStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

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

    /// An erased cell reads back as NUL or a space, depending on how it was
    /// blanked; neither is text.
    fn is_blank(&self, row: usize, col: usize) -> bool {
        matches!(self.ch(row, col), 0 | 0x20)
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

    /// The app's Cmd-K.
    fn clear_all(&self) {
        unsafe { bc::bb_term_clear_all(self.ptr) };
    }
}

impl Drop for Term {
    fn drop(&mut self) {
        unsafe { bc::bb_term_free(self.ptr) };
    }
}

// ---------------------------------------------------------------------------
// Part 2: an over-long `id=` must not cost the link
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
// Part 1: the refusal log must be true. Child process scenarios.
// ---------------------------------------------------------------------------

const KIB: usize = 1024;

/// Flood links: 3.5 KiB, under the 4 KiB per-link cap.
const URI_FLOOD: usize = 3 * KIB + 512;
/// Probe link: exactly the 4 KiB cap (inclusive), costlier than any flood
/// link, so it cannot slip into room that is too small for a flood link.
const URI_PROBE: usize = 4 * KIB;
const PROBE_TAG: usize = 900_001;
/// Flush threshold for the reusable feed buffer.
const FEED_BATCH: usize = 64 * KIB;

const CLOSE_LINK: &[u8] = b"\x1b]8;;\x1b\\";

/// The exact URI the builders produce: a unique 24-byte prefix padded with
/// `a` up to `len` bytes.
fn uri_for(tag: usize, len: usize) -> String {
    let mut uri = format!("https://x.test/{tag:06}/");
    assert!(uri.len() <= len, "uri prefix {} > {len}", uri.len());
    while uri.len() < len {
        uri.push('a');
    }
    uri
}

/// `ESC ] 8 ; ; <uri> ESC \ x`: one linked `x`, link left open.
fn push_open_link_x(buf: &mut Vec<u8>, tag: usize, uri_len: usize) {
    buf.extend_from_slice(b"\x1b]8;;");
    buf.extend_from_slice(uri_for(tag, uri_len).as_bytes());
    buf.extend_from_slice(b"\x1b\\x");
}

/// A `rows` x `cols` block of distinct links, one per cell, CR LF between
/// rows (none after the last), the last link closed. Fed in `FEED_BATCH`
/// pieces so the reusable buffer stays small.
fn flood_link_block(term: &Term, rows: usize, cols: usize) {
    let mut buf: Vec<u8> = Vec::with_capacity(FEED_BATCH + URI_FLOOD + 128);
    let mut tag = 0usize;
    for row in 0..rows {
        for _col in 0..cols {
            push_open_link_x(&mut buf, tag, URI_FLOOD);
            tag += 1;
            if buf.len() >= FEED_BATCH {
                term.feed(&buf);
                buf.clear();
            }
        }
        if row + 1 < rows {
            buf.extend_from_slice(b"\r\n");
        }
    }
    buf.extend_from_slice(CLOSE_LINK);
    term.feed(&buf);
    assert_eq!(term.poisoned(), 0, "the link flood poisoned the term");
}

/// What the probe link did at the home cell: whether its `x` printed and the
/// URL attributed to it.
type ProbeOutcome = (bool, Option<String>);

/// Writes the probe link over the home cell.
fn probe_at_home(term: &Term) -> ProbeOutcome {
    let mut buf: Vec<u8> = Vec::new();
    buf.extend_from_slice(b"\x1b[H");
    push_open_link_x(&mut buf, PROBE_TAG, URI_PROBE);
    buf.extend_from_slice(CLOSE_LINK);
    term.feed(&buf);
    assert_eq!(term.poisoned(), 0, "the probe poisoned the term");
    let snap = term.snapshot();
    (snap.ch(0, 0) == u32::from(b'x'), snap.link_url(0, 0))
}

fn probe_is_accepted(got: &ProbeOutcome) -> bool {
    got.0 && got.1.as_deref() == Some(uri_for(PROBE_TAG, URI_PROBE).as_str())
}

fn probe_is_refused(got: &ProbeOutcome) -> bool {
    got.0 && got.1.is_none()
}

/// What the user (or a program) does to get the links back.
#[derive(Clone, Copy, Debug)]
enum Remedy {
    /// The app's Cmd-K.
    CmdK,
    /// Erase everything reachable from the primary screen: home, ED 2
    /// (screen), ED 3 (scrollback), the sequence a shell's "clear and wipe
    /// scrollback" emits.
    Erase,
}

impl Remedy {
    fn tag(self) -> &'static str {
        match self {
            Remedy::CmdK => "cmdk",
            Remedy::Erase => "erase",
        }
    }

    fn apply(self, term: &Term) {
        match self {
            Remedy::CmdK => term.clear_all(),
            Remedy::Erase => term.feed(b"\x1b[H\x1b[2J\x1b[3J"),
        }
        assert_eq!(
            term.poisoned(),
            0,
            "the {} remedy poisoned the term",
            self.tag()
        );
    }
}

const CHILD_ENV: &str = "BB_OSC8_BUDGET_DIAGNOSIS_BLIND_CHILD";
const CHILD_ENTRY_TEST: &str = "rig_refusal_log_scenarios_run_and_hold_the_budget";

/// Rig precondition for every run, in a throwaway terminal: the probe bytes
/// themselves are accepted by a terminal whose budget is untouched.
fn child_canary() {
    let fresh = Term::new(80, 24, 10);
    let got = probe_at_home(&fresh);
    assert!(
        probe_is_accepted(&got),
        "child rig: the 4 KiB probe must be accepted by a fresh terminal, got {got:?}"
    );
}

/// What a run measured, printed as one `@@RESULT` line.
fn report(run: &str, exhausted: bool, wiped: bool, frees: bool) {
    eprintln!(
        "@@RESULT {run} exhausted={} wiped={} frees={}",
        u8::from(exhausted),
        u8::from(wiped),
        u8::from(frees)
    );
}

/// Applies the remedy and re-probes. Returns `(wiped, probe accepted)`.
fn remedy_and_reprobe(term: &Term, remedy: Remedy) -> (bool, bool) {
    // Rig: there is something visible to wipe (the refused probe's `x`).
    {
        let snap = term.snapshot();
        assert_eq!(
            snap.ch(0, 0),
            u32::from(b'x'),
            "child rig: the probe text must be on screen before the remedy"
        );
    }
    remedy.apply(term);
    let wiped = {
        let snap = term.snapshot();
        snap.is_blank(0, 0) && snap.history() == 0
    };
    let again = probe_at_home(term);
    (wiped, probe_is_accepted(&again))
}

/// A primary grid whose rows hold the whole budget, few enough rows (well
/// under the ~1000 spare rows the row storage keeps before it frees any)
/// that a screen wipe leaves the rows themselves allocated.
fn run_primary(remedy: Remedy) {
    const COLS: usize = 100;
    const ROWS: usize = 110;
    // Rig sizing: 11 000 x 3.5 KiB = 37.6 MiB of URIs against a 32 MiB budget.
    const _: () = assert!(COLS * ROWS * URI_FLOOD >= 36 * 1024 * 1024);
    let run = format!("primary_{}", remedy.tag());
    eprintln!("@@PHASE {run}_BEGIN");
    child_canary();
    let term = Term::new(COLS as u16, 24, 500);
    flood_link_block(&term, ROWS, COLS);
    // Home + ED 2: the linked viewport goes to history, the viewport is blank,
    // so the snapshot below carries at most one link.
    term.feed(b"\x1b[H\x1b[2J");
    {
        let snap = term.snapshot();
        assert!(
            snap.history() as usize >= ROWS - 10 && (snap.history() as usize) < 400,
            "child rig: the linked rows must sit in a few hundred lines of history; \
             history_size={}",
            snap.history()
        );
        assert!(
            snap.is_blank(0, 0),
            "child rig: the viewport must be blank, cell (0,0)={}",
            snap.ch(0, 0)
        );
    }
    let before = probe_at_home(&term);
    let exhausted = probe_is_refused(&before);
    eprintln!("@@PHASE {run}_REMEDY");
    let (wiped, frees) = remedy_and_reprobe(&term, remedy);
    report(&run, exhausted, wiped, frees);
    eprintln!("@@PHASE {run}_END");
}

/// The budget held by the INACTIVE alternate grid: a program drew a screen of
/// links on the alternate screen and left it. The remedy runs on the primary
/// screen, which does not touch the other grid.
fn run_alt(remedy: Remedy) {
    const COLS: usize = 120;
    const ROWS: usize = 100;
    // Rig sizing: 12 000 x 3.5 KiB = 41 MiB of URIs against a 32 MiB budget.
    const _: () = assert!(COLS * ROWS * URI_FLOOD >= 40 * 1024 * 1024);
    let run = format!("alt_{}", remedy.tag());
    eprintln!("@@PHASE {run}_BEGIN");
    child_canary();
    let term = Term::new(COLS as u16, ROWS as u16, 100);
    term.feed(b"\x1b[?1049h\x1b[H");
    flood_link_block(&term, ROWS, COLS);
    eprintln!("@@PHASE {run}_LEAVE");
    term.feed(b"\x1b[?1049l");
    {
        let snap = term.snapshot();
        assert_eq!(
            (snap.is_blank(0, 0), snap.history()),
            (true, 0),
            "child rig: back on the primary screen it must be blank with no history; \
             cell (0,0)={}",
            snap.ch(0, 0)
        );
    }
    let before = probe_at_home(&term);
    let exhausted = probe_is_refused(&before);
    eprintln!("@@PHASE {run}_REMEDY");
    let (wiped, frees) = remedy_and_reprobe(&term, remedy);
    report(&run, exhausted, wiped, frees);
    eprintln!("@@PHASE {run}_END");
}

const RUNS: [&str; 4] = ["primary_cmdk", "primary_erase", "alt_cmdk", "alt_erase"];

fn run_child_scenarios() {
    run_primary(Remedy::CmdK);
    run_primary(Remedy::Erase);
    run_alt(Remedy::CmdK);
    run_alt(Remedy::Erase);
    eprintln!("@@PHASE END");
}

/// One run as seen from the parent.
#[derive(Debug, Default)]
struct RunReport {
    /// The probe was refused before the remedy (the budget really was held).
    exhausted: bool,
    /// The remedy blanked the screen and emptied the history.
    wiped: bool,
    /// The probe was accepted after the remedy.
    frees: bool,
    result_seen: bool,
    /// Live-budget breadcrumb lines logged during the run.
    breadcrumbs: Vec<String>,
}

struct ChildReport {
    stderr: String,
    phases: Vec<String>,
    runs: BTreeMap<String, RunReport>,
}

/// A line that tells the maintainer the OSC 8 live budget refused links. The
/// sibling intern-cap line ("OSC 8 URI intern budget ... exhausted") is a
/// different budget and is excluded.
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

fn parse_child_stderr(stderr: &str) -> ChildReport {
    let mut phases: Vec<String> = Vec::new();
    let mut runs: BTreeMap<String, RunReport> = BTreeMap::new();
    let mut current: Option<String> = None;
    for line in stderr.lines() {
        if let Some(name) = line.strip_prefix("@@PHASE ") {
            let name = name.trim().to_owned();
            if let Some(run) = name.strip_suffix("_BEGIN") {
                current = Some(run.to_owned());
                runs.entry(run.to_owned()).or_default();
            } else if name.ends_with("_END") || name == "END" {
                current = None;
            }
            phases.push(name);
        } else if let Some(rest) = line.strip_prefix("@@RESULT ") {
            let mut parts = rest.split_whitespace();
            let run = parts.next().unwrap_or_default().to_owned();
            let entry = runs.entry(run).or_default();
            entry.result_seen = true;
            for kv in parts {
                match kv {
                    "exhausted=1" => entry.exhausted = true,
                    "wiped=1" => entry.wiped = true,
                    "frees=1" => entry.frees = true,
                    _ => {}
                }
            }
        } else if is_budget_breadcrumb(line) {
            if let Some(run) = &current {
                runs.entry(run.clone())
                    .or_default()
                    .breadcrumbs
                    .push(line.trim().to_owned());
            }
        }
    }
    ChildReport {
        stderr: stderr.to_owned(),
        phases,
        runs,
    }
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
            .expect("re-exec the test binary as the scenario child");
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        assert!(
            out.status.success(),
            "scenario child failed ({:?}); stderr:\n{stderr}",
            out.status
        );
        parse_child_stderr(&stderr)
    })
}

// --- Classifying what a log promises ---------------------------------------

/// What a log text promises about one remedy.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum Promise {
    /// The remedy is not named.
    NotMentioned,
    /// Named, but conditioned or negated (honest about when it works).
    Hedged,
    /// Named as a plain way to get the links back.
    Unconditional,
}

/// Words of a lower-cased sentence, apostrophes kept (`doesn't`).
fn words(sentence: &str) -> Vec<String> {
    sentence
        .split(|c: char| !(c.is_alphanumeric() || c == '\''))
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Spelling variants of Cmd-K collapse to one string: "Cmd-K", "cmd+k",
/// "Cmd K", "\u{2318}K", "Command-K", "bb_term_clear_all", "clear all".
fn mentions_cmd_k(text: &str) -> bool {
    let squashed: String = text
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '\u{2318}')
        .collect();
    ["cmdk", "commandk", "\u{2318}k", "clearall"]
        .iter()
        .any(|n| squashed.contains(n))
}

/// "erase", "erased", "erases", "erasing".
fn mentions_erase(text: &str) -> bool {
    words(&text.to_lowercase())
        .iter()
        .any(|w| w.starts_with("eras"))
}

/// Phrases that make a promise conditional or retract it, anywhere in the
/// log. Deliberately specific: a generic "not" also appears in "links will not
/// be attributed", which says nothing about a remedy.
const HEDGE_PHRASES: [&str; 20] = [
    "only if",
    "only when",
    "only after",
    "unless",
    "may not",
    "might not",
    "not always",
    "not necessarily",
    "sometimes",
    "does not free",
    "doesn't free",
    "does not release",
    "doesn't release",
    "will not free",
    "won't free",
    "cannot free",
    "can't free",
    "not free",
    "not release",
    "if the rows",
];

/// A negation followed, within four words, by a verb that says the remedy
/// works or does not ("cannot release", "never frees", "isn't able to help").
fn negates_a_remedy(sentence: &str) -> bool {
    const REMEDY_VERBS: [&str; 15] = [
        "free", "frees", "freed", "release", "releases", "released", "reclaim", "restore",
        "restores", "help", "helps", "work", "works", "recover", "reach",
    ];
    let w = words(&sentence.to_lowercase());
    w.iter().enumerate().any(|(i, word)| {
        let negator =
            matches!(word.as_str(), "not" | "never" | "no" | "cannot") || word.ends_with("n't");
        negator
            && w.iter()
                .skip(i + 1)
                .take(4)
                .any(|next| REMEDY_VERBS.contains(&next.as_str()))
    })
}

fn sentences(log: &str) -> Vec<&str> {
    log.split(['.', ';', '\n', '!', '?', '\u{2014}']).collect()
}

fn classify_promise(log: &str, mentions: fn(&str) -> bool) -> Promise {
    let touching: Vec<&str> = sentences(log).into_iter().filter(|s| mentions(s)).collect();
    if touching.is_empty() {
        return Promise::NotMentioned;
    }
    let lower = log.to_lowercase();
    let hedged = HEDGE_PHRASES.iter().any(|h| lower.contains(h))
        || touching.iter().any(|s| negates_a_remedy(s));
    if hedged {
        Promise::Hedged
    } else {
        Promise::Unconditional
    }
}

/// The wording of the refusal log the code carried when OSC8-c was filed.
const OLD_LOG: &str = "[blackbird_core] OSC 8 hyperlink live-byte budget exhausted \u{2014} new \
    hyperlinks are refused (printed without a link) until the rows holding links are erased \
    (\u{2318}K, bb_term_clear_all) or have scrolled out of scrollback (the grid keeps a row for up \
    to ~1000 more scrolls after that). Symptom: 'links stopped working'. One-shot per session.";

/// Rig for the classifiers: pinned on texts that must and must not count as
/// an unconditional promise of each remedy, including the old log verbatim.
#[test]
fn rig_promise_classifiers_pin_their_verdicts() {
    use Promise::{Hedged, NotMentioned, Unconditional};
    // (text, verdict for Cmd-K, verdict for erasing)
    let cases: [(&str, Promise, Promise); 12] = [
        (OLD_LOG, Unconditional, Unconditional),
        (
            "OSC 8 hyperlink budget exhausted; new links are dropped until Cmd-K clears them",
            Unconditional,
            NotMentioned,
        ),
        (
            "OSC 8 link budget exhausted: press \u{2318}K to free it",
            Unconditional,
            NotMentioned,
        ),
        (
            "OSC 8 hyperlink limit reached (bb_term_clear_all frees links)",
            Unconditional,
            NotMentioned,
        ),
        (
            "OSC 8 hyperlink budget exhausted; links are freed when their cells scroll out of \
             the retained scrollback or are overwritten",
            NotMentioned,
            NotMentioned,
        ),
        (
            "OSC 8 hyperlink budget exhausted; new links will not be attributed until \u{2318}K",
            Unconditional,
            NotMentioned,
        ),
        (
            "OSC 8 hyperlink budget exhausted; links are freed when their cells scroll out or \
             are overwritten; erasing the screen (or \u{2318}K) frees them only if the rows are \
             actually released",
            Hedged,
            Hedged,
        ),
        (
            "OSC 8 hyperlink budget exhausted; Cmd-K does not free links held by the inactive \
             alternate screen",
            Hedged,
            NotMentioned,
        ),
        (
            "OSC 8 hyperlink budget exhausted; \u{2318}K cannot release them",
            Hedged,
            NotMentioned,
        ),
        (
            "OSC 8 hyperlink budget exhausted; Cmd-K may not help",
            Hedged,
            NotMentioned,
        ),
        (
            "OSC 8 hyperlink budget exhausted; erase the rows to get links back",
            NotMentioned,
            Unconditional,
        ),
        ("", NotMentioned, NotMentioned),
    ];
    for (text, want_cmd_k, want_erase) in cases {
        assert_eq!(
            classify_promise(text, mentions_cmd_k),
            want_cmd_k,
            "Cmd-K verdict for {text:?}"
        );
        assert_eq!(
            classify_promise(text, mentions_erase),
            want_erase,
            "erase verdict for {text:?}"
        );
    }
}

fn expected_phases() -> Vec<String> {
    let mut v: Vec<String> = Vec::new();
    for run in RUNS {
        v.push(format!("{run}_BEGIN"));
        if run.starts_with("alt") {
            v.push(format!("{run}_LEAVE"));
        }
        v.push(format!("{run}_REMEDY"));
        v.push(format!("{run}_END"));
    }
    v.push("END".to_owned());
    v
}

fn assert_child_walked_every_phase(r: &ChildReport) {
    assert_eq!(
        r.phases,
        expected_phases(),
        "rig precondition: the child must walk every phase; child stderr:\n{}",
        r.stderr
    );
}

/// The child entry point and, in the parent, the rig preconditions every
/// behavioural test below relies on.
#[test]
fn rig_refusal_log_scenarios_run_and_hold_the_budget() {
    if matches!(std::env::var(CHILD_ENV).as_deref(), Ok("1")) {
        run_child_scenarios();
        return;
    }
    let r = child_report();
    assert_child_walked_every_phase(r);
    for name in RUNS {
        let s = &r.runs[name];
        assert!(
            s.result_seen,
            "no @@RESULT line for {name}; stderr:\n{}",
            r.stderr
        );
        assert!(
            s.wiped,
            "{name}: the remedy must blank the screen and empty the history (it is the action \
             under test); {s:?}"
        );
        assert!(
            !s.breadcrumbs.is_empty(),
            "{name}: exhausting the live budget with ~40 MB of distinct 3.5 KiB links must leave \
             a breadcrumb that names OSC 8 and the exhausted budget/limit; stderr:\n{}",
            r.stderr
        );
    }
    // Links in primary rows cannot be released by anything but the remedy,
    // so the budget must still be held right before it.
    for name in ["primary_cmdk", "primary_erase"] {
        assert!(
            r.runs[name].exhausted,
            "{name}: after 11 000 distinct 3.5 KiB links in the primary grid the 4 KiB probe \
             must be refused (budget held) before the remedy; stderr:\n{}",
            r.stderr
        );
    }
}

/// If the log promises `remedy` (as classified by `mentions`), the remedy
/// must keep the promise in `run`.
fn assert_promise_is_kept(
    run: &str,
    remedy_name: &str,
    mentions: fn(&str) -> bool,
    situation: &str,
) {
    let r = child_report();
    assert_child_walked_every_phase(r);
    let s = &r.runs[run];
    assert!(
        !s.breadcrumbs.is_empty(),
        "{run}: no live-budget breadcrumb was logged, so there is no text to judge; stderr:\n{}",
        r.stderr
    );
    let log = s.breadcrumbs.join("\n");
    if classify_promise(&log, mentions) != Promise::Unconditional {
        return;
    }
    // A budget that is no longer held after the program left (a build that
    // releases the inactive grid on its own) has nothing for the remedy to
    // free.
    assert!(
        !s.exhausted || s.frees,
        "The OSC 8 live-budget refusal log names {remedy_name} as a way to get links back, \
         without a condition, but {situation}: the 4 KiB probe link was refused before the \
         remedy (budget held: {}), the remedy blanked the screen (wiped={}), and the same probe \
         is STILL refused afterwards (accepted={}). A maintainer told '{remedy_name} frees the \
         hyperlink budget' is misled. Either make the action release the held links of both \
         grids, or state only what is true: links are freed when their cells scroll out of the \
         retained scrollback or are overwritten, and erasing the screen frees them only if the \
         rows holding them are reachable and actually released. Logged text: {log:?}",
        s.exhausted,
        s.wiped,
        s.frees
    );
}

#[test]
fn refusal_log_cmd_k_promise_holds_for_links_in_the_primary_grid() {
    assert_promise_is_kept(
        "primary_cmdk",
        "Cmd-K",
        mentions_cmd_k,
        "110 rows of distinct links sit in a few hundred lines of primary history",
    );
}

#[test]
fn refusal_log_cmd_k_promise_holds_for_links_held_by_the_inactive_alt_grid() {
    assert_promise_is_kept(
        "alt_cmdk",
        "Cmd-K",
        mentions_cmd_k,
        "the links are held by the inactive alternate grid after a program left the alternate \
         screen",
    );
}

#[test]
fn refusal_log_erase_promise_holds_for_links_in_the_primary_grid() {
    assert_promise_is_kept(
        "primary_erase",
        "erasing the rows (ESC[H ESC[2J ESC[3J)",
        mentions_erase,
        "110 rows of distinct links sit in a few hundred lines of primary history",
    );
}

/// The unreachable-grid case: erasing from the primary screen cannot free
/// links the inactive alternate grid holds, so a log that says erasing the
/// rows frees them is false.
#[test]
fn refusal_log_erase_promise_holds_for_links_held_by_the_inactive_alt_grid() {
    assert_promise_is_kept(
        "alt_erase",
        "erasing the rows (ESC[H ESC[2J ESC[3J)",
        mentions_erase,
        "the links are held by the inactive alternate grid after a program left the alternate \
         screen, and an erase issued on the primary screen does not reach that grid",
    );
}

// ---------------------------------------------------------------------------
// Part 3: the budget fields on Term carry the re-apply marker
// ---------------------------------------------------------------------------

const TERM_SRC: &str = "vendor/alacritty_terminal/src/term/mod.rs";
const MARKER_TEST_SRC: &str = "core/tests/vendor_markers_blind.rs";
const BUDGET_FIELDS: [&str; 3] = [
    "hyperlink_live",
    "hyperlink_live_max",
    "hyperlink_over_budget",
];
const MARKER_PHRASE: &str = "(re-apply on bump)";

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("core/ has a parent directory (the repo root)")
        .to_path_buf()
}

fn load(rel: &str) -> Vec<String> {
    let path = repo_root().join(rel);
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read source {}: {e}", path.display()));
    let lines: Vec<String> = text.lines().map(str::to_owned).collect();
    assert!(
        lines.len() > 50,
        "{rel} has only {} lines; the file moved or was truncated",
        lines.len()
    );
    lines
}

/// A COMMENT that names Blackbird and then carries `(re-apply on bump)`
/// (the repo's marker, same predicate as `vendor_markers_blind.rs`).
fn is_marker(line: &str) -> bool {
    let trimmed = line.trim_start();
    if !trimmed.starts_with("//") {
        return false;
    }
    let lower = trimmed.to_ascii_lowercase();
    match (lower.find("blackbird"), lower.find(MARKER_PHRASE)) {
        (Some(who), Some(phrase)) => who < phrase,
        _ => false,
    }
}

fn strip_visibility(mut s: &str) -> &str {
    for prefix in ["pub(crate) ", "pub(super) ", "pub "] {
        if let Some(rest) = s.strip_prefix(prefix) {
            s = rest;
            break;
        }
    }
    s
}

/// Is `line` a struct field line (declaration `name: Type,` or initialiser
/// `name: expr,` / shorthand `name,`) for exactly `name`?
fn is_field_line(line: &str, name: &str) -> bool {
    let rest = strip_visibility(line.trim_start());
    match rest.strip_prefix(name) {
        Some(tail) => {
            tail.starts_with(':') || tail.starts_with(',') || tail.trim_start().starts_with(':')
        }
        None => false,
    }
}

/// Marked when a marker comment sits on the line itself (trailing comment) or
/// anywhere in the contiguous non-blank lines directly above it: the same
/// "attached block" the vendor marker test uses, so one comment may head a
/// group of adjacent fields.
fn is_attached_marker(lines: &[String], idx: usize) -> bool {
    if let Some(pos) = lines[idx].find("//") {
        if is_marker(&lines[idx][pos..]) {
            return true;
        }
    }
    let mut i = idx;
    while i > 0 && !lines[i - 1].trim().is_empty() {
        i -= 1;
        if is_marker(&lines[i]) {
            return true;
        }
    }
    false
}

/// `[start, end]` (0-based) of the column-0 `pub struct Term<..> {` block.
fn term_struct_block(lines: &[String]) -> (usize, usize) {
    let starts: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with("pub struct Term<"))
        .map(|(i, _)| i)
        .collect();
    assert_eq!(
        starts.len(),
        1,
        "{TERM_SRC}: expected exactly one `pub struct Term<`, found 0-based lines {starts:?}"
    );
    let end = (starts[0] + 1..lines.len())
        .find(|&i| lines[i] == "}")
        .unwrap_or_else(|| panic!("{TERM_SRC}: struct Term never closes"));
    (starts[0], end)
}

/// Rig: the marker predicate, the field-line matcher and the attached-block
/// rule are pinned on synthetic source, so a green marker test below cannot
/// mean "matched nothing".
#[test]
fn rig_marker_scan_helpers_behave_on_synthetic_source() {
    assert!(is_marker(
        "    /// Blackbird fix (re-apply on bump): bytes held by live hyperlinks"
    ));
    assert!(is_marker(
        "        // Blackbird addition (re-apply on bump): x"
    ));
    assert!(!is_marker("    /// Blackbird fix: no phrase"));
    assert!(!is_marker("    // (re-apply on bump) Blackbird"));
    assert!(!is_marker(
        "    let s = \"Blackbird fix (re-apply on bump)\";"
    ));

    assert!(is_field_line(
        "    hyperlink_live: Arc<AtomicUsize>,",
        "hyperlink_live"
    ));
    assert!(is_field_line(
        "            hyperlink_live: Default::default(),",
        "hyperlink_live"
    ));
    assert!(is_field_line(
        "            hyperlink_live,",
        "hyperlink_live"
    ));
    assert!(is_field_line(
        "    pub(crate) hyperlink_live: u8,",
        "hyperlink_live"
    ));
    assert!(!is_field_line(
        "    hyperlink_live_max: usize,",
        "hyperlink_live"
    ));
    assert!(!is_field_line(
        "    self.hyperlink_live.load()",
        "hyperlink_live"
    ));
    assert!(!is_field_line(
        "    let hyperlink_live = 1;",
        "hyperlink_live"
    ));

    let src: Vec<String> = [
        "    /// Blackbird fix (re-apply on bump): group marker",
        "    alpha: u8,",
        "    beta: u8,",
        "",
        "    /// ordinary doc",
        "    gamma: u8,",
        "    delta: u8, // Blackbird fix (re-apply on bump): trailing",
        "",
        "    epsilon: u8,",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    let names = ["alpha", "beta", "gamma", "delta", "epsilon"];
    let marked: Vec<bool> = (0..src.len())
        .filter(|&i| names.iter().any(|n| is_field_line(&src[i], n)))
        .map(|i| is_attached_marker(&src, i))
        .collect();
    assert_eq!(
        marked,
        vec![true, true, false, true, false],
        "attached-marker rule on alpha, beta, gamma, delta, epsilon"
    );
}

#[test]
fn budget_fields_on_term_carry_the_reapply_marker_at_declaration_and_initialiser() {
    let lines = load(TERM_SRC);
    let (lo, hi) = term_struct_block(&lines);

    let mut unmarked: Vec<String> = Vec::new();
    for name in BUDGET_FIELDS {
        let hits: Vec<usize> = (0..lines.len())
            .filter(|&i| is_field_line(&lines[i], name))
            .collect();
        let decls: Vec<usize> = hits.iter().copied().filter(|&i| i > lo && i < hi).collect();
        let inits: Vec<usize> = hits.iter().copied().filter(|&i| i < lo || i > hi).collect();
        // Rig: every field is declared once in `struct Term` and initialised
        // at least once elsewhere in the file.
        assert_eq!(
            decls.len(),
            1,
            "{TERM_SRC}: expected exactly one declaration of `{name}` in `struct Term`, found \
             1-based lines {:?}",
            decls.iter().map(|i| i + 1).collect::<Vec<usize>>()
        );
        assert!(
            !inits.is_empty(),
            "{TERM_SRC}: expected at least one initialiser of `{name}` outside `struct Term`"
        );
        for (kind, idxs) in [("declaration", &decls), ("initialiser", &inits)] {
            for &i in idxs {
                if !is_attached_marker(&lines, i) {
                    unmarked.push(format!(
                        "{TERM_SRC}:{} {kind} of `{name}`: `{}`",
                        i + 1,
                        lines[i].trim()
                    ));
                }
            }
        }
    }
    assert_eq!(
        unmarked,
        Vec::<String>::new(),
        "every OSC 8 budget field on Term (declaration and initialiser) must carry a \
         `Blackbird fix (re-apply on bump)` comment, directly or as the head of the adjacent \
         group, so a re-vendor of alacritty_terminal finds it"
    );
}

/// Whole-word occurrence of `word` in `line`.
fn mentions_word(line: &str, word: &str) -> bool {
    let is_ident = |c: char| c.is_alphanumeric() || c == '_';
    let mut from = 0;
    while let Some(pos) = line[from..].find(word) {
        let start = from + pos;
        let end = start + word.len();
        let before_ok = line[..start]
            .chars()
            .next_back()
            .is_none_or(|c| !is_ident(c));
        let after_ok = line[end..].chars().next().is_none_or(|c| !is_ident(c));
        if before_ok && after_ok {
            return true;
        }
        from = start + word.len();
    }
    false
}

/// "The marker test lists them": the vendor marker test names each budget
/// field in code (a `Site { needle: "hyperlink_live", .. }` entry), so
/// dropping a field's marker fails a test.
#[test]
fn vendor_marker_test_lists_every_budget_field() {
    let lines = load(MARKER_TEST_SRC);
    // Rig: the file is the marker test and its OSC 8 budget test still exists.
    assert!(
        lines
            .iter()
            .any(|l| l.contains("fn osc8_budget_carries_reapply_marker")),
        "{MARKER_TEST_SRC}: the OSC 8 budget marker test (osc8_budget_carries_reapply_marker) \
         moved or was renamed; update this rig"
    );
    let code: Vec<&String> = lines
        .iter()
        .filter(|l| !l.trim_start().starts_with("//"))
        .collect();
    let missing: Vec<&str> = BUDGET_FIELDS
        .iter()
        .copied()
        .filter(|f| !code.iter().any(|l| mentions_word(l, f)))
        .collect();
    assert_eq!(
        missing,
        Vec::<&str>::new(),
        "{MARKER_TEST_SRC} must list the Term fields added for the OSC 8 live budget (as `Site` \
         needles, next to HYPERLINK_LIVE_MAX / HyperlinkInner / set_hyperlink); not mentioned in \
         code: {missing:?}"
    );
}
