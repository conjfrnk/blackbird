//! Blind regression tests for bug VTRO-c: the colour-query reply DoS bounds
//! (`ColorRequestQueue` cap = 256, per-second reply gate) are documented
//! wrongly, and the synchronized-update case is not pinned by any test.
//!
//! Author had no access to the implementation bodies. Consulted: the FFI
//! declarations and doc comments in `core/src/lib.rs`, the sibling suites
//! (`color_query.rs`, `color_query_chunk_order_blind.rs`,
//! `sync_output.rs`, `sync_update_timeout.rs`,
//! `pty_write_token_bucket_blind.rs`) and the child-process stderr pattern of
//! `osc8_live_budget_blind.rs`.
//!
//! ## The contract
//!
//! 1. The queue cap bounds ONE DRAIN INTERVAL. Outside a DEC 2026
//!    synchronized update the core drains after every ESC-delimited segment,
//!    so a flood of separate queries never queues more than a handful of
//!    entries: there the cap is only a backstop. INSIDE a synchronized
//!    update vte withholds every byte until ESU and replays the whole
//!    buffered region in one go, so the whole replayed buffer is ONE drain
//!    interval and the 256 cap is the live bound on it. Excess queries are
//!    dropped with a single, rate-limited breadcrumb (never one per query).
//! 2. The per-second colour-reply gate is a TUMBLING window (it resets
//!    wholesale when the second rolls over), not a sliding one, and it is not
//!    silent: the first drop in each window leaves a log line.
//! 3. The doc comments in `lib.rs`, `rate_limit.rs`, `input.rs` and
//!    `callback.rs` must say so, instead of claiming a drain interval is
//!    always one ESC-delimited segment and that the gate is a silent
//!    sliding-window.
//!
//! ## What is tested
//!
//! * Behaviour (pins the contract so the docs cannot drift from reality):
//!   `bb_term_input` BSU + 300 OSC 11 queries + ESU is answered with at most
//!   256 replies, and fewer than 300; the bytes really were buffered until
//!   ESU (`bb_term_sync_status` + zero replies before ESU); in a re-executed
//!   child process the core's stderr carries exactly one queue-cap
//!   breadcrumb for the dropped remainder of a 300- and a 1000-query
//!   replay, and none when the same flood is not inside a synchronized update
//!   (or stays below the cap); the gate leaves a breadcrumb; the gate
//!   tumbles (a full fresh allowance when the window rolls).
//! * Documentation (the part that fails until the docs are fixed): the
//!   COMMENTS (never the code) around the cap and the gate are read from
//!   `core/src/*.rs` and checked for the corrected statements.
//!
//! ## Cost (CLAUDE.md test-authoring rule)
//!
//! Every terminal is 80x24 with 100 lines of scrollback (~2 K cells, well
//! under a MiB; vte's 2 MiB sync buffer is the dominant per-terminal cost and
//! at most one terminal is alive at a time per thread). The largest input is
//! 1 000 queries x 7 B = 7 KB. Wall clock: one 1.1 s sleep in the tumbling
//! test (retried up to 3 times only if the machine stalls), one child process
//! of a few milliseconds. The tests that touch terminals hold a process-wide
//! lock so a loaded machine cannot stretch vte's 150 ms sync deadline by
//! scheduling two sync-heavy tests against each other.

use blackbird_core::*;
use std::ffi::c_void;
use std::process::Command;
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// DEC 2026 begin / end synchronized update.
const BSU: &[u8] = b"\x1b[?2026h";
const ESU: &[u8] = b"\x1b[?2026l";
/// One OSC 11 background-colour query, BEL terminated: exactly one ESC, so
/// exactly one ESC-delimited segment.
const QUERY: &[u8] = b"\x1b]11;?\x07";
/// The documented `ColorRequestQueue` cap.
const DOCUMENTED_QUEUE_CAP: usize = 256;
/// The flood size from the bug report: more than the cap, so the cap is hit.
const FLOOD: usize = 300;

static SERIAL: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Default)]
struct Sink {
    replies: Mutex<Vec<Vec<u8>>>,
}

unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    if ev.kind as u32 != BBEventKind::PtyWrite as u32 {
        return;
    }
    let sink = &*(ctx as *const Sink);
    let bytes = if ev.len > 0 && !ev.payload.is_null() {
        std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
    } else {
        Vec::new()
    };
    sink.replies.lock().unwrap().push(bytes);
}

/// An 80x24 terminal with colour-query replies opted in, counting every
/// `PtyWrite` event.
struct Rig {
    term: *mut BBTerm,
    // Boxed so the address handed to the C callback stays stable.
    sink: Box<Sink>,
}

