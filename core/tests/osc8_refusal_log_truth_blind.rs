//! Blind regression tests for OSC8-d: the OSC 8 live-budget refusal log must
//! tell the truth, and the tests that police it must be able to fail.
//!
//! Written from the bug report, the public C surface (`BBCore.h`, the doc
//! comment of `bb_term_clear_all`), the existing OSC 8 tests (especially
//! `osc8_budget_diagnosis_blind.rs`, whose child-process rig this borrows)
//! and the log text the core prints, without sight of the implementation
//! bodies.
//!
//! Why this file exists
//! --------------------
//! The refusal-log tests that used to live in `osc8_budget_diagnosis_blind.rs`
//! judged the log with `classify_promise`, which called a remedy "hedged" when
//! ANY hedge phrase ("only if", "does not free", "if the rows", ...) appeared
//! ANYWHERE in the log, even in a sentence about something else. A log that
//! hedges one remedy therefore shielded a false, unconditional promise about
//! another, and a log whose hedge is stale shielded itself. Those four
//! `refusal_log_*_promise_holds` tests could only pass.
//!
//! A first replacement that judged each SENTENCE still passed vacuously: the
//! log pairs a "frees" claim with a "does not reach" claim after a ", but" in
//! the one sentence that names each remedy, so the negation made the whole
//! sentence a hedge and the "frees" claim was never compared with anything.
//! The log is therefore read CLAUSE by clause.
//!
//! Contract under test
//! -------------------
//!   1. CLAIMS, READ CLAUSE BY CLAUSE. Every clause of the log that names a
//!      remedy (Cmd-K = `bb_term_clear_all`; erasing = `ESC[H ESC[2J ESC[3J`)
//!      is a claim: the remedy frees the links ("frees the links held by the
//!      screen that is showing") or it does not ("does not reach the other
//!      screen's rows"). A clause that names no remedy ("but it does not reach
//!      ...") speaks for the one before it. Scope words (the screen that is
//!      showing, the other screen, while the alternate screen is up, visible
//!      rows) narrow a claim to the measured situations it is about; a clause
//!      with none speaks about all of them; where claims overlap the narrowest
//!      wins. Each claim is compared with the measured outcome of every
//!      situation in its scope (links held by the primary grid, by the
//!      inactive alternate grid, or by the primary grid while the alternate
//!      screen is up; each with and without history): the probe link that was
//!      refused before the remedy must be accepted after it where the log says
//!      the remedy frees, and must still be refused where the log says it does
//!      not. A false promise and a false denial both fail. A hedge the reader
//!      cannot place (an unscoped "only if", "may not") promises and denies
//!      nothing, and a situation the log is silent about cannot fail.
//!   2. NO STALE ROW-RELEASE CONDITION. `Grid::clear_history` truncates, so
//!      the rows an erase or Cmd-K reaches are released at once, whatever the
//!      history size. The measured proof is the matrix below: for each
//!      remedy, the outcome with history equals the outcome without history
//!      (what decides it is WHICH SCREEN holds the links, not how many rows
//!      the grid keeps). A log that makes freeing conditional on "the rows
//!      holding them [being] actually released" describes a dependency that
//!      never shows up, and must not say it. A condition about reachability
//!      ("only if the links are on the screen being shown") is fine. The check
//!      is gated on the observation: if history size ever starts to matter
//!      again, a release condition becomes legitimate and the test stands
//!      down.
//!
//! Observed matrix (what the child measures; six situations x two remedies):
//!
//! | situation                                   | Cmd-K | erase |
//! |---------------------------------------------|-------|-------|
//! | primary, links in scrollback (history)      | frees | frees |
//! | primary, links in the viewport (no history) | frees | frees |
//! | inactive alt grid, primary without history  | frees | no    |
//! | inactive alt grid, primary with history     | frees | no    |
//! | alt screen up, primary links in the viewport| no    | no    |
//! | alt screen up, primary links in history     | frees | no    |
//!
//! The table is documentation. The tests below MEASURE it and compare the log
//! with what they measured; none of them asserts a cell of it directly, so a
//! build that frees more (or fewer) cases is judged on the wording it prints.
//!
//! How the log is observed: the core writes with `eprintln!`, which the
//! libtest harness would swallow, so the floods run in a re-executed child of
//! this very test binary with `--nocapture`; the parent parses the child's
//! stderr (phase markers `@@PHASE`, results `@@RESULT`).
//!
//! A note on snapshots: a snapshot has its own 1 MiB URI intern cap. A
//! probe's attribution is therefore only read from a snapshot whose viewport
//! holds none or one link. Where the links fill the primary viewport, the
//! "was the budget held" probe is written on the alternate screen (a separate
//! grid, blank after `?1049h`), which shares the per-terminal live budget.
//!
//! Pre-flight cost (memory x time) of the child, a debug build:
//!   - Twelve runs one after the other (6 situations x 2 remedies), each with
//!     its own terminal that is freed before the next starts.
//!   - Primary-history runs: 100 columns x 110 rows of distinct 3.5 KiB links
//!     (11 000 links, ~39 MB of input through one reusable 64 KiB buffer) in a
//!     100 x 24 terminal with 500 lines of scrollback (~100 KiB of cells).
//!   - Viewport / alternate runs: a 120 x 100 terminal, 12 000 distinct
//!     3.5 KiB links, ~43 MB of input; 150 short text lines for the
//!     "with history" variants.
//!   - The link heap a terminal retains is bounded by its own 32 MiB budget
//!     (measured ~34 MiB with grid), plus at most one 1 MiB snapshot intern
//!     table, so the peak is < ~60 MiB; one run takes ~1.3 s, the child ~16 s.
//!   - The in-process tests only run string classifiers on a few hundred
//!     bytes.

use std::collections::BTreeMap;
use std::ffi::CStr;
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
// Link floods and probes
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

/// Size of the wide terminal used by the viewport / alternate situations.
const WIDE_COLS: usize = 120;
const WIDE_ROWS: usize = 100;

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

/// Writes the probe link over the home cell of the screen that is showing.
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

// ---------------------------------------------------------------------------
// Situations and remedies
// ---------------------------------------------------------------------------

/// Which screen holds the links, relative to the screen the remedy runs on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Holder {
    /// The links are in the primary grid and the primary screen is up.
    Primary,
    /// The links are in the alternate grid; a program left the alternate
    /// screen, so the primary screen is up.
    InactiveAlt,
    /// The links are in the primary grid but the alternate screen is up.
    AltUp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Situation {
    /// Primary screen: 110 rows of links pushed into history, viewport blank.
    PrimaryHistory,
    /// Primary screen: links fill the viewport, no history.
    PrimaryViewport,
    /// Alternate grid holds the links; the primary has no history.
    InactiveAltNoHistory,
    /// Alternate grid holds the links; the primary has scrollback history.
    InactiveAltWithHistory,
    /// Alternate screen up; the primary's links fill its viewport.
    AltUpPrimaryViewport,
    /// Alternate screen up; the primary's links sit in its history.
    AltUpPrimaryHistory,
}

