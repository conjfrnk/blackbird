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