impl Rig {
    fn new() -> Rig {
        let sink = Box::new(Sink::default());
        let term = unsafe { bb_term_new(80, 24, 100) };
        assert_ne!(term as usize, 0, "bb_term_new(80,24,100) returned null");
        unsafe {
            bb_term_set_event_cb(term, Some(cb), &*sink as *const Sink as *mut c_void);
            bb_term_set_color_query_enabled(term, 1);
        }
        Rig { term, sink }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    fn reply_count(&self) -> usize {
        self.sink.replies.lock().unwrap().len()
    }

    fn replies(&self) -> Vec<Vec<u8>> {
        self.sink.replies.lock().unwrap().clone()
    }

    fn clear_replies(&self) {
        self.sink.replies.lock().unwrap().clear();
    }

    fn sync(&self) -> BBSyncStatus {
        unsafe { bb_term_sync_status(self.term) }
    }

    /// Rig precondition: a lone query outside any synchronized update is
    /// answered exactly once with a well-formed OSC 11 reply. Clears the
    /// recorded replies afterwards.
    fn assert_answers_a_lone_query(&self) {
        self.feed(QUERY);
        let got = self.replies();
        assert_eq!(
            got.len(),
            1,
            "rig precondition: a lone OSC 11 query must produce exactly one reply, got {got:?}"
        );
        assert_eq!(
            malformed_replies(&got),
            Vec::<String>::new(),
            "rig precondition: the lone reply must be a well-formed OSC 11 reply"
        );
        self.clear_replies();
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        unsafe { bb_term_free(self.term) };
    }
}

/// Every reply must be `ESC ] 11 ; rgb:... (BEL | ST)`; returns the ones
/// that are not, rendered for the failure message.
fn malformed_replies(replies: &[Vec<u8>]) -> Vec<String> {
    replies
        .iter()
        .filter(|r| {
            let s = String::from_utf8_lossy(r);
            !(s.starts_with("\x1b]11;rgb:") && (s.ends_with('\x07') || s.ends_with("\x1b\\")))
        })
        .map(|r| format!("{:?}", String::from_utf8_lossy(r)))
        .collect()
}

fn queries(n: usize) -> Vec<u8> {
    QUERY.repeat(n)
}

// ---------------------------------------------------------------------------
// Behaviour: the replay of a synchronized update is bounded by the cap
// ---------------------------------------------------------------------------

/// Precondition + action shared by the multi-chunk shapes: after the BSU and
/// the queries, nothing has been answered and the bytes sit in the parser's
/// sync buffer; after ESU the replay is answered. Returns the reply count.
fn replay_after_esu(rig: &Rig, label: &str, total_query_bytes: usize) -> usize {
    let before = rig.sync();
    assert_ne!(
        before.pending, 0,
        "{label}: precondition - a synchronized update must be open before ESU"
    );
    assert!(
        before.buffered_bytes as usize >= total_query_bytes,
        "{label}: precondition - the {total_query_bytes} query bytes must be buffered by vte \
         (buffered_bytes = {})",
        before.buffered_bytes
    );
    assert_eq!(
        rig.reply_count(),
        0,
        "{label}: precondition - queries inside a synchronized update must not be answered \
         before ESU"
    );
    rig.feed(ESU);
    assert_eq!(
        rig.sync().pending,
        0,
        "{label}: ESU must close the synchronized update"
    );
    rig.reply_count()
}

#[test]
fn sync_update_replay_of_300_colour_queries_is_answered_within_the_documented_cap() {
    let _g = serial();
    let total_query_bytes = FLOOD * QUERY.len();

    // Three ways the PTY layer may deliver the same byte stream.
    let mut measured: Vec<(&str, usize)> = Vec::new();

    // (a) BSU + queries + ESU in one `bb_term_input` call.
    {
        let rig = Rig::new();
        rig.assert_answers_a_lone_query();
        let mut all = BSU.to_vec();
        all.extend_from_slice(&queries(FLOOD));
        all.extend_from_slice(ESU);
        rig.feed(&all);
        assert_eq!(
            rig.sync().pending,
            0,
            "one-chunk: the synchronized update must be closed again"
        );
        let got = rig.replies();
        assert_eq!(
            malformed_replies(&got),
            Vec::<String>::new(),
            "one-chunk: replies must be well-formed OSC 11 replies"
        );
        measured.push(("one chunk", got.len()));
    }

    // (b) BSU + queries in one call, ESU in a second.
    {
        let rig = Rig::new();
        rig.assert_answers_a_lone_query();
        let mut head = BSU.to_vec();
        head.extend_from_slice(&queries(FLOOD));
        rig.feed(&head);
        let n = replay_after_esu(&rig, "bsu+queries | esu", total_query_bytes);
        assert_eq!(
            malformed_replies(&rig.replies()),
            Vec::<String>::new(),
            "bsu+queries | esu: replies must be well-formed OSC 11 replies"
        );
        measured.push(("bsu+queries | esu", n));
    }

    // (c) BSU, one call per query, ESU.
    {
        let rig = Rig::new();
        rig.assert_answers_a_lone_query();
        rig.feed(BSU);
        for _ in 0..FLOOD {
            rig.feed(QUERY);
        }
        let n = replay_after_esu(&rig, "bsu | query per call | esu", total_query_bytes);
        assert_eq!(
            malformed_replies(&rig.replies()),
            Vec::<String>::new(),
            "bsu | query per call | esu: replies must be well-formed OSC 11 replies"
        );
        measured.push(("bsu | query per call | esu", n));
    }

    for (shape, n) in &measured {
        assert_ne!(
            *n, 0,
            "{shape}: the replayed queries must be answered at all (measured {measured:?})"
        );
        assert!(
            *n <= DOCUMENTED_QUEUE_CAP,
            "{shape}: {FLOOD} colour queries inside one synchronized update must produce at \
             most the documented cap of {DOCUMENTED_QUEUE_CAP} replies, measured {n} \
             (all shapes: {measured:?})"
        );
        assert!(
            *n < FLOOD,
            "{shape}: the dropped remainder must not be answered - {FLOOD} queries produced {n} \
             replies (all shapes: {measured:?})"
        );
    }
}

// ---------------------------------------------------------------------------
// Behaviour: the gate is a tumbling window
// ---------------------------------------------------------------------------

#[test]
fn colour_reply_gate_is_tumbling_a_full_fresh_allowance_arrives_when_the_window_rolls() {
    // The gate allows N replies per 1 s window and resets WHOLESALE when the
    // window rolls over. A burst that fills the window just before the
    // boundary, followed by a second burst just after it (well under 1 s
    // later), is therefore answered with the same N again. A sliding window
    // would still count the first burst against the second and answer none.
    //
    // The window starts at terminal creation. Burst 1 must land inside the
    // first window (< ~0.97 s after creation) and burst 2 after the roll
    // (> 1.05 s after creation) yet < 0.95 s after burst 1; a machine stall
    // that breaks that makes the attempt inconclusive and it is retried.
    let _g = serial();
    const BURST: usize = 60; // > the 32/s gate, < the 128-token PtyWrite bucket

    let mut last_note = String::new();
    for attempt in 1..=3 {
        let created = Instant::now();
        // No lone-query control here: it would spend one slot of the very
        // allowance burst 1 measures. Burst 1 answering > 0 is the control.
        let rig = Rig::new();

        std::thread::sleep(Duration::from_millis(850));
        let burst1_start = created.elapsed();
        rig.feed(&queries(BURST));
        let burst1_end = created.elapsed();
        let r1 = rig.reply_count();

        let until = Duration::from_millis(1100);
        std::thread::sleep(until.saturating_sub(created.elapsed()));
        let burst2_start = created.elapsed();
        rig.feed(&queries(BURST));
        let r2 = rig.reply_count() - r1;

        let valid = burst1_end < Duration::from_millis(970)
            && burst2_start >= Duration::from_millis(1050)
            && burst2_start - burst1_start < Duration::from_millis(950);
        if !valid {
            last_note = format!(
                "attempt {attempt}: burst1 {burst1_start:?}..{burst1_end:?}, burst2 starts \
                 {burst2_start:?}"
            );
            continue;
        }

        assert!(
            r1 > 0 && r1 < BURST,
            "the gate must engage inside one window: {BURST} queries gave {r1} replies"
        );
        assert_eq!(
            r2, r1,
            "tumbling window: a burst of {BURST} queries just after the window rolled (burst 1 \
             at {burst1_start:?}, burst 2 at {burst2_start:?}, i.e. less than 1 s apart) must \
             get the same full allowance as burst 1 ({r1}), not {r2}"
        );
        return;
    }
    panic!("rig precondition: timing window missed in 3 attempts ({last_note})");
}

// ---------------------------------------------------------------------------
// Behaviour: stderr breadcrumbs (re-executed child process)
// ---------------------------------------------------------------------------

const CHILD_ENV: &str = "BB_COLOR_QUERY_CAP_DOCS_BLIND_CHILD";
const CHILD_ENTRY_TEST: &str =
    "sync_update_flood_logs_one_queue_cap_breadcrumb_not_one_per_dropped_query";

/// BSU + `n` queries (one call), check they are buffered and unanswered, ESU
/// (second call). Returns the reply count. Used inside the child.
fn sync_flood(n: usize) -> usize {
    let rig = Rig::new();
    rig.assert_answers_a_lone_query();
    let mut head = BSU.to_vec();
    head.extend_from_slice(&queries(n));
    rig.feed(&head);
    replay_after_esu(&rig, &format!("child sync x{n}"), n * QUERY.len())
}

/// `n` queries in ONE call with no synchronized update. Returns the reply
/// count.
fn plain_flood(n: usize) -> usize {
    let rig = Rig::new();
    rig.assert_answers_a_lone_query();
    assert_eq!(rig.sync().pending, 0, "child plain: no sync update open");
    rig.feed(&queries(n));
    rig.reply_count()
}

/// Runs inside the re-executed child. Prints phase markers (and measured
/// reply counts) to stderr; the core's own `eprintln!` breadcrumbs land in
/// between.
fn child_main() {
    eprintln!("@@PHASE SYNC_300");
    eprintln!("@@REPLIES {}", sync_flood(300));
    eprintln!("@@PHASE SYNC_1000");
    eprintln!("@@REPLIES {}", sync_flood(1000));
    eprintln!("@@PHASE SYNC_200");
    eprintln!("@@REPLIES {}", sync_flood(200));
    eprintln!("@@PHASE PLAIN_300");
    eprintln!("@@REPLIES {}", plain_flood(300));
    eprintln!("@@PHASE END");
}

#[derive(Debug)]
struct PhaseLog {
    name: String,
    replies: Option<usize>,
    /// Breadcrumbs about the ColorRequestQueue cap (mention the queue).
    queue_cap_lines: Vec<String>,
    /// Breadcrumbs about the per-second reply gate (colour, not the queue).
    gate_lines: Vec<String>,
}

struct ChildReport {
    stderr: String,
    phases: Vec<PhaseLog>,
}

impl ChildReport {
    fn phase(&self, name: &str) -> &PhaseLog {
        self.phases
            .iter()
            .find(|p| p.name == name)
            .unwrap_or_else(|| panic!("phase {name} missing; child stderr:\n{}", self.stderr))
    }
}

/// A log line about the colour-query DoS caps: it names colour and says a
/// cap / limit / drop happened.
fn is_colour_drop_line(line: &str) -> bool {
    let l = line.to_ascii_lowercase();
    (l.contains("color") || l.contains("colour"))
        && ["cap", "drop", "limit", "exceed"]
            .iter()
            .any(|w| l.contains(w))
}

fn is_queue_cap_line(line: &str) -> bool {
    is_colour_drop_line(line) && line.to_ascii_lowercase().contains("queue")
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

        let mut phases: Vec<PhaseLog> = Vec::new();
        for line in stderr.lines() {
            if let Some(name) = line.strip_prefix("@@PHASE ") {
                phases.push(PhaseLog {
                    name: name.trim().to_string(),
                    replies: None,
                    queue_cap_lines: Vec::new(),
                    gate_lines: Vec::new(),
                });
            } else if let Some(n) = line.strip_prefix("@@REPLIES ") {
                if let Some(p) = phases.last_mut() {
                    p.replies = n.trim().parse::<usize>().ok();
                }
            } else if is_colour_drop_line(line) {
                if let Some(p) = phases.last_mut() {
                    if is_queue_cap_line(line) {
                        p.queue_cap_lines.push(line.to_string());
                    } else {
                        p.gate_lines.push(line.to_string());
                    }
                }
            }
        }
        ChildReport { stderr, phases }
    })
}