const SITUATIONS: [Situation; 6] = [
    Situation::PrimaryHistory,
    Situation::PrimaryViewport,
    Situation::InactiveAltNoHistory,
    Situation::InactiveAltWithHistory,
    Situation::AltUpPrimaryViewport,
    Situation::AltUpPrimaryHistory,
];

/// Pairs that differ only in how much scrollback the grid keeps:
/// `(with history, without history)`.
const HISTORY_PAIRS: [(Situation, Situation); 2] = [
    (Situation::PrimaryHistory, Situation::PrimaryViewport),
    (
        Situation::InactiveAltWithHistory,
        Situation::InactiveAltNoHistory,
    ),
];

impl Situation {
    fn key(self) -> &'static str {
        match self {
            Situation::PrimaryHistory => "primary_history",
            Situation::PrimaryViewport => "primary_viewport",
            Situation::InactiveAltNoHistory => "inactive_alt_no_history",
            Situation::InactiveAltWithHistory => "inactive_alt_with_history",
            Situation::AltUpPrimaryViewport => "alt_up_primary_viewport",
            Situation::AltUpPrimaryHistory => "alt_up_primary_history",
        }
    }

    fn holder(self) -> Holder {
        match self {
            Situation::PrimaryHistory | Situation::PrimaryViewport => Holder::Primary,
            Situation::InactiveAltNoHistory | Situation::InactiveAltWithHistory => {
                Holder::InactiveAlt
            }
            Situation::AltUpPrimaryViewport | Situation::AltUpPrimaryHistory => Holder::AltUp,
        }
    }

    /// Do the links sit in scrollback, as opposed to rows on screen?
    fn links_in_history(self) -> bool {
        matches!(
            self,
            Situation::PrimaryHistory | Situation::AltUpPrimaryHistory
        )
    }

    fn describe(self) -> &'static str {
        match self {
            Situation::PrimaryHistory => {
                "110 rows of distinct links sit in a few hundred lines of primary history, the \
                 viewport is blank"
            }
            Situation::PrimaryViewport => {
                "12 000 distinct links fill the primary viewport, nothing is in history"
            }
            Situation::InactiveAltNoHistory => {
                "the links are held by the inactive alternate grid after a program left the \
                 alternate screen; the primary has no history"
            }
            Situation::InactiveAltWithHistory => {
                "the links are held by the inactive alternate grid after a program left the \
                 alternate screen; the primary has scrollback history"
            }
            Situation::AltUpPrimaryViewport => {
                "the alternate screen is up while the primary viewport holds 12 000 distinct links"
            }
            Situation::AltUpPrimaryHistory => {
                "the alternate screen is up while the primary history holds 110 rows of distinct \
                 links"
            }
        }
    }
}

/// What the user (or a program) does to get the links back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Remedy {
    /// The app's Cmd-K.
    CmdK,
    /// Home, ED 2 (screen), ED 3 (scrollback): the sequence a shell's "clear
    /// and wipe scrollback" emits.
    Erase,
}

const REMEDIES: [Remedy; 2] = [Remedy::CmdK, Remedy::Erase];