fn assert_child_walked_every_phase(r: &ChildReport) {
    let names: Vec<&str> = r.phases.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(
        names,
        vec!["SYNC_300", "SYNC_1000", "SYNC_200", "PLAIN_300", "END"],
        "rig precondition: the child must walk every phase; child stderr:\n{}",
        r.stderr
    );
    for name in ["SYNC_300", "SYNC_1000", "SYNC_200", "PLAIN_300"] {
        assert_ne!(
            r.phase(name).replies,
            None,
            "rig precondition: phase {name} must report its reply count; child stderr:\n{}",
            r.stderr
        );
    }
}

#[test]
fn sync_update_flood_logs_one_queue_cap_breadcrumb_not_one_per_dropped_query() {
    if matches!(std::env::var(CHILD_ENV).as_deref(), Ok("1")) {
        child_main();
        return;
    }
    let _g = serial();
    let r = child_report();
    assert_child_walked_every_phase(r);

    // Inside a synchronized update the whole replayed buffer is one drain
    // interval, so a flood past 256 queries hits the queue cap: 300 queries
    // drop 44, 1000 queries drop 744 - and each replay leaves ONE breadcrumb
    // (per-drop logging would itself be the amplifier the cap defends
    // against).
    for (name, sent) in [("SYNC_300", 300usize), ("SYNC_1000", 1000usize)] {
        let p = r.phase(name);
        assert_eq!(
            p.queue_cap_lines.len(),
            1,
            "{name}: {sent} colour queries replayed from one synchronized update must hit the \
             {DOCUMENTED_QUEUE_CAP} queue cap and log exactly one breadcrumb for the dropped \
             remainder; measured {} queue-cap line(s): {:?}\nchild stderr:\n{}",
            p.queue_cap_lines.len(),
            p.queue_cap_lines,
            r.stderr
        );
        assert!(
            p.queue_cap_lines[0].contains("256"),
            "{name}: the queue-cap breadcrumb must name the documented cap {DOCUMENTED_QUEUE_CAP}; \
             got {:?}",
            p.queue_cap_lines[0]
        );
        let replies = p.replies.unwrap_or(usize::MAX);
        assert!(
            replies > 0 && replies <= DOCUMENTED_QUEUE_CAP,
            "{name}: replies must be in 1..={DOCUMENTED_QUEUE_CAP}, measured {replies}"
        );
    }
}