impl Remedy {
    fn tag(self) -> &'static str {
        match self {
            Remedy::CmdK => "cmdk",
            Remedy::Erase => "erase",
        }
    }

    fn name(self) -> &'static str {
        match self {
            Remedy::CmdK => "Cmd-K (bb_term_clear_all)",
            Remedy::Erase => "erasing the rows (ESC[H ESC[2J ESC[3J)",
        }
    }

    fn mentions(self) -> fn(&str) -> bool {
        match self {
            Remedy::CmdK => mentions_cmd_k,
            Remedy::Erase => mentions_erase,
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

fn run_name(situation: Situation, remedy: Remedy) -> String {
    format!("{}.{}", situation.key(), remedy.tag())
}

// ---------------------------------------------------------------------------
// The child: drive every situation x remedy, one terminal at a time
// ---------------------------------------------------------------------------

const CHILD_ENV: &str = "BB_OSC8_REFUSAL_LOG_TRUTH_BLIND_CHILD";
const CHILD_ENTRY_TEST: &str = "rig_refusal_log_matrix_runs_and_exhausts_the_budget";

/// Rig precondition for the whole child, in a throwaway terminal: the probe
/// bytes themselves are accepted by a terminal whose budget is untouched.
fn child_canary() {
    let fresh = Term::new(80, 24, 10);
    let got = probe_at_home(&fresh);
    assert!(
        probe_is_accepted(&got),
        "child rig: the 4 KiB probe must be accepted by a fresh terminal, got {got:?}"
    );
}

/// Builds a terminal in `situation` with the live budget exhausted by links
/// held where the situation says, writes the "is the budget held" probe, and
/// returns the terminal and whether that probe was refused.
fn stage(situation: Situation) -> (Term, bool) {
    match situation {
        Situation::PrimaryHistory | Situation::AltUpPrimaryHistory => {
            const COLS: usize = 100;
            const ROWS: usize = 110;
            // Rig sizing: 11 000 x 3.5 KiB = 37.6 MiB of URIs against a 32 MiB
            // budget.
            const _: () = assert!(COLS * ROWS * URI_FLOOD >= 36 * 1024 * 1024);
            let term = Term::new(COLS as u16, 24, 500);
            flood_link_block(&term, ROWS, COLS);
            // Home + ED 2: the linked viewport goes to history, the viewport
            // is blank, so the snapshot below carries at most one link.
            term.feed(b"\x1b[H\x1b[2J");
            {
                let snap = term.snapshot();
                assert!(
                    snap.history() as usize >= ROWS - 10 && (snap.history() as usize) < 400,
                    "child rig: the linked rows must sit in a few hundred lines of history, far \
                     below the ~1000 spare rows a grid keeps; history_size={}",
                    snap.history()
                );
                assert!(
                    snap.is_blank(0, 0),
                    "child rig: the viewport must be blank, cell (0,0)={}",
                    snap.ch(0, 0)
                );
            }
            if situation == Situation::AltUpPrimaryHistory {
                term.feed(b"\x1b[?1049h");
            }
            let before = probe_at_home(&term);
            let refused = probe_is_refused(&before);
            (term, refused)
        }
        Situation::PrimaryViewport | Situation::AltUpPrimaryViewport => {
            // Rig sizing: 12 000 x 3.5 KiB = 41 MiB of URIs against 32 MiB.
            const _: () = assert!(WIDE_COLS * WIDE_ROWS * URI_FLOOD >= 40 * 1024 * 1024);
            let term = Term::new(WIDE_COLS as u16, WIDE_ROWS as u16, 100);
            // 99 CR LF between 100 rows of 120 cells: the flood ends with the
            // cursor in the last cell and never scrolls, so nothing is in
            // history. No snapshot is taken here: with the viewport full of
            // distinct links a snapshot would exhaust the term's URI intern
            // budget, which silently drops attribution for every new link
            // until Cmd-K and would corrupt what the probes measure (the
            // parent rig asserts that no run ever hit that budget).
            flood_link_block(&term, WIDE_ROWS, WIDE_COLS);
            // The viewport is full of links, so the "is the budget held" probe
            // goes onto the (blank) alternate screen: same per-terminal budget,
            // and a snapshot with at most one link.
            term.feed(b"\x1b[?1049h");
            let before = probe_at_home(&term);
            let refused = probe_is_refused(&before);
            if situation == Situation::PrimaryViewport {
                term.feed(b"\x1b[?1049l");
            }
            (term, refused)
        }
        Situation::InactiveAltNoHistory | Situation::InactiveAltWithHistory => {
            const _: () = assert!(WIDE_COLS * WIDE_ROWS * URI_FLOOD >= 40 * 1024 * 1024);
            let term = Term::new(WIDE_COLS as u16, WIDE_ROWS as u16, 100);
            if situation == Situation::InactiveAltWithHistory {
                let mut text = String::new();
                for i in 0..150 {
                    text.push_str(&format!("line {i}\r\n"));
                }
                term.feed(text.as_bytes());
                let history = term.snapshot().history();
                assert!(
                    history > 0,
                    "child rig: 150 lines in a {WIDE_ROWS}-row terminal must leave primary history"
                );
            }
            term.feed(b"\x1b[?1049h\x1b[H");
            flood_link_block(&term, WIDE_ROWS, WIDE_COLS);
            term.feed(b"\x1b[?1049l");
            {
                let snap = term.snapshot();
                let history = snap.history();
                match situation {
                    Situation::InactiveAltWithHistory => assert!(
                        history > 0,
                        "child rig: back on the primary screen it must still have its history"
                    ),
                    _ => assert_eq!(
                        (snap.is_blank(0, 0), history),
                        (true, 0),
                        "child rig: back on the primary screen it must be blank with no history; \
                         cell (0,0)={}",
                        snap.ch(0, 0)
                    ),
                }
            }
            let before = probe_at_home(&term);
            let refused = probe_is_refused(&before);
            (term, refused)
        }
    }
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

fn run_one(situation: Situation, remedy: Remedy) {
    let run = run_name(situation, remedy);
    eprintln!("@@PHASE {run}_BEGIN");
    let (term, exhausted) = stage(situation);
    eprintln!("@@PHASE {run}_REMEDY");
    remedy.apply(&term);
    let wiped = {
        let snap = term.snapshot();
        snap.is_blank(0, 0) && snap.history() == 0
    };
    let frees = probe_is_accepted(&probe_at_home(&term));
    report(&run, exhausted, wiped, frees);
    eprintln!("@@PHASE {run}_END");
}

fn run_child_scenarios() {
    child_canary();
    for situation in SITUATIONS {
        for remedy in REMEDIES {
            run_one(situation, remedy);
        }
    }
    eprintln!("@@PHASE END");
}

// ---------------------------------------------------------------------------
// The parent: parse what the child printed
// ---------------------------------------------------------------------------

/// One run as seen from the parent.
#[derive(Debug, Default)]
struct RunReport {
    /// The probe was refused before the remedy (the budget really was held).
    exhausted: bool,
    /// The remedy blanked the screen and emptied the history.
    wiped: bool,
    /// The probe was accepted after the remedy: the budget really came back.
    frees: bool,
    result_seen: bool,
    /// The snapshot URI intern budget (a different budget) was exhausted
    /// during the run. That silently drops attribution for every new link
    /// until Cmd-K, so a run where it happened measures nothing.
    intern_cap_hit: bool,
    /// Live-budget breadcrumb records logged during the run (a record may
    /// span several stderr lines).
    breadcrumbs: Vec<String>,
}

impl RunReport {
    fn log(&self) -> String {
        self.breadcrumbs.join("\n")
    }
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
    // True while the lines that follow belong to the breadcrumb just read.
    let mut in_record = false;
    for line in stderr.lines() {
        if let Some(name) = line.strip_prefix("@@PHASE ") {
            in_record = false;
            let name = name.trim().to_owned();
            if let Some(run) = name.strip_suffix("_BEGIN") {
                current = Some(run.to_owned());
                runs.entry(run.to_owned()).or_default();
            } else if name.ends_with("_END") || name == "END" {
                current = None;
            }
            phases.push(name);
        } else if let Some(rest) = line.strip_prefix("@@RESULT ") {
            in_record = false;
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
                in_record = true;
            }
        } else if line.starts_with("[blackbird_core]") {
            // Another log record (not the live-budget one).
            in_record = false;
            if line.contains("intern budget") {
                if let Some(run) = &current {
                    runs.entry(run.clone()).or_default().intern_cap_hit = true;
                }
            }
        } else if in_record && !line.trim().is_empty() {
            // Continuation of a multi-line breadcrumb.
            if let Some(run) = &current {
                if let Some(last) = runs.entry(run.clone()).or_default().breadcrumbs.last_mut() {
                    last.push('\n');
                    last.push_str(line.trim());
                }
            }
        } else {
            in_record = false;
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

fn expected_phases() -> Vec<String> {
    let mut v: Vec<String> = Vec::new();
    for situation in SITUATIONS {
        for remedy in REMEDIES {
            let run = run_name(situation, remedy);
            v.push(format!("{run}_BEGIN"));
            v.push(format!("{run}_REMEDY"));
            v.push(format!("{run}_END"));
        }
    }
    v.push("END".to_owned());
    v
}

/// The matrix, after the rig preconditions every behavioural test relies on.
fn matrix() -> &'static ChildReport {
    let r = child_report();
    assert_eq!(
        r.phases,
        expected_phases(),
        "rig precondition: the child must walk every phase; child stderr:\n{}",
        r.stderr
    );
    r
}

fn run_of(r: &'static ChildReport, situation: Situation, remedy: Remedy) -> &'static RunReport {
    let name = run_name(situation, remedy);
    r.runs
        .get(&name)
        .unwrap_or_else(|| panic!("no run named {name}; stderr:\n{}", r.stderr))
}

// ---------------------------------------------------------------------------
// Reading what a log claims (clause level)
// ---------------------------------------------------------------------------

/// One clause of the log that says something about the remedy being judged.
#[derive(Debug, Clone)]
struct Claim {
    /// The clause as logged, trimmed.
    clause: String,
    /// `true`: the remedy gets the links back. `false`: it does not.
    frees: bool,
    /// The measured situations the clause speaks about.
    scope: Vec<Situation>,
}

/// Words of a lower-cased text, apostrophes kept (`doesn't`).
fn words(text: &str) -> Vec<String> {
    text.split(|c: char| !(c.is_alphanumeric() || c == '\''))
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

/// Does this text name either remedy?
fn names_a_remedy(text: &str) -> bool {
    REMEDIES.iter().any(|r| r.mentions()(text))
}

/// Phrases that neither promise nor deny: the clause is a hedge the
/// measurement can neither confirm nor contradict.
const UNCERTAIN_PHRASES: [&str; 5] = [
    "may not",
    "might not",
    "not always",
    "not necessarily",
    "sometimes",
];

/// A negation followed, within four words, by a verb that says the remedy
/// works or does not ("cannot release", "never frees", "does not reach").
fn negates_a_remedy(clause: &str) -> bool {
    const REMEDY_VERBS: [&str; 15] = [
        "free", "frees", "freed", "release", "releases", "released", "reclaim", "restore",
        "restores", "help", "helps", "work", "works", "recover", "reach",
    ];
    let w = words(&clause.to_lowercase());
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

/// Clauses of a sentence: split at `:`, at commas outside parentheses
/// (`(ESC[2J, ESC[3J)` stays whole) and before ` but `. Each claim has to sit
/// in a clause of its own, so that a negation cannot shield a claim next to it.
fn clauses(sentence: &str) -> Vec<String> {
    let mut parts: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut depth = 0usize;
    for c in sentence.chars() {
        match c {
            '(' => {
                depth += 1;
                cur.push(c);
            }
            ')' => {
                depth = depth.saturating_sub(1);
                cur.push(c);
            }
            ':' | ',' if depth == 0 => parts.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    parts.push(cur);
    parts
        .iter()
        .flat_map(|part| part.split(" but "))
        .filter(|clause| !clause.trim().is_empty())
        .map(str::to_owned)
        .collect()
}

/// Words that open a condition.
const CONDITION_MARKERS: [&str; 9] = [
    " if ",
    " unless ",
    " as long as ",
    " provided ",
    " depends on ",
    " depending on ",
    " only when ",
    " only after ",
    " only once ",
];

/// Does this clause make something conditional?
fn is_conditional(clause: &str) -> bool {
    let padded = format!(" {} ", clause.to_lowercase());
    CONDITION_MARKERS.iter().any(|m| padded.contains(m))
}

/// The condition of a clause: the text after its first conditional marker.
fn condition_of(clause: &str) -> Option<String> {
    let padded = format!(" {} ", clause.to_lowercase());
    CONDITION_MARKERS
        .iter()
        .filter_map(|m| padded.find(m).map(|at| at + m.len()))
        .min()
        .map(|at| padded[at..].to_owned())
}

/// The measured situations a clause speaks about, read from its scope words.
/// Each scope word narrows the clause to the situations that fit it (a clause
/// with several speaks about the overlap, which may be empty); a clause with
/// none speaks about every situation.
fn scope_of(clause: &str) -> Vec<Situation> {
    let lower = clause.to_lowercase();
    let has = |needles: &[&str]| -> bool { needles.iter().any(|n| lower.contains(*n)) };
    let mut scope: Vec<Situation> = SITUATIONS.to_vec();
    // The screen the user is looking at is the primary one, except where a
    // program holds the alternate screen.
    if has(&[
        "screen that is showing",
        "screen being shown",
        "showing screen",
        "shown screen",
        "visible screen",
        "current screen",
    ]) {
        scope.retain(|s| s.holder() == Holder::Primary);
    }
    if has(&["other screen", "inactive"]) {
        scope.retain(|s| s.holder() != Holder::Primary);
    }
    if has(&[
        "alternate screen is up",
        "alt screen is up",
        "while the alternate screen",
        "while the alt screen",
    ]) {
        scope.retain(|s| s.holder() == Holder::AltUp);
    }
    if has(&["visible rows", "viewport"]) {
        scope.retain(|s| !s.links_in_history());
    }
    scope
}

/// Every clause of `log` that makes a claim about `remedy`, each judged on its
/// own: a negation in a neighbouring clause of the same sentence neither
/// shields nor retracts it. A clause that names no remedy ("but it does not
/// reach the visible rows ...") speaks for the remedy named before it in the
/// sentence, and only when it qualifies it.
fn claims_about(log: &str, remedy: Remedy) -> Vec<Claim> {
    let mut claims: Vec<Claim> = Vec::new();
    for sentence in sentences(log) {
        let mut about_remedy = false;
        for clause in clauses(sentence) {
            let names_any = names_a_remedy(&clause);
            if names_any {
                about_remedy = remedy.mentions()(&clause);
            }
            let negated = negates_a_remedy(&clause);
            let conditional = is_conditional(&clause);
            if !about_remedy || !(names_any || negated || conditional) {
                continue;
            }
            let lower = clause.to_lowercase();
            if UNCERTAIN_PHRASES.iter().any(|p| lower.contains(p)) {
                continue;
            }
            let scope = scope_of(&clause);
            // A condition with no scope the test can read ("only if the rows
            // are released") promises nothing it could be held to. The stale
            // release condition has its own test.
            if conditional && !negated && scope.len() == SITUATIONS.len() {
                continue;
            }
            claims.push(Claim {
                clause: clause.trim().to_owned(),
                frees: !negated,
                scope,
            });
        }
    }
    claims
}

/// What `claims` say happens in `situation`: `Some(frees)`, `None` when no
/// clause speaks about it, an error when equally specific clauses disagree.
/// The narrowest clause wins: "frees the other screen's links, but does not
/// reach the visible rows while the alternate screen is up" carves one case
/// out of the broader claim; a negation elsewhere never cancels a claim that
/// is not about the same case.
fn claimed(claims: &[Claim], situation: Situation) -> Result<Option<bool>, String> {
    let covering: Vec<&Claim> = claims
        .iter()
        .filter(|c| c.scope.contains(&situation))
        .collect();
    let Some(narrowest) = covering.iter().map(|c| c.scope.len()).min() else {
        return Ok(None);
    };
    let decisive: Vec<&Claim> = covering
        .into_iter()
        .filter(|c| c.scope.len() == narrowest)
        .collect();
    let first = decisive[0].frees;
    if decisive.iter().all(|c| c.frees == first) {
        Ok(Some(first))
    } else {
        Err(format!(
            "the log both says and denies it, in {:?}",
            decisive
                .iter()
                .map(|c| c.clause.as_str())
                .collect::<Vec<_>>()
        ))
    }
}

/// The verdict of the direct comparison: `Some(message)` when a clause of
/// `log` claims something about `remedy` that the measured `runs`
/// contradict: it says the remedy frees the links where the probe link stayed
/// refused, or that it does not where the probe link was accepted. A claim
/// that cannot be tied to any measured situation, or that the log makes and
/// retracts in equally specific words, is reported too.
fn claim_violation(log: &str, remedy: Remedy, runs: &[(Situation, bool)]) -> Option<String> {
    let claims = claims_about(log, remedy);
    let mut found: Vec<String> = Vec::new();
    for claim in claims.iter().filter(|c| c.scope.is_empty()) {
        found.push(format!(
            "the clause {:?} narrows to no measured situation, so it cannot be checked",
            claim.clause
        ));
    }
    for &(situation, frees) in runs {
        match claimed(&claims, situation) {
            Ok(Some(said)) if said != frees => {
                let spoken: Vec<&str> = claims
                    .iter()
                    .filter(|c| c.scope.contains(&situation))
                    .map(|c| c.clause.as_str())
                    .collect();
                found.push(format!(
                    "[{}] the log says {} {} here, but the budget {} (clauses: {spoken:?})",
                    situation.key(),
                    remedy.name(),
                    if said {
                        "frees the links"
                    } else {
                        "does not free them"
                    },
                    if frees {
                        "DID come back"
                    } else {
                        "did NOT come back"
                    },
                ));
            }
            Ok(_) => {}
            Err(why) => found.push(format!("[{}] {why}", situation.key())),
        }
    }
    if found.is_empty() {
        None
    } else {
        Some(found.join("; "))
    }
}

/// What a log claims about `remedy` in each situation, in `SITUATIONS` order,
/// one character each: `F` frees, `N` does not, `-` silent, `!` contradicts
/// itself.
fn claim_row(log: &str, remedy: Remedy) -> String {
    let claims = claims_about(log, remedy);
    SITUATIONS
        .iter()
        .map(|&s| match claimed(&claims, s) {
            Ok(Some(true)) => 'F',
            Ok(Some(false)) => 'N',
            Ok(None) => '-',
            Err(_) => '!',
        })
        .collect()
}

/// Vocabulary of a condition about the row storage being released.
const RELEASE_STEMS: [&str; 5] = ["releas", "reclaim", "dealloc", "truncat", "freed"];

/// Clauses of `log` that make something conditional on rows being released
/// ("... frees them only if the rows holding them are actually released").
fn stale_release_conditions(log: &str) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    for sentence in sentences(log) {
        for clause in clauses(sentence) {
            if let Some(cond) = condition_of(&clause) {
                if RELEASE_STEMS.iter().any(|s| cond.contains(s)) {
                    found.push(clause.trim().to_owned());
                }
            }
        }
    }
    found
}

// ---------------------------------------------------------------------------
// Rig tests: the claim reader and the judge can say no
// ---------------------------------------------------------------------------

/// The refusal log as the core printed it before OSC8-d was fixed.
const STALE_LOG: &str = "[blackbird_core] OSC 8 hyperlink live-byte budget exhausted \u{2014} new \
    hyperlinks are refused (printed without a link) until the cells holding links are \
    overwritten or scroll out of the retained scrollback. Erasing the screen frees them only if \
    the rows holding them are actually released: a plain erase (ESC[2J, ESC[3J) does not reach \
    the other screen's rows, and \u{2318}K (bb_term_clear_all) does not reach the shell's \
    visible rows while the alternate screen is up. Symptom: 'links stopped working'. One-shot \
    per session.";

/// The wording the core prints now. A copy: the live-log test below fails when
/// the claims the core's log makes drift away from this one, so the rig keeps
/// judging what ships. Each remedy sentence pairs a claim that it frees with a
/// claim that it does not reach, after a ", but" -- the shape that let one
/// negation shield every claim in the sentence.
const SHIPPED_LOG: &str = "[blackbird_core] OSC 8 hyperlink live-byte budget exhausted \u{2014} \
    new hyperlinks are refused (printed without a link) until the cells holding links are \
    overwritten or scroll out of the retained scrollback. Erasing the screen and then its \
    scrollback (ESC[2J, ESC[3J) frees the links held by the screen that is showing, but a plain \
    erase does not reach the other screen's rows; \u{2318}K (bb_term_clear_all) also frees the \
    other screen's links, but it does not reach the shell's visible rows while the alternate \
    screen is up. Symptom: 'links stopped working'. One-shot per session.";

/// The wording the very first OSC8-c test run pinned as "unconditional".
const OVERPROMISING_LOG: &str = "[blackbird_core] OSC 8 hyperlink live-byte budget exhausted \
    \u{2014} new hyperlinks are refused (printed without a link) until the rows holding links \
    are erased (\u{2318}K, bb_term_clear_all) or have scrolled out of scrollback. Symptom: \
    'links stopped working'. One-shot per session.";

/// What the build frees today (the table in the module docs): per situation,
/// whether the probe link was accepted after Cmd-K / after the erase.
const MEASURED_CMD_K: [(Situation, bool); 6] = [
    (Situation::PrimaryHistory, true),
    (Situation::PrimaryViewport, true),
    (Situation::InactiveAltNoHistory, true),
    (Situation::InactiveAltWithHistory, true),
    (Situation::AltUpPrimaryViewport, false),
    (Situation::AltUpPrimaryHistory, true),
];
const MEASURED_ERASE: [(Situation, bool); 6] = [
    (Situation::PrimaryHistory, true),
    (Situation::PrimaryViewport, true),
    (Situation::InactiveAltNoHistory, false),
    (Situation::InactiveAltWithHistory, false),
    (Situation::AltUpPrimaryViewport, false),
    (Situation::AltUpPrimaryHistory, false),
];

/// `table` with the outcome of `cells` set to `frees`.
fn with_outcome(
    table: &[(Situation, bool)],
    cells: &[Situation],
    frees: bool,
) -> Vec<(Situation, bool)> {
    table
        .iter()
        .map(|&(s, was)| (s, if cells.contains(&s) { frees } else { was }))
        .collect()
}

/// Rig for the claim reader: pinned on texts whose claims are known. The
/// decisive cases are the ones where a claim sits next to a negation in the
/// same sentence: reading the sentence as one hedge (the old behaviour) hid
/// the claim from the comparison.
#[test]
fn rig_claim_reader_pins_its_verdicts() {
    // Rows are in SITUATIONS order: primary_history, primary_viewport,
    // inactive_alt_no_history, inactive_alt_with_history,
    // alt_up_primary_viewport, alt_up_primary_history.
    // (text, row for Cmd-K, row for erasing)
    let cases: [(&str, &str, &str); 18] = [
        (OVERPROMISING_LOG, "FFFFFF", "FFFFFF"),
        (STALE_LOG, "----N-", "--NNNN"),
        // The wording as shipped: a claim and its negation in one sentence.
        (SHIPPED_LOG, "--FFNF", "FFNNNN"),
        // The same wording with "or": one clause names both remedies.
        (
            "OSC 8 hyperlink budget exhausted. Erasing the screen (ESC[2J, ESC[3J) or \u{2318}K \
             (bb_term_clear_all) frees the links held by the screen that is showing, but a plain \
             erase does not reach the other screen's rows, and \u{2318}K does not reach the \
             shell's visible rows while the alternate screen is up.",
            "FF--N-",
            "FFNNNN",
        ),
        // A hedge in a sentence about something else must not shield a claim.
        (
            "OSC 8 hyperlink budget exhausted. Links come back only if their cells are \
             overwritten. Press Cmd-K to free them.",
            "FFFFFF",
            "------",
        ),
        (
            "OSC 8 hyperlink budget exhausted. Erasing does not free links held by the other \
             screen. Cmd-K frees them.",
            "FFFFFF",
            "--NNNN",
        ),
        (
            "OSC 8 hyperlink budget exhausted; links are freed when their cells scroll out of \
             the retained scrollback or are overwritten",
            "------",
            "------",
        ),
        (
            "OSC 8 hyperlink budget exhausted; new links will not be attributed until \u{2318}K",
            "FFFFFF",
            "------",
        ),
        // A condition the reader can place narrows the claim to it.
        (
            "OSC 8 hyperlink budget exhausted; Cmd-K frees them only if they are on the screen \
             that is showing",
            "FF----",
            "------",
        ),
        (
            "OSC 8 hyperlink budget exhausted; \u{2318}K cannot release them",
            "NNNNNN",
            "------",
        ),
        // Two sentences about one remedy: the narrower negation carves a case
        // out of the broader claim, in the other sentence.
        (
            "OSC 8 hyperlink budget exhausted. Cmd-K frees them. Cmd-K does not reach the \
             visible rows while the alternate screen is up.",
            "FFFFNF",
            "------",
        ),
        // The same carve-out, joined by "but" without a comma.
        (
            "OSC 8 hyperlink budget exhausted; Cmd-K frees the other screen's links but does not \
             reach the shell's visible rows while the alternate screen is up",
            "--FFNF",
            "------",
        ),
        // "but it ..." belongs to the remedy before it, not to the other one.
        (
            "OSC 8 hyperlink budget exhausted; a plain erase frees the screen that is showing, \
             but it does not reach the other screen's rows. Cmd-K frees them.",
            "FFFFFF",
            "FFNNNN",
        ),
        (
            "OSC 8 hyperlink budget exhausted; erase the rows to get links back",
            "------",
            "FFFFFF",
        ),
        // Uncertain wording neither promises nor denies.
        (
            "OSC 8 hyperlink budget exhausted; a plain erase may not reach the other screen",
            "------",
            "------",
        ),
        // An unscoped condition promises nothing the measurement could test.
        (
            "OSC 8 hyperlink budget exhausted; Cmd-K frees them only if the stars align",
            "------",
            "------",
        ),
        // Equally specific words that say and deny the same thing.
        (
            "OSC 8 hyperlink budget exhausted. Cmd-K frees them. Cmd-K cannot release them.",
            "!!!!!!",
            "------",
        ),
        ("", "------", "------"),
    ];
    for (text, want_cmd_k, want_erase) in cases {
        assert_eq!(
            claim_row(text, Remedy::CmdK),
            want_cmd_k,
            "Cmd-K claims for {text:?}"
        );
        assert_eq!(
            claim_row(text, Remedy::Erase),
            want_erase,
            "erase claims for {text:?}"
        );
    }
}

/// Rig for the stale-condition detector: a condition about the rows being
/// released is flagged, a condition about reachability is not.
#[test]
fn rig_stale_release_condition_detector_pins_its_verdicts() {
    let flagged: [&str; 5] = [
        STALE_LOG,
        "Erasing the screen frees them only if the rows holding them are released",
        "Cmd-K frees the links unless the grid keeps the rows (they are reclaimed later)",
        "If the rows are released, the links are freed",
        "Links are credited back as long as the history rows are truncated",
    ];
    for text in flagged {
        assert_eq!(
            stale_release_conditions(text).len(),
            1,
            "a release condition must be flagged in {text:?}; got {:?}",
            stale_release_conditions(text)
        );
    }
    let clean: [&str; 6] = [
        SHIPPED_LOG,
        OVERPROMISING_LOG,
        "Erasing the screen frees them only if they are held by the screen that is showing",
        "Cmd-K does not reach the shell's visible rows while the alternate screen is up",
        "Links are freed when the cells scroll out of the retained scrollback or are overwritten",
        "Cmd-K and ESC[3J release the history rows at once, so the links are freed; a plain \
         erase does not reach the other screen's rows",
    ];
    for text in clean {
        assert_eq!(
            stale_release_conditions(text),
            Vec::<String>::new(),
            "no release condition may be flagged in {text:?}"
        );
    }
}

/// Rig for the judge: it reports a violation exactly when a clause claims
/// something the measurement contradicts, and a claim sitting next to a
/// negation, in the same sentence or another, is judged like any other.
#[test]
fn rig_claim_judge_can_fail() {
    let tables: [(Remedy, &[(Situation, bool)]); 2] = [
        (Remedy::CmdK, &MEASURED_CMD_K),
        (Remedy::Erase, &MEASURED_ERASE),
    ];

    // The wording the core prints agrees with the table it describes.
    for (remedy, table) in tables {
        assert_eq!(
            claim_violation(SHIPPED_LOG, remedy, table),
            None,
            "the shipped wording must agree with the table in the module docs for {}",
            remedy.name()
        );
    }

    // Reverse any one measured outcome and the shipped wording is caught,
    // naming the situation and the remedy. Cmd-K is silent about the two
    // primary-screen situations ("also frees the other screen's links"), so
    // nothing there can contradict it.
    for (remedy, table) in tables {
        for &(situation, frees) in table {
            let silent = remedy == Remedy::CmdK
                && matches!(
                    situation,
                    Situation::PrimaryHistory | Situation::PrimaryViewport
                );
            let verdict = claim_violation(
                SHIPPED_LOG,
                remedy,
                &with_outcome(table, &[situation], !frees),
            );
            if silent {
                assert_eq!(
                    verdict,
                    None,
                    "the shipped wording says nothing about {} in {}",
                    remedy.name(),
                    situation.key()
                );
            } else {
                assert_eq!(
                    verdict
                        .as_deref()
                        .map(|m| m.contains(situation.key()) && m.contains(remedy.name())),
                    Some(true),
                    "reversing {} in {} must contradict the shipped wording; got {verdict:?}",
                    remedy.name(),
                    situation.key()
                );
            }
        }
    }

    // The two regressions the sentence-level judge let through. Dropping
    // `clear_inactive_grid` from bb_term_clear_all: Cmd-K stops freeing what
    // the inactive alternate grid holds, yet the log still says it does.
    let no_inactive_clear = with_outcome(
        &MEASURED_CMD_K,
        &[
            Situation::InactiveAltNoHistory,
            Situation::InactiveAltWithHistory,
        ],
        false,
    );
    let v = claim_violation(SHIPPED_LOG, Remedy::CmdK, &no_inactive_clear);
    assert_eq!(
        v.as_deref()
            .map(|m| m.contains("inactive_alt_no_history")
                && m.contains("inactive_alt_with_history")),
        Some(true),
        "Cmd-K no longer freeing the inactive alternate grid must contradict the log; got {v:?}"
    );
    // Reverting the truncate in Grid::clear_history: an erase stops freeing
    // the screen that is showing, yet the log still says it does.
    let no_truncate = with_outcome(
        &MEASURED_ERASE,
        &[Situation::PrimaryHistory, Situation::PrimaryViewport],
        false,
    );
    let v = claim_violation(SHIPPED_LOG, Remedy::Erase, &no_truncate);
    assert_eq!(
        v.as_deref()
            .map(|m| m.contains("primary_history") && m.contains("primary_viewport")),
        Some(true),
        "an erase no longer freeing the screen that is showing must contradict the log; got {v:?}"
    );

    // A flat promise, a measured failure: violation, naming the failing run.
    let v = claim_violation(OVERPROMISING_LOG, Remedy::CmdK, &MEASURED_CMD_K);
    assert_eq!(
        v.as_deref()
            .map(|m| m.contains("alt_up_primary_viewport") && m.contains("Cmd-K")),
        Some(true),
        "an unconditional Cmd-K promise must be reported, naming the run where the budget did \
         not come back; got {v:?}"
    );
    // The same promise, the budget came back everywhere: no violation.
    let all_free = with_outcome(&MEASURED_CMD_K, &[Situation::AltUpPrimaryViewport], true);
    assert_eq!(
        claim_violation(OVERPROMISING_LOG, Remedy::CmdK, &all_free),
        None,
        "a promise that the measurement confirms must stand"
    );
    // The remedy is not named: nothing to hold against the log.
    assert_eq!(
        claim_violation(
            "OSC 8 hyperlink budget exhausted; links return when their cells are overwritten",
            Remedy::CmdK,
            &MEASURED_CMD_K
        ),
        None
    );
    // A hedge in a sentence about something else (here: when plain cells come
    // back) must NOT shield a false promise.
    let shielded = "OSC 8 hyperlink budget exhausted. Links come back only if their cells are \
                    overwritten. Press Cmd-K to free them.";
    let v = claim_violation(shielded, Remedy::CmdK, &MEASURED_CMD_K);
    assert_eq!(
        v.as_deref().map(|m| m.contains("alt_up_primary_viewport")),
        Some(true),
        "a hedge in an unrelated sentence must not turn a false Cmd-K promise into a pass; \
         got {v:?}"
    );
    // Erasing is judged on its own clauses, not on the Cmd-K ones.
    let v = claim_violation(
        "OSC 8 hyperlink budget exhausted; erase the screen to get links back. Cmd-K does \
         not reach the primary rows while the alternate screen is up.",
        Remedy::Erase,
        &MEASURED_ERASE,
    );
    assert_eq!(
        v.as_deref().map(|m| m.contains("inactive_alt_no_history")),
        Some(true),
        "a negation about Cmd-K must not shield an unconditional promise about erasing; got {v:?}"
    );
    // A denial the measurement contradicts is caught too: the log is stale in
    // the other direction.
    let v = claim_violation(
        "OSC 8 hyperlink budget exhausted; \u{2318}K does not reach the other screen's rows",
        Remedy::CmdK,
        &MEASURED_CMD_K,
    );
    assert_eq!(
        v.as_deref()
            .map(|m| m.contains("alt_up_primary_history") && m.contains("does not free")),
        Some(true),
        "a denial the measurement contradicts must be reported; got {v:?}"
    );
    // The pre-fix wording makes no claim the measurements contradict; its
    // fault is the stale release condition, which has its own test.
    for (remedy, table) in tables {
        assert_eq!(
            claim_violation(STALE_LOG, remedy, table),
            None,
            "the pre-fix wording's claims are true; only its release condition is stale"
        );
    }
    // Equally specific words that say and deny the same thing are reported.
    let v = claim_violation(
        "OSC 8 hyperlink budget exhausted. Cmd-K frees them. Cmd-K cannot release them.",
        Remedy::CmdK,
        &MEASURED_CMD_K,
    );
    assert_eq!(
        v.as_deref()
            .map(|m| m.contains("primary_history") && m.contains("both says and denies")),
        Some(true),
        "a log that says and denies the same thing must be reported; got {v:?}"
    );
    // One clause whose scope words contradict each other cannot be checked.
    let v = claim_violation(
        "OSC 8 hyperlink budget exhausted; Cmd-K frees the links of the screen that is showing \
         and does not reach the other screen's rows",
        Remedy::CmdK,
        &MEASURED_CMD_K,
    );
    assert_eq!(
        v.as_deref().map(|m| m.contains("cannot be checked")),
        Some(true),
        "a clause that narrows to no measured situation must be reported; got {v:?}"
    );
}

// ---------------------------------------------------------------------------
// Behavioural tests: the real core, the real log
// ---------------------------------------------------------------------------

/// The child entry point and, in the parent, the rig preconditions every
/// behavioural test below relies on: each of the twelve runs exhausted the
/// live budget (so "the budget came back" means something), blanked the
/// screen it ran on, and left a breadcrumb to judge.
#[test]
fn rig_refusal_log_matrix_runs_and_exhausts_the_budget() {
    if matches!(std::env::var(CHILD_ENV).as_deref(), Ok("1")) {
        run_child_scenarios();
        return;
    }
    let r = matrix();
    for situation in SITUATIONS {
        for remedy in REMEDIES {
            let name = run_name(situation, remedy);
            let s = run_of(r, situation, remedy);
            assert!(
                s.result_seen,
                "no @@RESULT line for {name}; stderr:\n{}",
                r.stderr
            );
            assert!(
                s.exhausted,
                "{name}: with {} the 4 KiB probe must be refused before the remedy (the live \
                 budget is held), otherwise \"the budget came back\" proves nothing; {s:?}",
                situation.describe()
            );
            assert!(
                !s.intern_cap_hit,
                "{name}: the snapshot URI intern budget was exhausted during the run, which drops \
                 attribution for every new link and makes the probes unreliable; {s:?}"
            );
            assert!(
                s.wiped,
                "{name}: the remedy must blank the screen it ran on and empty its history (it is \
                 the action under test); {s:?}"
            );
            assert!(
                !s.breadcrumbs.is_empty(),
                "{name}: exhausting the live budget with ~40 MB of distinct 3.5 KiB links must \
                 leave a breadcrumb that names OSC 8 and the exhausted budget/limit; stderr:\n{}",
                r.stderr
            );
        }
    }
}

/// Compares the log of every run in `holder`'s situations with what the
/// remedy really did there.
fn assert_log_matches_observation(remedy: Remedy, holder: Holder) {
    let r = matrix();
    let mut violations: Vec<String> = Vec::new();
    for situation in SITUATIONS.iter().copied().filter(|s| s.holder() == holder) {
        let run = run_of(r, situation, remedy);
        assert!(
            !run.breadcrumbs.is_empty(),
            "{}: no live-budget breadcrumb was logged, so there is no text to judge; stderr:\n{}",
            run_name(situation, remedy),
            r.stderr
        );
        assert!(
            run.exhausted,
            "{}: the budget must be held before the remedy for the comparison to mean anything",
            run_name(situation, remedy)
        );
        let log = run.log();
        if let Some(v) = claim_violation(&log, remedy, &[(situation, run.frees)]) {
            violations.push(format!(
                "{v}; situation: {}; logged text: {log:?}",
                situation.describe()
            ));
        }
    }
    assert_eq!(
        violations,
        Vec::<String>::new(),
        "A clause of the OSC 8 live-budget refusal log makes a claim about {} that the \
         measurement contradicts: it says the action frees the hyperlink budget where the probe \
         link stayed refused, or that it does not where the probe link was accepted. A \
         maintainer told the wrong thing is misled. State only what is true, or make the action \
         do what the log says",
        remedy.name()
    );
}

#[test]
fn refusal_log_cmd_k_promise_holds_for_links_in_the_primary_grid() {
    assert_log_matches_observation(Remedy::CmdK, Holder::Primary);
}

#[test]
fn refusal_log_cmd_k_promise_holds_for_links_held_by_the_inactive_alt_grid() {
    assert_log_matches_observation(Remedy::CmdK, Holder::InactiveAlt);
}

#[test]
fn refusal_log_cmd_k_promise_holds_while_the_alternate_screen_is_up() {
    assert_log_matches_observation(Remedy::CmdK, Holder::AltUp);
}

#[test]
fn refusal_log_erase_promise_holds_for_links_in_the_primary_grid() {
    assert_log_matches_observation(Remedy::Erase, Holder::Primary);
}

/// Erasing from the primary screen cannot free links the inactive alternate
/// grid holds, so a log that says erasing the rows frees them is false.
#[test]
fn refusal_log_erase_promise_holds_for_links_held_by_the_inactive_alt_grid() {
    assert_log_matches_observation(Remedy::Erase, Holder::InactiveAlt);
}

#[test]
fn refusal_log_erase_promise_holds_while_the_alternate_screen_is_up() {
    assert_log_matches_observation(Remedy::Erase, Holder::AltUp);
}

/// The comparison above only bites if the live log's claims are readable: a
/// log that names a remedy but whose clauses the reader cannot place would
/// pass it vacuously. So every remedy the log names must yield at least one
/// claim that ties to the measured situations, and the claims must still be
/// the ones the rig fixture (`SHIPPED_LOG`) is judged on, which keeps
/// `rig_claim_judge_can_fail` a test of the wording that ships.
#[test]
fn refusal_log_claims_are_readable_and_match_the_rig_fixture() {
    let r = matrix();
    let mut logs: Vec<String> = Vec::new();
    for situation in SITUATIONS {
        for remedy in REMEDIES {
            let log = run_of(r, situation, remedy).log();
            if !logs.contains(&log) {
                logs.push(log);
            }
        }
    }
    assert!(
        !logs.is_empty() && logs.iter().all(|l| !l.is_empty()),
        "rig: every run must have logged a breadcrumb; stderr:\n{}",
        r.stderr
    );
    let mut problems: Vec<String> = Vec::new();
    for log in &logs {
        for remedy in REMEDIES {
            let named = sentences(log).into_iter().any(remedy.mentions());
            if named && claims_about(log, remedy).is_empty() {
                problems.push(format!(
                    "the log names {} but no clause of it makes a claim the measurements can \
                     check (an unscoped condition, or wording the reader cannot place); logged \
                     text: {log:?}",
                    remedy.name()
                ));
            }
            if let Some(unplaceable) = claim_violation(log, remedy, &[]) {
                problems.push(unplaceable);
            }
            let (live, fixture) = (claim_row(log, remedy), claim_row(SHIPPED_LOG, remedy));
            if live != fixture {
                problems.push(format!(
                    "the claims the log makes about {} are {live:?} but the rig fixture \
                     SHIPPED_LOG makes {fixture:?}; update SHIPPED_LOG (and the table in \
                     rig_claim_judge_can_fail) to the wording the core prints; logged text: \
                     {log:?}",
                    remedy.name()
                ));
            }
        }
    }
    assert_eq!(problems, Vec::<String>::new());
}

/// `Grid::clear_history` truncates: erasing or Cmd-K frees the links of every
/// row they reach at once, with or without history. The log must not tell a
/// maintainer that freeing depends on the rows being "actually released".
/// That condition was true once (rows lingered until the grid dropped its
/// spare rows); the measurement below shows it is not exercised any more.
#[test]
fn refusal_log_names_no_row_release_condition_that_history_size_never_exercises() {
    let r = matrix();

    // The observation: does keeping history ever change whether the remedy
    // frees the budget?
    let mut table: Vec<String> = Vec::new();
    let mut history_matters = false;
    for remedy in REMEDIES {
        for (with_history, without_history) in HISTORY_PAIRS {
            let a = run_of(r, with_history, remedy).frees;
            let b = run_of(r, without_history, remedy).frees;
            table.push(format!(
                "{}: {} -> frees={a}; {} -> frees={b}",
                remedy.tag(),
                with_history.key(),
                without_history.key()
            ));
            history_matters |= a != b;
        }
    }
    if history_matters {
        // Whether the rows are kept makes a difference again, so a release
        // condition is a legitimate thing to say. Nothing to hold against it.
        return;
    }

    // Every distinct text the core logged, with the clauses that make
    // something conditional on rows being released.
    let mut logs: Vec<String> = Vec::new();
    for situation in SITUATIONS {
        for remedy in REMEDIES {
            let log = run_of(r, situation, remedy).log();
            if !logs.contains(&log) {
                logs.push(log);
            }
        }
    }
    assert!(
        !logs.is_empty() && logs.iter().all(|l| !l.is_empty()),
        "rig: every run must have logged a breadcrumb; stderr:\n{}",
        r.stderr
    );
    let mut stale: Vec<String> = logs
        .iter()
        .flat_map(|log| stale_release_conditions(log))
        .collect();
    stale.sort();
    stale.dedup();
    assert_eq!(
        stale,
        Vec::<String>::new(),
        "The OSC 8 live-budget refusal log makes freeing conditional on the rows being released, \
         but the measurement shows release is not a factor: the outcome is the same with and \
         without history for both remedies ({table:?}). Grid::clear_history truncates, so ESC[3J \
         and Cmd-K release the rows they reach at once; what decides the outcome is WHICH \
         SCREEN holds the links (a plain erase does not reach the other screen, Cmd-K does not \
         reach the primary's visible rows while the alternate screen is up). Say that instead. \
         Logged texts: {logs:?}"
    );
}