#[test]
fn colour_reply_gate_logs_its_first_drop_and_the_queue_cap_is_only_a_backstop_outside_sync() {
    let _g = serial();
    let r = child_report();
    assert_child_walked_every_phase(r);

    // Below the cap (200 < 256) or outside a synchronized update (every
    // ESC-delimited segment drains) the queue never overflows: no queue-cap
    // breadcrumb. The per-second gate still bounds the replies and says so
    // once for the window.
    for (name, sent) in [("SYNC_200", 200usize), ("PLAIN_300", 300usize)] {
        let p = r.phase(name);
        assert_eq!(
            p.queue_cap_lines.len(),
            0,
            "{name}: {sent} queries must not overflow the {DOCUMENTED_QUEUE_CAP}-entry queue \
             (below the cap, or drained per ESC-delimited segment); measured {} queue-cap \
             line(s): {:?}\nchild stderr:\n{}",
            p.queue_cap_lines.len(),
            p.queue_cap_lines,
            r.stderr
        );
        let replies = p.replies.unwrap_or(usize::MAX);
        assert!(
            replies > 0 && replies < sent,
            "{name}: the gate must answer some but not all of {sent} queries, measured {replies}"
        );
        // Tumbling window: the first drop per window logs; a scenario that
        // happens to straddle a 1 s boundary may log twice, never more.
        assert!(
            (1..=2).contains(&p.gate_lines.len()),
            "{name}: the colour-reply gate must log its first drop per window (1..=2 gate lines \
             expected), measured {}: {:?}\nchild stderr:\n{}",
            p.gate_lines.len(),
            p.gate_lines,
            r.stderr
        );
    }

    // The same gate also bounds the sync replay, with a bounded number of
    // gate breadcrumbs.
    for name in ["SYNC_300", "SYNC_1000"] {
        let p = r.phase(name);
        assert!(
            (1..=2).contains(&p.gate_lines.len()),
            "{name}: the gate must log its first drop for the replayed buffer too (1..=2 gate \
             lines expected), measured {}: {:?}\nchild stderr:\n{}",
            p.gate_lines.len(),
            p.gate_lines,
            r.stderr
        );
    }
}

// ---------------------------------------------------------------------------
// Documentation: the comments around the cap and the gate
// ---------------------------------------------------------------------------
//
// These tests read the COMMENTS of `core/src/{lib,rate_limit,input,callback}.rs`
// (never the code) and check that the colour-cap / colour-gate docs state the
// corrected facts. Blocks are located by the item they document (anchors) and
// by the identifiers they mention, so rewording or moving text inside a
// docblock is fine; renaming the documented items is not.

#[derive(Clone, Debug)]
struct Block {
    first: usize,
    last: usize,
    /// Original text (comment markers stripped, lines joined with a space);
    /// case-sensitive identifier checks run on this.
    raw: String,
    /// Lower-case, single-spaced.
    norm: String,
    /// Lower-case, all whitespace removed: survives line wraps inside a
    /// phrase ("ESC-\n delimited").
    compact: String,
}

impl Block {
    fn new(first: usize, last: usize, raw: String) -> Block {
        let norm = raw
            .to_lowercase()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        let compact = norm.replace(' ', "");
        Block {
            first,
            last,
            raw,
            norm,
            compact,
        }
    }

    fn has(&self, phrase: &str) -> bool {
        self.compact
            .contains(&phrase.to_lowercase().replace(' ', ""))
    }

    fn has_any(&self, phrases: &[&str]) -> bool {
        phrases.iter().any(|p| self.has(p))
    }

    /// Whole-word phrase match (a trailing plural `s` is tolerated). Used
    /// where a prefix match would be a false positive: the stale wording "the
    /// cap only bounds one drain" must not satisfy "only bound".
    fn has_word_phrase(&self, phrase: &str) -> bool {
        let p = phrase.to_lowercase();
        let mut from = 0;
        while let Some(pos) = self.norm[from..].find(&p) {
            let at = from + pos;
            let end = at + p.len();
            let left_ok = self.norm[..at]
                .chars()
                .next_back()
                .is_none_or(|c| !c.is_alphanumeric());
            let mut rest = self.norm[end..].chars();
            let right_ok = match rest.next() {
                None => true,
                Some(c) if !c.is_alphanumeric() => true,
                Some('s') => rest.next().is_none_or(|c| !c.is_alphanumeric()),
                Some(_) => false,
            };
            if left_ok && right_ok {
                return true;
            }
            from = end;
        }
        false
    }

    fn words(&self) -> Vec<&str> {
        self.norm
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .collect()
    }

    fn label(&self, file: &str) -> String {
        format!("{file}:{}-{}", self.first, self.last)
    }
}

fn comment_blocks(src: &str) -> Vec<Block> {
    let mut out: Vec<Block> = Vec::new();
    let mut cur: Option<(usize, usize, Vec<String>)> = None;
    for (i, line) in src.lines().enumerate() {
        let lineno = i + 1;
        let t = line.trim_start();
        if let Some(rest) = t.strip_prefix("//") {
            let body = rest.trim_start_matches(['/', '!']).trim().to_string();
            match cur.as_mut() {
                Some((_, last, lines)) => {
                    *last = lineno;
                    lines.push(body);
                }
                None => cur = Some((lineno, lineno, vec![body])),
            }
        } else if let Some((f, l, lines)) = cur.take() {
            out.push(Block::new(f, l, lines.join(" ")));
        }
    }
    if let Some((f, l, lines)) = cur.take() {
        out.push(Block::new(f, l, lines.join(" ")));
    }
    out
}

fn read_src(file: &str) -> String {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src")
        .join(file);
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("cannot read {}: {e}", p.display()))
}

/// Zero-based index of the first non-comment line containing `needle`.
fn item_line(lines: &[&str], needle: &str) -> Option<usize> {
    lines
        .iter()
        .position(|l| !l.trim_start().starts_with("//") && l.contains(needle))
}

/// The comment block directly above the item on line `idx` (skipping
/// `#[...]` attributes).
fn block_above(blocks: &[Block], lines: &[&str], idx: usize) -> Option<Block> {
    let mut j = idx;
    while j > 0 && lines[j - 1].trim_start().starts_with("#[") {
        j -= 1;
    }
    blocks.iter().find(|b| b.last == j).cloned()
}

struct Docs {
    file: &'static str,
    blocks: Vec<Block>,
}

/// Identifiers whose presence marks a comment block as colour-cap /
/// colour-gate documentation.
const GATE_IDS: [&str; 3] = [
    "COLOR_QUERY_REPLY",
    "COLOR_REQUEST_QUEUE_CAP",
    "color_query_reply",
];

impl Docs {
    /// `anchors`: substrings of item lines whose preceding docblock belongs
    /// in the set. `drain_fn`: also take every comment inside this function
    /// and its docblock.
    fn load(file: &'static str, anchors: &[&str], drain_fn: Option<&str>) -> Docs {
        let src = read_src(file);
        let lines: Vec<&str> = src.lines().collect();
        let all = comment_blocks(&src);
        let mut picked: Vec<Block> = Vec::new();
        fn push(b: Block, picked: &mut Vec<Block>) {
            if !picked.iter().any(|p| p.first == b.first) {
                picked.push(b);
            }
        }

        for a in anchors {
            let idx = item_line(&lines, a)
                .unwrap_or_else(|| panic!("doc anchor {a:?} not found in core/src/{file}"));
            let b = block_above(&all, &lines, idx).unwrap_or_else(|| {
                panic!("no comment block directly above {a:?} in core/src/{file}")
            });
            push(b, &mut picked);
        }
        for b in &all {
            if GATE_IDS.iter().any(|id| b.raw.contains(id)) {
                push(b.clone(), &mut picked);
            }
        }
        if let Some(f) = drain_fn {
            let start = item_line(&lines, &format!("fn {f}("))
                .unwrap_or_else(|| panic!("fn {f} not found in core/src/{file}"));
            let end = (start + 1..lines.len())
                .find(|&i| lines[i] == "}")
                .unwrap_or_else(|| panic!("end of fn {f} not found in core/src/{file}"));
            if let Some(b) = block_above(&all, &lines, start) {
                push(b, &mut picked);
            }
            for b in &all {
                if b.first > start + 1 && b.last <= end + 1 {
                    push(b.clone(), &mut picked);
                }
            }
        }
        picked.sort_by_key(|b| b.first);
        assert_ne!(
            picked.len(),
            0,
            "rig precondition: no colour-cap docs found in core/src/{file}"
        );
        Docs {
            file,
            blocks: picked,
        }
    }

    fn any(&self, phrases: &[&str]) -> bool {
        self.blocks.iter().any(|b| b.has_any(phrases))
    }

    fn any_word_phrase(&self, phrases: &[&str]) -> bool {
        self.blocks
            .iter()
            .any(|b| phrases.iter().any(|p| b.has_word_phrase(p)))
    }

    fn dump(&self) -> String {
        self.blocks
            .iter()
            .map(|b| format!("  [{}] {}", b.label(self.file), b.raw))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn lib_docs() -> Docs {
    Docs::load(
        "lib.rs",
        &[
            "pub(crate) color_query_reply_window_start:",
            "pub(crate) color_query_reply_drop_logged:",
        ],
        None,
    )
}

fn rate_limit_docs() -> Docs {
    Docs::load(
        "rate_limit.rs",
        &["pub(crate) const COLOR_QUERY_REPLY_PER_SECOND"],
        None,
    )
}

fn input_docs() -> Docs {
    Docs::load("input.rs", &[], Some("drain_color_requests"))
}

fn callback_docs() -> Docs {
    Docs::load(
        "callback.rs",
        &[
            "pub(crate) struct ColorRequestQueue",
            "pub(crate) const COLOR_REQUEST_QUEUE_CAP",
            "fn push(&self, entry: ColorRequestEntry)",
        ],
        None,
    )
}

/// Phrases that qualify a cap statement as being about a DEC 2026
/// synchronized update. Dates such as "2026-05-21" deliberately do not count.
const SYNC_QUALIFIERS: [&str; 6] = [
    "synchroni",
    "dec 2026",
    "mode 2026",
    "?2026",
    "sync update",
    "sync-update",
];

const LIVE_BOUND_PHRASES: [&str; 13] = [
    "live bound",
    "live limit",
    "live cap",
    "live defence",
    "live defense",
    "only bound",
    "only limit",
    "effective bound",
    "effective limit",
    "binding bound",
    "binding limit",
    "operative bound",
    "actual bound",
];

/// Occurrences of `needle` in `norm` that are not negated ("not sliding",
/// "rather than a sliding window") and not excused by what follows. Returns
/// a snippet per offending occurrence.
fn unexcused_mentions(norm: &str, needle: &str, excuses_after: &[&str]) -> Vec<String> {
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(pos) = norm[from..].find(needle) {
        let at = from + pos;
        let mut start = at.saturating_sub(25);
        while start < at && !norm.is_char_boundary(start) {
            start += 1;
        }
        let mut end = (at + needle.len() + 60).min(norm.len());
        while end < norm.len() && !norm.is_char_boundary(end) {
            end += 1;
        }
        let before = &norm[start..at];
        let after = &norm[at + needle.len()..end];
        let negated = before.split(|c: char| !c.is_alphanumeric()).any(|w| {
            matches!(
                w,
                "not" | "non" | "isn" | "never" | "unlike" | "than" | "no"
            )
        });
        let excused = excuses_after.iter().any(|e| after.contains(e));
        if !negated && !excused {
            out.push(format!("...{}{}{}...", before, needle, after));
        }
        from = at + needle.len();
    }
    out
}

/// Problems every file's colour-cap docs must not have: a drain interval
/// described as always one ESC-delimited segment (no synchronized-update
/// qualifier in the same docblock), the gate called sliding, the limiter
/// described as silent.
fn wording_problems(d: &Docs) -> Vec<String> {
    let mut problems = Vec::new();
    for b in &d.blocks {
        if b.has("ESC-delimited") && !b.has_any(&SYNC_QUALIFIERS) && !b.has("replay") {
            problems.push(format!(
                "{}: describes the drain interval as an ESC-delimited segment without saying \
                 that inside a DEC 2026 synchronized update the whole replayed buffer is one \
                 interval",
                b.label(d.file)
            ));
        }
        for hit in unexcused_mentions(&b.norm, "sliding", &[]) {
            problems.push(format!(
                "{}: calls the reply gate sliding-window, but it is a tumbling window: {hit}",
                b.label(d.file)
            ));
        }
        let about_limiter = b.words().iter().any(|w| {
            matches!(
                *w,
                "cap" | "window" | "gate" | "limit" | "limiter" | "bound"
            )
        });
        if about_limiter {
            for hit in unexcused_mentions(
                &b.norm,
                "silent",
                &["except", "first", "once", "one-shot", "breadcrumb", "but"],
            ) {
                problems.push(format!(
                    "{}: describes the colour cap/gate as silent, but the first drop is logged: \
                     {hit}",
                    b.label(d.file)
                ));
            }
        }
    }
    problems
}

/// The positive statements the cap docs of a file must make.
fn cap_statement_problems(d: &Docs) -> Vec<String> {
    let mut problems = wording_problems(d);
    if !d.any(&SYNC_QUALIFIERS) {
        problems.push(format!(
            "core/src/{}: never mentions the DEC 2026 synchronized update in the cap/gate docs",
            d.file
        ));
    }
    if !d.any(&["replay"]) {
        problems.push(format!(
            "core/src/{}: never says the whole REPLAYED buffer of a synchronized update is one \
             drain interval",
            d.file
        ));
    }
    if !d.any(&["backstop"]) {
        problems.push(format!(
            "core/src/{}: never says the cap is only a BACKSTOP outside a synchronized update",
            d.file
        ));
    }
    if !d.any_word_phrase(&LIVE_BOUND_PHRASES) {
        problems.push(format!(
            "core/src/{}: never says the cap is the LIVE BOUND inside a synchronized update",
            d.file
        ));
    }
    problems
}

fn gate_statement_problems(d: &Docs) -> Vec<String> {
    let mut problems = Vec::new();
    if !d.any(&["tumbling"]) {
        problems.push(format!(
            "core/src/{}: never says the colour-reply gate is a TUMBLING window",
            d.file
        ));
    }
    if !d.any(&["first drop", "breadcrumb", "logs", "logged", "logging"]) {
        problems.push(format!(
            "core/src/{}: never says the gate logs its first drop per window",
            d.file
        ));
    }
    problems
}

#[test]
fn control_doc_anchors_resolve_to_colour_cap_docs() {
    // Not the bug: proves the doc extraction finds real colour-cap docs in
    // every file, so the doc tests below cannot pass vacuously on an empty
    // selection.
    for d in [lib_docs(), rate_limit_docs(), input_docs(), callback_docs()] {
        assert!(
            d.blocks.iter().any(|b| b.has_any(&["color", "colour"])),
            "core/src/{}: the selected comment blocks do not mention colour at all:\n{}",
            d.file,
            d.dump()
        );
        assert!(
            d.blocks
                .iter()
                .any(|b| b.has_any(&["cap", "window", "gate"])),
            "core/src/{}: the selected comment blocks do not discuss a cap/window/gate:\n{}",
            d.file,
            d.dump()
        );
    }
}

fn assert_no_problems(d: &Docs, problems: Vec<String>, what: &str) {
    assert_eq!(
        problems,
        Vec::<String>::new(),
        "core/src/{} {what}; comment blocks examined:\n{}",
        d.file,
        d.dump()
    );
}

#[test]
fn lib_rs_docs_describe_the_sync_update_bound_and_a_tumbling_logging_gate() {
    let d = lib_docs();
    let mut problems = cap_statement_problems(&d);
    problems.extend(gate_statement_problems(&d));
    assert_no_problems(
        &d,
        problems,
        "(`color_query_reply_*` field docs) must describe the queue cap as a per-segment \
         backstop outside a synchronized update and the live per-replayed-buffer bound inside \
         one, and the reply gate as a tumbling window that logs its first drop",
    );
}

#[test]
fn rate_limit_rs_docs_describe_the_sync_update_bound_and_a_tumbling_logging_gate() {
    let d = rate_limit_docs();
    let mut problems = cap_statement_problems(&d);
    problems.extend(gate_statement_problems(&d));
    assert_no_problems(
        &d,
        problems,
        "(`COLOR_QUERY_REPLY_PER_SECOND` docs) must describe the queue cap as a per-segment \
         backstop outside a synchronized update and the live per-replayed-buffer bound inside \
         one, and the reply gate as a tumbling window that logs its first drop",
    );
}

#[test]
fn input_rs_docs_describe_the_sync_update_bound_and_a_tumbling_logging_gate() {
    let d = input_docs();
    let mut problems = cap_statement_problems(&d);
    problems.extend(gate_statement_problems(&d));
    assert_no_problems(
        &d,
        problems,
        "(`drain_color_requests` comments) must describe the queue cap as a per-segment \
         backstop outside a synchronized update and the live per-replayed-buffer bound inside \
         one, and the reply gate as a tumbling window that logs its first drop",
    );
}

#[test]
fn callback_rs_color_request_queue_docs_describe_the_sync_update_bound() {
    let d = callback_docs();
    let problems = cap_statement_problems(&d);
    assert_no_problems(
        &d,
        problems,
        "(`ColorRequestQueue` / `COLOR_REQUEST_QUEUE_CAP` / `push` docs) must describe the cap \
         as a per-segment backstop outside a synchronized update and the live \
         per-replayed-buffer bound inside one, must not call the reply gate sliding-window, \
         and must not say the overflow drop is silent",
    );
}
